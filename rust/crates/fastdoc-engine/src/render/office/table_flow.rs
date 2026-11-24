//! A table that fits no page, flowed line by line across page boundaries (S4 of
//! `docs/plans/pagination-to-engine.md`).
//!
//! A table taller than the page body has nowhere to be carried to, so it is not carried or cut at
//! a row: its lines flow exactly like prose — a line whose glyphs would pass the body's foot starts
//! the next page, and everything after it in that cell follows. This is the rule macOS applies to
//! a table piece that fits no page (`PageBandLayoutDelegate`, invariants 61d, 64, 142), stated once
//! over the line boxes a host measured; it is what lets a row split mid-cell, which a plan made of
//! whole rows cannot express.
//!
//! What it models, and where it comes from:
//! - cells are top-aligned (the reader forces it for a broken table, `topAlignCellsOf`), so every
//!   decision is made on the line's PROPOSED position: the row's top plus the cell's padding plus
//!   the line's own offset in the cell;
//! - each cell flows on its own. A line that would pass the foot starts the next page; the lines
//!   after it keep their natural gaps, so a cell's content lands flush at the next page's top;
//! - a row ends where its last cell ends (or at its natural height, whichever is lower down), and
//!   the next row starts there; a merged cell's end constrains the last row it covers;
//! - a run of three lines or fewer left at the foot of a page that the piece continues onto is
//!   pulled to the next page, whole (`orphanRunStarts`, the owner's 1-3 line rule). The pull only
//!   ever moves the run's FIRST line (the others follow or stay, as they do on macOS), is recorded,
//!   and the flow is re-run until no new run is found — the same fixpoint the reader's settle loop
//!   reaches, bounded by the same eight rounds.
//!
//! Pure arithmetic over host-measured boxes; it carries no text.

use super::page_plan::{PlanBlock, PlanRow};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// The reader's settle budget (`FootnoteBandSettle.maxRounds`): the most pull-forward rounds a
/// piece gets before the layout is taken as it stands.
pub const MAX_ROUNDS: usize = 8;

/// A pulled line must start this far from its page top to count as stranded (`orphanRunStarts`).
const NOT_AT_TOP: f64 = 0.5;

/// A run this long or shorter, stranded at a page's foot, moves on whole.
const MAX_ORPHAN_RUN: usize = 3;

/// One row's extent on one page: `[block, row, page, top, bottom]`, page-local points. A row the
/// flow carried across a boundary has one entry per page it touches.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct RowSegment(pub u32, pub u32, pub u32, pub f64, pub f64);

/// One cell line's place: `[block, row, cell, line, page, top]`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct CellLinePlacement(pub u32, pub u32, pub u32, pub u32, pub u32, pub f64);

/// The geometry the flow runs on. `band` is the space between one page's body foot and the next
/// page's body top (headers, footers, the desk gap): a position past `content_height + band` is on
/// the next page, one inside the band is on this page and starts the next at its first line.
pub struct FlowGeometry<'a> {
    pub content_height: f64,
    pub band: f64,
    pub note_bands: &'a HashMap<u32, f64>,
}

impl FlowGeometry<'_> {
    fn body(&self, page: u32) -> f64 {
        self.content_height - self.note_bands.get(&page).copied().unwrap_or(0.0)
    }

    fn pitch(&self) -> f64 {
        self.content_height + self.band
    }

    /// A position that has run past a whole page (a row taller than the pitch) is on a later one.
    pub fn normalise(&self, page: u32, y: f64) -> (u32, f64) {
        let pitch = self.pitch();
        if pitch > 0.0 && y >= pitch {
            let pages = (y / pitch).floor();
            return (page + pages as u32, y - pages * pitch);
        }
        (page, y)
    }
}

/// What the flow produced for one table.
#[derive(Debug, Clone, PartialEq)]
pub struct TableFlow {
    /// Where the table's last row ends: `(page, y)`.
    pub end: (u32, f64),
    /// Where the block after the table starts: the lower of `end` and the last line the typesetter
    /// placed (the last cell's, in text order), whose spacing after hangs below its box.
    pub after: (u32, f64),
    pub segments: Vec<RowSegment>,
    pub lines: Vec<CellLinePlacement>,
    /// The page the table's top edge is on.
    pub first_page: u32,
}

