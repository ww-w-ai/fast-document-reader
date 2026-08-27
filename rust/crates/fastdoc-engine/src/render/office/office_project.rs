//! Second producer of schema-v4 JSON — from the tree, never from the reader's own answer.
//!
//! `project` walks a `ValidatedRenderTree` and rebuilds the same flat `OfficeBlock` sequence and
//! side tables `office_export::to_json(&OfficeReadResult)` emits, WITHOUT importing
//! `OfficeReadResult` — the compiler, not a comment, is what stops this projector from copying the
//! reader's own answer instead of deriving it from the tree. Where the tree cannot honestly supply
//! a field the envelope declares, this returns `ProjectionError::Field` naming it, rather than
//! guessing a default that would pass the oracle once, on the fixture where the field happened to
//! be empty, and mislead every fixture after it.
//!
//! Known, deliberate exceptions to that rule — narrow, named here rather than silently defaulted,
//! and reported by the sprint's evidence file rather than hidden:
//! - `sections` / `section_start_blocks`: emitted as `[]` for a tree with exactly one `Section`
//!   node, which cannot tell "the source declared no sections" (the synthetic single-section case
//!   docx/odt always build) from "the source declared exactly one, with nothing this projector can
//!   otherwise see" apart — both build the identical tree. A tree with MORE than one `Section` node
//!   carries no such ambiguity (`office_adapter::from_office`'s own `section_count =
//!   result.sections.len().max(1)` proves the source declared that many), so `project` walks every
//!   section in order and honestly reconstructs `blocks`/`headers`/`footers`/`footnotes` across all
//!   of them — but still refuses `ProjectionError::Field("sections")` there rather than guess: five
//!   of `OfficeSectionDeclaration`'s six fields (`footnote_separator`, `page_border`,
//!   `hides_header`, `hides_footer`, `hides_master_page`, `is_vertical`) have no home anywhere in
//!   `wire::Section` to reconstruct them from.
//! - a span's own `comment_ids`: a wire `TextRun.commentIds` entry names a comment by a wire id
//!   this adapter minted, and `office_adapter::Ctx.comment_id_by_source` — the map back to the
//!   source's own opaque id string that resolved it — is adapter-internal build state, never
//!   serialized into the wire tree. Any run carrying one returns
//!   `ProjectionError::Field("span.comment_ids")`, sending the WHOLE document back to
//!   `office_export::to_json(&OfficeReadResult)`. `annotations.comments` itself IS projected
//!   (`comments`, below) whenever every span's `comment_ids` is empty — an orphan comment (no
//!   in-body range at all) never sets one, so it reaches here and is listed. `OfficeComment.id` is
//!   read from `wire::Comment.source_id`, which carries the document's own opaque id (docx's
//!   `w:id`, an odt `office:name`) unchanged. That field was added because the alternatives were
//!   both dishonest: `wire::Comment.id` is only ever this adapter's fresh mint, so stamping it in
//!   would report a number the source never wrote, and leaving the field empty asserts the
//!   document gave its comment no id when it plainly did. `OfficeComment.number` (the review pane's display order) is NOT lossy —
//!   both readers assign it 1-indexed in `OfficeReadResult.comments`'s own order
//!   (`docx_reader::parse_comments` sorts its result by it; `OdtReader`'s counter builds that array
//!   in push order), so `annotations.comments` sorted by wire id reconstructs it exactly.
//! - A table's filler cells (`office_adapter::map_table`'s pass-2 padding) are indistinguishable,
//!   once in the tree, from a genuinely empty, unstyled 1x1 cell the source actually authored —
//!   both cases now roundtrip identically, and the projection includes both.

use std::collections::{BTreeSet, HashMap};

use crate::render::office::hwp_shape_path::{
    PathCommand as HwpPathCommand, PathSpec, VectorGraphic,
};
use crate::render::office::office_block::{
    self as ob, BorderDecl, BorderSide, Cell, CellDiagonal, CellVAlign, EdgeBorders, EdgePadding,
    ListNumbering, OfficeBlock, OfficeComment, OfficeFootnote, OfficeFormControl,
    OfficeHeaderFooter, OfficePageNumberRestart, ParagraphFormat, RectEdge, Span, TableFormat,
};
use crate::render::render_tree::wire;
use crate::render::render_tree::ValidatedRenderTree;
use swiftshim::{CGPoint, CGSize, Data, NSColor, NSTextAlignment, SwiftString};

/// What this projector could not honestly derive from the tree — a named field, never a guess.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProjectionError {
    /// A field the schema-v4 envelope declares that the wire tree has no honest way to supply.
    Field(String),
    /// The tree itself is not the shape this projector assumes (a dangling node id, an unexpected
    /// payload where a specific one is required) — should not happen for a canonically validated
    /// tree, but is never swallowed.
    Malformed(String),
}

impl ProjectionError {
    pub fn description(&self) -> String {
        match self {
            ProjectionError::Field(name) => {
                format!("the tree cannot honestly supply schema-v4 field `{name}`")
            }
            ProjectionError::Malformed(detail) => format!("tree shape assumption violated: {detail}"),
        }
    }
}

