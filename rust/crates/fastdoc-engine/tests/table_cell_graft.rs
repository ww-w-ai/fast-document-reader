//! S5B1-02/03: `TableBlockBuilder::build`'s cell-block graft (`table_block_builder.rs:1111`'s
//! former `todo!()`) runs entirely in Rust — no host round trip — and invariant 51 (a cell's
//! terminating `"\n"` shares ONE attribute run with its content, not two) survives grafting the
//! table block onto both.
//!
//! The table here is SYNTHETIC and built inside this crate on purpose: `FMD_SPAN_PROBE` and its
//! corpus-probe siblings measure REAL documents from the Swift side of the app and are a
//! different sprint's instrument (see `../../CLAUDE.md`'s test table) — this file is the one that
//! is allowed to assert exact numbers because it built the input itself.

use fastdoc_engine::render::table_block_builder::{CellContent, TableBlockBuilder};
use fastdoc_engine::render::render_theme::RenderTheme;
use swiftshim::{
    AttrValue, NSAttributedString, NSAttributedStringKey, NSMutableAttributedString,
    NSParagraphStyle, NSRange, NSTextAlignment,
};

const FONT_SIZE: f64 = 12.0;

/// One paragraph's worth of content, carrying only a `.paragraphStyle` attribute (as every real
/// office paragraph does — `OfficeTextBuilder` never emits one without it) so the graft's
/// enumerate pass actually has a run to find.
fn paragraph_content(text: &str, alignment: NSTextAlignment) -> NSAttributedString {
    let mut s = NSMutableAttributedString::fromString(text);
    let len = s.length();
    let mut style = NSParagraphStyle::default();
    style.alignment = alignment;
    s.add_paragraph_style(style, NSRange::new(0, len));
    s.into_immutable()
}

/// Every `NSParagraphStyle` carrying `.paragraphStyle` across `range`, deduplicated by value —
/// the measurement invariant 51 is judged by. Two DIFFERENT attribute-run entries that happen to
/// hold an EQUAL paragraph style count as the same run for this purpose, exactly as AppKit's own
/// adjacent-equal-run coalescing would see them; two entries whose style DIFFERS (the terminator
/// grafted onto a fresh default instead of the content's own style, say) count as two.
fn distinct_paragraph_styles(attr: &NSAttributedString, range: NSRange) -> Vec<NSParagraphStyle> {
    let mut distinct: Vec<NSParagraphStyle> = Vec::new();
    attr.enumerateAttribute(&NSAttributedStringKey::ParagraphStyle, range, |value, _range, _stop| {
        if let Some(AttrValue::ParagraphStyle(style)) = value {
            if !distinct.iter().any(|existing| existing == style) {
                distinct.push(style.clone());
            }
        }
    });
    distinct
}

fn build_two_cell_row() -> (NSAttributedString, NSRange, NSRange) {
    let mut left = CellContent::default();
    left.content = paragraph_content("left", NSTextAlignment::Left);
    let mut right = CellContent::default();
    right.content = paragraph_content("right", NSTextAlignment::Center);

    let rows = vec![vec![left, right]];
    let column_widths = vec![50.0_f64, 50.0_f64];
    let theme = RenderTheme::current(FONT_SIZE);

    let result = TableBlockBuilder::build(
        &rows,
        0,
        &theme,
        &column_widths,
        None,
        None,
        None,
        None,
        None,
        None,
        None,
        false,
        None,
        200.0,
    );

    // "left" (4) + terminator (1) = 5, then "right" (5) + terminator (1) = 6, starting at 5.
    let left_range = NSRange::new(0, 5);
    let right_range = NSRange::new(5, 6);
    assert_eq!(
        result.string(),
        "left\nright\n\n",
        "the two cells plus the table's own trailing closer newline"
    );
    (result, left_range, right_range)
}

/// S5B1-02: the graft actually ran (the `todo!()` is gone and produced real output) — both
/// cells' text survives, and each carries at least one grafted `.paragraphStyle`.
#[test]
fn the_graft_produces_the_cells_content_with_a_paragraph_style() {
    let (result, left_range, right_range) = build_two_cell_row();
    assert!(!distinct_paragraph_styles(&result, left_range).is_empty());
    assert!(!distinct_paragraph_styles(&result, right_range).is_empty());
}

