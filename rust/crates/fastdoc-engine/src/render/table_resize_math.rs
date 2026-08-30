//! swift: Render/TableBlockBuilder.swift:958-1002 (`resizeTables`'s per-cell target-width step)
//!
//! S5B2a/S5B2b: host-to-Rust, the opposite direction from S5's text-measurement port. The live
//! `NSTextStorage` walk and the write-back stay Swift's — only the arithmetic answering "how wide
//! should this cell be" crosses, via `fastdoc_table_resize_cell_widths`
//! (`Sources/FastDocReader/Render/Office/RustEngineTableResize.swift`), called once per table from
//! `TableBlockBuilder.resizeTables`'s `#if FMD_RUST_ENGINE` branch. There never was a
//! `table_block_builder.rs::resize_tables` to wire this into — that stub required a live
//! `NSTextStorage`/`NSTextTableBlock` object model this crate does not have, and the traversal it
//! would have performed stays in Swift; S5B2b deleted the stub rather than implement it.

use crate::render::table_block_builder::GridTextTable;
use swiftshim::CGFloat;

/// One cell's own geometry — everything `resizeTables` reads off an `NSTextTableBlock` besides
/// the shared grid (`Render/TableBlockBuilder.swift:977-983`). `starting_column`/`column_span` are
/// `usize`, not `i32`: a table's own column indices are never negative, and clamping against
/// `column_count` (below) needs an unsigned comparison to match Swift's `min(_, ncol)` exactly —
/// a signed comparison would let a corrupt negative span silently become a huge unsigned one.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TableResizeCell {
    pub starting_column: usize,
    pub column_span: usize,
    pub pad_left: CGFloat,
    pub pad_right: CGFloat,
    pub border_left: CGFloat,
    pub border_right: CGFloat,
}

/// The whole payload one call answers: a table's shared grid inputs, plus every cell whose
/// target width is wanted. `column_count` is NOT a separate field — `edges(forWidth:)` and the
/// per-cell clamp both derive it from `column_proportions.len()`, exactly as
/// `Swift: TableBlockBuilder.swift:977` reads `table.numberOfColumns`, which is set from the same
/// count at build time (`build`'s own `GridTextTable.numberOfColumns = ncol`). A separate field
/// would let the two drift; there is deliberately nowhere for that to happen here.
#[derive(Debug, Clone, PartialEq)]
pub struct TableResizeInput {
    pub column_proportions: Vec<CGFloat>,
    pub available_width: CGFloat,
    pub outer_margin_left: CGFloat,
    pub outer_margin_right: CGFloat,
    /// `None` means "no authored cap" — `Swift: TableBlockBuilder.swift:24-33`'s `maxWidth: CGFloat?`.
    pub max_width: Option<CGFloat>,
    pub cells: Vec<TableResizeCell>,
}

/// One target width per `cells` entry, same order in, same order out.
///
/// This is `Swift: TableBlockBuilder.swift:977-988`'s formula, unchanged: build the shared grid
/// once via `GridTextTable::edges` (already ported, `table_block_builder.rs:181`), then for each
/// cell read both horizontal edges of its own column span and subtract its own padding and border
/// on both sides in full — never halved, `collapsesBorders` is off (see `edges`'s own doc comment
/// for why). `max(1.0, ...)` matches Swift's floor: a cell whose span or padding leaves no room
/// still gets a positive width rather than a negative or zero one `NSTextTableBlock` would reject.
pub fn cell_target_widths(input: &TableResizeInput) -> Vec<CGFloat> {
    let table = GridTextTable {
        column_proportions: input.column_proportions.clone(),
        outer_margin_left: input.outer_margin_left,
        outer_margin_right: input.outer_margin_right,
        max_width: input.max_width,
        ..GridTextTable::default()
    };
    let ncol = input.column_proportions.len();
    let edges = table.edges(input.available_width);
    input
        .cells
        .iter()
        .map(|cell| {
            let c0 = cell.starting_column.min(ncol);
            let c1 = (cell.starting_column + cell.column_span).min(ncol);
            let width = edges[c1] - edges[c0]
                - cell.pad_left
                - cell.pad_right
                - cell.border_left
                - cell.border_right;
            width.max(1.0)
        })
        .collect()
}

