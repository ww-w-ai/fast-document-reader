//! swift: Render/Office/PagePagination.swift
//! swift-range: 1-2

use std::collections::{HashMap, HashSet};
use swiftshim::{CGFloat, CGPoint, CGRect, CGSize};

/// swift: `CGRect.union(_:)` — swiftshim's `CGRect` has no drawing/geometry-op methods beyond
/// the computed properties (min/max/mid), so the smallest enclosing rect is computed locally
/// rather than added to the shim for one call site.
fn union_rect(a: CGRect, b: CGRect) -> CGRect {
    let min_x = a.minX().min(b.minX());
    let min_y = a.minY().min(b.minY());
    let max_x = a.maxX().max(b.maxX());
    let max_y = a.maxY().max(b.maxY());
    CGRect::fromOriginSize(
        CGPoint::new(min_x, min_y),
        CGSize::new(max_x - min_x, max_y - min_y),
    )
}

/// Where each SHEET of a paged document sits in the text view's own coordinates — the one piece of
/// arithmetic printing needs that the reader did not already have, kept pure and view-free so it is
/// judged by numbers rather than by looking at a printout.
///
/// The reader already lays a paged document out as a stack of pages: `PageBandLayoutDelegate` pushes
/// each page's first line down so that page `k`'s text begins exactly `pitch` below page `k-1`'s
/// (`pitch = pageContentHeight + band`, invariant 58). Printing therefore does NOT need a second
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

    /// THE lowest a body line may reach on a given page — its sheet's text bottom, less whatever
    /// that page reserves for the footnotes cited on it.
    ///
    /// ONE definition, because FOUR rules ask it and a fourth copy is what this exists to stop.
    /// `PageBandLayoutDelegate` already held three of them together (the keep-with-next check, the
    /// between-page shift and the table push) once a note band could shorten a page. The table
    /// PAGINATION rules were the fourth, and they were still asking the flat `page × pitch +
    /// pageContentHeight` — so a table that fitted the whole page but not the body a note band left
    /// it was judged as fitting, registered nowhere, and drawn straight over its own footnotes.
    /// MEASURED on a 30-note fiscal report: sheet 3's table ran to y=802 on an 841.9pt sheet whose
    /// body ends at 771, interleaved line for line with the four note lines beneath it.
    ///
    /// A document that cites no footnote passes an EMPTY `noteBands` and gets the identical number
    /// it got before this existed — which is what keeps the corpus provably unaffected.
    // swift: PagePagination.textBottom
    pub fn text_bottom(
        page: CGFloat,
        page_content_height: CGFloat,
        band: CGFloat,
        note_bands: &HashMap<i64, CGFloat>,
    ) -> CGFloat {
        let full = page * (page_content_height + band) + page_content_height;
        if note_bands.is_empty() || page < 0.0 {
            return full;
        }
        full - note_bands.get(&(page as i64)).copied().unwrap_or(0.0)
    }

    /// How much BODY a given page actually offers — the same subtraction as `textBottom`, expressed
    /// as a HEIGHT because that is what "does this piece fit" asks. Never negative: a band clamped
    /// to three quarters of its page (`FootnoteBandSettle.maxBandFraction`) cannot reach here, but a
    /// caller passing an unclamped one must not get a negative page out of it.
    // swift: PagePagination.bodyHeight
    pub fn body_height(page: CGFloat, page_content_height: CGFloat, note_bands: &HashMap<i64, CGFloat>) -> CGFloat {
        if note_bands.is_empty() || page < 0.0 {
            return page_content_height;
        }
        (page_content_height - note_bands.get(&(page as i64)).copied().unwrap_or(0.0)).max(0.0)
    }

    /// How far above a page's first line its own sheet begins.
    ///
    /// The document's declared top margin whenever it stated one. When it did not, HALF the band —
    /// which is not a guess so much as the same fallback the painter already uses: with no declared
    /// margins `PageBandPainter.footerTop`/`headerTop` put the footer in the upper half of the gap and
    /// the header in the lower half, i.e. they treat the gap's midpoint as the sheet edge. Printing
    /// has to agree with the painter about where the paper ends, or the footer of one page would print
    /// on the next.
    // swift: PagePagination.topMargin
    pub fn top_margin(declared: Option<CGFloat>, band: CGFloat) -> CGFloat {
        match declared {
            Some(d) if d >= 0.0 => d,
            _ => band / 2.0,
        }
    }

    /// The top edge of page `page`'s sheet (0-based), in the text view's flipped coordinates.
    ///
    /// `textOriginY` is `NSTextView.textContainerOrigin.y` — the app's own vertical inset, which is
    /// NOT part of the document and is why this cannot be derived from the pitch alone. `leadingBand`
    /// is the extra room reserved above the very first line for page 0's own header
    /// (`PageBandLayoutDelegate.leadingBand`).
    ///
    /// Page 0's sheet top is routinely NEGATIVE, and that is correct rather than a clamp waiting to
    /// happen: the reader shows only its own 28pt of padding above the first line, while the paper
    /// wants a full top margin there (99.25pt on the reference document). The missing 71pt is blank
    /// paper — there is nothing in the view to draw in it, and a print rect is allowed to reach past
    /// the view's bounds. Clamping it to 0 instead would print page 1 with a 28pt top margin and every
    /// other page with 99.25.
    // swift: PagePagination.sheetTop
    pub fn sheet_top(page: i64, text_origin_y: CGFloat, leading_band: CGFloat, pitch: CGFloat, top_margin: CGFloat) -> CGFloat {
        text_origin_y + leading_band + (page as CGFloat) * pitch - top_margin
    }

    /// Every sheet, in order — `rectForPage`'s whole answer. `width` is the document view's full
    /// width, which for a paged document is already the paper's (`DocumentWindowController.
    /// pagedDocumentWidth` = left margin + body + right margin), so the horizontal side needs no
    /// arithmetic at all.
    /// Join sheets across a boundary LAYOUT NEVER OPENED, so the page break is never drawn through a
    /// table.
    ///
    /// A line inside an `NSTextTableBlock` cannot be shifted (`PageBandLayoutDelegate.isInsideTable`,
    /// invariant 55/58's known edge), so a table crossing a page boundary simply overruns it and no
    /// band is opened there. The painter already knows to skip a header and footer in that case — but
    /// a SHEET drawn on the arithmetic grid does not care, so the sheet's edge and the desk behind it
    /// landed in the middle of a table, which the owner reported on sight. Two things then read as
    /// broken at once: the page appears to end mid-table, and the table draws straight over the desk.
    ///
    /// Joining them says the true thing instead — this page ran longer than its paper, because the
    /// reader cannot split the table. `openedBoundaries` is layout's own record; `nil` means nobody
    /// asked layout (a test, or the print path), and then every boundary stands.
    ///
    /// SCREEN ONLY. Paper cannot stretch, so `rectForPage` keeps the paper-sized grid — the divergence
    /// is the medium's, not a disagreement between two implementations.
    // swift: PagePagination.joiningUnopenedBoundaries
    pub fn joining_unopened_boundaries(sheets: &[CGRect], opened_boundaries: Option<&HashSet<i64>>) -> Vec<CGRect> {
        let Some(opened_boundaries) = opened_boundaries else { return sheets.to_vec() };
        if sheets.len() <= 1 {
            return sheets.to_vec();
        }
        let mut out: Vec<CGRect> = Vec::new();
        for (page, sheet) in sheets.iter().enumerate() {
            // Boundary `page - 1` is the one between the previous sheet and this one.
            if page > 0 && !opened_boundaries.contains(&((page - 1) as i64)) {
                if let Some(last) = out.pop() {
                    out.push(union_rect(last, *sheet));
                    continue;
                }
            }
            out.push(*sheet);
        }
        out
    }

    /// One table as a COMPLETED layout shows it — the only four numbers `tablesToPush` needs, so the
    /// decision can be judged arithmetically instead of by looking at a printout.
    ///
    /// `visualTop` is the table's real top edge (the smallest line top in it), which is NOT
    /// `firstLineTop`: the first line the typesetter reaches belongs to whichever cell comes first in
    /// TEXT order, and a vertically merged cell is centred in its own span, so that line can sit well
    /// below the table's top edge.
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

