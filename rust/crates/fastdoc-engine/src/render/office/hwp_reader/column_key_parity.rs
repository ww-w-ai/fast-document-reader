//! S2A2 Pass C, unit C1 — the measurement this sprint's column-authority design rests on, not
//! part of that design itself.
//!
//! A column position is proposed as the triple `(section_index, paragraph_index,
//! control_ordinal_within_paragraph)`, and the whole idea only holds if that triple is derivable
//! IDENTICALLY from two independent walks of the same parsed document: rhwp's own raw model
//! (`Control::ColumnDef` nested inside `sections[i].paragraphs[j].controls[k]`) and the flat JSON
//! envelope this crate already exports for the Swift/host mapping layer (`HwpBlock::Para` spans
//! carrying `column_def`, sectioned by `section_starts`). This file performs both walks against
//! ONE open parse (rhwp is an in-process rlib — no FFI handle, no xcframework, so "one open parse"
//! is simply one `HwpDocument::from_bytes` call reused for both) and reports three independent
//! checks, because key-SET equality alone can agree by coincidence (a dropped paragraph on one
//! side and an extra paragraph-class block elsewhere in the same section shift every later
//! `paragraph_index` but can cancel in the aggregate set comparison):
//!
//! - key sets — do the two walks name the same positions at all
//! - CHECK A — per-section paragraph-COUNT equality (`sections[i].paragraphs.len()` vs the count
//!   of `HwpBlock::Para` blocks that `section_starts` attributes to section `i`), run over every
//!   section regardless of whether it declares a column, because a paragraph-count drift is the
//!   thing that can make the key sets agree for the wrong reason
//! - CHECK B — for every key present in BOTH walks, do the ten fields the JSON `HwpColumnDef` DTO
//!   shares with the raw `ColumnDef` (all of it except `column_type` and `raw_attr`, which the DTO
//!   does not carry) actually agree — this rules out misattachment (two different `ColumnDef`s
//!   swapped onto each other's keys), which key-set equality cannot see either
//!
//! Building the `OfficeColumnLayout` map itself is later work — this file only measures.

use std::collections::{HashMap, HashSet};

use rhwp::model::control::Control;
use rhwp::model::document::Document;
use rhwp::model::page::{ColumnDef, ColumnDirection};
use rhwp::model::paragraph::Paragraph;

use super::schema::{HwpBlock, HwpColumnDef, HwpEnvelope};

/// One column-position key, as either walk names it: `(section_index, paragraph_index,
/// control_ordinal_within_paragraph)`. `control_ordinal` is 0-based among ONLY the `ColumnDef`
/// controls (raw walk) / `columnDef`-bearing spans (JSON walk) in that paragraph — never among
/// all controls/spans, so a paragraph whose first control is a bookmark and second is a column
/// break reports ordinal 0 for the column break, not 1.
pub type ColumnKey = (usize, usize, usize);

/// CHECK A — one section's paragraph count from each walk. `None` on a side means that side has
/// no section at that index at all (the two walks disagreed on section COUNT, not just content).
pub struct SectionParagraphCount {
    pub section_index: usize,
    pub raw_count: Option<usize>,
    pub json_count: Option<usize>,
}

impl SectionParagraphCount {
    pub fn matches(&self) -> bool {
        self.raw_count.is_some() && self.raw_count == self.json_count
    }
}

/// CHECK B — one shared key's field-level corroboration. `mismatched_fields` is empty when every
/// one of the ten shared fields agrees.
pub struct KeyCorroboration {
    pub key: ColumnKey,
    pub mismatched_fields: Vec<&'static str>,
}

/// Both walks' key sets, CHECK A, CHECK B, and the nested-`ColumnDef` count the design does not
/// yet account for.
pub struct ColumnKeyParity {
    /// Keys from `sections[i].paragraphs[j].controls[k]`, filtered to `Control::ColumnDef`.
    pub raw_keys: HashSet<ColumnKey>,
    /// Keys from the flat `blocks` envelope, `section_starts`-sectioned, filtered to
    /// `HwpBlock::Para` spans carrying `column_def`. Empty (never `None`) when the parser predates
    /// `section_starts` — that absence is itself a reportable disagreement, not a walk failure.
    pub json_keys: HashSet<ColumnKey>,
    /// `ColumnDef` controls found anywhere inside a header, footer, footnote, endnote or
    /// table-cell paragraph body, at any nesting depth. Neither key set above can express these
    /// positions (they are not addressed by a body `(section, paragraph, ordinal)` triple at all),
    /// so this is reported as a separate number and never merged into `raw_keys`.
    pub nested_column_def_count: usize,
    /// CHECK A, one entry per section index present on EITHER side.
    pub section_paragraph_counts: Vec<SectionParagraphCount>,
    /// CHECK B, one entry per key present in BOTH `raw_keys` and `json_keys`.
    pub key_corroborations: Vec<KeyCorroboration>,
}

