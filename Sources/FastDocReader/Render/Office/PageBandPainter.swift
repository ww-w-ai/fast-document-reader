import AppKit

/// Everything `PageBandPainter.draw` needs to paint a running header/footer at draw time, set
/// alongside `PageBandLayoutDelegate`'s own two numbers by the SAME `configurePageBand` call (see
/// `DocumentWindowController`) so both always describe the SAME render — never two calls that could
/// drift out of sync. `nil` on a `DocumentWindowController` (the default) costs nothing beyond the
/// one optional-unwrap in `ReaderTextView.drawBackground(in:)`, exactly like `pageBandDelegate.
/// isActive` costs nothing for the layout half.
struct PageBandContent {
    var headers: [OfficeHeaderFooter]
    var footers: [OfficeHeaderFooter]
    var theme: RenderTheme
    var columnWidth: CGFloat
    var documentDefaultFontSize: CGFloat
    var pageContentWidth: CGFloat?
    var headerHeight: CGFloat
    var footerHeight: CGFloat
    /// The LEADING (page-0) and TRAILING (final-page) reservations — `DocumentWindowController.
    /// configurePageBand`'s own computation, always set together with the six fields above from the
    /// SAME call so painting can never disagree with what was actually reserved (this struct's
    /// long-standing rule, now covering two more numbers). `0` disables painting the corresponding
    /// OUTER edge exactly as `headerHeight`/`footerHeight` being `0` already disables the
    /// between-page ones — see `PageBandPainter.draw`'s `page == 0` / `page == total - 1` arms.
    var leadingBand: CGFloat
    var trailingBand: CGFloat
    /// The between-page boundaries that layout actually OPENED (`PageBandLayoutDelegate.
    /// openedBoundaries`). A boundary missing from this set has NO empty band — the line that would
    /// have started the next page was inside a table and could not be moved — so nothing may be
    /// painted there. `nil` means "not known", and then every arithmetic boundary is painted, which
    /// is the behaviour every existing test was written against and the right answer for a caller
    /// (or a test) that drives the painter without a layout pass.
    var openedBoundaries: Set<Int>?
    /// WHERE each opened band is (`PageBandLayoutDelegate.openedBands`) — the position layout actually
    /// put the gap at, which is NOT `page × pitch + pageContentHeight` whenever a table overran its
    /// page. Consulted in preference to the arithmetic; absent for a page falls back to it.
    var openedBands: [Int: (top: CGFloat, height: CGFloat)] = [:]
    /// The document's own body margins and the running header's/footer's distance from the SHEET's
    /// edge (`OfficeReadResult.pageMarginTop`/`pageMarginBottom`/`pageHeaderDistance`/
    /// `pageFooterDistance`). When all four are known the band is laid out on the PAPER: the sheet
    /// boundary is a grid position, the footer sits its own distance above it and the header its own
    /// distance below, so the spacing is identical on every page. Absent, the band falls back to
    /// centring each side in half the gap — which drifts, because the gap is the margin PLUS whatever
    /// room the previous page's last line left over.
    var pageMarginTop: CGFloat?
    var pageMarginBottom: CGFloat?
    var headerDistance: CGFloat?
    var footerDistance: CGFloat?
}

