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

    static func applicableEntry(_ entries: [OfficeHeaderFooter], pageIndex: Int) -> OfficeHeaderFooter? {
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
    static func draw(_ content: PageBandContent, pageContentHeight: CGFloat, band: CGFloat,
                     documentHeight: CGFloat, visibleRect: NSRect, origin: NSPoint) {
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
            // THE PAGE BREAK ITSELF — drawn before the header/footer that sit inside it, so the two
            // land on top of the gap rather than under it. Only where layout actually opened the
            // band: filling a boundary that was never opened would put a grey stripe across a table.
            //
            // Why it exists: the band is the document's own two margins (invariant 57e), which on A4
            // is ~170pt of white. With nothing marking it, a reader sees a long blank stretch with a
            // header floating in the middle and no way to tell a page ended from a rendering fault —
            // reported as exactly that. Word shows the same break as a gap between two sheets; this
            // is that gap, one shade off the paper, closed by a hairline at each edge.
            if boundaryIsOpen, page < total - 1 {
                let gapTop = CGFloat(page) * pitch + pageContentHeight + leading + origin.y
                let rect = NSRect(x: origin.x, y: gapTop, width: content.columnWidth, height: band)
                if rect.intersects(visibleRect) {
                    Palette.pageGapBg.setFill()
                    rect.fill()
                    Palette.pageGapEdge.setFill()
                    // A whole DEVICE pixel, so the line is crisp at any magnification rather than a
                    // blurred two-pixel smear — the same reason invariant 42 keeps table rules integral.
                    let hair = 1 / max(1, NSScreen.main?.backingScaleFactor ?? 2)
                    NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: hair).fill()
                    NSRect(x: rect.minX, y: rect.maxY - hair, width: rect.width, height: hair).fill()
                }
            }
            // Footer of THIS page draws in the band that FOLLOWS it — never for the last page, which
            // has no following BETWEEN-PAGE band; its own trailing footer is the dedicated arm below.
            if boundaryIsOpen, page < total - 1, content.footerHeight > 0,
               let entry = applicableEntry(content.footers, pageIndex: page), !entry.blocks.isEmpty {
                let top = CGFloat(page) * pitch + pageContentHeight + leading
                paint(entry, pageIndex: page, totalPages: total, content: content,
                     top: top, height: content.footerHeight, origin: origin)
            }
            // Header of THIS page draws in the band that PRECEDES it — never for page 0, whose own
            // leading header is the dedicated arm below (a different reservation mechanism entirely).
            // Gated on the boundary BEFORE this page — the one whose band this header sits in.
            if bandExists(after: page - 1, in: content),
               page > 0, content.headerHeight > 0,
               let entry = applicableEntry(content.headers, pageIndex: page), !entry.blocks.isEmpty {
                let top = CGFloat(page) * pitch - content.headerHeight + leading
                paint(entry, pageIndex: page, totalPages: total, content: content,
                     top: top, height: content.headerHeight, origin: origin)
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
               let entry = applicableEntry(content.headers, pageIndex: 0), !entry.blocks.isEmpty {
                paint(entry, pageIndex: 0, totalPages: total, content: content,
                     top: 0, height: leading, origin: origin)
            }
            if page == total - 1, trailing > 0,
               let entry = applicableEntry(content.footers, pageIndex: total - 1), !entry.blocks.isEmpty {
                let top = CGFloat(page) * pitch + pageContentHeight + leading
                paint(entry, pageIndex: total - 1, totalPages: total, content: content,
                     top: top, height: trailing, origin: origin)
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