/// Parse `data` once and perform both walks against that single parse.
pub fn compute_column_key_parity(data: &[u8]) -> Result<ColumnKeyParity, String> {
    let doc = rhwp::wasm_api::HwpDocument::from_bytes(data).map_err(|e| e.to_string())?;
    let document = doc.document();

    let raw_map = walk_raw(document);
    let nested_column_def_count = count_nested_column_defs(document);

    let json = doc.export_document_json().map_err(|e| e.to_string())?;
    let envelope: HwpEnvelope =
        serde_json::from_str(&json).map_err(|e| format!("envelope decode failed: {e}"))?;
    let json_map = walk_json(&envelope);

    let section_paragraph_counts = compare_section_paragraph_counts(document, &envelope);

    let raw_keys: HashSet<ColumnKey> = raw_map.keys().copied().collect();
    let json_keys: HashSet<ColumnKey> = json_map.keys().copied().collect();
    let key_corroborations = raw_keys
        .intersection(&json_keys)
        .map(|key| KeyCorroboration {
            key: *key,
            mismatched_fields: corroborate_shared_fields(&raw_map[key], &json_map[key]),
        })
        .collect();

    Ok(ColumnKeyParity {
        raw_keys,
        json_keys,
        nested_column_def_count,
        section_paragraph_counts,
        key_corroborations,
    })
}

/// `sections[i].paragraphs[j].controls[k]`, kept only where `Control::ColumnDef`, keyed by
/// position and holding a clone of the raw `ColumnDef` so CHECK B can compare its fields.
/// Deliberately does NOT recurse into a control's own nested paragraphs (header/footer/footnote/
/// endnote/table cell) — those are `count_nested_column_defs`'s job, kept separate on purpose
/// (see this file's doc comment).
fn walk_raw(document: &Document) -> HashMap<ColumnKey, ColumnDef> {
    let mut out = HashMap::new();
    for (section_index, section) in document.sections.iter().enumerate() {
        for (paragraph_index, paragraph) in section.paragraphs.iter().enumerate() {
            let mut control_ordinal = 0usize;
            for control in &paragraph.controls {
                if let Control::ColumnDef(cd) = control {
                    out.insert((section_index, paragraph_index, control_ordinal), cd.clone());
                    control_ordinal += 1;
                }
            }
        }
    }
    out
}

/// `ColumnDef` controls reachable only through a header, footer, footnote, endnote or table-cell
/// paragraph body — i.e. everything `walk_raw` deliberately does not count, at any nesting depth
/// (a table inside a footnote inside a header all count once each, wherever they land).
fn count_nested_column_defs(document: &Document) -> usize {
    let mut count = 0usize;
    for section in &document.sections {
        for paragraph in &section.paragraphs {
            for control in &paragraph.controls {
                count += nested_container_column_defs(control);
            }
        }
    }
    count
}

/// If `control` is one of the five nested-body kinds, the `ColumnDef` count inside its paragraph
/// body (recursively) — otherwise 0.
fn nested_container_column_defs(control: &Control) -> usize {
    match control {
        Control::Header(h) => count_column_defs_in(&h.paragraphs),
        Control::Footer(f) => count_column_defs_in(&f.paragraphs),
        Control::Footnote(f) => count_column_defs_in(&f.paragraphs),
        Control::Endnote(e) => count_column_defs_in(&e.paragraphs),
        Control::Table(t) => t
            .cells
            .iter()
            .map(|cell| count_column_defs_in(&cell.paragraphs))
            .sum(),
        _ => 0,
    }
}

/// Every `ColumnDef` control inside `paragraphs`, at any depth — a direct hit counts, and any of
/// the five nested-body kinds recurses again (a table cell inside a footnote, a footnote inside a
/// header, etc.).
fn count_column_defs_in(paragraphs: &[Paragraph]) -> usize {
    let mut count = 0usize;
    for paragraph in paragraphs {
        for control in &paragraph.controls {
            if matches!(control, Control::ColumnDef(_)) {
                count += 1;
            }
            count += nested_container_column_defs(control);
        }
    }
    count
}

/// The flat `blocks` envelope, sectioned by `section_starts`, kept only where `HwpBlock::Para`
/// carries a span with `column_def`, holding a clone of the JSON DTO so CHECK B can compare its
/// fields. `paragraph_index` counts `Para` blocks seen since that section's start (0-based) — the
/// non-`Para` blocks a paragraph's OWN controls expand into (tables, images, shapes, equations) do
/// not advance it, matching the raw walk's `paragraphs[j]` indexing exactly.
fn walk_json(envelope: &HwpEnvelope) -> HashMap<ColumnKey, HwpColumnDef> {
    let mut out = HashMap::new();
    for (section_index, section_blocks) in section_block_slices(envelope).into_iter().enumerate() {
        let mut paragraph_index = 0usize;
        for block in section_blocks {
            let HwpBlock::Para(para) = block else {
                continue;
            };
            let mut control_ordinal = 0usize;
            for span in &para.spans {
                if let Some(cd) = &span.column_def {
                    out.insert(
                        (section_index, paragraph_index, control_ordinal),
                        cd.clone(),
                    );
                    control_ordinal += 1;
                }
            }
            paragraph_index += 1;
        }
    }
    out
}