/// The document, projected from its `ValidatedRenderTree` alone. Deliberately does not accept or
/// mention `OfficeReadResult` anywhere in its signature or body — see this module's own doc.
pub fn project(tree: &ValidatedRenderTree) -> Result<String, ProjectionError> {
    let bytes = tree
        .encode_json()
        .map_err(|e| ProjectionError::Malformed(format!("tree did not re-encode: {e:?}")))?;
    let envelope: wire::EnvelopeV1 = serde_json::from_slice(&bytes)
        .map_err(|e| ProjectionError::Malformed(format!("tree JSON did not decode: {e}")))?;

    let by_id: HashMap<u64, wire::Node> = envelope.nodes.into_iter().map(|n| (n.id, n)).collect();
    let resources: HashMap<u64, wire::Resource> =
        envelope.resources.into_iter().map(|r| (r.id, r)).collect();
    // Bookmark NAMES, not ids — `Span.bookmarks` (`office_block::Span`) is a list of names, the
    // same vocabulary `office_adapter::resolve_bookmark` minted these wire ids FROM, so this
    // reverse lookup loses nothing: `wire::Bookmark.name` already IS the source's own bookmark
    // name (unlike a wire comment id, which is a fresh mint with no source string anywhere in the
    // tree — see `Projector::comments` below for why that one stays lossy).
    let bookmark_names: HashMap<u64, String> =
        envelope.annotations.bookmarks.iter().map(|b| (b.id, b.name.clone())).collect();
    let mut proj = Projector {
        by_id,
        resources,
        images: HashMap::new(),
        pictures_declared_without_bytes: std::collections::HashSet::new(),
        vector_graphics: HashMap::new(),
        keep_with_next: BTreeSet::new(),
        page_break: BTreeSet::new(),
        hide_page_number: BTreeSet::new(),
        restart: Vec::new(),
        node_index: HashMap::new(),
        bookmark_names,
    };

    let root_id = envelope.document.root_node_id;
    let root = proj.get(root_id)?.clone();
    if root.children.is_empty() {
        return Err(ProjectionError::Malformed("document has no section children".to_string()));
    }
    // `section_count = result.sections.len().max(1)` is how `office_adapter::from_office` decides
    // how many `Section` nodes to build (see that function's own doc), so more than one here is
    // proof the source declared more than one — never a synthetic document-wide fallback, which
    // only ever produces exactly one. See this module's own doc for what that certainty buys and
    // costs: `blocks`/`headers`/`footers`/`footnotes` are honestly reconstructable by walking every
    // section in order (below); the per-section DECLARATIONS (`sections`, and the block-index list
    // coupled to it one-for-one, `section_start_blocks`) are not, and are refused rather than
    // guessed — see where `is_multi_section` is used, near the end of this function.
    let is_multi_section = root.children.len() > 1;

    let mut blocks: Vec<OfficeBlock> = Vec::new();
    let mut headers: Vec<OfficeHeaderFooter> = Vec::new();
    let mut footers: Vec<OfficeHeaderFooter> = Vec::new();
    let mut footnotes: Vec<OfficeFootnote> = Vec::new();
    let mut anchored_objects: Vec<ob::OfficeAnchoredObject> = Vec::new();
    let mut master_pages: Vec<ob::OfficeMasterPage> = Vec::new();
    let mut first_section: Option<wire::Section> = None;

    for (section_index, &section_id) in root.children.iter().enumerate() {
        let section_node = proj.get(section_id)?.clone();
        let section = match &section_node.payload {
            wire::NodePayload::Section(s) => s.clone(),
            other => {
                return Err(ProjectionError::Malformed(format!(
                    "document child was not a section: {other:?}"
                )))
            }
        };
        if first_section.is_none() {
            first_section = Some(section);
        }

        let mut flow_id: Option<u64> = None;
        // Resolved AFTER `map_blocks` below, once `node_index` actually names this section's own
        // block node ids — an `AnchoredObject`'s `anchoredToId` cannot be turned into a
        // `block_index` any earlier than that.
        let mut pending_anchored: Vec<wire::AnchoredObject> = Vec::new();
        for &child_id in &section_node.children {
            let child = proj.get(child_id)?.clone();
            match &child.payload {
                wire::NodePayload::Flow(_) => flow_id = Some(child_id),
                wire::NodePayload::Header(hf) => {
                    headers.push(proj.header_footer(&child, hf.clone())?)
                }
                wire::NodePayload::Footer(hf) => {
                    footers.push(proj.header_footer(&child, hf.clone())?)
                }
                wire::NodePayload::Footnote(fnote) => {
                    footnotes.push(proj.footnote(&child, fnote.clone())?)
                }
                wire::NodePayload::AnchoredObject(ao) => pending_anchored.push(ao.clone()),
                wire::NodePayload::MasterPage(mp) => {
                    master_pages.push(proj.master_page(mp.clone(), section_index as i64)?)
                }
                other => {
                    return Err(ProjectionError::Malformed(format!(
                        "unexpected section child payload: {other:?}"
                    )))
                }
            }
        }
        let flow_id = flow_id
            .ok_or_else(|| ProjectionError::Malformed("section has no flow child".to_string()))?;
        let flow_children = proj.get(flow_id)?.children.clone();

        let section_blocks = proj.map_blocks(&flow_children, blocks.len() as i64)?;
        blocks.extend(section_blocks);

        for ao in pending_anchored {
            anchored_objects.push(proj.anchored_object(ao)?);
        }
    }
    let section = first_section
        .ok_or_else(|| ProjectionError::Malformed("no section was found".to_string()))?;

    // Read, not reconstructed. The tree carries the document's own default on the document, and
    // each run carries only the size it declared, so there is nothing left to infer here. This
    // used to take the most COMMON run size as the default and then null every span matching it —
    // right on a long document, wrong on every short one, and wrong in both directions at once
    // (invariant 107). Deleting that guess is the whole point of the field above it.
    let default_body_font_size = envelope.document.default_body_font_size;

    let (
        page_content_width,
        page_margin_left,
        page_margin_right,
        page_content_height,
        page_margin_top,
        page_margin_bottom,
        page_header_distance,
        page_footer_distance,
    ) = match &section.paper {
        Some(paper) => (
            Some(paper.width_points - paper.margins.left - paper.margins.right),
            Some(paper.margins.left),
            Some(paper.margins.right),
            Some(paper.height_points - paper.margins.top - paper.margins.bottom),
            Some(paper.margins.top),
            Some(paper.margins.bottom),
            paper.header_distance_points,
            paper.footer_distance_points,
        ),
        None => (None, None, None, None, None, None, None, None),
    };

    // Every comment reaching this point is an orphan: a span carrying `comment_ids` makes
    // `convert_run` bail with `ProjectionError::Field("span.comment_ids")` before any block is
    // even finished, which sends the WHOLE document back to
    // `office_export::to_json(&OfficeReadResult)` — this module's own top-of-file doc names why (a
    // span's `comment_ids` cannot roundtrip through the wire tree). `id` is the one
    // `OfficeComment` field this reconstruction cannot honestly restore: it is meant to be the
    // DOCUMENT's own opaque id (docx's `w:id` attribute, an odt `office:name` — the shipped reader
    // preserves it verbatim), and the wire tree never carries that string anywhere — only
    // `office_adapter::Ctx.comment_id_by_source`, adapter-internal build state, ever held it.
    // `wire::Comment.id` is a fresh sequential mint with no document meaning of its own; stamping
    // it in here (even stringified) would be inventing a fact the source never stated, exactly the
    // failure shape invariant 108 names — a specific value written where "unknown" belongs. Left
    // empty instead, deliberately, so a caller comparing against the real source id sees a visible
    // gap rather than a plausible-looking wrong answer. Closing this gap for real needs
    // `wire::Comment` to carry the source's own id string, which is `office_adapter.rs`'s fix, not
    // this projector's. `number` has no such gap: both readers assign it 1-indexed in this exact
    // array's own order (`docx_reader::parse_comments` sorts its result by it; `OdtReader`'s
    // counter builds `result.comments` in that same push order), so this array's position after
    // sorting by wire id IS the display number, not a guess.
    let mut wire_comments = envelope.annotations.comments.clone();
    wire_comments.sort_by_key(|c| c.id);
    let comments: Vec<OfficeComment> = wire_comments
        .into_iter()
        .enumerate()
        .map(|(i, c)| OfficeComment {
            id: SwiftString::from(c.source_id),
            author: if c.author.is_empty() { None } else { Some(SwiftString::from(c.author)) },
            date_iso: c.date_iso.map(SwiftString::from),
            text: SwiftString::from(c.text),
            number: (i as i64) + 1,
        })
        .collect();

    let mut result = serde_json::Map::new();
    result.insert("v".to_string(), serde_json::Value::from(4u32));
    result.insert("blocks".to_string(), to_value(&blocks)?);
    result.insert("comments".to_string(), to_value(&comments)?);
    result.insert("images".to_string(), to_value(&proj.images)?);
    result.insert(
        "pictures_declared_without_bytes".to_string(),
        to_value(&proj.pictures_declared_without_bytes)?,
    );
    result.insert("vector_graphics".to_string(), to_value(&proj.vector_graphics)?);
    result.insert(
        "default_body_font_size".to_string(),
        serde_json::Value::from(default_body_font_size),
    );
    result.insert(
        "declared_faces".to_string(),
        to_value(&envelope.document.declared_faces)?,
    );
    insert_opt(&mut result, "page_content_width", page_content_width);
    insert_opt(&mut result, "page_margin_left", page_margin_left);
    insert_opt(&mut result, "page_margin_right", page_margin_right);
    insert_opt(&mut result, "page_content_height", page_content_height);
    insert_opt(&mut result, "page_margin_top", page_margin_top);
    insert_opt(&mut result, "page_margin_bottom", page_margin_bottom);
    insert_opt(&mut result, "page_header_distance", page_header_distance);
    insert_opt(&mut result, "page_footer_distance", page_footer_distance);
    result.insert("headers".to_string(), to_value(&headers)?);
    result.insert("footers".to_string(), to_value(&footers)?);
    result.insert("footnotes".to_string(), to_value(&footnotes)?);
    result.insert("master_pages".to_string(), to_value(&master_pages)?);
    // A tree with exactly one `Section` node is genuinely ambiguous (see this module's own doc):
    // it cannot tell "the source declared no sections" from "declared exactly one, with nothing
    // else this projector can see" apart, so `[]` is the accepted exception there. More than one
    // `Section` node carries no such ambiguity — `is_multi_section` above is proof the source
    // declared that many — so guessing `[]` there would not be resolving an ambiguity, it would be
    // reporting zero declared sections for a document that named several. Refused instead: five of
    // `OfficeSectionDeclaration`'s six fields (`footnote_separator`, `page_border`, `hides_header`,
    // `hides_footer`, `hides_master_page`, `is_vertical`) have no home anywhere in `wire::Section`
    // (`wire.rs`'s own field list) to reconstruct them from.
    if is_multi_section {
        return Err(ProjectionError::Field("sections".to_string()));
    }
    result.insert("sections".to_string(), to_value(&Vec::<ob::OfficeSectionDeclaration>::new())?);
    result.insert("anchored_objects".to_string(), to_value(&anchored_objects)?);
    // Same ambiguity as `sections` immediately above, for the single-section case: `section_start_blocks`
    // is coupled to `sections` one-for-one (`OfficeReadResult`'s own field docs — "indexed the same
    // way `section_start_blocks` is"), so a tree that cannot tell whether ANY section was declared
    // cannot honestly say where one starts either. `[]` here is the same accepted exception, not an
    // independent guess.
    result.insert("section_start_blocks".to_string(), to_value(&Vec::<i64>::new())?);
    result.insert(
        "keep_with_next_blocks".to_string(),
        to_value(&proj.keep_with_next.into_iter().collect::<Vec<_>>())?,
    );
    result.insert(
        "page_break_blocks".to_string(),
        to_value(&proj.page_break.into_iter().collect::<Vec<_>>())?,
    );
    result.insert(
        "hide_page_number_blocks".to_string(),
        to_value(&proj.hide_page_number.into_iter().collect::<Vec<_>>())?,
    );
    result.insert("page_number_restart_blocks".to_string(), to_value(&proj.restart)?);
    insert_opt(&mut result, "line_grid_pitch", section.line_grid_points);

    Ok(serde_json::Value::Object(result).to_string())
}