/// Paints the running header/footer INTO the band `PageBandLayoutDelegate` already reserved between
/// pages (header-footer-design.md build step 5) — draw-time only, exactly the discipline invariant
/// 38 established for the reading-line band and the comments panel's marks: paint over what layout
/// already decided, invalidate nothing, touch neither the text storage nor the span model.
///
/// The two OUTER edges — page 0's own leading header, and the last page's own trailing footer — are
/// reserved by TWO OTHER mechanisms, neither of them `textContainerInset` (a spike proved before this
/// was built that its `.height` pads the top and bottom by the SAME amount always, so it cannot give
/// the two edges different reservations — exactly what a header taller than a footer, or vice versa,
/// needs): `PageBandLayoutDelegate.leadingBand` shifts every line by a constant, the same mechanism
/// the between-page bands already use; `DocumentWindowController.applyTrailingFooterBand` widens
/// `NSLayoutManager`'s own "extra line fragment" for the trailing side, since nothing exists past the
/// last line for a shift to act on. `draw`, below, paints both once `PageBandContent.leadingBand`/
/// `.trailingBand` say there is room — `applicableEntry`/`totalPages` were already correct for these
/// pages from the start; only the PAINTING for these two specific slots was ever missing.
enum PageBandPainter {
    /// Which header/footer entry applies to a 0-based page index — header-footer-design.md §2d/§4:
    /// `.firstPage` wins on page 0 when the document declared one, EVEN WITH EMPTY BLOCKS (an empty
    /// `.firstPage` entry is the deliberate "no header on the cover" the reader parts already
    /// synthesize for `w:titlePg` with no `type="first"` reference — see `OfficeHeaderFooter.
    /// firstPage`'s own doc); `.evenPages` wins on even HUMAN page numbers (`pageIndex + 1` divisible
    /// by 2, since `pageIndex` is 0-based and page 0 is "page 1"); otherwise `.defaultPages`. Any
    /// selector with no matching entry falls through to `.defaultPages` — the single-sided fallback
    /// every format uses when it never declared the other side (header-footer-design.md §7: real
    /// even/odd DIFFERENCE is deferred past v1, but a document that provides one anyway should not
    /// be ignored). Returns `nil` when even `.defaultPages` is absent — a document with no header/
    /// footer at all, or one whose only entries are for a page class this page doesn't belong to.
    /// Where a page's own sheet EDGE is — the boundary between this page's paper and the next's.
    ///
    /// A grid position (`gridTop`, where the text region ends, plus the document's own bottom margin),
    /// NOT a fraction of the gap, and that is the whole point: the gap layout opens is the margin PLUS
    /// whatever room the previous page's last line left unused, which varies with paragraph spacing,
    /// headings and tables. Anchoring to the grid makes the header and footer land identically on
    /// every page; anchoring to the gap made them drift, which the owner read as odd and even pages
    /// having different margins. Clamped into the gap that layout really opened, so a page whose last
    /// line overran (a table) still cannot be painted over.
    ///
    /// `nil` when the document never stated a bottom margin — callers then fall back to the gap's own
    /// midpoint, the best available guess.
    static func sheetEdge(gridTop: CGFloat, gap: (top: CGFloat, height: CGFloat),
                          bottomMargin: CGFloat?) -> CGFloat? {
        bottomMargin.map { min(max(gridTop + $0, gap.top), gap.top + gap.height) }
    }

    /// The top of the FOOTER: its own declared distance above the sheet's edge (docx
    /// `w:pgMar/@w:footer`), the same number Word measures it by. Falls back to centring it in the
    /// upper half of the gap — this page's bottom margin — when the distance is unknown.
    static func footerTop(gap: (top: CGFloat, height: CGFloat), sheetEdge: CGFloat?,
                          distance: CGFloat?, footerHeight: CGFloat) -> CGFloat {
        // The PAPER's own bottom whenever it is known, even when the document never declared how far
        // above it the footer sits: the fallback below divides the GAP, and a gap is not a margin —
        // a page whose last line ended early opens a gap that begins in the middle of the sheet, and
        // dividing that put a page number across the middle of the page (measured on a real manual's
        // appendix: the number at y≈451 of 754 instead of y≈726). With the sheet edge known, a
        // missing distance means "as low as the paper allows", which is where every reader puts it.
        guard let sheetEdge else {
            return gap.top + max(0, (gap.height / 2 - footerHeight) / 2)
        }
        return max(gap.top, sheetEdge - (distance ?? 0) - footerHeight)
    }