/// Does this table have the line data a flow needs?
pub fn has_cells(rows: &[PlanRow]) -> bool {
    rows.iter().any(|r| !r.cells.is_empty())
}

/// Where a line sits in the table: its row, cell and item, then — for a line inside a nested table
/// — the same three again. Lexicographic order IS document order.
pub type LinePath = Vec<u32>;

/// Every line a flow placed, nested ones included: `(path, page, top)`.
pub type PlacedLines = Vec<(LinePath, u32, f64)>;

/// Floating-point slack in a fit test, in points.
const NOISE: f64 = 1e-6;

fn fits(geometry: &FlowGeometry, page: u32, y: f64, height: f64, trailing: f64) -> bool {
    // The delegate's own comparison: the glyphs must clear the foot, the spacing under them may hang.
    // The delegate compares absolute coordinates thousands of points down the document and this
    // compares page-local sums of the host's line heights, so a line that ends exactly on the foot
    // lands on either side of it by arithmetic noise alone; `NOISE` is far below anything a
    // document can say.
    !(y + height - trailing > geometry.body(page) + NOISE)
}

/// One pass of a table's flow from `(page, y)`, which is where its top edge stands.
///
/// `shift` is whether the page rule acts on the table's lines. The reader's FIRST layout of a
/// document has no record that any table fits no page, so its lines are left where they fall
/// (`shift: false`); every later layout shifts them. The lines in `pulled` are forced to the next
/// page whatever they would have done — the reader keeps every pull it has ever made, so the caller
/// owns that set across passes (`orphan_runs` says which lines a pass would add).
pub fn flow_table(
    geometry: &FlowGeometry,
    block_index: u32,
    block: &PlanBlock,
    start: (u32, f64),
    pulled: &BTreeSet<LinePath>,
    shift: bool,
) -> (TableFlow, PlacedLines) {
    let mut runner = Runner {
        geometry,
        block: block_index,
        pulled,
        shift,
        segments: Vec::new(),
        lines: Vec::new(),
        every_line: Vec::new(),
        last_line: None,
    };
    let start = geometry.normalise(start.0, start.1);
    let end = runner.rows(&block.rows, start, &[]);
    let after = runner.last_line.map_or(end, |line_end| later(end, line_end));
    let flow = TableFlow { end, after, segments: runner.segments, lines: runner.lines, first_page: start.0 };
    (flow, runner.every_line)
}

struct Runner<'a> {
    geometry: &'a FlowGeometry<'a>,
    block: u32,
    pulled: &'a BTreeSet<LinePath>,
    shift: bool,
    segments: Vec<RowSegment>,
    lines: Vec<CellLinePlacement>,
    every_line: PlacedLines,
    /// Where the outer table's last cell in text order ended its last line, spacing after included.
    last_line: Option<(u32, f64)>,
}

