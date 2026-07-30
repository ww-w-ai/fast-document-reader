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
