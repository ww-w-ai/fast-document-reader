//! Markdown -> canonical `RenderTree` producer (S3, pass A: contracts and the block layer).
//!
//! Bytes and a source name become the SAME `ValidatedRenderTree` the office adapters produce,
//! through the same `RenderTreeBuilder` (`render_tree/mod.rs`) — one canonical consumer serves
//! every format. This module resolves nothing that needs a viewport: no column widths, no font
//! metrics, no measured heights. Whatever the document declared crosses as the document's own
//! words.
//!
//! `s3.md`'s Design lays out three layers, in a fixed order, because parsing destroys two of
//! them: `scan` (math spans, taken from the raw source before any parse — `math.rs`, S3-05) ->
//! `parse` (comrak AST over the UNMODIFIED source — this module) -> `map` (comrak node -> wire
//! node — `blocks.rs` for block vocabulary and mermaid fences, `inline.rs` for inline
//! styles/links/raw HTML/images, S3-04/S3-06/S3-10). A node whose comrak `Sourcepos` falls
//! entirely inside a scanned math span is replaced by one `formula` node carrying the ORIGINAL
//! tex (`Ctx::math_hit`, checked at the top of both `blocks::map_block` and
//! `inline::Builder::walk` — math can surface at either granularity depending on how badly
//! parse-first shredded the surrounding block).
//!
//! `markdown_renderer.rs` is NOT extended or reused: it targets `NSAttributedString` and its
//! parse step is `todo!()`; pass C deletes it (S3-08). This producer is a fresh module reaching
//! the canonical tree the same door every other producer does.

mod blocks;
mod inline;
mod math;
mod source_position;

use comrak::{parse_document, Arena, Options};
use sha2::{Digest, Sha256};

use crate::render::render_tree::{
    DecodeError, DocumentFormat, Empty, NodePayload, RenderDocumentDraft,
    RenderResourceDraft, RenderTreeBuilder, RenderSourceDraft, SourceKind, ValidatedRenderTree,
};

use math::MathSpan;
use source_position::LineIndex;

/// What `Ctx::math_hit` found for one comrak node's `Sourcepos`, decided the moment it is asked
/// (never precomputed) so both `blocks.rs` and `inline.rs` can check at whatever granularity the
/// node they are looking at happens to be.
pub(crate) enum MathHit {
    /// Outside every scanned span — map this node normally.
    NotMath,
    /// The FIRST node found entirely inside this span. The caller emits ONE `formula` node
    /// carrying this tex and does not descend into the node's own children.
    Emit(String),
    /// A LATER node inside a span another node already claimed. The caller emits NOTHING at all
    /// for this node and does not descend — mirrors `emittedMath.insert(...).inserted == false`.
    Suppressed,
}

/// What this producer refuses, and why. Never a silent drop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MarkdownError {
    /// The source bytes are not valid UTF-8 — markdown has no other honest encoding to assume,
    /// and the wire schema's `RangeSegment::Text` (S3-11) requires a UTF-8 string to index into.
    InvalidUtf8,
    /// The tree this producer built failed canonical validation — should never happen for a
    /// correctly implemented producer, but never swallowed.
    Canonicalization(DecodeError),
}

/// The mutable build state threaded through the block AND inline walk: the id counter, the flat
/// node list (`RenderTreeBuilder` sorts by id before validation, so append order does not
/// matter), the two things every `source_spans` conversion needs (the raw text and its line
/// index), the scanned math spans plus which ones a node has already claimed
/// (`math_hit`/S3-05), and the image-resource dedup table `resolve_image_resource` (S3-06)
/// builds, keyed by declared `src` the same way `office_adapter.rs`'s own resource table is keyed
/// by declared image id.
pub(crate) struct Ctx<'a> {
    next_node_id: u64,
    nodes: Vec<crate::render::render_tree::RenderNodeDraft>,
    text: &'a str,
    line_index: &'a LineIndex,
    math_spans: &'a [MathSpan],
    emitted_math: std::collections::HashSet<usize>,
    next_resource_id: u64,
    resources: Vec<RenderResourceDraft>,
    resource_by_key: std::collections::BTreeMap<String, u64>,
    resource_by_hash: std::collections::BTreeMap<String, u64>,
}

impl<'a> Ctx<'a> {
    fn new(text: &'a str, line_index: &'a LineIndex, math_spans: &'a [MathSpan]) -> Self {
        Self {
            next_node_id: 1,
            nodes: Vec::new(),
            text,
            line_index,
            math_spans,
            emitted_math: std::collections::HashSet::new(),
            next_resource_id: 1,
            resources: Vec::new(),
            resource_by_key: std::collections::BTreeMap::new(),
            resource_by_hash: std::collections::BTreeMap::new(),
        }
    }

    fn new_node_id(&mut self) -> u64 {
        let id = self.next_node_id;
        self.next_node_id += 1;
        id
    }

    fn push(&mut self, node: crate::render::render_tree::RenderNodeDraft) {
        self.nodes.push(node);
    }

    /// One `Provenance`/`Exact` span carrying a block's whole comrak `Sourcepos`, converted to
    /// UTF-8 AND UTF-16 offsets (`source_position::LineIndex::segment`). Block granularity only —
    /// inline nodes (`textRun`) carry no span this pass; see `blocks.rs`'s module doc for why.
    fn span_for(
        &self,
        sourcepos: comrak::nodes::Sourcepos,
    ) -> Vec<crate::render::render_tree::SourceSpan> {
        vec![crate::render::render_tree::SourceSpan {
            source_id: 1,
            purpose: crate::render::render_tree::SpanPurpose::Provenance,
            affinity: crate::render::render_tree::Affinity::Exact,
            segments: vec![self.line_index.segment(self.text, sourcepos)],
        }]
    }

