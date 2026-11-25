import XCTest
import AppKit
@testable import FastDocReader

/// header-footer-design.md build steps 4 ("RESERVE THE BAND") and 5 ("PAINT THE BAND"). Four layers,
/// each proving a different half of the claim:
///
///  1. `PageBandGeometry.bandHeight` — the MEASUREMENT (header/footer built through the real
///     `OfficeTextBuilder`, laid out in an isolated stack — never the document's declared offset).
///  2. `PageBandLayoutDelegate` — the ALGORITHM in isolation, productionising
///     `PageBandShiftSpikeTests` verbatim (rect-derived page, not a counter) plus the one thing the
///     spike didn't have to model: a table line must never be shifted.
///  3. The REAL production stack (`MarkdownDocument` + `DocumentWindowController`) — proving the two
///     are actually wired together for a paged office document, and that every other document kind
///     (no header/footer, and markdown) is provably untouched.
///  4. Step 5's own wiring — `DocumentWindowController.pageBandContent`, and that `--extract` cannot
///     see any of it (invariant 40). The DECISIONS `PageBandPainter` makes (which entry applies, what
///     a PAGE/NUMPAGES field shows) are tested as pure functions in `PageBandPainterTests`, not here.
final class PageBandReservationTests: XCTestCase {
    private let theme = RenderTheme.current(size: 11)

    /// This file measures the BAND MECHANISM — what a running header and footer reserve — and every
    /// number in it predates the View menu's page options. Those options can add to the band (the
    /// outline reserves the document's own margins plus a desk between sheets even with nothing
    /// drawn in them), so without pinning them here the file's numbers would depend on a stored
    /// preference: the suite would read differently for a developer who had switched the outline off,
    /// and the shipped default alone would move nine of these assertions.
    ///
    /// Pinned to the shape this file was written against — no sheets, header and footer on — so it
    /// keeps guarding exactly the property it always did. The outline's own effects are
    /// `PageViewOptionsTests`' subject.
    override func setUp() {
        super.setUp()
        // The outline is the MASTER: a header and footer only exist alongside it, so "band, no
        // sheets" — the shape this suite used to pin — is no longer a configuration the reader has.
        PageViewOptionsStore.startingOptions = PageViewOptions(outline: true)
    }

    override func tearDown() {
        PageViewOptionsStore.reset()
        super.tearDown()
    }

    // MARK: - 1. PageBandGeometry (measurement)

    func testBandHeightIsZeroWithNoHeaderAndNoFooter() {
        let band = PageBandGeometry.bandHeight(headers: [], footers: [], theme: theme,
                                               columnWidth: 400, documentDefaultFontSize: 11,
                                               pageContentWidth: 400)
        XCTAssertEqual(band, 0, "no header/footer at all must reserve nothing")
    }

    func testBandHeightIsZeroWhenTheOnlyEntryHasNoBlocks() {
        // Exactly the synthesized blank first-page header/footer OOXML creates under `w:titlePg`
        // (header-footer-design.md §2d) — an entry exists but carries no content to measure.
        let blank = OfficeHeaderFooter(appliesTo: .defaultPages, blocks: [])
        let band = PageBandGeometry.bandHeight(headers: [blank], footers: [blank], theme: theme,
                                               columnWidth: 400, documentDefaultFontSize: 11,
                                               pageContentWidth: 400)
        XCTAssertEqual(band, 0, "a present-but-blank header/footer must still reserve nothing")
    }

    /// PRESENT, PRESENT-BUT-EMPTY, ABSENT — three answers, and only the first reserves anything.
    /// `w:titlePg`'s deliberately blank entry arrives with NO blocks and was always handled; this is
    /// the same thing one level deeper, and it is not exotic: **26 of the 94 real HWP/HWPX documents
    /// that declare a header or footer at all — 28% — declare one made of nothing but empty
    /// paragraphs**, and the reference report's own `.odt` declares exactly such a first-page header.
    /// Each of them opened a band on every page and drew nothing in it.
    func testAnEntryOfNothingButEmptyParagraphsReservesNothing() {
        let blank = OfficeHeaderFooter(appliesTo: .defaultPages,
                                       blocks: [.paragraph(spans: []), .paragraph(spans: [])])
        let band = PageBandGeometry.bandHeight(headers: [blank], footers: [], theme: theme,
                                               columnWidth: 400, documentDefaultFontSize: 11,
                                               pageContentWidth: 400)
        XCTAssertEqual(band, 0, "a header that builds to nothing must not reserve a band to put it in")
    }

    /// The counterweight, and why the test is on what it BUILDS rather than on whether there is text:
    /// a header that is only a logo draws no glyph at all and must still reserve. An attachment is
    /// `U+FFFC`, which is not whitespace.
    func testAPictureOnlyHeaderStillReserves() {
        let logo = OfficeHeaderFooter(appliesTo: .defaultPages,
                                      blocks: [.image(id: "logo", size: CGSize(width: 60, height: 20))])
        XCTAssertGreaterThan(
            PageBandGeometry.bandHeight(headers: [logo], footers: [], theme: theme, columnWidth: 400,
                                        documentDefaultFontSize: 11, pageContentWidth: 400), 0)
    }

