//! Checked conversion from the existing Office reader model into semantic RenderTree v1.
//!
//! Office documents carry no valid EDITABLE source coordinates (the byte/character offsets a
//! `.docx`/`.odt`/`.hwp` reader produces do not survive a round trip the way markdown's do), so
//! this adapter never emits `source_spans` or `edit` metadata on any node — every node's
//! provenance is the single whole-file `RenderSourceDraft` this module adds, `editable: false`.
//!
//! IDs are allocated across a few deterministic passes, each internally depth-first preorder, so
//! a node's id is always smaller than every id in its own subtree even though the passes no
//! longer form one single walk: the Document root is 1; every section's own id is reserved next
//! (so a header/footer/footnote can point `parent_id` straight at its owning section without a
//! later patch); then every `OfficeHeaderFooter`/`OfficeFootnote` is built (each owning a `Flow`
//! of its own blocks); then each section's body flow and its blocks are built in turn. Source ids
//! and resource ids are separate counters, each starting at 1 independently — and so are comment
//! ids and bookmark ids (`Annotations` is validated as its own id space, disjoint from node ids).

use super::office_accounting::{self, AccountingError};
use super::wire;
use super::{DecodeError, DocumentFormat, RenderTreeBuilder, ValidatedRenderTree};
use crate::render::office::column_geometry::OfficeColumnLayout;
use crate::render::office::hwp_shape_path::{PathCommand as HwpPathCommand, PathSpec, VectorGraphic};
use crate::render::office::office_block::{
    self, BorderDecl, BorderSide, Cell, CellVAlign, EdgeBorders, EdgePadding, OfficeBlock,
    OfficeComment, OfficeFootnote, OfficeFormControl, OfficeHeaderFooter, OfficeReadResult,
    PaperGeometry, Span, TableFormat,
};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use swiftshim::{CGSize, NSColor, NSImage, NSTextAlignment, SwiftString};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedOfficeResource {
    pub bytes: Vec<u8>,
    pub mime_type: String,
}

pub struct OfficeAdapterInput<'a> {
    pub format: DocumentFormat,
    pub source_name: &'a str,
    pub source_bytes: &'a [u8],
    pub result: &'a OfficeReadResult,
    pub resources: BTreeMap<String, ResolvedOfficeResource>,
}

/// What this adapter refuses, and why. Each variant is a fact the source declared that the
/// semantic tree has no honest place to put — never a silent drop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OfficeAdapterError {
    /// A block referenced a resource key (`OfficeBlock::Image.id` or `.background_image`'s key)
    /// that is absent from `OfficeAdapterInput.resources`.
    MissingResource(String),
    /// An `OfficeAnchoredObject.block_index` names a position `OfficeReadResult.blocks` does not
    /// hold a mapped node for — the reader's own contract (mapping.rs) leaves an empty paragraph
    /// carrier at that index rather than dropping the block, so this should never fire for a
    /// document a real reader produced; carried rather than panicked so a reader that some day
    /// breaks that contract fails with a name, not a crash.
    AnchoredObjectTargetMissing(i64),
    /// An `OfficeHeaderFooter` or `OfficeFootnote` named a section index (`.section`) that does
    /// not exist among `OfficeReadResult.sections` — a document fact the tree has no section to
    /// attach it to, never silently reassigned to section 0.
    SectionIndexMissing(i64),
    /// A `Span.comment_ids` entry names a comment id that `OfficeReadResult.comments` does not
    /// contain — a dangling reference, never dropped and never invented.
    UnresolvedCommentId(String),
    /// An `OfficeFootnote.number` is negative — `wire::Footnote.number` is `u64` and there is no
    /// honest non-negative value to substitute for it.
    NegativeFootnoteNumber(i64),
    /// The tree this adapter built failed canonical validation. Carries the validator's own
    /// error so a caller can see exactly which invariant this adapter's own construction violated
    /// — this should never happen for a correctly implemented adapter, but is not swallowed.
    Canonicalization(DecodeError),
    /// A `Span` or section carried an `OfficeColumnLayout` that `column_flow_from_office` could
    /// not honestly convert — most often `AccountingError::IncompleteOfficeColumnAuthority` (the
    /// raw pool never resolved this declaration, or resolved it ambiguously). Never substituted
    /// with `None` and never fabricated: the wrapped accounting error names exactly why.
    InvalidColumnAuthority(AccountingError),
}

pub(super) fn from_office(
    input: OfficeAdapterInput<'_>,
) -> Result<ValidatedRenderTree, OfficeAdapterError> {
    let result = input.result;

    let mut ctx = Ctx::new(result, &input.resources);
    ctx.register_comments(&result.comments);

    let root_id = ctx.new_node_id();

    // Every section's own id is reserved up front, before any header/footer/footnote or body
    // content, so those can point `parent_id` straight at their owning section instead of a
    // post-hoc patch. `section_count` mirrors the fallback the body-slicing loop below already
    // used: one synthetic section owning the whole document when the source declared none.
    let section_count = result.sections.len().max(1);
    let section_ids: Vec<u64> = (0..section_count).map(|_| ctx.new_node_id()).collect();

    // Every id in `header_ids`/`footer_ids`/`footnote's home` that a section's OWN OfficeHeaderFooter/
    // OfficeFootnote resolved to (`.section == Some(idx)`), plus — for headers/footers only — every
    // id an unscoped entry (`.section == None`) broadcasts to, since docx/odt never state which
    // section a running head belongs to and it is meant to apply document-wide (see `section`'s own
    // doc comment on `OfficeHeaderFooter`). Only the OWNED ids (never the broadcast references) also
    // become real `children` of that section, since a node can have exactly one tree parent.
    let mut header_ids_by_section: Vec<Vec<u64>> = vec![Vec::new(); section_count];
    let mut footer_ids_by_section: Vec<Vec<u64>> = vec![Vec::new(); section_count];
    let mut header_children_by_section: Vec<Vec<u64>> = vec![Vec::new(); section_count];
    let mut footer_children_by_section: Vec<Vec<u64>> = vec![Vec::new(); section_count];
    let mut footnote_children_by_section: Vec<Vec<u64>> = vec![Vec::new(); section_count];
    // S6-3: unlike a header/footer, `OfficeMasterPage.section` is not optional (a 바탕쪽 always
    // belongs to one section — invariant 78's own doc), so there is no broadcast case here.
    let mut master_page_children_by_section: Vec<Vec<u64>> = vec![Vec::new(); section_count];

    for hf in &result.headers {
        let owner = resolve_owner_section(hf.section, section_count)?;
        let node_id = ctx.build_header_footer_node(hf, true, section_ids[owner])?;
        match hf.section {
            Some(_) => header_ids_by_section[owner].push(node_id),
            None => {
                for ids in header_ids_by_section.iter_mut() {
                    ids.push(node_id);
                }
            }
        }
        header_children_by_section[owner].push(node_id);
    }
    for hf in &result.footers {
        let owner = resolve_owner_section(hf.section, section_count)?;
        let node_id = ctx.build_header_footer_node(hf, false, section_ids[owner])?;
        match hf.section {
            Some(_) => footer_ids_by_section[owner].push(node_id),
            None => {
                for ids in footer_ids_by_section.iter_mut() {
                    ids.push(node_id);
                }
            }
        }
        footer_children_by_section[owner].push(node_id);
    }
    for footnote in &result.footnotes {
        let owner = resolve_owner_section(footnote.section, section_count)?;
        let node_id = ctx.build_footnote_node(footnote, section_ids[owner])?;
        footnote_children_by_section[owner].push(node_id);
    }
    for page in &result.master_pages {
        let owner = resolve_owner_section(Some(page.section), section_count)?;
        let node_id = ctx.build_master_page_node(page, section_ids[owner])?;
        master_page_children_by_section[owner].push(node_id);
    }

    // Where each declared section's body begins in `result.blocks`; a single synthetic section
    // (no source declaration) owns the whole array, exactly as before this section carried
    // headers/footers/footnotes too.
    let starts = if result.sections.is_empty() { vec![0] } else { section_starts(result) };

    let mut anchored_objects_placed = 0usize;
    for idx in 0..section_count {
        let decl = result.sections.get(idx);
        let start = starts.get(idx).copied().unwrap_or(0).min(result.blocks.len());
        let end = starts
            .get(idx + 1)
            .copied()
            .unwrap_or(result.blocks.len())
            .max(start)
            .min(result.blocks.len());
        let slice = &result.blocks[start..end];

        let section_id = section_ids[idx];
        let flow_id = ctx.new_node_id();
        let flow_children = ctx.map_blocks(slice, Some(start), flow_id)?;
        ctx.nodes.push(wire::Node {
            id: flow_id,
            parent_id: Some(section_id),
            children: flow_children,
            source_spans: vec![],
            edit: None,
            payload: wire::NodePayload::Flow(wire::Empty {}),
        });

        // Owned by whichever section's `start..end` its `block_index` falls in — the carrier
        // paragraph mapping.rs left at that index is already one of this section's OWN blocks
        // (just mapped, above), so `block_node_id` already has it. Built here rather than in the
        // header/footer/footnote pre-pass because that pass runs BEFORE any block has a node id.
        let mut anchored_ids = Vec::new();
        for obj in &result.anchored_objects {
            let block_index = obj.block_index as usize;
            if obj.block_index >= 0 && block_index >= start && block_index < end {
                anchored_ids.push(ctx.build_anchored_object_node(obj, section_id)?);
                anchored_objects_placed += 1;
            }
        }

        let mut children = Vec::with_capacity(
            1 + header_children_by_section[idx].len()
                + footer_children_by_section[idx].len()
                + footnote_children_by_section[idx].len()
                + master_page_children_by_section[idx].len()
                + anchored_ids.len(),
        );
        children.push(flow_id);
        children.extend(header_children_by_section[idx].iter().copied());
        children.extend(footer_children_by_section[idx].iter().copied());
        children.extend(footnote_children_by_section[idx].iter().copied());
        children.extend(master_page_children_by_section[idx].iter().copied());
        children.extend(anchored_ids);

        let mut header_ids = std::mem::take(&mut header_ids_by_section[idx]);
        header_ids.sort_unstable();
        header_ids.dedup();
        let mut footer_ids = std::mem::take(&mut footer_ids_by_section[idx]);
        footer_ids.sort_unstable();
        footer_ids.dedup();

        let declared = decl.and_then(|d| d.paper);
        let paper = declared
            .or_else(|| result_page_geometry(result))
            .map(|geo| build_paper(&geo, result));
        let page_numbering = wire::PageNumbering {
            start: decl.and_then(|d| d.page_number_start),
            hidden: false,
        };
        // EFFECTIVE, not declared: a section that named neither is laid out on the document's, and
        // the two flags beside them are what keep `project` from reporting the inherited value as a
        // declaration the source never made (invariant 108).
        let declared_line_grid = decl.and_then(|d| d.line_grid_pitch);
        let line_grid_points = declared_line_grid.or(result.line_grid_pitch);
        let columns = column_flow_for_layout(first_declared_column_layout(slice))?.map(|flow| {
            wire::SectionColumns { count: flow.count, widths: flow.widths, gaps: flow.gaps }
        });
        let footnote_separator =
            decl.and_then(|d| d.footnote_separator.as_ref()).map(convert_footnote_separator);
        let page_border = decl.and_then(|d| d.page_border.as_ref()).map(convert_page_border);
        let hides_header = decl.is_some_and(|d| d.hides_header);
        let hides_footer = decl.is_some_and(|d| d.hides_footer);
        let hides_master_page = decl.is_some_and(|d| d.hides_master_page);
        let is_vertical = decl.is_some_and(|d| d.is_vertical);
        let section_payload = wire::NodePayload::Section(wire::Section {
            paper,
            paper_is_declared: declared.is_some(),
            line_grid_is_declared: declared_line_grid.is_some(),
            columns,
            header_ids,
            footer_ids,
            page_numbering,
            line_grid_points,
            footnote_separator,
            page_border,
            hides_header,
            hides_footer,
            hides_master_page,
            is_vertical,
        });
        ctx.nodes.push(wire::Node {
            id: section_id,
            parent_id: Some(root_id),
            children,
            source_spans: vec![],
            edit: None,
            payload: section_payload,
        });
    }
    // Section ranges tile `0..result.blocks.len()` exactly (`starts` is built from that same
    // array), so the only way an `OfficeAnchoredObject` never matched any section's range above
    // is a `block_index` outside it — negative or past the end. Refused by name rather than
    // silently dropping the object the loop above never reached.
    if anchored_objects_placed != result.anchored_objects.len() {
        let missing = result
            .anchored_objects
            .iter()
            .find(|obj| obj.block_index < 0 || obj.block_index as usize >= result.blocks.len())
            .map(|obj| obj.block_index)
            .unwrap_or(-1);
        return Err(OfficeAdapterError::AnchoredObjectTargetMissing(missing));
    }

    ctx.nodes.push(wire::Node {
        id: root_id,
        parent_id: None,
        children: section_ids,
        source_spans: vec![],
        edit: None,
        payload: wire::NodePayload::Document(wire::Empty {}),
    });

    let document = wire::Document {
        format: input.format,
        editable: false,
        root_node_id: root_id,
        source_ids: vec![],
        default_locale: None,
        declared_faces: result
            .declared_faces
            .iter()
            .map(|(name, face)| (name.to_string(), face.clone()))
            .collect(),
        default_body_font_size: result.default_body_font_size,
        declared_section_count: result.sections.len() as u32,
        document_paper: result_page_geometry(result).map(|geo| build_paper(&geo, result)),
        line_grid_points: result.line_grid_pitch,
    };
    let mut builder = RenderTreeBuilder::new("fastdoc-office-adapter", document);

    let source_sha256 = format!("{:x}", Sha256::digest(input.source_bytes));
    builder.add_source(wire::SourceDescriptor {
        id: 1,
        kind: wire::SourceKind::OriginalFile,
        name: input.source_name.to_string(),
        encoding: None,
        revision: "1".to_string(),
        sha256: source_sha256,
        byte_length: Some(input.source_bytes.len() as u64),
        utf8_length: None,
        utf16_length: None,
        editable: false,
        text_content: None,
    });
    for node in ctx.nodes {
        builder.add_node(node);
    }
    for resource in ctx.resources {
        builder.add_resource(resource);
    }
    for comment in ctx.comments {
        builder.add_comment(comment);
    }
    for bookmark in ctx.bookmarks {
        builder.add_bookmark(bookmark);
    }

    builder.build().map_err(OfficeAdapterError::Canonicalization)
}

/// Resolves an `OfficeHeaderFooter`/`OfficeFootnote`'s declared `section` to the index of the
/// section that owns it in the tree (its real `parent_id`). `None` (docx/odt never say) falls
/// back to section 0 — the header/footer additionally broadcasts its id into every OTHER
/// section's `header_ids`/`footer_ids` at the call site, since it applies document-wide; a
/// footnote has no such broadcast (it needs exactly one home). `Some(idx)` naming a section the
/// document does not have is a typed error, never silently clamped to section 0.
fn resolve_owner_section(
    section: Option<i64>,
    section_count: usize,
) -> Result<usize, OfficeAdapterError> {
    match section {
        None => Ok(0),
        Some(idx) => {
            if idx < 0 || idx as usize >= section_count {
                return Err(OfficeAdapterError::SectionIndexMissing(idx));
            }
            Ok(idx as usize)
        }
    }
}

/// Where each declared section begins in `result.blocks`. Falls back to "one section owns
/// everything, the rest own nothing" only when the source's own `section_start_blocks` cannot be
/// trusted to align with `sections` (a length mismatch) — this never invents a mid-document split
/// the source did not state.
fn section_starts(result: &OfficeReadResult) -> Vec<usize> {
    let n = result.sections.len();
    if result.section_start_blocks.len() == n {
        result
            .section_start_blocks
            .iter()
            .map(|&i| i.max(0) as usize)
            .collect()
    } else {
        let mut starts = vec![0usize];
        starts.extend(std::iter::repeat_n(result.blocks.len(), n.saturating_sub(1)));
        starts
    }
}

/// The document's page geometry as stated at the TOP level of the read result, used when a section
/// declares no paper of its own — including the synthetic section built for a document that states
/// no sections at all. Without this a document whose size lives only here canonicalizes with no
/// paper, which is not "the document said nothing" but a fact silently dropped.
///
/// All six are required together: a paper width is `left + content + right`, so a partial set
/// cannot produce an honest sheet and stays `None`.
fn result_page_geometry(result: &OfficeReadResult) -> Option<PaperGeometry> {
    Some(PaperGeometry {
        content_width: result.page_content_width?,
        content_height: result.page_content_height?,
        margin_left: result.page_margin_left?,
        margin_right: result.page_margin_right?,
        margin_top: result.page_margin_top?,
        margin_bottom: result.page_margin_bottom?,
    })
}

fn build_paper(geo: &PaperGeometry, result: &OfficeReadResult) -> wire::Paper {
    wire::Paper {
        width_points: geo.paper_width(),
        height_points: geo.paper_height(),
        margins: wire::Insets {
            top: geo.margin_top,
            right: geo.margin_right,
            bottom: geo.margin_bottom,
            left: geo.margin_left,
        },
        header_distance_points: result.page_header_distance,
        footer_distance_points: result.page_footer_distance,
    }
}