/// `envelope.blocks`, cut at `section_starts`' boundaries — the same slicing `walk_json` and
/// `json_section_paragraph_counts` both need, kept in one place so the two never drift apart from
/// each other. Empty (no sections at all) when `section_starts` is absent — a parser too old to
/// section the flat array, which this design cannot address either.
fn section_block_slices(envelope: &HwpEnvelope) -> Vec<&[HwpBlock]> {
    let Some(section_starts) = envelope.section_starts.as_ref() else {
        return Vec::new();
    };
    let total = envelope.blocks.len();
    section_starts
        .iter()
        .enumerate()
        .map(|(i, &start)| {
            let start = (start.max(0) as usize).min(total);
            let end = section_starts
                .get(i + 1)
                .map(|&next| (next.max(0) as usize).min(total))
                .unwrap_or(total);
            envelope.blocks.get(start..end.max(start)).unwrap_or(&[])
        })
        .collect()
}

/// CHECK A — `sections[i].paragraphs.len()` against the count of `HwpBlock::Para` blocks
/// `section_starts` attributes to section `i`, for every section index EITHER walk has, run
/// unconditionally (this does not depend on any column being declared anywhere).
fn compare_section_paragraph_counts(
    document: &Document,
    envelope: &HwpEnvelope,
) -> Vec<SectionParagraphCount> {
    let raw_counts: Vec<usize> = document
        .sections
        .iter()
        .map(|s| s.paragraphs.len())
        .collect();
    let json_counts: Vec<usize> = section_block_slices(envelope)
        .iter()
        .map(|blocks| blocks.iter().filter(|b| matches!(b, HwpBlock::Para(_))).count())
        .collect();

    let section_total = raw_counts.len().max(json_counts.len());
    (0..section_total)
        .map(|section_index| SectionParagraphCount {
            section_index,
            raw_count: raw_counts.get(section_index).copied(),
            json_count: json_counts.get(section_index).copied(),
        })
        .collect()
}

/// CHECK B — the ten fields the JSON `HwpColumnDef` DTO shares with the raw `ColumnDef`
/// (`Vendor/rhwp-src/src/model/page.rs:120-146`), reproducing the SAME conversion
/// `document_json.rs`'s `ColumnDefDto` construction applies (unit scaling, `skip_serializing_if`
/// defaults, the `separatorColor`-only-when-`separatorType != 0` rule) so a correctly-mapped pair
/// compares equal. `column_type` and `raw_attr` are excluded by design — the DTO never carries
/// them, so they are not shared fields to corroborate.
fn corroborate_shared_fields(raw: &ColumnDef, json: &HwpColumnDef) -> Vec<&'static str> {
    let mut mismatched = Vec::new();

    if json.column_count != raw.column_count as i64 {
        mismatched.push("column_count");
    }

    let expected_direction = match raw.direction {
        ColumnDirection::LeftToRight => "leftToRight",
        ColumnDirection::RightToLeft => "rightToLeft",
    };
    if json.direction.as_deref() != Some(expected_direction) {
        mismatched.push("direction");
    }

    if json.same_width.unwrap_or(false) != raw.same_width {
        mismatched.push("same_width");
    }
    if json.proportional_widths.unwrap_or(false) != raw.proportional_widths {
        mismatched.push("proportional_widths");
    }
    if json.separator_type.unwrap_or(0) != raw.separator_type as i64 {
        mismatched.push("separator_type");
    }
    if json.separator_width.unwrap_or(0) != raw.separator_width as i64 {
        mismatched.push("separator_width");
    }

    let expected_separator_color = (raw.separator_type != 0).then(|| color_hex(raw.separator_color));
    if json.separator_color != expected_separator_color {
        mismatched.push("separator_color");
    }

    let expected_spacing_pt = raw.spacing as f64 / 100.0;
    if (json.column_spacing_pt.unwrap_or(0.0) - expected_spacing_pt).abs() > 1e-6 {
        mismatched.push("column_spacing_pt");
    }

    let expected_widths = scaled_units(raw.same_width, raw.proportional_widths, &raw.widths);
    if !approx_eq_vec(json.column_widths.as_deref().unwrap_or(&[]), &expected_widths) {
        mismatched.push("column_widths");
    }

    let expected_gaps = scaled_units(raw.same_width, raw.proportional_widths, &raw.gaps);
    if !approx_eq_vec(json.column_gaps.as_deref().unwrap_or(&[]), &expected_gaps) {
        mismatched.push("column_gaps");
    }

    mismatched
}