    /// The other thing that draws without a glyph: a paragraph whose whole content is a RULE or a
    /// shaded band. The blocks are asked directly for those, because nothing reaches the built string.
    func testAHeaderThatIsOnlyARuleStillReserves() {
        let rule = OfficeHeaderFooter(
            appliesTo: .defaultPages,
            blocks: [.paragraph(spans: [], format: ParagraphFormat(borderWidth: 1, borderEdges: .bottom))])
        XCTAssertGreaterThan(
            PageBandGeometry.bandHeight(headers: [rule], footers: [], theme: theme, columnWidth: 400,
                                        documentDefaultFontSize: 11, pageContentWidth: 400), 0)
    }

    /// The single-source predicate the leading-band gate and this measurement now share, so the two
    /// cannot drift into disagreeing about whether a document has a header.
    func testEntryDrawsAnswersTheSameQuestionForAllThreeStates() {
        func draws(_ e: OfficeHeaderFooter?) -> Bool {
            PageBandGeometry.entryDraws(e, theme: theme, columnWidth: 400,
                                        documentDefaultFontSize: 11, pageContentWidth: 400)
        }
        XCTAssertFalse(draws(nil), "absent")
        XCTAssertFalse(draws(OfficeHeaderFooter(appliesTo: .defaultPages, blocks: [])), "blank entry")
        XCTAssertFalse(draws(OfficeHeaderFooter(appliesTo: .defaultPages,
                                                blocks: [.paragraph(spans: [])])), "empty paragraphs")
        XCTAssertTrue(draws(OfficeHeaderFooter(appliesTo: .defaultPages,
                                               blocks: [.paragraph(spans: [Span(text: "Title")])])))
    }

    /// With no margins declared, the band is exactly what this reader must DRAW — the two sides,
    /// nothing added. Checked algebraically rather than against a hardcoded point value (brittle to
    /// font metrics): `both == headerOnly + footerOnly`.
    ///
    /// It used to be `+ 12pt`, a "space between pages" the reader invented; the document's own
    /// margins say it instead now (`testBandTakesTheDocumentsOwnMarginsWhenItDeclaredThem`), and a
    /// document that declared none gets no invented padding at all.
    func testBandHeightIsExactlyHeaderPlusFooterWhenNoMarginsAreDeclared() {
        let header = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Document Title")])])
        let footer = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Page footer text")])])
        let headerOnly = PageBandGeometry.bandHeight(headers: [header], footers: [], theme: theme,
                                                      columnWidth: 400, documentDefaultFontSize: 11,
                                                      pageContentWidth: 400)
        let footerOnly = PageBandGeometry.bandHeight(headers: [], footers: [footer], theme: theme,
                                                      columnWidth: 400, documentDefaultFontSize: 11,
                                                      pageContentWidth: 400)
        let both = PageBandGeometry.bandHeight(headers: [header], footers: [footer], theme: theme,
                                               columnWidth: 400, documentDefaultFontSize: 11,
                                               pageContentWidth: 400)
        XCTAssertGreaterThan(headerOnly, 0, "must include real header height")
        XCTAssertGreaterThan(footerOnly, 0, "must include real footer height")
        XCTAssertEqual(both, headerOnly + footerOnly, accuracy: 0.5)
    }

    /// invariant 57: the document states the space between two pages — its bottom margin plus the
    /// next page's top margin — and a running header/footer lives INSIDE those margins rather than
    /// on top of them. So the declared pair wins whenever it is roomy enough, and the drawn height
    /// wins only when this reader would otherwise overlap the body.
    func testBandTakesTheDocumentsOwnMarginsWhenItDeclaredThem() {
        let header = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Document Title")])])
        let drawn = PageBandGeometry.bandHeight(headers: [header], footers: [], theme: theme,
                                                columnWidth: 400, documentDefaultFontSize: 11,
                                                pageContentWidth: 400)
        // Roomy margins (the ordinary case — a 1.5cm/1.5cm A4 is 85pt against a ~26pt header).
        let roomy = PageBandGeometry.bandHeight(headers: [header], footers: [], theme: theme,
                                                columnWidth: 400, documentDefaultFontSize: 11,
                                                pageContentWidth: 400,
                                                pageMarginTop: 60, pageMarginBottom: 40)
        XCTAssertEqual(roomy, 100, accuracy: 0.01, "the paper's own 60+40 is the space between pages")
        XCTAssertGreaterThan(roomy, drawn, "and it is roomier than the header alone needs")

        // Margins too tight for what we draw: expand to fit rather than paint over the body.
        let tight = PageBandGeometry.bandHeight(headers: [header], footers: [], theme: theme,
                                                columnWidth: 400, documentDefaultFontSize: 11,
                                                pageContentWidth: 400,
                                                pageMarginTop: 1, pageMarginBottom: 1)
        XCTAssertEqual(tight, drawn, accuracy: 0.01,
                       "2pt of declared margin cannot hold the header this reader draws")
    }

