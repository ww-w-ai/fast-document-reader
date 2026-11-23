//! Multi-column runs in the page plan (S5 of `docs/plans/pagination-to-engine.md`; invariants 100,
//! 143-145, 150).
//!
//! A document goes to N columns partway down a sheet and back again; the text under a declaration is
//! laid out as ONE tall stack at a column's width and then dealt into columns by a running offset
//! (`ColumnGeometry.placements`: down column 1 of a sheet, then column 2, then the next sheet). That
//! map and the geometry of the columns are in `column_geometry.rs`; this module is the glue that
//! feeds them the plan's stack and turns their answer back into pages.
//!
//! Page numbers and tops here follow the page grid of the plan: absolute `y` is
//! `leading + page * pitch + top`, the same one the reader's layout uses, so the map's own
//! arithmetic (`1e-6` of tolerance, the carry of a pushed line) runs on the numbers it was written for.

use super::column_geometry::{Column, ColumnGeometry, OfficeColumnLayout};
use serde::Deserialize;
use std::collections::HashMap;

/// What a document declares at the start of a columned run, as much as the geometry needs.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanColumnRun {
    pub count: i64,
    #[serde(default)]
    pub spacing: f64,
    /// Per-column widths and the gap after each, for a document that did not ask for equal columns.
    #[serde(default)]
    pub widths: Vec<f64>,
    #[serde(default)]
    pub gaps: Vec<f64>,
    /// Whether `widths`/`gaps` are shares of the whole (HWP 5) rather than points (HWPX).
    #[serde(default)]
    pub proportional: bool,
}

impl PlanColumnRun {
    /// The columns this declaration makes inside a body `body_width` wide; one column when it does
    /// not split the text.
    pub fn columns(&self, body_width: f64) -> Vec<Column> {
        let layout = OfficeColumnLayout {
            count: self.count,
            spacing: self.spacing,
            widths: self.widths.clone(),
            gaps: self.gaps.clone(),
            proportional: self.proportional,
            same_width: self.widths.is_empty(),
            ..OfficeColumnLayout::default()
        };
        ColumnGeometry::columns(body_width, &layout)
    }
}

/// The page grid a run is dealt across.
pub struct RunGrid<'a> {
    pub content_height: f64,
    pub band: f64,
    pub leading: f64,
    pub note_bands: &'a HashMap<u32, f64>,
}

impl RunGrid<'_> {
    pub fn pitch(&self) -> f64 {
        self.content_height + self.band
    }

    fn body(&self, page: u32) -> f64 {
        self.content_height - self.note_bands.get(&page).copied().unwrap_or(0.0)
    }

    /// The page an absolute `y` falls on — `PageBandLayoutDelegate.page(of:leadingBand:pitch:)`.
    pub fn page_of(&self, y: f64) -> i64 {
        (((y - self.leading) / self.pitch()) + 1e-6).floor() as i64
    }

    /// Absolute `y` of a page-local top.
    pub fn absolute(&self, page: u32, top: f64) -> f64 {
        self.leading + f64::from(page) * self.pitch() + top
    }

    /// The `(page, page-local top)` of an absolute `y`.
    pub fn local(&self, y: f64) -> (u32, f64) {
        let page = self.page_of(y).max(0) as u32;
        (page, y - self.leading - f64::from(page) * self.pitch())
    }
}

/// Where a stack line ended up: its column, its page and its page-local top.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ColumnedLine {
    pub column: u32,
    pub page: u32,
    pub top: f64,
}