impl Runner<'_> {
    /// Flows a table's rows from `start`; returns where the last one ends. `prefix` is the path of
    /// the item holding this table (empty for the outer one).
    fn rows(&mut self, rows: &[PlanRow], start: (u32, f64), prefix: &[u32]) -> (u32, f64) {
        let g = self.geometry;
        let (mut page, mut y) = start;
        // A merged cell's end, held for the last row it covers.
        let mut pending: BTreeMap<usize, (u32, f64)> = BTreeMap::new();
        for (r, row) in rows.iter().enumerate() {
            let (row_page, row_y) = (page, y);
            let mut end = g.normalise(row_page, row_y + row.height);
            // Where the row's cells begin. A cell whose FIRST line the page rule carries to a later
            // page takes the row's origin with it: the cells laid out after it start from there, as
            // the reader's typesetter lays them (measured: a one-line label pulled to the next page
            // brings the long cell beside it to the same page top).
            let mut origin = (row_page, row_y);
            for (c, cell) in row.cells.iter().enumerate() {
                let mut pos = g.normalise(origin.0, origin.1 + cell.pad_top);
                let mut previous_bottom = 0.0_f64;
                for (l, line) in cell.lines.iter().enumerate() {
                    let at = g.normalise(pos.0, pos.1 + (line.top - previous_bottom).max(0.0));
                    let mut path = prefix.to_vec();
                    path.extend([r as u32, c as u32, l as u32]);
                    pos = if line.rows.is_empty() {
                        let after = self.line(&path, at, line.height, line.trailing);
                        if l == 0 && self.shift && after.0 > origin.0 {
                            origin = (after.0, (after.1 - line.height) - cell.pad_top);
                        }
                        after
                    } else {
                        // A table inside the cell flows by the same rule.
                        self.rows(&line.rows, at, &path)
                    };
                    previous_bottom = line.top + line.height;
                }
                if prefix.is_empty() {
                    self.last_line = Some(pos);
                }
                let tail = (cell.content_height - previous_bottom).max(0.0);
                // The box ends at what the last line uses: the spacing after it hangs below.
                let hanging = cell.box_content.map_or(0.0, |b| (cell.content_height - b).max(0.0));
                let cell_end = g.normalise(pos.0, pos.1 + tail - hanging + cell.pad_bottom);
                let target = row_index_end(r, cell.row_span, rows.len());
                if target == r {
                    end = later(end, cell_end);
                } else {
                    let held = pending.entry(target).or_insert(cell_end);
                    *held = later(*held, cell_end);
                }
            }
            if let Some(held) = pending.remove(&r) {
                end = later(end, held);
            }
            if prefix.is_empty() {
                push_segments(&mut self.segments, self.block, r as u32, (row_page, row_y), end, g);
            }
            page = end.0;
            y = end.1;
        }
        (page, y)
    }

    /// One line, placed by the delegate's rule; returns the position below it.
    fn line(&mut self, path: &[u32], at: (u32, f64), height: f64, trailing: f64) -> (u32, f64) {
        let (mut p, mut ly) = at;
        let forced = self.pulled.contains(path);
        if self.shift && (forced || !fits(self.geometry, p, ly, height, trailing)) && (forced || ly > 0.0) {
            // A line already at the page's top has nowhere better to go; a forced one is moved
            // whatever it would have done (the delegate's `pullToNextPage`).
            p += 1;
            ly = 0.0;
        }
        self.every_line.push((path.to_vec(), p, ly));
        if path.len() == 3 {
            self.lines.push(CellLinePlacement(self.block, path[0], path[1], path[2], p, ly));
        }
        (p, ly + height)
    }
}

fn row_index_end(row: usize, span: u32, rows: usize) -> usize {
    (row + span.max(1) as usize - 1).min(rows.saturating_sub(1))
}

fn later(a: (u32, f64), b: (u32, f64)) -> (u32, f64) {
    if b.0 > a.0 || (b.0 == a.0 && b.1 > a.1) { b } else { a }
}

/// One entry per page a row touches: from where it starts to the page's body foot, whole pages in
/// between, and from the page top to where it ends.
fn push_segments(
    out: &mut Vec<RowSegment>,
    block: u32,
    row: u32,
    from: (u32, f64),
    to: (u32, f64),
    geometry: &FlowGeometry,
) {
    let mut page = from.0;
    let mut top = from.1;
    while page < to.0 {
        out.push(RowSegment(block, row, page, top, geometry.body(page).max(top)));
        page += 1;
        top = 0.0;
    }
    out.push(RowSegment(block, row, page, top, to.1.max(top)));
}

/// The page grid the reader bins a line by: `pitch` is a page's body plus the band after it, and
/// `leading` the band above the first page. The default (no pitch) files every line under its own
/// page.
#[derive(Debug, Clone, Copy, Default)]
pub struct PageGrid {
    pub pitch: f64,
    pub leading: f64,
}

impl PageGrid {
    /// The page the reader's `orphanRunStarts` files a line under, and the line's top on that page.
    ///
    /// It divides the line's absolute offset by the pitch and floors, with no tolerance. A line the
    /// page rule moved to the top of page `k` stands at `k * pitch + leading`, and the reader
    /// subtracts `leading` again before dividing; that round trip loses the last bit for some grids,
    /// so the line is filed under page `k - 1`, a full pitch below its top. The reader's run counts
    /// follow that filing, so the plan's must.
    fn filed(&self, page: u32, top: f64) -> (u32, f64) {
        if top != 0.0 || page == 0 || !(self.pitch > 0.0) {
            return (page, top);
        }
        let landed = f64::from(page) * self.pitch + self.leading;
        let offset = landed - self.leading;
        if (offset / self.pitch).floor() < f64::from(page) {
            return (page - 1, self.pitch);
        }
        (page, top)
    }
}

