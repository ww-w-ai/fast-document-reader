//! swift: Render/Office/PagePagination.swift

use swiftshim::CGFloat;

/// Where each SHEET of a paged document sits in the text view's own coordinates — the one piece of
/// arithmetic printing needs that the reader did not already have, kept pure and view-free so it is
/// judged by numbers rather than by looking at a printout.
///
/// The page plan lays a paged document out as a stack of pages: page `k`'s text begins exactly
/// `pitch` below page `k-1`'s (`pitch = pageContentHeight + band`, invariant 207). Printing therefore does NOT need a second
/// pagination engine — it needs to say where the PAPER around each of those text regions is, which is
/// one subtraction: the sheet starts one top margin above the text.
///
/// The load-bearing observation, measured on the reference report (`bus-headings.docx`): `pitch` IS
/// the paper. Its body is 671.75pt tall with margins of 99.25 and 70.90, and `band` is exactly those
/// two margins (invariant 57e), so `pitch == 841.90 == A4`. Nothing here has to reconcile two
/// different page grids, because there is only one.
// swift: PagePagination
pub struct PagePagination;

impl PagePagination {
    /// The repeat distance between one page's text and the next's — and, for a well-formed document,
    /// the paper's own height. Taken from what LAYOUT actually did rather than from the declared
    /// paper: if this reader had to widen the band because its own header/footer rendering is taller
    /// than the margins the document allowed (`PageBandGeometry.measure`'s `max`), the printed sheet
    /// grows with it. A sheet printed at the DECLARED height while the text repeats at a larger pitch
    /// would drift by the difference on every page and start slicing lines a few pages in.
    // swift: PagePagination.pitch
    pub fn pitch(page_content_height: CGFloat, band: CGFloat) -> CGFloat {
        page_content_height + band
    }

    /// One ROW of a table, as a completed layout shows it — what a page BREAK inside a table is
    /// allowed to move.
    ///
    /// `canBreakAbove` is the whole safety question and it is not about this row's own content: a
    /// break above row `R` is safe only when NO cell spans across that boundary, i.e. no block with
    /// `startingRow < R < startingRow + rowSpan`. Breaking where one does leaves the merged cell
    /// stretched across the gap between two pages — with the reader's own running header painted
    /// inside it, and the row's two halves a page apart. That was built, rendered and looked at before
    /// this rule existed; see `PageBandLayoutDelegate.pushWholeTable`.
    ///
    /// A row whose every column is covered by a merge from above has no text of its own, so it never
    /// becomes a `LaidOutRow` at all — which is the same answer, reached earlier.
    pub fn laid_out_row(first_char: i64, top: CGFloat, bottom: CGFloat, first_line_top: CGFloat, can_break_above: bool) -> LaidOutRow {
        LaidOutRow::new(first_char, top, bottom, first_line_top, can_break_above)
    }
}

// swift: PagePagination.LaidOutRow
#[derive(Debug, Clone, Copy)]
pub struct LaidOutRow {
    pub first_char: i64,
    pub top: CGFloat,
    pub bottom: CGFloat,
    pub first_line_top: CGFloat,
    pub can_break_above: bool,
}

impl LaidOutRow {
    pub fn new(first_char: i64, top: CGFloat, bottom: CGFloat, first_line_top: CGFloat, can_break_above: bool) -> Self {
        LaidOutRow { first_char, top, bottom, first_line_top, can_break_above }
    }
}

/// A run of rows welded into one unbreakable unit, as returned by `unbreakableGroups`.
// swift: PagePagination.unbreakableGroups
// (Swift tuple type, given a name here)
#[derive(Debug, Clone, Copy)]
pub struct UnbreakableGroup {
    pub first_char: i64,
    pub height: CGFloat,
    pub top_inset: CGFloat,
    pub row_count: i64,
}

impl PagePagination {
    /// The pieces a table may be broken into: each run of rows from one breakable boundary up to the
    /// next. A row whose `canBreakAbove` is false is welded to the row above it, so the two share a
    /// group and move together.
    ///
    /// One group means the table cannot be broken at all (its very first row is the only boundary),
    /// which is the answer for a form whose left column is merged from top to bottom.
    // swift: PagePagination.unbreakableGroups
    pub fn unbreakable_groups(rows: &[LaidOutRow]) -> Vec<UnbreakableGroup> {
        let mut out: Vec<UnbreakableGroup> = Vec::new();
        let mut start: Option<LaidOutRow> = None;
        let mut top: CGFloat = CGFloat::MAX;
        let mut bottom: CGFloat = CGFloat::MIN;
        let mut rows_in_group: i64 = 0;

        // swift: PagePagination.close
        fn close(out: &mut Vec<UnbreakableGroup>, start: &Option<LaidOutRow>, top: CGFloat, bottom: CGFloat, rows_in_group: i64) {
            let Some(s) = start else { return };
            out.push(UnbreakableGroup {
                first_char: s.first_char,
                height: bottom - top,
                top_inset: s.first_line_top - top,
                row_count: rows_in_group,
            });
        }

        for row in rows {
            if row.can_break_above || start.is_none() {
                close(&mut out, &start, top, bottom, rows_in_group);
                start = Some(*row);
                top = row.top;
                bottom = row.bottom;
                rows_in_group = 1;
            } else {
                top = top.min(row.top);
                bottom = bottom.max(row.bottom);
                rows_in_group += 1;
            }
        }
        close(&mut out, &start, top, bottom, rows_in_group);
        out
    }
}
