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
//! - `sections` / `section_start_blocks`: emitted as `[]` when `wire::Document.declared_section_count`
//!   is `0` — the one case a tree cannot otherwise tell "the source declared no sections" (the
//!   synthetic single-section case docx/odt always build) from "declared exactly one" apart, since
//!   both build an identical single-`Section` tree. Any other count reconstructs for real:
//!   `wire::Section` carries all six of `OfficeSectionDeclaration`'s fields (`footnote_separator`,
//!   `page_border`, `hides_header`, `hides_footer`, `hides_master_page`, `is_vertical`, alongside
//!   `paper`/`columns`/`page_numbering`/`line_grid_points`), so `project` walks every section in
//!   order and reconstructs `blocks`/`headers`/`footers`/`footnotes`/`sections`/
//!   `section_start_blocks` across all of them.
//! - a span's own `comment_ids`: a wire `TextRun.commentIds` entry names a comment by a wire id
//!   this adapter minted, and the map back to the source's own opaque id string is adapter-internal
//!   build state that is never serialized. A run carrying one therefore USED to return
//!   `ProjectionError::Field("span.comment_ids")`, sending the WHOLE document back to
//!   `office_export::to_json(&OfficeReadResult)` — which meant every document with a comment
//!   anchored in its body silently bypassed this projector, invisibly, because the fallback's
//!   output is correct. `wire::Comment.source_id` closed that: the tree now carries the source's
//!   own id on the comment itself, so `resolve_comment_source_id` reads the map out of the tree
//!   rather than needing the adapter's build state. A dangling id — one no comment in the tree
//!   declares — is `ProjectionError::Malformed`, not `Field`: it is a broken tree, not a fact the
//!   schema cannot express. `annotations.comments` itself IS projected (`comments`, below),
//!   whether or not a span references it — an orphan comment (no in-body range at all) simply
//!   references nothing. `OfficeComment.id` is
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
use swiftshim::{CGPoint, CGSize, Data, NSColor, NSEdgeInsets, NSTextAlignment, SwiftString};

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
    // name. The comment map beside it is the same shape and exists for the same reason: a wire
    // comment id is a fresh mint, and `wire::Comment.source_id` is what turns it back into the id
    // the DOCUMENT gave that comment. Before that field existed this projection could not resolve a
    // run's `commentIds` at all and bailed on the whole document, so every document with a comment
    // anchored in its body bypassed the canonical tree entirely.
    let bookmark_names: HashMap<u64, String> =
        envelope.annotations.bookmarks.iter().map(|b| (b.id, b.name.clone())).collect();
    let comment_source_ids: HashMap<u64, String> =
        envelope.annotations.comments.iter().map(|c| (c.id, c.source_id.clone())).collect();
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
        comment_source_ids,
    };

    let root_id = envelope.document.root_node_id;
    let root = proj.get(root_id)?.clone();
    if root.children.is_empty() {
        return Err(ProjectionError::Malformed("document has no section children".to_string()));
    }
    // `section_count = result.sections.len().max(1)` is how `office_adapter::from_office` decides
    // how many `Section` nodes to build (see that function's own doc), so more than one here is
    // proof the source declared more than one — never a synthetic document-wide fallback, which
    // only ever produces exactly one. `declared_section_count` is the tree's own record of what
    // `result.sections.len()` actually was (`wire::Document`'s own doc), which is what lets a tree
    // with exactly one `Section` node tell "the source declared none" (the synthetic document-wide
    // case) from "declared exactly one" apart — the two build an identical tree otherwise.
    let is_multi_section = root.children.len() > 1;
    let declared_section_count = envelope.document.declared_section_count as usize;
    if is_multi_section && declared_section_count != root.children.len() {
        return Err(ProjectionError::Malformed(format!(
            "declaredSectionCount {declared_section_count} disagrees with {} section nodes",
            root.children.len()
        )));
    }

    let mut blocks: Vec<OfficeBlock> = Vec::new();
    let mut headers: Vec<OfficeHeaderFooter> = Vec::new();
    let mut footers: Vec<OfficeHeaderFooter> = Vec::new();
    let mut footnotes: Vec<OfficeFootnote> = Vec::new();
    let mut anchored_objects: Vec<ob::OfficeAnchoredObject> = Vec::new();
    let mut master_pages: Vec<ob::OfficeMasterPage> = Vec::new();
    let mut first_section: Option<wire::Section> = None;
    // Every section's own declaration and where its blocks begin — walked alongside `blocks`
    // below so `section_start_blocks[i]` is the real index into the reconstructed `blocks`, not a
    // guess (`ProjectionError`'s module doc explains why this used to be an accepted `[]`).
    let mut wire_sections: Vec<wire::Section> = Vec::new();
    let mut section_start_blocks: Vec<i64> = Vec::new();

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
            first_section = Some(section.clone());
        }
        wire_sections.push(section);

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

        section_start_blocks.push(blocks.len() as i64);
        let section_blocks = proj.map_blocks(&flow_children, blocks.len() as i64)?;
        blocks.extend(section_blocks);

        for ao in pending_anchored {
            anchored_objects.push(proj.anchored_object(ao)?);
        }
    }
    // Nothing reads section zero any more -- the document's own sheet and line grid are carried on
    // `wire::Document` rather than inferred from the first section, which is what stopped an
    // inherited page from being reported as that section's declaration. A tree with no section at
    // all is still a shape this projector cannot work with, so the check stays.
    if first_section.is_none() {
        return Err(ProjectionError::Malformed("no section was found".to_string()));
    }

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
    ) = match &envelope.document.document_paper {
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

    // Comments reaching this point may be anchored or orphaned alike — a span carrying
    // `comment_ids` no longer sends the document to the fallback, because `wire::Comment.source_id`
    // carries the DOCUMENT's own opaque id (docx's `w:id`, an odt `office:name`) and
    // `resolve_comment_source_id` reads it straight out of the tree. `id` is taken from that field
    // verbatim. Before it existed this was the one `OfficeComment` field this reconstruction could
    // not honestly restore: `wire::Comment.id` is a fresh sequential mint with no document meaning
    // of its own, so stamping it in (even stringified) would have invented a fact the source never
    // stated — exactly the failure shape invariant 108 names, a specific value written where
    // "unknown" belongs. `number` has no such gap either: both readers assign it 1-indexed in this exact
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

    // One copy of each picture instead of one per use (`picture_pool`). Measured on a 2,562-page
    // manual: 692 pictures written for 61 distinct ones, 17,193,764 bytes of a 27,169,703-byte
    // payload. Done HERE and not only in `office_export::to_json` because this is the assembler a
    // real document reaches — all 669 of the corpus take the projection path.
    let mut blocks = blocks;
    let mut headers = headers;
    let mut footers = footers;
    let mut footnotes = footnotes;
    let mut master_pages = master_pages;
    let mut anchored_objects = anchored_objects;
    let mut interner = crate::render::office::picture_pool::Interner::new();
    interner.blocks(&mut blocks);
    for header in &mut headers { interner.blocks(&mut header.blocks); }
    for footer in &mut footers { interner.blocks(&mut footer.blocks); }
    for footnote in &mut footnotes { interner.blocks(&mut footnote.blocks); }
    for page in &mut master_pages {
        for object in &mut page.objects { interner.master_content(&mut object.content); }
    }
    for anchored in &mut anchored_objects {
        interner.master_content(&mut anchored.object.content);
    }
    let (_pooled, _distinct, picture_pool) = interner.finish();

    // The per-edge border declarations get the same treatment, in the same assembler and for the
    // same reason (`edge_border_pool`): 5,494 of them on one real manual for 274 distinct looks.
    // Done AFTER the pictures so the two walks stay independent and either can be turned off alone.
    let mut edge_interner = crate::render::office::edge_border_pool::Interner::new();
    edge_interner.blocks(&mut blocks);
    for header in &mut headers { edge_interner.blocks(&mut header.blocks); }
    for footer in &mut footers { edge_interner.blocks(&mut footer.blocks); }
    for footnote in &mut footnotes { edge_interner.blocks(&mut footnote.blocks); }
    let (_interned, _distinct_edges, edge_border_pool) = edge_interner.finish();

    // And the paragraph formats, on the same rule. This assembler is the one every real document
    // comes through, so pooling in the exporter alone would leave the two disagreeing — which is
    // exactly what `office_projection_oracle` caught the first time this was wired in one place.
    let mut format_interner = crate::render::office::paragraph_format_pool::Interner::new();
    format_interner.blocks(&mut blocks);
    for header in &mut headers { format_interner.blocks(&mut header.blocks); }
    for footer in &mut footers { format_interner.blocks(&mut footer.blocks); }
    for footnote in &mut footnotes { format_interner.blocks(&mut footnote.blocks); }
    for page in &mut master_pages {
        for object in &mut page.objects { format_interner.master_content(&mut object.content); }
    }
    for anchored in &mut anchored_objects {
        format_interner.master_content(&mut anchored.object.content);
    }
    let (_interned_formats, _distinct_formats, paragraph_format_pool) = format_interner.finish();

    let mut result = serde_json::Map::new();
    // The version the ENGINE writes, not a copy of it. This was a literal `4` beside
    // `office_export::SCHEMA_VERSION`, and the two are the same contract: the moment the exporter
    // moved to 5 this assembler kept saying 4, and since every real document comes through here the
    // host would have refused all of them. Nothing failed — the payload simply did not change.
    result.insert(
        "v".to_string(),
        serde_json::Value::from(super::office_export::SCHEMA_VERSION),
    );
    // Omitted when empty, exactly as `OfficeReadResult.picture_pool`'s own `skip_serializing_if`
    // omits it — the projection oracle compares this assembler's output against
    // `office_export::to_json`'s, and a field one of them writes as `{}` while the other leaves out
    // is a disagreement even when both mean "no pooled pictures".
    if !picture_pool.is_empty() {
        result.insert("picture_pool".to_string(), to_value(&picture_pool)?);
    }
    // Same rule, same reason, for the edge-border table.
    if !edge_border_pool.is_empty() {
        result.insert("edge_border_pool".to_string(), to_value(&edge_border_pool)?);
    }
    // Same rule, same reason, for the paragraph-format table.
    if !paragraph_format_pool.is_empty() {
        result.insert("paragraph_format_pool".to_string(), to_value(&paragraph_format_pool)?);
    }
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
    // `declared_section_count == 0` is the one genuine ambiguity left (see `wire::Document`'s own
    // doc on the field): a tree with exactly one `Section` node built from a source that declared
    // NONE looks identical to one that declared exactly one. `[]` is the honest answer there —
    // reporting a section the source never declared would be the guess, not this. Any other count
    // (0 sections is the only one still special-cased; 1 or more all now reconstruct for real)
    // walks every `Section` node this projector already collected in `wire_sections` and converts
    // it field for field, `sections[i]` in the same order the source declared them and
    // `section_start_blocks[i]` the real index `blocks` grows to at that section's own turn in the
    // walk above — not a guess, and not `Field("sections")` any more.
    if declared_section_count == 0 {
        result.insert("sections".to_string(), to_value(&Vec::<ob::OfficeSectionDeclaration>::new())?);
        result.insert("anchored_objects".to_string(), to_value(&anchored_objects)?);
        result.insert("section_start_blocks".to_string(), to_value(&Vec::<i64>::new())?);
    } else {
        let sections: Vec<ob::OfficeSectionDeclaration> =
            wire_sections.iter().map(convert_section_declaration_back).collect();
        result.insert("sections".to_string(), to_value(&sections)?);
        result.insert("anchored_objects".to_string(), to_value(&anchored_objects)?);
        result.insert("section_start_blocks".to_string(), to_value(&section_start_blocks)?);
    }
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
    // The DOCUMENT's own pitch, not section zero's effective one -- section zero's falls back to
    // this, so reading it back off the section would report a section's declaration as the
    // document's whenever section zero happened to declare one.
    insert_opt(&mut result, "line_grid_pitch", envelope.document.line_grid_points);

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
    /// `TextRun.commentIds` entry -> the id the DOCUMENT gave that comment, from
    /// `wire::Comment.source_id`. See `project`'s own comment for why this map is what removed a
    /// whole-document fallback rather than merely a missing field.
    comment_source_ids: HashMap<u64, String>,
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

    /// `TextRun.commentIds` entry -> the source's own comment id, mirroring
    /// `resolve_bookmark_name` exactly. A run naming a comment id `annotations.comments` does not
    /// contain is a malformed tree, not a silently dropped comment — the same standard bookmarks
    /// are held to.
    fn resolve_comment_source_id(&self, id: u64) -> Result<SwiftString, ProjectionError> {
        self.comment_source_ids.get(&id).map(|s| SwiftString::from(s.clone())).ok_or_else(|| {
            ProjectionError::Malformed(format!(
                "textRun.commentIds named comment {id}, which annotations.comments does not contain"
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
    /// The bytes a resource carries, decoded — or a refusal naming the resource that carries none.
    ///
    /// P2a: a resource may be carried BY REFERENCE (`source_key` names the picture, the document
    /// still holds it). Everything that needs actual pixels HERE — a decoded background fill, a
    /// master page's artwork — is something the reader synthesized rather than something the
    /// document named, so it always carries its bytes. Reaching this with none is a real defect,
    /// and it says so instead of painting a blank.
    fn resource_bytes(&self, resource: &wire::Resource) -> Result<Vec<u8>, ProjectionError> {
        use base64::Engine;
        let base64 = resource.bytes_base64.as_ref().ok_or_else(|| {
            ProjectionError::Malformed(format!(
                "resource {} carries no bytes, and this use needs pixels rather than a reference",
                resource.id
            ))
        })?;
        base64::engine::general_purpose::STANDARD
            .decode(base64)
            .map_err(|e| ProjectionError::Malformed(format!("resource bytes did not decode: {e}")))
    }

    fn background_resource(&mut self, resource_id: u64) -> Result<swiftshim::NSImage, ProjectionError> {
        let resource = self.resources.get(&resource_id).cloned().ok_or_else(|| {
            ProjectionError::Malformed(format!("background fill referenced missing resource {resource_id}"))
        })?;
        let bytes = self.resource_bytes(&resource)?;
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
                let bytes = self.resource_bytes(&resource)?;
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
        let comment_ids = run
            .comment_ids
            .iter()
            .map(|&id| self.resolve_comment_source_id(id))
            .collect::<Result<Vec<_>, _>>()?;
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
            comment_ids,
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
            format, format_ref: None,
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
                    format, format_ref: None,
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
                    format, format_ref: None,
                })
            }
            wire::NodePayload::Table(t) => self.map_table(node, t.clone()),
            wire::NodePayload::Image(img) => self.map_image(img.clone()),
            wire::NodePayload::Vector(v) => self.map_vector(v.clone()),
            wire::NodePayload::Formula(f) => {
                Ok(OfficeBlock::Formula { latex: SwiftString::from(f.source.clone()) })
            }
            wire::NodePayload::Unsupported(u) => Ok(OfficeBlock::UnsupportedGraphic {
                label: SwiftString::from(u.reason.clone()),
                size: CGSize::new(u.intrinsic_size.width, u.intrinsic_size.height),
                alignment: alignment_back(u.alignment),
            }),
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
        // A resource carried BY REFERENCE (P2a) names its picture and stops there: the block below
        // still carries `key`, and whoever draws it asks the still-open document for those pixels
        // when it needs them. Putting an entry in `self.images` is what makes an export carry the
        // picture, so NOT putting one is the whole of how an export stops carrying it.
        if resource.bytes_base64.is_some() {
            let bytes = self.resource_bytes(&resource)?;
            self.images.insert(SwiftString::from(key.clone()), Data(bytes));
        }
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
            edge_borders_ref: None,
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

/// `wire::Paper` -> `office_block::PaperGeometry`: inverts `office_adapter::build_paper`'s own
/// `content_width = width_points - margins.left - margins.right` (and the height equivalent) —
/// the same arithmetic `page_content_width` above already runs for the document-level fields.
fn paper_geometry_back(p: &wire::Paper) -> ob::PaperGeometry {
    ob::PaperGeometry {
        content_width: p.width_points - p.margins.left - p.margins.right,
        content_height: p.height_points - p.margins.top - p.margins.bottom,
        margin_left: p.margins.left,
        margin_right: p.margins.right,
        margin_top: p.margins.top,
        margin_bottom: p.margins.bottom,
    }
}

/// `wire::FootnoteSeparator` -> `office_block::OfficeFootnoteSeparator`, the reverse of
/// `office_adapter::convert_footnote_separator`.
fn convert_footnote_separator_back(fs: &wire::FootnoteSeparator) -> ob::OfficeFootnoteSeparator {
    ob::OfficeFootnoteSeparator {
        line_type: fs.line_type,
        line_width_pt: fs.line_width_points,
        color: fs.color.map(convert_color_back),
        length_pt: fs.length_points,
        margin_top_pt: fs.margin_top_points,
        margin_bottom_pt: fs.margin_bottom_points,
        note_spacing_pt: fs.note_spacing_points,
    }
}

/// `wire::PageBorder` -> `office_block::OfficePageBorder`, the reverse of
/// `office_adapter::convert_page_border` — `borders` goes back through the same
/// `convert_edge_borders_back` a cell's border set uses.
fn convert_page_border_back(pb: &wire::PageBorder) -> ob::OfficePageBorder {
    ob::OfficePageBorder {
        borders: pb.borders.as_ref().map(convert_edge_borders_back),
        background: pb.background.map(convert_color_back),
        spacing: NSEdgeInsets {
            top: pb.spacing.top,
            left: pb.spacing.left,
            bottom: pb.spacing.bottom,
            right: pb.spacing.right,
        },
        measured_from_paper: pb.measured_from_paper,
    }
}

/// `wire::Section` -> `office_block::OfficeSectionDeclaration`, one array element for one
/// `Section` node — called only once `declared_section_count` (`wire::Document`'s own doc) has
/// already ruled out the single-section-means-none ambiguity `sections: []` exists for.
///
/// `paper` is reconstructed from `wire::Section.paper` as-is, which is NOT the same claim as the
/// other five: `office_adapter::from_office` fills that field with the DOCUMENT-level fallback
/// (`result_page_geometry`) whenever a section declares no paper of its own, so a section that
/// declared nothing here reconstructs as though it declared the document's geometry explicitly.
/// `wire::Section` has no bit recording which case it was — flagged in this sprint's own report
/// rather than fixed here, since closing it needs a new wire field, out of this unit's scope.
fn convert_section_declaration_back(s: &wire::Section) -> ob::OfficeSectionDeclaration {
    ob::OfficeSectionDeclaration {
        footnote_separator: s.footnote_separator.as_ref().map(convert_footnote_separator_back),
        page_border: s.page_border.as_ref().map(convert_page_border_back),
        // `s.paper` is the EFFECTIVE sheet, which the adapter fills from the document when the
        // section named none. Reporting it unconditionally would state a declaration the source
        // never made -- `OfficeSectionDeclaration.paper`'s own contract is that `nil` means "this
        // section stated no page of its own" (invariant 73 is the defect that contract exists to
        // prevent). Same for the line pitch below.
        paper: if s.paper_is_declared { s.paper.as_ref().map(paper_geometry_back) } else { None },
        hides_header: s.hides_header,
        hides_footer: s.hides_footer,
        hides_master_page: s.hides_master_page,
        page_number_start: s.page_numbering.start,
        line_grid_pitch: if s.line_grid_is_declared { s.line_grid_points } else { None },
        is_vertical: s.is_vertical,
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
        edge_borders_ref: None,
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

    /// The top-level arrays `project`'s own callers (`fastdoc_read_office_json`) actually read —
    /// decoded through the SAME `OfficeBlock`/`OfficeComment`/`OfficeSectionDeclaration` types the
    /// encoder used, so these tests assert on the round-tripped Rust values rather than guessing
    /// this module's JSON shape.
    #[derive(serde::Deserialize)]
    struct ProjectedEnvelope {
        blocks: Vec<OfficeBlock>,
        comments: Vec<OfficeComment>,
        #[serde(default)]
        sections: Vec<ob::OfficeSectionDeclaration>,
        #[serde(default)]
        section_start_blocks: Vec<i64>,
        /// The DOCUMENT's own page and line grid, decoded here so a test can check them against a
        /// section's — the two are separate facts and the pair is what proves neither layer is
        /// reading the other's answer.
        #[serde(default)]
        page_content_width: Option<f64>,
        #[serde(default)]
        line_grid_pitch: Option<f64>,
    }

    fn projected(result: &ob::OfficeReadResult) -> ProjectedEnvelope {
        let tree = ValidatedRenderTree::from_office(input(result)).expect("tree builds");
        let json = project(&tree).expect("project succeeds on this fixture");
        serde_json::from_str(&json).expect("project's output is valid schema-v4 JSON")
    }

    /// S6-6's first unblock: a comment ANCHORED IN THE BODY used to send the whole document back
    /// to the legacy exporter. `convert_run` returned `ProjectionError::Field("span.comment_ids")`
    /// for any run carrying one, because a wire comment id is a fresh mint and nothing in the tree
    /// said which source comment it stood for — the map lived in `office_adapter`'s build state and
    /// was thrown away. So every commented document bypassed the canonical tree entirely, and the
    /// bypass was invisible: the fallback output is correct, so nothing failed.
    ///
    /// `wire::Comment.source_id` supplied the missing half, and the bail became a lookup. This test
    /// is what proves the tree path is now TAKEN rather than merely available: it asserts the span
    /// comes back naming the document's own comment id. Reinstating the bail makes `project` fail
    /// outright here rather than silently answer from the other path.
    #[test]
    fn a_comment_anchored_in_the_body_no_longer_sends_the_whole_document_to_the_fallback() {
        let mut result = ob::OfficeReadResult::default();
        result.comments.push(OfficeComment {
            id: SwiftString::from("7"),
            author: Some(SwiftString::from("Dana")),
            date_iso: None,
            text: SwiftString::from("Anchored comment"),
            number: 1,
        });
        result.blocks.push(OfficeBlock::Paragraph {
            spans: vec![Span {
                text: SwiftString::from("Commented text."),
                comment_ids: vec![SwiftString::from("7")],
                ..Default::default()
            }],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(), format_ref: None,
        });
        let doc = projected(&result);
        let OfficeBlock::Paragraph { spans, .. } = &doc.blocks[0] else {
            panic!("expected a paragraph");
        };
        assert_eq!(
            spans[0].comment_ids,
            vec![SwiftString::from("7")],
            "the run must name the comment by the id the DOCUMENT gave it, resolved through the \
             tree rather than by falling back out of it"
        );
        assert_eq!(doc.comments.len(), 1, "and the comment itself is still listed");
        assert_eq!(doc.comments[0].id, SwiftString::from("7"));
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
            format: ParagraphFormat::default(), format_ref: None,
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
    /// `comment_ids`) was silently eaten even on a successful tree projection. This fixture keeps
    /// a comment with NO referencing span deliberately, because that is the case the hardcode ate:
    /// when the defect was found, a comment WITH a body range did not reach this code at all — it
    /// hit `convert_run`'s bail and fell back to `office_export::to_json(&OfficeReadResult)`, which
    /// was already correct and would have passed with `comments: []` still hardcoded, proving
    /// nothing. That bail is gone (S6-6), so an anchored comment now reaches here too; this fixture
    /// stays orphan-only so it keeps biting the ORPHAN path specifically rather than being carried
    /// by the anchored one. Reverting the fix (hardcoding `[]` again) makes `comments` empty here.
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
            format: ParagraphFormat::default(), format_ref: None,
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

    /// S6-8's unblock: `office_adapter`'s `UnsupportedGraphic` arm used to discard `size` and
    /// `alignment` (`size: _, alignment: _`), which is what forced this exact arm to refuse
    /// `ProjectionError::Field("unsupportedGraphic.size")` — every document with a chart, SmartArt
    /// diagram or OLE object bypassed the canonical tree entirely. This asserts specific
    /// NON-default values (a size that is not `0x0`, an alignment that is not `.natural`) survive
    /// the full `OfficeBlock -> wire -> OfficeBlock` round trip, so a regression that reconstructs
    /// a default instead of the tree's actual value cannot hide behind a fixture that happens to
    /// use the default.
    #[test]
    fn an_unsupported_graphics_size_and_alignment_round_trip_through_project() {
        let mut result = ob::OfficeReadResult::default();
        result.blocks.push(OfficeBlock::UnsupportedGraphic {
            label: SwiftString::from("Chart 1"),
            size: CGSize::new(42.0, 17.0),
            alignment: Some(NSTextAlignment::Right),
        });
        let doc = projected(&result);
        let OfficeBlock::UnsupportedGraphic { label, size, alignment } = &doc.blocks[0] else {
            panic!("expected an UnsupportedGraphic block, got {:?}", doc.blocks[0]);
        };
        assert_eq!(*label, SwiftString::from("Chart 1"));
        assert_eq!(size.width, 42.0, "the tree's own width, not a guessed 0");
        assert_eq!(size.height, 17.0, "the tree's own height, not a guessed 0");
        assert_eq!(
            *alignment,
            Some(NSTextAlignment::Right),
            "the tree's own alignment, not a guessed absence"
        );
    }

    /// The one genuine ambiguity `declared_section_count` exists to resolve (`wire::Document`'s
    /// own doc): a source that declared NO sections builds the identical single-`Section` tree a
    /// source that declared exactly one does. `[]` is the honest answer for the former; a real
    /// one-element array — carrying the declared value, not a default — for the latter.
    #[test]
    /// The document's own page is a DIFFERENT fact from any section's, and a section that named no
    /// page of its own must not come back claiming the document's. `office_adapter` deliberately
    /// fills `wire::Section.paper` with the document's geometry so the section has an effective
    /// sheet to lay out against; reading that back as a DECLARATION is what
    /// `OfficeSectionDeclaration.paper`'s own contract forbids (`nil` = "this section stated no page
    /// of its own"), and invariant 73 is the defect that contract exists to prevent -- a 612pt
    /// appendix page typeset on the body's 555pt sheet. The two assertions here are the two halves:
    /// the document keeps its geometry, and the section does not borrow it.
    #[test]
    fn a_section_that_declared_no_page_does_not_report_the_documents_as_its_own() {
        let result = ob::OfficeReadResult {
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(), format_ref: None,
            }],
            sections: vec![ob::OfficeSectionDeclaration {
                hides_header: true,
                ..ob::OfficeSectionDeclaration::default()
            }],
            page_content_width: Some(400.0),
            page_content_height: Some(600.0),
            page_margin_left: Some(50.0),
            page_margin_right: Some(50.0),
            page_margin_top: Some(60.0),
            page_margin_bottom: Some(60.0),
            line_grid_pitch: Some(15.0),
            ..ob::OfficeReadResult::default()
        };
        let doc = projected(&result);
        assert_eq!(
            doc.page_content_width,
            Some(400.0),
            "the document's own page must survive -- it is carried on `wire::Document`"
        );
        assert_eq!(doc.line_grid_pitch, Some(15.0), "the document's own line grid must survive");
        assert_eq!(doc.sections.len(), 1);
        assert!(doc.sections[0].hides_header, "the fixture's section really is a declared one");
        assert_eq!(
            doc.sections[0].paper, None,
            "this section named no page, so it must report none -- reporting the document's would \
             state a declaration the source never made"
        );
        assert_eq!(
            doc.sections[0].line_grid_pitch, None,
            "same for the line grid: inherited is not declared"
        );
    }

    /// The other half of the pair above, and the reason a single `paper_is_declared` bit is not
    /// enough on its own: a section that DID name its own page must still report it, and the
    /// document's own geometry must not be overwritten by that section's. Before
    /// `wire::Document.document_paper` existed, `project` read the document's page and line grid off
    /// section zero, so a section declaring either one silently replaced the document's answer.
    #[test]
    fn a_section_that_declared_its_own_page_reports_it_without_replacing_the_documents() {
        let result = ob::OfficeReadResult {
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(), format_ref: None,
            }],
            sections: vec![ob::OfficeSectionDeclaration {
                paper: Some(ob::PaperGeometry {
                    content_width: 300.0,
                    content_height: 500.0,
                    margin_left: 10.0,
                    margin_top: 20.0,
                    margin_right: 30.0,
                    margin_bottom: 40.0,
                }),
                line_grid_pitch: Some(9.0),
                ..ob::OfficeSectionDeclaration::default()
            }],
            page_content_width: Some(400.0),
            page_content_height: Some(600.0),
            page_margin_left: Some(50.0),
            page_margin_right: Some(50.0),
            page_margin_top: Some(60.0),
            page_margin_bottom: Some(60.0),
            line_grid_pitch: Some(15.0),
            ..ob::OfficeReadResult::default()
        };
        let doc = projected(&result);
        let declared = doc.sections[0].paper.expect("the section declared a page of its own");
        assert_eq!(declared.content_width, 300.0, "the SECTION's width, not the document's 400");
        assert_eq!(doc.sections[0].line_grid_pitch, Some(9.0), "the section's own pitch");
        assert_eq!(
            doc.page_content_width,
            Some(400.0),
            "the DOCUMENT's width, not the section's 300 -- the two layers are separate facts"
        );
        assert_eq!(doc.line_grid_pitch, Some(15.0), "the document's own pitch, not the section's 9");
    }

    fn zero_declared_sections_projects_empty_and_one_declared_projects_one_real_element() {
        let none_declared = ob::OfficeReadResult {
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(), format_ref: None,
            }],
            ..ob::OfficeReadResult::default()
        };
        let doc = projected(&none_declared);
        assert_eq!(
            doc.sections.len(),
            0,
            "a source that declared no sections must project an empty array, not a synthesised one"
        );

        let one_declared = ob::OfficeReadResult {
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(), format_ref: None,
            }],
            sections: vec![ob::OfficeSectionDeclaration {
                hides_header: true,
                is_vertical: true,
                page_number_start: Some(3),
                ..ob::OfficeSectionDeclaration::default()
            }],
            ..ob::OfficeReadResult::default()
        };
        let doc = projected(&one_declared);
        assert_eq!(
            doc.sections.len(),
            1,
            "a source that declared exactly one section must project one real element"
        );
        assert!(doc.sections[0].hides_header, "the declared value, not the default false");
        assert!(doc.sections[0].is_vertical, "the declared value, not the default false");
        assert_eq!(doc.sections[0].page_number_start, Some(3));
    }

    /// `section_start_blocks[i]` must be the real index each section's own blocks begin at in the
    /// reconstructed `blocks` array — not `[]`, and not a guess. Section one contributes two
    /// blocks, so section two must start at index 2, never 1 or 0.
    #[test]
    fn section_start_blocks_matches_the_source_s_own_indices_for_a_two_section_document() {
        let paragraph = |text: &str| OfficeBlock::Paragraph {
            spans: vec![Span { text: text.into(), ..Span::default() }],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(), format_ref: None,
        };
        let result = ob::OfficeReadResult {
            blocks: vec![
                paragraph("section one, block zero"),
                paragraph("section one, block one"),
                paragraph("section two, block zero"),
            ],
            sections: vec![
                ob::OfficeSectionDeclaration::default(),
                ob::OfficeSectionDeclaration { is_vertical: true, ..ob::OfficeSectionDeclaration::default() },
            ],
            section_start_blocks: vec![0, 2],
            default_body_font_size: 11.0,
            ..ob::OfficeReadResult::default()
        };
        let doc = projected(&result);
        assert_eq!(
            doc.section_start_blocks,
            vec![0, 2],
            "section two's own blocks begin at index 2, not a guessed 1 or an empty list"
        );
        assert_eq!(doc.blocks.len(), 3, "all three blocks, across both sections, are present");
    }

    /// A single declared section carrying a non-default value on every one of the six
    /// previously-refused fields round-trips through `project` as that value, never the default —
    /// the same non-default discipline `an_unsupported_graphics_size_and_alignment_round_trip_through_project`
    /// above already applies to a different field family.
    #[test]
    fn a_declared_section_s_new_fields_round_trip_as_the_declared_value_not_the_default() {
        let section = ob::OfficeSectionDeclaration {
            footnote_separator: Some(ob::OfficeFootnoteSeparator {
                line_type: 2,
                line_width_pt: 0.6,
                color: Some(NSColor::srgb(0.4, 0.4, 0.4, 1.0)),
                length_pt: Some(100.0),
                margin_top_pt: 4.0,
                margin_bottom_pt: 2.0,
                note_spacing_pt: 1.0,
            }),
            page_border: Some(ob::OfficePageBorder {
                borders: Some(EdgeBorders {
                    top: Some(BorderDecl::Suppressed),
                    left: None,
                    bottom: None,
                    right: None,
                    inside_h: None,
                    inside_v: None,
                }),
                background: Some(NSColor::srgb(0.7, 0.6, 0.5, 1.0)),
                spacing: NSEdgeInsets { top: 9.0, left: 9.0, bottom: 9.0, right: 9.0 },
                measured_from_paper: true,
            }),
            paper: None,
            hides_header: true,
            hides_footer: true,
            hides_master_page: true,
            page_number_start: Some(2),
            line_grid_pitch: Some(15.0),
            is_vertical: true,
        };
        let result = ob::OfficeReadResult {
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(), format_ref: None,
            }],
            sections: vec![section.clone()],
            ..ob::OfficeReadResult::default()
        };
        let doc = projected(&result);
        assert_eq!(doc.sections.len(), 1);
        let got = &doc.sections[0];
        assert!(got.hides_header && got.hides_footer && got.hides_master_page && got.is_vertical);
        assert_eq!(got.page_number_start, section.page_number_start);
        assert_eq!(got.line_grid_pitch, section.line_grid_pitch);
        let fs = got.footnote_separator.as_ref().expect("footnote separator carried");
        assert_eq!(fs.line_type, 2);
        assert_eq!(fs.line_width_pt, 0.6);
        assert_eq!(fs.length_pt, Some(100.0));
        let pb = got.page_border.as_ref().expect("page border carried");
        assert!(pb.measured_from_paper);
        assert_eq!(pb.spacing.top, 9.0);
    }
}
