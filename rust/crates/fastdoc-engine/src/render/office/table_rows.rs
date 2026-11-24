//! How tall TextKit makes each row of a table (S6c of `docs/plans/pagination-to-engine.md`).
//!
//! Measured on the 편람's table 3120 (25 grid columns, 12 rows, cells merged across up to eight rows,
//! 2025_행정업무운영편람_최종.hwp): AppKit sizes a row from the cells that BEGIN in it and span one
//! row — the tallest of their content plus padding — and a row no such cell begins in is as tall as
//! nothing. A cell that spans several rows then asks for its own content plus padding: when the rows
//! it covers are already that tall it changes nothing, and when they are shorter the WHOLE shortfall
//! goes to the LAST row it covers. Rows 10-11 of that table: single-row cells need 9.0 and 8.8, a
//! two-row cell needs 25.4, so the rows stand at 9.0 and 16.4 (not 12.7 and 12.7); rows 4-5: a
//! two-row cell begins in row 4 where no single-row cell does, so row 4 is 0.0 and row 5 takes the
//! 9.8. Every cell box of that table matches this to the hundredth of a point.
//!
//! Known exception, not modelled: `s7-page-restart.hwp`'s table 11 has a top-aligned two-row cell whose
//! line needs 25.5 against the 21.0 its rows make, and TextKit leaves the rows at 21.0 and lets the
//! line run past its box. Limiting growth to cells that are not top-aligned fits that table and
//! table 3120 but costs the 편람 more than it gains (measured: 1,236 of its 1,426 column lines then
//! differ, against 1,096), so the rule is stated without it. A host that has TextKit reports the
//! rows it observed (`PlanBlock.rows_observed`) and never reaches this rule.
//!
//! Spans are applied in the order the cells were given (document order); a shortfall one span left
//! on a row counts as height for the next.

/// One cell's claim on the rows it begins in.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RowNeed {
    pub row: usize,
    /// How many rows the cell covers (1 for an ordinary cell).
    pub span: usize,
    /// The cell's content plus its padding and borders.
    pub need: f64,
}

/// The height of each of `rows` rows. A row no cell begins in and no span covers has no cell to
/// size it; it stands at `fallback[row]`.
pub fn row_heights(rows: usize, needs: &[RowNeed], fallback: &[f64]) -> Vec<f64> {
    let mut heights = vec![0.0_f64; rows];
    let mut claimed = vec![false; rows];
    for n in needs.iter().filter(|n| n.row < rows) {
        claimed[n.row] = true;
        let span = n.span.max(1).min(rows - n.row);
        for slot in &mut claimed[n.row..n.row + span] {
            *slot = true;
        }
        if span == 1 && n.need > heights[n.row] {
            heights[n.row] = n.need;
        }
    }
    for (row, h) in heights.iter_mut().enumerate() {
        if !claimed[row] {
            *h = fallback.get(row).copied().unwrap_or(0.0);
        }
    }
    for n in needs.iter().filter(|n| n.row < rows) {
        let span = n.span.max(1).min(rows - n.row);
        if n.span <= 1 || span <= 1 {
            continue;
        }
        let covered: f64 = heights[n.row..n.row + span].iter().sum();
        if n.need > covered {
            heights[n.row + span - 1] += n.need - covered;
        }
    }
    heights
}

#[cfg(test)]
mod tests {
    use super::*;

    fn need(row: usize, span: usize, need: f64) -> RowNeed {
        RowNeed { row, span, need }
    }

    #[test]
    fn a_row_is_its_tallest_single_row_cell() {
        assert_eq!(row_heights(1, &[need(0, 1, 9.0), need(0, 1, 12.0)], &[0.0]), vec![12.0]);
    }

    #[test]
    fn a_spans_shortfall_goes_to_the_last_row_it_covers() {
        // Table 3120, rows 10-11: single-row cells 9.0 and 8.82, a two-row cell 25.4.
        let h = row_heights(2, &[need(0, 2, 25.4), need(0, 1, 9.0), need(1, 1, 8.82)], &[0.0; 2]);
        assert!((h[0] - 9.0).abs() < 1e-9 && (h[1] - 16.4).abs() < 1e-9, "{h:?}");
    }

    #[test]
    fn a_row_only_a_span_begins_in_is_as_tall_as_nothing() {
        // Table 3120, rows 4-5: a two-row cell (9.82) begins in row 4; a single-row cell (8.82) in row 5.
        let h = row_heights(2, &[need(0, 2, 9.82), need(1, 1, 8.82)], &[5.0; 2]);
        assert!(h[0].abs() < 1e-9 && (h[1] - 9.82).abs() < 1e-9, "{h:?}");
    }

    #[test]
    fn a_span_the_rows_already_cover_changes_nothing() {
        assert_eq!(row_heights(2, &[need(0, 2, 10.0), need(0, 1, 8.0), need(1, 1, 8.0)], &[0.0; 2]), vec![8.0, 8.0]);
    }

    #[test]
    fn a_row_nothing_begins_or_spans_stands_at_its_fallback() {
        assert_eq!(row_heights(3, &[need(0, 1, 4.0), need(2, 1, 6.0)], &[0.0, 7.5, 0.0]), vec![4.0, 7.5, 6.0]);
        // A row a span covers is sized by the span, not by the fallback.
        assert_eq!(row_heights(3, &[need(0, 2, 20.0), need(2, 1, 6.0)], &[0.0, 7.5, 0.0]), vec![0.0, 20.0, 6.0]);
    }

    #[test]
    fn a_span_past_the_last_row_is_clamped() {
        assert_eq!(row_heights(2, &[need(0, 1, 14.0), need(1, 5, 44.0)], &[0.0; 2]), vec![14.0, 44.0]);
    }

    #[test]
    fn spans_apply_in_the_order_given_and_each_sees_the_last_ones_shortfall() {
        let h = row_heights(3, &[need(0, 3, 30.0), need(1, 2, 20.0), need(0, 1, 5.0), need(1, 1, 5.0), need(2, 1, 5.0)], &[0.0; 3]);
        // The three-row cell sees 15 and adds 15 to row 2; the two-row cell then sees 5 + 20 and is met.
        assert_eq!(h, vec![5.0, 5.0, 20.0]);
    }
}
