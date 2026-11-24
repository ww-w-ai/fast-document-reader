//! How tall AppKit's text table makes each row (S6c/S6d of `docs/plans/pagination-to-engine.md`).
//!
//! The rule below is the one `NSTextTable` applies, read off cell boxes measured on the 편람
//! (2025_행정업무운영편람_최종.hwp: table 3120 with 25 grid columns and cells merged across up to eight
//! rows, and the 15-row table nested in table 3173, whose merged cells make its row tops run upward
//! from one column group to the next):
//!
//! 1. A cell is as tall as its content plus padding and borders (`need`); a cell never grows because
//!    the rows it covers are taller.
//! 2. A row's top is the bottom of the cells that END in the row above it. A row with no cell ending
//!    in the row above stands where that row stood (it is as tall as nothing).
//! 3. Every cell that ends in the same row has the same bottom: the lowest any of them reaches
//!    (its top plus its `need`). That is why a one-line cell beside a taller neighbour is stretched to
//!    the neighbour's bottom, and why a merged cell's shortfall lands on the LAST row it covers.
//!
//! Row tops of such a table are not monotone across column groups (a cell in the right-hand block can
//! start above a cell in the left-hand block that sits in a later row), so heights are taken between
//! tops made monotone from below (the least top of this row and every row after it): rows never run
//! upward, and the table's total is the lowest bottom any cell reaches.
//!
//! Known exception, not modelled: `s7-page-restart.hwp`'s table 11 has a top-aligned two-row cell
//! whose line needs 25.5 against the 21.0 its rows make, and TextKit leaves the rows at 21.0 and lets
//! the line run past its box. A host that has TextKit can report the rows it observed
//! (`PlanBlock.rows_observed`) and never reaches this rule.

/// One cell's claim on the rows it covers.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RowNeed {
    pub row: usize,
    /// How many rows the cell covers (1 for an ordinary cell).
    pub span: usize,
    /// The cell's content plus its padding and borders.
    pub need: f64,
}

/// The height of each of `rows` rows. A row no cell covers has no cell to size it; it stands at
/// `fallback[row]`.
pub fn row_heights(rows: usize, needs: &[RowNeed], fallback: &[f64]) -> Vec<f64> {
    if rows == 0 {
        return Vec::new();
    }
    let needs: Vec<(usize, usize, f64)> = needs
        .iter()
        .filter(|n| n.row < rows)
        .map(|n| (n.row, (n.row + n.span.max(1)).min(rows) - 1, n.need))
        .collect();
    let mut covered = vec![false; rows];
    for &(first, last, _) in &needs {
        for slot in &mut covered[first..=last] {
            *slot = true;
        }
    }
    // `top[r]` is where row r begins; `top[rows]` is where the table ends.
    let mut top = vec![0.0_f64; rows + 1];
    let mut lowest = 0.0_f64;
    for r in 0..rows {
        let ending = needs.iter().filter(|&&(_, last, _)| last == r);
        let bottom = ending.map(|&(first, _, need)| top[first] + need).fold(None, |m: Option<f64>, b| Some(m.map_or(b, |m| m.max(b))));
        top[r + 1] = match bottom {
            Some(b) => b,
            None if covered[r] => top[r],
            None => top[r] + fallback.get(r).copied().unwrap_or(0.0),
        };
        lowest = lowest.max(top[r + 1]);
    }
    top[rows] = lowest;
    for r in (0..rows).rev() {
        top[r] = top[r].min(top[r + 1]);
    }
    (0..rows).map(|r| top[r + 1] - top[r]).collect()
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
    fn cells_that_end_in_the_same_row_share_the_lowest_bottom_and_row_tops_may_run_upward() {
        // The 15-row table nested in the 편람's table 3173 (rows 0-9 of it, cell needs read off the
        // boxes AppKit drew): the right-hand block's rows begin above rows the left-hand block has
        // not reached, and every cell ending in row 9 stops at the lowest of them.
        let cells = [
            (0, 1, 22.0), (0, 1, 23.5), (0, 1, 13.0), (0, 10, 10.0),
            (1, 1, 41.34), (1, 1, 22.17), (1, 3, 28.0), (1, 3, 28.0),
            (2, 1, 4.0),
            (3, 2, 21.0), (3, 2, 10.5),
            (4, 6, 22.5), (4, 2, 10.5), (4, 2, 10.5),
            (5, 2, 12.0), (6, 2, 18.55), (7, 2, 12.0), (8, 2, 18.56), (9, 1, 12.0),
        ];
        let needs: Vec<RowNeed> = cells.iter().map(|&(r, s, n)| need(r, s, n)).collect();
        let h = row_heights(10, &needs, &[0.0; 10]);
        let expected = [23.5, 28.0, 0.0, 0.0, 10.5, 0.0, 18.55, 0.0, 33.29, 12.0];
        for (row, (got, want)) in h.iter().zip(expected).enumerate() {
            assert!((got - want).abs() < 1e-6, "row {row}: {got} against {want} in {h:?}");
        }
        assert!((h.iter().sum::<f64>() - 125.84).abs() < 1e-6, "the table ends at the lowest bottom: {h:?}");
    }

    #[test]
    fn a_cell_beside_a_taller_neighbour_that_ends_in_the_same_row_is_stretched_to_it() {
        let h = row_heights(1, &[need(0, 1, 9.0), need(0, 1, 30.0)], &[0.0]);
        assert_eq!(h, vec![30.0]);
        assert_eq!(row_heights(1, &[need(0, 1, 30.0), need(0, 1, 9.0)], &[0.0]), vec![30.0], "whatever order they come in");
        // Two rows: the short cell in row 1 ends where the tall one does, so the row stands at the tall one.
        let h = row_heights(2, &[need(0, 1, 10.0), need(1, 1, 5.0), need(1, 1, 20.0)], &[0.0; 2]);
        assert_eq!(h, vec![10.0, 20.0]);
    }

    #[test]
    fn spans_apply_in_the_order_given_and_each_sees_the_last_ones_shortfall() {
        let h = row_heights(3, &[need(0, 3, 30.0), need(1, 2, 20.0), need(0, 1, 5.0), need(1, 1, 5.0), need(2, 1, 5.0)], &[0.0; 3]);
        // The three-row cell sees 15 and adds 15 to row 2; the two-row cell then sees 5 + 20 and is met.
        assert_eq!(h, vec![5.0, 5.0, 20.0]);
    }
}