/// Mutable build state: the id counters, the flat node/resource lists this adapter appends to in
/// any order (a `RenderTreeBuilder` sorts them by id before validation), and the per-block
/// pagination lookups re-keyed once from `OfficeReadResult`'s four parallel index lists.
struct Ctx<'a> {
    resources_input: &'a BTreeMap<String, ResolvedOfficeResource>,
    /// The size a run that declares none actually renders at (`OfficeReadResult`'s own default).
    default_body_font_size: f64,
    /// The reader's OWN decoded bytes, keyed the same way a block references them. HWP pre-decodes
    /// its pictures while its parser handle is alive, so for that format the bytes are here and
    /// nowhere else; the zip readers return identifiers instead and their bytes arrive through
    /// `resources_input`. Consulting only the caller's map would make an HWP picture unresolvable
    /// unless the caller copied it across first.
    reader_images: &'a std::collections::HashMap<SwiftString, swiftshim::Data>,
    /// `OfficeReadResult.pictures_declared_without_bytes` — `.image(id:)` keys the reader itself
    /// established have NO bytes anywhere, ever (not "not yet resolved" — genuinely absent: an
    /// empty binary-item reference, an external link). Consulted only when a key is in neither
    /// `reader_images` nor `resources_input`: that ordering means an actual resource always wins
    /// over this fact if one somehow exists under the same key, and a key naming NEITHER map nor
    /// this set is still the caller-error `MissingResource` this adapter always raised — this set
    /// only ever WEAKENS a would-be error into an intentionally empty `Image` node, never the
    /// reverse. See `wire::Image.resource_id`'s own doc for what the node looks like.
    pictures_declared_without_bytes: &'a std::collections::HashSet<SwiftString>,
    /// `OfficeReadResult.vector_graphics` — inline vector drawings keyed the same way a raster
    /// picture is (`OfficeBlock::Image.id`). Consulted BEFORE `reader_images`/`resources_input`
    /// for a given key: the host installs a rasterised fallback of the same drawing into `images`
    /// so an `.image(id:)` node always has something paintable before this adapter runs, but the
    /// vector paths are the document's own fact and the raster is a derived convenience — so a key
    /// present in both resolves to a `Vector` node, never an `Image` one.
    vector_graphics: &'a std::collections::HashMap<SwiftString, VectorGraphic>,
    next_node_id: u64,
    next_resource_id: u64,
    next_comment_id: u64,
    next_bookmark_id: u64,
    nodes: Vec<wire::Node>,
    resources: Vec<wire::Resource>,
    resource_by_key: BTreeMap<String, u64>,
    resource_by_hash: BTreeMap<String, u64>,
    keep_with_next: BTreeSet<i64>,
    page_break: BTreeSet<i64>,
    hide_page_number: BTreeSet<i64>,
    restart: BTreeMap<i64, i64>,
    /// Every wire `Comment`/`Bookmark` this run has built, appended to the builder once the whole
    /// tree is done. Kept here (not pushed straight to a builder) for the same reason `nodes`/
    /// `resources` are: this struct is the sole mutable build state threaded through the walk.
    comments: Vec<wire::Comment>,
    bookmarks: Vec<wire::Bookmark>,
    /// `OfficeComment.id` (the source's own opaque string key) -> the wire comment id this run
    /// assigned it, built ONCE up front (`register_comments`) so every `Span.comment_ids` lookup
    /// resolves against the complete set before any text run is mapped.
    comment_id_by_source: BTreeMap<String, u64>,
    /// A bookmark NAME (`Span.bookmarks` entries are names, not ids — the office model has no
    /// separate bookmark id) -> the wire bookmark id already minted for it, so a name repeated
    /// across more than one span still resolves to one `Bookmark` with one `target_node_id` (its
    /// first occurrence), per the deterministic string->id map this adapter promises everywhere
    /// else (comments, resources).
    bookmark_id_by_name: BTreeMap<String, u64>,
    /// `OfficeReadResult.blocks` index -> the node id `map_single_block`/`map_list_group` gave it,
    /// built as the flow is walked so an `OfficeAnchoredObject.block_index` (S6-2) can be resolved
    /// to the node it travels with without a second pass over the tree. A `ListItem` is recorded
    /// under its OWN index (not its group's `List` id), matching the one-index-per-source-block
    /// contract every other index list here already keeps.
    block_node_id: BTreeMap<i64, u64>,
}

impl<'a> Ctx<'a> {
    fn new(
        result: &'a OfficeReadResult,
        resources_input: &'a BTreeMap<String, ResolvedOfficeResource>,
    ) -> Self {
        Ctx {
            resources_input,
            default_body_font_size: result.default_body_font_size,
            reader_images: &result.images,
            pictures_declared_without_bytes: &result.pictures_declared_without_bytes,
            vector_graphics: &result.vector_graphics,
            next_node_id: 1,
            next_resource_id: 1,
            next_comment_id: 1,
            next_bookmark_id: 1,
            nodes: Vec::new(),
            resources: Vec::new(),
            resource_by_key: BTreeMap::new(),
            resource_by_hash: BTreeMap::new(),
            keep_with_next: result.keep_with_next_blocks.iter().copied().collect(),
            page_break: result.page_break_blocks.iter().copied().collect(),
            hide_page_number: result.hide_page_number_blocks.iter().copied().collect(),
            restart: result
                .page_number_restart_blocks
                .iter()
                .map(|r| (r.block, r.number))
                .collect(),
            comments: Vec::new(),
            bookmarks: Vec::new(),
            comment_id_by_source: BTreeMap::new(),
            bookmark_id_by_name: BTreeMap::new(),
            block_node_id: BTreeMap::new(),
        }
    }

    fn new_node_id(&mut self) -> u64 {
        let id = self.next_node_id;
        self.next_node_id += 1;
        id
    }

    fn new_resource_id(&mut self) -> u64 {
        let id = self.next_resource_id;
        self.next_resource_id += 1;
        id
    }

    fn new_comment_id(&mut self) -> u64 {
        let id = self.next_comment_id;
        self.next_comment_id += 1;
        id
    }

    fn new_bookmark_id(&mut self) -> u64 {
        let id = self.next_bookmark_id;
        self.next_bookmark_id += 1;
        id
    }

    /// Assigns every `OfficeComment` a wire id, in source order (`result.comments`'s own order —
    /// a plain counter, deliberately not a hash, so two distinct source ids can never collide onto
    /// one wire id). Must run before ANY span is mapped: `Span.comment_ids` resolves against this
    /// map, and an id it cannot find is `OfficeAdapterError::UnresolvedCommentId`, not a silent
    /// drop.
    fn register_comments(&mut self, comments: &[OfficeComment]) {
        for comment in comments {
            let id = self.new_comment_id();
            self.comment_id_by_source.insert(comment.id.to_string(), id);
            let author = comment.author.as_ref().map(|s| s.to_string()).unwrap_or_default();
            self.comments.push(wire::Comment {
                id,
                // The document's own identifier, carried rather than kept only in the map above:
                // a reader shows this, not our mint (invariant 108 — writing the mint here would
                // put a number the document never wrote where a fact belongs).
                source_id: comment.id.to_string(),
                author,
                text: comment.text.to_string(),
                date_iso: comment.date_iso.as_ref().map(|s| s.to_string()),
            });
        }
    }

    fn resolve_comment_id(&self, source_id: &str) -> Result<u64, OfficeAdapterError> {
        self.comment_id_by_source
            .get(source_id)
            .copied()
            .ok_or_else(|| OfficeAdapterError::UnresolvedCommentId(source_id.to_string()))
    }

    /// Resolves a bookmark NAME to its wire id, minting one (and recording its `Bookmark` with
    /// `target_node_id` pointing at the text run currently being built) the first time this name
    /// is seen; a later span carrying the same name reuses that id instead of creating a second
    /// bookmark with a different target.
    fn resolve_bookmark(&mut self, name: &str, target_node_id: u64) -> u64 {
        if let Some(&id) = self.bookmark_id_by_name.get(name) {
            return id;
        }
        let id = self.new_bookmark_id();
        self.bookmark_id_by_name.insert(name.to_string(), id);
        self.bookmarks.push(wire::Bookmark { id, name: name.to_string(), target_node_id });
        id
    }

    /// Builds one running header/footer: a `Header`/`Footer` node, parented directly at its
    /// owning section (`parent_id`, already resolved by the caller), owning a `Flow` of its own
    /// mapped blocks — the same shape `map_blocks`'s callers use for a section's own body.
    fn build_header_footer_node(
        &mut self,
        hf: &OfficeHeaderFooter,
        is_header: bool,
        parent_id: u64,
    ) -> Result<u64, OfficeAdapterError> {
        let node_id = self.new_node_id();
        let flow_id = self.new_node_id();
        let flow_children = self.map_blocks(&hf.blocks, None, flow_id)?;
        self.nodes.push(wire::Node {
            id: flow_id,
            parent_id: Some(node_id),
            children: flow_children,
            source_spans: vec![],
            edit: None,
            payload: wire::NodePayload::Flow(wire::Empty {}),
        });
        let band = wire::HeaderFooter {
            applies_to: convert_header_footer_applicability(hf.applies_to),
        };
        let payload = if is_header {
            wire::NodePayload::Header(band)
        } else {
            wire::NodePayload::Footer(band)
        };
        self.nodes.push(wire::Node {
            id: node_id,
            parent_id: Some(parent_id),
            children: vec![flow_id],
            source_spans: vec![],
            edit: None,
            payload,
        });
        Ok(node_id)
    }

    /// Builds one footnote: a `Footnote` node (parented at its owning section, `parent_id`) whose
    /// `body_flow_id` points at a `Flow` — also a real `children` entry of the `Footnote` node
    /// itself, since every node must be reachable via `children`, not `body_flow_id` alone.
    fn build_footnote_node(
        &mut self,
        footnote: &OfficeFootnote,
        parent_id: u64,
    ) -> Result<u64, OfficeAdapterError> {
        if footnote.number < 0 {
            return Err(OfficeAdapterError::NegativeFootnoteNumber(footnote.number));
        }
        let footnote_id = self.new_node_id();
        let flow_id = self.new_node_id();
        let flow_children = self.map_blocks(&footnote.blocks, None, flow_id)?;
        self.nodes.push(wire::Node {
            id: flow_id,
            parent_id: Some(footnote_id),
            children: flow_children,
            source_spans: vec![],
            edit: None,
            payload: wire::NodePayload::Flow(wire::Empty {}),
        });
        self.nodes.push(wire::Node {
            id: footnote_id,
            parent_id: Some(parent_id),
            children: vec![flow_id],
            source_spans: vec![],
            edit: None,
            payload: wire::NodePayload::Footnote(wire::Footnote {
                label: None,
                number: footnote.number as u64,
                body_flow_id: flow_id,
            }),
        });
        Ok(footnote_id)
    }

    fn pagination_for(&self, index: Option<i64>) -> wire::ParagraphPagination {
        match index {
            None => wire::ParagraphPagination::default(),
            Some(i) => wire::ParagraphPagination {
                keep_with_next: self.keep_with_next.contains(&i),
                page_break_before: self.page_break.contains(&i),
                hides_page_number: self.hide_page_number.contains(&i),
                page_number_restart: self.restart.get(&i).copied(),
            },
        }
    }

    /// Resolves an image/graphic resource key to a wire resource id, deduping first by key (the
    /// same key reused twice in one document) and then by content hash (two different keys whose
    /// bytes happen to be identical) — the validator refuses two resources sharing one sha256.
    fn resolve_resource(
        &mut self,
        key: &str,
        intrinsic: Option<wire::Size>,
    ) -> Result<u64, OfficeAdapterError> {
        if let Some(&id) = self.resource_by_key.get(key) {
            return Ok(id);
        }
        let from_caller = self.resources_input.get(key);
        let (bytes, mime): (&[u8], String) = match from_caller {
            Some(resolved) => (&resolved.bytes, resolved.mime_type.clone()),
            None => {
                let data = self
                    .reader_images
                    .get(&SwiftString::from(key.to_string()))
                    .ok_or_else(|| OfficeAdapterError::MissingResource(key.to_string()))?;
                (&data.0, sniff_image_mime(&data.0).to_string())
            }
        };
        let id = self.register_resource_bytes(bytes, mime, intrinsic, Some(key.to_string()));
        self.resource_by_key.insert(key.to_string(), id);
        Ok(id)
    }

    /// The hash-dedup half of `resolve_resource`, pulled out so a resource with no document key
    /// at all — an anchored object's `NSImage`, decoded straight from `OfficeMasterObjectContent`
    /// rather than looked up by an `.image(id:)` string — can still land in the SAME resource
    /// table and get the SAME cross-document dedup an ordinary picture does. `source_key` is
    /// `None` here on purpose: `wire::Resource.source_key`'s own doc says `None` means "a
    /// producer whose document never declared such a key", which is exactly this case, not an
    /// omission to fill in later.
    fn register_resource_bytes(
        &mut self,
        bytes: &[u8],
        mime: String,
        intrinsic: Option<wire::Size>,
        source_key: Option<String>,
    ) -> u64 {
        let hash = format!("{:x}", Sha256::digest(bytes));
        if let Some(&id) = self.resource_by_hash.get(&hash) {
            return id;
        }
        let id = self.new_resource_id();
        use base64::Engine;
        let bytes_base64 = base64::engine::general_purpose::STANDARD.encode(bytes);
        self.resources.push(wire::Resource {
            id,
            mime_type: mime,
            sha256: hash.clone(),
            byte_length: bytes.len() as u64,
            bytes_base64,
            intrinsic_size: intrinsic,
            source_key,
        });
        self.resource_by_hash.insert(hash, id);
        id
    }

    /// S6-4: a table/cell's own PICTURE fill, decoded — registered the same way `map_anchored_content`'s
    /// `Image` arm does, no `source_key` for the identical reason (`register_resource_bytes`'s own
    /// doc: a decoded fill never had a document-declared string id).
    fn background_resource(&mut self, image: &NSImage) -> u64 {
        let bytes: &[u8] = image.data.as_ref().map(|d| d.0.as_slice()).unwrap_or(&[]);
        let intrinsic = wire::Size { width: image.size.width, height: image.size.height };
        let mime = sniff_image_mime(bytes).to_string();
        self.register_resource_bytes(bytes, mime, Some(intrinsic), None)
    }

    /// Maps a run of sibling blocks (a section's flow, or a table cell's contents) into node ids
    /// for the caller to hang under `parent_id`. `base_index`, when `Some`, is this slice's own
    /// offset into `result.blocks` — the only case pagination re-keying applies, since the four
    /// index lists are stated against that top-level array, never against a cell's own blocks.
    fn map_blocks(
        &mut self,
        blocks: &[OfficeBlock],
        base_index: Option<usize>,
        parent_id: u64,
    ) -> Result<Vec<u64>, OfficeAdapterError> {
        let mut children = Vec::with_capacity(blocks.len());
        let mut i = 0usize;
        while i < blocks.len() {
            if matches!(blocks[i], OfficeBlock::ListItem { .. }) {
                let start = i;
                while i < blocks.len() && matches!(blocks[i], OfficeBlock::ListItem { .. }) {
                    i += 1;
                }
                let group = &blocks[start..i];
                let indices: Vec<Option<i64>> = (start..i)
                    .map(|k| base_index.map(|b| (b + k) as i64))
                    .collect();
                let list_id = self.map_list_group(group, &indices, parent_id)?;
                children.push(list_id);
            } else {
                let block_index = base_index.map(|b| (b + i) as i64);
                let id = self.map_single_block(&blocks[i], block_index, parent_id)?;
                children.push(id);
                i += 1;
            }
        }
        Ok(children)
    }

    fn map_spans(
        &mut self,
        spans: &[Span],
        parent_id: u64,
    ) -> Result<Vec<u64>, OfficeAdapterError> {
        let mut ids = Vec::with_capacity(spans.len());
        for span in spans {
            let id = self.new_node_id();
            let mut run = convert_text_run(span);
            run.column_flow = column_flow_for_layout(span.column_layout.as_ref())?;

            let mut bookmark_ids: Vec<u64> =
                span.bookmarks.iter().map(|name| self.resolve_bookmark(name.as_str(), id)).collect();
            bookmark_ids.sort_unstable();
            bookmark_ids.dedup();
            run.bookmark_ids = bookmark_ids;

            let mut comment_ids = Vec::with_capacity(span.comment_ids.len());
            for source_id in &span.comment_ids {
                comment_ids.push(self.resolve_comment_id(source_id.as_str())?);
            }
            comment_ids.sort_unstable();
            comment_ids.dedup();
            run.comment_ids = comment_ids;

            self.nodes.push(wire::Node {
                id,
                parent_id: Some(parent_id),
                children: vec![],
                source_spans: vec![],
                edit: None,
                payload: wire::NodePayload::TextRun(run),
            });
            ids.push(id);
        }
        Ok(ids)
    }