/// `ColumnDefDto`'s width/gap conversion: empty when `same_width` (the DTO omits them entirely in
/// that case), otherwise proportional values pass through unscaled and absolute HWPUNIT values are
/// divided by 100 to points — exactly `document_json.rs`'s own `column_widths`/`column_gaps`
/// construction.
fn scaled_units(same_width: bool, proportional: bool, values: &[i16]) -> Vec<f64> {
    if same_width {
        return Vec::new();
    }
    values
        .iter()
        .map(|v| if proportional { *v as f64 } else { *v as f64 / 100.0 })
        .collect()
}

fn approx_eq_vec(a: &[f64], b: &[f64]) -> bool {
    a.len() == b.len() && a.iter().zip(b).all(|(x, y)| (x - y).abs() <= 1e-6)
}

/// `document_json.rs`'s own `color_hex` (private to that module, so reproduced here rather than
/// exposed): a `ColorRef` (`u32`, `0x00BBGGRR`) to the `"RRGGBB"` hex string the JSON DTO carries.
fn color_hex(c: u32) -> String {
    let r = c & 0xFF;
    let g = (c >> 8) & 0xFF;
    let b = (c >> 16) & 0xFF;
    format!("{r:02X}{g:02X}{b:02X}")
}

// ---------------------------------------------------------------------------------------------
// Value-based reconciliation ambiguity — the follow-up measurement.
//
// Positional keying is dead: `push_shape_blocks` flattens a text box's paragraphs into the
// top-level block list as SIBLING `Block::Para` entries (`document_json.rs:3251-3254`,
// `:3386`), and the footnote path inserts a synthetic `Block::Para` (`:3936`) — so
// `paragraph_index` drifts between the raw and JSON walks in a fifth of the corpus (CHECK A,
// above), which is exactly what this file's own measurement caught.
//
// The replacement idea: stop keying by position, reconcile by VALUE. Pool every raw `ColumnDef`
// occurrence in the document (body AND nested — everything `count_nested_column_defs` already
// counts, since header/footer/footnote/table-cell bodies go through the SAME `build_blocks` and
// therefore reach the JSON side too), group that pool by the ten fields the JSON DTO shares with
// the raw declaration (excluding `column_type`/`raw_attr`, which the DTO never carries), and let
// a JSON occurrence look itself up by its own ten-field signature. This only works if the
// signature discriminates — this section measures how often it does not.
// ---------------------------------------------------------------------------------------------

/// The ten fields the JSON `HwpColumnDef` DTO shares with the raw `ColumnDef`, converted to the
/// SAME wire shape `corroborate_shared_fields` already reproduces (unit scaling, the
/// `separatorColor`-only-when-`separatorType != 0` rule, `sameWidth`'s width/gap suppression),
/// so a raw occurrence's signature and its JSON counterpart's signature are byte-for-byte the
/// same value when they describe the same declaration — and therefore hash and compare equal.
/// Floats are stored as milli-units (`round(pt * 1000)`) so the signature can be a `HashMap` key
/// at all; `column_spacing_pt`/`column_widths`/`column_gaps` go through the identical `/100.0`
/// division on both sides, so this rounding never manufactures a false split.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ColumnSignature {
    pub column_count: i64,
    pub direction: String,
    pub same_width: bool,
    pub proportional_widths: bool,
    pub separator_type: i64,
    pub separator_width: i64,
    pub separator_color: Option<String>,
    pub column_spacing_pt_milli: i64,
    pub column_widths_milli: Vec<i64>,
    pub column_gaps_milli: Vec<i64>,
}

/// The two fields the DTO does NOT carry — what a resolved match would have to adopt. Kept as
/// `(Debug-formatted column_type, raw_attr)` rather than the raw `ColumnType` enum itself:
/// `ColumnType` derives neither `Eq` nor `Hash` (it is a rendering-model type, not a keying one),
/// and a `Debug` string is exactly as discriminating for counting distinct pairs.
pub type ColumnTypeAttrPair = (String, u16);

/// One signature group's shape — how many raw occurrences share this signature, and how many
/// DISTINCT `(column_type, raw_attr)` pairs those occurrences disagree on. `distinct_pairs.len()
/// <= 1` is RESOLVABLE (every occurrence sharing this signature would adopt the same answer);
/// `>= 2` is AMBIGUOUS (content matching cannot decide between them).
struct SignatureGroup {
    occurrence_count: usize,
    distinct_pairs: HashSet<ColumnTypeAttrPair>,
}

/// One scope's (body-only, or body+nested) aggregate ambiguity numbers for one document.
pub struct SignatureScopeStats {
    pub occurrences: usize,
    pub distinct_signatures: usize,
    pub resolvable_signatures: usize,
    pub ambiguous_signatures: usize,
    /// Occurrence-weighted, not signature-weighted — one bad signature covering 300 occurrences
    /// must outweigh ten signatures covering one occurrence each.
    pub ambiguous_occurrences: usize,
}

