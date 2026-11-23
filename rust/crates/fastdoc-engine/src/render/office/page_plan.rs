//! The page plan: where every WHOLE BLOCK of a paged document goes (S2 of
//! `docs/plans/pagination-to-engine.md`).
//!
//! No Swift source: both hosts used to decide these things themselves (macOS in
//! `PageBandLayoutDelegate` + `DocumentWindowController.settlePagedTables`, Avalonia in
//! `PageLayout`), and the Avalonia copy had drifted. This module is the one rule set. It is pure
//! arithmetic over HOST-OBSERVED heights — line boxes, row heights, picture heights — keyed by an
//! opaque host key (the RenderTree node id on Avalonia). It carries no text and decides nothing the
//! host must measure: line breaking and glyph metrics stay host facts (plan D1).
//!
//! What it decides:
//! - a hard page break or a section start opens a page ONLY when the current page already holds
//!   something (a break at the top of an empty page is a no-op, never a second page — diagnosis
//!   cause 4);
//! - of two hard breaks with nothing but blank paragraphs between them the earlier is dropped
//!   (invariant 147; `PageBandLayoutDelegate.honouredPageBreaks`), except the break that opens the
//!   document and a break that also starts a section;
//! - keep-with-next: a block whose first line would sit in the last line-height of its page starts
//!   the next page (`PageBandLayoutDelegate`'s own approximation, kept so both hosts agree);
//! - a line, a blank paragraph or a picture that does not fit what is left of its page starts the
//!   next one; an item taller than a page still lands at a page top and overruns it (invariant 142);
//! - a table that overruns its page is carried whole, split at the boundaries no merged cell
//!   crosses, or — when it fits no page — broken at every such boundary (invariants 61, 64, 96).
//!   This is the direct form of `settlePagedTables`' fixpoint: pushes are idempotent, so simulating
//!   the placement once reaches the state the settle loop converges on (diagnosis cause 5);
//! - which section every page belongs to.
//!
//! - a paragraph is split at a LINE index (every line is placed on its own), and a table taller than
//!   the page body it starts on — one that fits no page — is split at LINE index inside its cells,
//!   mid-row, when the host reported the cells' lines (`table_flow.rs`, invariants 61d, 64, 142). The
//!   reader reaches that layout over several passes (its first layout lays every table out whole,
//!   each later one applies what the last measured, and the 1-3 line pulls it records are never
//!   taken back); `plan_pages` replays those passes. A line taller than the page is placed at a
//!   page top and overruns it.
//!
//! Out of scope here (a later slice): header/footer bands, the footnote fixpoint, columns and master
//! pages (S5). A per-page footnote reservation is accepted as an INPUT so a host that runs its own
//! footnote loop can still use the plan.

use super::page_pagination::{LaidOutRow, PagePagination};
pub use super::table_flow::{CellLinePlacement, RowSegment};
use super::table_flow::{flow_table, has_cells, orphan_runs, FlowGeometry, LinePath, PlacedLines, MAX_ROUNDS};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashMap};

/// `PagePlanV1.plan_version` / `PlanInput.plan_version`. A host that sends another value is refused
/// rather than guessed at.
pub const PAGE_PLAN_VERSION: u32 = 1;

/// How far past a page's text bottom an item may reach and still count as fitting — the same hair
/// every placement rule on both hosts already used.
const FIT_TOLERANCE: f64 = 0.01;
/// One page's footnote reservation, subtracted from that page's body.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanNoteBand {
    pub page: u32,
    pub height: f64,
}

/// One table row as the host measured it.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanRow {
    pub height: f64,
    /// `false` when a cell spans across the boundary above this row (row 0: always `false`).
    #[serde(default)]
    pub can_break_above: bool,
    /// The cells that BEGIN in this row, with the line boxes inside them. Only needed from a host
    /// that wants a table taller than a page flowed line by line (`table_flow.rs`); without it such
    /// a table is broken at the rows alone.
    #[serde(default)]
    pub cells: Vec<PlanCell>,
}

/// One line inside a cell: where it stands from the cell's content origin, and how tall.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanLine {
    pub top: f64,
    /// A line's box; for a nested table, its natural height.
    pub height: f64,
    /// The part of the box that is spacing under the glyphs, which a page may let hang past its foot.
    #[serde(default)]
    pub trailing: f64,
    /// A table nested in the cell, standing where this line would: it flows by the same rule.
    #[serde(default)]
    pub rows: Vec<PlanRow>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanCell {
    #[serde(default = "one")]
    pub row_span: u32,
    /// Border plus padding above and below the content.
    #[serde(default)]
    pub pad_top: f64,
    #[serde(default)]
    pub pad_bottom: f64,
    /// The content's own height, padding excluded.
    #[serde(default)]
    pub content_height: f64,
    #[serde(default)]
    pub lines: Vec<PlanLine>,
}

fn one() -> u32 {
    1
}

