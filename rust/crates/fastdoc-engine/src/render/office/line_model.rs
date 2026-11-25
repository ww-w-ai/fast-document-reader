//! The line model: how tall a paragraph's lines stand, and how tall a table row is, decided once
//! (S3 of `docs/plans/pagination-to-engine.md`).
//!
//! macOS gets these answers from TextKit applying the paragraph style `office_text_builder.rs`
//! resolved (invariants 161b/161e, 169, 170). A host with no such text stack (Avalonia) used to
//! invent them: a cell's lines at their natural height whatever the document's rule said, every
//! empty cell paragraph at a default size, every HWP line spacing ABOVE the glyphs. This module is
//! the one statement of those rules for a host that reports what it MEASURED and lets the engine
//! decide what the document MEANS. It carries no text and shapes nothing (plan D1): the input is
//! each line's natural box as the host's own layout produced it, the output is the box the
//! document asks for.
//!
//! What it decides, per paragraph:
//! - the paragraph's line-height rule (`Multiple` scales a line's natural box, `Exact` replaces it,
//!   `AtLeast` floors it) and the document's line grid, a floor under whatever the rule produced;
//! - HWP's line spacing BELOW the glyphs (161e): a paragraph whose rule is a floor taller than its
//!   character size stands `floor` per line whatever the face's natural box, and its last line may
//!   hand the gap back (161b) — in a cell that holds one paragraph, or in any cell of a table the
//!   reader lets break across pages;
//! - an empty paragraph in an HWP cell is one line of its own character size (169);
//! - a table row's height from its cells: each cell's content plus its padding, a decorative band
//!   standing at its declared height, a single-line cell floored at its row's declared height
//!   (166), and a merged cell's shortfall added to the last row it covers (`table_rows.rs`).
//!
//! Units: whatever the host used, throughout one call. The module never converts.

use super::table_rows::{self, RowNeed};
use serde::{Deserialize, Serialize};

/// `LineModelInput.version`. A host that sends another value is refused rather than guessed at.
pub const LINE_MODEL_VERSION: u32 = 1;

/// How far a floor must clear the character size before the line model treats the difference as
/// spacing (the same hair `office_text_builder.rs`'s `apply_line_model` uses by comparing `>`).
const GAP_EPSILON: f64 = 1e-9;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RuleMode {
    Multiple,
    Exact,
    AtLeast,
}

/// A paragraph's line-height rule, as the tree carries it (`wire::LineHeight`).
#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rule {
    pub mode: RuleMode,
    pub value: f64,
}

impl Rule {
    /// One line's box under this rule, from the box the host measured for it.
    fn apply(self, natural: f64) -> f64 {
        match self.mode {
            RuleMode::Exact => self.value,
            RuleMode::AtLeast => natural.max(self.value),
            RuleMode::Multiple => natural * if self.value > 0.0 { self.value } else { 1.0 },
        }
    }
}

/// One paragraph as the host measured it, plus the facts the document declared about it.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ParagraphFacts {
    /// Each line's natural box, in order. A blank paragraph carries ONE entry: the natural box of a
    /// line of its own size.
    #[serde(default)]
    pub lines: Vec<f64>,
    /// No visible text. Only its line stands.
    #[serde(default)]
    pub blank: bool,
    #[serde(default)]
    pub rule: Option<Rule>,
    /// The paragraph's character size: its largest run, or — for a blank paragraph — the size the
    /// reader vouched for.
    #[serde(default)]
    pub char_size: f64,
    #[serde(default)]
    pub spacing_before: f64,
    #[serde(default)]
    pub spacing_after: f64,
    /// HWP: the pitch is `size + spacing`, glyphs at the top of the box (161e).
    #[serde(default)]
    pub line_spacing_below: bool,
    /// The declared faces' line floor (invariant 163): the largest `size × lineHeightFloorRatio`
    /// over the paragraph's text runs, or — for a blank cell paragraph — of the run the reader
    /// vouched for. `0` when no run declares one. See `face_floor` for when it applies.
    #[serde(default)]
    pub face_floor: f64,
}