fn to_value<T: serde::Serialize>(v: &T) -> Result<serde_json::Value, ProjectionError> {
    serde_json::to_value(v).map_err(|e| ProjectionError::Malformed(format!("re-encode failed: {e}")))
}

fn insert_opt(map: &mut serde_json::Map<String, serde_json::Value>, key: &str, v: Option<f64>) {
    if let Some(v) = v {
        map.insert(key.to_string(), serde_json::Value::from(v));
    }
}




struct Projector {
    by_id: HashMap<u64, wire::Node>,
    resources: HashMap<u64, wire::Resource>,
    images: HashMap<SwiftString, Data>,
    /// `OfficeReadResult.pictures_declared_without_bytes`'s reverse — every `.image(id:)` key
    /// `map_image` reconstructed from `wire::Image.source_key` because `resource_id` was `None`.
    pictures_declared_without_bytes: std::collections::HashSet<SwiftString>,
    vector_graphics: HashMap<SwiftString, VectorGraphic>,
    keep_with_next: BTreeSet<i64>,
    page_break: BTreeSet<i64>,
    hide_page_number: BTreeSet<i64>,
    restart: Vec<OfficePageNumberRestart>,
    /// Node id -> its own position in the reconstructed `blocks`/`OfficeAnchoredObject.block_index`
    /// index space, recorded as each top-level flow block is mapped (`map_single_block`/
    /// `map_list_item`) — S6-2's reverse of `office_adapter::Ctx.block_node_id`. An anchored
    /// object's `anchoredToId` (`wire::AnchoredObject`) is looked up here to reconstruct
    /// `block_index`.
    node_index: HashMap<u64, i64>,
    /// Wire bookmark id -> the source's own bookmark NAME (`wire::Bookmark.name`) — see this
    /// field's own construction in `project` for why this round-trips honestly while comment ids
    /// (below) do not.
    bookmark_names: HashMap<u64, String>,
}

impl Projector {
    fn get(&self, id: u64) -> Result<&wire::Node, ProjectionError> {
        self.by_id
            .get(&id)
            .ok_or_else(|| ProjectionError::Malformed(format!("dangling node id {id}")))
    }

    /// `TextRun.bookmarkIds` entry -> the source's own bookmark NAME, via `self.bookmark_names`
    /// (built once, up front, from `annotations.bookmarks` — see `project`'s own comment). A run
    /// naming a bookmark id `annotations.bookmarks` does not contain would be a malformed tree,
    /// never a silently dropped bookmark.
    fn resolve_bookmark_name(&self, id: u64) -> Result<SwiftString, ProjectionError> {
        self.bookmark_names.get(&id).map(|name| SwiftString::from(name.clone())).ok_or_else(|| {
            ProjectionError::Malformed(format!(
                "textRun.bookmarkIds named bookmark {id}, which annotations.bookmarks does not contain"
            ))
        })
    }

    fn header_footer(
        &mut self,
        node: &wire::Node,
        hf: wire::HeaderFooter,
    ) -> Result<OfficeHeaderFooter, ProjectionError> {
        let flow_id = *node
            .children
            .first()
            .ok_or_else(|| ProjectionError::Malformed("header/footer has no flow".to_string()))?;
        let flow_children = self.get(flow_id)?.children.clone();
        let blocks = self.map_blocks(&flow_children, 0)?;
        Ok(OfficeHeaderFooter {
            applies_to: convert_hf_applicability(hf.applies_to),
            blocks,
            section: None,
        })
    }

    fn footnote(
        &mut self,
        node: &wire::Node,
        fnote: wire::Footnote,
    ) -> Result<OfficeFootnote, ProjectionError> {
        let flow_id = *node
            .children
            .first()
            .ok_or_else(|| ProjectionError::Malformed("footnote has no flow".to_string()))?;
        let flow_children = self.get(flow_id)?.children.clone();
        let blocks = self.map_blocks(&flow_children, 0)?;
        Ok(OfficeFootnote { number: fnote.number as i64, blocks, section: None })
    }

    /// S6-2's reverse of `office_adapter::build_anchored_object_node`: `anchoredToId` -> the
    /// carrier's own position in `blocks` (already recorded in `node_index` by the time this
    /// runs — see `project`'s per-section ordering), `contentId` -> an `OfficeMasterObject`
    /// (`anchored_content`, below), and exactly one of `y`/`paragraphAnchor` back into
    /// `paragraph_anchor` — never both, never neither (the wire shape's own invariant).
    fn anchored_object(
        &mut self,
        ao: wire::AnchoredObject,
    ) -> Result<ob::OfficeAnchoredObject, ProjectionError> {
        let block_index = *self.node_index.get(&ao.anchored_to_id).ok_or_else(|| {
            ProjectionError::Malformed(format!(
                "anchoredObject.anchoredToId {} names no block in this document's own flow",
                ao.anchored_to_id
            ))
        })?;
        let y = ao.y.unwrap_or(0.0);
        let paragraph_anchor = ao.paragraph_anchor.map(|pa| ob::ParagraphAnchor {
            align: convert_paragraph_anchor_align_back(pa.align),
            offset: pa.offset,
        });
        let content = self.anchored_content(ao.content_id)?;
        Ok(ob::OfficeAnchoredObject {
            block_index,
            object: ob::OfficeMasterObject {
                frame: swiftshim::CGRect::new(ao.x, y, ao.width, ao.height),
                content,
            },
            paragraph_anchor,
        })
    }

    /// The content half — an existing `Image`/`Vector`/`Flow` node, read back into
    /// `OfficeMasterObjectContent` the same shape `office_adapter::map_anchored_content` built it
    /// from. Unlike `map_image`/`map_vector` (ordinary in-flow pictures), NO `source_key` is
    /// required: an anchored object's `NSImage`/vector paths never had a document-declared string
    /// id to round-trip, only decoded bytes/paths (`register_resource_bytes`'s own doc).
    /// S6-4's reverse of `office_adapter::background_resource`: a resource id -> its decoded
    /// bytes, the same base64/`NSImage::fromData` round trip `anchored_content`'s `Image` arm uses
    /// (kept as a separate method — a background fill has no content NODE of its own to route
    /// through, only a raw resource reference on `TableStyle`/`TableCell`).
    fn background_resource(&mut self, resource_id: u64) -> Result<swiftshim::NSImage, ProjectionError> {
        let resource = self.resources.get(&resource_id).cloned().ok_or_else(|| {
            ProjectionError::Malformed(format!("background fill referenced missing resource {resource_id}"))
        })?;
        use base64::Engine;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(&resource.bytes_base64)
            .map_err(|e| ProjectionError::Malformed(format!("resource bytes did not decode: {e}")))?;
        swiftshim::NSImage::fromData(&Data(bytes)).ok_or_else(|| {
            ProjectionError::Malformed("background fill bytes did not decode as an image".to_string())
        })
    }