/// The first line of every run of three lines or fewer a group leaves at a page's foot while it
/// continues on the next.
pub fn orphan_runs(grid: &PageGrid, rows: &[PlanRow], lines: &[(LinePath, u32, f64)]) -> Vec<LinePath> {
    let group_of = group_starts(rows);
    // (group, page) -> lines, each with the top it is filed at
    let mut runs: BTreeMap<(usize, u32), Vec<(&LinePath, f64)>> = BTreeMap::new();
    for line in lines {
        let (page, top) = grid.filed(line.1, line.2);
        runs.entry((group_of[line.0[0] as usize], page)).or_default().push((&line.0, top));
    }
    let mut out = Vec::new();
    for (&(group, page), members) in &runs {
        if members.len() > MAX_ORPHAN_RUN || !runs.contains_key(&(group, page + 1)) {
            continue;
        }
        let first = members.iter().min_by(|a, b| a.0.cmp(b.0)).expect("a run has a line");
        if first.1 > NOT_AT_TOP {
            out.push(first.0.clone());
        }
    }
    out
}

/// For every row, the row index its unbreakable group starts at.
fn group_starts(rows: &[PlanRow]) -> Vec<usize> {
    let mut out = Vec::with_capacity(rows.len());
    let mut start = 0usize;
    for (i, row) in rows.iter().enumerate() {
        if i == 0 || row.can_break_above {
            start = i;
        }
        out.push(start);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::render::office::page_plan::{PlanCell, PlanKind, PlanLine};

    fn cell(lines: &[f64], pad_top: f64, pad_bottom: f64) -> PlanCell {
        let mut top = 0.0;
        let lines: Vec<PlanLine> = lines
            .iter()
            .map(|&h| {
                let l = PlanLine { top, height: h, trailing: 0.0, rows: Vec::new(), loc: None };
                top += h;
                l
            })
            .collect();
        PlanCell { row_span: 1, pad_top, pad_bottom, content_height: top, box_content: None, vertical_align: Default::default(), lines }
    }

    fn row(height: f64, can_break_above: bool, cells: Vec<PlanCell>) -> PlanRow {
        PlanRow { height, can_break_above, cells }
    }

    fn table(rows: Vec<PlanRow>) -> PlanBlock {
        PlanBlock { key: 1, kind: PlanKind::Table, rows, ..PlanBlock::default() }
    }

    fn geometry(body: f64, band: f64) -> (HashMap<u32, f64>, f64, f64) {
        (HashMap::new(), body, band)
    }

    /// The reader's settle for ONE table: flow, pull what a pass strands, flow again.
    fn run_settled(body: f64, band: f64, start: (u32, f64), rows: Vec<PlanRow>) -> (TableFlow, usize) {
        let (notes, body, band) = geometry(body, band);
        let g = FlowGeometry { content_height: body, band, note_bands: &notes };
        let block = table(rows);
        let mut pulled = BTreeSet::new();
        loop {
            let (flow, lines) = flow_table(&g, 0, &block, start, &pulled, true);
            let before = pulled.len();
            pulled.extend(orphan_runs(&PageGrid::default(), &block.rows, &lines));
            if pulled.len() == before {
                return (flow, pulled.len());
            }
        }
    }

    fn run(body: f64, band: f64, start: (u32, f64), rows: Vec<PlanRow>) -> TableFlow {
        run_settled(body, band, start, rows).0
    }

    fn pages_of(flow: &TableFlow) -> Vec<u32> {
        flow.lines.iter().map(|l| l.4).collect()
    }

    #[test]
    fn a_cells_box_ends_where_its_last_line_uses_and_the_spacing_after_it_hangs_below() {
        // Two 10pt lines whose last carries 4pt of spacing after: the box encloses 16 of the 20.
        let mut c = cell(&[10.0, 10.0], 1.0, 1.0);
        c.box_content = Some(16.0);
        let flow = run(100.0, 20.0, (0, 0.0), vec![row(0.0, false, vec![c])]);
        assert_eq!(flow.end, (0, 18.0));
        let flow = run(100.0, 20.0, (0, 0.0), vec![row(0.0, false, vec![cell(&[10.0, 10.0], 1.0, 1.0)])]);
        assert_eq!(flow.end, (0, 22.0));
    }

    #[test]
    fn a_line_that_ends_on_the_foot_to_within_arithmetic_noise_stays() {
        // The second line ends 1e-10 past a 79.18 body: rounding, not a document, put it there.
        let rows = vec![row(200.0, false, vec![cell(&[69.18, 10.0 + 1e-10, 10.0], 0.0, 0.0)])];
        let flow = run(79.18, 20.0, (0, 0.0), rows);
        assert_eq!(pages_of(&flow)[1], 0, "the second line ends on the foot and stays");
    }

    #[test]
    fn a_single_tall_cell_flows_line_by_line_onto_the_next_page() {
        // Ten 20pt lines in a 100pt body, no padding: five a page.
        let rows = vec![row(200.0, false, vec![cell(&[20.0; 10], 0.0, 0.0)])];
        let flow = run(100.0, 20.0, (0, 0.0), rows);
        assert_eq!(pages_of(&flow), vec![0, 0, 0, 0, 0, 1, 1, 1, 1, 1]);
        assert_eq!(flow.lines[5].5, 0.0);
        assert_eq!(flow.end, (1, 100.0));
    }

    #[test]
    fn the_first_line_that_passes_the_foot_starts_the_next_page_and_the_rest_follow() {
        let rows = vec![row(150.0, false, vec![cell(&[40.0, 40.0, 40.0, 30.0], 0.0, 0.0)])];
        let flow = run(100.0, 0.0, (0, 0.0), rows);
        // 40 + 40 = 80; the third (to 120) does not fit: page 1 from 0.
        assert_eq!(pages_of(&flow), vec![0, 0, 1, 1]);
        assert_eq!((flow.lines[2].5, flow.lines[3].5), (0.0, 40.0));
    }

    #[test]
    fn cells_flow_independently_and_the_row_ends_at_the_last_of_them() {
        let rows = vec![row(
            120.0,
            false,
            vec![cell(&[40.0, 40.0, 40.0], 0.0, 0.0), cell(&[30.0, 30.0], 0.0, 0.0)],
        )];
        let flow = run(100.0, 0.0, (0, 0.0), rows);
        // Cell 0 crosses at its third line; cell 1 stays whole on page 0.
        let by_cell = |c: u32| flow.lines.iter().filter(|l| l.2 == c).map(|l| l.4).collect::<Vec<_>>();
        assert_eq!(by_cell(0), vec![0, 0, 1]);
        assert_eq!(by_cell(1), vec![0, 0]);
        assert_eq!(flow.end, (1, 40.0));
    }

    #[test]
    fn the_next_row_starts_where_a_flowed_row_ended() {
        let rows = vec![
            row(120.0, false, vec![cell(&[40.0, 40.0, 40.0], 0.0, 0.0)]),
            row(30.0, true, vec![cell(&[30.0], 0.0, 0.0)]),
        ];
        let flow = run(100.0, 0.0, (0, 0.0), rows);
        let last = flow.lines.last().unwrap();
        assert_eq!((last.1, last.4, last.5), (1, 1, 40.0));
    }

    #[test]
    fn padding_moves_the_first_line_and_the_cells_foot() {
        let rows = vec![row(60.0, false, vec![cell(&[30.0], 10.0, 20.0)])];
        let flow = run(100.0, 0.0, (0, 0.0), rows);
        assert_eq!(flow.lines[0].5, 10.0);
        assert_eq!(flow.end, (0, 60.0));
    }

    #[test]
    fn a_line_that_leaves_only_its_spacing_under_the_foot_stays() {
        let mut c = cell(&[60.0, 60.0], 0.0, 0.0);
        c.lines[1].trailing = 25.0;
        // The second line ends at 120; 25 of it is spacing, so its glyphs end at 95 <= 100.
        let flow = run(100.0, 0.0, (0, 0.0), vec![row(120.0, false, vec![c])]);
        assert_eq!(pages_of(&flow), vec![0, 0]);
    }

    #[test]
    fn a_run_of_three_lines_or_fewer_stranded_at_the_foot_moves_on_whole() {
        // One cell of six 30pt lines starts at y=60 of a 100pt page: only its first line fits, and
        // the piece goes on over the next pages. One stranded line is not worth the seam.
        let rows = vec![row(180.0, false, vec![cell(&[30.0; 6], 0.0, 0.0)])];
        let (flow, pulled) = run_settled(100.0, 0.0, (0, 60.0), rows);
        assert_eq!(pulled, 1);
        assert_eq!(pages_of(&flow)[0], 1, "the stranded first line starts the next page");
    }

    #[test]
    fn three_lines_stranded_at_the_foot_are_still_a_run_that_moves_on() {
        // Starts at y=40 of a 100pt page: three 20pt lines fit, then the piece goes on. Three is the
        // longest run the owner's rule moves; four stay (next test).
        let rows = vec![row(240.0, false, vec![cell(&[20.0; 12], 0.0, 0.0)])];
        let (flow, pulled) = run_settled(100.0, 0.0, (0, 40.0), rows);
        assert_eq!(pulled, 1);
        assert_eq!(pages_of(&flow)[0], 1);
    }

    #[test]
    fn four_lines_at_the_foot_stay_where_they_are() {
        let rows = vec![row(300.0, false, vec![cell(&[20.0; 12], 0.0, 0.0)])];
        let (flow, pulled) = run_settled(100.0, 0.0, (0, 20.0), rows);
        assert_eq!(pulled, 0);
        assert_eq!(pages_of(&flow)[0], 0);
    }

    #[test]
    fn a_run_that_starts_a_page_is_the_continuation_and_is_not_pulled() {
        // Two lines open page 0, two open page 1 and one opens page 2: every run starts a page, so no
        // run is stranded, however short.
        let rows = vec![row(200.0, false, vec![cell(&[40.0, 40.0, 40.0, 40.0, 40.0], 0.0, 0.0)])];
        let (flow, pulled) = run_settled(100.0, 0.0, (0, 0.0), rows);
        assert_eq!(pulled, 0);
        assert_eq!(pages_of(&flow), vec![0, 0, 1, 1, 2]);
    }

    #[test]
    fn a_cell_whose_first_line_is_carried_over_brings_the_cells_after_it() {
        // A one-line label and a four-line cell beside it, starting at y=95 of a 100pt page: the
        // label's line does not fit and starts page 1, and the cell laid out after it begins there
        // too, instead of keeping its first line on page 0.
        let rows = vec![row(80.0, false, vec![cell(&[20.0], 0.0, 0.0), cell(&[1.0; 4], 0.0, 0.0)])];
        let flow = run(100.0, 0.0, (0, 95.0), rows);
        assert_eq!(pages_of(&flow), vec![1, 1, 1, 1, 1]);
        assert_eq!(flow.lines[1].5, 0.0, "the second cell starts at the page top");
    }

    #[test]
    fn a_merged_cells_end_holds_the_last_row_it_covers() {
        let mut tall = cell(&[40.0, 40.0, 40.0], 0.0, 0.0);
        tall.row_span = 2;
        let rows = vec![
            row(30.0, false, vec![tall, cell(&[30.0], 0.0, 0.0)]),
            row(30.0, true, vec![cell(&[30.0], 0.0, 0.0)]),
        ];
        let flow = run(100.0, 0.0, (0, 0.0), rows);
        // The merged cell's third line crosses to page 1 (ends at 40); row 1 cannot end before it.
        assert_eq!(flow.end.0, 1);
        assert!(flow.end.1 >= 40.0);
        // But the merged cell's end is held for the row it covers: row 1 still starts where row 0's
        // own cells ended (y=30 on page 0), not below the merged cell.
        let row_one_line = flow.lines.iter().find(|l| l.1 == 1).unwrap();
        assert_eq!((row_one_line.4, row_one_line.5), (0, 30.0));
    }

    #[test]
    fn a_row_that_runs_past_a_whole_pitch_leaves_the_next_row_on_a_later_page() {
        // Body 100 + band 20: a 250pt empty row from y=0 ends at 250 = page 2, y 10.
        let rows = vec![row(250.0, false, vec![]), row(10.0, true, vec![cell(&[10.0], 0.0, 0.0)])];
        let flow = run(100.0, 20.0, (0, 0.0), rows);
        assert_eq!((flow.lines[0].4, flow.lines[0].5), (2, 10.0));
    }

    #[test]
    fn a_table_nested_in_a_cell_flows_by_the_same_rule() {
        // An outer cell holding a nested two-row table of 40pt lines: the second nested row's line
        // passes the 100pt foot and starts page 1, taking the outer cell's end with it.
        let nested = vec![
            row(40.0, false, vec![cell(&[40.0], 0.0, 0.0)]),
            row(40.0, true, vec![cell(&[40.0], 0.0, 0.0)]),
            row(40.0, true, vec![cell(&[40.0], 0.0, 0.0)]),
        ];
        let mut outer = cell(&[], 0.0, 0.0);
        outer.lines.push(PlanLine { top: 0.0, height: 120.0, trailing: 0.0, rows: nested, loc: None });
        outer.content_height = 120.0;
        let flow = run(100.0, 20.0, (0, 0.0), vec![row(120.0, false, vec![outer])]);
        assert_eq!(flow.end, (1, 40.0));
    }

    #[test]
    fn rows_without_cell_data_keep_their_natural_height() {
        let rows = vec![row(40.0, false, vec![]), row(40.0, true, vec![])];
        let flow = run(100.0, 0.0, (0, 0.0), rows);
        assert_eq!(flow.end, (0, 80.0));
        assert!(!has_cells(&[row(1.0, false, vec![])]));
    }

    #[test]
    fn the_first_layout_leaves_every_line_where_it_falls_whatever_pulls_are_known() {
        // `shift: false` is the reader's first layout: nothing moves, not even a line an earlier
        // layout pulled. Ten 20pt lines from y=60 of a 100pt body: the first stays on page 0.
        let (notes, body, band) = geometry(100.0, 0.0);
        let g = FlowGeometry { content_height: body, band, note_bands: &notes };
        let block = table(vec![row(200.0, false, vec![cell(&[20.0; 10], 0.0, 0.0)])]);
        let pulled: BTreeSet<LinePath> = [vec![0, 0, 0]].into_iter().collect();
        let (first, _) = flow_table(&g, 0, &block, (0, 60.0), &pulled, false);
        assert_eq!((first.lines[0].4, first.lines[0].5), (0, 60.0));
        let (later, _) = flow_table(&g, 0, &block, (0, 60.0), &pulled, true);
        assert_eq!((later.lines[0].4, later.lines[0].5), (1, 0.0), "a later layout applies the pull");
    }

    /// A grid whose page-6 top does not survive the reader's `(6 * pitch + leading) - leading`
    /// round trip: 700.18 + 141.7 and a 70.85 leading band.
    fn lossy_grid() -> PageGrid {
        let grid = PageGrid { pitch: 700.18 + 141.7, leading: 70.85 };
        let landed = 6.0 * grid.pitch + grid.leading;
        assert!(((landed - grid.leading) / grid.pitch).floor() < 6.0, "the grid must lose the bit");
        grid
    }

    /// One row, one cell: a run of lines on page 5 and the line the page rule moved to page 6's top.
    fn stranded_with_a_moved_line() -> (PlanBlock, Vec<(LinePath, u32, f64)>) {
        let block = table(vec![row(0.0, false, vec![cell(&[10.0; 8], 0.0, 0.0)])]);
        let line = |i: u32, page: u32, top: f64| (vec![0, 0, i], page, top);
        let lines = vec![line(0, 5, 650.0), line(1, 5, 660.0), line(2, 5, 670.0), line(3, 6, 0.0), line(4, 6, 10.0)];
        (block, lines)
    }

    #[test]
    fn a_line_moved_to_a_page_top_is_filed_under_the_page_above_when_the_grid_loses_a_bit() {
        // Three lines at the foot of page 5 and the moved one at page 6's top: the reader files the
        // fourth under page 5, so the run is four lines and nothing is stranded.
        let (block, lines) = stranded_with_a_moved_line();
        assert!(orphan_runs(&lossy_grid(), &block.rows, &lines).is_empty());
        // Where the grid keeps the bit the line stays on its own page and the three are stranded.
        let exact = PageGrid { pitch: 100.0, leading: 0.0 };
        assert_eq!(orphan_runs(&exact, &block.rows, &lines), vec![vec![0, 0, 0]]);
    }

    #[test]
    fn a_line_below_a_page_top_is_never_refiled() {
        let (block, mut lines) = stranded_with_a_moved_line();
        lines[3].2 = 0.5;
        assert_eq!(orphan_runs(&lossy_grid(), &block.rows, &lines), vec![vec![0, 0, 0]]);
    }

    #[test]
    fn a_row_crossing_a_page_reports_a_segment_on_each_page() {
        let rows = vec![row(150.0, false, vec![cell(&[40.0, 40.0, 40.0, 30.0], 0.0, 0.0)])];
        let flow = run(100.0, 0.0, (0, 0.0), rows);
        let pages: Vec<u32> = flow.segments.iter().map(|s| s.2).collect();
        assert_eq!(pages, vec![0, 1]);
    }
}
