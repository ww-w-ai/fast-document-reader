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
//! S5 adds what a sheet carries and how it is shared out:
//! - the footnote band fixpoint runs INSIDE the call (`plan_footnotes.rs`): the host reports each
//!   note's height and the notes each block cites, the plan re-plans against the bands it proposes
//!   until the stopping rule (`FootnoteBandSettle`) says stop, and answers the bands and which page
//!   cites which note. A host that runs its own loop can still hand the plan its final bands as
//!   `noteBands` instead;
//! - a run of blocks under a multi-column declaration is laid out as one stack and dealt into
//!   columns (`plan_columns.rs`, invariants 100, 143-145, 150);
//! - for every page: the section, the running head and foot and the master page that apply, and the
//!   number it prints (`plan_furniture.rs`; invariants 62, 77, 78, 189).

use super::page_pagination::{LaidOutRow, PagePagination};
use super::column_geometry::Column;
use super::plan_columns::{place_run, ColumnedLine, PlanColumnRun, RunGrid};
use super::table_rows::{row_heights, RowNeed};
use super::plan_footnotes::{self as notes, Bands, NotesByPage, PlanCite, PlanNote, PlanSeparator};
use super::plan_furniture::{applicable_entry, displayed_numbers, master_pages, PlanEntry};
use super::footnote_band_settle::{FootnoteBandSettle, Outcome};
pub use super::table_flow::{CellLinePlacement, RowSegment};
use super::table_flow::{flow_table, has_cells, orphan_runs, FlowGeometry, LinePath, PageGrid, PlacedLines, MAX_ROUNDS};

/// Layouts the plan replays before taking the last as it stands: the reader's settle budget per
/// loop (`table_flow::MAX_ROUNDS`, `maxPagedTableSettles`) times the outer alternation of tables and
/// notes that `settlePagedTablesFully` runs.
const SETTLE_PASSES: usize = MAX_ROUNDS * MAX_ROUNDS;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

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
    /// What the cell's box encloses when that is less than the lines' extent: the paragraph spacing
    /// after the last line is part of its fragment but not of the box (TextKit's `usedRect`).
    /// Absent, the box encloses `content_height`.
    #[serde(default)]
    pub box_content: Option<f64>,
    /// Where the document puts the content inside the cell's box (the box is as tall as the rows the
    /// cell covers). The plan applies it itself, so a host sends its lines at their natural offsets.
    #[serde(default)]
    pub vertical_align: PlanAlign,
    #[serde(default)]
    pub lines: Vec<PlanLine>,
}

/// A cell's vertical alignment.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum PlanAlign {
    #[default]
    Top,
    Middle,
    Bottom,
}

impl PlanAlign {
    /// How far below the top of its padding the content starts in a box with `room` to spare.
    fn offset(self, room: f64) -> f64 {
        match self {
            Self::Top => 0.0,
            Self::Middle => room / 2.0,
            Self::Bottom => room,
        }
        .max(0.0)
    }
}

fn one() -> u32 {
    1
}

/// What a block IS, as far as placement goes.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum PlanKind {
    /// Placed line by line: `lines` carries each line box's height.
    #[default]
    Text,
    /// Placed as one unit of `height` (a picture, a rule): spacing included by the host.
    Atomic,
    /// Placed from `rows`.
    Table,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanBlock {
    /// The host's identity for this block (RenderTree node id on Avalonia). Echoed back, never read.
    pub key: i64,
    pub kind: PlanKind,
    #[serde(default)]
    pub section_start: bool,
    /// A section begins here without opening a sheet (the host's layout continued on the page it
    /// began on). The section names the pages from the next one on — a page belongs to the section
    /// in force at its first line — and no page opens.
    #[serde(default)]
    pub section_marker: bool,
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
    /// Table: per row, how far its lines reach below the row's top, spacing after the last line
    /// included. The host's lines hang that spacing below the row's box, and a carried piece is
    /// asked to fit by where its lines end, not where its box does. Empty = every row ends at its
    /// height; otherwise one entry per row.
    #[serde(default)]
    pub row_reach: Vec<f64>,
    /// Table: `rows[].height` is what the host's own layout made of each row (TextKit's), so the
    /// engine keeps it; without this a table described cell by cell has its rows solved from the
    /// cells (`table_rows.rs`).
    #[serde(default)]
    pub rows_observed: bool,
    /// The page this block's first line lands on restarts the page counter at this number (HWP's
    /// 새 번호); the first restart on a page wins.
    #[serde(default)]
    pub page_number_restart: Option<i64>,
    /// The page this block's first line lands on prints no page number (HWP's 쪽 번호 감추기).
    #[serde(default)]
    pub hides_page_number: bool,
    /// The notes this block cites, in citation order.
    #[serde(default)]
    pub cites: Vec<PlanCite>,
    /// The multi-column declaration (`PlanInput.column_runs`) this block sits under. Consecutive
    /// blocks naming the same one are laid out as one run.
    #[serde(default)]
    pub column_run: Option<u32>,
}

#[derive(Debug, Clone, Default, Deserialize)]
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
    /// What stands above page 0's first line (its running head, or the top margin). Only a columned
    /// run reads it: its absolute positions are measured from here.
    #[serde(default)]
    pub leading_band: f64,
    /// The width of the page body the columns are dealt across.
    #[serde(default)]
    pub body_width: f64,
    #[serde(default)]
    pub column_runs: Vec<PlanColumnRun>,
    /// The running heads, feet and master pages the host holds, in its own order; the answer names
    /// positions in these lists.
    #[serde(default)]
    pub headers: Vec<PlanEntry>,
    #[serde(default)]
    pub footers: Vec<PlanEntry>,
    #[serde(default)]
    pub masters: Vec<PlanEntry>,
    #[serde(default)]
    pub sections_hiding_header: Vec<i64>,
    #[serde(default)]
    pub sections_hiding_footer: Vec<i64>,
    #[serde(default)]
    pub sections_hiding_master: Vec<i64>,
    /// The notes of the document and what each section declared about the rule above them. With
    /// notes the plan runs the band fixpoint itself and `note_bands` is ignored.
    #[serde(default)]
    pub notes: Vec<PlanNote>,
    #[serde(default)]
    pub separators: Vec<PlanSeparator>,
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
    /// The column a block under a multi-column run was dealt into.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub column: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanPage {
    /// The section (0-based, in section-start order) this page belongs to.
    pub section: u32,
    /// The key of the first block placed on this page; `None` for a page nothing landed on.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_key: Option<i64>,
    /// The number the page prints: its own ordinal, or counted from the last restart (HWP 새 번호).
    pub number: i64,
    /// The document vetoes the page number on this page (HWP 쪽 번호 감추기).
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub number_hidden: bool,
    /// The position, in the host's `headers`/`footers`/`masters`, of the entry this page shows.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub header: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub footer: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub master: Option<u32>,
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
    /// The footnote bands the plan settled on, as `[page, height]`; the input's own when the host
    /// ran the loop itself.
    pub note_bands: Vec<(u32, f64)>,
    /// Which page cites which notes, as `[page, [number...]]`, in citation order.
    pub notes_by_page: Vec<(u32, Vec<i64>)>,
    /// Layouts the footnote fixpoint ran (1 when there are no notes).
    pub footnote_rounds: u32,
    /// The column of every text line of a columned run: `[block, line, column]`.
    pub column_lines: Vec<[u32; 3]>,
    /// The column of every cell line of a table in a columned run: `[block, row, cell, line, column]`.
    pub column_cell_lines: Vec<[u32; 5]>,
    /// Where each row of a table in a columned run stands in each column it reaches:
    /// `[block, row, page, column, top, bottom]`, page-local points — the box its cells are drawn in,
    /// from the cell lines dealt there and the room each cell keeps above its first line and below
    /// its last. A row only merged cells begin in has none.
    pub column_row_segments: Vec<ColumnRowSegment>,
    /// The lines of tables nested in cells of a columned run's tables, each with its column.
    pub nested_lines: Vec<NestedLine>,
    /// The columns of each declared run, as `x` from the body's left edge and `width`: the geometry
    /// `columnLines` and the other column answers index into. One list per `columnRuns` entry of the
    /// input (a declaration that does not split the text yields one column, the whole body).
    pub column_runs: Vec<Vec<Column>>,
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
    // A table the host described cell by cell, without having laid its rows out itself, is as tall as
    // TextKit makes it whatever heights the host summed (`table_rows.rs`): the rows are solved here,
    // from the cells.
    let solves_rows = |b: &PlanBlock| b.kind == PlanKind::Table && has_cells(&b.rows) && !b.rows_observed;
    let solved;
    let input = if input.blocks.iter().any(solves_rows) {
        let mut copy = input.clone();
        for block in copy.blocks.iter_mut().filter(|b| solves_rows(b)) {
            settle_rows(&mut block.rows);
        }
        solved = copy;
        &solved
    } else {
        input
    };
    let honoured = honoured_breaks(&input.blocks);
    let dropped = input
        .blocks
        .iter()
        .enumerate()
        .filter(|(i, b)| b.page_break_before && !honoured[*i])
        .count() as u32;

    // The footnote band fixpoint (invariant 98). With notes, the first layout reserves nothing and
    // each round re-plans against the bands the last one proposed; a host that ran the loop itself
    // hands its final bands in `note_bands` and the plan takes them as they are.
    let has_notes = !input.notes.is_empty();
    let mut bands: HashMap<u32, f64> = if has_notes {
        HashMap::new()
    } else {
        input.note_bands.iter().map(|n| (n.page, n.height)).collect()
    };
    let (mut core, mut pulled) = plan_core(input, &honoured, &bands);
    let mut footnote_rounds = 1u32;
    let mut assignment = NotesByPage::new();
    if has_notes {
        let heights: HashMap<i64, f64> = input.notes.iter().map(|n| (n.number, n.height)).collect();
        let section_known = input.blocks.iter().any(|b| !b.skip && (b.section_start || b.section_marker));
        let mut history: Vec<Bands> = Vec::new();
        assignment = assign_notes(input, &core);
        for _ in 0..FootnoteBandSettle::MAX_ROUNDS {
            let sections = page_sections(&core);
            let section_of = |page: u32| section_known.then(|| i64::from(sections.get(page as usize).copied().unwrap_or(0)));
            let proposal = notes::propose(&assignment, &heights, &input.separators, &section_of, input.content_height);
            match FootnoteBandSettle::step(&proposal, &history, FootnoteBandSettle::MAX_ROUNDS) {
                Outcome::Retry(next) => {
                    history.push(next.clone());
                    bands = next.iter().map(|(p, h)| (*p as u32, *h)).collect();
                    (core, pulled) = plan_core(input, &honoured, &bands);
                    footnote_rounds += 1;
                    assignment = assign_notes(input, &core);
                }
                Outcome::Stop(stopped, _) => {
                    let current: Bands = bands.iter().map(|(p, h)| (i64::from(*p), *h)).collect();
                    if !notes::same_bands(&current, &stopped) {
                        // The bands are final and this layout has never seen them: lay out against
                        // them, and take the assignment from the layout that exists, but only when
                        // the final bands already cover it (`refreshFootnoteAssignment`).
                        bands = stopped.iter().map(|(p, h)| (*p as u32, *h)).collect();
                        (core, pulled) = plan_core(input, &honoured, &bands);
                        footnote_rounds += 1;
                        let refreshed = assign_notes(input, &core);
                        let sections = page_sections(&core);
                        let section_of = |page: u32| section_known.then(|| i64::from(sections.get(page as usize).copied().unwrap_or(0)));
                        let need = notes::propose(&refreshed, &heights, &input.separators, &section_of, input.content_height);
                        if notes::covers(&stopped, &need) {
                            assignment = refreshed;
                        }
                    }
                    break;
                }
            }
        }
    }

    let page_count = core.reached.max(core.page) + 1;
    let sections = page_sections(&core);
    let section_known = input.blocks.iter().any(|b| !b.skip && (b.section_start || b.section_marker));
    let first_page = first_pages(&core);
    let mut restarts: BTreeMap<u32, i64> = BTreeMap::new();
    let mut hidden: BTreeSet<u32> = BTreeSet::new();
    for (index, block) in input.blocks.iter().enumerate() {
        if block.skip {
            continue;
        }
        let Some(&page) = first_page.get(&(index as u32)) else { continue };
        if let Some(first) = block.page_number_restart {
            // The first restart on a page wins: two markers on one sheet must not depend on order.
            restarts.entry(page).or_insert(first);
        }
        if block.hides_page_number {
            hidden.insert(page);
        }
    }
    let numbers = displayed_numbers(page_count, &restarts);
    let hiding_header: HashSet<i64> = input.sections_hiding_header.iter().copied().collect();
    let hiding_footer: HashSet<i64> = input.sections_hiding_footer.iter().copied().collect();
    let hiding_master: HashSet<i64> = input.sections_hiding_master.iter().copied().collect();
    let section_of_index = |page: u32| section_known.then(|| i64::from(sections.get(page as usize).copied().unwrap_or(0)));
    let master_queries: Vec<(u32, Option<i64>)> = (0..page_count).map(|p| (p, section_of_index(p))).collect();
    let masters = master_pages(&input.masters, &hiding_master, &master_queries);
    let pages: Vec<PlanPage> = (0..page_count)
        .map(|page| {
            let section = section_of_index(page);
            let pick = |entries: &[PlanEntry], hiding: &HashSet<i64>| {
                applicable_entry(entries, i64::from(page), section, hiding).map(|i| i as u32)
            };
            PlanPage {
                section: sections.get(page as usize).copied().unwrap_or(0),
                first_key: core.first_key.get(page as usize).copied().flatten(),
                number: numbers[page as usize],
                number_hidden: hidden.contains(&page),
                header: pick(&input.headers, &hiding_header),
                footer: pick(&input.footers, &hiding_footer),
                master: masters[page as usize].map(|i| i as u32),
            }
        })
        .collect();

    let mut note_bands: Vec<(u32, f64)> = bands.iter().filter(|(_, h)| **h > 0.0).map(|(p, h)| (*p, *h)).collect();
    note_bands.sort_by_key(|(page, _)| *page);
    Ok(PagePlan {
        plan_version: PAGE_PLAN_VERSION,
        page_count,
        pages,
        placements: core.placements,
        lines: core.lines,
        row_segments: core.row_segments,
        cell_lines: core.cell_lines,
        pulled_lines: pulled
            .iter()
            .map(|(block, path)| std::iter::once(*block).chain(path.iter().copied()).collect())
            .collect(),
        split_table_count: core.split_table_count,
        carried_table_count: core.carried_table_count,
        dropped_break_count: dropped,
        note_bands,
        notes_by_page: assignment.into_iter().collect(),
        footnote_rounds,
        column_lines: core.column_lines,
        column_cell_lines: core.column_cell_lines,
        column_row_segments: core.column_row_segments,
        nested_lines: core.nested_lines,
        column_runs: input.column_runs.iter().map(|run| run.columns(input.body_width)).collect(),
    })
}