    fn anchored_content(
        &mut self,
        content_id: u64,
    ) -> Result<ob::OfficeMasterObjectContent, ProjectionError> {
        let node = self.get(content_id)?.clone();
        match &node.payload {
            wire::NodePayload::Image(img) => {
                // An anchored object's `Image` always carries host-painted bytes
                // (`office_adapter::map_anchored_content` always registers them, never a
                // declared-without-bytes key), so `None` here means the tree itself is malformed,
                // not a document fact — the same reasoning `wire::Image.source_key`'s doc gives
                // for why this arm needs no `source_key`.
                let resource_id = img.resource_id.ok_or_else(|| {
                    ProjectionError::Malformed("anchored image carries no resource id".to_string())
                })?;
                let resource = self.resources.get(&resource_id).cloned().ok_or_else(|| {
                    ProjectionError::Malformed(format!(
                        "anchored image referenced missing resource {resource_id}"
                    ))
                })?;
                use base64::Engine;
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(&resource.bytes_base64)
                    .map_err(|e| ProjectionError::Malformed(format!("resource bytes did not decode: {e}")))?;
                let image = swiftshim::NSImage::fromData(&Data(bytes)).ok_or_else(|| {
                    ProjectionError::Malformed("anchored image bytes did not decode as an image".to_string())
                })?;
                Ok(ob::OfficeMasterObjectContent::Image(image))
            }
            wire::NodePayload::Vector(v) => {
                let paths: Vec<PathSpec> = v.paths.iter().map(convert_vector_path_back).collect();
                Ok(ob::OfficeMasterObjectContent::Vector(VectorGraphic {
                    paths,
                    size: CGSize::new(v.intrinsic_size.width, v.intrinsic_size.height),
                }))
            }
            wire::NodePayload::Flow(_) => {
                let blocks = self.map_blocks(&node.children, 0)?;
                Ok(ob::OfficeMasterObjectContent::Text(blocks))
            }
            other => Err(ProjectionError::Malformed(format!(
                "anchoredObject.contentId named an unexpected node payload: {other:?}"
            ))),
        }
    }

    /// S6-3's reverse of `office_adapter::build_master_page_node`: every `objectIds` child ->
    /// `master_object` (below), `section` from this node's own position among the document's
    /// `Section` children — the parent/child EDGE the tree already states, never a wire field of
    /// its own (the adapter's own choice, `wire::MasterPage`'s doc).
    fn master_page(
        &mut self,
        mp: wire::MasterPage,
        section_index: i64,
    ) -> Result<ob::OfficeMasterPage, ProjectionError> {
        let objects = mp
            .object_ids
            .iter()
            .map(|&id| self.master_object(id))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(ob::OfficeMasterPage {
            section: section_index,
            applies_to: convert_hf_applicability(mp.applies_to),
            objects,
        })
    }

    /// `MasterPageObject` -> `OfficeMasterObject`: `y` is read straight back (never a placeholder
    /// here — `wire::MasterPageObject`'s own doc, invariant 78), and `content_id` reuses
    /// `anchored_content` unchanged, since a master object's content is the identical `Image`/
    /// `Vector`/`Flow` vocabulary an anchored object's is.
    fn master_object(&mut self, object_id: u64) -> Result<ob::OfficeMasterObject, ProjectionError> {
        let node = self.get(object_id)?.clone();
        let wire::NodePayload::MasterPageObject(obj) = &node.payload else {
            return Err(ProjectionError::Malformed(format!(
                "masterPage.objectIds named an unexpected node payload: {:?}",
                node.payload
            )));
        };
        let content = self.anchored_content(obj.content_id)?;
        Ok(ob::OfficeMasterObject {
            frame: swiftshim::CGRect::new(obj.x, obj.y, obj.width, obj.height),
            content,
        })
    }

    /// Walks a run of sibling node ids (a flow's own children) into `OfficeBlock`s, unwrapping the
    /// wire tree's synthetic `List` wrapper back into the flat `ListItem` blocks the office model
    /// uses (see `office_adapter::map_list_group`'s own doc: office format never nests items under
    /// a container block). `base_index` is this slice's own offset into the reconstructed flat
    /// `blocks` array — matching `office_adapter::map_blocks`'s own re-keying, so
    /// `keep_with_next`/`page_break`/`hide_page_number`/`restart` land on the same indices.
    fn map_blocks(&mut self, ids: &[u64], base_index: i64) -> Result<Vec<OfficeBlock>, ProjectionError> {
        let mut out = Vec::with_capacity(ids.len());
        let mut i: i64 = base_index;
        for &id in ids {
            let node = self.get(id)?.clone();
            match &node.payload {
                wire::NodePayload::List(_) => {
                    for &item_id in &node.children {
                        let item_node = self.get(item_id)?.clone();
                        let wire::NodePayload::ListItem(li) = &item_node.payload else {
                            return Err(ProjectionError::Malformed(
                                "List child was not a ListItem".to_string(),
                            ));
                        };
                        out.push(self.map_list_item(&item_node.children, li.clone(), i)?);
                        self.node_index.insert(item_id, i);
                        i += 1;
                    }
                }
                _ => {
                    out.push(self.map_single_block(&node, i)?);
                    self.node_index.insert(id, i);
                    i += 1;
                }
            }
        }
        Ok(out)
    }

    fn record_pagination(&mut self, index: i64, p: &wire::ParagraphPagination) {
        if p.keep_with_next {
            self.keep_with_next.insert(index);
        }
        if p.page_break_before {
            self.page_break.insert(index);
        }
        if p.hides_page_number {
            self.hide_page_number.insert(index);
        }
        if let Some(n) = p.page_number_restart {
            self.restart.push(OfficePageNumberRestart { block: index, number: n });
        }
    }

    fn map_spans(&mut self, ids: &[u64]) -> Result<Vec<Span>, ProjectionError> {
        let mut out = Vec::with_capacity(ids.len());
        for &id in ids {
            let node = self.get(id)?.clone();
            let wire::NodePayload::TextRun(run) = &node.payload else {
                return Err(ProjectionError::Malformed("expected a text run".to_string()));
            };
            out.push(self.convert_run(run.clone())?);
        }
        Ok(out)
    }

    fn convert_run(&mut self, run: wire::TextRun) -> Result<Span, ProjectionError> {
        let column_layout = run.column_flow.as_ref().map(column_layout_back);
        if !run.comment_ids.is_empty() {
            return Err(ProjectionError::Field("span.comment_ids".to_string()));
        }
        let bookmarks = run
            .bookmark_ids
            .iter()
            .map(|&id| self.resolve_bookmark_name(id))
            .collect::<Result<Vec<_>, _>>()?;

        let underline = run.style.underline.is_some();
        let underline_style = run
            .style
            .underline
            .map(convert_underline_style_back)
            .unwrap_or_default();
        let (superscript, subscripted) = match run.style.vertical_position {
            wire::VerticalPosition::Superscript => (true, false),
            wire::VerticalPosition::Subscript => (false, true),
            wire::VerticalPosition::Normal => (false, false),
        };
        Ok(Span {
            text: SwiftString::from(run.text),
            bold: run.style.bold,
            italic: run.style.italic,
            underline,
            underline_style,
            code: run.style.inline_code,
            caps: run.style.caps,
            small_caps: run.style.small_caps,
            link: run.link.map(SwiftString::from),
            strikethrough: run.style.strike,
            superscript,
            footnote_ref: run.footnote_reference_number,
            form_control: run.form_control.map(|fc| OfficeFormControl {
                kind: convert_form_control_kind_back(fc.kind),
                caption: SwiftString::from(fc.caption),
                text: SwiftString::from(fc.text),
                value: fc.value,
                enabled: fc.enabled,
            }),
            column_layout,
            subscripted,
            rtl: matches!(run.direction, Some(wire::Direction::RightToLeft)),
            bookmarks,
            comment_ids: vec![],
            text_color: run.style.foreground.map(convert_color_back),
            highlight_color: run.style.background.map(convert_color_back),
            letter_spacing_percent: run.style.letter_spacing_percent,
            baseline_offset_percent: run.style.baseline_offset_percent,
            underline_color: run.style.underline_color.map(convert_color_back),
            strikethrough_color: run.style.strikethrough_color.map(convert_color_back),
            font_size: run.style.font_size_points,
            font_name: run.style.declared_font_name.map(SwiftString::from),
            resolved_font_descriptor: None,
            page_number_field: run.page_number_field.map(convert_page_number_field_back),
        })
    }