/// Deals a run's stack into columns. `lines` are `(id, absolute top, height)` in DOCUMENT order, the
/// first of which is where the run begins; the answer is keyed by `id`. `None` when the geometry
/// cannot be dealt (fewer than two columns, a run with no room).
pub fn place_run(lines: &[(i64, f64, f64)], columns: &[Column], grid: &RunGrid) -> Option<HashMap<i64, ColumnedLine>> {
    let first = lines.first()?;
    let pitch = grid.pitch();
    if !(pitch > 0.0) {
        return None;
    }
    // A run does not have to begin at a page top (invariant 100): its first sheet offers what is left
    // of it, every later one the whole body.
    let start_page = grid.page_of(first.1).max(0) as u32;
    let page_top = grid.absolute(start_page, 0.0);
    let origin = first.1.max(page_top);
    let first_height = (f64::from(start_page) * pitch + grid.body(start_page)) - (origin - grid.leading);
    let later_height = grid.body(start_page + 1);
    if !(first_height > 0.0) || !(later_height > 0.0) {
        return None;
    }
    let map = ColumnGeometry::placements(
        lines,
        origin,
        f64::from(start_page),
        columns,
        later_height,
        pitch,
        grid.leading,
        Some(first_height),
    );
    if map.is_empty() {
        return None;
    }
    let mut out = HashMap::with_capacity(map.len());
    for (id, (x, y)) in map {
        let column = columns.iter().position(|c| (c.x - x).abs() < 1e-6).unwrap_or(0) as u32;
        let (page, top) = grid.local(y);
        out.insert(id, ColumnedLine { column, page, top });
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn two_equal(width: f64) -> Vec<Column> {
        PlanColumnRun { count: 2, spacing: 10.0, widths: vec![], gaps: vec![], proportional: false }.columns(width)
    }

    fn grid(notes: &HashMap<u32, f64>) -> RunGrid<'_> {
        RunGrid { content_height: 100.0, band: 20.0, leading: 0.0, note_bands: notes }
    }

    fn stack(heights: &[f64], origin: f64) -> Vec<(i64, f64, f64)> {
        let mut y = origin;
        heights
            .iter()
            .enumerate()
            .map(|(i, &h)| {
                let line = (i as i64, y, h);
                y += h;
                line
            })
            .collect()
    }

    #[test]
    fn a_declaration_of_one_column_or_none_splits_nothing() {
        assert_eq!(PlanColumnRun { count: 1, spacing: 0.0, widths: vec![], gaps: vec![], proportional: false }.columns(300.0).len(), 1);
        let notes = HashMap::new();
        assert!(place_run(&stack(&[10.0], 0.0), &two_equal(300.0)[..1], &grid(&notes)).is_none());
    }

    #[test]
    fn the_stack_reads_down_column_one_then_column_two_then_the_next_sheet() {
        let notes = HashMap::new();
        // Ten 20pt lines on a 100pt body: five a column, so a sheet holds ten.
        let placed = place_run(&stack(&[20.0; 12], 0.0), &two_equal(300.0), &grid(&notes)).unwrap();
        let at = |i: i64| placed[&i];
        assert_eq!((at(0).column, at(0).page, at(0).top), (0, 0, 0.0));
        assert_eq!((at(4).column, at(4).page, at(4).top), (0, 0, 80.0));
        assert_eq!((at(5).column, at(5).page, at(5).top), (1, 0, 0.0));
        assert_eq!((at(9).column, at(9).page, at(9).top), (1, 0, 80.0));
        // The eleventh line is on the next sheet: its absolute y is `pitch` further down.
        assert_eq!((at(10).column, at(10).page, at(10).top), (0, 1, 0.0));
    }

    #[test]
    fn a_run_that_starts_partway_down_a_sheet_offers_that_sheet_only_what_is_left() {
        let notes = HashMap::new();
        // Starts 40pt down: its first column has 60pt (three 20pt lines); later sheets the whole 100.
        let placed = place_run(&stack(&[20.0; 8], 40.0), &two_equal(300.0), &grid(&notes)).unwrap();
        assert_eq!((placed[&0].column, placed[&0].page, placed[&0].top), (0, 0, 40.0));
        assert_eq!((placed[&3].column, placed[&3].page, placed[&3].top), (1, 0, 40.0), "column two begins where the run began");
        assert_eq!((placed[&6].column, placed[&6].page), (0, 1), "the first sheet held six lines");
        assert_eq!(placed[&6].top, 0.0);
    }

    #[test]
    fn a_line_that_would_cross_a_columns_foot_moves_whole_and_takes_the_rest_with_it() {
        let notes = HashMap::new();
        // 30 + 30 + 30 fill 90 of 100; the 30pt fourth does not fit and starts column two, and the
        // fifth follows it rather than sitting where it was.
        let placed = place_run(&stack(&[30.0, 30.0, 30.0, 30.0, 30.0], 0.0), &two_equal(300.0), &grid(&notes)).unwrap();
        assert_eq!((placed[&3].column, placed[&3].top), (1, 0.0));
        assert_eq!((placed[&4].column, placed[&4].top), (1, 30.0));
    }

    #[test]
    fn a_footnote_band_shortens_the_body_its_page_offers() {
        let notes: HashMap<u32, f64> = [(0, 40.0)].into_iter().collect();
        // Page 0 offers 60: three 20pt lines a column.
        let placed = place_run(&stack(&[20.0; 7], 0.0), &two_equal(300.0), &grid(&notes)).unwrap();
        assert_eq!((placed[&3].column, placed[&3].page), (1, 0));
        assert_eq!(placed[&6].page, 1, "six lines fill the first sheet");
    }

    #[test]
    fn unequal_columns_come_from_the_declared_widths() {
        let run = PlanColumnRun { count: 2, spacing: 0.0, widths: vec![100.0, 200.0], gaps: vec![0.0, 0.0], proportional: false };
        let columns = run.columns(300.0);
        assert_eq!(columns.iter().map(|c| (c.x, c.width)).collect::<Vec<_>>(), vec![(0.0, 100.0), (100.0, 200.0)]);
    }
}