// swift: PagePagination.LaidOutTable
#[derive(Debug, Clone)]
pub struct LaidOutTable {
    pub first_char: i64,
    pub visual_top: CGFloat,
    pub bottom: CGFloat,
    pub first_line_top: CGFloat,
    /// One past the last character any of this table's lines covers — the end of the LAST piece,
    /// which the piece boundaries alone cannot give (every other piece ends where the next begins).
    /// Defaults to `firstChar`, i.e. an empty extent, so a caller that only asks whether the whole
    /// table fits never accidentally claims a range it did not measure.
    pub last_char: i64,
    /// In document order. Empty for a caller that only cares whether the whole table fits.
    pub rows: Vec<LaidOutRow>,
    /// The DOCUMENT forbids cutting this table at a page boundary (`MDAttr.tableKeepsWhole`).
    /// `false` is "it did not say", not "it allows it" — the reader's own policy decides those.
    /// A table taller than a whole page is still broken: there is no page to move it to, and
    /// leaving it whole would put its foot in a margin rather than honour anything.
    pub keeps_whole: bool,
}

impl LaidOutTable {
    // swift: PagePagination.LaidOutTable
    pub fn new(
        first_char: i64,
        visual_top: CGFloat,
        bottom: CGFloat,
        first_line_top: CGFloat,
        last_char: Option<i64>,
        rows: Vec<LaidOutRow>,
        keeps_whole: bool,
    ) -> Self {
        LaidOutTable {
            first_char,
            visual_top,
            bottom,
            first_line_top,
            last_char: last_char.unwrap_or(first_char),
            rows,
            keeps_whole,
        }
    }
}

