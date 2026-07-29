import AppKit

/// Reserves per-page vertical space for a running header/footer (header-footer-design.md §4, build
/// step 4) by shifting line fragments down at page boundaries — geometry ONLY. Nothing is painted
/// here; drawing the header/footer text into the space this reserves is step 5, not yet built.
///
/// Productionises `PageBandShiftSpikeTests`' proven algorithm verbatim: the page a line belongs to
/// is DERIVED from the incoming rect, never carried as a running counter, which is what keeps the
/// rule idempotent under mid-document re-layout (a resize, a splice, ⌘F) — see that spike's own
/// idempotence test for exactly why a counter fails it.
///
/// Installed on the real `NSLayoutManager` UNCONDITIONALLY (`DocumentWindowController.init`) and
/// left inert everywhere it doesn't apply — see `isActive` — so no call site needs to know whether
/// the current document is paged or has a header/footer at all.
final class PageBandLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    /// The document's own page BODY height (`MarkdownDocument.officePageContentHeight`). `0` when
    /// unknown / not paged.
    var pageContentHeight: CGFloat
    /// `PageBandGeometry.bandHeight` — footer + gap + next header. `0` disables shifting entirely
    /// (see `isActive`): a document with no header/footer must reserve nothing and lay out exactly
    /// as it did before this delegate existed.
    var band: CGFloat
    /// Extra space reserved BEFORE the very first line of text — the OUTER edge the between-page
    /// shifting below cannot reach on its own (there is no earlier line to push down). `0` when there
    /// is no header, or page 0's own applicable header is deliberately blank (the OOXML "no header on
    /// the cover" rule — `PageBandPainter.applicableEntry`, checked by `DocumentWindowController.
    /// configurePageBand` before this is set): a document that blanked its cover must not grow an
    /// unexplained gap above it either.
    var leadingBand: CGFloat
    /// The TRAILING twin, other outer edge — space reserved AFTER the very last line. NOT read by
    /// this class's own shifting algorithm (nothing exists past the last line for it to push down);
    /// carried here purely as the natural single home for all four page-band numbers, alongside
    /// `pageContentHeight`/`band`/`leadingBand`. `DocumentWindowController.applyTrailingFooterBand`
    /// is what actually reserves it — see that method's own doc for why it needs a completely
    /// different mechanism (`NSLayoutManager`'s "extra line fragment") than either edge above.
    var trailingBand: CGFloat

    init(pageContentHeight: CGFloat = 0, band: CGFloat = 0, leadingBand: CGFloat = 0, trailingBand: CGFloat = 0) {
        self.pageContentHeight = pageContentHeight
        self.band = band
        self.leadingBand = leadingBand
        self.trailingBand = trailingBand
    }

    /// The single gate (header-footer-design.md build step 4: "GATE IT ON PAGED... only a document
    /// with pageContentHeight (and at least one header or footer) paginates") checked against real
    /// numbers rather than against `DocumentWindowController.isPaged`, so this class stays testable
    /// and reusable on its own — a caller sets these two numbers and everything else follows.
    var isActive: Bool { pageContentHeight > 0 && band > 0 }

    /// How many line fragments this delegate has actually shifted, matching the shape of
    /// `DocumentWindowController.pageZoomChangeCount`/`layoutStepCount` — a test can assert
    /// something DID happen without a stopwatch, and without hand-deriving the expected line
    /// positions itself.
    private(set) var shiftCount = 0

    func layoutManager(_ layoutManager: NSLayoutManager,
                        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                        baselineOffset: UnsafeMutablePointer<CGFloat>,
                        in textContainer: NSTextContainer,
                        forGlyphRange glyphRange: NSRange) -> Bool {
        guard isActive else { return false }
        // KNOWN HARD EDGE (header-footer-design.md §4/§7), deliberately NOT solved in this step: a
        // line inside an NSTextTableBlock owns its own geometry through the table (invariants
        // 39/50) and must not be shifted. A long table is allowed to overrun its page; the boundary
        // is taken at the next line after it, exactly as the design records.
        if isInsideTable(layoutManager, glyphRange) { return false }
        let pitch = pageContentHeight + band
        guard pitch > 0 else { return false }
        let rect = lineFragmentRect.pointee
        // Both derived in the exact coordinate system the between-page rule already proved correct —
        // just translated by `leadingBand` and back again. Page 0's own first line (proposed at its
        // NATURAL, never-yet-shifted `rect.minY == 0`) falls out of this identical "crossing" check
        // as page `-1` overrunning page `-1`'s own (empty) content — `page == floor((0 - leadingBand)
        // / pitch) == -1` whenever `leadingBand < pitch` (always true: a header/footer band is never
        // as tall as a whole page), and `target == (page + 1) * pitch + leadingBand == leadingBand`
        // is exactly page 0's own start. No separate branch is needed for it. `leadingBand == 0`
        // reduces this identically to the original, untranslated formula — a document with no
        // leading reservation is providably unaffected (`PageBandReservationTests` proves it).
        let page = ((rect.minY - leadingBand) / pitch).rounded(.down)
        let textBottom = page * pitch + pageContentHeight
        guard (rect.maxY - leadingBand) > textBottom else { return false }
        let target = (page + 1) * pitch + leadingBand
        let shift = target - rect.minY
        lineFragmentRect.pointee.origin.y += shift
        lineFragmentUsedRect.pointee.origin.y += shift
        shiftCount += 1
        return true
    }

    /// A paragraph built inside a table cell carries its `NSTextTableBlock` on `paragraphStyle.
    /// textBlocks` (`TableBlockBuilder`'s `ps.textBlocks = [block]`) — the same signal every other
    /// table-aware pass in this reader keys off. Checked at the glyph range's first character only,
    /// matching the rest of the codebase's per-paragraph attribute reads (e.g.
    /// `drawMDDecorations`'s `charRange.location`): a line fragment never spans two paragraphs.
    private func isInsideTable(_ layoutManager: NSLayoutManager, _ glyphRange: NSRange) -> Bool {
        guard glyphRange.length > 0, let storage = layoutManager.textStorage else { return false }
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard charRange.location >= 0, charRange.location < storage.length else { return false }
        guard let style = storage.attribute(.paragraphStyle, at: charRange.location, effectiveRange: nil)
                as? NSParagraphStyle else { return false }
        return !style.textBlocks.isEmpty
    }
}