/// One complete layout against a given set of note bands: the reader's passes replayed (see below),
/// then the final one. Returns that final layout and the pulls it kept.
fn plan_core(input: &PlanInput, honoured: &[bool], bands: &HashMap<u32, f64>) -> (State, BTreeSet<(u32, LinePath)>) {
    // A table that fits no page flows line by line, and the reader reaches that layout over several
    // passes: its first layout has no record that any table is over-tall, so every table lies where
    // it falls; each later one applies what the last measured, and the 1-3 line pulls it records
    // are never taken back. The plan replays those passes when the host reported cell lines.
    //
    // The reader also settles a round BEHIND its layout for the tables it carries: a table is moved
    // only once a layout has measured it overrunning, and what a later layout pulls from an over-tall
    // table depends on where the tables above it stood in that round. Each pass therefore moves only
    // the tables the passes before it recorded.
    let mut pulled: BTreeSet<(u32, LinePath)> = BTreeSet::new();
    let mut known: BTreeSet<u32> = BTreeSet::new();
    let grid = PageGrid { pitch: input.content_height + input.band, leading: input.leading_band };
    for round in 1..=SETTLE_PASSES {
        let mode = if round == 1 { Mode::Natural } else { Mode::Settled };
        let pass = run_pass(input, honoured, mode, &pulled, &known, bands);
        let mut added = false;
        for table in &pass.flowed {
            for path in orphan_runs(&grid, &input.blocks[table.block as usize].rows, &table.lines) {
                added |= pulled.insert((table.block, path));
            }
        }
        for table in &pass.new_pushes {
            added |= known.insert(*table);
        }
        if !added && round > 1 {
            break;
        }
    }
    let state = run_pass(input, honoured, Mode::Settled, &pulled, &known, bands);
    (state, pulled)
}

/// The section of every page: `section_boundaries` names the pages a section start opened.
fn page_sections(state: &State) -> Vec<u32> {
    let page_count = state.reached.max(state.page) + 1;
    let mut section = 0u32;
    let mut cursor = 0usize;
    (0..page_count)
        .map(|page| {
            while cursor < state.section_boundaries.len() && state.section_boundaries[cursor] == page {
                section += 1;
                cursor += 1;
            }
            section
        })
        .collect()
}

/// The page each block's first line (or its first piece) landed on, by block index.
fn first_pages(state: &State) -> HashMap<u32, u32> {
    let mut out: HashMap<u32, u32> = HashMap::new();
    for line in &state.lines {
        out.entry(line.0).or_insert(line.2);
    }
    for placement in &state.placements {
        out.entry(placement.block).or_insert(placement.page);
    }
    for line in &state.cell_lines {
        out.entry(line.0).or_insert(line.4);
    }
    out
}

