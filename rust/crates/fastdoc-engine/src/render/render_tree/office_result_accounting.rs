//! Mechanical S2A2 decisions for the complete Office result vocabulary.
#![cfg_attr(not(test), allow(dead_code))]

use crate::render::office::office_block::{
    OfficeAnchoredObject, OfficeComment, OfficeFootnote, OfficeHeaderFooter, OfficeMasterObject,
    OfficeMasterPage, OfficePageNumberRestart, OfficeReadResult, OfficeSectionDeclaration,
    ParagraphAnchor,
};
use std::collections::BTreeMap;

const EXPECTED_DECISIONS: usize = 30;
const EXPECTED_KEYS: &[&str] = &[
    "OfficeReadResult.blocks",
    "OfficeReadResult.comments",
    "OfficeReadResult.images",
    "OfficeReadResult.pictures_declared_without_bytes",
    "OfficeReadResult.picture_pool",
    "OfficeReadResult.edge_border_pool",
    "OfficeReadResult.paragraph_format_pool",
    "OfficeReadResult.vector_graphics",
    "OfficeReadResult.default_body_font_size",
    "OfficeReadResult.declared_faces",
    "OfficeReadResult.page_content_width",
    "OfficeReadResult.page_margin_left",
    "OfficeReadResult.page_margin_right",
    "OfficeReadResult.page_content_height",
    "OfficeReadResult.page_margin_top",
    "OfficeReadResult.page_margin_bottom",
    "OfficeReadResult.page_header_distance",
    "OfficeReadResult.page_footer_distance",
    "OfficeReadResult.headers",
    "OfficeReadResult.footers",
    "OfficeReadResult.footnotes",
    "OfficeReadResult.master_pages",
    "OfficeReadResult.sections",
    "OfficeReadResult.anchored_objects",
    "OfficeReadResult.section_start_blocks",
    "OfficeReadResult.keep_with_next_blocks",
    "OfficeReadResult.page_break_blocks",
    "OfficeReadResult.hide_page_number_blocks",
    "OfficeReadResult.page_number_restart_blocks",
    "OfficeReadResult.line_grid_pitch",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum AccountingError {
    DuplicateDecision(String),
    DecisionSetMismatch {
        missing: Vec<String>,
        unexpected: Vec<String>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DecisionKind {
    Mapped,
    Derived,
    Refused,
}

struct DecisionToken {
    key: &'static str,
    kind: DecisionKind,
}

#[derive(Debug)]
pub(crate) struct FieldDecisionLedger {
    decisions: BTreeMap<&'static str, DecisionKind>,
}

impl FieldDecisionLedger {
    fn new() -> Self {
        Self {
            decisions: BTreeMap::new(),
        }
    }
    fn record(&mut self, token: DecisionToken) -> Result<(), AccountingError> {
        if self.decisions.insert(token.key, token.kind).is_some() {
            return Err(AccountingError::DuplicateDecision(token.key.into()));
        }
        Ok(())
    }
    fn finish(self) -> Result<Self, AccountingError> {
        self.finish_expected(EXPECTED_KEYS, EXPECTED_DECISIONS)
    }
    fn finish_expected(
        self,
        expected_keys: &[&'static str],
        expected_count: usize,
    ) -> Result<Self, AccountingError> {
        let expected: std::collections::BTreeSet<_> = expected_keys.iter().copied().collect();
        let actual: std::collections::BTreeSet<_> = self.decisions.keys().copied().collect();
        if actual != expected {
            return Err(AccountingError::DecisionSetMismatch {
                missing: expected
                    .difference(&actual)
                    .map(|value| (*value).into())
                    .collect(),
                unexpected: actual
                    .difference(&expected)
                    .map(|value| (*value).into())
                    .collect(),
            });
        }
        debug_assert_eq!(self.decisions.len(), expected_count);
        Ok(self)
    }
    pub(crate) fn decision_count(&self) -> usize {
        self.decisions.len()
    }
    /// The recorded kind for one key. Counts alone cannot tell a field that was flipped from
    /// refused to mapped from one that was always mapped, and that flip is exactly how a dropped
    /// document fact would pass as parity.
    #[cfg(test)]
    fn kind_of(&self, key: &str) -> Option<DecisionKind> {
        self.decisions.get(key).copied()
    }
    pub(crate) fn derived_count(&self) -> usize {
        self.decisions
            .values()
            .filter(|kind| matches!(kind, DecisionKind::Derived))
            .count()
    }
    pub(crate) fn refused_count(&self) -> usize {
        self.decisions
            .values()
            .filter(|kind| matches!(kind, DecisionKind::Refused))
            .count()
    }
    pub(crate) fn mapped_count(&self) -> usize {
        self.decisions
            .values()
            .filter(|kind| matches!(kind, DecisionKind::Mapped))
            .count()
    }
}

fn mapped(key: &'static str) -> DecisionToken {
    DecisionToken {
        key,
        kind: DecisionKind::Mapped,
    }
}
fn derived(key: &'static str) -> DecisionToken {
    DecisionToken {
        key,
        kind: DecisionKind::Derived,
    }
}
fn refused(key: &'static str) -> DecisionToken {
    DecisionToken {
        key,
        kind: DecisionKind::Refused,
    }
}

macro_rules! record {
    ($ledger:ident, $prefix:literal, $($field:ident),+ $(,)?) => {$({
        let _ = &$field;
        $ledger.record(mapped(concat!($prefix, ".", stringify!($field))))?;
    })+};
}

pub(crate) fn account_office_read_result(
    result: &OfficeReadResult,
) -> Result<FieldDecisionLedger, AccountingError> {
    let mut ledger = FieldDecisionLedger::new();

    let OfficeReadResult {
        blocks,
        comments,
        images,
        pictures_declared_without_bytes,
        picture_pool,
        edge_border_pool,
        paragraph_format_pool,
        vector_graphics,
        default_body_font_size,
        declared_faces,
        page_content_width,
        page_margin_left,
        page_margin_right,
        page_content_height,
        page_margin_top,
        page_margin_bottom,
        page_header_distance,
        page_footer_distance,
        headers,
        footers,
        footnotes,
        master_pages,
        sections,
        anchored_objects,
        section_start_blocks,
        keep_with_next_blocks,
        page_break_blocks,
        hide_page_number_blocks,
        page_number_restart_blocks,
        line_grid_pitch } = result;

    record!(
        ledger,
        "OfficeReadResult",
        blocks,
        comments,
        images,
        pictures_declared_without_bytes,
        vector_graphics,
        headers,
        footers,
        footnotes,
        sections,
        line_grid_pitch
    );

    for (key, value) in [
        ("OfficeReadResult.page_content_width", page_content_width),
        ("OfficeReadResult.page_margin_left", page_margin_left),
        ("OfficeReadResult.page_margin_right", page_margin_right),
        ("OfficeReadResult.page_content_height", page_content_height),
        ("OfficeReadResult.page_margin_top", page_margin_top),
        ("OfficeReadResult.page_margin_bottom", page_margin_bottom),
    ] {
        let _ = value;
        ledger.record(derived(key))?;
    }
    let _ = section_start_blocks;
    ledger.record(derived("OfficeReadResult.section_start_blocks"))?;

    // `picture_pool` exists only on a WIRE that chooses to pool — a result reaching this
    // ledger always has it empty. The canonical tree carries the same bytes in its own
    // hash-keyed resource table, which is where the pooling idea came from — so it is derived,
    // not dropped, and asserting it is empty here says out loud that a reader is never the
    // thing that fills it.
    debug_assert!(picture_pool.is_empty(), "picture_pool is a wire field, not a reader's output");
    let _ = picture_pool;
    ledger.record(derived("OfficeReadResult.picture_pool"))?;
    // Same shape and same reason as `picture_pool` above, for the field P4b pooled: a wire
    // encoder fills it, so a reader's own result never carries one.
    debug_assert!(
        edge_border_pool.is_empty(),
        "edge_border_pool is a wire field, not a reader's output"
    );
    let _ = edge_border_pool;
    ledger.record(derived("OfficeReadResult.edge_border_pool"))?;
    // Same shape and same reason as `picture_pool`/`edge_border_pool` above, for the paragraph
    // format pool: a wire encoder fills it, so a reader's own result never carries one.
    debug_assert!(
        paragraph_format_pool.is_empty(),
        "paragraph_format_pool is a wire field, not a reader's output"
    );
    let _ = paragraph_format_pool;
    ledger.record(derived("OfficeReadResult.paragraph_format_pool"))?;

    // The four pagination facts are block-index lists re-keyed onto the node that owns the block
    // (`ParagraphPagination`). Deterministic and reversible by walking nodes in source order, so
    // `derived` rather than `mapped` — the source shape and the canonical shape are not the same.
    for (key, present) in [
        ("OfficeReadResult.keep_with_next_blocks", !keep_with_next_blocks.is_empty()),
        ("OfficeReadResult.page_break_blocks", !page_break_blocks.is_empty()),
        ("OfficeReadResult.hide_page_number_blocks", !hide_page_number_blocks.is_empty()),
        (
            "OfficeReadResult.page_number_restart_blocks",
            !page_number_restart_blocks.is_empty(),
        ),
    ] {
        let _ = present;
        ledger.record(derived(key))?;
    }

    // MAPPED: carried unchanged on `wire::Document.default_body_font_size`, once per document.
    // This entry used to read "derived", on the reasoning that every run carried the resolved
    // answer so nothing was lost. Something WAS lost — stamping the default onto each run made a
    // run that declared the default and a run that inherited it the same bytes, and the reverse
    // projection then guessed between them by frequency, which is wrong on every short document
    // (invariant 107). A default copied onto every consumer is smeared, not carried.
    let _ = default_body_font_size;
    ledger.record(mapped("OfficeReadResult.default_body_font_size"))?;
    // Carried onto `wire::Document.declared_faces`, keyed by the same face name, with no
    // reshaping — the office adapter copies this table across unchanged.
    let _ = declared_faces;
    ledger.record(mapped("OfficeReadResult.declared_faces"))?;

    // Straight to `Paper`, beside the margins the same section already carries.
    let _ = page_header_distance;
    ledger.record(mapped("OfficeReadResult.page_header_distance"))?;
    let _ = page_footer_distance;
    ledger.record(mapped("OfficeReadResult.page_footer_distance"))?;
    // S6-3: a 바탕쪽 now becomes a `masterPage` node (`office_adapter::build_master_page_node`),
    // never dropped — see `account_master_page`/`account_master_object` for the field-by-field
    // accounting of what that node and its object children carry.
    let _ = master_pages;
    ledger.record(mapped("OfficeReadResult.master_pages"))?;
    // S6-2: an anchored object's frame/content/paragraph rule now becomes an `anchoredObject`
    // node (`office_adapter::from_office`), never dropped — see `account_anchored_object` and
    // `account_paragraph_anchor` below for the field-by-field accounting of what that node carries.
    let _ = anchored_objects;
    ledger.record(mapped("OfficeReadResult.anchored_objects"))?;

    ledger.finish()
}

const OFFICE_COMMENT_KEYS: &[&str] = &[
    "OfficeComment.id",
    "OfficeComment.author",
    "OfficeComment.date_iso",
    "OfficeComment.text",
    "OfficeComment.number",
];

pub(crate) fn account_office_comment(
    comment: &OfficeComment,
) -> Result<FieldDecisionLedger, AccountingError> {
    let mut ledger = FieldDecisionLedger::new();
    let OfficeComment {
        id,
        author,
        date_iso,
        text,
        number,
    } = comment;
    record!(ledger, "OfficeComment", author, date_iso, text);
    // MAPPED, not derived: `wire::Comment.source_id` carries this string unchanged. It was
    // "derived" while it lived only in the adapter's build-time `comment_id_by_source` map, which
    // meant the reverse projection could not recover it and filled the field with our own mint —
    // a number the document never wrote (invariants 107, 108).
    let _ = id;
    ledger.record(mapped("OfficeComment.id"))?;
    let _ = number;
    ledger.record(derived("OfficeComment.number"))?;
    ledger.finish_expected(OFFICE_COMMENT_KEYS, OFFICE_COMMENT_KEYS.len())
}

const OFFICE_HEADER_FOOTER_KEYS: &[&str] = &[
    "OfficeHeaderFooter.applies_to",
    "OfficeHeaderFooter.blocks",
    "OfficeHeaderFooter.section",
];

pub(crate) fn account_office_header_footer(
    header_footer: &OfficeHeaderFooter,
) -> Result<FieldDecisionLedger, AccountingError> {
    let mut ledger = FieldDecisionLedger::new();
    let OfficeHeaderFooter {
        applies_to,
        blocks,
        section,
    } = header_footer;
    // MAPPED, not refused. This entry said the canonical tree could not carry which pages a running
    // head applies to, while `office_adapter.rs:591` has been converting it onto
    // `wire::HeaderFooter.applies_to`, read back on the host side by
    // `RenderTreeOfficeAdapter.applicability`. The label was stale in the CONSERVATIVE
    // direction — it under-reported the tree, and a sprint reading this ledger to plan what the
    // tree still cannot express would have found a gap that is not there. Proven by round trip,
    // not by reading the code.
    record!(ledger, "OfficeHeaderFooter", blocks, applies_to);
    let _ = section;
    ledger.record(derived("OfficeHeaderFooter.section"))?;
    ledger.finish_expected(OFFICE_HEADER_FOOTER_KEYS, OFFICE_HEADER_FOOTER_KEYS.len())
}

const OFFICE_FOOTNOTE_KEYS: &[&str] = &[
    "OfficeFootnote.number",
    "OfficeFootnote.blocks",
    "OfficeFootnote.section",
];

pub(crate) fn account_office_footnote(
    footnote: &OfficeFootnote,
) -> Result<FieldDecisionLedger, AccountingError> {
    let mut ledger = FieldDecisionLedger::new();
    let OfficeFootnote {
        number,
        blocks,
        section,
    } = footnote;
    record!(ledger, "OfficeFootnote", number, blocks);
    let _ = section;
    ledger.record(derived("OfficeFootnote.section"))?;
    ledger.finish_expected(OFFICE_FOOTNOTE_KEYS, OFFICE_FOOTNOTE_KEYS.len())
}

pub(crate) fn account_page_number_restart(
    restart: &OfficePageNumberRestart,
) -> Result<FieldDecisionLedger, AccountingError> {
    const KEYS: &[&str] = &[
        "OfficePageNumberRestart.block",
        "OfficePageNumberRestart.number",
    ];
    let mut ledger = FieldDecisionLedger::new();
    let OfficePageNumberRestart { block, number } = restart;
    // DERIVED, not refused — and the pair was the clearest sign the label was stale, because the
    // document-level list that holds these was already recorded as `derived` two hundred lines up.
    // A list cannot be derivable while its own elements are refused.
    //
    // `block` is the paragraph's INDEX, which the tree keeps as the node's position rather than as
    // a number (`office_adapter.rs:653` writes `ParagraphPagination.page_number_restart` onto the
    // node itself); `number` rides there unchanged. Walking nodes in source order recovers both
    // (`RenderTreeOfficeAdapter`, host side), which is what makes this derived rather than mapped:
    // the source shape and the canonical shape are not the same. Proven by round trip.
    let _ = (block, number);
    ledger.record(derived("OfficePageNumberRestart.block"))?;
    ledger.record(derived("OfficePageNumberRestart.number"))?;
    ledger.finish_expected(KEYS, KEYS.len())
}

pub(crate) fn account_section_declaration(
    section: &OfficeSectionDeclaration,
) -> Result<FieldDecisionLedger, AccountingError> {
    const KEYS: &[&str] = &[
        "OfficeSectionDeclaration.footnote_separator",
        "OfficeSectionDeclaration.page_border",
        "OfficeSectionDeclaration.paper",
        "OfficeSectionDeclaration.hides_header",
        "OfficeSectionDeclaration.hides_footer",
        "OfficeSectionDeclaration.hides_master_page",
        "OfficeSectionDeclaration.page_number_start",
        "OfficeSectionDeclaration.line_grid_pitch",
        "OfficeSectionDeclaration.is_vertical",
    ];
    let mut ledger = FieldDecisionLedger::new();
    let OfficeSectionDeclaration {
        footnote_separator,
        page_border,
        paper,
        hides_header,
        hides_footer,
        hides_master_page,
        page_number_start,
        line_grid_pitch,
        is_vertical,
    } = section;
    let _ = (
        paper,
        page_number_start,
        line_grid_pitch,
        footnote_separator,
        page_border,
        hides_header,
        hides_footer,
        hides_master_page,
        is_vertical,
    );
    ledger.record(mapped("OfficeSectionDeclaration.paper"))?;
    ledger.record(mapped("OfficeSectionDeclaration.page_number_start"))?;
    ledger.record(mapped("OfficeSectionDeclaration.line_grid_pitch"))?;
    // These six moved from REFUSED to MAPPED once `wire::Section` gained somewhere to put them
    // (`footnote_separator`/`page_border`/`hides_header`/`hides_footer`/`hides_master_page`/
    // `is_vertical` — `wire.rs`'s own field list) and `office_adapter::from_office` started
    // carrying every one of them onto the tree, with the tree -> `OfficeReadResult` projection
    // (`RenderTreeOfficeAdapter.swift`) reconstructing them back for real instead of dropping any
    // document that declared more than one section.
    ledger.record(mapped("OfficeSectionDeclaration.footnote_separator"))?;
    ledger.record(mapped("OfficeSectionDeclaration.page_border"))?;
    ledger.record(mapped("OfficeSectionDeclaration.hides_header"))?;
    ledger.record(mapped("OfficeSectionDeclaration.hides_footer"))?;
    ledger.record(mapped("OfficeSectionDeclaration.hides_master_page"))?;
    ledger.record(mapped("OfficeSectionDeclaration.is_vertical"))?;
    ledger.finish_expected(KEYS, KEYS.len())
}

/// S6-3: `office_adapter::build_master_page_node` carries every one of these three fields into
/// the tree (`applies_to` -> `wire::MasterPage.applies_to`, `objects` -> `object_ids`'
/// `MasterPageObject` children, `section` -> which section node this becomes a child of — never
/// a wire field of its own, since the parent/child edge already states it, the same posture
/// `OfficeHeaderFooter.section` takes).
pub(crate) fn account_master_page(
    page: &OfficeMasterPage,
) -> Result<FieldDecisionLedger, AccountingError> {
    const KEYS: &[&str] = &[
        "OfficeMasterPage.section",
        "OfficeMasterPage.applies_to",
        "OfficeMasterPage.objects",
    ];
    let mut ledger = FieldDecisionLedger::new();
    let OfficeMasterPage {
        section,
        applies_to,
        objects,
    } = page;
    let _ = (section, applies_to, objects);
    for key in KEYS {
        ledger.record(mapped(key))?;
    }
    ledger.finish_expected(KEYS, KEYS.len())
}

/// S6-3: `office_adapter::build_master_page_object_node`/`map_anchored_content` (S6-2's, reused
/// verbatim — see that function's own doc) carry both fields.
pub(crate) fn account_master_object(
    object: &OfficeMasterObject,
) -> Result<FieldDecisionLedger, AccountingError> {
    const KEYS: &[&str] = &["OfficeMasterObject.frame", "OfficeMasterObject.content"];
    let mut ledger = FieldDecisionLedger::new();
    let OfficeMasterObject { frame, content } = object;
    let _ = (frame, content);
    for key in KEYS {
        ledger.record(mapped(key))?;
    }
    ledger.finish_expected(KEYS, KEYS.len())
}

/// S6-2: `office_adapter::build_anchored_object_node`/`map_anchored_content` carry every one of
/// these three fields into the tree (`block_index` -> `anchoredToId`, `object` -> the frame plus
/// an `Image`/`Vector`/`Flow` content child, `paragraph_anchor` -> `wire::ParagraphAnchor` when
/// present) — `account_master_object`/`account_master_page` just above now record the same
/// mapping (S6-3), for the master-object content vocabulary this ledger's `object` reuses.
pub(crate) fn account_anchored_object(
    anchored: &OfficeAnchoredObject,
) -> Result<FieldDecisionLedger, AccountingError> {
    const KEYS: &[&str] = &[
        "OfficeAnchoredObject.block_index",
        "OfficeAnchoredObject.object",
        "OfficeAnchoredObject.paragraph_anchor",
    ];
    let mut ledger = FieldDecisionLedger::new();
    let OfficeAnchoredObject {
        block_index,
        object,
        paragraph_anchor,
    } = anchored;
    let _ = (block_index, object, paragraph_anchor);
    for key in KEYS {
        ledger.record(mapped(key))?;
    }
    ledger.finish_expected(KEYS, KEYS.len())
}

pub(crate) fn account_paragraph_anchor(
    anchor: &ParagraphAnchor,
) -> Result<FieldDecisionLedger, AccountingError> {
    const KEYS: &[&str] = &["ParagraphAnchor.align", "ParagraphAnchor.offset"];
    let mut ledger = FieldDecisionLedger::new();
    let ParagraphAnchor { align, offset } = anchor;
    let _ = (align, offset);
    for key in KEYS {
        ledger.record(mapped(key))?;
    }
    ledger.finish_expected(KEYS, KEYS.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::render::office::office_block::{
        HeaderFooterApplicability, OfficeMasterObjectContent, ParagraphAnchorAlign,
    };

    #[test]
    fn account_office_comment_records_exactly_five_decisions() {
        let comment = OfficeComment {
            id: "1".into(),
            author: None,
            date_iso: None,
            text: "".into(),
            number: 1,
        };
        let ledger = account_office_comment(&comment).unwrap();
        assert_eq!(ledger.decision_count(), 5);
        // 3 -> 4 mapped: `OfficeComment.id` is carried on `wire::Comment.source_id` now, not
        // reshaped away into an adapter-internal map.
        assert_eq!(ledger.mapped_count(), 4);
        assert_eq!(ledger.derived_count(), 1);
        assert_eq!(ledger.refused_count(), 0);
    }

    #[test]
    fn account_office_header_footer_records_exactly_three_decisions() {
        let header_footer = OfficeHeaderFooter {
            applies_to: HeaderFooterApplicability::DefaultPages,
            blocks: Vec::new(),
            section: None,
        };
        let ledger = account_office_header_footer(&header_footer).unwrap();
        assert_eq!(ledger.decision_count(), 3);
        // `applies_to` moved mapped-ward, which is where the adapter and the projection had it all
        // along — see this function's own note.
        assert_eq!(ledger.mapped_count(), 2);
        assert_eq!(ledger.derived_count(), 1);
        assert_eq!(ledger.refused_count(), 0);
    }

    #[test]
    fn account_office_footnote_records_exactly_three_decisions() {
        let footnote = OfficeFootnote {
            number: 1,
            blocks: Vec::new(),
            section: None,
        };
        let ledger = account_office_footnote(&footnote).unwrap();
        assert_eq!(ledger.decision_count(), 3);
        assert_eq!(ledger.mapped_count(), 2);
        assert_eq!(ledger.derived_count(), 1);
        assert_eq!(ledger.refused_count(), 0);
    }

    #[test]
    fn section_and_restart_accounting_are_exhaustive() {
        let section = account_section_declaration(&OfficeSectionDeclaration::default()).unwrap();
        assert_eq!(section.decision_count(), 9);
        // All nine are MAPPED now: `wire::Section` carries every one of
        // `OfficeSectionDeclaration`'s fields, and the tree -> `OfficeReadResult` projection
        // (`RenderTreeOfficeAdapter.swift`) reconstructs them for real instead of refusing a
        // multi-section document outright.
        assert_eq!(section.mapped_count(), 9);
        assert_eq!(section.derived_count(), 0);
        assert_eq!(section.refused_count(), 0);

        let restart = account_page_number_restart(&OfficePageNumberRestart {
            block: 0,
            number: 1,
        })
        .unwrap();
        assert_eq!(restart.decision_count(), 2);
        // Both fields ride on the node the restart belongs to and come back by walking nodes in
        // source order, so they are derived rather than refused. With these two, THIS ledger and
        // every sub-ledger under it record no refusal at all: there is nothing in the office
        // vocabulary the canonical tree cannot carry.
        assert_eq!(restart.derived_count(), 2);
        assert_eq!(restart.refused_count(), 0);
    }

    /// S6-3's `master_pages` was the last top-level field this ledger still recorded `refused` —
    /// with it now `mapped` alongside S6-2's `anchored_objects`, every one of the 27 is `mapped`
    /// or `derived`; `refused_count()` for THIS ledger is honestly zero. A sub-ledger further down
    /// the same object graph (`OfficeSectionDeclaration`'s own six fields, `account_section`) used
    /// to still record `refused` — closed too, once `wire::Section` gained somewhere to carry them
    /// — so this assertion is about the TOP-LEVEL 27 only, not a claim the sub-ledger differs any
    /// more. (S6-5a added `pictures_declared_without_bytes`, `mapped` — see that field's own doc.)
    #[test]
    fn account_office_read_result_records_exactly_twenty_nine_decisions() {
        let result = OfficeReadResult::default();
        let ledger = account_office_read_result(&result).unwrap();
        // P4b added `edge_border_pool`, `derived` for the same reason as `picture_pool`.
        assert_eq!(ledger.decision_count(), 30);
        assert!(ledger.mapped_count() > 0);
        assert!(ledger.derived_count() > 0);
        assert_eq!(ledger.refused_count(), 0);
        assert_eq!(
            ledger.mapped_count() + ledger.derived_count() + ledger.refused_count(),
            30
        );
    }

    /// Both families now record `mapped` for every field: master pages as of S6-3
    /// (`account_master_page`/`account_master_object`), anchored objects as of S6-2
    /// (`account_anchored_object`/`account_paragraph_anchor`) — `office_adapter::from_office`
    /// actually carries every one of them into the tree.
    #[test]
    fn master_page_and_anchored_object_families_are_exhaustively_mapped() {
        let object = OfficeMasterObject {
            frame: swiftshim::CGRect::new(0.0, 0.0, 1.0, 1.0),
            content: OfficeMasterObjectContent::Text(Vec::new()),
        };

        let page = account_master_page(&OfficeMasterPage {
            section: 0,
            applies_to: HeaderFooterApplicability::DefaultPages,
            objects: Vec::new(),
        })
        .unwrap();
        assert_eq!(page.decision_count(), 3);
        assert_eq!(page.mapped_count(), 3);

        let master_object = account_master_object(&object).unwrap();
        assert_eq!(master_object.decision_count(), 2);
        assert_eq!(master_object.mapped_count(), 2);

        let anchored = account_anchored_object(&OfficeAnchoredObject {
            block_index: 0,
            object,
            paragraph_anchor: None,
        })
        .unwrap();
        assert_eq!(anchored.decision_count(), 3);
        assert_eq!(anchored.mapped_count(), 3);

        let anchor = account_paragraph_anchor(&ParagraphAnchor {
            align: ParagraphAnchorAlign::Top,
            offset: 0.0,
        })
        .unwrap();
        assert_eq!(anchor.decision_count(), 2);
        assert_eq!(anchor.mapped_count(), 2);
    }

    #[test]
    fn every_result_field_keeps_its_exact_decision_kind() {
        use DecisionKind::{Derived, Mapped};
        const EXPECTED: &[(&str, DecisionKind)] = &[
            ("OfficeReadResult.blocks", Mapped),
            ("OfficeReadResult.comments", Mapped),
            ("OfficeReadResult.images", Mapped),
            ("OfficeReadResult.pictures_declared_without_bytes", Mapped),
            ("OfficeReadResult.picture_pool", Derived),
            ("OfficeReadResult.edge_border_pool", Derived),
            ("OfficeReadResult.paragraph_format_pool", Derived),
            ("OfficeReadResult.vector_graphics", Mapped),
            ("OfficeReadResult.headers", Mapped),
            ("OfficeReadResult.footers", Mapped),
            ("OfficeReadResult.footnotes", Mapped),
            ("OfficeReadResult.sections", Mapped),
            ("OfficeReadResult.keep_with_next_blocks", Derived),
            ("OfficeReadResult.page_break_blocks", Derived),
            ("OfficeReadResult.line_grid_pitch", Mapped),
            ("OfficeReadResult.page_content_width", Derived),
            ("OfficeReadResult.page_margin_left", Derived),
            ("OfficeReadResult.page_margin_right", Derived),
            ("OfficeReadResult.page_content_height", Derived),
            ("OfficeReadResult.page_margin_top", Derived),
            ("OfficeReadResult.page_margin_bottom", Derived),
            ("OfficeReadResult.section_start_blocks", Derived),
            ("OfficeReadResult.default_body_font_size", Mapped),
            ("OfficeReadResult.declared_faces", Mapped),
            ("OfficeReadResult.page_header_distance", Mapped),
            ("OfficeReadResult.page_footer_distance", Mapped),
            ("OfficeReadResult.master_pages", Mapped),
            ("OfficeReadResult.anchored_objects", Mapped),
            ("OfficeReadResult.hide_page_number_blocks", Derived),
            ("OfficeReadResult.page_number_restart_blocks", Derived),
        ];
        assert_eq!(EXPECTED.len(), EXPECTED_DECISIONS);
        let ledger = account_office_read_result(&OfficeReadResult::default()).unwrap();
        for (key, kind) in EXPECTED {
            assert_eq!(ledger.kind_of(key), Some(*kind), "wrong decision for {key}");
        }
    }

    #[test]
    fn expected_keys_are_exactly_twenty_six() {
        // Name kept ("twenty_six") — the test still proves the invariant its name describes
        // (`EXPECTED_KEYS.len() == EXPECTED_DECISIONS`), it just now checks 28: 27 since S6-5a,
        // and `picture_pool` since P4a (`derived` — a wire-only field, empty in every result that
        // reaches this ledger, whose bytes the canonical tree already holds in its resource table).
        assert_eq!(EXPECTED_KEYS.len(), EXPECTED_DECISIONS);
    }

    #[test]
    fn ledger_rejects_duplicate_decisions() {
        let mut ledger = FieldDecisionLedger::new();
        ledger.record(mapped("x")).unwrap();
        assert!(matches!(
            ledger.record(mapped("x")),
            Err(AccountingError::DuplicateDecision(_))
        ));
    }

    #[test]
    fn ledger_rejects_missing_decisions() {
        let mut ledger = FieldDecisionLedger::new();
        ledger.record(mapped("one")).unwrap();
        assert!(matches!(
            ledger.finish(),
            Err(AccountingError::DecisionSetMismatch { .. })
        ));
    }

    #[test]
    fn ledger_rejects_same_count_substituted_key() {
        let mut ledger = FieldDecisionLedger::new();
        for key in EXPECTED_KEYS.iter().skip(1) {
            ledger.record(mapped(key)).unwrap();
        }
        ledger.record(mapped("bogus.same_count.key")).unwrap();
        assert_eq!(ledger.decision_count(), EXPECTED_DECISIONS);
        let AccountingError::DecisionSetMismatch {
            missing,
            unexpected,
        } = ledger.finish().unwrap_err()
        else {
            panic!("same-count key substitution was accepted or misclassified");
        };
        assert_eq!(missing, vec!["OfficeReadResult.blocks"]);
        assert_eq!(unexpected, vec!["bogus.same_count.key"]);
    }
}