/// What a block IS, as far as placement goes.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum PlanKind {
    /// Placed line by line: `lines` carries each line box's height.
    Text,
    /// Placed as one unit of `height` (a picture, a rule): spacing included by the host.
    Atomic,
    /// Placed from `rows`.
    Table,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanBlock {
    /// The host's identity for this block (RenderTree node id on Avalonia). Echoed back, never read.
    pub key: i64,
    pub kind: PlanKind,
    #[serde(default)]
    pub section_start: bool,
    #[serde(default)]
    pub page_break_before: bool,
    #[serde(default)]
    pub keep_with_next: bool,
    /// Not part of the page flow at all (a footnote body the host draws at its citing page).
    #[serde(default)]
    pub skip: bool,
    /// A paragraph with no visible text (blank lines, whitespace) — invariant 147's notion of empty.
    #[serde(default)]
    pub empty: bool,
    #[serde(default)]
    pub spacing_before: f64,
    #[serde(default)]
    pub spacing_after: f64,
    /// Text: each line box's height, in order.
    #[serde(default)]
    pub lines: Vec<f64>,
    /// Text: the part of a line box a page may let hang past its foot (HWP's line spacing under the
    /// glyphs, invariant 161). `0` for a producer with no such rule.
    #[serde(default)]
    pub trailing: f64,
    /// Atomic: the block's whole height, spacing included.
    #[serde(default)]
    pub height: f64,
    /// Table: rows in order.
    #[serde(default)]
    pub rows: Vec<PlanRow>,
    /// Table: the document forbids cutting it at a page boundary.
    #[serde(default)]
    pub keeps_whole: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanInput {
    pub plan_version: u32,
    /// The page body height, before any footnote reservation.
    pub content_height: f64,
    /// The reader's "split tables across pages" preference.
    #[serde(default)]
    pub split_tables: bool,
    #[serde(default)]
    pub note_bands: Vec<PlanNoteBand>,
    /// The space between one page's body foot and the next page's body top. Only a table flowed
    /// across pages reads it (a row that runs past a whole page lands on a later one).
    #[serde(default)]
    pub band: f64,
    pub blocks: Vec<PlanBlock>,
}

/// One text line's place: `[block index, line index, page, top]`, `top` page-local in points.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct LinePlacement(pub u32, pub u32, pub u32, pub f64);

/// One non-text block, or one row-bounded piece of a table, placed on a page.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BlockPlacement {
    pub block: u32,
    pub key: i64,
    pub page: u32,
    pub top: f64,
    pub height: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub row_start: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub row_count: Option<u32>,
    /// A table piece the flow cut through the middle of rows: its rows are drawn from
    /// `rowSegments` and `cellLines`, not as whole rows.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub flowed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanPage {
    /// The section (0-based, in section-start order) this page belongs to.
    pub section: u32,
    /// The key of the first block placed on this page; `None` for a page nothing landed on.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_key: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PagePlan {
    pub plan_version: u32,
    pub page_count: u32,
    pub pages: Vec<PlanPage>,
    pub placements: Vec<BlockPlacement>,
    pub lines: Vec<LinePlacement>,
    /// For a flowed table: each row's extent on each page it touches.
    pub row_segments: Vec<RowSegment>,
    /// For a flowed table: each cell line's page and page-local top.
    pub cell_lines: Vec<CellLinePlacement>,
    /// The lines the 1-3 line rule moved to the next page, as `[block, row, cell, item, ...]`.
    pub pulled_lines: Vec<Vec<u32>>,
    /// Tables the plan placed as more than one piece.
    pub split_table_count: u32,
    /// Tables the plan moved whole to the page after the one they would have overrun.
    pub carried_table_count: u32,
    /// Hard breaks dropped by invariant 147.
    pub dropped_break_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanError(pub String);

impl std::fmt::Display for PlanError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Plan every block of a paged document. Pure and deterministic.
pub fn plan_pages(input: &PlanInput) -> Result<PagePlan, PlanError> {
    if input.plan_version != PAGE_PLAN_VERSION {
        return Err(PlanError(format!(
            "unsupported planVersion {} (this engine plans version {PAGE_PLAN_VERSION})",
            input.plan_version
        )));
    }
    if !(input.content_height > 0.0) || !input.content_height.is_finite() {
        return Err(PlanError("contentHeight must be a positive number".into()));
    }
    for (index, block) in input.blocks.iter().enumerate() {
        if !finite_all(block) {
            return Err(PlanError(format!("block {index} carries a non-finite height")));
        }
    }
    let honoured = honoured_breaks(&input.blocks);
    let dropped = input
        .blocks
        .iter()
        .enumerate()
        .filter(|(i, b)| b.page_break_before && !honoured[*i])
        .count() as u32;
    // A table that fits no page flows line by line, and the reader reaches that layout over several
    // passes: its first layout has no record that any table is over-tall, so every table lies where
    // it falls; each later one applies what the last measured, and the 1-3 line pulls it records
    // are never taken back. The plan replays those passes when the host reported cell lines.
    let flowable = input
        .blocks
        .iter()
        .any(|b| !b.skip && b.kind == PlanKind::Table && has_cells(&b.rows));
    let mut pulled: BTreeSet<(u32, LinePath)> = BTreeSet::new();
    if flowable {
        for round in 1..=MAX_ROUNDS {
            let mode = if round == 1 { Mode::Natural } else { Mode::Settled };
            let pass = run_pass(input, &honoured, mode, &pulled);
            let mut added = false;
            for table in &pass.flowed {
                for path in orphan_runs(&input.blocks[table.block as usize].rows, &table.lines) {
                    added |= pulled.insert((table.block, path));
                }
            }
            if !added && round > 1 {
                break;
            }
        }
    }
    let state = run_pass(input, &honoured, Mode::Settled, &pulled);

    let page_count = state.page + 1;
    let mut section = 0u32;
    let mut cursor = 0usize;
    let mut pages = Vec::with_capacity(page_count as usize);
    for page in 0..page_count {
        while cursor < state.section_boundaries.len() && state.section_boundaries[cursor] == page {
            section += 1;
            cursor += 1;
        }
        pages.push(PlanPage { section, first_key: state.first_key.get(page as usize).copied().flatten() });
    }
    Ok(PagePlan {
        plan_version: PAGE_PLAN_VERSION,
        page_count,
        pages,
        placements: state.placements,
        lines: state.lines,
        row_segments: state.row_segments,
        cell_lines: state.cell_lines,
        pulled_lines: pulled
            .iter()
            .map(|(block, path)| std::iter::once(*block).chain(path.iter().copied()).collect())
            .collect(),
        split_table_count: state.split_table_count,
        carried_table_count: state.carried_table_count,
        dropped_break_count: dropped,
    })
}

/// Which layout of the reader a pass stands for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    /// The first layout: nothing is known to be over-tall, so a table is laid out whole where it
    /// falls and its lines are not moved.
    Natural,
    /// A later layout: tables are carried, broken or flowed.
    Settled,
}