/// A paragraph's lines after the document's own rules.
#[derive(Debug, Clone, PartialEq)]
pub struct PlacedParagraph {
    pub heights: Vec<f64>,
    /// The part of the LAST line's box that is spacing under the glyphs, which a page may let hang
    /// past its foot (161e). `0` when the paragraph has no such rule or handed it back.
    pub trailing: f64,
}

/// The line box a paragraph stands at. `grid` is the document's line grid pitch, a floor under every
/// line. `in_cell` selects the cell-only rules; `drops_trailing_gap` is the cell's rule that its
/// last line is a line and not a line plus its spacing (161b).
pub fn place_paragraph(p: &ParagraphFacts, grid: Option<f64>, in_cell: bool, drops_trailing_gap: bool) -> PlacedParagraph {
    let floor = |h: f64| match grid {
        Some(g) if g > 0.0 => h.max(g),
        _ => h,
    };
    let count = p.lines.len().max(1);
    // 169: an empty paragraph in an HWP cell is a line of its own character size, nothing else.
    if p.blank && in_cell && p.line_spacing_below && p.char_size > 0.0 {
        return PlacedParagraph { heights: vec![p.char_size], trailing: 0.0 };
    }
    let below_floor = match p.rule {
        Some(Rule { mode: RuleMode::AtLeast, value })
            if p.line_spacing_below && !p.blank && p.char_size > 0.0 && value > p.char_size + GAP_EPSILON =>
        {
            Some(value)
        }
        _ => None,
    };
    if let Some(pitch) = below_floor {
        let mut heights = vec![floor(pitch); count];
        let gap = pitch - p.char_size;
        if drops_trailing_gap {
            // The last line is a line, not a line plus its spacing.
            *heights.last_mut().expect("count >= 1") = floor(p.char_size);
            return PlacedParagraph { heights, trailing: 0.0 };
        }
        return PlacedParagraph { heights, trailing: gap };
    }
    let rule = p.rule;
    let natural = |i: usize| p.lines.get(i).copied().unwrap_or(0.0);
    let face = face_floor(p, in_cell);
    let heights = (0..count)
        .map(|i| floor(match rule { Some(r) => r.apply(natural(i)), None => natural(i) }.max(face)))
        .collect();
    PlacedParagraph { heights, trailing: 0.0 }
}

/// The floor a declared face puts under every line of `p` (invariant 163), the way macOS's
/// `OfficeTextBuilder` raises `minimumLineHeight`: `face_floor × max(1, multiple)`; nothing under an
/// exact rule or HWP's below-the-glyphs pitch. In the body it floors a paragraph with text
/// (`applyDeclaredFaceLineHeight`); in a cell only a blank paragraph, the empty line whose face the
/// reader vouched for (`emptyCellLine`) — macOS's cell content takes no face floor on its text lines.
fn face_floor(p: &ParagraphFacts, in_cell: bool) -> f64 {
    if p.face_floor <= 0.0 || p.line_spacing_below || p.blank != in_cell {
        return 0.0;
    }
    match p.rule {
        Some(Rule { mode: RuleMode::Exact, .. }) => 0.0,
        Some(Rule { mode: RuleMode::Multiple, value }) => p.face_floor * value.max(1.0),
        _ => p.face_floor,
    }
}

// ------------------------------------------------------------------------------------------
// Table rows
// ------------------------------------------------------------------------------------------