    /// header-footer-design.md §7: even/odd headers are deferred past v1. An `.evenPages`-only
    /// entry (no `.defaultPages` entry present at all) must still be measured — it is the ONLY
    /// entry there is — via the `entries.first` fallback, not silently treated as zero.
    func testANonDefaultEntryIsStillMeasuredWhenItIsTheOnlyOne() {
        let evenOnly = OfficeHeaderFooter(appliesTo: .evenPages,
                                          blocks: [.paragraph(spans: [Span(text: "Even page header")])])
        let band = PageBandGeometry.bandHeight(headers: [evenOnly], footers: [], theme: theme,
                                               columnWidth: 400, documentDefaultFontSize: 11,
                                               pageContentWidth: 400)
        XCTAssertGreaterThan(band, 0)
    }

    /// THE REPORTED SYMPTOM: "현재 홀수쪽, 짝수쪽의 여백이 다름". The gap layout opens is the
    /// document's own margin PLUS whatever room the previous page's last line left unused, and that
    /// leftover varies with paragraph spacing, headings and tables. Centring the header and footer in
    /// halves of that gap therefore moved them a few points page to page. Anchored to the SHEET's own
    /// edge, using the distances the document states (`w:pgMar/@w:header`/`@w:footer`), the placement
    /// is identical on every page — and the leftover shows where it truly is, as white space above the
    /// footer, which is what a short page looks like in Word.
    func testHeaderAndFooterSitAtTheirDeclaredDistanceFromTheSheetEdgeOnEveryPage() {
        let content: CGFloat = 600, marginTop: CGFloat = 40, marginBottom: CGFloat = 30
        let band = marginTop + marginBottom
        let pitch = content + band
        let headerDistance: CGFloat = 12, footerDistance: CGFloat = 10
        let headerHeight: CGFloat = 14, footerHeight: CGFloat = 14

        /// Page `n`'s boundary, with `leftover` points of its own page left unused by its last line —
        /// the thing that used to move the header and footer.
        func offsets(page: Int, leftover: CGFloat) -> (footerAboveEdge: CGFloat, headerBelowEdge: CGFloat) {
            let gridTop = CGFloat(page) * pitch + content
            let gap = (top: gridTop - leftover, height: band + leftover)
            let edge = try! XCTUnwrap(PageBandPainter.sheetEdge(gridTop: gridTop, gap: gap,
                                                               bottomMargin: marginBottom))
            let footer = PageBandPainter.footerTop(gap: gap, sheetEdge: edge,
                                                  distance: footerDistance, footerHeight: footerHeight)
            let header = PageBandPainter.headerTop(gap: gap, sheetEdge: edge,
                                                   distance: headerDistance, headerHeight: headerHeight)
            return (edge - (footer + footerHeight), header - edge)
        }

        // Three pages, each leaving a DIFFERENT amount of its own page unused — which is the real
        // shape of a document, and what made this drift.
        let a = offsets(page: 0, leftover: 0)
        let b = offsets(page: 1, leftover: 7.5)
        let c = offsets(page: 2, leftover: 17)
        for (label, o) in [("page 0", a), ("page 1", b), ("page 2", c)] {
            XCTAssertEqual(o.footerAboveEdge, footerDistance, accuracy: 0.01,
                           "\(label): the footer sits its own declared distance above the sheet edge")
            XCTAssertEqual(o.headerBelowEdge, headerDistance, accuracy: 0.01,
                           "\(label): and the header its own distance below it")
        }
    }

    /// A document that states no distances keeps the halves it used before they were parsed — every
    /// ODT and HWP document today (invariant 37's "the document said nothing → unchanged").
    func testAnUndeclaredDistanceFallsBackToTheHalvesOfTheGap() {
        let gap = (top: 100 as CGFloat, height: 80 as CGFloat)
        XCTAssertNil(PageBandPainter.sheetEdge(gridTop: 100, gap: gap, bottomMargin: nil))
        XCTAssertEqual(PageBandPainter.footerTop(gap: gap, sheetEdge: nil, distance: nil, footerHeight: 20),
                       110, accuracy: 0.01, "centred in the upper half")
        XCTAssertEqual(PageBandPainter.headerTop(gap: gap, sheetEdge: nil, distance: nil, headerHeight: 20),
                       150, accuracy: 0.01, "centred in the lower half")
    }

    /// Neither side may ever be painted outside the gap layout actually opened — the clamp that keeps
    /// a page whose last line overran (a table) from being drawn over.
    func testPlacementIsClampedInsideTheOpenedGap() {
        let gap = (top: 100 as CGFloat, height: 40 as CGFloat)
        // A footer distance larger than the gap itself would place it above the previous page's text.
        XCTAssertEqual(PageBandPainter.footerTop(gap: gap, sheetEdge: 120, distance: 500, footerHeight: 14),
                       gap.top, accuracy: 0.01)
        // A header distance larger than the gap would place it on its own page's first line.
        XCTAssertEqual(PageBandPainter.headerTop(gap: gap, sheetEdge: 120, distance: 500, headerHeight: 14),
                       gap.top + gap.height - 14, accuracy: 0.01)
        // And the sheet edge itself never leaves the gap.
        XCTAssertEqual(PageBandPainter.sheetEdge(gridTop: 0, gap: gap, bottomMargin: 0), gap.top)
        XCTAssertEqual(PageBandPainter.sheetEdge(gridTop: 1000, gap: gap, bottomMargin: 0),
                       gap.top + gap.height)
    }