/// Page → the notes it cites. A note is drawn once, on the first page that cites it; a marker in a
/// text block is found by the line holding it, one in a table or a picture by the page the block
/// starts on (`FootnoteLayout.Assign`, `DocumentWindowController.footnotePages`).
fn assign_notes(input: &PlanInput, state: &State) -> NotesByPage {
    let known: HashSet<i64> = input.notes.iter().map(|n| n.number).collect();
    let mut line_pages: HashMap<u32, Vec<u32>> = HashMap::new();
    for line in &state.lines {
        line_pages.entry(line.0).or_default().push(line.2);
    }
    let first = first_pages(state);
    let mut citations: Vec<(u32, usize, usize, i64)> = Vec::new();
    for (index, block) in input.blocks.iter().enumerate() {
        if block.skip {
            continue;
        }
        for (order, cite) in block.cites.iter().enumerate() {
            if !known.contains(&cite.note) {
                continue;
            }
            let page = match block.kind {
                PlanKind::Text => line_pages.get(&(index as u32)).and_then(|pages| {
                    let at = cite.line.map_or(0, |l| l as usize).min(pages.len().saturating_sub(1));
                    pages.get(at).copied()
                }),
                _ => cite
                    .cell
                    .and_then(|[row, cell, line]| {
                        state
                            .cell_lines
                            .iter()
                            .find(|l| l.0 == index as u32 && l.1 == row && l.2 == cell && l.3 == line)
                            .map(|l| l.4)
                    })
                    .or_else(|| first.get(&(index as u32)).copied()),
            };
            if let Some(page) = page {
                citations.push((page, index, order, cite.note));
            }
        }
    }
    citations.sort();
    let mut placed: HashSet<i64> = HashSet::new();
    let mut out = NotesByPage::new();
    for (page, _, _, note) in citations {
        if placed.insert(note) {
            out.entry(page).or_default().push(note);
        }
    }
    out
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

fn run_pass(
    input: &PlanInput,
    honoured: &[bool],
    mode: Mode,
    pulled: &BTreeSet<(u32, LinePath)>,
    known: &BTreeSet<u32>,
    bands: &HashMap<u32, f64>,
) -> State {
    let mut state = State {
        content_height: input.content_height,
        band: input.band.max(0.0),
        note_bands: bands.clone(),
        mode,
        pulled: pulled.clone(),
        known_pushes: known.clone(),
        new_pushes: BTreeSet::new(),
        flowed: Vec::new(),
        page: 0,
        reached: 0,
        cursor: 0.0,
        placements: Vec::new(),
        lines: Vec::new(),
        row_segments: Vec::new(),
        cell_lines: Vec::new(),
        column_lines: Vec::new(),
        column_cell_lines: Vec::new(),
        column_row_segments: Vec::new(),
        nested_lines: Vec::new(),
        first_key: vec![None],
        section_boundaries: Vec::new(),
        split_table_count: 0,
        carried_table_count: 0,
    };
    let mut index = 0usize;
    while index < input.blocks.len() {
        let block = &input.blocks[index];
        if block.skip {
            index += 1;
            continue;
        }
        if let Some(run_id) = block.column_run {
            // The blocks of one columned run are laid out together.
            let mut end = index + 1;
            while end < input.blocks.len()
                && (input.blocks[end].skip || input.blocks[end].column_run == Some(run_id))
            {
                end += 1;
            }
            if let Some(run) = input.column_runs.get(run_id as usize) {
                if state.place_column_run(input, honoured, index, end, run) {
                    index = end;
                    continue;
                }
            }
        }
        state.open_block(block, honoured[index]);
        let idx = index as u32;
        match block.kind {
            PlanKind::Text => state.place_text(idx, block),
            PlanKind::Atomic => state.place_atomic(idx, block),
            PlanKind::Table => state.place_table(idx, block, input.split_tables),
        }
        index += 1;
    }
    state
}

/// Rows from cells: every nested table first (it is an item of a cell, and the items under it move
/// with its height), then this table's rows by TextKit's rule (`table_rows.rs`).
fn settle_rows(rows: &mut [PlanRow]) {
    for row in rows.iter_mut() {
        for cell in row.cells.iter_mut() {
            let mut shift = 0.0;
            for line in cell.lines.iter_mut() {
                line.top += shift;
                if !line.rows.is_empty() {
                    settle_rows(&mut line.rows);
                    let height: f64 = line.rows.iter().map(|r| r.height).sum();
                    shift += height - line.height;
                    line.height = height;
                }
            }
            cell.content_height += shift;
            if let Some(boxed) = cell.box_content.as_mut() {
                *boxed += shift;
            }
        }
    }
    if !has_cells(rows) {
        return;
    }
    let needs: Vec<RowNeed> = rows
        .iter()
        .enumerate()
        .flat_map(|(r, row)| {
            row.cells.iter().map(move |c| RowNeed { row: r, span: c.row_span.max(1) as usize, need: c.pad_top + c.box_content.unwrap_or(c.content_height) + c.pad_bottom })
        })
        .collect();
    let given: Vec<f64> = rows.iter().map(|r| r.height).collect();
    for (row, height) in rows.iter_mut().zip(row_heights(given.len(), &needs, &given)) {
        row.height = height;
    }
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

struct State {
    content_height: f64,
    band: f64,
    note_bands: HashMap<u32, f64>,
    mode: Mode,
    pulled: BTreeSet<(u32, LinePath)>,
    /// The tables the reader has recorded as overrunning in an EARLIER layout (`tablesToPush`'s
    /// record): only those are moved by this layout. A table that first overruns in this one lies
    /// where it falls until the next layout has measured it — the reader settles a round behind its
    /// own layout, and what each round pulls depends on where the tables above stood in it.
    known_pushes: BTreeSet<u32>,
    /// The tables this layout found overrunning where they lie, for the next one.
    new_pushes: BTreeSet<u32>,
    flowed: Vec<FlowedTable>,
    page: u32,
    /// The furthest page anything reached. A columned run ends on the page its last line was dealt
    /// to, which is not always the furthest.
    reached: u32,
    cursor: f64,
    placements: Vec<BlockPlacement>,
    lines: Vec<LinePlacement>,
    row_segments: Vec<RowSegment>,
    cell_lines: Vec<CellLinePlacement>,
    column_lines: Vec<[u32; 3]>,
    column_cell_lines: Vec<[u32; 5]>,
    column_row_segments: Vec<ColumnRowSegment>,
    nested_lines: Vec<NestedLine>,
    first_key: Vec<Option<i64>>,
    section_boundaries: Vec<u32>,
    split_table_count: u32,
    carried_table_count: u32,
}

/// One thing a columned run's stack holds, by where the layout recorded it.
#[derive(Clone, Copy)]
enum StackSlot {
    Line(usize),
    Placement(usize),
    CellLine(usize),
    Nested(usize),
}

/// A line inside a table nested in a cell of a table in a columned run: it is dealt like any other
/// line, and its place is reported by its path (row, cell, line, then the same again per level).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NestedLine {
    pub block: u32,
    pub path: Vec<u32>,
    pub page: u32,
    pub top: f64,
    pub column: u32,
}

struct StackItem {
    slot: StackSlot,
    block: u32,
    height: f64,
    /// What the cell holding this line keeps around it (a line of a table's cell only).
    leaf: Option<LeafBox>,
}

/// One row's extent in one column: `[block, row, page, column, top, bottom]`, page-local points.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct ColumnRowSegment(pub u32, pub u32, pub u32, pub u32, pub f64, pub f64);

/// The room a cell keeps above its first line and below its last, and which cell it is.
#[derive(Debug, Clone, Copy)]
struct LeafBox {
    row: u32,
    cell: u32,
    /// The cell covers one row: a merged cell's box is the union of the rows it covers, which draw
    /// their own boxes.
    single_row: bool,
    above: f64,
    below: f64,
}

/// What the cell a leaf line belongs to keeps around it. `flowed` tables are top-aligned and run on
/// past their rows, so the room below comes from the cell's own tail rather than from its rows.
fn leaf_box(rows: &[PlanRow], path: &[u32], flowed: bool) -> Option<LeafBox> {
    let (r, c, l) = (*path.first()? as usize, *path.get(1)? as usize, *path.get(2)? as usize);
    let cell = rows.get(r)?.cells.get(c)?;
    let line = cell.lines.get(l)?;
    let span = (cell.row_span.max(1) as usize).min(rows.len() - r);
    let box_height: f64 = rows[r..r + span].iter().map(|row| row.height).sum();
    let (above, below) = if path.len() > 3 {
        // A line of a table nested in the cell: the cell's own padding bounds the whole nest.
        (cell.pad_top, cell.pad_bottom)
    } else if flowed {
        (cell.pad_top + line.top, cell.pad_bottom + (cell.content_height - line.top - line.height).max(0.0))
    } else {
        let room = box_height - cell.pad_top - cell.content_height - cell.pad_bottom;
        let above = cell.pad_top + cell.vertical_align.offset(room) + line.top;
        (above, (box_height - above - line.height).max(0.0))
    };
    Some(LeafBox { row: path[0], cell: path[1], single_row: cell.row_span <= 1, above, below })
}

impl State {
    fn body(&self, page: u32) -> f64 {
        self.content_height - self.note_bands.get(&page).copied().unwrap_or(0.0)
    }

    fn next_page(&mut self) {
        self.page += 1;
        self.reached = self.reached.max(self.page);
        self.cursor = 0.0;
        if self.first_key.len() <= self.page as usize {
            self.first_key.resize(self.page as usize + 1, None);
        }
    }

    /// A section start or an honoured hard break opens a page — unless the page is still empty.
    fn open_block(&mut self, block: &PlanBlock, honoured_break: bool) {
        if block.section_start || (block.page_break_before && honoured_break) {
            // A break at the top of an empty page is a no-op: the page it would open is this one.
            if self.cursor > 0.0 {
                self.next_page();
            }
            if block.section_start && self.page > 0 {
                self.section_boundaries.push(self.page);
            }
        }
        if block.section_marker && !block.section_start {
            // In force from the next sheet on, unless the marker is the first thing on this one.
            let from = if self.cursor > 0.0 { self.page + 1 } else { self.page };
            if from > 0 {
                self.section_boundaries.push(from);
            }
        }
    }

    /// Lays the blocks `from..to` — one run under a multi-column declaration — out as ONE stack at
    /// the column's width, as the reader's first measurement does, then deals the stack into columns
    /// (invariants 100, 143-145, 150). Returns `false` when the declaration does not split the text,
    /// in which case nothing was placed and the blocks are laid out as ordinary ones.
    fn place_column_run(&mut self, input: &PlanInput, honoured: &[bool], from: usize, to: usize, run: &PlanColumnRun) -> bool {
        let columns = run.columns(input.body_width);
        if columns.len() < 2 {
            return false;
        }
        let page_before = self.page as usize;
        let reached_before = self.reached;
        let mut stack: Vec<StackItem> = Vec::new();
        let mut opened: Vec<(usize, u32, u32)> = Vec::new();
        let mut spacing_after = 0.0;
        for index in from..to {
            let block = &input.blocks[index];
            if block.skip {
                continue;
            }
            let idx = index as u32;
            let boundaries_before = self.section_boundaries.len();
            self.open_block(block, honoured[index]);
            // A section opened inside the run is named by the page of the STACK it fell on; the
            // columns deal the stack onto other pages, so the boundary follows its block's first line
            // (a boundary that waits for the next sheet keeps its one page of delay).
            for slot in boundaries_before..self.section_boundaries.len() {
                opened.push((slot, idx, self.section_boundaries[slot].saturating_sub(self.page)));
            }
            match block.kind {
                PlanKind::Text => {
                    let start = self.lines.len();
                    self.place_text(idx, block);
                    for (at, line) in self.lines[start..].iter().enumerate() {
                        let height = block.lines.get(line.1 as usize).copied().unwrap_or(0.0);
                        stack.push(StackItem { slot: StackSlot::Line(start + at), block: idx, height, leaf: None });
                    }
                    spacing_after = block.spacing_after;
                }
                PlanKind::Atomic => {
                    self.place_atomic(idx, block);
                    stack.push(StackItem { slot: StackSlot::Placement(self.placements.len() - 1), block: idx, height: block.height, leaf: None });
                    spacing_after = 0.0;
                }
                PlanKind::Table => {
                    self.place_table_in_stack(input.split_tables, idx, block, &mut stack);
                    spacing_after = block.spacing_after;
                }
            }
        }
        // Absolute positions on the plan's page grid, in document order.
        let grid = RunGrid {
            content_height: self.content_height,
            band: self.band,
            leading: input.leading_band,
            note_bands: &self.note_bands,
        };
        let stacked: Vec<(i64, f64, f64)> = stack
            .iter()
            .enumerate()
            .map(|(id, item)| {
                let (page, top) = self.position_of(item.slot);
                (id as i64, grid.absolute(page, top), item.height)
            })
            .collect();
        let Some(dealt) = place_run(&stacked, &columns, &grid) else { return true };
        // The stack's own page breaks were a measurement; the pages the run really reaches are the
        // ones its columns were dealt to.
        self.reached = reached_before;
        self.first_key.truncate(page_before + 1);
        let mut last: Option<(u32, f64, f64)> = None;
        for (id, item) in stack.iter().enumerate() {
            let Some(&ColumnedLine { column, page, top }) = dealt.get(&(id as i64)) else {
                let (page, top) = self.position_of(item.slot);
                last = Some((page, top, item.height));
                continue;
            };
            self.dealt_to(item, column, page, top);
            last = Some((page, top, item.height));
            if self.first_key.len() <= page as usize {
                self.first_key.resize(page as usize + 1, None);
            }
            if self.first_key[page as usize].is_none() {
                self.first_key[page as usize] = Some(input.blocks[item.block as usize].key);
            }
            self.reached = self.reached.max(page);
        }
        self.column_row_segments_of(&stack, &dealt);
        // A page belongs to the section its top-left line is in (the reader asks which character
        // stands at the page's top edge, in the first column): a section whose opener the columns
        // dealt to a later column, or lower down a sheet, begins on the first sheet whose top-left
        // line is the opener or comes after it. The 편람's colophon opens mid-sheet in column two.
        let mut top_left: BTreeMap<u32, (f64, u32)> = BTreeMap::new();
        for (id, item) in stack.iter().enumerate() {
            if let Some(at) = dealt.get(&(id as i64)).filter(|at| at.column == 0) {
                let entry = top_left.entry(at.page).or_insert((at.top, item.block));
                if at.top < entry.0 - 1e-9 {
                    *entry = (at.top, item.block);
                }
            }
        }
        for (slot, block, offset) in opened {
            let first = stack.iter().find(|item| item.block == block).map(|item| self.position_of(item.slot).0);
            if let Some((&page, _)) = top_left.iter().find(|(_, (_, top_block))| *top_block >= block) {
                self.section_boundaries[slot] = page;
            } else if let Some(page) = first {
                self.section_boundaries[slot] = page + offset;
            }
        }
        if let Some((page, top, height)) = last {
            self.page = page;
            self.cursor = top + height + spacing_after;
        }
        true
    }

    /// The boxes the rows of a columned run's tables are drawn in, one per row per column the row
    /// reaches: its cells' lines as dealt there, each cell keeping the room it had above its first
    /// line and below its last (a cell the columns cut keeps none at the cut).
    fn column_row_segments_of(&mut self, stack: &[StackItem], dealt: &HashMap<i64, ColumnedLine>) {
        let mut first: HashMap<(u32, u32, u32), usize> = HashMap::new();
        let mut last: HashMap<(u32, u32, u32), usize> = HashMap::new();
        for (id, item) in stack.iter().enumerate() {
            if let Some(leaf) = item.leaf {
                let key = (item.block, leaf.row, leaf.cell);
                first.entry(key).or_insert(id);
                last.insert(key, id);
            }
        }
        let mut boxes: BTreeMap<(u32, u32, u32, u32), (f64, f64)> = BTreeMap::new();
        for (id, item) in stack.iter().enumerate() {
            let (Some(leaf), Some(at)) = (item.leaf, dealt.get(&(id as i64))) else { continue };
            if !leaf.single_row {
                continue;
            }
            let key = (item.block, leaf.row, leaf.cell);
            let above = if first.get(&key) == Some(&id) { leaf.above } else { 0.0 };
            let below = if last.get(&key) == Some(&id) { leaf.below } else { 0.0 };
            let top = (at.top - above).max(0.0);
            let bottom = at.top + item.height + below;
            let entry = boxes.entry((item.block, leaf.row, at.page, at.column)).or_insert((top, bottom));
            entry.0 = entry.0.min(top);
            entry.1 = entry.1.max(bottom);
        }
        for ((block, row, page, column), (top, bottom)) in boxes {
            self.column_row_segments.push(ColumnRowSegment(block, row, page, column, top, bottom));
        }
    }

    fn position_of(&self, slot: StackSlot) -> (u32, f64) {
        match slot {
            StackSlot::Line(i) => (self.lines[i].2, self.lines[i].3),
            StackSlot::Placement(i) => (self.placements[i].page, self.placements[i].top),
            StackSlot::CellLine(i) => (self.cell_lines[i].4, self.cell_lines[i].5),
            StackSlot::Nested(i) => (self.nested_lines[i].page, self.nested_lines[i].top),
        }
    }

    /// Moves a stack item to where its column put it, and says which column that is.
    fn dealt_to(&mut self, item: &StackItem, column: u32, page: u32, top: f64) {
        match item.slot {
            StackSlot::Line(i) => {
                let line = self.lines[i];
                self.lines[i] = LinePlacement(line.0, line.1, page, top);
                self.column_lines.push([line.0, line.1, column]);
            }
            StackSlot::Placement(i) => {
                self.placements[i].page = page;
                self.placements[i].top = top;
                self.placements[i].column = Some(column);
            }
            StackSlot::CellLine(i) => {
                let line = self.cell_lines[i];
                self.cell_lines[i] = CellLinePlacement(line.0, line.1, line.2, line.3, page, top);
                self.column_cell_lines.push([line.0, line.1, line.2, line.3, column]);
            }
            StackSlot::Nested(i) => {
                let line = &mut self.nested_lines[i];
                line.page = page;
                line.top = top;
                line.column = column;
            }
        }
    }

    /// A table inside a columned run falls where the page rule puts it in the reader's stack — carried
    /// whole, cut at its rows, or flowed line by line — and its lines, those of a table nested in a
    /// cell included, are what the columns deal. One with no cell data is dealt piece by piece.
    fn place_table_in_stack(&mut self, split_tables: bool, index: u32, block: &PlanBlock, stack: &mut Vec<StackItem>) {
        // The reader's first layout lays a columned run's stack like any other text: a table whose
        // cells were measured stays where it falls. Only the later layouts settle it.
        let keep_natural = self.mode == Mode::Natural && has_cells(&block.rows);
        let mode = if keep_natural { self.mode } else { std::mem::replace(&mut self.mode, Mode::Settled) };
        let start = (self.page, self.cursor);
        let (placements_from, cells_from, segments_from) =
            (self.placements.len(), self.cell_lines.len(), self.row_segments.len());
        self.place_table(index, block, split_tables);
        self.mode = mode;
        let mut leaves: Vec<(Vec<u32>, u32, f64, f64)> = Vec::new(); // (path, page, top, height)
        let flowed_table = self.placements[placements_from..].iter().any(|p| p.flowed)
            || (keep_natural && self.flowed.last().map_or(false, |f| f.block == index));
        if flowed_table {
            // Flowed: the flow already placed every line, nested ones included. What it said about
            // the table's pieces and rows was only where the stack stood.
            if let Some(flowed) = self.flowed.last().filter(|f| f.block == index) {
                for (path, page, top) in &flowed.lines {
                    leaves.push((path.clone(), *page, *top, leaf_height(&block.rows, path)));
                }
            }
            self.cell_lines.truncate(cells_from);
            self.row_segments.truncate(segments_from);
            self.placements.truncate(placements_from);
        } else {
            let mut pieces: Vec<BlockPlacement> = self.placements[placements_from..].to_vec();
            if keep_natural {
                // Lying where it fell, whole: one piece from where it began.
                let total: f64 = block.rows.iter().map(|r| r.height).sum();
                pieces = vec![BlockPlacement {
                    block: index,
                    key: block.key,
                    page: start.0,
                    top: start.1 + block.spacing_before,
                    height: total,
                    row_start: Some(0),
                    row_count: Some(block.rows.len() as u32),
                    flowed: false,
                    column: None,
                }];
            }
            if !has_cells(&block.rows) {
                for (offset, piece) in pieces.into_iter().enumerate() {
                    stack.push(StackItem { slot: StackSlot::Placement(placements_from + offset), block: index, height: piece.height, leaf: None });
                }
                return;
            }
            // The leaf lines describe the table from here on; the pieces were only where it stood.
            self.placements.truncate(placements_from);
            for piece in pieces {
                let start = piece.row_start.unwrap_or(0) as usize;
                let end = (start + piece.row_count.unwrap_or(block.rows.len() as u32) as usize).min(block.rows.len());
                let rows_height: f64 = block.rows[start..end].iter().map(|r| r.height).sum();
                // A whole table's placement carries its spacing; the rows begin below the spacing before.
                let top = piece.top + if (piece.height - rows_height).abs() > 1e-9 { block.spacing_before } else { 0.0 };
                synth_leaves(&block.rows[start..end], start as u32, top, piece.page, &[], &mut leaves);
            }
        }
        for (path, page, top, height) in leaves {
            let leaf = leaf_box(&block.rows, &path, flowed_table);
            if path.len() == 3 {
                stack.push(StackItem { slot: StackSlot::CellLine(self.cell_lines.len()), block: index, height, leaf });
                self.cell_lines.push(CellLinePlacement(index, path[0], path[1], path[2], page, top));
            } else {
                stack.push(StackItem { slot: StackSlot::Nested(self.nested_lines.len()), block: index, height, leaf });
                self.nested_lines.push(NestedLine { block: index, path, page, top, column: 0 });
            }
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
            // The delegate's own comparison for a line: glyphs past the foot, no tolerance (it is a
            // plain `>` there; the hair is the table rule's).
            let past_foot = self.cursor > 0.0 && self.cursor + height - hangs > self.body(self.page);
            if keeps || past_foot {
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
            column: None,
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
                column: None,
            });
        }
        self.row_segments.extend(flow.segments);
        self.cell_lines.extend(flow.lines);
        while self.page < flow.after.0 {
            self.next_page();
        }
        self.cursor = flow.after.1 + block.spacing_after;
    }

    /// The reader's first layout of a table: it lies where it falls, whole, and runs on past the page
    /// foot. An over-tall one reports where its lines fell, which is what the first pulls are read
    /// from.
    fn place_table_naturally(&mut self, index: u32, block: &PlanBlock, total: f64, over_tall: bool) {
        if !over_tall {
            self.record_if_overrunning(index, block, total);
        }
        self.cursor += block.spacing_before;
        let geometry = FlowGeometry { content_height: self.content_height, band: self.band, note_bands: &self.note_bands };
        let end = if over_tall {
            let none = BTreeSet::new();
            let (flow, every_line) = flow_table(&geometry, index, block, (self.page, self.cursor), &none, false);
            self.flowed.push(FlowedTable { block: index, lines: every_line });
            flow.after
        } else {
            geometry.normalise(self.page, self.cursor + total)
        };
        while self.page < end.0 {
            self.next_page();
        }
        self.cursor = end.1 + block.spacing_after;
    }

    /// A table the reader has not yet recorded as overrunning: it stays where it falls and its tail
    /// may run past the page foot. What follows it is moved on by the ordinary page rule.
    fn place_table_lying(&mut self, index: u32, block: &PlanBlock, total: f64, whole: f64) {
        self.record_if_overrunning(index, block, total);
        self.mark_first(block.key);
        self.placements.push(BlockPlacement {
            block: index,
            key: block.key,
            page: self.page,
            top: self.cursor,
            height: whole,
            row_start: Some(0),
            row_count: Some(block.rows.len() as u32),
            flowed: false,
            column: None,
        });
        let geometry = FlowGeometry { content_height: self.content_height, band: self.band, note_bands: &self.note_bands };
        let y = self.cursor + block.spacing_before + total;
        // A table that runs past a whole page is on a later one; one that ends exactly on the foot
        // is still on this page, and the next block moves on by its own fit.
        let end = if y > self.content_height + self.band { geometry.normalise(self.page, y) } else { (self.page, y) };
        while self.page < end.0 {
            self.next_page();
        }
        self.cursor = end.1 + block.spacing_after;
    }

    /// `tablesToPush`'s test, taken on the layout just made: the table's bottom, spacing included
    /// (the plan's own measure of a whole table), is past the foot of the page its top is on.
    fn record_if_overrunning(&mut self, index: u32, block: &PlanBlock, total: f64) {
        let whole = block.spacing_before + total + block.spacing_after;
        if self.cursor + whole > self.body(self.page) + FIT_TOLERANCE {
            self.new_pushes.insert(index);
        }
    }

    fn place_table(&mut self, index: u32, block: &PlanBlock, split_tables: bool) {
        let rows = &block.rows;
        let rows_height: f64 = rows.iter().map(|r| r.height).sum();
        let hang = if block.rows_observed { 0.0 } else { last_row_hang(rows) };
        let total = rows_height + hang;
        let whole = block.spacing_before + total + block.spacing_after;
        let over_tall = rows_height > self.body(self.page) && has_cells(rows);
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
        // A table no earlier layout has measured overrunning lies where it falls, whole, and is only
        // recorded for the next one (`tablesToPush`'s `known || overruns`).
        if !self.known_pushes.contains(&index) {
            self.place_table_lying(index, block, total, whole);
            return;
        }
        let fits_here =self.cursor + whole <= self.body(self.page) + FIT_TOLERANCE;

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
                column: None,
            });
            self.cursor += whole;
            return;
        }

        self.split_table_count += 1;
        self.cursor += block.spacing_before;
        for group in &groups {
            let start = group.first_char as usize;
            let count = group.row_count as usize;
            let ends_the_table = start + count == rows.len();
            let tail = if ends_the_table { hang } else { 0.0 };
            let piece: f64 = rows[start..start + count].iter().map(|r| r.height).sum::<f64>() + tail;
            let reach = piece_reach(block, start, count).max(piece);
            // A piece taller than the page body is never pushed: it overruns wherever it starts.
            if self.cursor > 0.0
                && self.cursor + reach > self.body(self.page) + FIT_TOLERANCE
                && reach <= self.body(self.page)
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
                column: None,
            });
            self.cursor += piece;
        }
        self.cursor += block.spacing_after;
    }
}