    fn map_list_item(
        &mut self,
        span_ids: &[u64],
        li: wire::ListItem,
        index: i64,
    ) -> Result<OfficeBlock, ProjectionError> {
        self.record_pagination(index, &li.pagination);
        let spans = self.map_spans(span_ids)?;
        let numbering = li.numbering.map(|n| ListNumbering {
            glyphs: convert_glyphs_back(n.glyphs),
            start_number: n.start_number,
        });
        let (format, alignment, rtl) = paragraph_format_back(&li.style);
        Ok(OfficeBlock::ListItem {
            level: li.level as i64 - 1,
            ordered: li.ordered,
            spans,
            marker: li.marker.map(SwiftString::from),
            rtl,
            alignment,
            tab_stops: convert_tab_stops_back(&li.tab_stops),
            format,
            numbering,
        })
    }

    fn map_single_block(&mut self, node: &wire::Node, index: i64) -> Result<OfficeBlock, ProjectionError> {
        match &node.payload {
            wire::NodePayload::Heading(h) => {
                self.record_pagination(index, &h.pagination);
                let spans = self.map_spans(&node.children)?;
                let (format, alignment, rtl) = paragraph_format_back(&h.style);
                Ok(OfficeBlock::Heading {
                    level: h.level,
                    spans,
                    rtl,
                    alignment,
                    tab_stops: convert_tab_stops_back(&h.tab_stops),
                    format,
                })
            }
            wire::NodePayload::Paragraph(p) => {
                self.record_pagination(index, &p.pagination);
                let spans = self.map_spans(&node.children)?;
                let (format, alignment, rtl) = paragraph_format_back(&p.style);
                Ok(OfficeBlock::Paragraph {
                    spans,
                    rtl,
                    alignment,
                    tab_stops: convert_tab_stops_back(&p.tab_stops),
                    format,
                })
            }
            wire::NodePayload::Table(t) => self.map_table(node, t.clone()),
            wire::NodePayload::Image(img) => self.map_image(img.clone()),
            wire::NodePayload::Vector(v) => self.map_vector(v.clone()),
            wire::NodePayload::Formula(f) => {
                Ok(OfficeBlock::Formula { latex: SwiftString::from(f.source.clone()) })
            }
            wire::NodePayload::Unsupported(_) => {
                Err(ProjectionError::Field("unsupportedGraphic.size".to_string()))
            }
            other => Err(ProjectionError::Malformed(format!("unexpected flow child: {other:?}"))),
        }
    }

    fn map_image(&mut self, img: wire::Image) -> Result<OfficeBlock, ProjectionError> {
        let alignment = alignment_back(img.alignment);
        // `resource_id: None` is `wire::Image`'s own positive statement — the document declared
        // this picture and no bytes back it (`office_adapter::Ctx::map_image`'s doc). There is no
        // `Resource` row to recover a key from in that case, which is exactly why
        // `office_adapter` always sets `source_key` regardless of whether a resource resolved:
        // this arm is the honest reconstruction, not a guess, and the id is recorded in
        // `pictures_declared_without_bytes` so the projected JSON carries the SAME fact the reader's
        // own `OfficeReadResult` does.
        let Some(resource_id) = img.resource_id else {
            let key = img
                .source_key
                .clone()
                .ok_or_else(|| ProjectionError::Field("image.sourceKey".to_string()))?;
            self.pictures_declared_without_bytes.insert(SwiftString::from(key.clone()));
            return Ok(OfficeBlock::Image {
                id: SwiftString::from(key),
                size: CGSize::new(img.intrinsic_size.width, img.intrinsic_size.height),
                alignment,
            });
        };
        let resource = self
            .resources
            .get(&resource_id)
            .ok_or_else(|| {
                ProjectionError::Malformed(format!("image referenced missing resource {resource_id}"))
            })?
            .clone();
        let key = resource
            .source_key
            .clone()
            .ok_or_else(|| ProjectionError::Field("resource.sourceKey".to_string()))?;
        use base64::Engine;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(&resource.bytes_base64)
            .map_err(|e| ProjectionError::Malformed(format!("resource bytes did not decode: {e}")))?;
        self.images.insert(SwiftString::from(key.clone()), Data(bytes));
        Ok(OfficeBlock::Image {
            id: SwiftString::from(key),
            size: CGSize::new(img.intrinsic_size.width, img.intrinsic_size.height),
            alignment,
        })
    }

    fn map_vector(&mut self, v: wire::Vector) -> Result<OfficeBlock, ProjectionError> {
        let key = v
            .source_key
            .clone()
            .ok_or_else(|| ProjectionError::Field("vector.sourceKey".to_string()))?;
        let paths: Vec<PathSpec> = v.paths.iter().map(convert_vector_path_back).collect();
        let graphic = VectorGraphic {
            paths,
            size: CGSize::new(v.intrinsic_size.width, v.intrinsic_size.height),
        };
        self.vector_graphics.insert(SwiftString::from(key.clone()), graphic);
        let alignment = alignment_back(v.alignment);
        Ok(OfficeBlock::Image {
            id: SwiftString::from(key),
            size: CGSize::new(v.intrinsic_size.width, v.intrinsic_size.height),
            alignment,
        })
    }

    fn map_table(&mut self, node: &wire::Node, t: wire::Table) -> Result<OfficeBlock, ProjectionError> {
        let mut rows: Vec<Vec<Cell>> = Vec::with_capacity(node.children.len());
        for &row_id in &node.children {
            let row_node = self.get(row_id)?.clone();
            let wire::NodePayload::TableRow(_row) = &row_node.payload else {
                return Err(ProjectionError::Malformed("table child was not a row".to_string()));
            };
            let mut cell_ids_sorted = row_node.children.clone();
            cell_ids_sorted.sort_by_key(|&id| {
                let n = self.by_id.get(&id);
                match n.map(|n| &n.payload) {
                    Some(wire::NodePayload::TableCell(c)) => c.column,
                    _ => 0,
                }
            });
            let mut row_out = Vec::with_capacity(cell_ids_sorted.len());
            for cell_id in cell_ids_sorted {
                let cell_node = self.get(cell_id)?.clone();
                let wire::NodePayload::TableCell(tc) = &cell_node.payload else {
                    return Err(ProjectionError::Malformed("row child was not a cell".to_string()));
                };
                let blocks = self.map_blocks(&cell_node.children, 0)?;
                let mut cell = convert_cell_back(tc.clone(), blocks);
                // S6-4: mutually exclusive by construction (`office_adapter::map_table`'s own
                // priority) — at most one of the two is `Some` on any wire cell.
                cell.background_image = tc
                    .background_resource_id
                    .map(|id| self.background_resource(id))
                    .transpose()?;
                cell.background_gradient = tc.background_gradient.as_ref().map(convert_gradient_back);
                row_out.push(cell);
            }
            rows.push(row_out);
        }

        let column_widths = t.source_column_widths.clone();
        let background_image = t
            .style
            .background_resource_id
            .map(|id| self.background_resource(id))
            .transpose()?;
        let background_gradient = t.style.background_gradient.as_ref().map(convert_gradient_back);
        let format = TableFormat {
            default_border_color: t.style.default_uniform_border.as_ref().and_then(|b| b.color).map(convert_color_back),
            default_border_width: t.style.default_uniform_border.as_ref().and_then(|b| b.width_points),
            default_shading: t.style.default_shading.map(convert_color_back),
            background_image,
            background_gradient,
            source_width: t.style.source_width_points,
            edge_borders: t.style.edge_borders.as_ref().map(convert_edge_borders_back),
            default_padding: t.style.default_padding.as_ref().map(optional_insets_to_edge_padding),
            repeat_header_rows: t.style.repeat_header_rows,
            page_break_policy: t.style.page_break_policy.map(convert_page_break_policy_back),
            outer_margin: t.style.outer_margin.as_ref().map(optional_insets_to_edge_padding),
        };
        Ok(OfficeBlock::Table {
            rows,
            header_rows: t.header_rows as i64,
            column_widths,
            format,
        })
    }
}