    /// The painter's own half of the gate — `PageBandPainter.bandExists(after:in:)`, the SAME function
    /// both between-page arms of `draw` call, not a re-implementation of its condition here. (An
    /// earlier version of this test did re-implement it and passed with the gate removed from the
    /// painter entirely — invariant 30's lesson, self-inflicted.)
    func testThePainterSkipsABoundaryLayoutDidNotOpen() {
        func content(_ openedBoundaries: Set<Int>?) -> PageBandContent {
            var c = PageBandContent(headers: [], footers: [], theme: theme, columnWidth: 400,
                                    documentDefaultFontSize: 11, pageContentWidth: 400,
                                    headerHeight: 20, footerHeight: 0,
                                    leadingBand: 0, trailingBand: 0)
            c.openedBoundaries = openedBoundaries
            return c
        }
        // No information (a caller that never ran layout) → paint every boundary, exactly as before.
        for page in 0..<3 {
            XCTAssertTrue(PageBandPainter.bandExists(after: page, in: content(nil)))
        }
        XCTAssertTrue(PageBandPainter.bandExists(after: 0, in: content([0, 1, 2])))
        XCTAssertTrue(PageBandPainter.bandExists(after: 2, in: content([0, 1, 2])))
        // Only the open one — the others are inside a table and have no space to paint into.
        XCTAssertTrue(PageBandPainter.bandExists(after: 0, in: content([0])))
        XCTAssertFalse(PageBandPainter.bandExists(after: 1, in: content([0])))
        XCTAssertFalse(PageBandPainter.bandExists(after: 2, in: content([0])))
        // Nothing open at all: a document that is one long table paints nothing over it.
        for page in 0..<3 {
            XCTAssertFalse(PageBandPainter.bandExists(after: page, in: content([])))
        }
    }

    // MARK: - 3. The real production stack (MarkdownDocument + DocumentWindowController)

    private func clearSavedWindowFrame() {
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
    }

    private func silenceResizeNotifications(_ wc: DocumentWindowController) {
        wc.textView.postsFrameChangedNotifications = false
        wc.textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = false
    }