/// A flowed table's lines in one pass, for the pull rule.
struct FlowedTable {
    block: u32,
    lines: PlacedLines,
}

fn run_pass<'a>(
    input: &'a PlanInput,
    honoured: &[bool],
    mode: Mode,
    pulled: &'a BTreeSet<(u32, LinePath)>,
) -> State<'a> {
    let note_bands: HashMap<u32, f64> = input.note_bands.iter().map(|n| (n.page, n.height)).collect();
    let mut state = State {
        content_height: input.content_height,
        band: input.band.max(0.0),
        note_bands,
        mode,
        pulled,
        flowed: Vec::new(),
        page: 0,
        cursor: 0.0,
        placements: Vec::new(),
        lines: Vec::new(),
        row_segments: Vec::new(),
        cell_lines: Vec::new(),
        first_key: vec![None],
        section_boundaries: Vec::new(),
        split_table_count: 0,
        carried_table_count: 0,
    };
    for (index, block) in input.blocks.iter().enumerate() {
        if block.skip {
            continue;
        }
        let index = index as u32;
        if block.section_start || (block.page_break_before && honoured[index as usize]) {
            // A break at the top of an empty page is a no-op: the page it would open is this one.
            if state.cursor > 0.0 {
                state.next_page();
            }
            if block.section_start && state.page > 0 {
                state.section_boundaries.push(state.page);
            }
        }
        match block.kind {
            PlanKind::Text => state.place_text(index, block),
            PlanKind::Atomic => state.place_atomic(index, block),
            PlanKind::Table => state.place_table(index, block, input.split_tables),
        }
    }
    state
}

fn finite_all(block: &PlanBlock) -> bool {
    block.spacing_before.is_finite()
        && block.spacing_after.is_finite()
        && block.trailing.is_finite()
        && block.height.is_finite()
        && block.lines.iter().all(|h| h.is_finite())
        && block.rows.iter().all(|r| r.height.is_finite())
}

/// Which hard breaks stand. A hard break is dropped when everything from it up to the next break
/// or section start is blank — the page it would open holds nothing but the paragraph that carried
/// it, and the next break opens another straight after (invariant 147: 94 of the 편람's 185 markers
/// sit on an empty paragraph). Two narrowings, each because the wider rule would claim something
/// unmeasured: the document's FIRST marker stands when nothing but blanks precedes it (the cover),
/// and a break that also begins a section always stands.
fn honoured_breaks(blocks: &[PlanBlock]) -> Vec<bool> {
    let mut honoured: Vec<bool> = blocks.iter().map(|b| b.page_break_before).collect();
    let markers: Vec<usize> = blocks
        .iter()
        .enumerate()
        .filter(|(_, b)| !b.skip && (b.page_break_before || b.section_start))
        .map(|(i, _)| i)
        .collect();
    let Some(&first) = markers.first() else { return honoured };
    let opens_the_document = blocks[..first].iter().all(|b| b.empty || b.skip);
    for pair in markers.windows(2) {
        let (previous, next) = (pair[0], pair[1]);
        let b = &blocks[previous];
        if !b.page_break_before || b.section_start {
            continue;
        }
        if previous == first && opens_the_document {
            continue;
        }
        if blocks[previous..next].iter().all(|b| b.empty || b.skip) {
            honoured[previous] = false;
        }
    }
    honoured
}

struct State<'a> {
    content_height: f64,
    band: f64,
    note_bands: HashMap<u32, f64>,
    mode: Mode,
    pulled: &'a BTreeSet<(u32, LinePath)>,
    flowed: Vec<FlowedTable>,
    page: u32,
    cursor: f64,
    placements: Vec<BlockPlacement>,
    lines: Vec<LinePlacement>,
    row_segments: Vec<RowSegment>,
    cell_lines: Vec<CellLinePlacement>,
    first_key: Vec<Option<i64>>,
    section_boundaries: Vec<u32>,
    split_table_count: u32,
    carried_table_count: u32,
}

