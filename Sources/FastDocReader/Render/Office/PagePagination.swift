import CoreGraphics

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
enum PagePagination {
    /// The repeat distance between one page's text and the next's — and, for a well-formed document,
    /// the paper's own height. Taken from what LAYOUT actually did rather than from the declared
    /// paper: if this reader had to widen the band because its own header/footer rendering is taller
    /// than the margins the document allowed (`PageBandGeometry.measure`'s `max`), the printed sheet
    /// grows with it. A sheet printed at the DECLARED height while the text repeats at a larger pitch
    /// would drift by the difference on every page and start slicing lines a few pages in.
    static func pitch(pageContentHeight: CGFloat, band: CGFloat) -> CGFloat {
        pageContentHeight + band
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
    static func textBottom(ofPage page: CGFloat, pageContentHeight: CGFloat, band: CGFloat,
                           noteBands: [Int: CGFloat]) -> CGFloat {
        let full = page * (pageContentHeight + band) + pageContentHeight
        guard !noteBands.isEmpty, page >= 0 else { return full }
        return full - (noteBands[Int(page)] ?? 0)
    }

    /// How much BODY a given page actually offers — the same subtraction as `textBottom`, expressed
    /// as a HEIGHT because that is what "does this piece fit" asks. Never negative: a band clamped
    /// to three quarters of its page (`FootnoteBandSettle.maxBandFraction`) cannot reach here, but a
    /// caller passing an unclamped one must not get a negative page out of it.
    static func bodyHeight(ofPage page: CGFloat, pageContentHeight: CGFloat,
                           noteBands: [Int: CGFloat]) -> CGFloat {
        guard !noteBands.isEmpty, page >= 0 else { return pageContentHeight }
        return max(0, pageContentHeight - (noteBands[Int(page)] ?? 0))
    }

    /// How far above a page's first line its own sheet begins.
    ///
    /// The document's declared top margin whenever it stated one. When it did not, HALF the band —
    /// which is not a guess so much as the same fallback the painter already uses: with no declared
    /// margins `PageBandPainter.footerTop`/`headerTop` put the footer in the upper half of the gap and
    /// the header in the lower half, i.e. they treat the gap's midpoint as the sheet edge. Printing
    /// has to agree with the painter about where the paper ends, or the footer of one page would print
    /// on the next.
    static func topMargin(declared: CGFloat?, band: CGFloat) -> CGFloat {
        guard let declared, declared >= 0 else { return band / 2 }
        return declared
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
    static func sheetTop(page: Int, textOriginY: CGFloat, leadingBand: CGFloat,
                         pitch: CGFloat, topMargin: CGFloat) -> CGFloat {
        textOriginY + leadingBand + CGFloat(page) * pitch - topMargin
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
    static func joiningUnopenedBoundaries(_ sheets: [CGRect],
                                          openedBoundaries: Set<Int>?,
                                          straddledByATable: Set<Int>? = nil) -> [CGRect] {
        guard let openedBoundaries, sheets.count > 1 else { return sheets }
        var out: [CGRect] = []
        // A boundary is welded when layout opened no band there AND something is actually drawn
        // across it. Without the second half, a boundary layout simply had no line to move at —
        // the prose that follows a table carried whole starts at a page top on its own — reads as
        // "never broke here" and welds two real sheets into one (see
        // `PageBandLayoutDelegate.tableStraddledBoundaries` for the measurement). A `nil` straddle
        // set means nobody measured, and the old, wider behaviour is kept.
        func weld(_ boundary: Int) -> Bool {
            guard !openedBoundaries.contains(boundary) else { return false }
            guard let straddledByATable else { return true }
            return straddledByATable.contains(boundary)
        }
        for (page, sheet) in sheets.enumerated() {
            // Boundary `page - 1` is the one between the previous sheet and this one.
            if page > 0, weld(page - 1), let last = out.popLast() {
                out.append(last.union(sheet))
            } else {
                out.append(sheet)
            }
        }
        return out
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
    struct LaidOutRow {
        var firstChar: Int
        var top: CGFloat
        var bottom: CGFloat
        var firstLineTop: CGFloat
        var canBreakAbove: Bool

        init(firstChar: Int, top: CGFloat, bottom: CGFloat, firstLineTop: CGFloat, canBreakAbove: Bool) {
            self.firstChar = firstChar
            self.top = top
            self.bottom = bottom
            self.firstLineTop = firstLineTop
            self.canBreakAbove = canBreakAbove
        }
    }

    struct LaidOutTable {
        var firstChar: Int
        var visualTop: CGFloat
        var bottom: CGFloat
        var firstLineTop: CGFloat
        /// One past the last character any of this table's lines covers — the end of the LAST piece,
        /// which the piece boundaries alone cannot give (every other piece ends where the next begins).
        /// Defaults to `firstChar`, i.e. an empty extent, so a caller that only asks whether the whole
        /// table fits never accidentally claims a range it did not measure.
        var lastChar: Int
        /// In document order. Empty for a caller that only cares whether the whole table fits.
        var rows: [LaidOutRow]
        /// The DOCUMENT forbids cutting this table at a page boundary (`MDAttr.tableKeepsWhole`).
        /// `false` is "it did not say", not "it allows it" — the reader's own policy decides those.
        /// A table taller than a whole page is still broken: there is no page to move it to, and
        /// leaving it whole would put its foot in a margin rather than honour anything.
        var keepsWhole: Bool

        init(firstChar: Int, visualTop: CGFloat, bottom: CGFloat, firstLineTop: CGFloat,
             lastChar: Int? = nil, rows: [LaidOutRow] = [], keepsWhole: Bool = false) {
            self.keepsWhole = keepsWhole
            self.firstChar = firstChar
            self.visualTop = visualTop
            self.bottom = bottom
            self.firstLineTop = firstLineTop
            self.lastChar = lastChar ?? firstChar
            self.rows = rows
        }
    }

    /// How tall a table is, and how far its first line in text order sits below its own top — the two
    /// position-INDEPENDENT facts the layout rule needs to move it. Position-independent because a
    /// paged document's reading column never changes (invariant 57), so measuring them once is enough
    /// for the whole render.
    struct TableMetrics: Equatable {
        var height: CGFloat
        var topInset: CGFloat

        /// Rounded to a hundredth of a point on the way in, which is what lets the settle loop stop:
        /// it re-measures every round and compares the whole record, so a piece whose height came back
        /// as `161.70000000000002` one round and `161.7` the next would read as a change for ever.
        init(height: CGFloat, topInset: CGFloat) {
            self.height = (height * 100).rounded() / 100
            self.topInset = (topInset * 100).rounded() / 100
        }
    }

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
    static func tablesToPush(_ tables: [LaidOutTable],
                             pageContentHeight: CGFloat, band: CGFloat, leadingBand: CGFloat,
                             splitTables: Bool = false,
                             alreadyPushed: [Int: TableMetrics] = [:],
                             noteBands: [Int: CGFloat] = [:]) -> [Int: TableMetrics] {
        let pitch = pageContentHeight + band
        guard pitch > 0, pageContentHeight > 0 else { return alreadyPushed }
        var out = alreadyPushed

        /// Which page a `y` starts on, with the hair of tolerance the layout rule uses — see
        /// `PageBandLayoutDelegate.page(of:leadingBand:pitch:)`. The two must agree exactly or the
        /// decision keeps asking for a move the rule has already made.
        func pageOf(_ top: CGFloat) -> CGFloat {
            (((top - leadingBand) / pitch) + 1e-6).rounded(.down)
        }

        /// Does this span, sitting here, run past the bottom of the page it starts on — where
        /// "bottom" is the body that page actually offers, notes taken out (`textBottom`)?
        func overruns(top: CGFloat, bottom: CGFloat) -> Bool {
            let bound = textBottom(ofPage: pageOf(top), pageContentHeight: pageContentHeight,
                                   band: band, noteBands: noteBands)
            return (bottom - leadingBand) > bound + 0.01
        }

        for t in tables {
            let height = t.bottom - t.visualTop
            // An entry already in the record is RE-MEASURED even though it no longer overruns — it no
            // longer overruns BECAUSE it was moved, and its metrics were taken from the layout that
            // existed before anything moved. Freezing them froze a `topInset` of 302.14pt on the
            // reported document where the settled layout's is 3.0, which put the piece's top 300pt
            // above where it is drawn, so the rule read a piece running to 911pt as ending at 745 and
            // declined to move it. Only the KEY is kept verbatim (invariant 61d): dropping a key would
            // make the piece fit, then not fit, then fit, and the settle would never converge, while
            // refreshing a value converges as soon as the layout does — the record is compared whole
            // each round and every number in it is rounded to a hundredth of a point.
            let groups = unbreakableGroups(t.rows)
            let known = out[t.firstChar] != nil || groups.contains { out[$0.firstChar] != nil }
            guard known || overruns(top: t.visualTop, bottom: t.bottom) else { continue }
            // WHERE IT WOULD LAND, not where it stands. Carrying moves a table to the NEXT page,
            // so "can it be carried" is a question about that page's body — and with notes the two
            // pages can offer different amounts. Judging by the page it sits on would carry a table
            // onto a sheet that cannot hold it either, and the record would march it forward one
            // sheet per round until the settle's cap stopped it.
            let landingPage = pageOf(t.visualTop) + 1
            let landingBody = bodyHeight(ofPage: landingPage, pageContentHeight: pageContentHeight,
                                         noteBands: noteBands)
            let fitsOnAPage = height <= landingBody
            // BREAK IT — always when it is taller than a page (there is no whole page to move it to,
            // and the owner's rule is that such a table must be split), and by preference when the
            // reader has asked for breaking. Every row that may safely start a page is registered;
            // the layout rule then moves whichever of them actually crosses, and the ones that do not
            // cost nothing.
            // A table the document says may not be cut is carried whole — unless it cannot fit on a
            // page at all, where breaking is the only thing that keeps it out of a margin.
            if !fitsOnAPage || (splitTables && !t.keepsWhole) {
                // The unit that moves is not a ROW but an UNBREAKABLE GROUP: the run of rows between
                // two boundaries a merged cell does not cross. Registering rows instead was tried and
                // measured on the reference report, which is merged nearly everywhere — the safe rows
                // moved, the merged stretches between them did not, and twenty lines still landed in
                // margins. A group is exactly what may start a page.
                if groups.count > 1 {
                    // A piece that will be broken where it stands must NOT also be carried: the
                    // layout rule asks `pushedTables` first, so registering both would move the piece
                    // to the next page and only then start filling — the empty page this exists to
                    // avoid.
                    let tableExceedsAPage = height > landingBody
                    for g in groups where g.height <= landingBody
                        && !tableExceedsAPage && !brokenInPlace(g, landingBody) {
                        out[g.firstChar] = TableMetrics(height: g.height, topInset: g.topInset)
                    }
                    continue
                }
                // Nothing inside it can be broken — every boundary is crossed by a merged cell, which
                // is one real table in a Korean report form. Better whole on the next page than half in
                // a margin, so it falls through to the other arm rather than being left where it is.
            }
            guard fitsOnAPage else { continue }
            out[t.firstChar] = TableMetrics(height: height, topInset: t.firstLineTop - t.visualTop)
        }
        return out
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
    static func oversizedPieces(_ tables: [LaidOutTable], pageContentHeight: CGFloat,
                                band: CGFloat = 0, leadingBand: CGFloat = 0,
                                noteBands: [Int: CGFloat] = [:],
                                alreadyOversized: [Int: Int] = [:]) -> [Int: Int] {
        guard pageContentHeight > 0 else { return alreadyOversized }
        var out = alreadyOversized
        let pitch = pageContentHeight + band
        for t in tables {
            // "Taller than a page" is measured against the body this table's OWN page offers. A
            // note band takes that body away, and a table judged against the whole sheet is then
            // declared to fit, carried nowhere, and drawn over the notes it cites. With no notes
            // this is `pageContentHeight` exactly, so every other document is unchanged.
            let onPage = pitch > 0 ? (((t.visualTop - leadingBand) / pitch) + 1e-6).rounded(.down) : 0
            let body = bodyHeight(ofPage: onPage, pageContentHeight: pageContentHeight,
                                  noteBands: noteBands)
            let groups = unbreakableGroups(t.rows)
            guard !groups.isEmpty else {
                // No rows were measured, so the whole table is the only piece there is.
                if t.bottom - t.visualTop > body, t.lastChar > t.firstChar {
                    out[t.firstChar] = t.lastChar
                }
                continue
            }
            // The owner's rule is about the TABLE: *"표 자체가 한페이지 넘기면"* it is broken where it
            // stands, cell middles and all — only a run of three lines or fewer is moved on
            // (`pullToNextPage`). A table that FITS on a page keeps the menu's carry/break choice.
            let tableExceedsAPage = t.bottom - t.visualTop > body
            for (i, g) in groups.enumerated()
                where tableExceedsAPage || brokenInPlace(g, body) {
                let end = i + 1 < groups.count ? groups[i + 1].firstChar : t.lastChar
                if end > g.firstChar { out[g.firstChar] = end }
            }
        }
        return out
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
    private static func brokenInPlace(_ group: (firstChar: Int, height: CGFloat, topInset: CGFloat,
                                                rowCount: Int),
                                      _ pageContentHeight: CGFloat) -> Bool {
        group.height > pageContentHeight
    }

    /// The pieces a table may be broken into: each run of rows from one breakable boundary up to the
    /// next. A row whose `canBreakAbove` is false is welded to the row above it, so the two share a
    /// group and move together.
    ///
    /// One group means the table cannot be broken at all (its very first row is the only boundary),
    /// which is the answer for a form whose left column is merged from top to bottom.
    static func unbreakableGroups(_ rows: [LaidOutRow])
        -> [(firstChar: Int, height: CGFloat, topInset: CGFloat, rowCount: Int)] {
        var out: [(firstChar: Int, height: CGFloat, topInset: CGFloat, rowCount: Int)] = []
        var start: LaidOutRow?
        var top = CGFloat.greatestFiniteMagnitude
        var bottom = -CGFloat.greatestFiniteMagnitude
        var rowsInGroup = 0
        func close() {
            guard let s = start else { return }
            out.append((firstChar: s.firstChar, height: bottom - top, topInset: s.firstLineTop - top,
                        rowCount: rowsInGroup))
        }
        for row in rows {
            if row.canBreakAbove || start == nil {
                close()
                start = row
                top = row.top
                bottom = row.bottom
                rowsInGroup = 1
            } else {
                top = min(top, row.top)
                bottom = max(bottom, row.bottom)
                rowsInGroup += 1
            }
        }
        close()
        return out
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
    static func sheets(count: Int, width: CGFloat, textOriginY: CGFloat, leadingBand: CGFloat,
                       pitch: CGFloat, topMargin: CGFloat, deskGap: CGFloat = 0) -> [CGRect] {
        guard count > 0, pitch > 0, width > 0 else { return [] }
        let paperHeight = max(1, pitch - deskGap)
        return (0..<count).map { page in
            CGRect(x: 0,
                   y: sheetTop(page: page, textOriginY: textOriginY, leadingBand: leadingBand,
                               pitch: pitch, topMargin: topMargin),
                   width: width, height: paperHeight)
        }
    }
}