    /// A run of contiguous `OfficeBlock::ListItem`s becomes one synthetic `List` node, since the
    /// validator requires every `ListItem`'s parent to be a `List` (`validate_parent_kind`) but
    /// the office model carries list items flat, distinguished only by `level`. The group's own
    /// `Numbering` is taken from its first item — `wire::List` carries exactly one, and per-item
    /// numbering (when items disagree) does not survive this fold; each `ListItem`'s own
    /// `numbering`/`marker`/`ordered` fields are still carried individually.
    fn map_list_group(
        &mut self,
        items: &[OfficeBlock],
        indices: &[Option<i64>],
        parent_id: u64,
    ) -> Result<u64, OfficeAdapterError> {
        let list_id = self.new_node_id();
        let mut item_ids = Vec::with_capacity(items.len());
        let mut first_numbering: Option<office_block::ListNumbering> = None;

        for (item, idx) in items.iter().zip(indices.iter()) {
            let OfficeBlock::ListItem {
                level,
                ordered,
                spans,
                marker,
                rtl,
                alignment,
                tab_stops,
                format,
                numbering,
            } = item
            else {
                unreachable!("map_list_group is only called with ListItem blocks")
            };
            if first_numbering.is_none() {
                first_numbering = *numbering;
            }
            let item_id = self.new_node_id();
            let run_ids = self.map_spans(spans, item_id)?;
            let wire_numbering = numbering.as_ref().map(|n| wire::Numbering {
                glyphs: convert_glyphs(n.glyphs),
                start_number: n.start_number,
            });
            let payload = wire::NodePayload::ListItem(wire::ListItem {
                level: ((*level + 1).clamp(1, 32)) as u32,
                ordered: *ordered,
                marker: marker.as_ref().map(|m| m.to_string()),
                numbering: wire_numbering,
                style: paragraph_style(format, *alignment, *rtl),
                tab_stops: sanitize_tab_stops(tab_stops),
                pagination: self.pagination_for(*idx),
            });
            self.nodes.push(wire::Node {
                id: item_id,
                parent_id: Some(list_id),
                children: run_ids,
                source_spans: vec![],
                edit: None,
                payload,
            });
            if let Some(index) = idx {
                self.block_node_id.insert(*index, item_id);
            }
            item_ids.push(item_id);
        }

        let glyphs = first_numbering
            .as_ref()
            .map(|n| convert_glyphs(n.glyphs))
            .unwrap_or(wire::ListNumberingGlyphs::Decimal);
        let start_number = first_numbering.as_ref().and_then(|n| n.start_number);
        self.nodes.push(wire::Node {
            id: list_id,
            parent_id: Some(parent_id),
            children: item_ids,
            source_spans: vec![],
            edit: None,
            payload: wire::NodePayload::List(wire::List {
                numbering: wire::Numbering { glyphs, start_number },
            }),
        });
        Ok(list_id)
    }

    fn map_single_block(
        &mut self,
        block: &OfficeBlock,
        block_index: Option<i64>,
        parent_id: u64,
    ) -> Result<u64, OfficeAdapterError> {
        let node_id = self.new_node_id();
        let (children, payload) = match block {
            OfficeBlock::Heading { level, spans, rtl, alignment, tab_stops, format } => {
                let runs = self.map_spans(spans, node_id)?;
                let payload = wire::NodePayload::Heading(wire::Heading {
                    level: *level,
                    style: paragraph_style(format, *alignment, *rtl),
                    tab_stops: sanitize_tab_stops(tab_stops),
                    pagination: self.pagination_for(block_index),
                });
                (runs, payload)
            }
            OfficeBlock::Paragraph { spans, rtl, alignment, tab_stops, format } => {
                let runs = self.map_spans(spans, node_id)?;
                let payload = wire::NodePayload::Paragraph(wire::Paragraph {
                    style: paragraph_style(format, *alignment, *rtl),
                    tab_stops: sanitize_tab_stops(tab_stops),
                    pagination: self.pagination_for(block_index),
                });
                (runs, payload)
            }
            OfficeBlock::ListItem { .. } => {
                unreachable!("ListItem blocks are grouped by map_blocks before reaching here")
            }
            OfficeBlock::Table { rows, header_rows, column_widths, format } => {
                self.map_table(rows, *header_rows, column_widths, format, node_id)?
            }
            OfficeBlock::Image { id, size, alignment } => {
                (vec![], self.map_image_or_vector(id, *size, *alignment)?)
            }
            OfficeBlock::UnsupportedGraphic { label, size, alignment } => {
                let reason = if label.as_str().is_empty() {
                    "unsupported graphic".to_string()
                } else {
                    label.to_string()
                };
                let payload = wire::NodePayload::Unsupported(wire::Unsupported {
                    source_format_tag: "officeGraphic".to_string(),
                    reason,
                    preserved_text: None,
                    resource_ids: vec![],
                    intrinsic_size: wire::Size { width: size.width, height: size.height },
                    alignment: alignment.map(convert_alignment).unwrap_or(wire::Alignment::Natural),
                });
                (vec![], payload)
            }
            OfficeBlock::Formula { latex } => {
                let payload = wire::NodePayload::Formula(wire::Formula {
                    source: latex.to_string(),
                    display: true,
                    alignment: wire::Alignment::Natural,
                });
                (vec![], payload)
            }
        };
        self.nodes.push(wire::Node {
            id: node_id,
            parent_id: Some(parent_id),
            children,
            source_spans: vec![],
            edit: None,
            payload,
        });
        if let Some(index) = block_index {
            self.block_node_id.insert(index, node_id);
        }
        Ok(node_id)
    }

    /// An `OfficeBlock::Image`'s key resolves to a `Vector` node when `vector_graphics` names it,
    /// and to a raster `Image` node otherwise — see the `vector_graphics` field's own doc for why
    /// the vector always wins when a key names both. A key naming neither is `MissingResource`,
    /// same as the pure-raster path always was.
    fn map_image_or_vector(
        &mut self,
        id_key: &SwiftString,
        size: CGSize,
        alignment: Option<NSTextAlignment>,
    ) -> Result<wire::NodePayload, OfficeAdapterError> {
        if let Some(graphic) = self.vector_graphics.get(id_key).cloned() {
            return Ok(self.map_vector(&graphic, id_key, alignment));
        }
        self.map_image(id_key, size, alignment)
    }

    fn map_image(
        &mut self,
        id_key: &SwiftString,
        size: CGSize,
        alignment: Option<NSTextAlignment>,
    ) -> Result<wire::NodePayload, OfficeAdapterError> {
        let intrinsic = wire::Size {
            width: size.width,
            height: size.height,
        };
        // A key already resolvable through the ordinary paths (this run's own dedup cache, the
        // reader's decoded bytes, or the caller's resource map) always wins — this set only ever
        // stands in for an id that resolves NOWHERE else, matching `resolve_resource`'s own
        // caller-map-then-reader-images order.
        let resource_id = if !self.resource_by_key.contains_key(id_key.as_str())
            && !self.resources_input.contains_key(id_key.as_str())
            && !self.reader_images.contains_key(id_key)
            && self.pictures_declared_without_bytes.contains(id_key)
        {
            None
        } else {
            Some(self.resolve_resource(id_key.as_str(), Some(intrinsic.clone()))?)
        };
        Ok(wire::NodePayload::Image(wire::Image {
            resource_id,
            intrinsic_size: intrinsic,
            display_size: None,
            // Office formats have no percent-of-column width declaration; only markdown's `%`
            // syntax sets this.
            display_width_fraction: None,
            alignment: alignment.map(convert_alignment).unwrap_or(wire::Alignment::Natural),
            alt_text: None,
            // Set unconditionally — a `Resource`-backed image and a declared-without-bytes one
            // (`resource_id: None` above) round-trip through the identical field; see
            // `wire::Image.source_key`'s own doc.
            source_key: Some(id_key.as_str().to_string()),
        }))
    }

    /// A `VectorGraphic`'s own `size` is its intrinsic size (never the block's `size`, which on
    /// this path is the layout box the host already reserved — the drawing's own dimensions are
    /// the document fact `wire::Vector.intrinsic_size` means to carry). `resource_id` stays `None`:
    /// there is no separate raster resource to point at here, and the validator only requires one
    /// when `Some`.
    fn map_vector(
        &mut self,
        graphic: &VectorGraphic,
        id_key: &SwiftString,
        alignment: Option<NSTextAlignment>,
    ) -> wire::NodePayload {
        let intrinsic = wire::Size {
            width: graphic.size.width,
            height: graphic.size.height,
        };
        let paths = graphic.paths.iter().map(convert_vector_path).collect();
        wire::NodePayload::Vector(wire::Vector {
            resource_id: None,
            paths,
            intrinsic_size: intrinsic,
            display_size: None,
            alignment: alignment.map(convert_alignment).unwrap_or(wire::Alignment::Natural),
            source_key: Some(id_key.as_str().to_string()),
        })
    }

    /// The content half of an `OfficeMasterObject` — an `Image`/`Vector`/`Flow` node built the
    /// SAME way an in-flow one is (`map_image`/`map_vector`/the ordinary block walk), never a new
    /// vocabulary. `content_id`'s own doc says why: the anchor semantics are what S6-2 adds, not
    /// the content shapes.
    ///
    /// Unlike `map_image`/`map_vector` above, there is no document-declared string key here —
    /// `OfficeMasterObjectContent::Image` carries decoded pixels directly (`swiftshim::NSImage`),
    /// not an `.image(id:)` reference — so this registers the bytes straight into the resource
    /// table (`register_resource_bytes`) rather than resolving one.
    fn map_anchored_content(
        &mut self,
        content: &office_block::OfficeMasterObjectContent,
        parent_id: u64,
    ) -> Result<u64, OfficeAdapterError> {
        let node_id = self.new_node_id();
        let (children, payload) = match content {
            office_block::OfficeMasterObjectContent::Image(image) => {
                let bytes: &[u8] = image.data.as_ref().map(|d| d.0.as_slice()).unwrap_or(&[]);
                let intrinsic = wire::Size { width: image.size.width, height: image.size.height };
                let mime = sniff_image_mime(bytes).to_string();
                let resource_id =
                    self.register_resource_bytes(bytes, mime, Some(intrinsic.clone()), None);
                (
                    vec![],
                    wire::NodePayload::Image(wire::Image {
                        resource_id: Some(resource_id),
                        intrinsic_size: intrinsic,
                        display_size: None,
                        display_width_fraction: None,
                        alignment: wire::Alignment::Natural,
                        alt_text: None,
                        // No document-declared key: these are host-painted bytes registered
                        // straight into the resource table, same as `Vector`'s `source_key: None`
                        // immediately below for the identical reason.
                        source_key: None,
                    }),
                )
            }
            // A pre-rendered drawing (raw PDF bytes) is not structured paths, so it is carried as a
            // picture — the same treatment the host already gives a rasterised vector fallback.
            //
            // THIS ARM IS UNREACHABLE FROM THIS CRATE'S OWN READER, and not by accident. Rasterising
            // paths needs a graphics stack, which is the host's, so the Swift reader renders them at
            // read time (`HwpReader.swift:639` -> `HwpShapeRenderer.pdf`) and stores `.drawing(pdf)`,
            // while this crate keeps the vector description and stores `Vector`. Measured, after
            // S6-3 made master pages reachable: the 편람 fixture's 11 master pages carry 65 objects,
            // every one of them `Image`/`Vector`/`Text` and NOT ONE `Drawing`. An earlier version of
            // this comment predicted S6-3 would be the day this arm ran; it was wrong, and the
            // measurement is recorded here so the prediction is not made a third time.
            //
            // It stays because the variant is the SHARED vocabulary both readers speak (the schema-v4
            // decode has a "Drawing" case, `OfficeEnvelopeDecoding.swift:201`), not because anything
            // here produces one. Do NOT count it as a covered branch — nothing can exercise it from
            // this side, so a test that claims to is passing on a path it never took (invariant 103).
            //
            // The consequence belongs to S6-6: a host reading the TREE gets `vector` where its own
            // reader would have produced `.drawing(pdf)`, so it has to rasterise at consume time. The
            // two also disagree about what survives — the Swift reader DROPS a drawing whose frame is
            // under half a point or whose render fails, and this one keeps the vector regardless.
            office_block::OfficeMasterObjectContent::Drawing(data) => {
                let mime = sniff_image_mime(&data.0).to_string();
                let intrinsic = wire::Size { width: 0.0, height: 0.0 };
                let resource_id =
                    self.register_resource_bytes(&data.0, mime, Some(intrinsic.clone()), None);
                (
                    vec![],
                    wire::NodePayload::Image(wire::Image {
                        resource_id: Some(resource_id),
                        intrinsic_size: intrinsic,
                        display_size: None,
                        display_width_fraction: None,
                        alignment: wire::Alignment::Natural,
                        alt_text: None,
                        source_key: None,
                    }),
                )
            }
            office_block::OfficeMasterObjectContent::Vector(graphic) => {
                let paths = graphic.paths.iter().map(convert_vector_path).collect();
                (
                    vec![],
                    wire::NodePayload::Vector(wire::Vector {
                        resource_id: None,
                        paths,
                        intrinsic_size: wire::Size { width: graphic.size.width, height: graphic.size.height },
                        display_size: None,
                        alignment: wire::Alignment::Natural,
                        source_key: None,
                    }),
                )
            }
            // Rhwp emits a text box's words as ordinary sibling blocks (`Text`'s own doc), so
            // this is the SAME `Flow` shape a footnote body already is — `map_blocks` unchanged,
            // no `base_index` because these blocks are not part of the document's own pagination
            // index space (`keep_with_next`/`page_break`/... are stated against `OfficeReadResult
            // .blocks`, never against text nested inside an anchored object).
            office_block::OfficeMasterObjectContent::Text(blocks) => {
                let children = self.map_blocks(blocks, None, node_id)?;
                (children, wire::NodePayload::Flow(wire::Empty {}))
            }
        };
        self.nodes.push(wire::Node {
            id: node_id,
            parent_id: Some(parent_id),
            children,
            source_spans: vec![],
            edit: None,
            payload,
        });
        Ok(node_id)
    }

    /// One `OfficeAnchoredObject` as a node: the anchor semantics (frame, which reference the
    /// frame is measured against, the paragraph rule when `y` is not yet knowable) plus a child
    /// node for its content. `parent_id` is the owning SECTION — the same level a header/footer/
    /// footnote attaches at, since an anchored object is not part of any one flow's ordinary
    /// sibling order.
    fn build_anchored_object_node(
        &mut self,
        obj: &office_block::OfficeAnchoredObject,
        parent_id: u64,
    ) -> Result<u64, OfficeAdapterError> {
        let anchored_to_id = *self
            .block_node_id
            .get(&obj.block_index)
            .ok_or(OfficeAdapterError::AnchoredObjectTargetMissing(obj.block_index))?;
        let node_id = self.new_node_id();
        let content_id = self.map_anchored_content(&obj.object.content, node_id)?;
        // `y` is final only when there is no paragraph rule to complete it later — see
        // `wire::AnchoredObject`'s own doc for why the two are mutually exclusive rather than
        // "y, corrected afterward": a placeholder number surviving into the tree is exactly the
        // guessed value invariant 31/81 both reject.
        let (y, paragraph_anchor) = match &obj.paragraph_anchor {
            Some(anchor) => (
                None,
                Some(wire::ParagraphAnchor {
                    align: convert_paragraph_anchor_align(anchor.align),
                    offset: anchor.offset,
                }),
            ),
            None => (Some(obj.object.frame.origin.y), None),
        };
        self.nodes.push(wire::Node {
            id: node_id,
            parent_id: Some(parent_id),
            children: vec![content_id],
            source_spans: vec![],
            edit: None,
            payload: wire::NodePayload::AnchoredObject(wire::AnchoredObject {
                x: obj.object.frame.origin.x,
                width: obj.object.frame.size.width,
                height: obj.object.frame.size.height,
                y,
                paragraph_anchor,
                anchored_to_id,
                content_id,
            }),
        });
        Ok(node_id)
    }

    /// One `OfficeMasterObject` as a node: `map_anchored_content` builds the SAME content vocabulary
    /// (Image/Drawing/Vector/Text) an anchored object already uses — S6-3 adds no new content kind,
    /// only the frame wrapper (`MasterPageObject`, never `AnchoredObject`: there is no block this
    /// travels with and no paragraph rule, invariant 78's own "there is no anchor to resolve").
    fn build_master_page_object_node(
        &mut self,
        obj: &office_block::OfficeMasterObject,
        parent_id: u64,
    ) -> Result<u64, OfficeAdapterError> {
        let node_id = self.new_node_id();
        let content_id = self.map_anchored_content(&obj.content, node_id)?;
        self.nodes.push(wire::Node {
            id: node_id,
            parent_id: Some(parent_id),
            children: vec![content_id],
            source_spans: vec![],
            edit: None,
            payload: wire::NodePayload::MasterPageObject(wire::MasterPageObject {
                x: obj.frame.origin.x,
                width: obj.frame.size.width,
                height: obj.frame.size.height,
                y: obj.frame.origin.y,
                content_id,
            }),
        });
        Ok(node_id)
    }