    /// See `MathHit`'s own doc for what each variant means to the caller. This is
    /// `mathSpan(containing:)` PLUS the `emittedMath` dedup, folded into one call so
    /// `blocks::map_block` and `inline::Builder::walk` each need exactly one check at the top.
    fn math_hit(&mut self, sourcepos: comrak::nodes::Sourcepos) -> MathHit {
        match math::containing(self.math_spans, self.line_index, sourcepos) {
            None => MathHit::NotMath,
            Some(idx) if self.emitted_math.insert(idx) => {
                MathHit::Emit(self.math_spans[idx].tex.clone())
            }
            Some(_) => MathHit::Suppressed,
        }
    }

    /// A markdown image's declared `src` -> a wire resource id, deduped first by the exact `src`
    /// string (the same source referenced twice) and then by content hash (two different `src`
    /// strings that happen to collide, mirroring `office_adapter.rs`'s own two-level dedup).
    ///
    /// This producer does not read image bytes (S3-06's design: resolving that image needs a
    /// filesystem/network fetch this pass has no mandate for, and `Image.resource_id` still
    /// requires SOME registered resource — `validate.rs`'s `require_resource`). The resource this
    /// registers carries the document's own declared `src` STRING as its content, with MIME type
    /// `text/uri-list` (RFC 2483 — the real registered type for "this is a URI reference", not an
    /// invented one) — an honest statement of what is actually known ("the document points here"),
    /// never a guess at the image's own bytes or dimensions. `Image.intrinsic_size` is set to
    /// `{0, 0}` by the caller for the same reason `blocks.rs`'s table producer uses `0.0` grid
    /// widths: a finite, honest placeholder for "this pass did not resolve it" rather than a
    /// guessed value invariants 1/2/11 would then need correcting later.
    fn resolve_image_resource(&mut self, src: &str) -> u64 {
        if let Some(&id) = self.resource_by_key.get(src) {
            return id;
        }
        let bytes = src.as_bytes();
        let hash = format!("{:x}", Sha256::digest(bytes));
        if let Some(&id) = self.resource_by_hash.get(&hash) {
            self.resource_by_key.insert(src.to_string(), id);
            return id;
        }
        let id = self.next_resource_id;
        self.next_resource_id += 1;
        use base64::Engine;
        let bytes_base64 = base64::engine::general_purpose::STANDARD.encode(bytes);
        self.resources.push(RenderResourceDraft {
            id,
            mime_type: "text/uri-list".to_string(),
            sha256: hash.clone(),
            byte_length: bytes.len() as u64,
            bytes_base64,
            intrinsic_size: None,
            source_key: None,
        });
        self.resource_by_key.insert(src.to_string(), id);
        self.resource_by_hash.insert(hash, id);
        id
    }
}

/// Bytes and a source name to a validated markdown `RenderTree`. Extensions enabled at parse time
/// (not via a Cargo feature — comrak GFM extensions are runtime `ExtensionOptions`): tables and
/// task lists (S3-03), plus strikethrough and autolink (S3-04, pass B) — GFM extensions default
/// OFF in comrak, and leaving either unset is exactly invariant 41's failure (strikethrough
/// shipped dead once already because nothing turned the option on).
pub fn produce(bytes: &[u8], source_name: &str) -> Result<ValidatedRenderTree, MarkdownError> {
    let text = std::str::from_utf8(bytes).map_err(|_| MarkdownError::InvalidUtf8)?;
    let line_index = LineIndex::build(text);
    // Layer 1 — scan BEFORE parsing (S3-05, invariant 12). `math.rs`'s module doc has the full
    // rationale for why this producer never masks the source the way a first draft of this design
    // did: comrak parses the real, unmodified bytes below, exactly like the shipping renderer.
    let math_spans = math::scan_math_spans(text);

    let arena = Arena::new();
    let mut options = Options::default();
    options.extension.table = true;
    options.extension.tasklist = true;
    options.extension.strikethrough = true;
    options.extension.autolink = true;
    let root = parse_document(&arena, text, &options);

    let mut ctx = Ctx::new(text, &line_index, &math_spans);
    let doc_id = ctx.new_node_id();
    let mut top_children = Vec::new();
    for child in root.children() {
        blocks::map_block(child, doc_id, &mut ctx, &mut top_children);
    }
    ctx.push(crate::render::render_tree::RenderNodeDraft {
        id: doc_id,
        parent_id: None,
        children: top_children,
        source_spans: vec![],
        edit: None,
        payload: NodePayload::Document(Empty {}),
    });

    let document = RenderDocumentDraft {
        format: DocumentFormat::Markdown,
        editable: false,
        root_node_id: doc_id,
        source_ids: vec![],
        default_locale: None,
        declared_faces: std::collections::BTreeMap::new(),
    };
    let mut builder = RenderTreeBuilder::new("fastdoc-markdown-producer", document);

    let sha256 = format!("{:x}", Sha256::digest(bytes));
    builder.add_source(RenderSourceDraft {
        id: 1,
        kind: SourceKind::DecodedText,
        name: source_name.to_string(),
        encoding: Some("UTF-8".to_string()),
        revision: "1".to_string(),
        sha256,
        byte_length: Some(bytes.len() as u64),
        utf8_length: Some(text.len() as u64),
        utf16_length: Some(text.encode_utf16().count() as u64),
        editable: false,
        text_content: Some(text.to_string()),
    });
    for node in ctx.nodes {
        builder.add_node(node);
    }
    for resource in ctx.resources {
        builder.add_resource(resource);
    }
    builder.build().map_err(MarkdownError::Canonicalization)
}