    private func settle(_ wc: DocumentWindowController, windowWidth: CGFloat) {
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: windowWidth, height: 600), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.updateTextInset()
    }

    private func longBody(paragraphs: Int = 30) -> [OfficeBlock] {
        let sentence = "The quick brown fox jumps over the lazy dog near the riverbank at dusk."
        return (0..<paragraphs).map { _ in
            .paragraph(spans: [Span(text: String(repeating: sentence + " ", count: 3))])
        }
    }

    /// Opens a synthetic paged office document — `setOfficeContent` is the same seam
    /// `OfficeDocumentTests`/`PagedZoomTests` drive, independent of any real docx/odt/HWP parser.
    private func openPagedOffice(headers: [OfficeHeaderFooter], footers: [OfficeHeaderFooter],
                                 pageContentHeight: CGFloat, blocks: [OfficeBlock]? = nil)
        throws -> (MarkdownDocument, DocumentWindowController) {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-pageband-\(UUID().uuidString).docx")
        doc.setOfficeContent(
            blocks: blocks ?? longBody(), archive: nil, defaultBodyFontSize: 11,
            pageContentWidth: 400, pageContentHeight: pageContentHeight,
            headers: headers, footers: footers)
        clearSavedWindowFrame()
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        silenceResizeNotifications(wc)
        settle(wc, windowWidth: 800)
        wc.paginateNow()   // the window's own plan arrives on a later run-loop turn
        return (doc, wc)
    }

    private func allLineRects(_ wc: DocumentWindowController) throws -> [NSRect] {
        let layout = try XCTUnwrap(wc.textView.layoutManager)
        let container = try XCTUnwrap(wc.textView.textContainer)
        layout.ensureLayout(for: container)
        var rects: [NSRect] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, _, _ in
            rects.append(rect)
        }
        return rects
    }

    /// THE feature, through the real document → render → layout-manager-delegate path: a paged
    /// office document with a real header AND footer reserves the measured band between pages, and
    /// the reservation lands at the RIGHT y (an exact multiple of the measured band per boundary),
    /// not merely "somewhere".
    ///
    /// Mutation target: in `MarkdownDocument.render(into:)`'s `.office` case, changing the `band`
    /// ternary's true-branch to always `0` (as if `wc.configurePageBand` were never wired to
    /// `PageBandGeometry` at all) makes this fail — `wc.pageBandDelegate.isActive` would be false
    /// and every line would land back at its unpaginated position.
    func testARealPagedDocumentWithAHeaderAndFooterReservesTheMeasuredBandAtPageBoundaries() throws {
        let header = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Running Header")])])
        let footer = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Running Footer")])])
        let (doc, wc) = try openPagedOffice(headers: [header], footers: [footer], pageContentHeight: 150)
        _ = doc

        XCTAssertTrue(wc.isPaged, "precondition: this document declared a page width")
        XCTAssertTrue(wc.pageBandDelegate.isActive, "a header+footer must activate the reservation")
        XCTAssertGreaterThan(wc.pageBandDelegate.band, 0)

        let rects = try allLineRects(wc)
        XCTAssertGreaterThan(wc.pageBandDelegate.shiftCount, 0,
                             "this document is long enough that it must cross at least one page boundary")

        // Translated by `leadingBand` exactly as `PageBandLayoutDelegate.shouldSetLineFragmentRect`
        // itself is (its own doc: "just translated by leadingBand and back again") — this fixture's
        // header applies to page 0 too (no separate `.firstPage` entry), so `leadingBand` is the
        // measured header height here, not zero.
        let pitch = wc.pageBandDelegate.pageContentHeight + wc.pageBandDelegate.band
        let leading = wc.pageBandDelegate.leadingBand
        for rect in rects {
            let page = ((rect.minY - leading) / pitch).rounded(.down)
            XCTAssertLessThanOrEqual(rect.maxY, page * pitch + leading + wc.pageBandDelegate.pageContentHeight + 0.5,
                                     "a line must never run into the space reserved for the header/footer band")
        }
    }

    /// "A document with no header/footer is unchanged" — same body, same page height, headers/
    /// footers both empty. Every consecutive pair of lines must be exactly contiguous (no page-grid
    /// snapping at all), proving the delegate is a true no-op rather than merely "close enough".
    ///
    /// Mutation target: `PageBandLayoutDelegate.isActive`'s `band > 0` half of the condition —
    /// dropping it (leaving only `pageContentHeight > 0`) makes this fail, because lines would then
    /// snap to a zero-gap page grid the moment any straddled a boundary, producing a jump even
    /// though nothing should have moved.
    func testARealDocumentWithNoHeaderOrFooterIsLaidOutExactlyAsBefore() throws {
        // Nothing to reserve means the OUTLINE is off too — with it on, the desk between
        // sheets is reserved whether or not there is a header (invariant 60c).
        PageViewOptionsStore.startingOptions = PageViewOptions(outline: false)
        let (_, wc) = try openPagedOffice(headers: [], footers: [], pageContentHeight: 150)

        XCTAssertTrue(wc.isPaged, "precondition: this document is still paged (page WIDTH is what makes it so)")
        XCTAssertFalse(wc.pageBandDelegate.isActive, "no header/footer must never activate the reservation")
        XCTAssertEqual(wc.pageBandDelegate.band, 0)
        XCTAssertEqual(wc.pageBandDelegate.shiftCount, 0)

        let rects = try allLineRects(wc)
        XCTAssertGreaterThan(rects.count, 10, "precondition: enough lines for a jump to be detectable")
        for i in 1..<rects.count {
            XCTAssertEqual(rects[i].minY, rects[i - 1].maxY, accuracy: 0.5,
                           "line \(i) is not contiguous with its predecessor — something shifted it")
        }
    }

    /// Markdown never reaches `officePageContentHeight`/`officeHeaders`/`officeFooters` at all
    /// (they default to nil/empty for every non-office kind), so `configurePageBand` is never even
    /// called for it — proven directly against the one flag every effect in the delegate gates on.
    func testAMarkdownDocumentNeverActivatesTheReservation() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-pageband-md-\(UUID().uuidString).md")
        let source = String(repeating: "A line of ordinary markdown text.\n\n", count: 40)
        try Data(source.utf8).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        let doc = MarkdownDocument()
        doc.fileURL = temp
        try doc.read(from: Data(source.utf8), ofType: "public.plain-text")
        clearSavedWindowFrame()
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        silenceResizeNotifications(wc)
        settle(wc, windowWidth: 800)

        XCTAssertFalse(wc.isPaged)
        XCTAssertFalse(wc.pageBandDelegate.isActive)
        XCTAssertEqual(wc.pageBandDelegate.pageContentHeight, 0)
        XCTAssertEqual(wc.pageBandDelegate.band, 0)
        XCTAssertEqual(wc.pageBandDelegate.shiftCount, 0)
    }

    // MARK: - 4. Painting (build step 5) — wiring only; DECISIONS are PageBandPainterTests' job

    /// A paged document with a real header AND footer must come out of `render(into:)` with
    /// `pageBandContent` populated — the same render call that activates `pageBandDelegate` also
    /// hands the painter what it needs, from the SAME measurement (`PageBandGeometry.measure`).
    ///
    /// Mutation target: in `MarkdownDocument.render(into:)`'s `.office` case, changing the `sides`
    /// ternary's true-branch to `PageBandGeometry.Sides(header: 0, footer: 0, band: 0)` unconditionally
    /// (as if step 5 were never wired to the measurement at all) makes this fail — `wc.pageBandContent`
    /// would be `nil` even though a header and footer were declared.
    func testARealPagedDocumentWithAHeaderAndFooterHasPaintContentWired() throws {
        let header = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Running Header")])])
        let footer = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Running Footer")])])
        let (_, wc) = try openPagedOffice(headers: [header], footers: [footer], pageContentHeight: 150)

        let content = try XCTUnwrap(wc.pageBandContent, "a header+footer document must get paint content")
        XCTAssertEqual(content.headers, [header])
        XCTAssertEqual(content.footers, [footer])
        XCTAssertGreaterThan(content.headerHeight, 0)
        XCTAssertGreaterThan(content.footerHeight, 0)
        // Identity with the reservation: the SAME two heights step 4 measured (via
        // `PageBandGeometry.measure`) must be what step 5 paints with — not a second, independently
        // measured pair that could silently disagree with the space actually reserved.
        // (This fixture declares no page margins, so the band IS the two drawn heights — see
        // `testBandTakesTheDocumentsOwnMarginsWhenItDeclaredThem` for the case where the paper's own
        // margins are roomier and win instead.)
        XCTAssertEqual(content.headerHeight + content.footerHeight + RenderTheme.pageDeskGap,
                       wc.pageBandDelegate.band, accuracy: 0.01,
                       "the band is the two drawn heights plus the desk the outline reserves")
    }

    /// "A document with no header/footer is unchanged" — step 5's own half of that claim:
    /// `pageBandContent` must be `nil`, not merely empty, so `ReaderTextView.drawBackground` skips
    /// the paint pass entirely rather than iterating over nothing.
    ///
    /// Mutation target: `DocumentWindowController.configurePageBand`'s `band > 0 ? ... : nil`
    /// ternary — replacing the `nil` branch with an always-populated (but empty) `PageBandContent`
    /// would still cost an allocation and a needless per-draw iteration.
    func testARealDocumentWithNoHeaderOrFooterHasNoPaintContentEither() throws {
        // Nothing to reserve means the OUTLINE is off too — with it on, the desk between
        // sheets is reserved whether or not there is a header (invariant 60c).
        PageViewOptionsStore.startingOptions = PageViewOptions(outline: false)
        let (_, wc) = try openPagedOffice(headers: [], footers: [], pageContentHeight: 150)
        XCTAssertNil(wc.pageBandContent)
    }

    /// Markdown never reaches any of this — same precondition `testAMarkdownDocumentNeverActivatesThe
    /// Reservation` checks for the layout delegate, checked here for the paint content too.
    func testAMarkdownDocumentNeverGetsPaintContentEither() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-pageband-paint-md-\(UUID().uuidString).md")
        let source = String(repeating: "A line of ordinary markdown text.\n\n", count: 10)
        try Data(source.utf8).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        let doc = MarkdownDocument()
        doc.fileURL = temp
        try doc.read(from: Data(source.utf8), ofType: "public.plain-text")
        clearSavedWindowFrame()
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        silenceResizeNotifications(wc)
        settle(wc, windowWidth: 800)

        XCTAssertNil(wc.pageBandContent)
    }

    /// invariant 40: running header/footer content is presentation and must never reach `--extract`.
    /// `OfficeMarkdownSerializer.serialize` takes only `[OfficeBlock]` — it cannot see `headers`/
    /// `footers` even in principle, since its signature never accepts them — so this proves the
    /// STRUCTURAL guarantee directly rather than trusting the signature by inspection alone: the
    /// same body blocks serialize identically whether or not the read result also carried a header
    /// and footer.
    func testHeaderAndFooterContentNeverReachesExtract() {
        let body: [OfficeBlock] = [
            .heading(level: 1, spans: [Span(text: "Report Title")]),
            .paragraph(spans: [Span(text: "Ordinary body text.")]),
        ]
        let withoutHeaderFooter = OfficeReadResult(blocks: body)
        let withHeaderFooter = OfficeReadResult(
            blocks: body,
            headers: [OfficeHeaderFooter(appliesTo: .defaultPages,
                                         blocks: [.paragraph(spans: [Span(text: "Running Header")])])],
            footers: [OfficeHeaderFooter(appliesTo: .defaultPages,
                                         blocks: [.paragraph(spans: [Span(text: "Page "),
                                                                     Span(text: "2", pageNumberField: .page)])])])

        let extractWithout = OfficeMarkdownSerializer.serialize(withoutHeaderFooter.blocks)
        let extractWith = OfficeMarkdownSerializer.serialize(withHeaderFooter.blocks)
        XCTAssertEqual(extractWithout, extractWith,
                       "a header/footer (or a live page-number field inside one) must not change --extract")
        XCTAssertFalse(extractWith.contains("Running Header"))
        XCTAssertFalse(extractWith.contains("Running Footer"))
    }

    // MARK: - 5. Edges — page 0's own leading header, the last page's own trailing footer
    //
    // The between-page reservation/painting above (§§1–4) leaves both OUTER edges untouched — there
    // is no line before page 0's first one for a shift to push down, and no line after the last one
    // for the between-page footer arm to draw beneath. `PageBandLayoutDelegate.leadingBand` (a
    // constant shift applied to EVERY line, not just ones that cross a boundary — see that class's
    // own `page == -1` derivation) and `DocumentWindowController.applyTrailingFooterBand` (which
    // widens the layout manager's own "extra line fragment") are the two different mechanisms that
    // close that gap. `DocumentWindowController.configurePageBand` decides the two numbers;
    // `PageBandPainter.draw`'s `page == 0`/`page == total - 1` arms paint into them (already proven
    // wired via `content.leadingBand`/`content.trailingBand` below — pixel drawing itself is left
    // untested per this repo's own constraint, invariant "cannot drive synthetic scroll").

    /// THE DEFECT this section exists to close: a document whose header applies to every page
    /// (including page 0 — no separate `.firstPage` entry, i.e. no `w:titlePg`/OOXML blank-cover
    /// rule) must reserve real space ABOVE its very first line, not just between pages 1→2, 2→3, …
    ///
    /// Mutation target: `DocumentWindowController.configurePageBand`'s `leading` computation —
    /// hardcoding it to `0` regardless of `firstPageHeader` makes this fail (the geometry assertion
    /// below), reproducing the original bug report exactly ("the first page has no header above it").
    func testLeadingHeaderBandIsReservedWhenNoFirstPageEntryIsDeclared() throws {
        let header = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Running Header")])])
        let (_, wc) = try openPagedOffice(headers: [header], footers: [], pageContentHeight: 150)

        XCTAssertGreaterThan(wc.pageBandDelegate.leadingBand, 0,
                             "a header with no separate first-page entry applies to page 0 too")
        let content = try XCTUnwrap(wc.pageBandContent)
        XCTAssertEqual(content.leadingBand, wc.pageBandDelegate.leadingBand,
                       "the delegate (geometry) and the painter (content) must agree on the same reservation")
        XCTAssertEqual(content.leadingBand, content.headerHeight, accuracy: 0.01,
                       "the leading reservation is exactly the measured header height — nothing more")

        // GEOMETRY, not merely the number: the first actual line of BODY text must sit exactly
        // `leadingBand` below where it would with no header at all — proving there is real drawable
        // room above it for the header to paint into, not just a delegate flag that says so.
        let rects = try allLineRects(wc)
        let firstLine = try XCTUnwrap(rects.first)
        XCTAssertEqual(firstLine.minY, wc.pageBandDelegate.leadingBand, accuracy: 0.5,
                       "the document's first line must start exactly one leading band below the top")
    }

    /// The OOXML "no header on the cover" rule (header-footer-design.md §2d): a document that
    /// declares an EXPLICIT, EMPTY `.firstPage` header entry — Word's own way of saying "this
    /// section's first page deliberately has no header" — must reserve NOTHING above page 0, even
    /// though its `.defaultPages` header is real and non-empty (and does get painted from page 1
    /// onward). Reserving space here would grow an unexplained gap above a cover the author
    /// deliberately left bare.
    ///
    /// Mutation target: `configurePageBand`'s `firstPageHeader` gate — replacing
    /// `!(firstPageHeader?.blocks.isEmpty ?? true)` with `firstPageHeader != nil` makes this fail (an
    /// empty-but-present `.firstPage` entry would wrongly count as "there is a cover header").
    func testLeadingHeaderBandIsZeroWhenTheFirstPageIsDeclaredBlank() throws {
        let blankFirstPage = OfficeHeaderFooter(appliesTo: .firstPage, blocks: [])
        let defaultHeader = OfficeHeaderFooter(appliesTo: .defaultPages,
                                               blocks: [.paragraph(spans: [Span(text: "Running Header")])])
        let (_, wc) = try openPagedOffice(headers: [blankFirstPage, defaultHeader], footers: [],
                                          pageContentHeight: 150)

        XCTAssertEqual(wc.pageBandDelegate.leadingBand, 0,
                       "a document that blanked its own cover must not grow an unexplained gap above it")
        let content = try XCTUnwrap(wc.pageBandContent)
        XCTAssertEqual(content.leadingBand, 0)
        // The reservation BETWEEN pages must be entirely unaffected — this document still has a real
        // header from page 1 onward, only page 0's own leading edge is suppressed.
        XCTAssertGreaterThan(content.headerHeight, 0)
        XCTAssertGreaterThan(wc.pageBandDelegate.band, 0)

        // GEOMETRY: with nothing reserved, the very first line sits at its natural, unshifted top —
        // byte-identical to a document with no header at all (`testARealDocumentWithNoHeaderOrFooter
        // IsLaidOutExactlyAsBefore`'s own precondition).
        let rects = try allLineRects(wc)
        let firstLine = try XCTUnwrap(rects.first)
        XCTAssertEqual(firstLine.minY, 0, accuracy: 0.5,
                       "a blanked cover must leave the first line exactly where it would sit with no header")
    }

    /// THE DEFECT's other half: a footer applying to the (unmarked) last page must reserve real
    /// space BELOW the document's very last line — the between-page footer arm only ever draws in
    /// the gap BEFORE the next page, and there is no next page after the last one.
    ///
    /// Mutation target: `applyTrailingFooterBand`'s `width = trailing > 0 ? tc.size.width : 0` /
    /// its `setExtraLineFragmentRect` call — zeroing either makes the frame stop growing, reproducing
    /// "the last page has no footer below it".
    func testTrailingFooterBandIsReservedBelowTheLastLine() throws {
        let footer = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Running Footer")])])
        let (_, wc) = try openPagedOffice(headers: [], footers: [footer], pageContentHeight: 150)

        XCTAssertGreaterThan(wc.pageBandDelegate.trailingBand, 0)
        let content = try XCTUnwrap(wc.pageBandContent)
        XCTAssertEqual(content.trailingBand, content.footerHeight, accuracy: 0.01)

        // GEOMETRY: AppKit already reserves a default one-line-tall "extra line fragment" past the
        // last real line even with no override at all (confirmed by probe before this was built —
        // header-footer-design.md build step 4's own spike), so `applyTrailingFooterBand` REPLACES
        // that default reservation rather than adding on top of it — the before/after DELTA is not
        // the number to check. What must hold is the ABSOLUTE final extent: the last real line's own
        // `maxY` plus exactly `trailingBand`, proving real, drawable room exists below the last line
        // at precisely the height the footer was measured at.
        let layout = try XCTUnwrap(wc.textView.layoutManager)
        let container = try XCTUnwrap(wc.textView.textContainer)
        layout.ensureLayout(for: container)
        let lastGlyph = layout.numberOfGlyphs - 1
        let baseline = lastGlyph >= 0
            ? layout.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil).maxY : 0
        wc.applyTrailingFooterBand()
        let after = layout.usedRect(for: container).height
        XCTAssertEqual(after, baseline + wc.pageBandDelegate.trailingBand, accuracy: 0.5,
                       "the laid-out extent must end exactly one trailing footer band past the last line")
    }

    /// The counterpart to the two tests above: a document with NEITHER a header nor a footer must
    /// reserve nothing at either outer edge, and `applyTrailingFooterBand` — called unconditionally
    /// on every document by `precomputeLayout`'s completion, header/footer or not — must be a true
    /// no-op rather than merely "small".
    func testNeitherEdgeIsReservedWithNoHeaderOrFooter() throws {
        // Nothing to reserve means the OUTLINE is off too — with it on, the desk between
        // sheets is reserved whether or not there is a header (invariant 60c).
        PageViewOptionsStore.startingOptions = PageViewOptions(outline: false)
        let (_, wc) = try openPagedOffice(headers: [], footers: [], pageContentHeight: 150)
        XCTAssertEqual(wc.pageBandDelegate.leadingBand, 0)
        XCTAssertEqual(wc.pageBandDelegate.trailingBand, 0)

        let layout = try XCTUnwrap(wc.textView.layoutManager)
        let container = try XCTUnwrap(wc.textView.textContainer)
        layout.ensureLayout(for: container)
        let before = layout.usedRect(for: container).height
        wc.applyTrailingFooterBand()
        let after = layout.usedRect(for: container).height
        XCTAssertEqual(after, before, accuracy: 0.01, "no footer must reserve no trailing space at all")
    }

    /// `restore(_:)`'s own top-of-document snap (invariant 24) must widen to include a reserved
    /// leading header band — otherwise "restore to the top" lands the reader just past the band,
    /// scrolling the header (and the page's own top margin) out of sight instead of showing them.
    /// Geometry only: the clip view's scroll origin after restoring the very first character with
    /// `offsetFromTop == 0` must be exactly `0`, never `leadingBand` short of it.
    ///
    /// Mutation target: `restore(_:)`'s guard — reverting `textView.textContainerInset.height +
    /// pageBandDelegate.leadingBand` back to `textView.textContainerInset.height` alone makes this
    /// fail the moment `leadingBand > 0`.
    func testRestoringToTheTopShowsTheFullLeadingHeaderBand() throws {
        let header = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Running Header")])])
        let (_, wc) = try openPagedOffice(headers: [header], footers: [], pageContentHeight: 150)
        XCTAssertGreaterThan(wc.pageBandDelegate.leadingBand, 0, "precondition: a real band is reserved")

        // Scroll away from the top first, so restoring is a real move and not a no-op that would
        // pass this test vacuously.
        let sv = try XCTUnwrap(wc.textView.enclosingScrollView)
        sv.contentView.scroll(to: NSPoint(x: 0, y: 400))
        sv.reflectScrolledClipView(sv.contentView)

        wc.restore(DocumentWindowController.ReadingAnchor(char: 0, offsetFromTop: 0))
        XCTAssertEqual(sv.contentView.bounds.origin.y, 0, accuracy: 0.5,
                       "restoring the very first character must land at the true top, header band included")
    }

    /// `scrollCharToTop`'s identical top-of-document snap, same reasoning as the test above.
    ///
    /// Mutation target: `scrollCharToTop`'s guard — same revert as above.
    func testScrollCharToTopShowsTheFullLeadingHeaderBand() throws {
        let header = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Running Header")])])
        let (_, wc) = try openPagedOffice(headers: [header], footers: [], pageContentHeight: 150)
        XCTAssertGreaterThan(wc.pageBandDelegate.leadingBand, 0, "precondition: a real band is reserved")

        let sv = try XCTUnwrap(wc.textView.enclosingScrollView)
        sv.contentView.scroll(to: NSPoint(x: 0, y: 400))
        sv.reflectScrolledClipView(sv.contentView)

        wc.scrollCharToTop(0)
        XCTAssertEqual(sv.contentView.bounds.origin.y, 0, accuracy: 0.5,
                       "scrolling character 0 to the top must land at the true top, header band included")
    }

}