/// One thing stacked in a cell.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum CellItem {
    /// Consecutive paragraphs, laid out by the host.
    #[serde(rename_all = "camelCase")]
    Text { paragraphs: Vec<ParagraphFacts> },
    /// A picture or a nested table: a box the host already sized.
    #[serde(rename_all = "camelCase")]
    Fixed { height: f64 },
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CellFacts {
    pub row: usize,
    #[serde(default = "one")]
    pub row_span: usize,
    /// Top plus bottom padding.
    #[serde(default)]
    pub v_padding: f64,
    /// An empty cell whose row declares a height stands at it outright (a decorative band).
    #[serde(default)]
    pub declared_height: Option<f64>,
    /// A single-line cell is held to at least this (the row's declared height, 166).
    #[serde(default)]
    pub min_row_height: Option<f64>,
    #[serde(default)]
    pub items: Vec<CellItem>,
}

fn one() -> usize {
    1
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TableFacts {
    pub row_count: usize,
    /// One line of the document's default size: what a cell with no content at all stands at.
    pub empty_line: f64,
    /// The table's default top plus bottom padding, for a row no cell begins in.
    #[serde(default)]
    pub row_padding: f64,
    /// The reader lets this table break across pages, so every cell's last line is a line (161b).
    #[serde(default)]
    pub drops_trailing_gap: bool,
    pub cells: Vec<CellFacts>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LineModelInput {
    pub version: u32,
    #[serde(default)]
    pub grid_pitch: Option<f64>,
    /// Body paragraphs, answered one for one.
    #[serde(default)]
    pub paragraphs: Vec<ParagraphFacts>,
    #[serde(default)]
    pub tables: Vec<TableFacts>,
}

/// Where each line of a paragraph sits inside its cell, relative to the cell's content origin.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ParagraphLayout {
    pub tops: Vec<f64>,
    pub heights: Vec<f64>,
    /// The part of each line's box that is spacing under the glyphs (HWP, 161e), which a page may
    /// let hang past its foot; `0` when the paragraph has no such rule or handed it back.
    pub trailing: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ItemLayout {
    #[serde(rename_all = "camelCase")]
    Text { paragraphs: Vec<ParagraphLayout> },
    #[serde(rename_all = "camelCase")]
    Fixed { top: f64, height: f64 },
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CellLayout {
    /// The cell's content height, padding not included.
    pub height: f64,
    pub items: Vec<ItemLayout>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TableLayout {
    pub row_heights: Vec<f64>,
    pub cells: Vec<CellLayout>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ParagraphAnswer {
    pub heights: Vec<f64>,
    pub trailing: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LineModelOutput {
    pub model_version: u32,
    pub paragraphs: Vec<ParagraphAnswer>,
    pub tables: Vec<TableLayout>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum LineModelError {
    Version(u32),
    NotFinite(&'static str),
    RowOutOfRange { row: usize, rows: usize },
}

impl std::fmt::Display for LineModelError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Version(v) => write!(f, "line model version {v} is not {LINE_MODEL_VERSION}"),
            Self::NotFinite(what) => write!(f, "{what} is not a finite number"),
            Self::RowOutOfRange { row, rows } => write!(f, "a cell sits in row {row} of a {rows}-row table"),
        }
    }
}

impl std::error::Error for LineModelError {}

fn finite(value: f64, what: &'static str) -> Result<(), LineModelError> {
    if value.is_finite() { Ok(()) } else { Err(LineModelError::NotFinite(what)) }
}

fn check_paragraph(p: &ParagraphFacts) -> Result<(), LineModelError> {
    for h in &p.lines {
        finite(*h, "a line box")?;
    }
    finite(p.char_size, "a character size")?;
    finite(p.spacing_before, "a spacing")?;
    finite(p.spacing_after, "a spacing")?;
    finite(p.face_floor, "a face floor")?;
    if let Some(rule) = p.rule {
        finite(rule.value, "a line-height rule")?;
    }
    Ok(())
}

/// Lays a cell's content out from its top and reports its height.
fn layout_cell(cell: &CellFacts, empty_line: f64, grid: Option<f64>, table_drops_gap: bool) -> CellLayout {
    if cell.items.is_empty() {
        return CellLayout { height: empty_line, items: Vec::new() };
    }
    // 161b counts every paragraph the cell holds, a nested table or picture included.
    let paragraph_count: usize = cell
        .items
        .iter()
        .map(|item| match item {
            CellItem::Text { paragraphs } => paragraphs.len(),
            CellItem::Fixed { .. } => 1,
        })
        .sum();
    let mut y = 0.0_f64;
    let mut items = Vec::with_capacity(cell.items.len());
    let last_item = cell.items.len() - 1;
    for (index, item) in cell.items.iter().enumerate() {
        match item {
            CellItem::Fixed { height } => {
                items.push(ItemLayout::Fixed { top: y, height: *height });
                y += *height;
            }
            CellItem::Text { paragraphs } => {
                let mut laid = Vec::with_capacity(paragraphs.len());
                for (i, p) in paragraphs.iter().enumerate() {
                    let is_last = index == last_item && i + 1 == paragraphs.len();
                    let drops = is_last && (paragraph_count == 1 || table_drops_gap);
                    let placed = place_paragraph(p, grid, true, drops);
                    y += p.spacing_before;
                    let mut tops = Vec::with_capacity(placed.heights.len());
                    for h in &placed.heights {
                        tops.push(y);
                        y += *h;
                    }
                    y += p.spacing_after;
                    laid.push(ParagraphLayout { tops, heights: placed.heights, trailing: placed.trailing });
                }
                items.push(ItemLayout::Text { paragraphs: laid });
            }
        }
    }
    CellLayout { height: y, items }
}

/// A cell that holds something to draw: visible text or a box. A cell of nothing but blank
/// paragraphs is "empty" for the decorative-band rule.
fn has_content(cell: &CellFacts) -> bool {
    cell.items.iter().any(|item| match item {
        CellItem::Fixed { .. } => true,
        CellItem::Text { paragraphs } => paragraphs.iter().any(|p| !p.blank),
    })
}

/// One unwrapped line of text and nothing else (166's single-line cell).
fn single_text_line(cell: &CellFacts) -> bool {
    match cell.items.as_slice() {
        [CellItem::Text { paragraphs }] => matches!(paragraphs.as_slice(), [p] if !p.blank && p.lines.len() <= 1),
        _ => false,
    }
}

pub fn solve_table(table: &TableFacts, grid: Option<f64>) -> Result<TableLayout, LineModelError> {
    finite(table.empty_line, "an empty line")?;
    finite(table.row_padding, "a row padding")?;
    let rows = table.row_count;
    let mut cells = Vec::with_capacity(table.cells.len());
    for cell in &table.cells {
        if cell.row >= rows {
            return Err(LineModelError::RowOutOfRange { row: cell.row, rows });
        }
        finite(cell.v_padding, "a padding")?;
        for item in &cell.items {
            match item {
                CellItem::Fixed { height } => finite(*height, "a box height")?,
                CellItem::Text { paragraphs } => paragraphs.iter().try_for_each(check_paragraph)?,
            }
        }
        cells.push(layout_cell(cell, table.empty_line, grid, table.drops_trailing_gap));
    }

    // A cell asks for its content plus its padding (a decorative band for its declared height, a
    // single-line cell for at least its row's); `table_rows` says how TextKit turns those claims into
    // row heights, merged cells included.
    let needs: Vec<RowNeed> = table
        .cells
        .iter()
        .zip(&cells)
        .map(|(cell, laid)| {
            let span = cell.row_span.max(1);
            let need = match cell.declared_height {
                // A band the document drew that tall: the declaration already counts both paddings and
                // the line, so it replaces their sum.
                Some(declared) if span == 1 && declared > 0.0 && !has_content(cell) => declared,
                _ => {
                    let mut need = laid.height + cell.v_padding;
                    if span == 1 {
                        if let Some(floor) = cell.min_row_height {
                            if floor > 0.0 && single_text_line(cell) {
                                need = need.max(floor);
                            }
                        }
                    }
                    need
                }
            };
            RowNeed { row: cell.row, span, need }
        })
        .collect();
    let base = table.empty_line + table.row_padding;
    let row_heights = table_rows::row_heights(rows, &needs, &vec![base; rows]);
    Ok(TableLayout { row_heights, cells })
}

/// The whole call: body paragraphs answered one for one, tables solved.
pub fn solve(input: &LineModelInput) -> Result<LineModelOutput, LineModelError> {
    if input.version != LINE_MODEL_VERSION {
        return Err(LineModelError::Version(input.version));
    }
    if let Some(grid) = input.grid_pitch {
        finite(grid, "a line grid")?;
    }
    let mut paragraphs = Vec::with_capacity(input.paragraphs.len());
    for p in &input.paragraphs {
        check_paragraph(p)?;
        let placed = place_paragraph(p, input.grid_pitch, false, false);
        paragraphs.push(ParagraphAnswer { heights: placed.heights, trailing: placed.trailing });
    }
    let tables = input
        .tables
        .iter()
        .map(|t| solve_table(t, input.grid_pitch))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(LineModelOutput { model_version: LINE_MODEL_VERSION, paragraphs, tables })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn para(lines: &[f64], rule: Option<Rule>, size: f64, below: bool) -> ParagraphFacts {
        ParagraphFacts {
            lines: lines.to_vec(),
            blank: false,
            rule,
            char_size: size,
            spacing_before: 0.0,
            spacing_after: 0.0,
            line_spacing_below: below,
            face_floor: 0.0,
        }
    }
    fn at_least(v: f64) -> Option<Rule> {
        Some(Rule { mode: RuleMode::AtLeast, value: v })
    }

    #[test]
    fn each_rule_mode_acts_on_the_natural_box_its_own_way() {
        let p = |mode, v| para(&[14.0, 14.0], Some(Rule { mode, value: v }), 10.0, false);
        assert_eq!(place_paragraph(&p(RuleMode::Multiple, 1.5), None, false, false).heights, vec![21.0, 21.0]);
        assert_eq!(place_paragraph(&p(RuleMode::Exact, 9.0), None, false, false).heights, vec![9.0, 9.0]);
        assert_eq!(place_paragraph(&p(RuleMode::AtLeast, 12.0), None, false, false).heights, vec![14.0, 14.0]);
        assert_eq!(place_paragraph(&p(RuleMode::AtLeast, 20.0), None, false, false).heights, vec![20.0, 20.0]);
        assert_eq!(place_paragraph(&para(&[14.0], None, 10.0, false), None, false, false).heights, vec![14.0]);
    }

    #[test]
    fn the_line_grid_is_a_floor_under_the_rule() {
        let p = para(&[10.0], Some(Rule { mode: RuleMode::Exact, value: 8.0 }), 10.0, false);
        assert_eq!(place_paragraph(&p, Some(15.0), false, false).heights, vec![15.0]);
        assert_eq!(place_paragraph(&p, Some(5.0), false, false).heights, vec![8.0]);
    }

    #[test]
    fn hwp_spacing_goes_below_the_glyphs_so_the_face_natural_box_does_not_matter() {
        // 160% of a 10pt run: pitch 16. A face whose natural box is 14.5 must not make it taller.
        let p = para(&[14.5, 14.5, 14.5], at_least(16.0), 10.0, true);
        let placed = place_paragraph(&p, None, false, false);
        assert_eq!(placed.heights, vec![16.0, 16.0, 16.0]);
        assert_eq!(placed.trailing, 6.0, "the page may let that gap hang past its foot");
        // The same rule without the flag is a plain floor and follows the face.
        let plain = para(&[14.5, 14.5, 14.5], at_least(16.0), 10.0, false);
        assert_eq!(place_paragraph(&plain, None, false, false).heights, vec![16.0, 16.0, 16.0]);
        let tall = para(&[18.0], at_least(16.0), 10.0, false);
        assert_eq!(place_paragraph(&tall, None, false, false).heights, vec![18.0]);
    }

    #[test]
    fn a_declared_face_floors_its_lines_by_the_paragraphs_multiple_but_not_an_exact_rule() {
        // 맑은 고딕 at 9pt: 15.6 per line whatever the substitute's natural box (invariant 163).
        let mut p = para(&[10.5, 10.5], None, 9.0, false);
        p.face_floor = 15.6;
        assert_eq!(place_paragraph(&p, None, false, false).heights, vec![15.6, 15.6]);
        p.rule = Some(Rule { mode: RuleMode::Multiple, value: 1.5 });
        let h = place_paragraph(&p, None, false, false).heights;
        assert!((h[0] - 23.4).abs() < 1e-9, "{h:?}");
        p.rule = at_least(20.0);
        assert_eq!(place_paragraph(&p, None, false, false).heights, vec![20.0, 20.0]);
        p.rule = Some(Rule { mode: RuleMode::Exact, value: 12.0 });
        assert_eq!(place_paragraph(&p, None, false, false).heights, vec![12.0, 12.0]);
        // HWP's below-the-glyphs pitch is the document's own, not a face's.
        let mut hwp = para(&[10.5], at_least(14.0), 9.0, true);
        hwp.face_floor = 15.6;
        assert_eq!(place_paragraph(&hwp, None, false, true).heights, vec![9.0]);
        // A cell's text lines take none (macOS's cell content has no face floor) ...
        p.rule = None;
        assert_eq!(place_paragraph(&p, None, true, false).heights, vec![10.5, 10.5]);
        // ... and a blank paragraph takes it only in a cell.
        let mut blank = para(&[10.5], None, 9.0, false);
        blank.blank = true;
        blank.face_floor = 15.6;
        assert_eq!(place_paragraph(&blank, None, false, false).heights, vec![10.5]);
        assert_eq!(place_paragraph(&blank, None, true, false).heights, vec![15.6]);
    }

    #[test]
    fn a_floor_at_or_under_the_character_size_is_not_spacing() {
        let p = para(&[14.5], at_least(10.0), 10.0, true);
        let placed = place_paragraph(&p, None, false, false);
        assert_eq!(placed.heights, vec![14.5]);
        assert_eq!(placed.trailing, 0.0);
    }

    #[test]
    fn the_last_line_of_a_cell_paragraph_hands_its_spacing_back() {
        let p = para(&[14.5, 14.5], at_least(16.0), 10.0, true);
        let placed = place_paragraph(&p, None, true, true);
        assert_eq!(placed.heights, vec![16.0, 10.0]);
        assert_eq!(placed.trailing, 0.0);
    }

    #[test]
    fn an_empty_hwp_cell_paragraph_is_one_line_of_its_own_size() {
        let mut p = para(&[14.5], at_least(16.0), 9.0, true);
        p.blank = true;
        assert_eq!(place_paragraph(&p, None, true, false).heights, vec![9.0]);
        // Outside a cell it is an ordinary line under its rule.
        assert_eq!(place_paragraph(&p, None, false, false).heights, vec![16.0]);
        // A paragraph with no size the reader vouched for keeps the host's line.
        p.char_size = 0.0;
        assert_eq!(place_paragraph(&p, None, true, false).heights, vec![16.0]);
    }

    fn cell(row: usize, span: usize, items: Vec<CellItem>) -> CellFacts {
        CellFacts { row, row_span: span, v_padding: 4.0, declared_height: None, min_row_height: None, items }
    }
    fn text(paragraphs: Vec<ParagraphFacts>) -> CellItem {
        CellItem::Text { paragraphs }
    }
    fn table(rows: usize, drops: bool, cells: Vec<CellFacts>) -> TableFacts {
        TableFacts { row_count: rows, empty_line: 10.0, row_padding: 4.0, drops_trailing_gap: drops, cells }
    }

    #[test]
    fn a_row_stands_at_its_tallest_cell_plus_padding() {
        let t = table(1, false, vec![
            cell(0, 1, vec![text(vec![para(&[12.0], None, 10.0, false)])]),
            cell(0, 1, vec![text(vec![para(&[12.0, 12.0, 12.0], None, 10.0, false)])]),
        ]);
        assert_eq!(solve_table(&t, None).unwrap().row_heights, vec![40.0]);
    }

    #[test]
    fn paragraph_spacing_lies_inside_the_cell_and_tops_follow_it() {
        let mut a = para(&[10.0], None, 10.0, false);
        a.spacing_before = 2.0;
        a.spacing_after = 3.0;
        let mut b = para(&[10.0, 10.0], None, 10.0, false);
        b.spacing_before = 4.0;
        let t = table(1, false, vec![cell(0, 1, vec![text(vec![a, b])])]);
        let solved = solve_table(&t, None).unwrap();
        assert_eq!(solved.cells[0].height, 2.0 + 10.0 + 3.0 + 4.0 + 20.0);
        match &solved.cells[0].items[0] {
            ItemLayout::Text { paragraphs } => {
                assert_eq!(paragraphs[0].tops, vec![2.0]);
                assert_eq!(paragraphs[1].tops, vec![19.0, 29.0]);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_one_paragraph_hwp_cell_drops_its_last_gap_but_a_two_paragraph_one_only_when_the_table_breaks() {
        let hwp = |size| para(&[14.5], at_least(2.0 * size), size, true);
        let one = table(1, false, vec![cell(0, 1, vec![text(vec![hwp(10.0)])])]);
        assert_eq!(solve_table(&one, None).unwrap().cells[0].height, 10.0);
        let two = table(1, false, vec![cell(0, 1, vec![text(vec![hwp(10.0), hwp(10.0)])])]);
        assert_eq!(solve_table(&two, None).unwrap().cells[0].height, 40.0);
        let breaking = table(1, true, vec![cell(0, 1, vec![text(vec![hwp(10.0), hwp(10.0)])])]);
        assert_eq!(solve_table(&breaking, None).unwrap().cells[0].height, 30.0);
    }

    #[test]
    fn a_picture_beside_the_paragraph_means_the_paragraph_is_not_the_cells_only_one() {
        let hwp = para(&[14.5], at_least(20.0), 10.0, true);
        let t = table(1, false, vec![cell(0, 1, vec![text(vec![hwp]), CellItem::Fixed { height: 30.0 }])]);
        assert_eq!(solve_table(&t, None).unwrap().cells[0].height, 20.0 + 30.0);
    }

    #[test]
    fn an_empty_cell_stands_at_one_default_line_and_a_row_with_no_cell_does_too() {
        let t = table(2, false, vec![cell(0, 1, vec![])]);
        assert_eq!(solve_table(&t, None).unwrap().row_heights, vec![14.0, 14.0]);
    }

    #[test]
    fn a_decorative_band_stands_at_its_declared_height_and_a_cell_with_text_does_not() {
        let mut band = cell(0, 1, vec![]);
        band.declared_height = Some(3.0);
        let mut blank = cell(1, 1, vec![text(vec![ParagraphFacts { blank: true, lines: vec![12.0], char_size: 10.0, ..Default::default() }])]);
        blank.declared_height = Some(3.0);
        let mut worded = cell(2, 1, vec![text(vec![para(&[12.0], None, 10.0, false)])]);
        worded.declared_height = Some(3.0);
        let solved = solve_table(&table(3, false, vec![band, blank, worded]), None).unwrap();
        assert_eq!(solved.row_heights, vec![3.0, 3.0, 16.0]);
    }

    #[test]
    fn a_single_line_cell_is_floored_at_its_rows_declared_height_but_a_wrapped_one_is_not() {
        let mut one = cell(0, 1, vec![text(vec![para(&[12.0], None, 10.0, false)])]);
        one.min_row_height = Some(30.0);
        let mut two = cell(1, 1, vec![text(vec![para(&[12.0, 12.0], None, 10.0, false)])]);
        two.min_row_height = Some(30.0);
        let solved = solve_table(&table(2, false, vec![one, two]), None).unwrap();
        assert_eq!(solved.row_heights, vec![30.0, 28.0]);
    }

    #[test]
    fn a_merged_cells_shortfall_goes_to_the_last_row_it_covers() {
        let tall = cell(0, 2, vec![text(vec![para(&[20.0, 20.0, 20.0, 20.0], None, 10.0, false)])]);
        let a = cell(0, 1, vec![text(vec![para(&[10.0], None, 10.0, false)])]);
        let b = cell(1, 1, vec![text(vec![para(&[10.0], None, 10.0, false)])]);
        let solved = solve_table(&table(2, false, vec![tall, a, b]), None).unwrap();
        // rows start at 14 + 14; the merged cell needs 84, so 56 more, all on the second row (the
        // TextKit rule measured on the 편람's table 3120).
        assert_eq!(solved.row_heights, vec![14.0, 70.0]);
    }

    #[test]
    fn a_row_only_a_merged_cell_begins_in_is_as_tall_as_nothing() {
        let tall = cell(0, 2, vec![text(vec![para(&[20.0], None, 10.0, false)])]);
        let b = cell(1, 1, vec![text(vec![para(&[10.0], None, 10.0, false)])]);
        let solved = solve_table(&table(2, false, vec![tall, b]), None).unwrap();
        // The merged cell needs 24; row 1 stands at 14 and takes the 10 the pair is short.
        assert_eq!(solved.row_heights, vec![0.0, 24.0]);
    }

    #[test]
    fn a_span_past_the_last_row_is_clamped_not_an_error() {
        let c = cell(1, 5, vec![text(vec![para(&[40.0], None, 10.0, false)])]);
        let solved = solve_table(&table(2, false, vec![cell(0, 1, vec![]), c]), None).unwrap();
        assert_eq!(solved.row_heights, vec![14.0, 44.0]);
    }

    #[test]
    fn refuses_what_it_cannot_answer() {
        let mut bad = LineModelInput { version: 2, grid_pitch: None, paragraphs: vec![], tables: vec![] };
        assert_eq!(solve(&bad), Err(LineModelError::Version(2)));
        bad.version = 1;
        bad.paragraphs.push(para(&[f64::NAN], None, 10.0, false));
        assert!(solve(&bad).is_err());
        let off = table(1, false, vec![cell(3, 1, vec![])]);
        assert_eq!(solve_table(&off, None), Err(LineModelError::RowOutOfRange { row: 3, rows: 1 }));
    }

    #[test]
    fn the_wire_form_round_trips_through_serde() {
        let json = r#"{"version":1,"gridPitch":0,"paragraphs":[{"lines":[14.5],"rule":{"mode":"atLeast","value":16},"charSize":10,"lineSpacingBelow":true}],
            "tables":[{"rowCount":1,"emptyLine":10,"cells":[{"row":0,"items":[{"kind":"text","paragraphs":[{"lines":[14.5],"rule":{"mode":"atLeast","value":16},"charSize":10,"lineSpacingBelow":true}]},{"kind":"fixed","height":5}]}]}]}"#;
        let input: LineModelInput = serde_json::from_str(json).unwrap();
        let out = solve(&input).unwrap();
        assert_eq!(out.paragraphs[0].heights, vec![16.0]);
        assert_eq!(out.paragraphs[0].trailing, 6.0);
        assert_eq!(out.tables[0].cells[0].height, 16.0 + 5.0);
        let wire = serde_json::to_string(&out).unwrap();
        assert!(wire.contains("\"rowHeights\"") && wire.contains("\"modelVersion\":1"), "{wire}");
    }
}