    /// Does a footer placed at `top` still end ABOVE its own page's paper edge?
    ///
    /// `sheetEdge` above is CLAMPED into the gap layout actually opened, so that a page whose last
    /// line overran is not painted over — and when the overrun passes the paper edge, that clamp
    /// pushes the footer past it, onto the NEXT SHEET. Invisible on screen, where a sheet is notional;
    /// on paper it is page 5's number printed at the top of page 6, measured on the reference report,
    /// where a table overran by 1.12pt and moved `- 5 -` a whole sheet. (Task 2's page outline would
    /// make the same fault visible on screen, so this is not a print-only correction.)
    ///
    /// `paperEdge` is the UNCLAMPED grid position — `gridTop + bottomMargin` — which is exact: the
    /// delegate always shifts a page's first line to precisely `page × pitch + leadingBand`, so page
    /// boundaries never drift even when the gaps between them do. `nil` (the document stated no bottom
    /// margin) means there is no sheet to fall off, and everything is allowed.
    ///
    /// When this is false the footer is SKIPPED rather than moved, which is the same judgement
    /// `bandExists` already encodes: a missing page number reads as a short page, a page number in the
    /// wrong place reads as a corrupt document.
    static func footerFitsOnItsSheet(top: CGFloat, footerHeight: CGFloat, paperEdge: CGFloat?) -> Bool {
        guard let paperEdge else { return true }
        return top + footerHeight <= paperEdge + 0.01   // 0.01: the reading column is fractional
    }

    /// The top of the HEADER: its own declared distance BELOW the sheet edge that precedes its page
    /// (docx `w:pgMar/@w:header`). Never allowed past the end of that gap, or it would sit on the
    /// first line of the page it belongs to.
    static func headerTop(gap: (top: CGFloat, height: CGFloat), sheetEdge: CGFloat?,
                          distance: CGFloat?, headerHeight: CGFloat) -> CGFloat {
        // BELOW the sheet edge whenever it is known — a header belongs to the page it heads, and the
        // half-of-the-gap fallback put it on the PREVIOUS sheet whenever the gap was large (measured:
        // page 372's number printed at the bottom of page 371's paper).
        guard let sheetEdge else {
            let half = gap.height / 2
            return gap.top + half + max(0, (half - headerHeight) / 2)
        }
        return min(sheetEdge + (distance ?? 0), gap.top + gap.height - headerHeight)
    }

    /// Is there real, empty space in the band AFTER `page` — i.e. did layout manage to open that
    /// boundary? THE one gate both between-page arms of `draw` go through, so a header and the footer
    /// facing it across the same band can never disagree about whether that band exists.
    ///
    /// A boundary falling inside a table cannot be opened (`PageBandLayoutDelegate.isInsideTable`), so
    /// painting there lands on the table's own rows. Reported on a real report as a page number
    /// printed across a table's header row and the running title across a data row — which reads as a
    /// corrupt document, strictly worse than the missing header that skipping gives.
    ///
    /// `nil` (`openedBoundaries` unset — a caller that never ran layout) means "no information", and
    /// then every arithmetic boundary paints, which is exactly what this did before the set existed.
    static func bandExists(after page: Int, in content: PageBandContent) -> Bool {
        guard let opened = content.openedBoundaries else { return true }
        return opened.contains(page)
    }

    static func applicableEntry(_ entries: [OfficeHeaderFooter], pageIndex: Int,
                                section: Int? = nil) -> OfficeHeaderFooter? {
        // THE SECTION FIRST, when both the page and the entry know theirs — a running head belongs
        // to its own section (invariant 77) and a page belongs to one section (invariant 78). An
        // entry that names no section (docx, odt) applies wherever its parity does, as it always has.
        var entries = entries
        if let section {
            let own = entries.filter { $0.section == nil || $0.section == section }
            entries = own
        }
        if pageIndex == 0, let first = entries.first(where: { $0.appliesTo == .firstPage }) {
            return first
        }
        let humanPage = pageIndex + 1
        if humanPage % 2 == 0, let even = entries.first(where: { $0.appliesTo == .evenPages }) {
            return even
        }
        return entries.first(where: { $0.appliesTo == .defaultPages })
    }

    /// `ceil(documentHeight / pitch)`, clamped to at least 1 — header-footer-design.md §5's own
    /// suggested formula. `documentHeight` is the ALREADY-LAID-OUT extent (`NSLayoutManager.
    /// usedRect(for:).height`, invariant 48's contiguous layout means this costs nothing extra to
    /// read), never re-walked here. `pitch <= 0` (not paginating at all) or a document with no
    /// laid-out height yet both report 1 rather than 0 — a page COUNT of zero has no honest meaning.
    static func totalPages(documentHeight: CGFloat, pitch: CGFloat) -> Int {
        guard pitch > 0, documentHeight > 0 else { return 1 }
        return max(1, Int((documentHeight / pitch).rounded(.up)))
    }