fn convert_hf_applicability(v: wire::HeaderFooterApplicability) -> ob::HeaderFooterApplicability {
    match v {
        wire::HeaderFooterApplicability::DefaultPages => ob::HeaderFooterApplicability::DefaultPages,
        wire::HeaderFooterApplicability::FirstPage => ob::HeaderFooterApplicability::FirstPage,
        wire::HeaderFooterApplicability::EvenPages => ob::HeaderFooterApplicability::EvenPages,
    }
}

fn convert_paragraph_anchor_align_back(
    v: wire::ParagraphAnchorAlign,
) -> ob::ParagraphAnchorAlign {
    match v {
        wire::ParagraphAnchorAlign::Top => ob::ParagraphAnchorAlign::Top,
        wire::ParagraphAnchorAlign::Center => ob::ParagraphAnchorAlign::Center,
        wire::ParagraphAnchorAlign::Bottom => ob::ParagraphAnchorAlign::Bottom,
    }
}

fn convert_underline_style_back(v: wire::UnderlineStyle) -> ob::UnderlineStyle {
    match v {
        wire::UnderlineStyle::Single => ob::UnderlineStyle::Single,
        wire::UnderlineStyle::Double => ob::UnderlineStyle::Double,
        wire::UnderlineStyle::Dotted => ob::UnderlineStyle::Dotted,
        wire::UnderlineStyle::Dashed => ob::UnderlineStyle::Dashed,
        wire::UnderlineStyle::Wavy => ob::UnderlineStyle::Wavy,
    }
}

fn convert_form_control_kind_back(v: wire::FormControlKind) -> ob::OfficeFormControlKind {
    use wire::FormControlKind as K;
    match v {
        K::CheckBox => ob::OfficeFormControlKind::CheckBox,
        K::RadioButton => ob::OfficeFormControlKind::RadioButton,
        K::PushButton => ob::OfficeFormControlKind::PushButton,
        K::ComboBox => ob::OfficeFormControlKind::ComboBox,
        K::Edit => ob::OfficeFormControlKind::Edit,
        K::ListBox => ob::OfficeFormControlKind::ListBox,
        K::ScrollBar => ob::OfficeFormControlKind::ScrollBar,
        K::Unknown => ob::OfficeFormControlKind::Unknown,
    }
}

/// Reverse of `office_accounting::column_flow_from_office` — rebuilds the span's own
/// `OfficeColumnLayout` from the wire tree's `ColumnFlowDeclaration`.
///
/// Two of `OfficeColumnLayout`'s fields are `Option` on the source side
/// (`separator_color`/`separator_color_ref`, `source_raw_attributes`) but required on the wire
/// side — `column_flow_from_office` itself refuses to build a `ColumnFlowDeclaration` at all when
/// any of them is `None` (`AccountingError::IncompleteOfficeColumnAuthority`). So a
/// `ColumnFlowDeclaration` reaching this function is proof those three were `Some` on the source,
/// and reconstructing them as `Some` here is not a guess — it is the only value that could have
/// produced this wire node.
fn column_layout_back(
    flow: &wire::ColumnFlowDeclaration,
) -> crate::render::office::column_geometry::OfficeColumnLayout {
    use crate::render::office::column_geometry::{
        OfficeColumnDirection, OfficeColumnFlowType, OfficeColumnLayout,
    };
    OfficeColumnLayout {
        flow_type: Some(match flow.flow_type {
            wire::ColumnFlowType::Normal => OfficeColumnFlowType::Normal,
            wire::ColumnFlowType::Distribute => OfficeColumnFlowType::Distribute,
            wire::ColumnFlowType::Parallel => OfficeColumnFlowType::Parallel,
        }),
        count: i64::from(flow.count),
        spacing: flow.spacing_points,
        widths: flow.widths.clone(),
        gaps: flow.gaps.clone(),
        proportional: flow.source_proportional_widths,
        same_width: flow.source_same_width,
        direction: match flow.direction {
            wire::ColumnFlowDirection::LeftToRight => OfficeColumnDirection::LeftToRight,
            wire::ColumnFlowDirection::RightToLeft => OfficeColumnDirection::RightToLeft,
        },
        separator_type: column_separator_style_to_code(flow.separator.style),
        separator_width_code: flow.separator.source_width_code,
        separator_width_pt: flow.separator.width_points,
        // The source only ever carries a colour when a rule is actually drawn
        // (`OfficeColumnLayout::from_rhwp_column_def`: `(separator_type != 0).then_some(color)`) —
        // `column_flow_from_office` enforces the same rule the other way
        // (`AccountingError::InvalidOfficeColumnSeparatorColor` if a `None` style carries one), so
        // a "no rule" declaration reaching here must reconstruct `None`, not the colour the ref
        // would still compute to.
        separator_color: (flow.separator.style != wire::ColumnSeparatorStyle::None)
            .then(|| convert_color_back(flow.separator.color)),
        separator_color_ref: Some(flow.separator.source_color_ref),
        source_raw_attributes: Some(flow.source_raw_attributes),
    }
}

/// Reverse of `column_flow_from_office`'s own `0..=7` match on `separator_type`.
fn column_separator_style_to_code(v: wire::ColumnSeparatorStyle) -> i64 {
    match v {
        wire::ColumnSeparatorStyle::None => 0,
        wire::ColumnSeparatorStyle::Solid => 1,
        wire::ColumnSeparatorStyle::Dash => 2,
        wire::ColumnSeparatorStyle::Dot => 3,
        wire::ColumnSeparatorStyle::DashDot => 4,
        wire::ColumnSeparatorStyle::DashDotDot => 5,
        wire::ColumnSeparatorStyle::LongDash => 6,
        wire::ColumnSeparatorStyle::Circle => 7,
    }
}

fn convert_page_number_field_back(v: wire::PageNumberField) -> ob::PageNumberField {
    match v {
        wire::PageNumberField::Page => ob::PageNumberField::Page,
        wire::PageNumberField::NumPages => ob::PageNumberField::NumPages,
    }
}

fn convert_color_back(c: wire::Color) -> NSColor {
    match c.space {
        wire::ColorSpace::Srgb => NSColor::srgb(c.red, c.green, c.blue, c.alpha),
        wire::ColorSpace::DeviceRgb => NSColor::device_rgb(c.red, c.green, c.blue, c.alpha),
    }
}

/// S6-4's reverse of `office_adapter::convert_gradient`.
fn convert_gradient_back(g: &wire::Gradient) -> ob::OfficeGradient {
    ob::OfficeGradient {
        stops: g.stops.iter().map(|c| convert_color_back(c.clone())).collect(),
        angle_degrees: g.angle_degrees,
    }
}

fn convert_glyphs_back(v: wire::ListNumberingGlyphs) -> ob::ListNumberingGlyphs {
    use wire::ListNumberingGlyphs as G;
    match v {
        G::Decimal => ob::ListNumberingGlyphs::Decimal,
        G::CircledDecimal => ob::ListNumberingGlyphs::CircledDecimal,
        G::RomanUpper => ob::ListNumberingGlyphs::RomanUpper,
        G::RomanLower => ob::ListNumberingGlyphs::RomanLower,
        G::LatinUpper => ob::ListNumberingGlyphs::LatinUpper,
        G::LatinLower => ob::ListNumberingGlyphs::LatinLower,
        G::HangulSyllable => ob::ListNumberingGlyphs::HangulSyllable,
        G::HangulNumber => ob::ListNumberingGlyphs::HangulNumber,
        G::HanjaNumber => ob::ListNumberingGlyphs::HanjaNumber,
    }
}

