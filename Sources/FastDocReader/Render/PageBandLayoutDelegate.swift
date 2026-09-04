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

    /// The character extents of table pieces that fit on NO page, `start → end` — measured by
    /// `PagePagination.oversizedPieces` from a completed layout, exactly like `pushedTables`.
    ///
    /// A line inside one of these is the ONE case where a table line is shifted where it stands: there
    /// is no whole page to carry the piece to, so refusing to touch it leaves its rows in the margin
    /// and leaves this class recording a boundary as opened over content that is still drawn in it —
    /// which paints the desk gap across the table's own lines. Word breaks such a row (it splits every
    /// row that does not carry `w:cantSplit`), and this is that answer.
    var oversizedPieces: [Int: Int] = [:]

    /// Lines that must START a page even though they would fit where they stand — the first line of a
    /// run of THREE OR FEWER lines a break would have stranded at the bottom of a page.
    ///
    /// The owner's rule: *"약간 1~3줄 애매할 땐 → 잘라서 다음 페이지로, 4줄 이상이면 페이지를 잘라서 셀이
    /// 구분됨"*. Breaking a cell is only worth the seam when enough of it stays behind; one or two
    /// stranded lines above a page gap read as a mistake. Measured from a completed layout by
    /// `DocumentWindowController.orphanRunStarts` and kept, like every other record here, keyed by
    /// character location.
    var pullToNextPage: Set<Int> = []

    /// Character locations the DOCUMENT breaks a page at (`MDAttr.startsPage` — HWP's 쪽 나누기 /
    /// 구역 나누기), collected from the built text before layout runs.
    ///
    /// Unlike everything else recorded here, this is not measured FROM a layout: the instruction is
    /// in the document, so it is known before the first line is placed. Honouring it is what keeps a
    /// cover, a foreword and a table of contents on three pages instead of running them together and
    /// pushing every page after them off by the difference.
    var documentPageBreaks: Set<Int> = []

    /// The markers in `storage` that actually have work to do — every `MDAttr.startsPage` EXCEPT one
    /// whose page would hold nothing but the empty paragraph the PREVIOUS marker left there.
    ///
    /// **Why the `shift > 0.5` guard in the rule below is not already this.** That guard asks "is this
    /// line at a page top", which is what makes a second layout pass idempotent. It cannot ask "is
    /// this line the first thing ON its page", because a line one empty paragraph below the top is
    /// not at the top and its page still carries nothing. Measured on `2025 행정업무운영 편람`: 94 of
    /// its 185 markers sit on an EMPTY paragraph, which takes the break, lands at the top of the new
    /// page and occupies one line there — so the next paragraph's break is no longer at the top and
    /// opens ANOTHER page, leaving the first holding only the 바탕쪽. Suppressing those is **2 pages**
    /// on this manual (516 → 514), not the 11 invariant 90 estimated from the marker shape alone:
    /// most of the pages that hold nothing are emptied by something else entirely, which that
    /// invariant now records.
    ///
    /// **Derived, never accumulated** — the discipline in this file's own header. Counting "has a
    /// glyph-bearing line landed on this page yet" would be a running counter, and mid-document
    /// re-layout (a resize, a splice, ⌘F) re-lays only a RANGE, so the count would arrive stale and
    /// the same marker would decide differently on the second pass. Emptiness BETWEEN two markers is
    /// a property of the text, decided once before layout, and every pass reads the same answer.
    ///
    /// Two deliberate narrowings, each because the wider rule would claim something unmeasured:
    /// - **The document's FIRST marker is always honoured.** Nothing precedes it, so what sits above
    ///   it is the document's opening rather than a page a break abandoned — here that is the cover,
    ///   whose body is empty only because its artwork is 바탕쪽 (invariant 78).
    /// - **A marker that also begins a SECTION is always honoured.** 구역 나누기 can change the paper
    ///   itself (invariant 73 — this manual runs five different body boxes), and a section that never
    ///   starts a page can never apply the paper it declares.
    /// Every PARAGRAPH carrying `key`, as its own range — the reliable way to read a per-paragraph
    /// marker back out of built text.
    ///
    /// **`enumerateAttribute` alone cannot do this, and the way it fails is silent.** It reports the
    /// longest range over which one attribute is CONSTANT, and every paragraph that carries one of
    /// these markers carries the same `true` — so two adjacent marked paragraphs arrive as a SINGLE
    /// run. A caller reading `range.location` then sees one marker where the document wrote two, and
    /// a caller reading the range sees one block where the document wrote two. Measured on
    /// `2025 행정업무운영 편람`: **176 runs against 185 marked paragraphs — 9 page breaks lost**,
    /// including ones with real text above them, where the effect was a heading that breaks straight
    /// after a paragraph that breaks quietly not starting a page at all.
    ///
    /// Splitting at paragraph boundaries costs one `paragraphRange` per MARKED paragraph — a couple
    /// of hundred on a 400-page manual, not one per character.
    static func markedParagraphs(_ key: NSAttributedString.Key,
                                 in storage: NSAttributedString) -> [(start: Int, end: Int)] {
        guard storage.length > 0 else { return [] }
        let text = storage.string as NSString
        var out: [(start: Int, end: Int)] = []
        storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            var location = range.location
            while location < NSMaxRange(range) {
                let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
                let end = min(max(NSMaxRange(paragraph), location + 1), NSMaxRange(range))
                out.append((start: location, end: end))
                location = end
            }
        }
        return out
    }

    static func honouredPageBreaks(in storage: NSAttributedString) -> Set<Int> {
        guard storage.length > 0 else { return [] }
        let text = storage.string as NSString
        var markers = markedParagraphs(MDAttr.startsPage, in: storage).map(\.start)
        guard markers.count > 1 else { return Set(markers) }
        markers.sort()
        // The one marker that must survive whatever sits after it: the first, when nothing at all
        // precedes it. What is above such a marker is the document's OPENING, not a page some
        // earlier break abandoned — here the cover, whose body is empty only because its artwork is
        // 바탕쪽 (invariant 78). Dropping it would run the cover into the page that follows. A first
        // marker with real text above it is an ordinary marker and takes the rule below.
        let opensTheDocument = text
            .substring(to: markers[0]).unicodeScalars
            .allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        var honoured = Set(markers)
        for (index, marker) in markers.enumerated().dropFirst() {
            let previous = markers[index - 1]
            guard !(previous == markers[0] && opensTheDocument) else { continue }
            let between = text.substring(with: NSRange(location: previous, length: marker - previous))
            guard between.unicodeScalars
                .allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else { continue }
            honoured.remove(previous)
        }
        return honoured
    }

    /// Character RANGES the document keeps with what follows them (`MDAttr.keepWithNext`), as
    /// `(start, end)` pairs — a heading and the paragraph under it must not be split by a page.
    ///
    /// Held as ranges rather than as single locations because the rule is about the block's LAST
    /// line: if that line is the last thing on a page, the block moves to the next page WHOLE, so
    /// the reader needs to know where the block began to move it. Empty for every document that
    /// declares none, which is most of them.
    var keepWithNextRanges: [(start: Int, end: Int)] = []

    /// Is this character inside a piece that must be broken where it stands? Linear over the record,
    /// which holds one entry per over-tall piece — single digits on real documents, and empty for the
    /// overwhelming majority, which is why the check begins by asking that.
    private func isInsideOversizedPiece(_ location: Int) -> Bool {
        guard !oversizedPieces.isEmpty else { return false }
        return oversizedPieces.contains { location >= $0.key && location < $0.value }
    }

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
    var isActive: Bool { pageContentHeight > 0 && (band > 0 || !noteBands.isEmpty) }

    /// Whether this document has SHEETS at all — the weaker half of the gate above, and the one the
    /// footnote path must ask instead.
    ///
    /// `isActive` answers "is there anything to reserve", which cannot decide whether a footnote
    /// gets placed: a note's reservation is what makes the answer yes, so gating the reservation on
    /// it is circular and settles on "no". Measured on the 637-document corpus: 17 of the 22
    /// footnote-citing documents declare neither a running head nor a foot, and every one of them
    /// lost its notes entirely — the exporter lifts a note out of the body flow, and with the band
    /// inert nothing drew it back (invariant 99's known limitation, now closed).
    var paginates: Bool { pageContentHeight > 0 }

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

    /// The boundaries a TABLE actually spans — the only ones the weld exists to protect.
    ///
    /// `openedBoundaries` answers "did this pass MOVE a line here", which is not the same question.
    /// A boundary can be perfectly real and still open nothing: a table carried whole to the next
    /// page leaves the prose after it starting exactly at a page top, so there is no line to move
    /// and no band to record. `joiningUnopenedBoundaries` read that as "layout never broke here" and
    /// welded the two sheets. Measured on `2025_행정업무운영편람_최종.hwp`: of the 21 boundaries left
    /// unopened, **9 have a table across them and 12 have nothing at all**, and welding all 21 made
    /// the appendix a single sheet 22 pages tall — the margin number stopped changing and Go to Page
    /// could not reach past it.
    ///
    /// `nil` means NOBODY MEASURED (invariant 108's rule — a missing measurement is not an empty
    /// one), and the weld then falls back to its old, wider behaviour rather than drawing page rules
    /// through tables on a document whose settle has not run.
    var tableStraddledBoundaries: Set<Int>?

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

    /// Where the typesetter PROPOSED each table line, before this delegate touched it — keyed by the
    /// line's first character.
    ///
    /// This exists because a cell's vertical alignment is applied AFTER the line fragment is placed,
    /// so the completed layout and this delegate see the same line at different heights: measured on
    /// `사업계획서_13-15p_수정안.docx`, the line at character 482 sits at 723.08 in the finished
    /// layout (its cell is centred in a 623pt row) and is proposed here at 423.94. A `topInset`
    /// measured from the finished layout and subtracted from the proposed rect therefore puts the
    /// piece's top 302pt above where it is drawn, and the rule read a piece running to 911pt as
    /// ending at 745 and declined to move it. `DocumentWindowController.laidOutTables` reads these
    /// back so the inset is measured in the frame it will be USED in.
    private(set) var proposedTableLineTops: [Int: CGFloat] = [:]

    /// Called when the storage is about to be laid out afresh — see `openedBoundaries`.
    func resetOpenedBoundaries() {
        openedBoundaries = []
        openedBands = [:]
        shiftCount = 0
        proposedTableLineTops = [:]
    }

    /// Record a page boundary as opened, and WHERE the empty band it made is. Page 0's own first
    /// line falls out of the shifting formula as page `-1` (see the rule below), and a negative index
    /// is not a between-page boundary at all — the leading band is its own mechanism.
    private func recordBand(page: CGFloat, top: CGFloat, target: CGFloat) {
        guard page >= 0 else { return }
        openedBoundaries.insert(Int(page))
        openedBands[Int(page)] = (top: top, height: target - top)
        // EVERY boundary the shift jumped OVER is open too. A line that moves more than one page —
        // which is what an author's page break does whenever the page it leaves is barely used —
        // skips the pages in between, and those pages then have no line of their own to open their
        // boundary. `joiningUnopenedBoundaries` reads an unopened boundary as "layout never broke
        // here" and welds the two sheets into one, so a chapter divider came out as a single
        // double-height page carrying two running heads and two page numbers. The pages exist
        // because the document says they do; their boundaries are real.
        let pitch = pageContentHeight + band
        guard pitch > 0 else { return }
        let targetPage = Int(((target - leadingBand) / pitch).rounded())
        guard targetPage > Int(page) + 1 else { return }
        for skipped in (Int(page) + 1)..<targetPage {
            openedBoundaries.insert(skipped)
            // The gap at a boundary nothing was shifted across is exactly the band, in its own
            // page's place — the same geometry an ordinary crossing would have produced.
            openedBands[skipped] = (top: leadingBand + CGFloat(skipped) * pitch + pageContentHeight,
                                    height: band)
        }
    }

    /// Everything the settle measured from a layout — dropped together with the string it was keyed
    /// against. Both records are character-keyed, so carrying either into a different document would
    /// move whatever happens to start at that offset.
    func resetMeasuredPieces() {
        pushedTables = [:]
        oversizedPieces = [:]
        pullToNextPage = []
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                        baselineOffset: UnsafeMutablePointer<CGFloat>,
                        in textContainer: NSTextContainer,
                        forGlyphRange glyphRange: NSRange) -> Bool {
        guard isActive || !columnPlacements.isEmpty else { return false }
        // COLUMNS FIRST, and then nothing else for that line. A line inside a multi-column run is
        // placed by a different rule from the one below — the between-page rule pushes a line DOWN
        // to the next sheet, while a column break sends it back UP and across — and letting both
        // touch one line would make the result depend on which ran last.
        if !columnPlacements.isEmpty,
           placeInColumn(layoutManager, glyphRange, lineFragmentRect, lineFragmentUsedRect) {
            return true
        }
        guard isActive else { return false }
        // A line inside an `NSTextTableBlock` owns its geometry through the table (invariants 39/50)
        // and is never shifted where it stands — SPLITTING a table at a page boundary was measured and
        // is not available to us; see `pushWholeTable`, which moves the table instead.
        let pitch = pageContentHeight + band
        guard pitch > 0 else { return false }
        let rect = lineFragmentRect.pointee
        let insideTable = isInsideTable(layoutManager, glyphRange)
        // Both recorded AFTER whatever this pass does to the line, so a table line's record differs
        // from the finished layout only by the cell's own vertical alignment — which is exactly the
        // difference the piece's inset has to be measured across.
        let tableLine = insideTable
            ? layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil).location
            : nil
        defer { if let tableLine { proposedTableLineTops[tableLine] = lineFragmentRect.pointee.minY } }
        if insideTable {
            if pushWholeTable(layoutManager, glyphRange, rect, pitch,
                              lineFragmentRect, lineFragmentUsedRect) { return true }
            // The one exception, and it is not a softening of the rule above: a piece that fits on NO
            // page cannot be carried anywhere, so leaving it alone leaves its rows in the margin and
            // this class recording a boundary as opened over lines that are still drawn there. Such a
            // piece falls through to the ordinary between-page rule — one line moved at a page
            // boundary, which is what Word does to any row that does not say `w:cantSplit`.
            guard let tableLine, isInsideOversizedPiece(tableLine) else { return false }
            // A run this short is moved WHOLE rather than broken across the gap, so its first line
            // starts the next page even though it would have fitted where it stands.
            if pullToNextPage.contains(tableLine) {
                let page = PageBandLayoutDelegate.page(of: rect.minY, leadingBand: leadingBand,
                                                       pitch: pitch)
                let target = (page + 1) * pitch + leadingBand
                let shift = target - rect.minY
                // Already at a page top: nothing to do, which is what makes this idempotent.
                guard shift > 0.5 else { return false }
                lineFragmentRect.pointee.origin.y += shift
                lineFragmentUsedRect.pointee.origin.y += shift
                shiftCount += 1
                recordBand(page: page, top: rect.minY, target: target)
                return true
            }
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
        // KEEP WITH NEXT — the block's last line is about to end a page, and what follows belongs
        // with it. Moving the whole block down is the only honest answer: shifting just the last
        // line would split the block itself, and leaving it puts a heading alone at the foot of a
        // page. Checked here, where the line that WOULD end the page is still in hand.
        if !keepWithNextRanges.isEmpty, !insideTable {
            let line = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            if let block = keepWithNextRanges.first(where: { line.location >= $0.start && line.location < $0.end }),
               block.start == line.location {
                // Only the block's FIRST line is moved — every later line follows it, the same
                // property the between-page rule relies on. Whether it needs moving is decided by
                // where the block's own end would land, which is one page-crossing check on the
                // line that starts it plus the block's height, and layout has not measured that
                // yet. So the cheap, correct approximation: if this first line would sit in the
                // LAST line-height of its page, the block starts the next page instead.
                let page = ((rect.minY - leadingBand) / pitch).rounded(.down)
                let textBottom = self.textBottom(ofPage: page)
                if (rect.maxY - leadingBand) > textBottom - rect.height {
                    let target = (page + 1) * pitch + leadingBand
                    let shift = target - rect.minY
                    if shift > 0.5 {
                        lineFragmentRect.pointee.origin.y += shift
                        lineFragmentUsedRect.pointee.origin.y += shift
                        shiftCount += 1
                        recordBand(page: page, top: rect.minY, target: target)
                        return true
                    }
                }
            }
        }
        // THE DOCUMENT'S OWN BREAK, before the "does it fit" rule: this line starts a page because
        // the author said so, not because the previous one ran out of room. Table lines are excluded
        // above (they own their geometry through the table), which is also why this sits after that
        // guard rather than at the top.
        if !documentPageBreaks.isEmpty, !insideTable {
            let line = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil).location
            if documentPageBreaks.contains(line) {
                let page = PageBandLayoutDelegate.page(of: rect.minY, leadingBand: leadingBand, pitch: pitch)
                let target = (page + 1) * pitch + leadingBand
                let shift = target - rect.minY
                // Already at a page top — the break has nothing to do, which is what makes a second
                // layout pass over the same text idempotent.
                if shift > 0.5 {
                    lineFragmentRect.pointee.origin.y += shift
                    lineFragmentUsedRect.pointee.origin.y += shift
                    shiftCount += 1
                    recordBand(page: page, top: rect.minY, target: target)
                    return true
                }
            }
        }
        let page = ((rect.minY - leadingBand) / pitch).rounded(.down)
        let textBottom = self.textBottom(ofPage: page)
        // What has to fit is the line's GLYPHS. A paragraph that carries its pitch as
        // `lineSpacing` (the HWP model, `OfficeTextBuilder.applyLineModel`) keeps that spacing
        // under the glyphs, and 한글 lets it run into the band: on the reference manual the last
        // line of a page sits with its glyph bottom 0.5pt above the text bottom and its spacing
        // 8pt below it. Fitting the whole box pushed such a line to the next page — one line in
        // three pages, 23pt of foot gap per page on average (invariant 161).
        let trailing = trailingLineSpacing(layoutManager, glyphRange)
        guard (rect.maxY - trailing - leadingBand) > textBottom else { return false }
        let target = (page + 1) * pitch + leadingBand
        let shift = target - rect.minY
        lineFragmentRect.pointee.origin.y += shift
        lineFragmentUsedRect.pointee.origin.y += shift
        shiftCount += 1
        // This line begins page `page + 1`, so the boundary that was just opened is page `page`'s.
        // Page 0's own first line falls out of the same formula as `page == -1` (see above), and a
        // negative index is not a between-page boundary at all — the leading band is its own
        // mechanism — so it is deliberately not recorded.
        // The gap is what the shift OPENED: from where this line was GOING to start to where it now
        // does. `rect` is the local copy taken before the mutation, so it still holds the proposed
        // position — which is also the bottom of the previous page's last line, however far that page
        // overran.
        recordBand(page: page, top: rect.minY, target: target)
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
        let textBottom = self.textBottom(ofPage: page)
        // Already fits where it stands: nothing to do, and this is what makes the rule idempotent —
        // a table that was moved once lands at a page top and then declines to move again.
        guard (visualTop - leadingBand + metrics.height) > textBottom else { return false }
        let target = (page + 1) * pitch + leadingBand
        let shift = target - visualTop
        guard shift > 0 else { return false }
        lineFragmentRect.pointee.origin.y += shift
        lineFragmentUsedRect.pointee.origin.y += shift
        shiftCount += 1
        recordBand(page: page, top: visualTop, target: target)
        return true
    }

    /// Which page a point sits on — with a hair of tolerance, which is load-bearing rather than
    /// tidy. A piece moved to a page top lands at EXACTLY `page × pitch + leadingBand`, and that
    /// number does not survive the division: measured, a line placed at page 6's top came back as
    /// `5051.279999999` against a pitch product of `5051.28`, so a bare `floor` called it page 5 and
    /// the rule then judged it against page 5's bottom — a piece that had just been moved correctly
    /// read as still overrunning, and the settle could not converge.
    /// Height reserved at the FOOT of a page for the footnotes cited on it, keyed by page — empty
    /// for every document that cites none, which leaves every number below exactly what it was.
    ///
    /// Set by the settle loop, never by layout: which notes a page cites is only knowable once the
    /// page has been laid out, and reserving room for them moves the very markers that decided it
    /// (invariant 98). `FootnoteBandSettle` owns when that stops.
    var noteBands: [Int: CGFloat] = [:]

    /// The character ranges this document typesets in columns, and what each says.
    ///
    /// Keyed by CHARACTER range rather than by a `y`, deliberately: a column transform rewrites the
    /// very coordinate a `y`-keyed lookup would use, so the run a line belongs to has to be decided
    /// by something the transform cannot move. It also means these need no settling — unlike a note
    /// band (invariant 98), which document text is in columns is known before any layout runs.
    var columnRuns: [(range: NSRange, layout: OfficeColumnLayout)] = []
    /// How many lines the column rule has moved — the same shape as `shiftCount`, so a test can
    /// assert something DID happen without hand-deriving where every line went.
    private(set) var columnMoveCount = 0

    /// The column declaration in force at a character location, if any.
    func columnLayout(atCharacter location: Int) -> OfficeColumnLayout? {
        guard !columnRuns.isEmpty else { return nil }
        return columnRuns.first { NSLocationInRange(location, $0.range) }?.layout
    }

    /// THE lowest a body line may reach on a given page — its sheet's text bottom, less whatever
    /// that page reserves for notes.
    ///
    /// One definition for all three rules that ask (the keep-with-next check, the between-page
    /// shift, and the table push). They were three copies of `page × pitch + pageContentHeight`
    /// before a note band could shorten any of them, and three copies of a number that now VARIES
    /// per page is three chances to disagree about where a page ends — which shows up as a line
    /// drawn over a footnote rather than as a failed check.
    func textBottom(ofPage page: CGFloat) -> CGFloat {
        PagePagination.textBottom(ofPage: page, pageContentHeight: pageContentHeight,
                                  band: band, noteBands: noteBands)
    }

    /// Put this line where the column map says it goes. Returns whether the line was moved.
    ///
    /// A pure lookup by CHARACTER LOCATION — see `ColumnGeometry.placements` for why the column
    /// cannot be re-derived from the laid-out rect, and why that makes this idempotent for free.
    private func placeInColumn(_ layoutManager: NSLayoutManager, _ glyphRange: NSRange,
                               _ lineFragmentRect: UnsafeMutablePointer<NSRect>,
                               _ lineFragmentUsedRect: UnsafeMutablePointer<NSRect>) -> Bool {
        guard !columnPlacements.isEmpty, glyphRange.length > 0 else { return false }
        let chars = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard let target = columnPlacements[chars.location] else { return false }
        let rect = lineFragmentRect.pointee
        guard abs(rect.minX - target.x) > 0.01 || abs(rect.minY - target.y) > 0.01 else { return false }
        let dx = target.x - rect.minX
        lineFragmentRect.pointee.origin.x = target.x
        lineFragmentRect.pointee.origin.y = target.y
        lineFragmentUsedRect.pointee.origin.x += dx
        lineFragmentUsedRect.pointee.origin.y = target.y
        columnMoveCount += 1
        return true
    }

    /// Where each line of a columned run goes, keyed by the line's first character.
    ///
    /// Measured once from the run laid out as a single tall stack (`DocumentWindowController.
    /// settleColumnPlacements`) and then fixed: what a line's column IS cannot be read back out of
    /// the page once the lines have been moved, because the typesetter re-derives `x` per line and
    /// so erases the only evidence.
    var columnPlacements: [Int: (x: CGFloat, y: CGFloat)] = [:]

    /// The page boundaries a COLUMN placement crosses, which nothing else can see.
    ///
    /// `openedBoundaries` is filled by the between-page rule, and a line the column map claims never
    /// reaches it — `placeInColumn` runs FIRST and returns, deliberately, because the two rules move
    /// a line in opposite directions and letting both touch one line would make the result depend on
    /// which ran last. So a columned run opens no boundary at all, and
    /// `PagePagination.joiningUnopenedBoundaries` reads that as "layout never broke here" and welds
    /// the whole run into one enormous sheet: measured on `2025_행정업무운영편람_최종.hwp`, whose
    /// two-column appendix runs from character 235,989 to the end of the document — every one of its
    /// last 21 boundaries unopened, and the tail drawn as two sheets 11 and 10 pages tall.
    ///
    /// Filled by `DocumentWindowController.settleColumnPlacements` from the finished map rather than
    /// per line, for the same reason the map itself is: the placement is decided ONCE and is the only
    /// authority on which page a columned line is on. Set alongside `columnPlacements` and cleared
    /// with it — carrying it into a different document would open boundaries that document never had.
    var columnOpenedBoundaries: Set<Int> = []

    /// The width the columns are measured across — the body width this document is laid out in.
    /// Set beside the other page numbers; `0` disables the column rule entirely, which is what a
    /// document with no column declaration wants anyway.
    var columnBodyWidth: CGFloat = 0

    static func page(of y: CGFloat, leadingBand: CGFloat, pitch: CGFloat) -> CGFloat {
        (((y - leadingBand) / pitch) + 1e-6).rounded(.down)
    }

    /// A paragraph built inside a table cell carries its `NSTextTableBlock` on `paragraphStyle.
    /// textBlocks` (`TableBlockBuilder`'s `ps.textBlocks = [block]`) — the same signal every other
    /// table-aware pass in this reader keys off. Checked at the glyph range's first character only,
    /// matching the rest of the codebase's per-paragraph attribute reads (e.g.
    /// `drawMDDecorations`'s `charRange.location`): a line fragment never spans two paragraphs.
    /// The `lineSpacing` the line's paragraph style puts UNDER it — the part of a fragment that
    /// may hang past the foot of a page. Zero for every style that carries no spacing.
    private func trailingLineSpacing(_ layoutManager: NSLayoutManager, _ glyphRange: NSRange) -> CGFloat {
        guard let storage = layoutManager.textStorage else { return 0 }
        let chars = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard chars.location < storage.length,
              let style = storage.attribute(.paragraphStyle, at: chars.location,
                                            effectiveRange: nil) as? NSParagraphStyle else { return 0 }
        return max(0, style.lineSpacing)
    }

    private func isInsideTable(_ layoutManager: NSLayoutManager, _ glyphRange: NSRange) -> Bool {
        guard glyphRange.length > 0, let storage = layoutManager.textStorage else { return false }
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard charRange.location >= 0, charRange.location < storage.length else { return false }
        guard let style = storage.attribute(.paragraphStyle, at: charRange.location, effectiveRange: nil)
                as? NSParagraphStyle else { return false }
        return !style.textBlocks.isEmpty
    }
}