/// One document's full ambiguity report: the raw pool grouped two ways (`all` = body+nested per
/// the replacement design, `body_only` = the restriction the design decides whether it needs),
/// plus how many JSON-side occurrences (anywhere in the document — body, headers, footers,
/// footnotes, at any table-cell depth) have no signature match at all in the `all` raw pool.
pub struct ColumnAmbiguityReport {
    pub all: SignatureScopeStats,
    pub body_only: SignatureScopeStats,
    pub json_occurrences_total: usize,
    pub json_occurrences_unmatched: usize,
}

/// Parse `data` once; pool every raw `ColumnDef` (body + nested), group by signature, and check
/// every JSON-side occurrence against that pool.
pub fn compute_column_ambiguity(data: &[u8]) -> Result<ColumnAmbiguityReport, String> {
    let doc = rhwp::wasm_api::HwpDocument::from_bytes(data).map_err(|e| e.to_string())?;
    let document = doc.document();

    let raw_occurrences = collect_raw_occurrences(document);
    let all_items: Vec<(ColumnSignature, ColumnTypeAttrPair)> = raw_occurrences
        .iter()
        .map(|(_, sig, pair)| (sig.clone(), pair.clone()))
        .collect();
    let body_items: Vec<(ColumnSignature, ColumnTypeAttrPair)> = raw_occurrences
        .iter()
        .filter(|(is_body, _, _)| *is_body)
        .map(|(_, sig, pair)| (sig.clone(), pair.clone()))
        .collect();

    let all_map = group_by_signature(&all_items);
    let body_map = group_by_signature(&body_items);

    let json = doc.export_document_json().map_err(|e| e.to_string())?;
    let envelope: HwpEnvelope =
        serde_json::from_str(&json).map_err(|e| format!("envelope decode failed: {e}"))?;
    let json_signatures = collect_json_signatures(&envelope);
    let json_occurrences_total = json_signatures.len();
    let json_occurrences_unmatched = json_signatures
        .iter()
        .filter(|sig| !all_map.contains_key(*sig))
        .count();

    Ok(ColumnAmbiguityReport {
        all: scope_stats(&all_map),
        body_only: scope_stats(&body_map),
        json_occurrences_total,
        json_occurrences_unmatched,
    })
}

/// Every raw `ColumnDef` occurrence in the document, tagged `is_body` (found directly in
/// `sections[i].paragraphs[j].controls`, the SAME scope `walk_raw` above keys by position) vs
/// nested (found through a header/footer/footnote/endnote/table-cell body, the SAME scope
/// `count_nested_column_defs` above counts) — this function's tagged output is that same
/// body/nested split, just returning the values instead of a count.
fn collect_raw_occurrences(document: &Document) -> Vec<(bool, ColumnSignature, ColumnTypeAttrPair)> {
    let mut out = Vec::new();
    for section in &document.sections {
        for paragraph in &section.paragraphs {
            for control in &paragraph.controls {
                if let Control::ColumnDef(cd) = control {
                    out.push((true, raw_signature(cd), type_attr_pair(cd)));
                }
                collect_nested_raw_occurrences(control, &mut out);
            }
        }
    }
    out
}

/// If `control` is one of the five nested-body kinds, every `ColumnDef` occurrence inside it
/// (recursively) — mirrors `nested_container_column_defs`'s traversal exactly, but collects
/// values instead of counting.
fn collect_nested_raw_occurrences(
    control: &Control,
    out: &mut Vec<(bool, ColumnSignature, ColumnTypeAttrPair)>,
) {
    match control {
        Control::Header(h) => collect_raw_occurrences_in(&h.paragraphs, out),
        Control::Footer(f) => collect_raw_occurrences_in(&f.paragraphs, out),
        Control::Footnote(f) => collect_raw_occurrences_in(&f.paragraphs, out),
        Control::Endnote(e) => collect_raw_occurrences_in(&e.paragraphs, out),
        Control::Table(t) => {
            for cell in &t.cells {
                collect_raw_occurrences_in(&cell.paragraphs, out);
            }
        }
        _ => {}
    }
}

fn collect_raw_occurrences_in(
    paragraphs: &[Paragraph],
    out: &mut Vec<(bool, ColumnSignature, ColumnTypeAttrPair)>,
) {
    for paragraph in paragraphs {
        for control in &paragraph.controls {
            if let Control::ColumnDef(cd) = control {
                out.push((false, raw_signature(cd), type_attr_pair(cd)));
            }
            collect_nested_raw_occurrences(control, out);
        }
    }
}