fn convert_tab_alignment_back(v: wire::TabAlignment) -> ob::TabAlignment {
    match v {
        wire::TabAlignment::Left => ob::TabAlignment::Left,
        wire::TabAlignment::Center => ob::TabAlignment::Center,
        wire::TabAlignment::Right => ob::TabAlignment::Right,
        wire::TabAlignment::Decimal => ob::TabAlignment::Decimal,
    }
}

fn convert_tab_leader_back(v: wire::TabLeader) -> ob::TabLeader {
    match v {
        wire::TabLeader::None => ob::TabLeader::None,
        wire::TabLeader::Dot => ob::TabLeader::Dot,
        wire::TabLeader::Hyphen => ob::TabLeader::Hyphen,
        wire::TabLeader::Underscore => ob::TabLeader::Underscore,
    }
}

fn convert_tab_stops_back(stops: &[wire::TabStop]) -> Vec<ob::TabStop> {
    stops
        .iter()
        .map(|s| ob::TabStop::new(s.position_points, convert_tab_alignment_back(s.alignment), convert_tab_leader_back(s.leader)))
        .collect()
}

fn convert_cell_valign_back(v: wire::VerticalAlignment) -> CellVAlign {
    match v {
        wire::VerticalAlignment::Top => CellVAlign::Top,
        wire::VerticalAlignment::Middle => CellVAlign::Center,
        wire::VerticalAlignment::Bottom => CellVAlign::Bottom,
    }
}

fn convert_border_line_style_back(v: wire::BorderLineStyle) -> ob::BorderLineStyle {
    match v {
        wire::BorderLineStyle::Solid => ob::BorderLineStyle::Solid,
        wire::BorderLineStyle::Dashed => ob::BorderLineStyle::Dashed,
        wire::BorderLineStyle::Dotted => ob::BorderLineStyle::Dotted,
        wire::BorderLineStyle::Double => ob::BorderLineStyle::Double,
    }
}

fn convert_border_decl_back(d: &wire::BorderDeclaration) -> BorderDecl {
    match d {
        wire::BorderDeclaration::Suppressed => BorderDecl::Suppressed,
        wire::BorderDeclaration::Drawn(side) => BorderDecl::Drawn(BorderSide {
            width: side.width_points,
            color: side.color.map(convert_color_back),
            style: convert_border_line_style_back(side.style),
        }),
    }
}

fn convert_edge_borders_back(eb: &wire::BorderSet) -> EdgeBorders {
    EdgeBorders {
        top: eb.top.as_ref().map(convert_border_decl_back),
        left: eb.left.as_ref().map(convert_border_decl_back),
        bottom: eb.bottom.as_ref().map(convert_border_decl_back),
        right: eb.right.as_ref().map(convert_border_decl_back),
        inside_h: eb.inside_horizontal.as_ref().map(convert_border_decl_back),
        inside_v: eb.inside_vertical.as_ref().map(convert_border_decl_back),
    }
}

fn optional_insets_to_edge_padding(oi: &wire::OptionalInsets) -> EdgePadding {
    EdgePadding { top: oi.top, left: oi.left, bottom: oi.bottom, right: oi.right }
}

fn convert_page_break_policy_back(v: wire::TablePageBreakPolicy) -> ob::TablePageBreakPolicy {
    match v {
        wire::TablePageBreakPolicy::Never => ob::TablePageBreakPolicy::Never,
        wire::TablePageBreakPolicy::AtRowBoundary => ob::TablePageBreakPolicy::AtRowBoundary,
        wire::TablePageBreakPolicy::Anywhere => ob::TablePageBreakPolicy::Anywhere,
    }
}

fn convert_cell_diagonal_back(d: &wire::CellDiagonal) -> CellDiagonal {
    CellDiagonal {
        direction: match d.direction {
            wire::CellDiagonalDirection::Slash => ob::CellDiagonalDirection::Slash,
            wire::CellDiagonalDirection::Backslash => ob::CellDiagonalDirection::Backslash,
            wire::CellDiagonalDirection::Both => ob::CellDiagonalDirection::Both,
        },
        side: BorderSide {
            width: d.side.width_points,
            color: d.side.color.map(convert_color_back),
            style: convert_border_line_style_back(d.side.style),
        },
    }
}

fn convert_cell_back(tc: wire::TableCell, blocks: Vec<OfficeBlock>) -> Cell {
    Cell {
        blocks,
        row_span: tc.row_span as i64,
        col_span: tc.column_span as i64,
        background_color: tc.direct_shading.map(convert_color_back),
        // S6-4: patched onto the return value by `map_table`'s own loop, which alone has the
        // `&mut self` a resource lookup needs (this free function has none).
        background_image: None,
        background_gradient: None,
        border_color: tc.direct_uniform_border.as_ref().and_then(|b| b.color).map(convert_color_back),
        border_width: tc.direct_uniform_border.as_ref().and_then(|b| b.width_points),
        edge_borders: tc.direct_edge_borders.as_ref().map(convert_edge_borders_back),
        width: tc.declared_width_points,
        vertical_alignment: tc.vertical_alignment.map(convert_cell_valign_back),
        padding: tc.uniform_padding_points,
        edge_padding: tc.edge_padding.as_ref().map(optional_insets_to_edge_padding),
        diagonal: tc.diagonal.as_ref().map(convert_cell_diagonal_back),
        style_shading: tc.style_shading.map(convert_color_back),
        style_border_color: tc.style_uniform_border.as_ref().and_then(|b| b.color).map(convert_color_back),
        style_border_width: tc.style_uniform_border.as_ref().and_then(|b| b.width_points),
    }
}

fn convert_path_command_back(cmd: &wire::PathCommand) -> HwpPathCommand {
    match (cmd.command.as_str(), cmd.values.as_slice()) {
        ("moveTo", [x, y]) => HwpPathCommand::Move(CGPoint::new(*x, *y)),
        ("lineTo", [x, y]) => HwpPathCommand::Line(CGPoint::new(*x, *y)),
        ("curveTo", [x1, y1, x2, y2, x3, y3]) => HwpPathCommand::Curve(
            CGPoint::new(*x1, *y1),
            CGPoint::new(*x2, *y2),
            CGPoint::new(*x3, *y3),
        ),
        _ => HwpPathCommand::Close,
    }
}

fn convert_vector_path_back(p: &wire::VectorPath) -> PathSpec {
    PathSpec {
        commands: p.commands.iter().map(convert_path_command_back).collect(),
        stroke: p.stroke.as_ref().map(|s| BorderSide {
            width: s.width_points,
            color: s.color.map(convert_color_back),
            style: convert_border_line_style_back(s.style),
        }),
        fill: p.fill.map(convert_color_back),
        arrow_start: p.arrow_start,
        arrow_end: p.arrow_end,
    }
}

fn alignment_back(a: wire::Alignment) -> Option<NSTextAlignment> {
    match a {
        wire::Alignment::Natural => None,
        wire::Alignment::Left => Some(NSTextAlignment::Left),
        wire::Alignment::Right => Some(NSTextAlignment::Right),
        wire::Alignment::Center => Some(NSTextAlignment::Center),
        wire::Alignment::Justified => Some(NSTextAlignment::Justified),
    }
}

fn convert_line_break_granularity_back(v: wire::LineBreakGranularity) -> ob::LineBreakGranularity {
    match v {
        wire::LineBreakGranularity::Word => ob::LineBreakGranularity::Word,
        wire::LineBreakGranularity::Hyphen => ob::LineBreakGranularity::Hyphen,
        wire::LineBreakGranularity::Character => ob::LineBreakGranularity::Character,
    }
}