impl State<'_> {
    fn body(&self, page: u32) -> f64 {
        self.content_height - self.note_bands.get(&page).copied().unwrap_or(0.0)
    }

    fn next_page(&mut self) {
        self.page += 1;
        self.cursor = 0.0;
        if self.first_key.len() <= self.page as usize {
            self.first_key.resize(self.page as usize + 1, None);
        }
    }

    fn mark_first(&mut self, key: i64) {
        let slot = &mut self.first_key[self.page as usize];
        if slot.is_none() {
            *slot = Some(key);
        }
    }

    /// The one push rule: an item that does not fit what is left of the page starts the next one —
    /// whether or not it would fit a whole page, because an oversized item loses least when it
    /// starts at a page top.
    fn overruns(&self, height: f64) -> bool {
        self.cursor > 0.0 && self.cursor + height > self.body(self.page) + FIT_TOLERANCE
    }

    fn place_text(&mut self, index: u32, block: &PlanBlock) {
        if block.lines.is_empty() {
            return;
        }
        self.cursor += block.spacing_before;
        for (line_index, &height) in block.lines.iter().enumerate() {
            let hangs = block.trailing.max(0.0);
            // The first line of a keep-with-next block that would sit in the last line-height of its
            // page takes the whole block to the next page.
            let keeps = line_index == 0
                && block.keep_with_next
                && self.cursor > 0.0
                && self.cursor + height > self.body(self.page) - height;
            if keeps || self.overruns(height - hangs) {
                self.next_page();
            }
            self.mark_first(block.key);
            self.lines.push(LinePlacement(index, line_index as u32, self.page, self.cursor));
            self.cursor += height;
        }
        self.cursor += block.spacing_after;
    }

    fn place_atomic(&mut self, index: u32, block: &PlanBlock) {
        if self.overruns(block.height) {
            self.next_page();
        }
        self.mark_first(block.key);
        self.placements.push(BlockPlacement {
            block: index,
            key: block.key,
            page: self.page,
            top: self.cursor,
            height: block.height,
            row_start: None,
            row_count: None,
            flowed: false,
        });
        self.cursor += block.height;
    }

    fn flow_table(&mut self, index: u32, block: &PlanBlock) {
        self.cursor += block.spacing_before;
        let geometry = FlowGeometry { content_height: self.content_height, band: self.band, note_bands: &self.note_bands };
        let mine: BTreeSet<LinePath> =
            self.pulled.iter().filter(|(b, _)| *b == index).map(|(_, p)| p.clone()).collect();
        let (flow, every_line) = flow_table(&geometry, index, block, (self.page, self.cursor), &mine, true);
        self.flowed.push(FlowedTable { block: index, lines: every_line });
        while self.page < flow.first_page {
            self.next_page();
        }
        self.mark_first(block.key);
        self.split_table_count += 1;
        // One placement per page the table touches: the rows it holds there, and its extent.
        let mut by_page: std::collections::BTreeMap<u32, (u32, u32, f64, f64)> = std::collections::BTreeMap::new();
        for s in &flow.segments {
            let e = by_page.entry(s.2).or_insert((s.1, s.1, s.3, s.4));
            e.0 = e.0.min(s.1);
            e.1 = e.1.max(s.1);
            e.2 = e.2.min(s.3);
            e.3 = e.3.max(s.4);
        }
        for (page, (first, last, top, bottom)) in by_page {
            if self.first_key.len() <= page as usize {
                self.first_key.resize(page as usize + 1, None);
            }
            if self.first_key[page as usize].is_none() {
                self.first_key[page as usize] = Some(block.key);
            }
            self.placements.push(BlockPlacement {
                block: index,
                key: block.key,
                page,
                top,
                height: bottom - top,
                row_start: Some(first),
                row_count: Some(last - first + 1),
                flowed: true,
            });
        }
        self.row_segments.extend(flow.segments);
        self.cell_lines.extend(flow.lines);
        while self.page < flow.end.0 {
            self.next_page();
        }
        self.cursor = flow.end.1 + block.spacing_after;
    }

    /// The reader's first layout of a table: it lies where it falls, whole, and runs on past the page
    /// foot. An over-tall one reports where its lines fell, which is what the first pulls are read
    /// from.
    fn place_table_naturally(&mut self, index: u32, block: &PlanBlock, total: f64, over_tall: bool) {
        self.cursor += block.spacing_before;
        let geometry = FlowGeometry { content_height: self.content_height, band: self.band, note_bands: &self.note_bands };
        let end = if over_tall {
            let none = BTreeSet::new();
            let (flow, every_line) = flow_table(&geometry, index, block, (self.page, self.cursor), &none, false);
            self.flowed.push(FlowedTable { block: index, lines: every_line });
            flow.end
        } else {
            geometry.normalise(self.page, self.cursor + total)
        };
        while self.page < end.0 {
            self.next_page();
        }
        self.cursor = end.1 + block.spacing_after;
    }

    fn place_table(&mut self, index: u32, block: &PlanBlock, split_tables: bool) {
        let rows = &block.rows;
        let total: f64 = rows.iter().map(|r| r.height).sum();
        let whole = block.spacing_before + total + block.spacing_after;
        let over_tall = total > self.body(self.page) && has_cells(rows);
        if self.mode == Mode::Natural {
            self.place_table_naturally(index, block, total, over_tall);
            return;
        }
        // A table taller than the page body it starts on has nowhere to be carried to: when the host
        // reported its cells' lines it flows line by line, as prose does (`table_flow.rs`).
        if over_tall {
            self.flow_table(index, block);
            return;
        }
        let fits_here = self.cursor + whole <= self.body(self.page) + FIT_TOLERANCE;

        let groups = if fits_here { Vec::new() } else { table_groups(rows) };
        // Where the table would land if carried: a table taller than that page's body has nowhere to
        // be carried to and is broken where it stands, whatever the reader's preference says.
        let fits_a_page = total <= self.body(self.page + 1);
        let breaks_into_groups = groups.len() > 1 && (!fits_a_page || (split_tables && !block.keeps_whole));

        if !breaks_into_groups {
            if self.overruns(whole) {
                self.carried_table_count += 1;
                self.next_page();
            }
            self.mark_first(block.key);
            self.placements.push(BlockPlacement {
                block: index,
                key: block.key,
                page: self.page,
                top: self.cursor,
                height: whole,
                row_start: Some(0),
                row_count: Some(rows.len() as u32),
                flowed: false,
            });
            self.cursor += whole;
            return;
        }

        self.split_table_count += 1;
        self.cursor += block.spacing_before;
        for group in &groups {
            let start = group.first_char as usize;
            let count = group.row_count as usize;
            let piece: f64 = rows[start..start + count].iter().map(|r| r.height).sum();
            // A piece taller than the page body is never pushed: it overruns wherever it starts.
            if self.cursor > 0.0
                && self.cursor + piece > self.body(self.page) + FIT_TOLERANCE
                && piece <= self.body(self.page)
            {
                self.next_page();
            }
            self.mark_first(block.key);
            self.placements.push(BlockPlacement {
                block: index,
                key: block.key,
                page: self.page,
                top: self.cursor,
                height: piece,
                row_start: Some(start as u32),
                row_count: Some(count as u32),
                flowed: false,
            });
            self.cursor += piece;
        }
        self.cursor += block.spacing_after;
    }
}