/// S5B1-02: the block landed on the paragraph it was placed for, not a neighbour's — the left
/// cell's grafted block starts at column 0, the right cell's at column 1, and neither carries
/// the other's.
#[test]
fn each_cells_block_names_its_own_column_not_its_neighbours() {
    let (result, left_range, right_range) = build_two_cell_row();

    let left_styles = distinct_paragraph_styles(&result, left_range);
    let right_styles = distinct_paragraph_styles(&result, right_range);

    assert_eq!(left_styles.len(), 1, "left cell content+terminator must share one style");
    assert_eq!(right_styles.len(), 1, "right cell content+terminator must share one style");

    let left_block = left_styles[0].textBlocks.last().expect("left cell was grafted a block");
    let right_block = right_styles[0].textBlocks.last().expect("right cell was grafted a block");

    assert_eq!(left_block.startingColumn, 0);
    assert_eq!(right_block.startingColumn, 1);
    assert_ne!(
        left_block.startingColumn, right_block.startingColumn,
        "each cell's block must name its own column"
    );
}

/// S5B1-03 — invariant 51, measured as a number: a cell's content and its terminating `"\n"`
/// still resolve to exactly ONE distinct paragraph style each (not two), after the graft.
/// `terminator_attributes` gave the "\n" the SAME style object the content's last character
/// carried before grafting; if the graft skipped the terminator, or grafted a FRESH default onto
/// it instead of the content's own (mutated) style, this count moves from 1 to 2.
#[test]
fn the_terminator_does_not_gain_its_own_attribute_run() {
    let (result, left_range, right_range) = build_two_cell_row();

    let left_styles = distinct_paragraph_styles(&result, left_range);
    let right_styles = distinct_paragraph_styles(&result, right_range);

    assert_eq!(
        left_styles.len(),
        1,
        "invariant 51: left cell's content+terminator must be ONE attribute run, found {}",
        left_styles.len()
    );
    assert_eq!(
        right_styles.len(),
        1,
        "invariant 51: right cell's content+terminator must be ONE attribute run, found {}",
        right_styles.len()
    );

    // And the surviving style really is the grafted one (one block, not zero, not stacked twice
    // by a graft that ran over the same run more than once).
    assert_eq!(left_styles[0].textBlocks.len(), 1);
    assert_eq!(right_styles[0].textBlocks.len(), 1);
}

/// Nested cell (a cell inside a cell) is what `textBlocks` being a `Vec` is FOR (S5B1-01) — this
/// exercises that through the graft itself rather than only through the shim's own round-trip
/// test. The INNER table is built first (`OfficeTextBuilder.cellContent` builds a nested grid
/// inside the outer cell's content), so a paragraph style already carrying one block is carrying
/// the inner cell's, and the outer cell's block is PREPENDED to it — TextKit reads `textBlocks`
/// outermost first (invariant 168). Never replaced, never appended.
#[test]
fn a_paragraph_already_inside_one_block_keeps_it_when_grafted_again() {
    let mut left = CellContent::default();
    let mut content = NSMutableAttributedString::fromString("inner");
    let len = content.length();
    let mut style = NSParagraphStyle::default();
    let inner_table = swiftshim::NSTextTable::new();
    let inner_block = swiftshim::NSTextTableBlock::new(inner_table, 0, 1, 0, 1);
    style.textBlocks.push(inner_block.clone());
    content.add_paragraph_style(style, NSRange::new(0, len));
    left.content = content.into_immutable();

    let rows = vec![vec![left]];
    let column_widths = vec![100.0_f64];
    let theme = RenderTheme::current(FONT_SIZE);
    let result = TableBlockBuilder::build(
        &rows, 0, &theme, &column_widths, None, None, None, None, None, None, None, false, None,
        100.0,
    );

    let whole = NSRange::new(0, result.length());
    let styles = distinct_paragraph_styles(&result, whole);
    assert_eq!(styles.len(), 1, "content+terminator still ONE run after a second graft");
    assert_eq!(
        styles[0].textBlocks.len(),
        2,
        "the inner block survives and the grafting cell's own block is put before it"
    );
    assert_eq!(styles[0].textBlocks[1], inner_block, "inner block unchanged, now second");
    assert_ne!(styles[0].textBlocks[0], inner_block, "the outer block is first");
}