/// Every `HwpColumnDef` occurrence reachable anywhere in the JSON envelope for this document —
/// the flat body `blocks`, PLUS `headers`/`footers`/`footnotes` (rhwp's own flattening of nested
/// header/footer/footnote controls into document-level arrays), descending into any `HwpTable`
/// cell's own `blocks` at any depth (a table cell carries `blocks: Vec<HwpBlock>` via the SAME
/// `build_blocks` the body uses — `document_json.rs`'s `build_table_block`, `blocks:
/// build_blocks(doc, &cell.paragraphs)`). This is the JSON-side mirror of
/// `collect_raw_occurrences`'s full body+nested scope, not just `walk_json`'s body-only slice.
fn collect_json_signatures(envelope: &HwpEnvelope) -> Vec<ColumnSignature> {
    let mut out = Vec::new();
    collect_json_signatures_in(&envelope.blocks, &mut out);
    if let Some(headers) = &envelope.headers {
        for h in headers {
            collect_json_signatures_in(&h.blocks, &mut out);
        }
    }
    if let Some(footers) = &envelope.footers {
        for f in footers {
            collect_json_signatures_in(&f.blocks, &mut out);
        }
    }
    if let Some(footnotes) = &envelope.footnotes {
        for f in footnotes {
            collect_json_signatures_in(&f.blocks, &mut out);
        }
    }
    out
}

fn collect_json_signatures_in(blocks: &[HwpBlock], out: &mut Vec<ColumnSignature>) {
    for block in blocks {
        match block {
            HwpBlock::Para(p) => {
                for span in &p.spans {
                    if let Some(cd) = &span.column_def {
                        out.push(json_signature(cd));
                    }
                }
            }
            HwpBlock::Table(t) => {
                for row in &t.rows {
                    for cell in row {
                        collect_json_signatures_in(&cell.blocks, out);
                    }
                }
            }
            _ => {}
        }
    }
}

/// `(Debug-formatted column_type, raw_attr)` — see `ColumnTypeAttrPair`'s doc comment for why
/// `Debug` rather than the enum itself.
fn type_attr_pair(cd: &ColumnDef) -> ColumnTypeAttrPair {
    (format!("{:?}", cd.column_type), cd.raw_attr)
}

/// A raw `ColumnDef`'s ten shared fields, converted through the SAME wire rule
/// `corroborate_shared_fields` already reproduces (see `scaled_units`/`color_hex` there), then
/// rounded to milli-units so the result can be a `HashMap` key.
fn raw_signature(cd: &ColumnDef) -> ColumnSignature {
    let direction = match cd.direction {
        ColumnDirection::LeftToRight => "leftToRight",
        ColumnDirection::RightToLeft => "rightToLeft",
    }
    .to_string();
    let separator_color = (cd.separator_type != 0).then(|| color_hex(cd.separator_color));
    let spacing_pt = cd.spacing as f64 / 100.0;
    let widths = scaled_units(cd.same_width, cd.proportional_widths, &cd.widths);
    let gaps = scaled_units(cd.same_width, cd.proportional_widths, &cd.gaps);
    ColumnSignature {
        column_count: cd.column_count as i64,
        direction,
        same_width: cd.same_width,
        proportional_widths: cd.proportional_widths,
        separator_type: cd.separator_type as i64,
        separator_width: cd.separator_width as i64,
        separator_color,
        column_spacing_pt_milli: to_milli(spacing_pt),
        column_widths_milli: widths.iter().map(|v| to_milli(*v)).collect(),
        column_gaps_milli: gaps.iter().map(|v| to_milli(*v)).collect(),
    }
}

/// A JSON `HwpColumnDef`'s ten fields, defaulted the SAME way `corroborate_shared_fields` reads
/// them (an omitted `skip_serializing_if` field decodes to `None`, which means the wire's own
/// falsy/zero/empty default), then rounded to milli-units the same as `raw_signature`.
pub(crate) fn json_signature(cd: &HwpColumnDef) -> ColumnSignature {
    ColumnSignature {
        column_count: cd.column_count,
        direction: cd.direction.clone().unwrap_or_default(),
        same_width: cd.same_width.unwrap_or(false),
        proportional_widths: cd.proportional_widths.unwrap_or(false),
        separator_type: cd.separator_type.unwrap_or(0),
        separator_width: cd.separator_width.unwrap_or(0),
        separator_color: cd.separator_color.clone(),
        column_spacing_pt_milli: to_milli(cd.column_spacing_pt.unwrap_or(0.0)),
        column_widths_milli: cd
            .column_widths
            .as_deref()
            .unwrap_or(&[])
            .iter()
            .map(|v| to_milli(*v))
            .collect(),
        column_gaps_milli: cd
            .column_gaps
            .as_deref()
            .unwrap_or(&[])
            .iter()
            .map(|v| to_milli(*v))
            .collect(),
    }
}

fn to_milli(pt: f64) -> i64 {
    (pt * 1000.0).round() as i64
}

fn group_by_signature(
    items: &[(ColumnSignature, ColumnTypeAttrPair)],
) -> HashMap<ColumnSignature, SignatureGroup> {
    let mut map: HashMap<ColumnSignature, SignatureGroup> = HashMap::new();
    for (signature, pair) in items {
        let group = map.entry(signature.clone()).or_insert_with(|| SignatureGroup {
            occurrence_count: 0,
            distinct_pairs: HashSet::new(),
        });
        group.occurrence_count += 1;
        group.distinct_pairs.insert(pair.clone());
    }
    map
}