    /// One 바탕쪽 as a node, parented at its owning section (`parent_id`) the same level a header/
    /// footer/footnote/anchored object attaches at — never which PAGE it paints on (draw-time,
    /// `MasterPagePainter`/S5C-3's job, not this tree's — see `wire::MasterPage`'s own doc).
    fn build_master_page_node(
        &mut self,
        page: &office_block::OfficeMasterPage,
        parent_id: u64,
    ) -> Result<u64, OfficeAdapterError> {
        let node_id = self.new_node_id();
        let object_ids = page
            .objects
            .iter()
            .map(|obj| self.build_master_page_object_node(obj, node_id))
            .collect::<Result<Vec<u64>, _>>()?;
        self.nodes.push(wire::Node {
            id: node_id,
            parent_id: Some(parent_id),
            children: object_ids.clone(),
            source_spans: vec![],
            edit: None,
            payload: wire::NodePayload::MasterPage(wire::MasterPage {
                applies_to: convert_header_footer_applicability(page.applies_to),
                object_ids,
            }),
        });
        Ok(node_id)
    }

    /// Builds a `Table` node's row/cell subtree, and returns the `TableRow` child ids alongside
    /// the `Table` payload for the caller to attach to `table_id`.
    ///
    /// The office model only carries ANCHOR cells per row (`OfficeBlock::Table`'s own doc: a
    /// covered position is simply absent), so this derives column indices itself with the same
    /// left-to-right, skip-what-is-occupied algorithm `TableBlockBuilder` uses at render time —
    /// then pads any grid coordinate still uncovered once a row is done with an empty 1x1 filler
    /// cell, which is the only way to satisfy `validate_table`'s full-coverage requirement for a
    /// source table whose declared spans do not already tile the grid exactly.
    fn map_table(
        &mut self,
        rows: &[Vec<Cell>],
        header_rows: i64,
        column_widths: &[f64],
        format: &TableFormat,
        table_id: u64,
    ) -> Result<(Vec<u64>, wire::NodePayload), OfficeAdapterError> {
        // Pass 1: natural anchor placement, purely to learn the grid's true column count.
        let mut occupied: BTreeSet<(usize, usize)> = BTreeSet::new();
        let mut natural: Vec<Vec<(usize, usize, usize)>> = Vec::with_capacity(rows.len());
        for (r, row_cells) in rows.iter().enumerate() {
            let mut col = 0usize;
            let mut placements = Vec::with_capacity(row_cells.len());
            for cell in row_cells {
                while occupied.contains(&(r, col)) {
                    col += 1;
                }
                let row_span = (cell.row_span.max(1) as usize).min(rows.len() - r);
                let col_span = cell.col_span.max(1) as usize;
                for rr in r..r + row_span {
                    for cc in col..col + col_span {
                        occupied.insert((rr, cc));
                    }
                }
                placements.push((col, row_span, col_span));
                col += col_span;
            }
            natural.push(placements);
        }
        let total_cols = occupied.iter().map(|&(_, c)| c + 1).max().unwrap_or(1);

        // Pass 2: build the real nodes, padding every row's uncovered coordinates as we finish it.
        let mut occupied2: BTreeSet<(usize, usize)> = BTreeSet::new();
        let mut row_ids = Vec::with_capacity(rows.len());
        for (r, row_cells) in rows.iter().enumerate() {
            let row_id = self.new_node_id();
            let mut entries: Vec<(usize, Option<&Cell>, usize, usize)> =
                Vec::with_capacity(row_cells.len());
            for (cell, &(col, row_span, col_span)) in row_cells.iter().zip(natural[r].iter()) {
                for rr in r..r + row_span {
                    for cc in col..col + col_span {
                        occupied2.insert((rr, cc));
                    }
                }
                entries.push((col, Some(cell), row_span, col_span));
            }
            for c in 0..total_cols {
                if !occupied2.contains(&(r, c)) {
                    occupied2.insert((r, c));
                    entries.push((c, None, 1, 1));
                }
            }
            entries.sort_by_key(|e| e.0);

            let mut cell_ids = Vec::with_capacity(entries.len());
            for (col, cell_opt, row_span, col_span) in entries {
                let cell_id = self.new_node_id();
                let (cell_children, cell_payload) = if let Some(cell) = cell_opt {
                    let cell_children = self.map_blocks(&cell.blocks, None, cell_id)?;
                    let mut cell_payload =
                        convert_cell(cell, r as u32, col as u32, row_span as u32, col_span as u32);
                    // S6-4: `cell.background_image` alone cannot be trusted here — it is
                    // `mapping.rs`'s MERGED field (a real picture OR the synthesized gradient
                    // bitmap, `fill_image(...).or_else(gradient_image(...))`). Only
                    // `cell.background_gradient` being `None` proves the real picture won; when it
                    // is `Some`, `background_image` (if set at all) is that synthetic bitmap and
                    // must never become a resource — carrying it would fabricate a document
                    // picture out of a rendering convenience.
                    cell_payload.background_resource_id = if cell.background_gradient.is_none() {
                        cell.background_image.as_ref().map(|img| self.background_resource(img))
                    } else {
                        None
                    };
                    cell_payload.background_gradient =
                        cell.background_gradient.as_ref().map(convert_gradient);
                    (cell_children, cell_payload)
                } else {
                    (vec![], empty_filler_cell(r as u32, col as u32))
                };
                self.nodes.push(wire::Node {
                    id: cell_id,
                    parent_id: Some(row_id),
                    children: cell_children,
                    source_spans: vec![],
                    edit: None,
                    payload: wire::NodePayload::TableCell(cell_payload),
                });
                cell_ids.push(cell_id);
            }

            self.nodes.push(wire::Node {
                id: row_id,
                parent_id: Some(table_id),
                children: cell_ids,
                source_spans: vec![],
                edit: None,
                payload: wire::NodePayload::TableRow(wire::TableRow {
                    row: r as u32,
                    header: (r as i64) < header_rows.max(0),
                    cant_split: false,
                    height: None,
                }),
            });
            row_ids.push(row_id);
        }

        let grid_widths = if !column_widths.is_empty() && column_widths.len() == total_cols {
            column_widths.to_vec()
        } else {
            vec![0.0; total_cols]
        };
        let source_column_widths =
            if !column_widths.is_empty() && column_widths.len() == grid_widths.len() {
                grid_widths.clone()
            } else {
                vec![]
            };
        // S6-4: same disambiguation as the per-cell case above — `format.background_image` is
        // `mapping.rs`'s merged field (real picture OR synthetic gradient bitmap); only when
        // `format.background_gradient` is `None` does it prove a real picture won.
        let background_resource_id = if format.background_gradient.is_none() {
            format.background_image.as_ref().map(|img| self.background_resource(img))
        } else {
            None
        };
        let background_gradient = format.background_gradient.as_ref().map(convert_gradient);
        let style = wire::TableStyle {
            default_uniform_border: uniform_border(format.default_border_color, format.default_border_width),
            default_shading: format.default_shading.map(convert_color),
            edge_borders: format.edge_borders.as_ref().map(convert_edge_borders),
            default_padding: format.default_padding.as_ref().map(insets_nonneg),
            source_width_points: format.source_width,
            repeat_header_rows: format.repeat_header_rows,
            page_break_policy: format.page_break_policy.map(convert_page_break_policy),
            outer_margin: format.outer_margin.as_ref().map(insets_finite),
            background_resource_id,
            background_gradient,
        };
        let table_payload = wire::NodePayload::Table(wire::Table {
            grid_widths,
            alignment: wire::Alignment::Natural,
            preferred_width: format.source_width,
            header_rows: (header_rows.max(0) as u32).min(rows.len() as u32),
            source_column_widths,
            style,
        });
        Ok((row_ids, table_payload))
    }
}

fn empty_filler_cell(row: u32, column: u32) -> wire::TableCell {
    wire::TableCell {
        row,
        column,
        row_span: 1,
        column_span: 1,
        direct_shading: None,
        direct_uniform_border: None,
        direct_edge_borders: None,
        declared_width_points: None,
        vertical_alignment: None,
        uniform_padding_points: None,
        edge_padding: None,
        diagonal: None,
        style_shading: None,
        style_uniform_border: None,
        background_resource_id: None,
        background_gradient: None,
    }
}

/// Everything but `background_resource_id`/`background_gradient` — the caller (`map_table`'s own
/// cell loop) patches those two in afterward, since resolving a resource needs `&mut self` and
/// this is a free function.
fn convert_cell(cell: &Cell, row: u32, column: u32, row_span: u32, column_span: u32) -> wire::TableCell {
    wire::TableCell {
        row,
        column,
        row_span,
        column_span,
        direct_shading: cell.background_color.map(convert_color),
        direct_uniform_border: uniform_border(cell.border_color, cell.border_width),
        direct_edge_borders: cell.edge_borders.as_ref().map(convert_edge_borders),
        declared_width_points: cell.width,
        vertical_alignment: cell.vertical_alignment.map(convert_cell_valign),
        uniform_padding_points: cell.padding,
        edge_padding: cell.edge_padding.as_ref().map(insets_nonneg),
        diagonal: cell.diagonal.as_ref().map(convert_cell_diagonal),
        style_shading: cell.style_shading.map(convert_color),
        style_uniform_border: uniform_border(cell.style_border_color, cell.style_border_width),
        background_resource_id: None,
        background_gradient: None,
    }
}

/// Converts a span or section's own `OfficeColumnLayout`, when it declared one, into the wire
/// tree's `ColumnFlowDeclaration` — reusing `office_accounting::column_flow_from_office` rather
/// than re-deriving its acceptance rule. `None` in means the span/section declared no column flow
/// at all, which stays `Ok(None)`; `Some` in means it did, and a layout that could not be honestly
/// converted (incomplete raw authority, an invalid count, ...) surfaces as
/// `OfficeAdapterError::InvalidColumnAuthority` rather than being silently dropped to `None`.
fn column_flow_for_layout(
    layout: Option<&OfficeColumnLayout>,
) -> Result<Option<wire::ColumnFlowDeclaration>, OfficeAdapterError> {
    layout
        .map(|layout| {
            office_accounting::column_flow_from_office(layout)
                .map_err(OfficeAdapterError::InvalidColumnAuthority)
        })
        .transpose()
}

/// The column declaration governing a SECTION, read the same way `OfficeTextBuilder` finds the
/// one governing a block: office formats carry it on the first run inside a paragraph/heading/list
/// item, not on the section itself, so the section's own authority is whichever of ITS blocks
/// declares one first.
fn first_declared_column_layout(blocks: &[OfficeBlock]) -> Option<&OfficeColumnLayout> {
    blocks.iter().find_map(|block| match block {
        OfficeBlock::Heading { spans, .. }
        | OfficeBlock::Paragraph { spans, .. }
        | OfficeBlock::ListItem { spans, .. } => {
            spans.iter().find_map(|s| s.column_layout.as_ref())
        }
        _ => None,
    })
}

/// A run carries ONLY the size it declared. The document's default has its own slot
/// (`wire::Document.default_body_font_size`) and is not copied down here: a default written onto
/// every run is indistinguishable from every run having declared it, which destroys the one fact
/// a consumer needs to reproduce the document's own rhythm (invariant 107).
fn convert_text_run(span: &Span) -> wire::TextRun {
    let underline = if span.underline { Some(convert_underline_style(span.underline_style)) } else { None };
    let vertical_position = if span.superscript {
        wire::VerticalPosition::Superscript
    } else if span.subscripted {
        wire::VerticalPosition::Subscript
    } else {
        wire::VerticalPosition::Normal
    };
    wire::TextRun {
        text: span.text.to_string(),
        style: wire::CharacterStyle {
            bold: span.bold,
            italic: span.italic,
            strike: span.strikethrough,
            inline_code: span.code,
            caps: span.caps,
            small_caps: span.small_caps,
            underline,
            vertical_position,
            letter_spacing_percent: span.letter_spacing_percent,
            baseline_offset_percent: span.baseline_offset_percent,
            underline_color: if span.underline { span.underline_color.map(convert_color) } else { None },
            strikethrough_color: if span.strikethrough {
                span.strikethrough_color.map(convert_color)
            } else {
                None
            },
            declared_font_name: span.font_name.as_ref().map(|s| s.to_string()),
            font_families: vec![],
            // ONLY what this run declared. Stamping the document's default here made a run that
            // stated 11pt and a run that inherited 11pt the same bytes, and the reverse projection
            // then had to GUESS which was which — by frequency, which is right on a long document
            // and wrong on every short one (invariant 107). The default now rides on
            // `wire::Document.default_body_font_size`, where one document has exactly one of it.
            font_size_points: span.font_size,
            foreground: span.text_color.map(convert_color),
            background: span.highlight_color.map(convert_color),
            baseline_offset_points: None,
            language: None,
            script: None,
            feature_flags: vec![],
        },
        direction: if span.rtl { Some(wire::Direction::RightToLeft) } else { None },
        link: span.link.as_ref().map(|s| s.to_string()),
        bookmark_ids: vec![],
        comment_ids: vec![],
        field: None,
        footnote_reference_number: span.footnote_ref,
        form_control: span.form_control.as_ref().map(convert_form_control),
        page_number_field: span.page_number_field.map(convert_page_number_field),
        column_flow: None,
    }
}

fn convert_form_control(fc: &OfficeFormControl) -> wire::InlineFormControl {
    wire::InlineFormControl {
        kind: convert_form_control_kind(fc.kind),
        caption: fc.caption.to_string(),
        text: fc.text.to_string(),
        value: fc.value,
        enabled: fc.enabled,
    }
}

fn convert_form_control_kind(v: office_block::OfficeFormControlKind) -> wire::FormControlKind {
    use office_block::OfficeFormControlKind as K;
    match v {
        K::CheckBox => wire::FormControlKind::CheckBox,
        K::RadioButton => wire::FormControlKind::RadioButton,
        K::PushButton => wire::FormControlKind::PushButton,
        K::ComboBox => wire::FormControlKind::ComboBox,
        K::Edit => wire::FormControlKind::Edit,
        K::ListBox => wire::FormControlKind::ListBox,
        K::ScrollBar => wire::FormControlKind::ScrollBar,
        K::Unknown => wire::FormControlKind::Unknown,
    }
}

fn convert_page_number_field(v: office_block::PageNumberField) -> wire::PageNumberField {
    match v {
        office_block::PageNumberField::Page => wire::PageNumberField::Page,
        office_block::PageNumberField::NumPages => wire::PageNumberField::NumPages,
    }
}

fn paragraph_style(
    format: &office_block::ParagraphFormat,
    alignment: Option<NSTextAlignment>,
    rtl: bool,
) -> wire::ParagraphStyle {
    wire::ParagraphStyle {
        alignment: alignment.map(convert_alignment),
        direction: if rtl { Some(wire::Direction::RightToLeft) } else { None },
        first_line_indent: format.first_line_indent,
        head_indent: format.indent_start,
        tail_indent: format.indent_end,
        spacing_before: format.spacing_before,
        spacing_after: format.spacing_after,
        line_height: format.line_height.map(convert_line_height),
        borders: paragraph_border_set(format),
        shading: format.shading.map(convert_color),
        legacy_columns: None,
        list_text_distance: format.list_text_distance,
        hanging_indent: format.hanging_indent,
        contextual_spacing: format.contextual_spacing,
        east_asian_line_break: format.east_asian_line_break.map(convert_line_break_granularity),
        latin_line_break: format.latin_line_break.map(convert_line_break_granularity),
        auto_space_east_asian_latin: format.auto_space_east_asian_latin,
        auto_space_east_asian_number: format.auto_space_east_asian_number,
        line_height_from_font_metrics: format.line_height_from_font_metrics,
    }
}

/// A paragraph border set may not declare inside edges (`validate_border_set`,
/// `allow_inside_edges = false`), and the office model only carries one uniform colour/width
/// across whichever edges `ParagraphFormat.border_edges` names — so every named edge gets the
/// same drawn rule. `None` unless the document actually named an edge AND said something to draw.
fn paragraph_border_set(format: &office_block::ParagraphFormat) -> Option<wire::BorderSet> {
    if format.border_edges.is_empty() {
        return None;
    }
    if format.border_color.is_none() && format.border_width.is_none() {
        return None;
    }
    let drawn = wire::BorderDeclaration::Drawn(wire::DrawnBorder {
        width_points: format.border_width.unwrap_or(0.0),
        color: format.border_color.map(convert_color),
        style: wire::BorderLineStyle::Solid,
    });
    let mut set = wire::BorderSet::default();
    if format.border_edges.contains(office_block::RectEdge::TOP) {
        set.top = Some(drawn.clone());
    }
    if format.border_edges.contains(office_block::RectEdge::LEFT) {
        set.left = Some(drawn.clone());
    }
    if format.border_edges.contains(office_block::RectEdge::BOTTOM) {
        set.bottom = Some(drawn.clone());
    }
    if format.border_edges.contains(office_block::RectEdge::RIGHT) {
        set.right = Some(drawn);
    }
    Some(set)
}