/// One call answers EVERY table in a document. On a 323-table, 6,077-cell document the host's
/// width-unchanged reflow cost 4.5ms of its own and 9.5ms through a per-table crossing; the gap
/// decomposed into 0.35ms of boundary, 1.6ms of payload arrays and 2.4ms of collection, so the
/// crossing count was never the price — materialising the payload was (`s5b2b-latency.md`).
/// Batching it removes the per-table share of that, and the arithmetic (`cell_target_widths`) is
/// unchanged and reused per table, so behaviour cannot drift from the single-table export.
pub fn cell_target_widths_batch(inputs: &[TableResizeInput]) -> Vec<CGFloat> {
    inputs.iter().flat_map(cell_target_widths).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cell(col: usize, span: usize, pad: CGFloat, border: CGFloat) -> TableResizeCell {
        TableResizeCell {
            starting_column: col,
            column_span: span,
            pad_left: pad,
            pad_right: pad,
            border_left: border,
            border_right: border,
        }
    }

    /// Every other fixture in this module declares EQUAL columns, and equal columns cannot tell a
    /// grid that reads its proportions apart from one that ignores them and divides evenly. Flattening
    /// `column_proportions` to uniform passed all six of them — this is the test that fails when it
    /// happens, and unequal columns are what documents actually declare.
    #[test]
    fn unequal_columns_keep_the_proportions_the_document_declared() {
        let input = TableResizeInput {
            column_proportions: vec![0.5, 0.25, 0.25],
            available_width: 400.0,
            outer_margin_left: 0.0,
            outer_margin_right: 0.0,
            max_width: None,
            cells: vec![cell(0, 1, 0.0, 0.0), cell(1, 1, 0.0, 0.0), cell(2, 1, 0.0, 0.0)],
        };
        let widths = cell_target_widths(&input);
        // Edges land at [0, 200, 300, 400]: the first column is twice either of the others. An
        // implementation that divided evenly would answer [133.33, 133.33, 133.33].
        assert_eq!(widths, vec![200.0, 100.0, 100.0]);
    }

    #[test]
    fn three_equal_columns_split_the_available_width() {
        let input = TableResizeInput {
            column_proportions: vec![1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0],
            available_width: 300.0,
            outer_margin_left: 0.0,
            outer_margin_right: 0.0,
            max_width: None,
            cells: vec![cell(0, 1, 4.0, 1.0), cell(1, 1, 4.0, 1.0), cell(2, 1, 4.0, 1.0)],
        };
        let widths = cell_target_widths(&input);
        // edges land at [0, 100, 200, 300] (300 * 1/3 rounds exactly); each cell's raw span is
        // 100pt, minus 4+4 padding and 1+1 border = 90.
        assert_eq!(widths, vec![90.0, 90.0, 90.0]);
    }

    #[test]
    fn a_merged_cell_spans_more_than_one_column() {
        let input = TableResizeInput {
            column_proportions: vec![0.25, 0.25, 0.25, 0.25],
            available_width: 400.0,
            outer_margin_left: 0.0,
            outer_margin_right: 0.0,
            max_width: None,
            cells: vec![
                // A 2-column merge starting at column 0.
                cell(0, 2, 2.0, 0.0),
                cell(2, 1, 2.0, 0.0),
                cell(3, 1, 2.0, 0.0),
            ],
        };
        let widths = cell_target_widths(&input);
        // edges = [0, 100, 200, 300, 400]. The merged cell spans edges[0..2] = 200, minus 2+2 pad.
        assert_eq!(widths[0], 196.0);
        assert_eq!(widths[1], 96.0);
        assert_eq!(widths[2], 96.0);
    }

    #[test]
    fn proportions_that_do_not_sum_to_one_still_produce_a_positive_answer() {
        // Not every caller's proportions are guaranteed to sum to 1 (a corrupt source table, or
        // one column's own declared share dropped during parsing) — `edges` never assumes it: the
        // last edge is clamped to `usable`'s own floor regardless of what `cum` reached.
        let input = TableResizeInput {
            column_proportions: vec![0.5, 0.6], // sums to 1.1
            available_width: 200.0,
            outer_margin_left: 0.0,
            outer_margin_right: 0.0,
            max_width: None,
            cells: vec![cell(0, 1, 0.0, 0.0), cell(1, 1, 0.0, 0.0)],
        };
        let widths = cell_target_widths(&input);
        assert!(widths[0] > 0.0 && widths[1] > 0.0, "{widths:?}");
        // The second edge is clamped to the usable width's floor, never rounded past it — the
        // same guard `edges`'s own doc comment names for the "last edge" case.
        assert!(widths[0] + widths[1] <= 200.0 + 0.001, "{widths:?}");
    }

    #[test]
    fn an_authored_max_width_caps_the_grid_before_the_cells_split_it() {
        let unclamped = TableResizeInput {
            column_proportions: vec![0.5, 0.5],
            available_width: 500.0,
            outer_margin_left: 0.0,
            outer_margin_right: 0.0,
            max_width: None,
            cells: vec![cell(0, 1, 0.0, 0.0), cell(1, 1, 0.0, 0.0)],
        };
        let clamped = TableResizeInput {
            max_width: Some(200.0),
            ..unclamped.clone()
        };
        let unclamped_widths = cell_target_widths(&unclamped);
        let clamped_widths = cell_target_widths(&clamped);
        assert_eq!(unclamped_widths, vec![250.0, 250.0]);
        assert_eq!(clamped_widths, vec![100.0, 100.0]);
    }

    #[test]
    fn an_outer_margin_narrows_the_grid_and_shifts_it() {
        let input = TableResizeInput {
            column_proportions: vec![1.0],
            available_width: 300.0,
            outer_margin_left: 20.0,
            outer_margin_right: 20.0,
            max_width: None,
            cells: vec![cell(0, 1, 0.0, 0.0)],
        };
        let widths = cell_target_widths(&input);
        // usable = 300 - 20 - 20 = 260; the single cell spans the whole narrowed grid.
        assert_eq!(widths, vec![260.0]);
    }

    #[test]
    fn batch_concatenates_each_tables_widths_in_table_then_cell_order() {
        let a = TableResizeInput {
            column_proportions: vec![0.5, 0.5],
            available_width: 200.0,
            outer_margin_left: 0.0,
            outer_margin_right: 0.0,
            max_width: None,
            cells: vec![cell(0, 1, 0.0, 0.0), cell(1, 1, 0.0, 0.0)],
        };
        let b = TableResizeInput {
            column_proportions: vec![1.0],
            available_width: 300.0,
            outer_margin_left: 10.0,
            outer_margin_right: 10.0,
            max_width: None,
            cells: vec![cell(0, 1, 0.0, 0.0)],
        };
        let batched = cell_target_widths_batch(&[a.clone(), b.clone()]);
        let mut expected = cell_target_widths(&a);
        expected.extend(cell_target_widths(&b));
        assert_eq!(batched, expected);
    }

    #[test]
    fn a_span_leaving_no_room_still_returns_a_positive_width() {
        let input = TableResizeInput {
            column_proportions: vec![0.1, 0.9],
            available_width: 100.0,
            outer_margin_left: 0.0,
            outer_margin_right: 0.0,
            max_width: None,
            cells: vec![cell(0, 1, 50.0, 50.0)], // padding alone exceeds the column's own width
        };
        let widths = cell_target_widths(&input);
        assert_eq!(widths, vec![1.0]);
    }
}