fn scope_stats(map: &HashMap<ColumnSignature, SignatureGroup>) -> SignatureScopeStats {
    let mut occurrences = 0usize;
    let mut resolvable_signatures = 0usize;
    let mut ambiguous_signatures = 0usize;
    let mut ambiguous_occurrences = 0usize;
    for group in map.values() {
        occurrences += group.occurrence_count;
        if group.distinct_pairs.len() <= 1 {
            resolvable_signatures += 1;
        } else {
            ambiguous_signatures += 1;
            ambiguous_occurrences += group.occurrence_count;
        }
    }
    SignatureScopeStats {
        occurrences,
        distinct_signatures: map.len(),
        resolvable_signatures,
        ambiguous_signatures,
        ambiguous_occurrences,
    }
}

// ---------------------------------------------------------------------------------------------
// S2A2-06 — the reconciliation itself. `compute_column_ambiguity` above measured that the
// ten-field signature discriminates (637-sample corpus: 5,648 raw occurrences, 658 distinct
// signatures, all 658 resolvable, 0 ambiguous, 0 of 5,653 JSON-side occurrences unmatched); this
// builds the map `mapping.rs`'s `column_layout` actually consults, from the SAME raw pool
// `collect_raw_occurrences` walks — reused here rather than widened, because its tuple already
// throws away the owned `ColumnDef` a resolved match needs to keep.
// ---------------------------------------------------------------------------------------------

/// Every raw `ColumnDef` occurrence (body + nested — the identical scope `collect_raw_occurrences`
/// already walks), paired with its ten-field signature, its `(column_type, raw_attr)` pair, and
/// the owned declaration itself.
pub(crate) fn collect_raw_declarations(
    document: &Document,
) -> Vec<(ColumnSignature, ColumnTypeAttrPair, ColumnDef)> {
    let mut out = Vec::new();
    for section in &document.sections {
        for paragraph in &section.paragraphs {
            for control in &paragraph.controls {
                if let Control::ColumnDef(cd) = control {
                    out.push((raw_signature(cd), type_attr_pair(cd), cd.clone()));
                }
                collect_nested_raw_declarations(control, &mut out);
            }
        }
    }
    out
}

/// Mirrors `collect_nested_raw_occurrences`'s traversal exactly, but keeps the owned `ColumnDef`.
fn collect_nested_raw_declarations(
    control: &Control,
    out: &mut Vec<(ColumnSignature, ColumnTypeAttrPair, ColumnDef)>,
) {
    match control {
        Control::Header(h) => collect_raw_declarations_in(&h.paragraphs, out),
        Control::Footer(f) => collect_raw_declarations_in(&f.paragraphs, out),
        Control::Footnote(f) => collect_raw_declarations_in(&f.paragraphs, out),
        Control::Endnote(e) => collect_raw_declarations_in(&e.paragraphs, out),
        Control::Table(t) => {
            for cell in &t.cells {
                collect_raw_declarations_in(&cell.paragraphs, out);
            }
        }
        _ => {}
    }
}

fn collect_raw_declarations_in(
    paragraphs: &[Paragraph],
    out: &mut Vec<(ColumnSignature, ColumnTypeAttrPair, ColumnDef)>,
) {
    for paragraph in paragraphs {
        for control in &paragraph.controls {
            if let Control::ColumnDef(cd) = control {
                out.push((raw_signature(cd), type_attr_pair(cd), cd.clone()));
            }
            collect_nested_raw_declarations(control, out);
        }
    }
}

/// Group `collect_raw_declarations`'s pool by signature. A signature RESOLVES (present in the
/// returned map) only when every occurrence sharing it agrees on `(column_type, raw_attr)` — the
/// two fields the JSON DTO never carries, so a JSON-side occurrence has no way to state them
/// itself and can only adopt them from a raw declaration that shares everything else it DOES
/// state. A signature with two or more distinct pairs is AMBIGUOUS and is left out of the map
/// entirely — content alone cannot decide between them, and `mapping.rs`'s `column_layout` then
/// leaves that declaration exactly as its own ten-field JSON reading already produces it.
pub(crate) fn resolve_column_declarations(document: &Document) -> HashMap<ColumnSignature, ColumnDef> {
    let mut groups: HashMap<ColumnSignature, Vec<(ColumnTypeAttrPair, ColumnDef)>> = HashMap::new();
    for (signature, pair, cd) in collect_raw_declarations(document) {
        groups.entry(signature).or_default().push((pair, cd));
    }
    let mut resolved = HashMap::new();
    for (signature, entries) in groups {
        let distinct: HashSet<&ColumnTypeAttrPair> = entries.iter().map(|(pair, _)| pair).collect();
        if distinct.len() == 1 {
            if let Some((_, cd)) = entries.into_iter().next() {
                resolved.insert(signature, cd);
            }
        }
    }
    resolved
}