fn convert_edge_borders(eb: &EdgeBorders) -> wire::BorderSet {
    wire::BorderSet {
        top: eb.top.map(convert_border_decl),
        right: eb.right.map(convert_border_decl),
        bottom: eb.bottom.map(convert_border_decl),
        left: eb.left.map(convert_border_decl),
        inside_horizontal: eb.inside_h.map(convert_border_decl),
        inside_vertical: eb.inside_v.map(convert_border_decl),
    }
}

fn convert_border_decl(d: BorderDecl) -> wire::BorderDeclaration {
    match d {
        BorderDecl::Suppressed => wire::BorderDeclaration::Suppressed,
        BorderDecl::Drawn(side) => wire::BorderDeclaration::Drawn(wire::DrawnBorder {
            width_points: side.width,
            color: side.color.map(convert_color),
            style: convert_border_line_style(side.style),
        }),
    }
}

fn convert_cell_diagonal(d: &office_block::CellDiagonal) -> wire::CellDiagonal {
    wire::CellDiagonal {
        direction: match d.direction {
            office_block::CellDiagonalDirection::Slash => wire::CellDiagonalDirection::Slash,
            office_block::CellDiagonalDirection::Backslash => wire::CellDiagonalDirection::Backslash,
            office_block::CellDiagonalDirection::Both => wire::CellDiagonalDirection::Both,
        },
        side: wire::DrawnBorder {
            width_points: d.side.width,
            color: d.side.color.map(convert_color),
            style: convert_border_line_style(d.side.style),
        },
    }
}

/// `hwp_shape_path::PathSpec` -> `wire::VectorPath`. Values cross unaltered — a path command's
/// coordinates are the validator's problem (`vector data is invalid` on a non-finite one), not
/// something this adapter substitutes a safe number for.
fn convert_vector_path(spec: &PathSpec) -> wire::VectorPath {
    wire::VectorPath {
        commands: spec.commands.iter().map(convert_path_command).collect(),
        stroke: spec.stroke.as_ref().map(convert_vector_stroke),
        fill: spec.fill.map(convert_color),
        arrow_start: spec.arrow_start,
        arrow_end: spec.arrow_end,
    }
}

fn convert_path_command(cmd: &HwpPathCommand) -> wire::PathCommand {
    match *cmd {
        HwpPathCommand::Move(p) => {
            wire::PathCommand { command: "moveTo".to_string(), values: vec![p.x, p.y] }
        }
        HwpPathCommand::Line(p) => {
            wire::PathCommand { command: "lineTo".to_string(), values: vec![p.x, p.y] }
        }
        HwpPathCommand::Curve(c1, c2, end) => wire::PathCommand {
            command: "curveTo".to_string(),
            values: vec![c1.x, c1.y, c2.x, c2.y, end.x, end.y],
        },
        HwpPathCommand::Close => wire::PathCommand { command: "close".to_string(), values: vec![] },
    }
}

fn convert_vector_stroke(side: &BorderSide) -> wire::DrawnBorder {
    wire::DrawnBorder {
        width_points: side.width,
        color: side.color.map(convert_color),
        style: convert_border_line_style(side.style),
    }
}

fn convert_border_line_style(v: office_block::BorderLineStyle) -> wire::BorderLineStyle {
    match v {
        office_block::BorderLineStyle::Solid => wire::BorderLineStyle::Solid,
        office_block::BorderLineStyle::Dashed => wire::BorderLineStyle::Dashed,
        office_block::BorderLineStyle::Dotted => wire::BorderLineStyle::Dotted,
        office_block::BorderLineStyle::Double => wire::BorderLineStyle::Double,
    }
}

fn convert_underline_style(v: office_block::UnderlineStyle) -> wire::UnderlineStyle {
    match v {
        office_block::UnderlineStyle::Single => wire::UnderlineStyle::Single,
        office_block::UnderlineStyle::Double => wire::UnderlineStyle::Double,
        office_block::UnderlineStyle::Dotted => wire::UnderlineStyle::Dotted,
        office_block::UnderlineStyle::Dashed => wire::UnderlineStyle::Dashed,
        office_block::UnderlineStyle::Wavy => wire::UnderlineStyle::Wavy,
    }
}

fn convert_tab_alignment(v: office_block::TabAlignment) -> wire::TabAlignment {
    match v {
        office_block::TabAlignment::Left => wire::TabAlignment::Left,
        office_block::TabAlignment::Center => wire::TabAlignment::Center,
        office_block::TabAlignment::Right => wire::TabAlignment::Right,
        office_block::TabAlignment::Decimal => wire::TabAlignment::Decimal,
    }
}

fn convert_tab_leader(v: office_block::TabLeader) -> wire::TabLeader {
    match v {
        office_block::TabLeader::None => wire::TabLeader::None,
        office_block::TabLeader::Dot => wire::TabLeader::Dot,
        office_block::TabLeader::Hyphen => wire::TabLeader::Hyphen,
        office_block::TabLeader::Underscore => wire::TabLeader::Underscore,
    }
}

fn convert_cell_valign(v: CellVAlign) -> wire::VerticalAlignment {
    match v {
        CellVAlign::Top => wire::VerticalAlignment::Top,
        CellVAlign::Center => wire::VerticalAlignment::Middle,
        CellVAlign::Bottom => wire::VerticalAlignment::Bottom,
    }
}

fn convert_glyphs(v: office_block::ListNumberingGlyphs) -> wire::ListNumberingGlyphs {
    use office_block::ListNumberingGlyphs as G;
    match v {
        G::Decimal => wire::ListNumberingGlyphs::Decimal,
        G::CircledDecimal => wire::ListNumberingGlyphs::CircledDecimal,
        G::RomanUpper => wire::ListNumberingGlyphs::RomanUpper,
        G::RomanLower => wire::ListNumberingGlyphs::RomanLower,
        G::LatinUpper => wire::ListNumberingGlyphs::LatinUpper,
        G::LatinLower => wire::ListNumberingGlyphs::LatinLower,
        G::HangulSyllable => wire::ListNumberingGlyphs::HangulSyllable,
        G::HangulNumber => wire::ListNumberingGlyphs::HangulNumber,
        G::HanjaNumber => wire::ListNumberingGlyphs::HanjaNumber,
    }
}

fn convert_page_break_policy(v: office_block::TablePageBreakPolicy) -> wire::TablePageBreakPolicy {
    match v {
        office_block::TablePageBreakPolicy::Never => wire::TablePageBreakPolicy::Never,
        office_block::TablePageBreakPolicy::AtRowBoundary => wire::TablePageBreakPolicy::AtRowBoundary,
        office_block::TablePageBreakPolicy::Anywhere => wire::TablePageBreakPolicy::Anywhere,
    }
}

fn convert_line_break_granularity(
    v: office_block::LineBreakGranularity,
) -> wire::LineBreakGranularity {
    match v {
        office_block::LineBreakGranularity::Word => wire::LineBreakGranularity::Word,
        office_block::LineBreakGranularity::Hyphen => wire::LineBreakGranularity::Hyphen,
        office_block::LineBreakGranularity::Character => wire::LineBreakGranularity::Character,
    }
}

/// The document's own statement of which pages this band serves. Folding the three states into one
/// would print a title page's header on every page.
/// What the bytes ARE, read from their own magic number. The reader hands over decoded pictures
/// without saying what format they are in, and `valid_mime` requires a real token — so this reads
/// the signature rather than guessing from a key name that may carry no extension at all.
fn sniff_image_mime(bytes: &[u8]) -> &'static str {
    match bytes {
        [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, ..] => "image/png",
        [0xFF, 0xD8, 0xFF, ..] => "image/jpeg",
        [b'G', b'I', b'F', b'8', ..] => "image/gif",
        [b'B', b'M', ..] => "image/bmp",
        [b'I', b'I', 0x2A, 0x00, ..] | [b'M', b'M', 0x00, 0x2A, ..] => "image/tiff",
        [b'R', b'I', b'F', b'F', _, _, _, _, b'W', b'E', b'B', b'P', ..] => "image/webp",
        _ => "application/octet-stream",
    }
}

fn convert_header_footer_applicability(
    value: office_block::HeaderFooterApplicability,
) -> wire::HeaderFooterApplicability {
    match value {
        office_block::HeaderFooterApplicability::DefaultPages => {
            wire::HeaderFooterApplicability::DefaultPages
        }
        office_block::HeaderFooterApplicability::FirstPage => {
            wire::HeaderFooterApplicability::FirstPage
        }
        office_block::HeaderFooterApplicability::EvenPages => {
            wire::HeaderFooterApplicability::EvenPages
        }
    }
}

fn convert_line_height(lh: office_block::LineHeight) -> wire::LineHeight {
    match lh {
        office_block::LineHeight::Multiple(v) => wire::LineHeight { value: v, mode: wire::LineHeightMode::Multiple },
        office_block::LineHeight::Exact(v) => wire::LineHeight { value: v, mode: wire::LineHeightMode::Exact },
        office_block::LineHeight::AtLeast(v) => wire::LineHeight { value: v, mode: wire::LineHeightMode::AtLeast },
    }
}

fn convert_alignment(v: NSTextAlignment) -> wire::Alignment {
    match v {
        NSTextAlignment::Left => wire::Alignment::Left,
        NSTextAlignment::Right => wire::Alignment::Right,
        NSTextAlignment::Center => wire::Alignment::Center,
        NSTextAlignment::Justified => wire::Alignment::Justified,
        NSTextAlignment::Natural => wire::Alignment::Natural,
    }
}

fn convert_paragraph_anchor_align(
    v: office_block::ParagraphAnchorAlign,
) -> wire::ParagraphAnchorAlign {
    match v {
        office_block::ParagraphAnchorAlign::Top => wire::ParagraphAnchorAlign::Top,
        office_block::ParagraphAnchorAlign::Center => wire::ParagraphAnchorAlign::Center,
        office_block::ParagraphAnchorAlign::Bottom => wire::ParagraphAnchorAlign::Bottom,
    }
}

/// S6-4: `office_block::OfficeGradient` -> `wire::Gradient` — a declaration, never a bitmap.
fn convert_gradient(g: &office_block::OfficeGradient) -> wire::Gradient {
    wire::Gradient {
        stops: g.stops.iter().copied().map(convert_color).collect(),
        angle_degrees: g.angle_degrees,
    }
}

/// `office_block::OfficeFootnoteSeparator` -> `wire::FootnoteSeparator`, field for field — every
/// length already arrives in points from the reader, nothing here converts units.
fn convert_footnote_separator(fs: &office_block::OfficeFootnoteSeparator) -> wire::FootnoteSeparator {
    wire::FootnoteSeparator {
        line_type: fs.line_type,
        line_width_points: fs.line_width_pt,
        color: fs.color.map(convert_color),
        length_points: fs.length_pt,
        margin_top_points: fs.margin_top_pt,
        margin_bottom_points: fs.margin_bottom_pt,
        note_spacing_points: fs.note_spacing_pt,
    }
}

/// `office_block::OfficePageBorder` -> `wire::PageBorder`. `borders` reuses `convert_edge_borders`
/// — the SAME per-edge decode a table cell's border gets, so invariant 47's "a SUPPRESSED edge is
/// not a missing one" distinction is not re-implemented here.
fn convert_page_border(pb: &office_block::OfficePageBorder) -> wire::PageBorder {
    wire::PageBorder {
        borders: pb.borders.as_ref().map(convert_edge_borders),
        background: pb.background.map(convert_color),
        spacing: wire::Insets {
            top: pb.spacing.top,
            right: pb.spacing.right,
            bottom: pb.spacing.bottom,
            left: pb.spacing.left,
        },
        measured_from_paper: pb.measured_from_paper,
    }
}

fn convert_color(c: NSColor) -> wire::Color {
    use swiftshim::color_font::NSColorSpaceName;
    wire::Color {
        red: c.red,
        green: c.green,
        blue: c.blue,
        alpha: c.alpha,
        space: match c.space {
            NSColorSpaceName::SRGB => wire::ColorSpace::Srgb,
            NSColorSpaceName::DeviceRGB => wire::ColorSpace::DeviceRgb,
        },
    }
}

fn uniform_border(color: Option<NSColor>, width: Option<f64>) -> Option<wire::UniformBorder> {
    if color.is_none() && width.is_none() {
        return None;
    }
    Some(wire::UniformBorder { color: color.map(convert_color), width_points: width })
}

fn insets_nonneg(ep: &EdgePadding) -> wire::OptionalInsets {
    wire::OptionalInsets {
        top: ep.top,
        right: ep.right,
        bottom: ep.bottom,
        left: ep.left,
    }
}

fn insets_finite(ep: &EdgePadding) -> wire::OptionalInsets {
    wire::OptionalInsets {
        top: ep.top,
        right: ep.right,
        bottom: ep.bottom,
        left: ep.left,
    }
}