/// What a table's last row hangs below its box: the spacing after the last paragraph of the cells
/// that end in it. A row solved from its cells ends at the box (`settle_rows`), but the host's next
/// block starts after the lines, so the table is that much taller.
fn last_row_hang(rows: &[PlanRow]) -> f64 {
    // The block after a table starts at the lower of the cells' boxes and the last line the
    // typesetter placed, which is the LAST cell's, wherever its content sits in its box.
    let Some((r, cell)) = rows.iter().enumerate().flat_map(|(r, row)| row.cells.iter().map(move |c| (r, c))).last() else {
        return 0.0;
    };
    let Some(boxed) = cell.box_content else { return 0.0 };
    let end = (r + cell.row_span.max(1) as usize).min(rows.len());
    let box_height: f64 = rows[r..end].iter().map(|row| row.height).sum();
    let room = (box_height - cell.pad_top - boxed - cell.pad_bottom).max(0.0);
    let lines_end = cell.pad_top + cell.vertical_align.offset(room) + cell.content_height;
    (lines_end - (box_height - cell.pad_bottom)).max(0.0)
}

/// How far the lines of rows `start..start + count` reach below the piece's top: the piece's height,
/// or further where a row's last line hangs its spacing after past the row's box (`row_reach`).
fn piece_reach(block: &PlanBlock, start: usize, count: usize) -> f64 {
    let rows = &block.rows;
    let mut offset = 0.0;
    let mut reach = 0.0f64;
    for i in start..start + count {
        let row_reach = block.row_reach.get(i).copied().filter(|_| block.row_reach.len() == rows.len()).unwrap_or(rows[i].height);
        reach = reach.max(offset + row_reach.max(rows[i].height));
        offset += rows[i].height;
    }
    reach
}