#[cfg(test)]
mod reconciliation_tests {
    use super::*;
    use rhwp::model::document::Section;
    use rhwp::model::page::{ColumnDef, ColumnDirection, ColumnType};

    /// A `ColumnDef` with every one of the ten shared fields set to a non-default value, so a
    /// signature computed from it cannot accidentally coincide with the zero-valued default the
    /// other tests rely on staying UNmatched.
    fn sample_column_def(column_type: ColumnType, raw_attr: u16) -> ColumnDef {
        ColumnDef {
            column_type,
            column_count: 2,
            direction: ColumnDirection::RightToLeft,
            same_width: false,
            spacing: 250,
            widths: vec![1000, 1100],
            gaps: vec![100],
            proportional_widths: false,
            separator_type: 4,
            separator_width: 7,
            separator_color: 0x0022_1133,
            raw_attr,
        }
    }

    fn document_with(paragraphs: Vec<Paragraph>) -> Document {
        Document {
            sections: vec![Section { paragraphs, ..Default::default() }],
            ..Default::default()
        }
    }

    fn paragraph_with(controls: Vec<Control>) -> Paragraph {
        Paragraph { controls, ..Default::default() }
    }

    #[test]
    fn a_signature_with_one_distinct_pair_resolves_to_that_declaration() {
        let cd = sample_column_def(ColumnType::Parallel, 0xABCD);
        let document = document_with(vec![paragraph_with(vec![Control::ColumnDef(cd.clone())])]);

        let resolved = resolve_column_declarations(&document);
        // Count first — a lookup on an empty map would also read as "no match", so pin that the
        // pooling actually produced an entry before trusting what is inside it.
        assert_eq!(resolved.len(), 1, "one occurrence, one signature, must resolve to exactly one entry");

        let signature = raw_signature(&cd);
        let matched = resolved.get(&signature).expect("the occurrence's own signature must be the key");
        assert_eq!(matched.column_type, ColumnType::Parallel);
        assert_eq!(matched.raw_attr, 0xABCD);
        assert_eq!(matched.column_count, cd.column_count);
    }

    #[test]
    fn an_unmatched_signature_is_absent_from_the_resolution_map() {
        // The pool contains ONE declaration; a signature that does not match it (a different
        // column_count, so the ten-field signature differs) must not be a key at all.
        let cd = sample_column_def(ColumnType::Normal, 1);
        let document = document_with(vec![paragraph_with(vec![Control::ColumnDef(cd)])]);

        let resolved = resolve_column_declarations(&document);
        assert_eq!(resolved.len(), 1, "sanity: the one real occurrence still resolved");

        let mut different = sample_column_def(ColumnType::Normal, 1);
        different.column_count = 3;
        let missing_signature = raw_signature(&different);
        assert!(
            !resolved.contains_key(&missing_signature),
            "a signature nothing in the pool declared must not resolve"
        );
    }

    #[test]
    fn a_signature_with_two_distinct_pairs_is_ambiguous_and_stays_out_of_the_map() {
        // Two occurrences share every one of the ten fields but disagree on `raw_attr` — a field
        // the signature deliberately excludes, so both land in the SAME group.
        let a = sample_column_def(ColumnType::Normal, 1);
        let b = sample_column_def(ColumnType::Normal, 2);
        assert_eq!(raw_signature(&a), raw_signature(&b), "test setup: must share one signature");

        let document = document_with(vec![
            paragraph_with(vec![Control::ColumnDef(a.clone())]),
            paragraph_with(vec![Control::ColumnDef(b)]),
        ]);

        // Confirm the ambiguity actually exists in the pool before trusting its absence from the
        // resolved map — two distinct pairs, not one and not zero.
        let declarations = collect_raw_declarations(&document);
        assert_eq!(declarations.len(), 2, "both occurrences must have been walked");
        let distinct_pairs: HashSet<&ColumnTypeAttrPair> =
            declarations.iter().map(|(_, pair, _)| pair).collect();
        assert_eq!(distinct_pairs.len(), 2, "test setup: the two occurrences must disagree on the excluded fields");

        let resolved = resolve_column_declarations(&document);
        let signature = raw_signature(&a);
        assert!(
            !resolved.contains_key(&signature),
            "an ambiguous signature must not resolve to either candidate"
        );
    }

    #[test]
    fn a_nested_declaration_inside_a_table_cell_is_pooled() {
        use rhwp::model::table::{Cell, Table};

        let cd = sample_column_def(ColumnType::Distribute, 9);
        let cell = Cell {
            paragraphs: vec![paragraph_with(vec![Control::ColumnDef(cd.clone())])],
            ..Default::default()
        };
        let table = Table { cells: vec![cell], ..Default::default() };
        let document = document_with(vec![paragraph_with(vec![Control::Table(Box::new(table))])]);

        let resolved = resolve_column_declarations(&document);
        assert_eq!(resolved.len(), 1, "the nested declaration must be pooled exactly once");
        assert!(resolved.contains_key(&raw_signature(&cd)));
    }
}