/// The runs of rows a page break may not cut: `first_char` is the group's first ROW INDEX here.
fn table_groups(rows: &[PlanRow]) -> Vec<super::page_pagination::UnbreakableGroup> {
    let mut top = 0.0;
    let laid_out: Vec<LaidOutRow> = rows
        .iter()
        .enumerate()
        .map(|(i, r)| {
            let row = LaidOutRow::new(i as i64, top, top + r.height, top, r.can_break_above);
            top += r.height;
            row
        })
        .collect();
    PagePagination::unbreakable_groups(&laid_out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(key: i64, lines: &[f64]) -> PlanBlock {
        PlanBlock {
            key,
            kind: PlanKind::Text,
            section_start: false,
            page_break_before: false,
            keep_with_next: false,
            skip: false,
            empty: false,
            spacing_before: 0.0,
            spacing_after: 0.0,
            lines: lines.to_vec(),
            trailing: 0.0,
            height: 0.0,
            rows: Vec::new(),
            keeps_whole: false,
        }
    }

    fn blank(key: i64, height: f64) -> PlanBlock {
        PlanBlock { empty: true, ..text(key, &[height]) }
    }

    fn picture(key: i64, height: f64) -> PlanBlock {
        PlanBlock { kind: PlanKind::Atomic, height, ..text(key, &[]) }
    }

    fn table(key: i64, rows: &[(f64, bool)], keeps_whole: bool) -> PlanBlock {
        PlanBlock {
            kind: PlanKind::Table,
            rows: rows.iter().map(|&(height, can_break_above)| PlanRow { height, can_break_above, cells: Vec::new() }).collect(),
            keeps_whole,
            ..text(key, &[])
        }
    }

    fn input(content_height: f64, blocks: Vec<PlanBlock>) -> PlanInput {
        PlanInput { plan_version: 1, content_height, split_tables: true, note_bands: Vec::new(), band: 0.0, blocks }
    }

    fn pages_of_lines(plan: &PagePlan) -> Vec<u32> {
        plan.lines.iter().map(|l| l.2).collect()
    }

    #[test]
    fn lines_flow_onto_the_next_page_when_they_do_not_fit() {
        let plan = plan_pages(&input(100.0, vec![text(1, &[40.0, 40.0, 40.0, 40.0])])).unwrap();
        assert_eq!(plan.page_count, 2);
        assert_eq!(pages_of_lines(&plan), vec![0, 0, 1, 1]);
        assert_eq!(plan.lines[2].3, 0.0);
    }

    #[test]
    fn a_line_that_ends_exactly_on_the_foot_fits() {
        let plan = plan_pages(&input(100.0, vec![text(1, &[50.0, 50.0, 50.0])])).unwrap();
        assert_eq!(pages_of_lines(&plan), vec![0, 0, 1]);
    }

    #[test]
    fn spacing_is_added_around_a_paragraph_but_never_decides_a_fit() {
        let mut p = text(1, &[40.0, 40.0]);
        p.spacing_before = 10.0;
        p.spacing_after = 15.0;
        let plan = plan_pages(&input(100.0, vec![p, text(2, &[40.0])])).unwrap();
        assert_eq!(plan.lines[0].3, 10.0);
        assert_eq!(plan.lines[1].3, 50.0);
        // 10 + 80 + 15 = 105 consumed: the next line starts past the page, so it is pushed.
        assert_eq!(plan.lines[2].2, 1);
    }

    #[test]
    fn a_hard_break_at_the_top_of_an_empty_page_opens_no_second_page() {
        // Page 0 is full; block 2 (nothing to draw) carries a break and opens page 1; block 3's
        // break finds page 1 still empty and must not open page 2.
        let mut opener = picture(2, 0.0);
        opener.page_break_before = true;
        let mut heading = text(3, &[20.0]);
        heading.page_break_before = true;
        let plan = plan_pages(&input(100.0, vec![text(1, &[100.0]), opener, heading])).unwrap();
        assert_eq!(plan.page_count, 2);
        assert_eq!(plan.lines.last().unwrap().2, 1);
    }

    #[test]
    fn a_break_with_content_above_it_opens_a_page_and_the_first_block_never_does() {
        let mut next = text(2, &[10.0]);
        next.page_break_before = true;
        let plan = plan_pages(&input(100.0, vec![text(1, &[60.0, 60.0]), next])).unwrap();
        assert_eq!(plan.page_count, 3, "page 1 holds a line, so the break opens page 2");

        let mut first = text(1, &[10.0]);
        first.page_break_before = true;
        let plan = plan_pages(&input(100.0, vec![first])).unwrap();
        assert_eq!(plan.page_count, 1, "the document's first block never opens a page");
    }

    #[test]
    fn of_two_breaks_with_only_blanks_between_the_earlier_is_dropped() {
        let mut a = blank(2, 10.0);
        a.page_break_before = true;
        let mut b = text(3, &[10.0]);
        b.page_break_before = true;
        let plan = plan_pages(&input(100.0, vec![text(1, &[10.0]), a, b])).unwrap();
        // a's break is dropped; b's break opens page 1; a stays on page 0.
        assert_eq!(plan.dropped_break_count, 1);
        assert_eq!(plan.page_count, 2);
        assert_eq!(pages_of_lines(&plan), vec![0, 0, 1]);
    }

    #[test]
    fn the_break_that_opens_the_document_and_a_section_start_are_kept() {
        let mut cover = blank(1, 10.0);
        cover.page_break_before = true;
        let mut next = text(2, &[10.0]);
        next.page_break_before = true;
        let plan = plan_pages(&input(100.0, vec![cover, next])).unwrap();
        assert_eq!(plan.dropped_break_count, 0, "the opening break stands");

        let mut a = blank(2, 10.0);
        a.page_break_before = true;
        a.section_start = true;
        let mut b = text(3, &[10.0]);
        b.page_break_before = true;
        let plan = plan_pages(&input(100.0, vec![text(1, &[10.0]), a, b])).unwrap();
        assert_eq!(plan.dropped_break_count, 0, "a break that starts a section stands");
        assert_eq!(plan.page_count, 3);
    }

    #[test]
    fn a_blank_run_that_text_follows_keeps_both_breaks() {
        let mut a = text(2, &[10.0]);
        a.page_break_before = true;
        let mut b = text(3, &[10.0]);
        b.page_break_before = true;
        let plan = plan_pages(&input(100.0, vec![text(1, &[10.0]), a, b])).unwrap();
        assert_eq!(plan.dropped_break_count, 0);
        assert_eq!(plan.page_count, 3);
    }

    #[test]
    fn section_starts_name_the_section_of_every_page_even_on_an_empty_page() {
        let mut s1 = text(2, &[10.0]);
        s1.section_start = true;
        let mut s2 = text(3, &[10.0]);
        s2.section_start = true;
        let mut s0 = text(1, &[10.0]);
        s0.section_start = true;
        let plan = plan_pages(&input(100.0, vec![s0, s1, s2])).unwrap();
        assert_eq!(plan.pages.iter().map(|p| p.section).collect::<Vec<_>>(), vec![0, 1, 2]);

        // Section 1 begins on a page the overflow already opened: no extra page, still section 1.
        let mut s1 = picture(2, 50.0);
        s1.section_start = true;
        let plan = plan_pages(&input(100.0, vec![text(1, &[100.0]), picture(9, 100.0), s1])).unwrap();
        assert_eq!(plan.pages.last().unwrap().section, 1);
    }

    #[test]
    fn keep_with_next_moves_a_block_that_starts_in_the_last_line_of_its_page() {
        let mut heading = text(2, &[20.0]);
        heading.keep_with_next = true;
        // 70 used; the heading's line (20) would end at 90 > 100 - 20: it starts the next page.
        let plan = plan_pages(&input(100.0, vec![text(1, &[70.0]), heading, text(3, &[20.0])])).unwrap();
        assert_eq!(plan.lines[1].2, 1);
        assert_eq!(plan.lines[2].2, 1);

        let mut heading = text(2, &[20.0]);
        heading.keep_with_next = true;
        let plan = plan_pages(&input(100.0, vec![text(1, &[50.0]), heading, text(3, &[20.0])])).unwrap();
        assert_eq!(plan.lines[1].2, 0, "room for the heading and a line after it");

        // At a page top it never moves (there is nowhere better to put it).
        let mut tall = text(1, &[80.0]);
        tall.keep_with_next = true;
        let plan = plan_pages(&input(100.0, vec![tall])).unwrap();
        assert_eq!(plan.page_count, 1);
    }

    #[test]
    fn a_table_that_fits_a_page_is_carried_whole_when_splitting_is_off() {
        let rows = [(30.0, false), (30.0, true), (30.0, true)];
        let mut plan_input = input(100.0, vec![text(1, &[40.0]), table(2, &rows, false)]);
        plan_input.split_tables = false;
        let plan = plan_pages(&plan_input).unwrap();
        assert_eq!(plan.placements.len(), 1);
        assert_eq!((plan.placements[0].page, plan.placements[0].top), (1, 0.0));
        assert_eq!(plan.split_table_count, 0);
    }

    #[test]
    fn a_table_splits_at_row_boundaries_when_splitting_is_on() {
        let rows = [(30.0, false), (30.0, true), (30.0, true)];
        let plan = plan_pages(&input(100.0, vec![text(1, &[40.0]), table(2, &rows, false)])).unwrap();
        // 60 left: rows 0 and 1 stay on page 0, row 2 moves on.
        let pieces: Vec<(u32, f64, Option<u32>, Option<u32>)> =
            plan.placements.iter().map(|p| (p.page, p.top, p.row_start, p.row_count)).collect();
        assert_eq!(pieces, vec![(0, 40.0, Some(0), Some(1)), (0, 70.0, Some(1), Some(1)), (1, 0.0, Some(2), Some(1))]);
        assert_eq!(plan.split_table_count, 1);
    }

    #[test]
    fn a_table_the_document_keeps_whole_is_carried_even_when_splitting_is_on() {
        let rows = [(30.0, false), (30.0, true), (30.0, true)];
        let plan = plan_pages(&input(100.0, vec![text(1, &[40.0]), table(2, &rows, true)])).unwrap();
        assert_eq!(plan.placements.len(), 1);
        assert_eq!(plan.placements[0].page, 1);
    }

    #[test]
    fn rows_a_merged_cell_spans_are_never_separated() {
        // Rows 1 and 2 are welded (row 2 cannot break above): the middle group is 60 tall.
        let rows = [(30.0, false), (30.0, true), (30.0, false), (30.0, true)];
        let plan = plan_pages(&input(100.0, vec![text(1, &[50.0]), table(2, &rows, false)])).unwrap();
        let starts: Vec<(u32, Option<u32>, Option<u32>)> =
            plan.placements.iter().map(|p| (p.page, p.row_start, p.row_count)).collect();
        // 50 left: group 0 (30) fits; group 1 (60) does not and moves; group 2 (30) follows it.
        assert_eq!(starts, vec![(0, Some(0), Some(1)), (1, Some(1), Some(2)), (1, Some(3), Some(1))]);
    }

    #[test]
    fn a_table_taller_than_a_page_is_broken_where_it_stands_whatever_the_preference() {
        let rows: Vec<(f64, bool)> = (0..6).map(|i| (30.0, i > 0)).collect();
        let mut plan_input = input(100.0, vec![text(1, &[20.0]), table(2, &rows, true)]);
        plan_input.split_tables = false;
        let plan = plan_pages(&plan_input).unwrap();
        assert!(plan.placements.len() > 1);
        assert!(plan.page_count >= 3);
        let rows_placed: u32 = plan.placements.iter().map(|p| p.row_count.unwrap()).sum();
        assert_eq!(rows_placed, 6, "every row is placed exactly once");
    }

    #[test]
    fn a_table_with_no_boundary_to_break_at_is_carried_whole() {
        let rows = [(30.0, false), (30.0, false), (30.0, false)];
        let plan = plan_pages(&input(100.0, vec![text(1, &[40.0]), table(2, &rows, false)])).unwrap();
        assert_eq!(plan.placements.len(), 1);
        assert_eq!(plan.placements[0].page, 1);
    }

    #[test]
    fn table_spacing_counts_toward_the_fit_of_a_whole_table_only() {
        let mut t = table(2, &[(50.0, false)], false);
        t.spacing_before = 6.0;
        t.spacing_after = 6.0;
        let plan = plan_pages(&input(100.0, vec![text(1, &[40.0]), t])).unwrap();
        // 40 + 62 > 100: carried; whole height includes both spacings.
        assert_eq!((plan.placements[0].page, plan.placements[0].height), (1, 62.0));
    }

    #[test]
    fn a_footnote_reservation_shortens_only_its_own_page() {
        let mut plan_input = input(100.0, vec![text(1, &[40.0, 40.0, 40.0])]);
        plan_input.note_bands = vec![PlanNoteBand { page: 0, height: 30.0 }];
        let plan = plan_pages(&plan_input).unwrap();
        assert_eq!(pages_of_lines(&plan), vec![0, 1, 1]);
    }

    #[test]
    fn skipped_blocks_take_no_room_and_no_part_in_page_decisions() {
        let mut note = text(9, &[500.0]);
        note.skip = true;
        let plan = plan_pages(&input(100.0, vec![text(1, &[10.0]), note])).unwrap();
        assert_eq!(plan.page_count, 1);
        assert_eq!(plan.lines.len(), 1);
    }

    #[test]
    fn first_key_names_the_first_block_on_every_page() {
        let plan = plan_pages(&input(100.0, vec![text(11, &[60.0]), text(12, &[60.0]), picture(13, 30.0)])).unwrap();
        assert_eq!(plan.pages.iter().map(|p| p.first_key).collect::<Vec<_>>(), vec![Some(11), Some(12)]);
    }

    #[test]
    fn invalid_input_is_refused_rather_than_guessed_at() {
        let mut bad = input(100.0, vec![]);
        bad.plan_version = 2;
        assert!(plan_pages(&bad).is_err());
        assert!(plan_pages(&input(0.0, vec![])).is_err());
        assert!(plan_pages(&input(100.0, vec![text(1, &[f64::NAN])])).is_err());
        assert_eq!(plan_pages(&input(100.0, vec![])).unwrap().page_count, 1);
    }

    fn flow_cell(lines: &[f64]) -> PlanCell {
        let mut top = 0.0;
        let lines = lines
            .iter()
            .map(|&h| {
                let line = PlanLine { top, height: h, trailing: 0.0, rows: Vec::new() };
                top += h;
                line
            })
            .collect();
        PlanCell { row_span: 1, pad_top: 0.0, pad_bottom: 0.0, content_height: top, lines }
    }

    fn flow_table_block(key: i64, rows: Vec<(f64, Vec<PlanCell>)>) -> PlanBlock {
        let rows = rows
            .into_iter()
            .enumerate()
            .map(|(i, (height, cells))| PlanRow { height, can_break_above: i > 0, cells })
            .collect();
        PlanBlock { kind: PlanKind::Table, rows, ..text(key, &[]) }
    }

    #[test]
    fn a_table_taller_than_a_page_flows_line_by_line_through_the_middle_of_a_row() {
        // One row, one cell of ten 20pt lines on a 100pt page that already holds 20pt of text.
        let table = flow_table_block(2, vec![(200.0, vec![flow_cell(&[20.0; 10])])]);
        let plan = plan_pages(&input(100.0, vec![text(1, &[20.0]), table])).unwrap();
        let pages: Vec<u32> = plan.cell_lines.iter().map(|l| l.4).collect();
        assert_eq!(pages, vec![0, 0, 0, 0, 1, 1, 1, 1, 1, 2], "four fit under the text, then five a page");
        assert_eq!(plan.page_count, 3);
        assert!(plan.placements.iter().all(|p| p.flowed), "every piece is marked as cut through its rows");
        let touched: Vec<u32> = plan.placements.iter().map(|p| p.page).collect();
        assert_eq!(touched, vec![0, 1, 2]);
        assert_eq!(plan.row_segments.len(), 3, "the row has one extent per page it crosses");
    }

    #[test]
    fn a_run_of_three_lines_or_fewer_stranded_at_a_foot_starts_the_next_page() {
        // The table follows a 60pt line: two of its 20pt lines fit on page 0 and it goes on. Two
        // lines are not worth the seam, so the first of them starts page 1 and the run follows it.
        let table = flow_table_block(2, vec![(120.0, vec![flow_cell(&[20.0; 6])])]);
        let plan = plan_pages(&input(100.0, vec![text(1, &[60.0]), table])).unwrap();
        assert_eq!(plan.pulled_lines, vec![vec![1, 0, 0, 0]]);
        assert_eq!(plan.cell_lines[0].4, 1);
    }

    #[test]
    fn a_table_with_no_cell_data_is_still_cut_at_its_rows() {
        let rows: Vec<PlanRow> = (0..6).map(|i| PlanRow { height: 30.0, can_break_above: i > 0, cells: Vec::new() }).collect();
        let table = PlanBlock { kind: PlanKind::Table, rows, ..text(2, &[]) };
        let plan = plan_pages(&input(100.0, vec![text(1, &[20.0]), table])).unwrap();
        assert!(plan.placements.iter().all(|p| !p.flowed));
        assert!(plan.cell_lines.is_empty());
    }

    #[test]
    fn the_wire_form_round_trips_through_json() {
        let json = r#"{"planVersion":1,"contentHeight":100,"splitTables":true,"noteBands":[],
            "blocks":[{"key":7,"kind":"text","lines":[40,40,40]},
                      {"key":8,"kind":"table","rows":[{"height":30},{"height":30,"canBreakAbove":true}]}]}"#;
        let parsed: PlanInput = serde_json::from_str(json).unwrap();
        let plan = plan_pages(&parsed).unwrap();
        let out = serde_json::to_value(&plan).unwrap();
        assert_eq!(out["pageCount"], 2);
        assert_eq!(out["lines"][2], serde_json::json!([0, 2, 1, 0.0]));
        assert_eq!(out["pages"][0]["firstKey"], 7);
    }
}