fn convert_line_height_back(lh: &wire::LineHeight) -> ob::LineHeight {
    match lh.mode {
        wire::LineHeightMode::Multiple => ob::LineHeight::Multiple(lh.value),
        wire::LineHeightMode::Exact => ob::LineHeight::Exact(lh.value),
        wire::LineHeightMode::AtLeast => ob::LineHeight::AtLeast(lh.value),
    }
}

/// Reverse of `office_adapter::paragraph_border_set` (see its own doc: one uniform colour/width
/// across whichever edges were named). Reconstructs `border_edges` from which edges the wire
/// `BorderSet` names, and takes the first present edge's colour/width as the uniform value — exact
/// whenever all named edges share one value, which `paragraph_border_set` always produces.
fn paragraph_border_back(bs: &Option<wire::BorderSet>) -> (RectEdge, Option<NSColor>, Option<f64>) {
    let Some(bs) = bs else {
        return (RectEdge::empty(), None, None);
    };
    let mut edges = RectEdge::empty();
    let mut color = None;
    let mut width = None;
    let mut take = |decl: &Option<wire::BorderDeclaration>, edge: RectEdge| {
        if let Some(wire::BorderDeclaration::Drawn(d)) = decl {
            edges.insert(edge);
            if color.is_none() && width.is_none() {
                color = d.color.map(convert_color_back);
                width = Some(d.width_points);
            }
        }
    };
    take(&bs.top, RectEdge::TOP);
    take(&bs.left, RectEdge::LEFT);
    take(&bs.bottom, RectEdge::BOTTOM);
    take(&bs.right, RectEdge::RIGHT);
    (edges, color, width)
}

/// Reverse of `office_adapter::paragraph_style` — returns the reconstructed `(ParagraphFormat,
/// alignment, rtl)` triple `Heading`/`Paragraph`/`ListItem` each carry as three separate fields.
fn paragraph_format_back(style: &wire::ParagraphStyle) -> (ParagraphFormat, Option<NSTextAlignment>, bool) {
    let alignment = style.alignment.map(convert_alignment_back);
    let rtl = matches!(style.direction, Some(wire::Direction::RightToLeft));
    let (border_edges, border_color, border_width) = paragraph_border_back(&style.borders);
    let format = ParagraphFormat {
        list_text_distance: style.list_text_distance,
        spacing_before: style.spacing_before,
        spacing_after: style.spacing_after,
        line_height: style.line_height.as_ref().map(convert_line_height_back),
        indent_start: style.head_indent,
        indent_end: style.tail_indent,
        first_line_indent: style.first_line_indent,
        hanging_indent: style.hanging_indent,
        contextual_spacing: style.contextual_spacing,
        shading: style.shading.map(convert_color_back),
        border_color,
        border_width,
        border_edges,
        east_asian_line_break: style.east_asian_line_break.map(convert_line_break_granularity_back),
        latin_line_break: style.latin_line_break.map(convert_line_break_granularity_back),
        auto_space_east_asian_latin: style.auto_space_east_asian_latin,
        auto_space_east_asian_number: style.auto_space_east_asian_number,
        line_height_from_font_metrics: style.line_height_from_font_metrics,
    };
    (format, alignment, rtl)
}

fn convert_alignment_back(a: wire::Alignment) -> NSTextAlignment {
    match a {
        wire::Alignment::Natural => NSTextAlignment::Natural,
        wire::Alignment::Left => NSTextAlignment::Left,
        wire::Alignment::Right => NSTextAlignment::Right,
        wire::Alignment::Center => NSTextAlignment::Center,
        wire::Alignment::Justified => NSTextAlignment::Justified,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::render::office::office_block::{OfficeComment, ParagraphFormat};
    use crate::render::render_tree::{DocumentFormat, OfficeAdapterInput};

    fn input(result: &ob::OfficeReadResult) -> OfficeAdapterInput<'_> {
        OfficeAdapterInput {
            format: DocumentFormat::Docx,
            source_name: "doc.docx",
            source_bytes: b"hello office",
            result,
            resources: std::collections::BTreeMap::new(),
        }
    }

    /// The two top-level arrays `project`'s own callers (`fastdoc_read_office_json`) actually read
    /// — decoded through the SAME `OfficeBlock`/`OfficeComment` types the encoder used, so these
    /// tests assert on the round-tripped Rust values rather than guessing this module's JSON shape.
    #[derive(serde::Deserialize)]
    struct ProjectedEnvelope {
        blocks: Vec<OfficeBlock>,
        comments: Vec<OfficeComment>,
    }

    fn projected(result: &ob::OfficeReadResult) -> ProjectedEnvelope {
        let tree = ValidatedRenderTree::from_office(input(result)).expect("tree builds");
        let json = project(&tree).expect("project succeeds — this fixture has no comment_ids and one section");
        serde_json::from_str(&json).expect("project's output is valid schema-v4 JSON")
    }

    /// Defect 1 (S6-7): `convert_run` hardcoded `bookmarks: vec![]` for every span, so an internal
    /// link resolving to a bookmark went nowhere on the tree path even though `office_adapter`
    /// resolves and carries the bookmark into the wire tree just fine. Reverting the fix (hardcoding
    /// `bookmarks: vec![]` again) makes this fail: the span comes back with no bookmark name.
    #[test]
    fn a_bookmarked_span_projects_its_bookmark_name() {
        let mut result = ob::OfficeReadResult::default();
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
        let doc = projected(&result);
        let OfficeBlock::Paragraph { spans, .. } = &doc.blocks[0] else {
            panic!("expected a paragraph block, got {:?}", doc.blocks[0]);
        };
        assert_eq!(
            spans[0].bookmarks,
            vec![SwiftString::from("Chapter1")],
            "the projected span must carry the bookmark name back, not an empty list"
        );
    }

    /// Defect 2 (S6-7): `project` hardcoded `"comments": []` unconditionally, so an ORPHAN comment
    /// (no `w:commentRangeStart`/`office:annotation-end` anywhere — no span ever sets
    /// `comment_ids`) was silently eaten even on a successful tree projection. This fixture MUST
    /// have no span carrying `comment_ids`: a comment WITH a body range instead hits `convert_run`'s
    /// bail and falls back to `office_export::to_json(&OfficeReadResult)`, which was already correct
    /// before this fix and would pass even with `comments: []` still hardcoded — proving nothing
    /// about this change. Reverting the fix (hardcoding `[]` again) makes `comments` empty here.
    #[test]
    fn an_orphan_comment_with_no_referencing_span_is_still_projected() {
        let mut result = ob::OfficeReadResult::default();
        result.comments.push(OfficeComment {
            id: SwiftString::from("5"),
            author: Some(SwiftString::from("Carol")),
            date_iso: None,
            text: SwiftString::from("Orphan comment"),
            number: 1,
        });
        result.blocks.push(OfficeBlock::Paragraph {
            spans: vec![Span {
                text: SwiftString::from("Plain text, no ranges at all."),
                ..Default::default()
            }],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        });
        let doc = projected(&result);
        assert_eq!(doc.comments.len(), 1, "the orphan comment must still be listed");
        assert_eq!(doc.comments[0].author, Some(SwiftString::from("Carol")));
        assert_eq!(doc.comments[0].text, SwiftString::from("Orphan comment"));
        assert_eq!(
            doc.comments[0].number, 1,
            "display number is reconstructed from this array's own order, which both readers \
             assign 1-indexed"
        );
        // The DOCUMENT's own id, round-tripped through `wire::Comment.source_id`. This assertion
        // has been wrong twice, in both possible directions, which is why it is spelled out: the
        // projection first filled this with `wire::Comment.id` — our own sequential mint, a number
        // the source never wrote — and then, once that was removed, with the empty string, which
        // asserts the document gave its comment no id when it plainly gave it "5". Both are
        // invariant 108's mistake: a specific value written where the truth was "we did not carry
        // it". The fix was to carry it.
        assert_eq!(
            doc.comments[0].id,
            SwiftString::from("5"),
            "the comment must come back with the id the DOCUMENT gave it, never our own mint and \
             never empty"
        );
    }
}