/// How tall a table is, and how far its first line in text order sits below its own top — the two
/// position-INDEPENDENT facts the layout rule needs to move it. Position-independent because a
/// paged document's reading column never changes (invariant 57), so measuring them once is enough
/// for the whole render.
// swift: PagePagination.TableMetrics
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TableMetrics {
    pub height: CGFloat,
    pub top_inset: CGFloat,
}

impl TableMetrics {
    /// Rounded to a hundredth of a point on the way in, which is what lets the settle loop stop:
    /// it re-measures every round and compares the whole record, so a piece whose height came back
    /// as `161.70000000000002` one round and `161.7` the next would read as a change for ever.
    pub fn new(height: CGFloat, top_inset: CGFloat) -> Self {
        TableMetrics {
            height: (height * 100.0).round() / 100.0,
            top_inset: (top_inset * 100.0).round() / 100.0,
        }
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
    /// Which tables must be moved WHOLE to the next page rather than allowed to run into the margin.
    ///
    /// A table qualifies when it does BOTH:
    ///  - overruns its own page's text bottom (its rows would print in the margin, and the reader
    ///    cannot split it — `PageBandLayoutDelegate.pushWholeTable` records why), and
    ///  - would FIT on a page of its own. A taller one gains nothing by moving: it would overrun the
    ///    next page just as far, having wasted the rest of the page it left. Measured on a 25-row
    ///    fixture whose 660pt table lives on a 220pt page — moving it adds a near-empty page and
    ///    changes nothing else.
    ///
    /// `alreadyPushed` is what a previous round decided. Its entries are kept verbatim: the rule that
    /// consumes them is idempotent (a table sitting at a page top declines to move again), and
    /// dropping one because it now fits would make it fit, then not fit, then fit — the settle loop
    /// would never converge.
    // swift: PagePagination.tablesToPush
    pub fn tables_to_push(
        tables: &[LaidOutTable],
        page_content_height: CGFloat,
        band: CGFloat,
        leading_band: CGFloat,
        split_tables: bool,
        already_pushed: &HashMap<i64, TableMetrics>,
        note_bands: &HashMap<i64, CGFloat>,
    ) -> HashMap<i64, TableMetrics> {
        let pitch = page_content_height + band;
        if !(pitch > 0.0) || !(page_content_height > 0.0) {
            return already_pushed.clone();
        }
        let mut out = already_pushed.clone();

        /// Which page a `y` starts on, with the hair of tolerance the layout rule uses — see
        /// `PageBandLayoutDelegate.page(of:leadingBand:pitch:)`. The two must agree exactly or the
        /// decision keeps asking for a move the rule has already made.
        // swift: PagePagination.pageOf
        fn page_of(top: CGFloat, leading_band: CGFloat, pitch: CGFloat) -> CGFloat {
            (((top - leading_band) / pitch) + 1e-6).floor()
        }

        /// Does this span, sitting here, run past the bottom of the page it starts on — where
        /// "bottom" is the body that page actually offers, notes taken out (`textBottom`)?
        // swift: PagePagination.overruns
        fn overruns(
            top: CGFloat,
            bottom: CGFloat,
            leading_band: CGFloat,
            pitch: CGFloat,
            page_content_height: CGFloat,
            band: CGFloat,
            note_bands: &HashMap<i64, CGFloat>,
        ) -> bool {
            let bound = PagePagination::text_bottom(page_of(top, leading_band, pitch), page_content_height, band, note_bands);
            (bottom - leading_band) > bound + 0.01
        }

        for t in tables {
            let height = t.bottom - t.visual_top;
            // An entry already in the record is RE-MEASURED even though it no longer overruns — it no
            // longer overruns BECAUSE it was moved, and its metrics were taken from the layout that
            // existed before anything moved. Freezing them froze a `topInset` of 302.14pt on the
            // reported document where the settled layout's is 3.0, which put the piece's top 300pt
            // above where it is drawn, so the rule read a piece running to 911pt as ending at 745 and
            // declined to move it. Only the KEY is kept verbatim (invariant 61d): dropping a key would
            // make the piece fit, then not fit, then fit, and the settle would never converge, while
            // refreshing a value converges as soon as the layout does — the record is compared whole
            // each round and every number in it is rounded to a hundredth of a point.
            let groups = Self::unbreakable_groups(&t.rows);
            let known = out.contains_key(&t.first_char) || groups.iter().any(|g| out.contains_key(&g.first_char));
            if !(known || overruns(t.visual_top, t.bottom, leading_band, pitch, page_content_height, band, note_bands)) {
                continue;
            }
            // WHERE IT WOULD LAND, not where it stands. Carrying moves a table to the NEXT page,
            // so "can it be carried" is a question about that page's body — and with notes the two
            // pages can offer different amounts. Judging by the page it sits on would carry a table
            // onto a sheet that cannot hold it either, and the record would march it forward one
            // sheet per round until the settle's cap stopped it.
            let landing_page = page_of(t.visual_top, leading_band, pitch) + 1.0;
            let landing_body = Self::body_height(landing_page, page_content_height, note_bands);
            let fits_on_a_page = height <= landing_body;
            // BREAK IT — always when it is taller than a page (there is no whole page to move it to,
            // and the owner's rule is that such a table must be split), and by preference when the
            // reader has asked for breaking. Every row that may safely start a page is registered;
            // the layout rule then moves whichever of them actually crosses, and the ones that do not
            // cost nothing.
            // A table the document says may not be cut is carried whole — unless it cannot fit on a
            // page at all, where breaking is the only thing that keeps it out of a margin.
            if !fits_on_a_page || (split_tables && !t.keeps_whole) {
                // The unit that moves is not a ROW but an UNBREAKABLE GROUP: the run of rows between
                // two boundaries a merged cell does not cross. Registering rows instead was tried and
                // measured on the reference report, which is merged nearly everywhere — the safe rows
                // moved, the merged stretches between them did not, and twenty lines still landed in
                // margins. A group is exactly what may start a page.
                if groups.len() > 1 {
                    // A piece that will be broken where it stands must NOT also be carried: the
                    // layout rule asks `pushedTables` first, so registering both would move the piece
                    // to the next page and only then start filling — the empty page this exists to
                    // avoid.
                    let table_exceeds_a_page = height > landing_body;
                    for g in groups.iter().filter(|g| {
                        g.height <= landing_body && !table_exceeds_a_page && !Self::broken_in_place(g, landing_body)
                    }) {
                        out.insert(g.first_char, TableMetrics::new(g.height, g.top_inset));
                    }
                    continue;
                }
                // Nothing inside it can be broken — every boundary is crossed by a merged cell, which
                // is one real table in a Korean report form. Better whole on the next page than half in
                // a margin, so it falls through to the other arm rather than being left where it is.
            }
            if !fits_on_a_page {
                continue;
            }
            out.insert(t.first_char, TableMetrics::new(height, t.first_line_top - t.visual_top));
        }
        out
    }

    /// The character extents of the pieces that fit on NO page — the ones `tablesToPush` is
    /// structurally unable to help, because moving a piece taller than the page body only empties the
    /// page it left (invariant 61d). A reader that stops there leaves those rows in the margin AND
    /// leaves a boundary recorded as opened over content that is still drawn there, which paints the
    /// page's desk gap straight across a table's own lines.
    ///
    /// Word's answer is to break the row where it stands — `w:cantSplit` is what asks it not to, and a
    /// document that never sets it is asking to be split (measured on the reported file: `cantSplit`
    /// 0, `vMerge` 0, so invariant 61a's tearing hazard cannot arise there). So a piece in this list is
    /// handed to the reader's ORDINARY between-page rule, one line at a time, exactly as prose is.
    ///
    /// `alreadyOversized` is kept VERBATIM for the same reason `tablesToPush` keeps its own record:
    /// once a piece is being broken, the gaps that opening puts inside it grow its measured extent, so
    /// re-deriving from the new layout could flip the answer back and forth and the settle would never
    /// stop. The record only grows, and there are finitely many pieces.
    // swift: PagePagination.oversizedPieces
    pub fn oversized_pieces(
        tables: &[LaidOutTable],
        page_content_height: CGFloat,
        band: CGFloat,
        leading_band: CGFloat,
        note_bands: &HashMap<i64, CGFloat>,
        already_oversized: &HashMap<i64, i64>,
    ) -> HashMap<i64, i64> {
        if !(page_content_height > 0.0) {
            return already_oversized.clone();
        }
        let mut out = already_oversized.clone();
        let pitch = page_content_height + band;
        for t in tables {
            // "Taller than a page" is measured against the body this table's OWN page offers. A
            // note band takes that body away, and a table judged against the whole sheet is then
            // declared to fit, carried nowhere, and drawn over the notes it cites. With no notes
            // this is `pageContentHeight` exactly, so every other document is unchanged.
            let on_page = if pitch > 0.0 { (((t.visual_top - leading_band) / pitch) + 1e-6).floor() } else { 0.0 };
            let body = Self::body_height(on_page, page_content_height, note_bands);
            let groups = Self::unbreakable_groups(&t.rows);
            if groups.is_empty() {
                // No rows were measured, so the whole table is the only piece there is.
                if t.bottom - t.visual_top > body && t.last_char > t.first_char {
                    out.insert(t.first_char, t.last_char);
                }
                continue;
            }
            // The owner's rule is about the TABLE: *"표 자체가 한페이지 넘기면"* it is broken where it
            // stands, cell middles and all — only a run of three lines or fewer is moved on
            // (`pullToNextPage`). A table that FITS on a page keeps the menu's carry/break choice.
            let table_exceeds_a_page = t.bottom - t.visual_top > body;
            for (i, g) in groups.iter().enumerate() {
                if table_exceeds_a_page || Self::broken_in_place(g, body) {
                    let end = if i + 1 < groups.len() { groups[i + 1].first_char } else { t.last_char };
                    if end > g.first_char {
                        out.insert(g.first_char, end);
                    }
                }
            }
        }
        out
    }

    /// May this piece be broken WHERE IT STANDS, one line at a time, the way Word breaks a row that
    /// does not carry `w:cantSplit`? ONLY when it fits on no page at all, so that carrying it is not
    /// an option (invariant 61d).
    ///
    /// Extending it to every SINGLE-ROW piece — which is provably free of the merged cell invariant
    /// 61a tears, since a merge welds the rows it spans into one group — was built and MEASURED, to
    /// fill the page a carried row leaves partly empty. It fills the page and puts the rows back in
    /// the margin, because a line inside an `NSTextTableBlock` does not stay where this delegate puts
    /// it (invariants 39/42): table lines left in a margin went 15 → 94 on `2025_행정업무운영편람_최종.hwp`,
    /// 0 → 7 on `1790387_prep_final_report.hwpx` and 0 → 3 on the reported docx, with page bodies of
    /// 507pt carrying 780–1015pt of lines. Over-tall pieces are the exception that works because they
    /// have nowhere to be carried to in the first place — for them the choice is between a broken row
    /// and a row in the margin, not between a broken row and a whole one.
    // swift: PagePagination.brokenInPlace
    fn broken_in_place(group: &UnbreakableGroup, page_content_height: CGFloat) -> bool {
        group.height > page_content_height
    }

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

    /// `deskGap` is the space the band reserved for the DESK between two drawn sheets
    /// (`RenderTheme.pageDeskGap`, non-zero only while the page outline is on). A sheet is therefore
    /// `pitch - deskGap` tall — the document's own paper — and the pages no longer TILE: the gap
    /// between sheet `k`'s bottom and sheet `k+1`'s top is exactly `deskGap`, which is what makes
    /// them read as separate pieces of paper rather than as one continuous roll.
    ///
    /// This mattered more than it looks: the first version had no desk at all, so the sheets tiled
    /// edge to edge, the desk fill was completely covered by the very sheets it sat behind, and the
    /// feature drew as a hairline — indistinguishable from the page-break rule it was supposed to
    /// replace. It looked like nothing had happened.
    // swift: PagePagination.sheets
    pub fn sheets(count: i64, width: CGFloat, text_origin_y: CGFloat, leading_band: CGFloat, pitch: CGFloat, top_margin: CGFloat, desk_gap: CGFloat) -> Vec<CGRect> {
        if !(count > 0) || !(pitch > 0.0) || !(width > 0.0) {
            return Vec::new();
        }
        let paper_height = (pitch - desk_gap).max(1.0);
        (0..count)
            .map(|page| {
                CGRect::new(
                    0.0,
                    Self::sheet_top(page, text_origin_y, leading_band, pitch, top_margin),
                    width,
                    paper_height,
                )
            })
            .collect()
    }
}
