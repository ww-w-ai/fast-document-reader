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
    /// How much of `band` is the DESK between two drawn sheets rather than the document's own margins
    /// (`RenderTheme.pageDeskGap`, non-zero only while the page outline is on).
    ///
    /// Held HERE, beside the band it is part of, because the drawing side has to subtract exactly what
    /// the layout side added. Reading the preference again at draw time looked equivalent and is not:
    /// between a toggle writing the preference and the band being re-solved there is a window in which
    /// a paint would take the new answer against the old band and mis-tile every sheet by 12pt. One
    /// fact, set once, by whoever reserved the space.
    var deskGap: CGFloat = 0

    /// Pieces that must be moved WHOLE to the next page rather than allowed to run into the margin,
    /// keyed by the character location of the first line of each. A piece is a whole TABLE when the
    /// reader keeps tables together, and an unbreakable run of ROWS when it breaks them (invariant 64)
    /// — the rule below is the same either way, which is why there is one record and not two — `DocumentWindowController.
    /// settlePagedTables` measures these from a completed layout and puts them here, and the rule
    /// below re-derives the actual shift from each incoming rect.
    ///
    /// Empty for every document that needs nothing moved, which is the overwhelming majority: on the
    /// reference report 4 of 16 tables overrun, and on a document whose tables all fit this stays
    /// empty and the layout is bit-for-bit what it was before this existed.
    var pushedTables: [Int: PagePagination.TableMetrics] = [:]

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

    /// The page boundaries this delegate actually OPENED — page `n` is present when the first line of
    /// page `n+1` was pushed down, i.e. when the band between them is real, empty space.
    ///
    /// The painter must consult this rather than compute boundaries arithmetically, and that is not a
    /// tidiness point: a line inside a table cannot be shifted (see `isInsideTable` below), so when a
    /// page boundary falls inside a long table NO space is made there — and a painter that trusted
    /// the arithmetic drew the header and the footer straight over the table's own rows. Reported on
    /// a real report: `- 3 -` printed across a table's header row and the running title across a data
    /// row, which reads as a corrupt document rather than as a missing header.
    ///
    /// Reset on every layout pass that re-runs, because a re-render re-decides every boundary; a
    /// stale entry would paint into space the new layout did not make.
    private(set) var openedBoundaries: Set<Int> = []

    /// WHERE each opened band actually is: page `n` → the vertical span of the empty gap that was
    /// made after it, in text-container coordinates.
    ///
    /// The arithmetic position (`page × pitch + pageContentHeight`) is NOT this, and the difference is
    /// a reported defect rather than a nicety: a table cannot be shifted, so it overruns its page, and
    /// the gap then begins BELOW where the page grid says it should. Painting the footer at the
    /// arithmetic position printed "- 4 -" across the last rows of a table that had overrun. The gap
    /// is exactly `[the line's own proposed top, where it was moved to]` — everything above the
    /// proposed top is the previous page's last line, everything below the target is the next page.
    private(set) var openedBands: [Int: (top: CGFloat, height: CGFloat)] = [:]

    /// Called when the storage is about to be laid out afresh — see `openedBoundaries`.
    func resetOpenedBoundaries() {
        openedBoundaries = []
        openedBands = [:]
        shiftCount = 0
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                        baselineOffset: UnsafeMutablePointer<CGFloat>,
                        in textContainer: NSTextContainer,
                        forGlyphRange glyphRange: NSRange) -> Bool {
        guard isActive else { return false }
        // A line inside an `NSTextTableBlock` owns its geometry through the table (invariants 39/50)
        // and is never shifted where it stands — SPLITTING a table at a page boundary was measured and
        // is not available to us; see `pushWholeTable`, which moves the table instead.
        let pitch = pageContentHeight + band
        guard pitch > 0 else { return false }
        let rect = lineFragmentRect.pointee
        if isInsideTable(layoutManager, glyphRange) {
            return pushWholeTable(layoutManager, glyphRange, rect, pitch,
                                  lineFragmentRect, lineFragmentUsedRect)
        }
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
        // This line begins page `page + 1`, so the boundary that was just opened is page `page`'s.
        // Page 0's own first line falls out of the same formula as `page == -1` (see above), and a
        // negative index is not a between-page boundary at all — the leading band is its own
        // mechanism — so it is deliberately not recorded.
        if page >= 0 {
            openedBoundaries.insert(Int(page))
            // The gap is what the shift OPENED: from where this line was GOING to start to where it
            // now does. `rect` is the local copy taken before the mutation, so it still holds the
            // proposed position — which is also the bottom of the previous page's last line, however
            // far that page overran.
            openedBands[Int(page)] = (top: rect.minY, height: shift)
        }
        return true
    }

    /// A table that would run off the bottom of its page is moved WHOLE to the top of the next one —
    /// the whole rule, and it needs to touch exactly ONE line to do it.
    ///
    /// **Why moving beats splitting, measured rather than assumed.** Letting the ordinary between-page
    /// rule shift table lines DOES produce a real Word-like split, and on a table of single-line cells
    /// it is flawless: rows stay whole, each page's segment keeps its own border box, the running
    /// header and footer land in the gap. On a REAL report it tears. A vertically merged cell spans
    /// the boundary, so the half of the row that moved leaves the merged cell stretched across the gap
    /// — with this reader's own header and page number painted inside the table — and the row's two
    /// halves end up a page apart. Splitting honestly needs `NSTextTableBlock` geometry we do not own
    /// (invariants 39/42 spent a night establishing that we should not), so the table moves instead.
    ///
    /// **Why one line is enough.** The typesetter positions each line after the previous one, so
    /// shifting the table's first line carries every later line with it — the same property the
    /// between-page rule above already relies on. Verified on the reference report: pushing table #0's
    /// first line left its height identical to the hundredth (438.45 both ways) and landed its visual
    /// top exactly on the target, merged-cell inset and all.
    ///
    /// **What it refuses to do.** A table TALLER than the page body can never fit, so CARRYING it only
    /// wastes the page it left — it is broken into unbreakable pieces instead (invariant 64), and the
    /// pieces arrive here through the same record. A piece that is itself taller than the page still
    /// stays where it is and overruns, which is the honest best and what
    /// `PagePagination.joiningUnopenedBoundaries` draws truthfully.
    private func pushWholeTable(_ layoutManager: NSLayoutManager, _ glyphRange: NSRange,
                                 _ rect: NSRect, _ pitch: CGFloat,
                                 _ lineFragmentRect: UnsafeMutablePointer<NSRect>,
                                 _ lineFragmentUsedRect: UnsafeMutablePointer<NSRect>) -> Bool {
        guard !pushedTables.isEmpty else { return false }
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard let metrics = pushedTables[charRange.location] else { return false }
        // The table's own top edge, which is what has to clear the page — not this line's, which a
        // merged cell can push down by an arbitrary amount.
        let visualTop = rect.minY - metrics.topInset
        let page = PageBandLayoutDelegate.page(of: visualTop, leadingBand: leadingBand, pitch: pitch)
        let textBottom = page * pitch + pageContentHeight
        // Already fits where it stands: nothing to do, and this is what makes the rule idempotent —
        // a table that was moved once lands at a page top and then declines to move again.
        guard (visualTop - leadingBand + metrics.height) > textBottom else { return false }
        let target = (page + 1) * pitch + leadingBand
        let shift = target - visualTop
        guard shift > 0 else { return false }
        lineFragmentRect.pointee.origin.y += shift
        lineFragmentUsedRect.pointee.origin.y += shift
        shiftCount += 1
        if page >= 0 {
            openedBoundaries.insert(Int(page))
            openedBands[Int(page)] = (top: visualTop, height: shift)
        }
        return true
    }

    /// Which page a point sits on — with a hair of tolerance, which is load-bearing rather than
    /// tidy. A piece moved to a page top lands at EXACTLY `page × pitch + leadingBand`, and that
    /// number does not survive the division: measured, a line placed at page 6's top came back as
    /// `5051.279999999` against a pitch product of `5051.28`, so a bare `floor` called it page 5 and
    /// the rule then judged it against page 5's bottom — a piece that had just been moved correctly
    /// read as still overrunning, and the settle could not converge.
    static func page(of y: CGFloat, leadingBand: CGFloat, pitch: CGFloat) -> CGFloat {
        (((y - leadingBand) / pitch) + 1e-6).rounded(.down)
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