    /// Replace every `MDAttr.pageNumberField`-marked run's text with its LIVE value for THIS page —
    /// mutates a COPY the caller just built fresh for this one draw (never the shared document
    /// storage, never undo-tracked), the same "compute a display transform on a copy" discipline
    /// `OfficeTextBuilder`'s own `caps` transform uses. `page` is 1-based (the human page number,
    /// `pageIndex + 1`) to match what a reader expects a page field to show. Ranges are replaced
    /// back-to-front so an earlier range's offset stays valid while a later one's length changes.
    /// A span with no `pageNumberField` is never touched — its cached text (Word's stale last-computed
    /// value) survives exactly as authored, everywhere this function isn't asked to look.
    static func substitutingPageFields(_ attr: NSAttributedString, page: Int, totalPages: Int) -> NSAttributedString {
        guard attr.length > 0 else { return attr }
        var replacements: [(NSRange, String)] = []
        attr.enumerateAttribute(MDAttr.pageNumberField, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            guard let field = value as? PageNumberField else { return }
            replacements.append((range, String(field == .page ? page : totalPages)))
        }
        guard !replacements.isEmpty else { return attr }
        let out = NSMutableAttributedString(attributedString: attr)
        for (range, replacement) in replacements.reversed() {
            out.replaceCharacters(in: range, with: replacement)
        }
        return out
    }