/// `validate_tab_stops` requires the whole set to be finite and strictly increasing by position.
/// Sorting is a canonical ordering of a set the document states without one, so it happens here.
/// Nothing is dropped: a stop the source states out of contract reaches the validator and fails the
/// document loudly, because a silently deleted tab stop is a document that renders wrong with no
/// way to find out why.
fn sanitize_tab_stops(stops: &[office_block::TabStop]) -> Vec<wire::TabStop> {
    let mut sorted: Vec<&office_block::TabStop> = stops.iter().collect();
    sorted.sort_by(|a, b| a.position.partial_cmp(&b.position).unwrap_or(std::cmp::Ordering::Equal));
    sorted
        .into_iter()
        .map(|ts| wire::TabStop {
            position_points: ts.position,
            alignment: convert_tab_alignment(ts.alignment),
            leader: convert_tab_leader(ts.leader),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::render::office::office_block::{
        ListNumbering, OfficeFootnoteSeparator, OfficeMasterObject, OfficeMasterObjectContent,
        OfficePageBorder, OfficeSectionDeclaration, ParagraphFormat,
    };
    use swiftshim::{CGRect, NSEdgeInsets};

    fn input(result: &OfficeReadResult) -> OfficeAdapterInput<'_> {
        OfficeAdapterInput {
            format: DocumentFormat::Docx,
            source_name: "doc.docx",
            source_bytes: b"hello office",
            result,
            resources: BTreeMap::new(),
        }
    }

    /// A source metric outside the canonical contract must reach the validator and stop the
    /// document. The adapter used to substitute `0.0` / `None` for these, which turned a rejection
    /// the validator reports precisely into a silently wrong layout value.
    #[test]
    fn a_non_finite_source_metric_fails_loudly_instead_of_being_substituted() {
        let format = ParagraphFormat {
            spacing_before: Some(f64::NAN),
            ..ParagraphFormat::default()
        };
        let result = OfficeReadResult {
            blocks: vec![office_block::OfficeBlock::Paragraph {
                spans: vec![],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format,
            }],
            ..OfficeReadResult::default()
        };
        assert!(
            matches!(
                from_office(input(&result)),
                Err(OfficeAdapterError::Canonicalization(_))
            ),
            "a NaN paragraph metric must stop canonicalization, not become a number"
        );
    }

    /// The tree must keep the two facts APART: what the document's default is, and what each run
    /// declared. The old shape of this test asserted the opposite — that a run with no size of its
    /// own carries the document's default — and passed, which is how the loss stayed invisible for
    /// so long: the value was reachable, so "derived" looked honest, while the distinction between
    /// a declared 13.5 and an inherited one had already been destroyed (invariant 107).
    #[test]
    fn the_document_carries_its_default_and_a_run_that_declared_nothing_carries_nothing() {
        let result = OfficeReadResult {
            default_body_font_size: 13.5,
            blocks: vec![office_block::OfficeBlock::Paragraph {
                spans: vec![Span { text: "x".into(), ..Span::default() }],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            }],
            ..OfficeReadResult::default()
        };
        let tree = from_office(input(&result)).expect("canonicalizes");
        let json = tree.encode_json().expect("encodes");
        let value: serde_json::Value = serde_json::from_slice(&json).unwrap();
        assert_eq!(
            value["document"]["defaultBodyFontSize"].as_f64(),
            Some(13.5),
            "the document's own default must be carried, once, on the document"
        );
        let runs: Vec<&serde_json::Value> = value["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|n| n["type"] == "textRun")
            .collect();
        assert_eq!(runs.len(), 1, "this fixture has exactly one run");
        assert!(
            runs[0]["data"]["style"]["fontSizePoints"].is_null(),
            "a run that declared no size must carry none — stamping the default here is what made \
             a declared size and an inherited one the same bytes"
        );
    }

    /// The other half of the same rule: a run that DID declare a size keeps it, even when that
    /// size happens to equal the document's default. This is the case the projection's old
    /// frequency heuristic got wrong on every short document.
    #[test]
    fn a_run_that_declared_the_same_size_as_the_default_still_says_so() {
        let result = OfficeReadResult {
            default_body_font_size: 13.5,
            blocks: vec![office_block::OfficeBlock::Paragraph {
                spans: vec![Span { text: "x".into(), font_size: Some(13.5), ..Span::default() }],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            }],
            ..OfficeReadResult::default()
        };
        let tree = from_office(input(&result)).expect("canonicalizes");
        let json = tree.encode_json().expect("encodes");
        let value: serde_json::Value = serde_json::from_slice(&json).unwrap();
        let sizes: Vec<f64> = value["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|n| n["type"] == "textRun")
            .filter_map(|n| n["data"]["style"]["fontSizePoints"].as_f64())
            .collect();
        assert_eq!(sizes, vec![13.5], "an explicitly declared size survives even at the default");
    }

    /// HWP hands its pictures over already decoded, in the result itself. If the adapter consulted
    /// only the caller's resource map, every HWP picture would be `MissingResource` unless the
    /// caller copied the bytes across first — and the ledger's claim that `images` is mapped would
    /// be false.
    #[test]
    fn a_reader_decoded_picture_resolves_without_the_caller_supplying_it() {
        const PNG: &[u8] = &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01];
        let mut images = std::collections::HashMap::new();
        images.insert(SwiftString::from("pic1".to_string()), swiftshim::Data(PNG.to_vec()));
        let result = OfficeReadResult {
            images,
            blocks: vec![office_block::OfficeBlock::Image {
                id: SwiftString::from("pic1".to_string()),
                size: CGSize::new(10.0, 20.0),
                alignment: None,
            }],
            ..OfficeReadResult::default()
        };
        // `input` supplies an EMPTY resource map on purpose.
        let tree = from_office(input(&result)).expect("the reader's own bytes must resolve");
        let value: serde_json::Value =
            serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        let resources = value["resources"].as_array().unwrap();
        assert_eq!(resources.len(), 1, "the picture must become one checked resource");
        assert_eq!(resources[0]["mimeType"], "image/png", "read from the bytes' own signature");
        assert_eq!(resources[0]["byteLength"], PNG.len());
    }

    /// A document that states its page size only at the top level (no section declares paper, or
    /// there are no sections at all) must still canonicalize WITH that sheet. Reading the geometry
    /// from the section declaration alone dropped it silently.
    #[test]
    fn top_level_page_geometry_reaches_the_sheet_when_no_section_declares_one() {
        let result = OfficeReadResult {
            page_content_width: Some(400.0),
            page_content_height: Some(600.0),
            page_margin_left: Some(50.0),
            page_margin_right: Some(50.0),
            page_margin_top: Some(60.0),
            page_margin_bottom: Some(60.0),
            ..OfficeReadResult::default()
        };
        let tree = from_office(input(&result)).expect("canonicalizes");
        let value: serde_json::Value =
            serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        let section = value["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|n| n["type"] == "section")
            .expect("a section exists");
        let paper = &section["data"]["paper"];
        assert_eq!(paper["widthPoints"], 500.0, "left + content + right");
        assert_eq!(paper["heightPoints"], 720.0, "top + content + bottom");
        assert_eq!(paper["margins"]["left"], 50.0);
    }

    /// A partial statement cannot make an honest sheet, so it stays absent rather than becoming a
    /// sheet with invented zeroes.
    #[test]
    fn partial_top_level_page_geometry_yields_no_sheet() {
        let result = OfficeReadResult {
            page_content_width: Some(400.0),
            ..OfficeReadResult::default()
        };
        let tree = from_office(input(&result)).expect("canonicalizes");
        let value: serde_json::Value =
            serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        let section = value["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|n| n["type"] == "section")
            .expect("a section exists");
        assert!(section["data"]["paper"].is_null(), "no invented sheet");
    }

    #[test]
    fn empty_result_canonicalizes() {
        let result = OfficeReadResult::default();
        let tree = ValidatedRenderTree::from_office(input(&result)).expect("should canonicalize");
        assert_eq!(tree.schema_version(), 1);
        // One synthetic Section + one Flow, both under Document.
        assert_eq!(tree.node_tags(), vec!["document", "section", "flow"]);
    }

    #[test]
    fn paragraph_with_runs() {
        let mut result = OfficeReadResult::default();
        result.blocks.push(OfficeBlock::Paragraph {
            spans: vec![
                Span { text: SwiftString::from("hello "), bold: true, ..Default::default() },
                Span { text: SwiftString::from("world"), italic: true, ..Default::default() },
            ],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        });
        let tree = ValidatedRenderTree::from_office(input(&result)).unwrap();
        let tags = tree.node_tags();
        assert_eq!(tags, vec!["document", "section", "flow", "paragraph", "textRun", "textRun"]);
    }

    #[test]
    fn heading_block() {
        let mut result = OfficeReadResult::default();
        result.blocks.push(OfficeBlock::Heading {
            level: 1,
            spans: vec![Span { text: SwiftString::from("Title"), ..Default::default() }],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        });
        let tree = ValidatedRenderTree::from_office(input(&result)).unwrap();
        assert!(tree.node_tags().contains(&"heading"));
    }

    #[test]
    fn list_items_grouped_under_one_list() {
        let mut result = OfficeReadResult::default();
        for i in 0..3 {
            result.blocks.push(OfficeBlock::ListItem {
                level: 0,
                ordered: true,
                spans: vec![Span { text: SwiftString::from(format!("item {i}")), ..Default::default() }],
                marker: None,
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
                numbering: Some(ListNumbering::default()),
            });
        }
        let tree = ValidatedRenderTree::from_office(input(&result)).unwrap();
        let tags = tree.node_tags();
        assert_eq!(tags.iter().filter(|t| **t == "list").count(), 1);
        assert_eq!(tags.iter().filter(|t| **t == "listItem").count(), 3);
    }

    /// The cell-padding rule, moved here from the JSON mutation battery. It used to be checked by
    /// a `cell-padding-negative` mutation, and that mutation stopped describing an invalid value
    /// once a NEGATIVE padding became legal — rhwp's `Cell::effective_padding` really produces
    /// them (measured: 2 of 674 cells in `59043_regulatory_analysis.hwp`, at -309.84 and -144.72)
    /// and the shipped reader carries them to AppKit untouched and opens the document, so refusing
    /// them made the tree stricter than the app it replaces.
    ///
    /// What remains forbidden is a padding that is not a NUMBER, and that cannot be expressed in
    /// JSON at all — so deleting the mutation would have left the rule with nothing biting it. It
    /// is checked here instead, on the `from_office` path, which is where a NaN can actually
    /// arrive from a parser. Both directions are asserted: NaN refuses, negative does not.
    #[test]
    fn a_negative_cell_padding_is_carried_but_a_nan_one_stops_the_document() {
        fn table_with_padding(padding: office_block::EdgePadding) -> OfficeReadResult {
            let mut cell = Cell::new_with_spans(
                vec![Span { text: SwiftString::from("x"), ..Default::default() }],
                1,
                1,
            );
            cell.edge_padding = Some(padding);
            let mut result = OfficeReadResult::default();
            result.blocks.push(OfficeBlock::Table {
                rows: vec![vec![cell]],
                header_rows: 0,
                column_widths: vec![],
                format: TableFormat::default(),
            });
            result
        }

        let negative = table_with_padding(office_block::EdgePadding {
            top: Some(-309.84),
            left: Some(0.0),
            bottom: Some(0.0),
            right: Some(0.0),
        });
        assert!(
            from_office(input(&negative)).is_ok(),
            "a negative padding is a number the parser really produces and the reader really \
             draws — refusing it costs the whole document over one cell"
        );

        let nan = table_with_padding(office_block::EdgePadding {
            top: Some(f64::NAN),
            left: Some(0.0),
            bottom: Some(0.0),
            right: Some(0.0),
        });
        assert!(
            matches!(from_office(input(&nan)), Err(OfficeAdapterError::Canonicalization(_))),
            "a padding that is not a number must still stop canonicalization"
        );

        // The TABLE's own default padding goes through the same helper, and the host resolves the
        // two as one chain (cell, else table, else the reader's default), so both directions have
        // to hold there too — a stricter fallback than the value falling back to it would refuse
        // documents the cell-level rule just accepted.
        let mut table_negative = OfficeReadResult::default();
        table_negative.blocks.push(OfficeBlock::Table {
            rows: vec![vec![Cell::new_with_spans(
                vec![Span { text: SwiftString::from("x"), ..Default::default() }],
                1,
                1,
            )]],
            header_rows: 0,
            column_widths: vec![],
            format: TableFormat {
                default_padding: Some(office_block::EdgePadding {
                    top: Some(0.0),
                    left: Some(-1.0),
                    bottom: Some(0.0),
                    right: Some(0.0),
                }),
                ..TableFormat::default()
            },
        });
        assert!(
            from_office(input(&table_negative)).is_ok(),
            "a table's default padding must accept a negative for the same reason a cell's does"
        );
    }

    #[test]
    fn nested_table_with_cell_paragraph() {
        let mut result = OfficeReadResult::default();
        let cell = Cell::new_with_spans(
            vec![Span { text: SwiftString::from("cell text"), ..Default::default() }],
            1,
            1,
        );
        result.blocks.push(OfficeBlock::Table {
            rows: vec![vec![cell]],
            header_rows: 0,
            column_widths: vec![],
            format: TableFormat::default(),
        });
        let tree = ValidatedRenderTree::from_office(input(&result)).unwrap();
        let tags = tree.node_tags();
        assert!(tags.contains(&"table"));
        assert!(tags.contains(&"tableRow"));
        assert!(tags.contains(&"tableCell"));
        assert!(tags.contains(&"paragraph"));
    }

    fn dummy_image() -> swiftshim::NSImage {
        swiftshim::NSImage::withSize(CGSize::new(1.0, 1.0))
    }

    /// S6-4: a cell's real picture fill becomes a resource reference, never a refusal — and never
    /// a `background_gradient` (the two are mutually exclusive by construction).
    #[test]
    fn a_cell_picture_fill_becomes_a_resource_reference_not_a_refusal() {
        let mut result = OfficeReadResult::default();
        let mut cell = Cell::new_with_spans(vec![], 1, 1);
        cell.background_image = Some(dummy_image());
        result.blocks.push(OfficeBlock::Table {
            rows: vec![vec![cell]],
            header_rows: 0,
            column_widths: vec![],
            format: TableFormat::default(),
        });
        let tree = ValidatedRenderTree::from_office(input(&result)).expect("must not refuse");
        let value: serde_json::Value = serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        let cell_node = value["nodes"].as_array().unwrap().iter().find(|n| n["type"] == "tableCell").unwrap();
        assert!(cell_node["data"]["backgroundResourceId"].is_u64(), "expected a resource id, got {cell_node:?}");
        assert!(cell_node["data"]["backgroundGradient"].is_null());
        assert_eq!(value["resources"].as_array().unwrap().len(), 1);
    }

    /// S6-4's other half: a gradient-only fill (no real picture) carries stops+angle as a
    /// declaration, never a rasterized bitmap — no `resources` entry is created for it.
    #[test]
    fn a_gradient_only_fill_carries_a_declaration_not_a_bitmap() {
        let mut result = OfficeReadResult::default();
        let mut format = TableFormat::default();
        format.background_gradient = Some(office_block::OfficeGradient {
            stops: vec![NSColor::srgb(1.0, 0.0, 0.0, 1.0),
                        NSColor::srgb(0.0, 0.0, 1.0, 1.0)],
            angle_degrees: Some(45.0),
        });
        result.blocks.push(OfficeBlock::Table {
            rows: vec![],
            header_rows: 0,
            column_widths: vec![],
            format,
        });
        let tree = ValidatedRenderTree::from_office(input(&result)).expect("must not refuse");
        let value: serde_json::Value = serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        let table_node = value["nodes"].as_array().unwrap().iter().find(|n| n["type"] == "table").unwrap();
        let style = &table_node["data"]["style"];
        assert!(style["backgroundResourceId"].is_null());
        let stops = style["backgroundGradient"]["stops"].as_array().unwrap();
        assert_eq!(stops.len(), 2);
        assert_eq!(style["backgroundGradient"]["angleDegrees"], 45.0);
        assert!(value["resources"].as_array().unwrap().is_empty(), "a synthesized gradient bitmap must never become a resource");
    }

    #[test]
    fn pagination_rekeys_onto_the_right_block_including_a_heading() {
        let mut result = OfficeReadResult::default();
        result.blocks.push(OfficeBlock::Paragraph {
            spans: vec![],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        });
        result.blocks.push(OfficeBlock::Heading {
            level: 2,
            spans: vec![],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        });
        result.keep_with_next_blocks.push(0);
        result.page_break_blocks.push(1);
        result.hide_page_number_blocks.push(1);
        result.page_number_restart_blocks.push(office_block::OfficePageNumberRestart { block: 1, number: 5 });

        let tree = ValidatedRenderTree::from_office(input(&result)).unwrap();
        let json = tree.encode_json().unwrap();
        let text = String::from_utf8(json).unwrap();
        // The paragraph (block 0) only carries keepWithNext.
        assert!(text.contains("\"keepWithNext\":true"));
        // The heading (block 1) carries the page break / hide / restart trio.
        assert!(text.contains("\"pageBreakBefore\":true"));
        assert!(text.contains("\"hidesPageNumber\":true"));
        assert!(text.contains("\"pageNumberRestart\":5"));
    }

    #[test]
    fn missing_resource_is_a_typed_error() {
        let mut result = OfficeReadResult::default();
        result.blocks.push(OfficeBlock::Image {
            id: SwiftString::from("img:1"),
            size: CGSize::new(10.0, 10.0),
            alignment: None,
        });
        let err = ValidatedRenderTree::from_office(input(&result)).unwrap_err();
        assert_eq!(err, OfficeAdapterError::MissingResource("img:1".to_string()));
    }

    fn vector_result(graphic: VectorGraphic) -> OfficeReadResult {
        let mut vector_graphics = std::collections::HashMap::new();
        vector_graphics.insert(SwiftString::from("shape:1".to_string()), graphic);
        let mut result = OfficeReadResult { vector_graphics, ..OfficeReadResult::default() };
        result.blocks.push(OfficeBlock::Image {
            id: SwiftString::from("shape:1"),
            size: CGSize::new(1.0, 1.0),
            alignment: None,
        });
        result
    }

    fn one_path(spec: PathSpec) -> VectorGraphic {
        VectorGraphic { paths: vec![spec], size: CGSize::new(30.0, 40.0) }
    }

    /// A key present in `vector_graphics` must become a `Vector` node, never an `Image` one, even
    /// though the same `OfficeBlock::Image` shape is what carries it.
    #[test]
    fn an_image_key_naming_a_vector_graphic_becomes_a_vector_node_not_an_image() {
        let result = vector_result(one_path(PathSpec {
            commands: vec![HwpPathCommand::Move(swiftshim::CGPoint { x: 0.0, y: 0.0 })],
            stroke: None,
            fill: None,
            arrow_start: false,
            arrow_end: false,
        }));
        let tree = ValidatedRenderTree::from_office(input(&result)).expect("canonicalizes");
        let tags = tree.node_tags();
        assert!(tags.contains(&"vector"), "expected a vector node, got {tags:?}");
        assert!(!tags.contains(&"image"), "must not also emit an image node");

        let value: serde_json::Value =
            serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        let vector_node =
            value["nodes"].as_array().unwrap().iter().find(|n| n["type"] == "vector").unwrap();
        assert_eq!(vector_node["data"]["intrinsicSize"]["width"], 30.0);
        assert_eq!(vector_node["data"]["intrinsicSize"]["height"], 40.0);
    }

    /// Each of the four `PathCommand` kinds must translate to its own named wire command with the
    /// right coordinate count — a wrong name (e.g. a curve emitted as `lineTo`) silently drops the
    /// control points a renderer needs to draw the actual curve.
    #[test]
    fn each_path_command_kind_translates_with_the_right_name_and_values() {
        let result = vector_result(one_path(PathSpec {
            commands: vec![
                HwpPathCommand::Move(swiftshim::CGPoint { x: 1.0, y: 2.0 }),
                HwpPathCommand::Line(swiftshim::CGPoint { x: 3.0, y: 4.0 }),
                HwpPathCommand::Curve(
                    swiftshim::CGPoint { x: 5.0, y: 6.0 },
                    swiftshim::CGPoint { x: 7.0, y: 8.0 },
                    swiftshim::CGPoint { x: 9.0, y: 10.0 },
                ),
                HwpPathCommand::Close,
            ],
            stroke: None,
            fill: None,
            arrow_start: false,
            arrow_end: false,
        }));
        let tree = ValidatedRenderTree::from_office(input(&result)).expect("canonicalizes");
        let value: serde_json::Value =
            serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        let vector_node =
            value["nodes"].as_array().unwrap().iter().find(|n| n["type"] == "vector").unwrap();
        let commands = vector_node["data"]["paths"][0]["commands"].as_array().unwrap();
        assert_eq!(commands[0]["command"], "moveTo");
        assert_eq!(commands[0]["values"], serde_json::json!([1.0, 2.0]));
        assert_eq!(commands[1]["command"], "lineTo");
        assert_eq!(commands[1]["values"], serde_json::json!([3.0, 4.0]));
        assert_eq!(commands[2]["command"], "curveTo");
        assert_eq!(commands[2]["values"], serde_json::json!([5.0, 6.0, 7.0, 8.0, 9.0, 10.0]));
        assert_eq!(commands[3]["command"], "close");
        assert_eq!(commands[3]["values"], serde_json::json!([]));
    }

    /// Stroke width/colour/style, fill and both arrow flags must all survive the crossing — a
    /// drawing reduced to bare geometry loses the difference between a filled arrow and a plain
    /// line.
    #[test]
    fn stroke_fill_and_arrow_flags_survive() {
        let result = vector_result(one_path(PathSpec {
            commands: vec![HwpPathCommand::Close],
            stroke: Some(BorderSide {
                width: 2.5,
                color: Some(swiftshim::NSColor::srgb(0.1, 0.2, 0.3, 1.0)),
                style: office_block::BorderLineStyle::Dashed,
            }),
            fill: Some(swiftshim::NSColor::srgb(0.8, 0.7, 0.6, 0.5)),
            arrow_start: true,
            arrow_end: true,
        }));
        let tree = ValidatedRenderTree::from_office(input(&result)).expect("canonicalizes");
        let value: serde_json::Value =
            serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        let path =
            &value["nodes"].as_array().unwrap().iter().find(|n| n["type"] == "vector").unwrap()
                ["data"]["paths"][0];
        assert_eq!(path["stroke"]["widthPoints"], 2.5);
        assert_eq!(path["stroke"]["style"], "dashed");
        assert_eq!(path["stroke"]["color"]["red"], 0.1);
        assert_eq!(path["fill"]["red"], 0.8);
        assert_eq!(path["fill"]["alpha"], 0.5);
        assert_eq!(path["arrowStart"], true);
        assert_eq!(path["arrowEnd"], true);
    }

    /// S6-3: a 바탕쪽 becomes a `masterPage` node under its section, its declared object a
    /// `masterPageObject` child whose `y` is FINAL (never a placeholder — invariant 78) with a
    /// `Vector` content child, the same content vocabulary an anchored object already uses.
    #[test]
    fn master_page_becomes_a_node_with_a_final_y_object() {
        let mut result = OfficeReadResult::default();
        result.master_pages.push(office_block::OfficeMasterPage {
            section: 0,
            applies_to: office_block::HeaderFooterApplicability::EvenPages,
            objects: vec![OfficeMasterObject {
                frame: CGRect::new(1.0, 2.0, 3.0, 4.0),
                content: OfficeMasterObjectContent::Vector(one_path(PathSpec {
                    commands: vec![HwpPathCommand::Move(swiftshim::CGPoint { x: 0.0, y: 0.0 })],
                    stroke: None,
                    fill: None,
                    arrow_start: false,
                    arrow_end: false,
                })),
            }],
        });
        let tree = ValidatedRenderTree::from_office(input(&result)).expect("must not refuse");
        let value: serde_json::Value =
            serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        let nodes = value["nodes"].as_array().unwrap();
        let page = nodes.iter().find(|n| n["type"] == "masterPage").unwrap();
        assert_eq!(page["data"]["appliesTo"], "evenPages");
        let object_id = page["data"]["objectIds"][0].as_u64().unwrap();
        let object = nodes.iter().find(|n| n["id"] == object_id).unwrap();
        assert_eq!(object["type"], "masterPageObject");
        assert_eq!(object["data"]["x"], 1.0);
        assert_eq!(object["data"]["y"], 2.0, "a master object's y is always final");
        assert_eq!(object["data"]["width"], 3.0);
        assert_eq!(object["data"]["height"], 4.0);
        let content_id = object["data"]["contentId"].as_u64().unwrap();
        let content = nodes.iter().find(|n| n["id"] == content_id).unwrap();
        assert_eq!(content["type"], "vector");
    }

    /// WHICH section a master page belongs to, not merely that it belongs to one. Mirrors the
    /// anchored-object lesson (`an_anchored_object_names_the_block_it_was_declared_against`'s own
    /// doc): a fixture with only one candidate section cannot tell whether `section` was read at
    /// all, so this declares two and anchors the master page to the SECOND.
    #[test]
    fn a_master_page_names_the_section_it_was_declared_against() {
        let mut result = OfficeReadResult::default();
        for text in ["first", "second"] {
            result.blocks.push(OfficeBlock::Paragraph {
                spans: vec![Span { text: SwiftString::from(text.to_string()), ..Default::default() }],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            });
        }
        result.sections = vec![
            office_block::OfficeSectionDeclaration::default(),
            office_block::OfficeSectionDeclaration::default(),
        ];
        result.section_start_blocks = vec![0, 1];
        result.master_pages.push(office_block::OfficeMasterPage {
            section: 1,
            applies_to: office_block::HeaderFooterApplicability::DefaultPages,
            objects: vec![OfficeMasterObject {
                frame: CGRect::zero(),
                content: OfficeMasterObjectContent::Text(vec![]),
            }],
        });
        let tree = ValidatedRenderTree::from_office(input(&result)).expect("must not refuse");
        let value: serde_json::Value =
            serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        let nodes = value["nodes"].as_array().unwrap();
        let page = nodes.iter().find(|n| n["type"] == "masterPage").unwrap();
        let section = nodes.iter().find(|n| n["id"] == page["parentId"]).unwrap();
        let flow_id = section["children"][0].as_u64().unwrap();
        let flow = nodes.iter().find(|n| n["id"] == flow_id).unwrap();
        let first_block = flow["children"][0].as_u64().unwrap();
        let paragraph = nodes.iter().find(|n| n["id"] == first_block).unwrap();
        let text: Vec<&str> = nodes
            .iter()
            .filter(|n| n["parentId"] == paragraph["id"] && n["type"] == "textRun")
            .filter_map(|n| n["data"]["text"].as_str())
            .collect();
        assert_eq!(text, vec!["second"], "declared against section 1, must attach to THAT section");
    }

    /// `OfficeMasterPage.section` naming a section index the document does not have is the same
    /// typed error a header/footer/footnote already gets (`resolve_owner_section`) — never
    /// silently clamped to section 0.
    #[test]
    fn a_master_page_with_a_dangling_section_is_a_typed_error() {
        let mut result = OfficeReadResult::default();
        result.master_pages.push(office_block::OfficeMasterPage {
            section: 3,
            applies_to: office_block::HeaderFooterApplicability::DefaultPages,
            objects: vec![OfficeMasterObject {
                frame: CGRect::zero(),
                content: OfficeMasterObjectContent::Text(vec![]),
            }],
        });
        let err = ValidatedRenderTree::from_office(input(&result)).unwrap_err();
        assert_eq!(err, OfficeAdapterError::SectionIndexMissing(3));
    }

    /// S6-2: a paper-/page-relative anchored object (no `paragraph_anchor`) becomes a node whose
    /// `y` is FINAL, attached under its section alongside a `Vector` content child — never an
    /// `unsupportedGraphic`, never a refusal.
    #[test]
    fn anchored_object_with_a_final_y_becomes_a_node() {
        let mut result = OfficeReadResult::default();
        result.blocks.push(OfficeBlock::Paragraph {
            spans: vec![],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        });
        result.anchored_objects.push(office_block::OfficeAnchoredObject {
            block_index: 0,
            object: OfficeMasterObject {
                frame: CGRect::new(10.0, 20.0, 30.0, 40.0),
                content: OfficeMasterObjectContent::Vector(one_path(PathSpec {
                    commands: vec![HwpPathCommand::Move(swiftshim::CGPoint { x: 0.0, y: 0.0 })],
                    stroke: None,
                    fill: None,
                    arrow_start: false,
                    arrow_end: false,
                })),
            },
            paragraph_anchor: None,
        });
        let tree = ValidatedRenderTree::from_office(input(&result)).expect("must not refuse");
        let tags = tree.node_tags();
        assert!(tags.contains(&"anchoredObject"), "expected an anchoredObject node, got {tags:?}");
        assert!(tags.contains(&"vector"), "expected its content child, got {tags:?}");

        let value: serde_json::Value =
            serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        let node = value["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|n| n["type"] == "anchoredObject")
            .unwrap();
        assert_eq!(node["data"]["x"], 10.0);
        assert_eq!(node["data"]["y"], 20.0, "paper/page-relative: y must be FINAL, not dropped");
        assert_eq!(node["data"]["width"], 30.0);
        assert_eq!(node["data"]["height"], 40.0);
        assert!(node["data"]["paragraphAnchor"].is_null());
        let anchored_to = node["data"]["anchoredToId"].as_u64().unwrap();
        let content = node["data"]["contentId"].as_u64().unwrap();
        let target = value["nodes"].as_array().unwrap().iter().find(|n| n["id"] == anchored_to).unwrap();
        assert_eq!(target["type"], "paragraph", "must point at the empty-paragraph carrier");
        let content_node =
            value["nodes"].as_array().unwrap().iter().find(|n| n["id"] == content).unwrap();
        assert_eq!(content_node["type"], "vector");
    }

    /// WHICH block it is anchored to, not merely that it is anchored to one.
    ///
    /// The two tests around this one both declare a single block, so `block_index` can only ever
    /// resolve to the one node there is — measured: replacing the lookup key with a constant `0`
    /// changed nothing and the whole crate still passed. A document anchors objects to different
    /// paragraphs, and an off-by-one there puts a seal on the wrong page with every value still
    /// well-formed. Two blocks, anchored to the SECOND, is the smallest fixture that can tell.
    #[test]
    fn an_anchored_object_names_the_block_it_was_declared_against() {
        let mut result = OfficeReadResult::default();
        for text in ["first", "second"] {
            result.blocks.push(OfficeBlock::Paragraph {
                spans: vec![Span { text: SwiftString::from(text.to_string()), ..Default::default() }],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            });
        }
        result.anchored_objects.push(office_block::OfficeAnchoredObject {
            block_index: 1,
            object: OfficeMasterObject {
                frame: CGRect::new(1.0, 2.0, 3.0, 4.0),
                content: OfficeMasterObjectContent::Text(vec![]),
            },
            paragraph_anchor: None,
        });
        let tree = ValidatedRenderTree::from_office(input(&result)).expect("must not refuse");
        let value: serde_json::Value =
            serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        let nodes = value["nodes"].as_array().unwrap();
        let anchored = nodes.iter().find(|n| n["type"] == "anchoredObject").unwrap();
        let target_id = anchored["data"]["anchoredToId"].as_u64().unwrap();
        let target = nodes.iter().find(|n| n["id"] == target_id).unwrap();
        // The carrier is the paragraph whose own text run says "second".
        let text: Vec<&str> = nodes
            .iter()
            .filter(|n| n["parentId"] == target["id"] && n["type"] == "textRun")
            .filter_map(|n| n["data"]["text"].as_str())
            .collect();
        assert_eq!(text, vec!["second"],
                   "the object was declared against block 1 and must name THAT paragraph");
    }

    /// S6-2's other half: a paragraph-relative object's `y` is NOT carried — invariant 31/81 both
    /// say a value only layout can complete must not ship a guessed number. `paragraphAnchor`
    /// carries the rule instead.
    #[test]
    fn anchored_object_with_a_paragraph_rule_carries_no_y() {
        let mut result = OfficeReadResult::default();
        result.blocks.push(OfficeBlock::Paragraph {
            spans: vec![],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        });
        result.anchored_objects.push(office_block::OfficeAnchoredObject {
            block_index: 0,
            object: OfficeMasterObject {
                frame: CGRect::new(10.0, 0.0, 30.0, 40.0),
                content: OfficeMasterObjectContent::Vector(one_path(PathSpec {
                    commands: vec![HwpPathCommand::Move(swiftshim::CGPoint { x: 0.0, y: 0.0 })],
                    stroke: None,
                    fill: None,
                    arrow_start: false,
                    arrow_end: false,
                })),
            },
            paragraph_anchor: Some(office_block::ParagraphAnchor {
                align: office_block::ParagraphAnchorAlign::Bottom,
                offset: 155.3,
            }),
        });
        let tree = ValidatedRenderTree::from_office(input(&result)).expect("must not refuse");
        let value: serde_json::Value =
            serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        let node = value["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|n| n["type"] == "anchoredObject")
            .unwrap();
        assert!(node["data"]["y"].is_null(), "paragraph-relative: y is not yet known, must not ship a placeholder");
        assert_eq!(node["data"]["paragraphAnchor"]["align"], "bottom");
        assert_eq!(node["data"]["paragraphAnchor"]["offset"], 155.3);
    }

    /// A `block_index` no section's range ever reaches (past the end of `result.blocks`) is a
    /// reader/adapter contract violation, not a silent drop.
    #[test]
    fn anchored_object_with_a_dangling_block_index_is_a_typed_error() {
        let mut result = OfficeReadResult::default();
        result.anchored_objects.push(office_block::OfficeAnchoredObject {
            block_index: 0,
            object: OfficeMasterObject {
                frame: CGRect::zero(),
                content: OfficeMasterObjectContent::Text(vec![]),
            },
            paragraph_anchor: None,
        });
        let err = ValidatedRenderTree::from_office(input(&result)).unwrap_err();
        assert_eq!(err, OfficeAdapterError::AnchoredObjectTargetMissing(0));
    }

    #[test]
    fn ids_are_deterministic_across_two_runs() {
        let mut result = OfficeReadResult::default();
        result.blocks.push(OfficeBlock::Paragraph {
            spans: vec![Span { text: SwiftString::from("x"), ..Default::default() }],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        });
        let a = ValidatedRenderTree::from_office(input(&result)).unwrap();
        let b = ValidatedRenderTree::from_office(input(&result)).unwrap();
        assert_eq!(a.encode_json().unwrap(), b.encode_json().unwrap());
    }

    #[test]
    fn a_header_and_footer_land_under_their_section_and_are_referenced_by_its_ids() {
        let mut result = OfficeReadResult::default();
        result.blocks.push(OfficeBlock::Paragraph {
            spans: vec![Span { text: SwiftString::from("body"), ..Default::default() }],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        });
        result.headers.push(office_block::OfficeHeaderFooter {
            applies_to: office_block::HeaderFooterApplicability::DefaultPages,
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![Span { text: SwiftString::from("running head"), ..Default::default() }],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            }],
            section: None,
        });
        result.footers.push(office_block::OfficeHeaderFooter {
            applies_to: office_block::HeaderFooterApplicability::DefaultPages,
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![Span { text: SwiftString::from("running foot"), ..Default::default() }],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            }],
            section: None,
        });
        let tree = ValidatedRenderTree::from_office(input(&result)).unwrap();
        let tags = tree.node_tags();
        assert!(tags.contains(&"header"));
        assert!(tags.contains(&"footer"));
        let json = String::from_utf8(tree.encode_json().unwrap()).unwrap();
        assert!(json.contains("\"headerIds\":["));
        assert!(json.contains("\"footerIds\":["));
        assert!(!json.contains("\"headerIds\":[]"));
        assert!(!json.contains("\"footerIds\":[]"));
    }

    #[test]
    fn a_footnote_node_points_at_a_flow_holding_its_blocks() {
        let mut result = OfficeReadResult::default();
        result.blocks.push(OfficeBlock::Paragraph {
            spans: vec![Span {
                text: SwiftString::from("see note"),
                footnote_ref: Some(1),
                ..Default::default()
            }],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        });
        result.footnotes.push(OfficeFootnote {
            number: 1,
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![Span { text: SwiftString::from("the note text"), ..Default::default() }],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            }],
            section: None,
        });
        let tree = ValidatedRenderTree::from_office(input(&result)).unwrap();
        assert!(tree.node_tags().contains(&"footnote"));
        let json = String::from_utf8(tree.encode_json().unwrap()).unwrap();
        assert!(json.contains("\"footnoteReferenceNumber\":1"));
        assert!(json.contains("\"number\":1"));
        assert!(json.contains("the note text"));
    }

    #[test]
    fn two_comments_with_different_string_ids_get_different_wire_ids_and_are_both_reachable() {
        let mut result = OfficeReadResult::default();
        result.comments.push(OfficeComment {
            id: SwiftString::from("c-first"),
            author: Some(SwiftString::from("Reviewer A")),
            date_iso: None,
            text: SwiftString::from("first comment"),
            number: 1,
        });
        result.comments.push(OfficeComment {
            id: SwiftString::from("c-second"),
            author: None,
            date_iso: None,
            text: SwiftString::from("second comment"),
            number: 2,
        });
        result.blocks.push(OfficeBlock::Paragraph {
            spans: vec![Span {
                text: SwiftString::from("annotated"),
                comment_ids: vec![SwiftString::from("c-first"), SwiftString::from("c-second")],
                ..Default::default()
            }],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        });
        let tree = ValidatedRenderTree::from_office(input(&result)).unwrap();
        let json = String::from_utf8(tree.encode_json().unwrap()).unwrap();
        assert!(json.contains("\"commentIds\":[1,2]"));
        assert!(json.contains("first comment"));
        assert!(json.contains("second comment"));
    }

    /// Two source comment ids likely to collide under a naive scheme (a hash, or truncation) must
    /// still resolve to two different wire ids — this adapter uses a plain counter precisely to
    /// make that impossible regardless of the strings involved.
    #[test]
    fn comment_id_assignment_is_a_counter_so_similar_strings_never_collide() {
        let mut result = OfficeReadResult::default();
        result.comments.push(OfficeComment {
            id: SwiftString::from("1"),
            author: Some(SwiftString::from("A")),
            date_iso: None,
            text: SwiftString::from("one"),
            number: 1,
        });
        result.comments.push(OfficeComment {
            id: SwiftString::from("01"),
            author: Some(SwiftString::from("B")),
            date_iso: None,
            text: SwiftString::from("zero one"),
            number: 2,
        });
        let tree = ValidatedRenderTree::from_office(input(&result)).unwrap();
        let json = String::from_utf8(tree.encode_json().unwrap()).unwrap();
        // Both the mint AND the document's own id, checked together: the mint is what a wire
        // reference resolves against, and `sourceId` is what a reader shows. A substring check
        // that pinned them adjacent used to stand here and broke the moment `sourceId` was added
        // between them — the fields matter, their order in the JSON does not.
        assert!(json.contains("\"id\":1,"), "the first comment keeps mint 1");
        assert!(json.contains("\"id\":2,"), "the second comment keeps mint 2");
        // And both source ids survive DISTINCTLY, which is this test's actual subject: "1" and
        // "01" are different identifiers that a numeric reading would collapse into one. The mint
        // makes collision impossible on the wire; carrying `sourceId` is what lets a reader still
        // tell the two comments apart by the names the document gave them.
        assert!(json.contains("\"sourceId\":\"1\""), "the document's own id for the first");
        assert!(json.contains("\"sourceId\":\"01\""), "and the different one for the second");
    }

    #[test]
    fn a_bookmark_targets_the_right_text_run_node() {
        let mut result = OfficeReadResult::default();
        result.blocks.push(OfficeBlock::Paragraph {
            spans: vec![Span {
                text: SwiftString::from("anchor here"),
                bookmarks: vec![SwiftString::from("Chapter1")],
                ..Default::default()
            }],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        });
        let tree = ValidatedRenderTree::from_office(input(&result)).unwrap();
        let json = String::from_utf8(tree.encode_json().unwrap()).unwrap();
        assert!(json.contains("\"name\":\"Chapter1\""));
        assert!(json.contains("\"bookmarkIds\":[1]"));

        // The name of this test promises the bookmark lands on the RUN. Asserting only that the
        // name and the id appear leaves that promise unchecked: pointing `targetNodeId` at the
        // paragraph instead passes both assertions above. Resolve the id and read the node it
        // names, so a relation moved one level up fails here.
        let doc: serde_json::Value = serde_json::from_str(&json).unwrap();
        let bookmarks = doc["annotations"]["bookmarks"].as_array().expect("annotations.bookmarks array");
        assert_eq!(bookmarks.len(), 1, "the fixture declares exactly one bookmark");
        let target = bookmarks[0]["targetNodeId"].as_u64().expect("targetNodeId");
        let nodes = doc["nodes"].as_array().expect("nodes array");
        let targeted = nodes
            .iter()
            .find(|n| n["id"].as_u64() == Some(target))
            .unwrap_or_else(|| panic!("bookmark targets node {target}, which is not in the tree"));
        assert_eq!(
            targeted["type"].as_str(),
            Some("textRun"),
            "the bookmark must target the text run that carries it, not its parent block"
        );
        assert_eq!(
            targeted["data"]["text"].as_str(),
            Some("anchor here"),
            "the targeted run must be the one whose span declared the bookmark"
        );
    }

    #[test]
    fn an_unresolved_comment_id_is_a_typed_error() {
        let mut result = OfficeReadResult::default();
        result.blocks.push(OfficeBlock::Paragraph {
            spans: vec![Span {
                text: SwiftString::from("annotated"),
                comment_ids: vec![SwiftString::from("nowhere")],
                ..Default::default()
            }],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        });
        let err = ValidatedRenderTree::from_office(input(&result)).unwrap_err();
        assert_eq!(err, OfficeAdapterError::UnresolvedCommentId("nowhere".to_string()));
    }

    #[test]
    fn a_header_naming_a_nonexistent_section_is_a_typed_error() {
        let mut result = OfficeReadResult::default();
        result.headers.push(office_block::OfficeHeaderFooter {
            applies_to: office_block::HeaderFooterApplicability::DefaultPages,
            blocks: vec![],
            section: Some(3),
        });
        let err = ValidatedRenderTree::from_office(input(&result)).unwrap_err();
        assert_eq!(err, OfficeAdapterError::SectionIndexMissing(3));
    }

    #[test]
    fn ids_including_headers_footnotes_and_comments_stay_identical_across_two_runs() {
        let mut result = OfficeReadResult::default();
        result.comments.push(OfficeComment {
            id: SwiftString::from("c1"),
            author: Some(SwiftString::from("A")),
            date_iso: None,
            text: SwiftString::from("hi"),
            number: 1,
        });
        result.headers.push(office_block::OfficeHeaderFooter {
            applies_to: office_block::HeaderFooterApplicability::DefaultPages,
            blocks: vec![],
            section: None,
        });
        result.footnotes.push(OfficeFootnote { number: 1, blocks: vec![], section: None });
        result.blocks.push(OfficeBlock::Paragraph {
            spans: vec![Span {
                text: SwiftString::from("x"),
                comment_ids: vec![SwiftString::from("c1")],
                bookmarks: vec![SwiftString::from("b1")],
                ..Default::default()
            }],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        });
        let a = ValidatedRenderTree::from_office(input(&result)).unwrap();
        let b = ValidatedRenderTree::from_office(input(&result)).unwrap();
        assert_eq!(a.encode_json().unwrap(), b.encode_json().unwrap());
    }

    /// A chart/SmartArt/OLE placeholder occupies real space on the page — losing its size changes
    /// the document's layout, not just its decoration. `map_single_block`'s `UnsupportedGraphic`
    /// arm used to discard `size`/`alignment` (`size: _, alignment: _`), which is what forced
    /// `office_project::project` to refuse every document carrying one. This asserts the specific
    /// non-default values a real document declares — width 42, height 17, `.right` — survive into
    /// the wire node rather than a coincidental default (`0x0`/`.natural`) that would pass even if
    /// the fields were still being thrown away and re-invented as zero.
    #[test]
    fn an_unsupported_graphics_size_and_alignment_survive_into_the_wire_node() {
        let mut result = OfficeReadResult::default();
        result.blocks.push(OfficeBlock::UnsupportedGraphic {
            label: SwiftString::from("Chart 1"),
            size: CGSize::new(42.0, 17.0),
            alignment: Some(NSTextAlignment::Right),
        });
        let tree = ValidatedRenderTree::from_office(input(&result)).unwrap();
        let value: serde_json::Value = serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        let node = value["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|n| n["type"] == "unsupported")
            .expect("an unsupported node exists");
        assert_eq!(node["data"]["reason"], "Chart 1");
        assert_eq!(node["data"]["intrinsicSize"]["width"], 42.0);
        assert_eq!(node["data"]["intrinsicSize"]["height"], 17.0);
        assert_eq!(node["data"]["alignment"], "right");
    }

    /// The `None` (source stated no alignment) case, spelled `wire::Alignment::Natural` — the same
    /// convention `Image.alignment`/`alignment_back` already use, not a second `Option<Alignment>`
    /// wrapper. Asserted separately from the `Some` case above so a regression that always writes
    /// `"natural"` regardless of input cannot hide behind the other test's non-default value.
    #[test]
    fn an_unsupported_graphic_with_no_declared_alignment_writes_natural() {
        let mut result = OfficeReadResult::default();
        result.blocks.push(OfficeBlock::UnsupportedGraphic {
            label: SwiftString::from("SmartArt"),
            size: CGSize::new(5.0, 5.0),
            alignment: None,
        });
        let tree = ValidatedRenderTree::from_office(input(&result)).unwrap();
        let value: serde_json::Value = serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        let node = value["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|n| n["type"] == "unsupported")
            .expect("an unsupported node exists");
        assert_eq!(node["data"]["alignment"], "natural");
    }

    /// A fully non-default section declaration — every one of `OfficeSectionDeclaration`'s six
    /// previously-refused fields set to a value that is NOT that field's default — survives the
    /// adapter into `wire::Section`, field for field. Asserting non-default values throughout is
    /// deliberate: a fixture that happened to use the default could not catch a regression that
    /// silently reconstructs the default instead of the declared value.
    #[test]
    fn a_section_declaring_every_new_field_survives_into_the_wire_section() {
        let section = OfficeSectionDeclaration {
            footnote_separator: Some(OfficeFootnoteSeparator {
                line_type: 3,
                line_width_pt: 0.75,
                color: Some(NSColor::srgb(0.1, 0.2, 0.3, 1.0)),
                length_pt: Some(144.0),
                margin_top_pt: 5.0,
                margin_bottom_pt: 3.0,
                note_spacing_pt: 1.5,
            }),
            page_border: Some(OfficePageBorder {
                borders: Some(EdgeBorders {
                    top: Some(BorderDecl::Drawn(BorderSide {
                        width: 2.0,
                        color: Some(NSColor::srgb(0.5, 0.5, 0.5, 1.0)),
                        style: office_block::BorderLineStyle::Dashed,
                    })),
                    left: None,
                    bottom: None,
                    right: None,
                    inside_h: None,
                    inside_v: None,
                }),
                background: Some(NSColor::srgb(0.8, 0.8, 0.9, 1.0)),
                spacing: NSEdgeInsets { top: 12.0, left: 12.0, bottom: 12.0, right: 12.0 },
                measured_from_paper: true,
            }),
            paper: None,
            hides_header: true,
            hides_footer: true,
            hides_master_page: true,
            page_number_start: Some(7),
            line_grid_pitch: Some(18.0),
            is_vertical: true,
        };
        let result = OfficeReadResult {
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            }],
            sections: vec![section],
            ..OfficeReadResult::default()
        };
        let tree = from_office(input(&result)).expect("canonicalizes");
        let value: serde_json::Value =
            serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        let node = value["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|n| n["type"] == "section")
            .expect("a section node exists");
        let data = &node["data"];
        assert_eq!(data["footnoteSeparator"]["lineType"], 3);
        assert_eq!(data["footnoteSeparator"]["lineWidthPoints"], 0.75);
        assert_eq!(data["footnoteSeparator"]["lengthPoints"], 144.0);
        assert_eq!(data["footnoteSeparator"]["marginTopPoints"], 5.0);
        assert_eq!(data["footnoteSeparator"]["marginBottomPoints"], 3.0);
        assert_eq!(data["footnoteSeparator"]["noteSpacingPoints"], 1.5);
        assert!(data["footnoteSeparator"]["color"].is_object());
        assert_eq!(data["pageBorder"]["measuredFromPaper"], true);
        assert_eq!(data["pageBorder"]["spacing"]["top"], 12.0);
        assert!(data["pageBorder"]["borders"]["top"].is_object());
        assert!(data["pageBorder"]["background"].is_object());
        assert_eq!(data["hidesHeader"], true);
        assert_eq!(data["hidesFooter"], true);
        assert_eq!(data["hidesMasterPage"], true);
        assert_eq!(data["isVertical"], true);
        assert_eq!(data["pageNumbering"]["start"], 7);
        assert_eq!(data["lineGridPoints"], 18.0);
    }

    /// A section declaring NOTHING new (every one of the six at its default/`None`) must carry
    /// those defaults through too — the opposite regression from the test above, and the one a
    /// `hides_header: true` fixture alone could not catch (defaulting `false` to `true` silently
    /// would look the same as a passing default-to-default round trip if only the non-default
    /// fixture existed).
    #[test]
    fn a_section_declaring_none_of_the_new_fields_carries_no_veto_and_no_frame() {
        let result = OfficeReadResult {
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            }],
            sections: vec![OfficeSectionDeclaration::default()],
            ..OfficeReadResult::default()
        };
        let tree = from_office(input(&result)).expect("canonicalizes");
        let value: serde_json::Value =
            serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        let node = value["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|n| n["type"] == "section")
            .expect("a section node exists");
        let data = &node["data"];
        assert!(data["footnoteSeparator"].is_null());
        assert!(data["pageBorder"].is_null());
        assert_eq!(data["hidesHeader"], false);
        assert_eq!(data["hidesFooter"], false);
        assert_eq!(data["hidesMasterPage"], false);
        assert_eq!(data["isVertical"], false);
    }

    /// A NaN in one of the footnote separator's POSITION fields must still stop canonicalization —
    /// relaxing them from `finite_nonnegative` to `is_finite` (to admit the genuine small negative
    /// values real HWP documents produce, see `validate.rs`'s own comment) must not also admit NaN.
    #[test]
    fn a_nan_footnote_separator_margin_fails_canonicalization() {
        let result = OfficeReadResult {
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            }],
            sections: vec![OfficeSectionDeclaration {
                footnote_separator: Some(OfficeFootnoteSeparator {
                    margin_top_pt: f64::NAN,
                    ..OfficeFootnoteSeparator::default()
                }),
                ..OfficeSectionDeclaration::default()
            }],
            ..OfficeReadResult::default()
        };
        assert!(
            matches!(from_office(input(&result)), Err(OfficeAdapterError::Canonicalization(_))),
            "a NaN footnote separator margin must stop canonicalization"
        );
    }

    /// A NEGATIVE footnote separator line WIDTH must still be refused — unlike the position fields
    /// above, `line_width_points` stays `finite_nonnegative` (it is a stroke width, not a margin),
    /// so this must not have been loosened alongside them.
    #[test]
    fn a_negative_footnote_separator_line_width_fails_canonicalization() {
        let result = OfficeReadResult {
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            }],
            sections: vec![OfficeSectionDeclaration {
                footnote_separator: Some(OfficeFootnoteSeparator {
                    line_width_pt: -1.0,
                    ..OfficeFootnoteSeparator::default()
                }),
                ..OfficeSectionDeclaration::default()
            }],
            ..OfficeReadResult::default()
        };
        assert!(
            matches!(from_office(input(&result)), Err(OfficeAdapterError::Canonicalization(_))),
            "a negative footnote separator line width must stop canonicalization"
        );
    }

    /// The genuine near-zero negative this repo measured on a real document (`blank2010.hwp`:
    /// `length_pt: -0.01`, `margin_top_pt: -0.01`) must NOT be refused — a regression back to
    /// `finite_nonnegative` on the position fields would silently reject that real fixture again.
    #[test]
    fn a_small_negative_footnote_separator_position_still_canonicalizes() {
        let result = OfficeReadResult {
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            }],
            sections: vec![OfficeSectionDeclaration {
                footnote_separator: Some(OfficeFootnoteSeparator {
                    length_pt: Some(-0.01),
                    margin_top_pt: -0.01,
                    ..OfficeFootnoteSeparator::default()
                }),
                ..OfficeSectionDeclaration::default()
            }],
            ..OfficeReadResult::default()
        };
        from_office(input(&result))
            .expect("a small negative footnote separator position must still canonicalize");
    }

    /// NaN in the page border's spacing must fail, the same way a NaN paragraph metric does.
    #[test]
    fn a_nan_page_border_spacing_fails_canonicalization() {
        let result = OfficeReadResult {
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            }],
            sections: vec![OfficeSectionDeclaration {
                page_border: Some(OfficePageBorder {
                    borders: None,
                    background: None,
                    spacing: NSEdgeInsets { top: f64::NAN, left: 0.0, bottom: 0.0, right: 0.0 },
                    measured_from_paper: false,
                }),
                ..OfficeSectionDeclaration::default()
            }],
            ..OfficeReadResult::default()
        };
        assert!(
            matches!(from_office(input(&result)), Err(OfficeAdapterError::Canonicalization(_))),
            "a NaN page border spacing must stop canonicalization"
        );
    }

    /// The tree's own record of how many sections the SOURCE declared
    /// (`wire::Document.declared_section_count`) — `0` when the source declared none at all (the
    /// synthetic single-section fallback docx/odt always build), and the real count otherwise. This
    /// is what `office_project::project` reads to tell that ambiguity apart; a regression that
    /// always writes `0`, or always writes `sections.len().max(1)`, breaks it silently unless this
    /// field is asserted directly.
    #[test]
    fn declared_section_count_reflects_zero_and_nonzero_source_declarations() {
        let no_sections = OfficeReadResult {
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            }],
            ..OfficeReadResult::default()
        };
        let tree = from_office(input(&no_sections)).expect("canonicalizes");
        let value: serde_json::Value =
            serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        assert_eq!(value["document"]["declaredSectionCount"], 0);

        let one_section = OfficeReadResult {
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            }],
            sections: vec![OfficeSectionDeclaration::default()],
            ..OfficeReadResult::default()
        };
        let tree = from_office(input(&one_section)).expect("canonicalizes");
        let value: serde_json::Value =
            serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        assert_eq!(value["document"]["declaredSectionCount"], 1);
    }
}