/// The height of the line a path names: row, cell, line, then the same again inside a table nested
/// at that line.
fn leaf_height(rows: &[PlanRow], path: &[u32]) -> f64 {
    let mut rows = rows;
    let mut chunks = path.chunks(3).peekable();
    while let Some(step) = chunks.next() {
        let [r, c, l] = step else { return 0.0 };
        let Some(line) = rows.get(*r as usize).and_then(|row| row.cells.get(*c as usize)).and_then(|cell| cell.lines.get(*l as usize)) else {
            return 0.0;
        };
        if chunks.peek().is_none() {
            return line.height;
        }
        rows = &line.rows;
    }
    0.0
}

/// Every leaf line of `rows` — a table nested in a cell contributes its own lines, not itself — as
/// `(path, page, top, height)`, the rows standing from `top` on `page`. `first_row` is the row index
/// of `rows[0]` in the table's own numbering (a piece starts partway down), `prefix` the path of the
/// line holding a nested table.
fn synth_leaves(rows: &[PlanRow], first_row: u32, top: f64, page: u32, prefix: &[u32], out: &mut Vec<(Vec<u32>, u32, f64, f64)>) {
    let mut row_top = top;
    for (offset, row) in rows.iter().enumerate() {
        for (c, cell) in row.cells.iter().enumerate() {
            // The cell's box is as tall as the rows it covers; its content sits in it as aligned.
            let span = (cell.row_span.max(1) as usize).min(rows.len() - offset);
            let box_height: f64 = rows[offset..offset + span].iter().map(|r| r.height).sum();
            let room = box_height - cell.pad_top - cell.content_height - cell.pad_bottom;
            let aligned = cell.vertical_align.offset(room);
            for (l, line) in cell.lines.iter().enumerate() {
                let line_top = row_top + cell.pad_top + aligned + line.top;
                let mut path = prefix.to_vec();
                path.extend([first_row + offset as u32, c as u32, l as u32]);
                if line.rows.is_empty() {
                    out.push((path, page, line_top, line.height));
                } else {
                    synth_leaves(&line.rows, 0, line_top, page, &path, out);
                }
            }
        }
        row_top += row.height;
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
        PlanBlock { key, lines: lines.to_vec(), ..PlanBlock::default() }
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
        PlanInput { plan_version: 1, content_height, split_tables: true, blocks, ..PlanInput::default() }
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
    fn a_line_a_hair_past_the_foot_moves_on() {
        // The delegate compares glyphs with the foot by a plain `>`: no tolerance for a line.
        let plan = plan_pages(&input(100.0, vec![text(1, &[50.0]), text(2, &[50.005])])).unwrap();
        assert_eq!(pages_of_lines(&plan), vec![0, 1]);
    }

    #[test]
    fn a_table_is_moved_only_by_the_layout_after_the_one_that_measured_it_overrunning() {
        let blocks = vec![text(1, &[40.0]), table(2, &[(50.0, false), (30.0, false)], false)];
        let plan_input = input(100.0, blocks);
        let honoured = honoured_breaks(&plan_input.blocks);
        let bands = HashMap::new();
        let none = BTreeSet::new();
        // The first measured layout has recorded nothing, so the table lies where it falls and is
        // recorded for the next one.
        let lying = run_pass(&plan_input, &honoured, Mode::Settled, &BTreeSet::new(), &none, &bands);
        assert_eq!(lying.placements[0].page, 0);
        assert!(lying.new_pushes.contains(&1));
        // Once recorded it is carried.
        let known: BTreeSet<u32> = [1].into_iter().collect();
        let carried = run_pass(&plan_input, &honoured, Mode::Settled, &BTreeSet::new(), &known, &bands);
        assert_eq!(carried.placements[0].page, 1);
        // And the plan reaches that layout by itself.
        assert_eq!(plan_pages(&plan_input).unwrap().placements[0].page, 1);
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
        PlanCell { row_span: 1, pad_top: 0.0, pad_bottom: 0.0, content_height: top, box_content: None, vertical_align: PlanAlign::Top, lines }
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
    fn a_run_only_the_settled_layout_strands_is_still_pulled() {
        // Band 200: the first layout lets all six lines lie on page 0 (nothing to pull). The settled
        // layout starts page 1 at the third line, stranding two lines at the foot — found in round 2.
        let table = flow_table_block(2, vec![(120.0, vec![flow_cell(&[20.0; 6])])]);
        let mut plan_input = input(100.0, vec![text(1, &[60.0]), table]);
        plan_input.band = 200.0;
        let plan = plan_pages(&plan_input).unwrap();
        assert_eq!(plan.pulled_lines, vec![vec![1, 0, 0, 0]]);
    }

    #[test]
    fn a_pull_the_first_layout_made_stays_even_when_the_settled_layout_would_not_make_it() {
        // The first layout leaves the first line at y=95 with one more on the page and the rest on
        // the next: a stranded run, pulled. A settled layout alone moves that line anyway (it does
        // not fit), so nothing would be recorded — the record exists only because the first layout
        // made it, and the reader never takes a pull back.
        let table = flow_table_block(2, vec![(200.0, vec![flow_cell(&[20.0; 10])])]);
        let mut plan_input = input(100.0, vec![text(1, &[95.0]), table]);
        plan_input.band = 20.0;
        let plan = plan_pages(&plan_input).unwrap();
        assert_eq!(plan.pulled_lines, vec![vec![1, 0, 0, 0]]);
        assert_eq!(plan.cell_lines[0].4, 1);
    }

    #[test]
    fn a_pull_belongs_to_the_table_that_made_it() {
        // Table 1 pulls its first line; table 2 has a line on the same path that fits where it
        // stands (a single line: nothing of it is ever stranded) and must stay there.
        let first = flow_table_block(1, vec![(120.0, vec![flow_cell(&[20.0; 6])])]);
        // The cell stands 120 tall (the row is as tall as its cells), its one line 20.
        let second = flow_table_block(2, vec![(120.0, vec![PlanCell { content_height: 120.0, ..flow_cell(&[20.0]) }])]);
        let plan = plan_pages(&input(100.0, vec![text(0, &[60.0]), first, second])).unwrap();
        assert_eq!(plan.pulled_lines, vec![vec![1, 0, 0, 0]]);
        let second_first_line = plan.cell_lines.iter().find(|l| l.0 == 2 && l.3 == 0).unwrap();
        assert_eq!(second_first_line.4, 2, "table 2's first line is on the page the first table ended on");
    }

    #[test]
    fn a_cells_content_sits_in_the_box_of_the_rows_it_covers_as_the_document_aligns_it() {
        // Two rows of 10 and 30; a cell begun in row 0 covers both (box 40) and holds one 6pt line
        // between 1pt paddings (content 6). Room = 40 - 1 - 6 - 1 = 32.
        let cell = |align| PlanCell { row_span: 2, pad_top: 1.0, pad_bottom: 1.0, vertical_align: align, ..flow_cell(&[6.0]) };
        let tops = |align| {
            let rows = vec![
                PlanRow { height: 10.0, can_break_above: true, cells: vec![cell(align)] },
                PlanRow { height: 30.0, can_break_above: false, cells: Vec::new() },
            ];
            let mut out = Vec::new();
            synth_leaves(&rows, 0, 100.0, 0, &[], &mut out);
            out[0].2
        };
        assert_eq!(tops(PlanAlign::Top), 101.0);
        assert_eq!(tops(PlanAlign::Middle), 101.0 + 16.0);
        assert_eq!(tops(PlanAlign::Bottom), 101.0 + 32.0);
    }

    fn entry(applies_to: PlanApplies, section: Option<i64>) -> PlanEntry {
        PlanEntry { applies_to, section }
    }

    use super::super::plan_furniture::PlanApplies;

    #[test]
    fn every_page_names_the_head_foot_and_master_that_apply_and_the_number_it_prints() {
        // Three pages, the second opening section 1; entries: a catch-all head, a first-page head,
        // a foot only section 1 has, a master for each section.
        let mut s1 = text(2, &[60.0]);
        s1.section_start = true;
        let mut plan_input = input(100.0, vec![text(1, &[60.0]), s1, text(3, &[60.0])]);
        plan_input.headers = vec![entry(PlanApplies::DefaultPages, None), entry(PlanApplies::FirstPage, None)];
        plan_input.footers = vec![entry(PlanApplies::DefaultPages, Some(1))];
        plan_input.masters = vec![entry(PlanApplies::DefaultPages, Some(0)), entry(PlanApplies::DefaultPages, Some(1))];
        let plan = plan_pages(&plan_input).unwrap();
        assert_eq!(plan.page_count, 3);
        let heads: Vec<Option<u32>> = plan.pages.iter().map(|p| p.header).collect();
        assert_eq!(heads, vec![Some(1), Some(0), Some(0)], "the first-page head belongs to page 0 only");
        let foots: Vec<Option<u32>> = plan.pages.iter().map(|p| p.footer).collect();
        assert_eq!(foots, vec![None, Some(0), Some(0)], "a section's foot shows on its own pages");
        let masters: Vec<Option<u32>> = plan.pages.iter().map(|p| p.master).collect();
        assert_eq!(masters, vec![Some(0), Some(1), Some(1)]);
        assert_eq!(plan.pages.iter().map(|p| p.number).collect::<Vec<_>>(), vec![1, 2, 3]);
    }

    #[test]
    fn a_section_that_continues_on_its_page_names_the_pages_from_the_next_one_on() {
        // The marker sits on page 0 beside text already there: page 0 stays section 0 and no page
        // opens; the page the text then overflows onto belongs to section 1.
        let mut marker = text(2, &[30.0]);
        marker.section_marker = true;
        let plan = plan_pages(&input(100.0, vec![text(1, &[30.0]), marker, text(3, &[60.0])])).unwrap();
        assert_eq!(plan.page_count, 2);
        assert_eq!(plan.pages.iter().map(|p| p.section).collect::<Vec<_>>(), vec![0, 1]);
        assert_eq!(pages_of_lines(&plan), vec![0, 0, 1]);

        // A marker that is the first thing on its sheet names that sheet.
        let mut top = text(2, &[60.0]);
        top.section_marker = true;
        let plan = plan_pages(&input(100.0, vec![text(1, &[100.0]), top])).unwrap();
        assert_eq!(plan.pages.iter().map(|p| p.section).collect::<Vec<_>>(), vec![0, 1]);
    }

    #[test]
    fn a_restart_renumbers_from_its_page_and_a_veto_hides_only_its_page() {
        let mut restart = text(2, &[60.0]);
        restart.page_number_restart = Some(1);
        let mut hide = text(3, &[60.0]);
        hide.hides_page_number = true;
        let plan = plan_pages(&input(100.0, vec![text(1, &[60.0]), restart, hide, text(4, &[60.0])])).unwrap();
        assert_eq!(plan.pages.iter().map(|p| p.number).collect::<Vec<_>>(), vec![1, 1, 2, 3]);
        assert_eq!(plan.pages.iter().map(|p| p.number_hidden).collect::<Vec<_>>(), vec![false, false, true, false]);
    }

    #[test]
    fn of_two_restarts_on_one_page_the_first_wins() {
        let mut a = text(1, &[40.0]);
        a.page_number_restart = Some(5);
        let mut b = text(2, &[40.0]);
        b.page_number_restart = Some(9);
        let plan = plan_pages(&input(100.0, vec![a, b, text(3, &[60.0])])).unwrap();
        assert_eq!(plan.pages.iter().map(|p| p.number).collect::<Vec<_>>(), vec![5, 6]);
    }

    fn cited(mut block: PlanBlock, notes: &[(i64, u32)]) -> PlanBlock {
        block.cites = notes.iter().map(|&(note, line)| PlanCite { note, line: Some(line), cell: None }).collect();
        block
    }

    #[test]
    fn the_footnote_band_is_settled_inside_the_plan() {
        // A 100pt body, four 30pt lines; the first cites a 40pt note, so page 0 reserves 8 + 40 = 48
        // and keeps 52: one line fits, the other three go to page 1. The marker stays on page 0, the
        // second round proposes the same band, and the plan stops.
        let mut plan_input = input(100.0, vec![cited(text(1, &[30.0, 30.0, 30.0, 30.0]), &[(1, 0)])]);
        plan_input.notes = vec![PlanNote { number: 1, height: 40.0 }];
        let plan = plan_pages(&plan_input).unwrap();
        assert_eq!(plan.notes_by_page, vec![(0, vec![1])]);
        assert_eq!(plan.note_bands, vec![(0, 48.0)]);
        assert_eq!(pages_of_lines(&plan), vec![0, 1, 1, 1]);
        assert_eq!(plan.footnote_rounds, 2);
    }

    #[test]
    fn a_marker_the_band_keeps_moving_settles_on_the_loose_half_of_its_oscillation() {
        // The marker on the third line cites a 40pt note. Reserved on page 0 it pushes the marker to
        // page 1; reserved on page 1 it lets the marker back. The rule stops on the cycle and takes
        // the pointwise maximum: both pages reserve the band.
        let mut plan_input = input(100.0, vec![cited(text(1, &[30.0, 30.0, 30.0, 30.0]), &[(1, 2)])]);
        plan_input.notes = vec![PlanNote { number: 1, height: 40.0 }];
        let plan = plan_pages(&plan_input).unwrap();
        assert_eq!(plan.note_bands, vec![(0, 48.0), (1, 48.0)]);
        // The final bands move the marker to a page they do not reserve for it (page 2), and a
        // re-taken assignment is adopted only when its bands are already covered: it is not, so the
        // note stays on the page the stopping round saw it on.
        assert_eq!(plan.notes_by_page, vec![(0, vec![1])]);
    }

    #[test]
    fn a_marker_in_a_flowed_table_is_cited_from_the_page_of_its_own_line() {
        // Ten 20pt lines flow over pages 0 and 1 after a 20pt line; the marker is on the sixth, which
        // stands on page 1. Without the cell line the note is cited from where the table starts.
        let cite_at = |cell: Option<[u32; 3]>| {
            let mut table = flow_table_block(2, vec![(200.0, vec![flow_cell(&[20.0; 10])])]);
            table.cites = vec![PlanCite { note: 1, line: None, cell }];
            let mut plan_input = input(100.0, vec![text(1, &[20.0]), table]);
            plan_input.notes = vec![PlanNote { number: 1, height: 10.0 }];
            plan_pages(&plan_input).unwrap().notes_by_page
        };
        assert_eq!(cite_at(None), vec![(0, vec![1])]);
        assert_eq!(cite_at(Some([0, 0, 5])), vec![(1, vec![1])]);
    }

    #[test]
    fn a_note_cited_twice_is_drawn_once_on_the_first_page_that_cites_it() {
        let blocks = vec![cited(text(1, &[60.0]), &[(1, 0)]), cited(text(2, &[60.0]), &[(1, 0)])];
        let mut plan_input = input(100.0, blocks);
        plan_input.notes = vec![PlanNote { number: 1, height: 10.0 }];
        let plan = plan_pages(&plan_input).unwrap();
        assert_eq!(plan.notes_by_page, vec![(0, vec![1])]);
        assert_eq!(plan.note_bands.len(), 1);
    }

    #[test]
    fn the_lines_of_a_table_nested_in_a_cell_are_dealt_with_the_rest() {
        // A cell whose one line holds a nested table of two rows of two 20pt lines: four leaf lines,
        // on a 60pt body that holds three a column.
        let nested_cell = || flow_cell(&[20.0, 20.0]);
        let nested = vec![
            PlanRow { height: 40.0, can_break_above: false, cells: vec![nested_cell()] },
            PlanRow { height: 40.0, can_break_above: true, cells: vec![nested_cell()] },
        ];
        let outer = PlanCell {
            row_span: 1,
            pad_top: 0.0,
            pad_bottom: 0.0,
            content_height: 80.0,
            box_content: None,
            vertical_align: PlanAlign::Top,
            lines: vec![PlanLine { top: 0.0, height: 80.0, trailing: 0.0, rows: nested }],
        };
        let table = columned(flow_table_block(1, vec![(80.0, vec![outer])]), 0);
        let mut plan_input = input(60.0, vec![table]);
        plan_input.body_width = 300.0;
        plan_input.column_runs = vec![two_columns()];
        let plan = plan_pages(&plan_input).unwrap();
        assert_eq!(plan.nested_lines.len(), 4);
        assert_eq!(plan.nested_lines[0].path, vec![0, 0, 0, 0, 0, 0]);
        assert_eq!(plan.nested_lines.iter().map(|l| l.column).collect::<Vec<_>>(), vec![0, 0, 0, 1]);
        assert!(plan.cell_lines.is_empty(), "the cell line that held the nested table is not itself a line");
    }

    #[test]
    fn a_carried_table_with_a_nested_table_is_dealt_by_its_leaf_lines() {
        // 40pt of text, then a table 80pt tall that does not fit what is left of the 100pt sheet: it
        // is carried whole to the stack's next sheet, which the columns read as their second column.
        let nested = vec![PlanRow { height: 80.0, can_break_above: false, cells: vec![flow_cell(&[20.0; 4])] }];
        let outer = PlanCell {
            row_span: 1,
            pad_top: 0.0,
            pad_bottom: 0.0,
            content_height: 80.0,
            box_content: None,
            vertical_align: PlanAlign::Top,
            lines: vec![PlanLine { top: 0.0, height: 80.0, trailing: 0.0, rows: nested }],
        };
        let table = columned(flow_table_block(2, vec![(80.0, vec![outer])]), 0);
        let mut plan_input = input(100.0, vec![columned(text(1, &[40.0]), 0), table]);
        plan_input.body_width = 300.0;
        plan_input.column_runs = vec![two_columns()];
        let plan = plan_pages(&plan_input).unwrap();
        assert_eq!(plan.nested_lines.len(), 4);
        assert!(plan.nested_lines.iter().all(|l| l.column == 1 && l.page == 0));
        assert_eq!(plan.nested_lines.iter().map(|l| l.top).collect::<Vec<_>>(), vec![0.0, 20.0, 40.0, 60.0]);
    }

    #[test]
    fn a_band_that_pushes_its_own_marker_forward_settles_on_the_page_the_marker_ends_on() {
        // The marker sits on the last line that fits page 0 with no band; with its band reserved it
        // no longer fits, moves to page 1, and page 1 reserves the band instead.
        let mut plan_input = input(100.0, vec![cited(text(1, &[45.0, 45.0, 45.0]), &[(1, 1)])]);
        plan_input.notes = vec![PlanNote { number: 1, height: 30.0 }];
        let plan = plan_pages(&plan_input).unwrap();
        let (page, numbers) = &plan.notes_by_page[0];
        assert_eq!(numbers, &vec![1]);
        let band = plan.note_bands.iter().find(|(p, _)| p == page).map(|(_, h)| *h).unwrap();
        assert!(band > 0.0, "the page that cites the note reserves room for it");
        let marker_page = plan.lines.iter().find(|l| l.0 == 0 && l.1 == 1).unwrap().2;
        assert_eq!(marker_page, *page, "the note is on the page its marker landed on");
    }

    #[test]
    fn a_host_that_ran_the_loop_itself_hands_in_its_final_bands() {
        let mut plan_input = input(100.0, vec![text(1, &[40.0, 40.0, 40.0])]);
        plan_input.note_bands = vec![PlanNoteBand { page: 0, height: 30.0 }];
        let plan = plan_pages(&plan_input).unwrap();
        assert_eq!(pages_of_lines(&plan), vec![0, 1, 1], "70pt of body holds one 40pt line");
        assert_eq!(plan.note_bands, vec![(0, 30.0)]);
        assert_eq!(plan.footnote_rounds, 1);
    }

    fn columned(mut block: PlanBlock, run: u32) -> PlanBlock {
        block.column_run = Some(run);
        block
    }

    fn two_columns() -> PlanColumnRun {
        PlanColumnRun { count: 2, spacing: 10.0, widths: Vec::new(), gaps: Vec::new(), proportional: false }
    }

    #[test]
    fn a_columned_run_is_dealt_into_columns_and_the_text_after_it_follows_the_last_line() {
        // 30pt of text, then ten 10pt lines in two columns on a 100pt page, then more text.
        // The run starts at y=30, so its first column offers 70: seven lines; column two begins
        // where the run did and takes the other three; the next block follows the last of them.
        let blocks = vec![
            text(1, &[30.0]),
            columned(text(2, &[10.0; 10]), 0),
            text(3, &[10.0]),
        ];
        let mut plan_input = input(100.0, blocks);
        plan_input.body_width = 300.0;
        plan_input.column_runs = vec![two_columns()];
        let plan = plan_pages(&plan_input).unwrap();
        let line = |b: u32, l: u32| plan.lines.iter().find(|p| p.0 == b && p.1 == l).copied().unwrap();
        assert_eq!((line(1, 0).2, line(1, 0).3), (0, 30.0));
        assert_eq!((line(1, 6).2, line(1, 6).3), (0, 90.0));
        assert_eq!((line(1, 7).2, line(1, 7).3), (0, 30.0), "the eighth line begins column two where the run began");
        assert!(plan.column_lines.contains(&[1, 7, 1]));
        assert!(plan.column_lines.contains(&[1, 0, 0]));
        // Text after the run continues below the last line of the last column.
        assert_eq!((line(2, 0).2, line(2, 0).3), (0, 60.0));
        assert_eq!(plan.page_count, 1);
    }

    #[test]
    fn the_text_after_a_columned_run_follows_its_last_line_and_the_spacing_the_run_left() {
        let mut run = columned(text(1, &[10.0; 4]), 0);
        run.spacing_after = 7.0;
        let mut plan_input = input(100.0, vec![text(0, &[20.0]), run, text(2, &[10.0])]);
        plan_input.body_width = 300.0;
        plan_input.column_runs = vec![two_columns()];
        let plan = plan_pages(&plan_input).unwrap();
        // Four lines in the 80pt left of the sheet: one column. The last ends at 60; 7 of spacing.
        let after = plan.lines.iter().find(|l| l.0 == 2).unwrap();
        assert_eq!((after.2, after.3), (0, 67.0));
        assert_eq!(plan.pages[0].first_key, Some(0), "the page's first block is the one before the run");
        assert_eq!(plan.page_count, 1);
    }

    #[test]
    fn a_table_in_a_columned_stack_is_pulled_by_the_first_layout_like_any_other() {
        // As `a_pull_the_first_layout_made_stays_even_when_the_settled_layout_would_not_make_it`, with
        // the table under a column declaration: the stack's first layout leaves its first line at
        // y=95 stranded at the foot, and the reader keeps the pull that finds.
        let table = columned(flow_table_block(2, vec![(200.0, vec![flow_cell(&[20.0; 10])])]), 0);
        let mut plan_input = input(100.0, vec![text(1, &[95.0]), table]);
        plan_input.band = 20.0;
        plan_input.body_width = 300.0;
        plan_input.column_runs = vec![two_columns()];
        let plan = plan_pages(&plan_input).unwrap();
        assert_eq!(plan.pulled_lines, vec![vec![1, 0, 0, 0]]);
    }

    #[test]
    fn a_cell_box_encloses_what_its_last_line_uses_not_the_spacing_after_it() {
        let cell = |boxed: Option<f64>| PlanCell { pad_top: 1.0, pad_bottom: 1.0, box_content: boxed, ..flow_cell(&[30.0]) };
        let mut with = vec![PlanRow { height: 0.0, can_break_above: false, cells: vec![cell(Some(25.0))] }];
        let mut without = vec![PlanRow { height: 0.0, can_break_above: false, cells: vec![cell(None)] }];
        settle_rows(&mut with);
        settle_rows(&mut without);
        assert_eq!(with[0].height, 27.0);
        assert_eq!(without[0].height, 32.0);
    }

    #[test]
    fn a_nested_table_grows_the_box_content_with_the_cell_it_stands_in() {
        // The line standing for the nested table is 10 tall and the table solves to 30: the cell's
        // content, and what its box encloses, both grow by 20.
        let nested = vec![PlanRow { height: 30.0, can_break_above: false, cells: Vec::new() }];
        let line = PlanLine { top: 0.0, height: 10.0, trailing: 0.0, rows: nested };
        let cell = PlanCell { content_height: 10.0, box_content: Some(8.0), lines: vec![line], ..flow_cell(&[]) };
        let mut rows = vec![PlanRow { height: 0.0, can_break_above: false, cells: vec![cell] }];
        settle_rows(&mut rows);
        assert_eq!(rows[0].height, 28.0);
    }

    #[test]
    fn a_columned_run_that_overflows_its_sheet_opens_the_next_one() {
        let blocks = vec![columned(text(1, &[10.0; 25]), 0)];
        let mut plan_input = input(100.0, blocks);
        plan_input.body_width = 300.0;
        plan_input.column_runs = vec![two_columns()];
        let plan = plan_pages(&plan_input).unwrap();
        // Ten lines a column, twenty a sheet: the last five are on page 1, in its first column.
        assert_eq!(plan.page_count, 2);
        assert_eq!(plan.lines.iter().filter(|l| l.2 == 1).count(), 5);
        assert_eq!(plan.pages[1].first_key, Some(1));
        assert!(plan.column_lines.contains(&[0, 24, 0]));
    }

    #[test]
    fn a_section_opened_inside_a_columned_run_starts_on_the_page_its_first_line_was_dealt_to() {
        // 25 lines a sheet-and-a-bit in two columns (twenty a sheet), then a section start in the
        // same run: in the reader's stack it opens stack page 5, but the columns deal it to the sheet
        // that holds its line, and that is where the section begins.
        let mut opener = columned(text(2, &[10.0]), 0);
        opener.section_start = true;
        let blocks = vec![columned(text(1, &[10.0; 25]), 0), opener];
        let mut plan_input = input(100.0, blocks);
        plan_input.body_width = 300.0;
        plan_input.column_runs = vec![two_columns()];
        let plan = plan_pages(&plan_input).unwrap();
        let dealt = plan.lines.iter().find(|l| l.0 == 1).map(|l| l.2).unwrap();
        assert_eq!(plan.pages[dealt as usize].section, 1);
        assert_eq!(plan.pages[dealt as usize - 1].section, 0);
    }

    #[test]
    fn a_declaration_of_one_column_is_laid_out_as_ordinary_text() {
        let blocks = vec![columned(text(1, &[30.0, 30.0, 30.0, 30.0]), 0)];
        let mut plan_input = input(100.0, blocks);
        plan_input.body_width = 300.0;
        plan_input.column_runs = vec![PlanColumnRun { count: 1, spacing: 0.0, widths: Vec::new(), gaps: Vec::new(), proportional: false }];
        let plan = plan_pages(&plan_input).unwrap();
        assert_eq!(pages_of_lines(&plan), vec![0, 0, 0, 1]);
        assert!(plan.column_lines.is_empty());
    }

    #[test]
    fn a_table_inside_a_columned_run_is_dealt_cell_line_by_cell_line() {
        // One row, two cells of three 20pt lines, on a 100pt page whose columns hold 50: the first
        // column takes two lines of each cell's stack, the second column the rest.
        let table = columned(flow_table_block(1, vec![(60.0, vec![flow_cell(&[20.0; 3])])]), 0);
        let mut plan_input = input(100.0, vec![columned(text(0, &[10.0; 4]), 0), table]);
        plan_input.body_width = 300.0;
        plan_input.column_runs = vec![two_columns()];
        let plan = plan_pages(&plan_input).unwrap();
        // The stack: four 10pt lines (0..40) then 20pt cell lines at 40, 60, 80; the columns are 100
        // tall, so everything fits column one.
        assert_eq!(plan.cell_lines.iter().map(|l| (l.4, l.5)).collect::<Vec<_>>(), vec![(0, 40.0), (0, 60.0), (0, 80.0)]);
        assert_eq!(plan.column_cell_lines.len(), 3);
        // The row stands in column one from its first line to its last (the cell has no padding).
        assert_eq!(plan.column_row_segments, vec![ColumnRowSegment(1, 0, 0, 0, 40.0, 100.0)]);
        // The geometry the columns index into: two columns of (300 - 10) / 2.
        assert_eq!(plan.column_runs.len(), 1);
        assert_eq!(plan.column_runs[0].iter().map(|c| (c.x, c.width)).collect::<Vec<_>>(), vec![(0.0, 145.0), (155.0, 145.0)]);
    }

    #[test]
    fn a_row_a_column_cuts_is_boxed_in_each_column_with_its_cell_padding_only_at_the_cut_ends() {
        // One cell of four 20pt lines padded 4 above and below (a row 88 tall) in a run whose columns
        // hold 70: the first three lines fit column one, the fourth starts column two.
        let mut cell = flow_cell(&[20.0; 4]);
        cell.pad_top = 4.0;
        cell.pad_bottom = 4.0;
        cell.content_height = 80.0;
        let table = columned(flow_table_block(1, vec![(88.0, vec![cell])]), 0);
        let mut plan_input = input(70.0, vec![table]);
        plan_input.body_width = 300.0;
        plan_input.column_runs = vec![two_columns()];
        let plan = plan_pages(&plan_input).unwrap();
        let boxes: Vec<(u32, f64, f64)> = plan.column_row_segments.iter().map(|s| (s.3, s.4, s.5)).collect();
        // Column one: from the top, with the room above the first line, and the cut keeps nothing
        // below its last line (three 20pt lines: the box ends where they do).
        // Column two: the line left, which as the cell's last line keeps its 4 below it.
        assert_eq!(boxes.len(), 2, "{boxes:?}");
        assert_eq!((boxes[0].0, boxes[0].1), (0, 0.0), "{boxes:?}");
        assert_eq!(boxes[0].2 % 20.0, 0.0, "the cut keeps no room: {boxes:?}");
        assert_eq!(boxes[1].0, 1, "{boxes:?}");
        assert_eq!(boxes[1].2 - boxes[1].1, 20.0 + 4.0, "{boxes:?}");
    }

    #[test]
    fn a_cell_in_a_columned_run_is_boxed_with_the_padding_it_has_above_its_first_line_and_below_its_last() {
        // 40pt of text, then in the same run a one-row table whose cell (padded 4 and 4) holds one 20pt
        // line: the line stands at 44, the box from 40 to 68.
        let mut cell = flow_cell(&[20.0]);
        cell.pad_top = 4.0;
        cell.pad_bottom = 4.0;
        let table = columned(flow_table_block(1, vec![(28.0, vec![cell])]), 0);
        let mut plan_input = input(100.0, vec![columned(text(0, &[40.0]), 0), table]);
        plan_input.body_width = 300.0;
        plan_input.column_runs = vec![two_columns()];
        let plan = plan_pages(&plan_input).unwrap();
        assert_eq!(plan.cell_lines.iter().map(|l| l.5).collect::<Vec<_>>(), vec![44.0]);
        assert_eq!(plan.column_row_segments, vec![ColumnRowSegment(1, 0, 0, 0, 40.0, 68.0)]);
    }

    #[test]
    fn what_stands_below_a_nested_table_is_dealt_where_the_engine_solved_the_nest_ends() {
        // The same cell as the nesting test above (a line, a nest the host summed to 80 but solved to
        // 40, a line) in a columned run: the last line stands at 10 + 40, not 10 + 80.
        let nested = vec![PlanRow { height: 80.0, can_break_above: false, cells: vec![flow_cell(&[40.0])] }];
        let line = |top, height| PlanLine { top, height, trailing: 0.0, rows: Vec::new() };
        let outer = PlanCell {
            row_span: 1,
            pad_top: 0.0,
            pad_bottom: 0.0,
            content_height: 100.0,
            box_content: None,
            vertical_align: PlanAlign::Top,
            lines: vec![line(0.0, 10.0), PlanLine { top: 10.0, height: 80.0, trailing: 0.0, rows: nested }, line(90.0, 10.0)],
        };
        let table = columned(PlanBlock { kind: PlanKind::Table, rows: vec![PlanRow { height: 100.0, can_break_above: false, cells: vec![outer] }], ..text(1, &[]) }, 0);
        let mut plan_input = input(1000.0, vec![table]);
        plan_input.body_width = 300.0;
        plan_input.column_runs = vec![two_columns()];
        let plan = plan_pages(&plan_input).unwrap();
        let last = plan.cell_lines.iter().find(|l| l.3 == 2).unwrap();
        assert_eq!(last.5, 50.0);
    }

    #[test]
    fn a_table_described_cell_by_cell_is_as_tall_as_textkit_makes_it_whatever_heights_the_host_summed() {
        // Row 0 holds a two-row cell needing 25 and a one-row cell needing 9; row 1 a one-row cell
        // needing 8. The rows are 9 and 8 plus the 8 the two-row cell is short, all on row 1 (9 + 16):
        // the table is 25 tall however tall the host said its rows were.
        let merged = PlanCell { row_span: 2, vertical_align: PlanAlign::Middle, ..flow_cell(&[25.0]) };
        let rows = vec![
            PlanRow { height: 100.0, can_break_above: true, cells: vec![merged, flow_cell(&[9.0])] },
            PlanRow { height: 100.0, can_break_above: false, cells: vec![flow_cell(&[8.0])] },
        ];
        let table = PlanBlock { kind: PlanKind::Table, rows, ..text(1, &[]) };
        let plan = plan_pages(&input(1000.0, vec![table])).unwrap();
        assert_eq!(plan.placements[0].height, 25.0);
    }

    #[test]
    fn a_piece_is_carried_when_its_lines_reach_past_the_foot_though_its_box_would_fit() {
        // Row 1's box would end at 100, the foot; its last line hangs 6 below it, which is where the
        // reader asks a carried piece to fit.
        let rows = [(10.0, false), (10.0, true), (10.0, true)];
        let page_of_row = |plan: &PagePlan, row: u32| plan.placements.iter().find(|p| p.row_start == Some(row)).unwrap().page;
        let mut reaching = table(2, &rows, false);
        reaching.row_reach = vec![10.0, 16.0, 10.0];
        let plan = plan_pages(&input(100.0, vec![text(1, &[80.0]), reaching])).unwrap();
        assert_eq!((page_of_row(&plan, 0), page_of_row(&plan, 1)), (0, 1));
        let plain = plan_pages(&input(100.0, vec![text(1, &[80.0]), table(2, &rows, false)])).unwrap();
        assert_eq!((page_of_row(&plain, 0), page_of_row(&plain, 1)), (0, 0));
    }

    fn hanging_cell(box_content: f64) -> PlanCell {
        let line = PlanLine { top: 0.0, height: 28.0, trailing: 8.0, rows: Vec::new() };
        PlanCell { content_height: 28.0, box_content: Some(box_content), lines: vec![line], ..flow_cell(&[]) }
    }

    #[test]
    fn what_follows_a_table_starts_below_its_last_line_where_the_spacing_after_hangs_past_the_box() {
        let rows = vec![PlanRow { height: 20.0, can_break_above: false, cells: vec![hanging_cell(20.0)] }];
        let table = PlanBlock { kind: PlanKind::Table, rows, ..text(1, &[]) };
        let plan = plan_pages(&input(1000.0, vec![table, text(2, &[10.0])])).unwrap();
        assert_eq!(plan.placements[0].height, 28.0);
        assert_eq!(plan.lines[0].3, 28.0);
    }

    #[test]
    fn a_flowed_table_ends_at_its_last_line_where_the_spacing_after_it_hangs_below_the_box() {
        // 15 lines of 10 on 100pt pages: ten on the first, five on the second, the last hanging 5 of
        // spacing below its box, with 1pt of padding under the cell.
        let below = |box_content: f64| {
            let lines: Vec<PlanLine> = (0..15).map(|i| PlanLine { top: i as f64 * 10.0, height: 10.0, trailing: 0.0, rows: Vec::new() }).collect();
            let cell = PlanCell { pad_bottom: 1.0, content_height: 150.0, box_content: Some(box_content), lines, ..flow_cell(&[]) };
            let rows = vec![PlanRow { height: 146.0, can_break_above: false, cells: vec![cell] }];
            let table = PlanBlock { kind: PlanKind::Table, rows, ..text(1, &[]) };
            let plan = plan_pages(&input(100.0, vec![table, text(2, &[10.0])])).unwrap();
            let line = plan.lines.iter().find(|l| l.0 == 1).unwrap();
            (line.2, line.3)
        };
        // The last line ends it, though the row's box (with the padding under it) ends at 46.
        assert_eq!(below(145.0), (1, 50.0));
    }

    #[test]
    fn rows_the_host_observed_are_kept_as_they_are() {
        // The same table as above, but its host laid it out itself (TextKit) and says these are the
        // rows it made: the engine does not second-guess them from the cells.
        let merged = PlanCell { row_span: 2, vertical_align: PlanAlign::Middle, ..flow_cell(&[25.0]) };
        let rows = vec![
            PlanRow { height: 30.0, can_break_above: true, cells: vec![merged, flow_cell(&[9.0])] },
            PlanRow { height: 12.0, can_break_above: false, cells: vec![flow_cell(&[8.0])] },
        ];
        let table = PlanBlock { kind: PlanKind::Table, rows, rows_observed: true, ..text(1, &[]) };
        let plan = plan_pages(&input(1000.0, vec![table])).unwrap();
        assert_eq!(plan.placements[0].height, 42.0);
    }

    #[test]
    fn a_table_nested_in_a_cell_moves_what_stands_below_it_when_the_engine_solves_its_height() {
        // A cell holds a 10pt line, a nested table the host summed to 80 (its one row's cell needs
        // only 40) and a 10pt line. The nest is 40, so the cell is 60 tall, not 100.
        let nested = vec![PlanRow { height: 80.0, can_break_above: false, cells: vec![flow_cell(&[40.0])] }];
        let line = |top, height| PlanLine { top, height, trailing: 0.0, rows: Vec::new() };
        let outer = PlanCell {
            row_span: 1,
            pad_top: 0.0,
            pad_bottom: 0.0,
            content_height: 100.0,
            box_content: None,
            vertical_align: PlanAlign::Top,
            lines: vec![line(0.0, 10.0), PlanLine { top: 10.0, height: 80.0, trailing: 0.0, rows: nested }, line(90.0, 10.0)],
        };
        let table = PlanBlock { kind: PlanKind::Table, rows: vec![PlanRow { height: 100.0, can_break_above: false, cells: vec![outer] }], ..text(1, &[]) };
        let plan = plan_pages(&input(1000.0, vec![table])).unwrap();
        assert_eq!(plan.placements[0].height, 60.0);
    }

    #[test]
    fn a_table_with_no_cell_data_in_a_columned_run_is_dealt_row_by_row() {
        let rows: Vec<PlanRow> = (0..6).map(|i| PlanRow { height: 30.0, can_break_above: i > 0, cells: Vec::new() }).collect();
        let table = columned(PlanBlock { kind: PlanKind::Table, rows, ..text(1, &[]) }, 0);
        let mut plan_input = input(100.0, vec![table]);
        plan_input.body_width = 300.0;
        plan_input.column_runs = vec![two_columns()];
        let plan = plan_pages(&plan_input).unwrap();
        // Three rows a column (90 of 100), so rows 3..5 are in column two from the top.
        let rows_in: Vec<(Option<u32>, Option<u32>)> = plan.placements.iter().map(|p| (p.column, p.row_start)).collect();
        assert_eq!(rows_in[0], (Some(0), Some(0)));
        assert_eq!(rows_in[3], (Some(1), Some(3)));
        assert_eq!(plan.placements[3].top, 0.0);
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