    /// Draw every header/footer whose band intersects `visibleRect` — called from `ReaderTextView.
    /// drawBackground(in:)`, gated by the caller on `pageBandDelegate.isActive` (this function itself
    /// re-checks the same two numbers so it is safe to call unconditionally too). `visibleRect` is
    /// the view's own property, used the SAME loose way `drawReadingLine`/`drawMDDecorations` already
    /// use it against container-local geometry (see those functions' own comments) — this file
    /// follows that existing convention rather than introducing a stricter one just for this feature.
    /// `origin` is `textContainerOrigin`, exactly as every other decoration in this file receives it.
    /// `sectionOfPage` answers which section a page is typeset on, so an entry declared by another
    /// section is not painted here — see `DocumentWindowController.sectionOfPage`. `nil` means the
    /// document never said, and every entry then applies by parity alone, as it did before.
    static func draw(_ content: PageBandContent, pageContentHeight: CGFloat, band: CGFloat,
                     documentHeight: CGFloat, visibleRect: NSRect, origin: NSPoint,
                     sectionOfPage: (Int) -> Int? = { _ in nil }) {
        guard pageContentHeight > 0, band > 0 else { return }
        let pitch = pageContentHeight + band
        // `Int(_: CGFloat)` traps on NaN/infinite — guard defensively the same way
        // `PageBandGeometry.measuredHeight` guards `columnWidth.isFinite` before using it in
        // arithmetic that later feeds an `Int` conversion. In practice `visibleRect` and
        // `documentHeight` are always finite (real view/layout geometry), but a paint pass must
        // never be the thing that turns a degenerate value into a crash.
        guard pitch.isFinite, documentHeight.isFinite,
              visibleRect.minY.isFinite, visibleRect.maxY.isFinite else { return }
        let leading = content.leadingBand
        let trailing = content.trailingBand
        // `documentHeight` (`NSLayoutManager.usedRect(for:).height`) already carries whatever LEADING
        // offset the layout delegate baked into every line's position, and — once
        // `DocumentWindowController.applyTrailingFooterBand` has actually run — the TRAILING
        // reservation too (both are real laid-out extent by the time either is non-zero here;
        // nothing about reading them back out forces layout early). Subtracting them back off
        // recovers the real BODY extent `totalPages` must be judged against: leaving them in would
        // silently manufacture a phantom extra page the instant either reservation's own size pushed
        // the total just past a `pitch` multiple.
        let bodyHeight = max(0, documentHeight - leading - trailing)
        let total = totalPages(documentHeight: bodyHeight, pitch: pitch)
        // Pad by one page on each side of the visible range — cheap (a header/footer is a handful of
        // paragraphs) and avoids a hairline-thin visible sliver skipping a band it should still show.
        let firstPage = max(0, Int(((visibleRect.minY - leading) / pitch).rounded(.down)) - 1)
        let lastPage = min(total - 1, Int(((visibleRect.maxY - leading) / pitch).rounded(.up)) + 1)
        guard firstPage <= lastPage else { return }
        for page in firstPage...lastPage {
            // Did layout actually MAKE the band after this page? A boundary falling inside a table
            // could not be opened (`PageBandLayoutDelegate.isInsideTable`), so there is no empty
            // space there and painting would land on the table's own rows — measured on a real
            // report as a page number across a table's header row and a running title across a data
            // row. Both BETWEEN-page arms below are gated on it; the two OUTER edges are not, because
            // they are reserved by different mechanisms that a table cannot block.
            let boundaryIsOpen = bandExists(after: page, in: content)
            // WHERE the band actually is. Layout's own answer when it has one, the page grid only
            // as a fallback: a table cannot be shifted, so it overruns its page and the gap then
            // starts BELOW `page × pitch + pageContentHeight`. Trusting the grid printed "- 4 -"
            // across the last rows of an overrunning table — reported, and the reason this exists.
            let gridTop = CGFloat(page) * pitch + pageContentHeight + leading
            let gap = content.openedBands[page].map { (top: $0.top + origin.y, height: $0.height) }
                ?? (top: gridTop + origin.y, height: band)
            // WHERE THE SHEET ENDS. A grid position, not a fraction of the gap: `gridTop` is where
            // this page's text region ends and the document's own bottom margin begins, so the paper's
            // edge is exactly one bottom margin further down. Clamped into the gap that layout really
            // opened, because a page whose last line overran (a table) has a gap that starts lower.
            let sheetEdge = Self.sheetEdge(gridTop: gridTop + origin.y, gap: gap,
                                           bottomMargin: content.pageMarginBottom)

            // THE PAGE BREAK ITSELF — one line across the reading column, in the middle of the gap,
            // between the footer above it and the header below it. Drawn first so those two land on
            // top of it.
            //
            // It began as a FILLED band, one shade off the paper, and the owner read that as "헤더와
            // 푸터 부분에 일부러 영역을 그린건가? 디바이더는 없고 영역 박스만 크게 있네" — on A4 the
            // gap is ~170pt, so a fill is a large grey box that describes the header/footer AREA
            // rather than the page ending. A divider is a line. The gap keeps the paper's own colour.
            // Footer of THIS page draws in the band that FOLLOWS it — never for the last page, which
            // has no following BETWEEN-PAGE band; its own trailing footer is the dedicated arm below.
            if boundaryIsOpen, page < total - 1, content.footerHeight > 0,
               let entry = applicableEntry(content.footers, pageIndex: page, section: sectionOfPage(page)),
               !entry.blocks.isEmpty {
                // ITS OWN DISTANCE above the sheet's bottom edge (docx `w:pgMar/@w:footer`) — the
                // same number Word measures it by, so the footer lands identically on every page.
                // Without it, centred in the upper half of the gap: still inside this page's bottom
                // margin, but drifting with the gap, which is what read as odd and even pages having
                // different margins.
                let footerTop = Self.footerTop(gap: gap, sheetEdge: sheetEdge,
                                               distance: content.footerDistance,
                                               footerHeight: content.footerHeight)
                // …but never onto the NEXT sheet. See `footerFitsOnItsSheet`.
                let paperEdge = content.pageMarginBottom.map { gridTop + origin.y + $0 }
                if Self.footerFitsOnItsSheet(top: footerTop, footerHeight: content.footerHeight,
                                             paperEdge: paperEdge) {
                    paint(entry, pageIndex: page, totalPages: total, content: content,
                         top: footerTop - origin.y, height: content.footerHeight, origin: origin)
                }
            }
            // Header of THIS page draws in the band that PRECEDES it — never for page 0, whose own
            // leading header is the dedicated arm below (a different reservation mechanism entirely).
            // Gated on the boundary BEFORE this page — the one whose band this header sits in.
            if bandExists(after: page - 1, in: content),
               page > 0, content.headerHeight > 0,
               let entry = applicableEntry(content.headers, pageIndex: page, section: sectionOfPage(page)),
               !entry.blocks.isEmpty {
                // At the BOTTOM of the gap that PRECEDES this page — directly above its first line.
                // ITS OWN DISTANCE below the sheet's TOP edge, which is the boundary that precedes
                // this page (docx `w:pgMar/@w:header`). Same reasoning as the footer above.
                let previous = content.openedBands[page - 1].map { (top: $0.top, height: $0.height) }
                    ?? (top: CGFloat(page) * pitch - band + leading, height: band)
                let previousGridTop = CGFloat(page - 1) * pitch + pageContentHeight + leading
                let previousEdge = Self.sheetEdge(gridTop: previousGridTop, gap: previous,
                                                  bottomMargin: content.pageMarginBottom)
                let headerTop = Self.headerTop(gap: previous, sheetEdge: previousEdge,
                                               distance: content.headerDistance,
                                               headerHeight: content.headerHeight)
                paint(entry, pageIndex: page, totalPages: total, content: content,
                     top: headerTop, height: content.headerHeight, origin: origin)
            }
            // The two OUTER edges the between-page arms above structurally cannot reach: page 0's own
            // LEADING header, and the LAST page's own TRAILING footer. Reserved by two entirely
            // different mechanisms (`PageBandLayoutDelegate.leadingBand` / `DocumentWindowController.
            // applyTrailingFooterBand`, neither a line-shift at a boundary), so painted here rather
            // than folded into the two arms above, which are untouched from how step 5 first shipped
            // them. `.firstPage` with empty `blocks` (the OOXML "no header on the cover" rule, §2d)
            // must keep producing nothing — `applicableEntry` already encodes that selection; this
            // arm only adds WHERE to paint once it says there is something to paint.
            if page == 0, leading > 0,
               let entry = applicableEntry(content.headers, pageIndex: 0, section: sectionOfPage(0)),
               !entry.blocks.isEmpty {
                // Its own declared distance below the sheet's top edge — which, for page 0, is where
                // the leading reservation begins. Reduces to 0 (the original behaviour) whenever the
                // reservation is only as tall as the header itself, i.e. whenever the reader is NOT
                // drawing sheets: there is no room to be a distance INTO.
                let top = max(0, min(content.headerDistance ?? 0, leading - content.headerHeight))
                paint(entry, pageIndex: 0, totalPages: total, content: content,
                     top: top, height: content.headerHeight > 0 ? content.headerHeight : leading,
                     origin: origin)
            }
            if page == total - 1, trailing > 0,
               let entry = applicableEntry(content.footers, pageIndex: total - 1, section: sectionOfPage(total - 1)),
               !entry.blocks.isEmpty {
                // The same, from the other end: its own distance ABOVE the last sheet's bottom edge,
                // clamped so it never rides up over the document's own last line. Also reduces to 0
                // when the reservation is exactly the footer's height.
                let base = CGFloat(page) * pitch + pageContentHeight + leading
                let inset = max(0, trailing - (content.footerDistance ?? 0) - content.footerHeight)
                paint(entry, pageIndex: total - 1, totalPages: total, content: content,
                     top: base + inset,
                     height: content.footerHeight > 0 ? content.footerHeight : trailing, origin: origin)
            }
        }
    }

    /// Builds ONE entry through the SAME `OfficeTextBuilder` the body and `PageBandGeometry` both
    /// use (invariant 29's single-builder discipline), substitutes this page's live field values,
    /// then draws it — a fresh build per visible band per draw pass, which is fine: a header/footer
    /// is a handful of paragraphs (PageBandGeometry's own measurement pays the identical cost once
    /// already), nowhere near the body text this reader is careful to build only once.
    private static func paint(_ entry: OfficeHeaderFooter, pageIndex: Int, totalPages: Int,
                              content: PageBandContent, top: CGFloat, height: CGFloat, origin: NSPoint) {
        let built = OfficeTextBuilder.build(entry.blocks, theme: content.theme,
                                            columnWidth: content.columnWidth,
                                            documentDefaultFontSize: content.documentDefaultFontSize,
                                            pageContentWidth: content.pageContentWidth)
        guard built.length > 0 else { return }
        let sub = substitutingPageFields(built, page: pageIndex + 1, totalPages: totalPages)
        let rect = NSRect(x: origin.x, y: top + origin.y, width: content.columnWidth, height: height)
        sub.draw(in: rect)
    }
}
