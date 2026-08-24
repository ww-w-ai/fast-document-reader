import XCTest
import AppKit
@testable import FastDocReader

/// ⌘P for a PAGED document: the printout is the same pages the reader shows, on the paper the
/// document itself declares (`printing-design.md`).
///
/// Every end-to-end case here prints to a real PDF FILE and reads the result back, which is the whole
/// reason this file can exist: an `NSPrintOperation` with `jobDisposition == .save` runs headlessly,
/// with no print panel and no printer, so page COUNT and paper SIZE become ordinary deterministic
/// assertions rather than something judged by looking at a printout. Nothing here uses a stopwatch or
/// a screenshot.
final class PrintPaginationTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-print-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        FontSizeStore.startingSize = FontSizeStore.defaultSize
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        // The page view options are a stored GLOBAL preference, so without this every case here
        // would depend on whatever the developer running the suite last chose in the View menu.
        PageViewOptionsStore.reset()
    }

    override func tearDownWithError() throws {
        FontSizeStore.startingSize = FontSizeStore.defaultSize
        PageViewOptionsStore.reset()
        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: - (1) The geometry, on its own

    /// Sheets tile at exactly the pitch, so page `k`'s paper begins where page `k-1`'s ended — the
    /// property that makes a printout a stack of pages rather than a slowly drifting one.
    func testSheetsTileExactlyAtThePitch() {
        let sheets = PagePagination.sheets(count: 5, width: 595.3, textOriginY: 28, leadingBand: 0,
                                           pitch: 841.9, topMargin: 99.25)
        XCTAssertEqual(sheets.count, 5)
        for (i, s) in sheets.enumerated() {
            XCTAssertEqual(s.height, 841.9, accuracy: 0.001, "sheet \(i) is one pitch tall")
            XCTAssertEqual(s.width, 595.3, accuracy: 0.001)
            if i > 0 {
                XCTAssertEqual(s.minY, sheets[i - 1].maxY, accuracy: 0.001,
                               "sheet \(i) starts exactly where sheet \(i - 1) ended")
            }
        }
    }

    /// A desk gap makes the sheets stop touching WITHOUT moving any of them: each page still begins
    /// exactly one pitch after the last, and the paper is simply shorter by the desk. The first
    /// version had no gap at all, the sheets tiled, the desk fill was covered by the very sheets it
    /// sat behind, and the whole feature drew as a hairline.
    func testADeskGapSeparatesTheSheetsWithoutMovingThem() {
        let tiled = PagePagination.sheets(count: 3, width: 500, textOriginY: 28, leadingBand: 0,
                                          pitch: 800, topMargin: 90)
        let spaced = PagePagination.sheets(count: 3, width: 500, textOriginY: 28, leadingBand: 0,
                                           pitch: 800, topMargin: 90, deskGap: 12)
        XCTAssertEqual(spaced.map(\.minY), tiled.map(\.minY), "no sheet moved")
        XCTAssertEqual(spaced[0].height, 788, accuracy: 0.001, "the paper is shorter by the desk")
        XCTAssertEqual(spaced[1].minY - spaced[0].maxY, 12, accuracy: 0.001,
                       "…and that is exactly what shows between them")
    }

    /// Page 0's sheet reaches ABOVE the view, and that is the correct answer rather than a bug to
    /// clamp away. The reader shows its own 28pt of padding above the first line; the paper wants a
    /// full 99.25pt top margin there. The missing 71.25pt is blank paper with nothing in the view to
    /// draw in it. Clamping to 0 would print page 1 with a 28pt top margin and every other page with
    /// 99.25 — a printout whose first page is visibly different from the rest.
    func testTheFirstSheetReachesAboveTheViewByTheMissingTopMargin() {
        let top = PagePagination.sheetTop(page: 0, textOriginY: 28, leadingBand: 0,
                                          pitch: 841.9, topMargin: 99.25)
        XCTAssertEqual(top, -71.25, accuracy: 0.001)
        // …and the text still lands exactly one top margin below the paper's edge.
        XCTAssertEqual(28 - top, 99.25, accuracy: 0.001)
    }

    /// A leading band (page 0 DOES have its own header, so room was reserved above the first line)
    /// moves every sheet down with it — the reservation is part of the page, not padding outside it.
    func testALeadingBandShiftsEverySheet() {
        let without = PagePagination.sheetTop(page: 2, textOriginY: 28, leadingBand: 0,
                                              pitch: 800, topMargin: 90)
        let with = PagePagination.sheetTop(page: 2, textOriginY: 28, leadingBand: 36,
                                           pitch: 800, topMargin: 90)
        XCTAssertEqual(with - without, 36, accuracy: 0.001)
    }

    /// With no declared margins the sheet edge is the gap's midpoint — the SAME fallback
    /// `PageBandPainter.footerTop`/`headerTop` already use (footer in the upper half, header in the
    /// lower half). Printing has to agree with the painter about where the paper ends, or one page's
    /// footer prints on the next.
    func testAnUndeclaredTopMarginFallsBackToHalfTheBand() {
        XCTAssertEqual(PagePagination.topMargin(declared: nil, band: 80), 40, accuracy: 0.001)
        XCTAssertEqual(PagePagination.topMargin(declared: 99.25, band: 170.15), 99.25, accuracy: 0.001)
    }

    // MARK: - (2) A footer belongs to its OWN sheet

    /// The measured defect: on the reference report a table overran page 5 by 1.12pt, the sheet-edge
    /// clamp pushed the footer past the paper's edge, and `- 5 -` printed at the TOP OF PAGE 6.
    func testAFooterThatWouldLandOnTheNextSheetIsSkippedRatherThanMoved() {
        let paperEdge: CGFloat = 4110.25
        // Comfortably above the edge — drawn.
        XCTAssertTrue(PageBandPainter.footerFitsOnItsSheet(top: 4032.76, footerHeight: 36.06,
                                                           paperEdge: paperEdge))
        // Exactly flush with it — still its own sheet.
        XCTAssertTrue(PageBandPainter.footerFitsOnItsSheet(top: paperEdge - 36.06, footerHeight: 36.06,
                                                           paperEdge: paperEdge))
        // The real case: the gap starts 1.12pt BELOW the paper edge, so the whole footer is next door.
        XCTAssertFalse(PageBandPainter.footerFitsOnItsSheet(top: 4111.37, footerHeight: 36.06,
                                                            paperEdge: paperEdge))
    }

    /// A document that never stated a bottom margin has no sheet edge to fall off, and must keep
    /// behaving exactly as it did before this rule existed (invariant 37's unspecified case).
    func testWithNoDeclaredBottomMarginEveryFooterStillDraws() {
        XCTAssertTrue(PageBandPainter.footerFitsOnItsSheet(top: 99_999, footerHeight: 36,
                                                           paperEdge: nil))
    }

    // MARK: - (3) End to end, through a real print job

    /// THE headline property: one printed sheet per page the READER counts, on the paper the DOCUMENT
    /// declares. Both halves are read back out of the PDF the job actually produced.
    func testAPagedDocumentPrintsOneSheetPerReaderPageAtItsOwnPaperSize() throws {
        let (_, wc) = try openPaged()
        let pages = wc.printPageCount
        XCTAssertGreaterThan(pages, 1, "precondition: the fixture must be long enough to paginate")
        XCTAssertEqual(wc.printSheets.count, pages)

        let pdf = try printToPDF(wc)
        XCTAssertEqual(pdf.numberOfPages, pages,
                       "the printout must have the same number of pages the reader itself shows")
        let box = try XCTUnwrap(pdf.page(at: 1)).getBoxRect(CGPDFBox.mediaBox)
        XCTAssertEqual(box.width, Self.paperWidth, accuracy: 1.0,
                       "the paper is the DOCUMENT's own sheet, not the printer's default")
        XCTAssertEqual(box.height, Self.paperHeight, accuracy: 1.0)
    }

    /// The reader's page grid, not AppKit's. `NSTextView` paginates by filling the printable height
    /// with lines, which would put the reader's page 3 across two sheets; this asserts the sheets
    /// really are the ones `printSheets` computed, by the two numbers AppKit could not have arrived at
    /// on its own — every sheet is the DOCUMENT's own paper height, and consecutive sheets are exactly
    /// one page PITCH apart whatever the lines on them do.
    ///
    /// The old witness was that page 1's sheet started ABOVE the view (a negative `minY`), which was
    /// true while the leading band was the only thing above the first line — and a line shift makes no
    /// room at the top of a text view, because `textContainerOrigin` is derived from where the content
    /// starts and cancels it. The room is now in the inset (`applyVerticalInset`), so page 1's sheet is
    /// on screen like every other one, and a negative number is no longer evidence of anything.
    func testTheViewTakesPaginationOverFromAppKit() throws {
        let (_, wc) = try openPaged()
        var range = NSRange()
        XCTAssertTrue(wc.textView.knowsPageRange(&range),
                      "a paged document paginates itself")
        XCTAssertEqual(range.location, 1)
        XCTAssertEqual(range.length, wc.printPageCount)
        XCTAssertEqual(wc.textView.rectForPage(1), wc.printSheets[0])
        let pitch = PagePagination.pitch(pageContentHeight: wc.pageBandDelegate.pageContentHeight,
                                         band: wc.pageBandDelegate.band)
        XCTAssertEqual(wc.textView.rectForPage(1).height, Self.paperHeight, accuracy: 1.0,
                       "a sheet is the document's own paper, not what a printer's margins left over")
        XCTAssertEqual(wc.textView.rectForPage(2).minY - wc.textView.rectForPage(1).minY, pitch,
                       accuracy: 0.01, "sheets tile at the document's own pitch")
    }

    /// Page 1's sheet is REACHABLE — its whole outline, including the top margin, is inside the view a
    /// reader can scroll to. The band delegate cannot give that room: measured on this fixture, a
    /// 99.25pt leading band left `textContainerOrigin.y` at −72 and put the sheet's top edge 72pt above
    /// the document's own origin, where nothing can draw and no scroll can reach ("1페이지에서 가장
    /// 아래로 내려도 위가 안 보임"). Mutation-checked against `applyVerticalInset`.
    func testTheFirstSheetIsFullyInsideTheView() throws {
        let (_, wc) = try openPaged()
        XCTAssertGreaterThanOrEqual(wc.pageSheets.first?.minY ?? -1, 0,
                                    "page 1's paper begins above the view — its top margin cannot be seen")
        XCTAssertGreaterThan(wc.pageBandDelegate.leadingBand, 0, "precondition: this page reserves a band")
    }

    /// Markdown has no paper, so it must keep AppKit's own line-aware pagination — and must still
    /// print. The grid is gated on the DOCUMENT, never on "is this an office file".
    func testAMarkdownDocumentStillPrintsAndDoesNotUseThePageGrid() throws {
        let (_, wc) = try openMarkdown(String(repeating: "A paragraph of prose.\n\n", count: 200))
        XCTAssertTrue(wc.printSheets.isEmpty, "markdown has no page grid to print on")
        // `knowsPageRange` is deliberately NOT called directly here: with no grid it forwards to
        // `NSTextView`'s own implementation, which reads `NSPrintOperation.current` and crashes
        // (SIGSEGV, measured) when asked outside a job. The real job below exercises the same path.
        let pdf = try printToPDF(wc)
        XCTAssertGreaterThan(pdf.numberOfPages, 1, "a long markdown file still paginates and prints")
    }

    /// The third branch: a document that reserves NO band, so its text runs continuously and cutting
    /// it on the page grid would slice a line in half — it takes the PAPER from the document and
    /// leaves the breaking to `NSTextView`'s own line-aware pagination.
    ///
    /// Reaching it needs BOTH halves now: no running header or footer (real and common — the first
    /// `.hwp` reached for while building this had a page height of 657.64pt and no header at all)
    /// AND the page outline switched off, since the outline reserves the document's own margins
    /// between sheets whether or not anything is drawn in them (`PageViewOptions.separatesPages`).
    func testADocumentThatReservesNoBandKeepsAppKitsPaginationOnItsOwnPaper() throws {
        PageViewOptionsStore.startingOptions = PageViewOptions(outline: false)
        let (_, wc) = try openPaged(headerAndFooter: false)
        XCTAssertTrue(wc.isPaged, "precondition: it still declares a page")
        XCTAssertFalse(wc.pageBandDelegate.isActive, "…but reserves no band, so it did not paginate")
        XCTAssertTrue(wc.printSheets.isEmpty, "so printing must not impose the page grid on it")

        let pdf = try printToPDF(wc)
        XCTAssertGreaterThan(pdf.numberOfPages, 1, "it still paginates — AppKit does the breaking")
        let box = try XCTUnwrap(pdf.page(at: 1)).getBoxRect(CGPDFBox.mediaBox)
        XCTAssertEqual(box.width, Self.paperWidth, accuracy: 1.0,
                       "the paper is still the document's own sheet")
        XCTAssertEqual(box.height, Self.paperHeight, accuracy: 1.0)
    }

    /// A paged print must not leave its A4-with-no-margins settings behind in `NSPrintInfo.shared`:
    /// the next document printed would then be a markdown file on a page with no margins at all.
    /// `makePrintOperation` copies, and this is what stops that being quietly undone.
    func testPrintingAPagedDocumentDoesNotMutateTheSharedPrintInfo() throws {
        let (_, wc) = try openPaged()
        let before = (NSPrintInfo.shared.paperSize, NSPrintInfo.shared.topMargin,
                      NSPrintInfo.shared.leftMargin)
        _ = try printToPDF(wc)
        XCTAssertEqual(NSPrintInfo.shared.paperSize, before.0)
        XCTAssertEqual(NSPrintInfo.shared.topMargin, before.1)
        XCTAssertEqual(NSPrintInfo.shared.leftMargin, before.2)
    }

    /// The trap `printing-design.md` names first: a paged document is READ at 1.8× (invariant 57b),
    /// and a print that inherited that would produce paper 1.8× too large — silently, since the pages
    /// would still look right on screen. Measured rather than assumed: `scrollView.magnification` is a
    /// transform on the CLIP view, and the text view's own geometry is identical at both zooms.
    func testTheReadingZoomNeverReachesThePaper() throws {
        let (doc, wc) = try openPaged()
        let boundsAtOpen = wc.textView.bounds
        doc.increaseReaderFontSize(nil)      // paged: this is a magnification, not a rebuild
        doc.increaseReaderFontSize(nil)
        XCTAssertGreaterThan(wc.pageZoom, 1.0, "precondition: the reader really is zoomed in")
        // WIDTH exactly: a magnification that leaked into the view's own geometry would scale it by
        // the zoom factor, which is the whole failure mode. (Height is compared loosely — the
        // trailing footer reservation is re-derived from the last line's rect and moves by hundredths
        // of a point, which says nothing about zoom.)
        XCTAssertEqual(wc.textView.bounds.width, boundsAtOpen.width,
                       "the zoom must not move the view's own geometry — that is what printing reads")
        XCTAssertEqual(wc.textView.bounds.height, boundsAtOpen.height, accuracy: 1.0)

        let pdf = try printToPDF(wc)
        let box = try XCTUnwrap(pdf.page(at: 1)).getBoxRect(CGPDFBox.mediaBox)
        XCTAssertEqual(box.width, Self.paperWidth, accuracy: 1.0,
                       "paper stays the document's own size however far the READER zoomed in")
    }

    // MARK: - (4) The header is built against the PAGE, not the window

    /// A running header is authored against the page's own body width, and taking it from the live
    /// reading column instead was a real, measured defect: the first render can run before the window
    /// has been laid out, leaving the text container at its 600pt starting size, and nothing re-runs
    /// the band configuration afterwards. On the reference report — whose header is `w:jc="right"` —
    /// that put the header's right edge at x=656 on a 595.3pt sheet, i.e. off the paper, and the
    /// printout carried no running header at all.
    func testTheHeaderBandIsBuiltAtThePageBodyWidthNotTheReadingColumn() throws {
        let (_, wc) = try openPaged()
        let content = try XCTUnwrap(wc.pageBandContent)
        XCTAssertEqual(content.columnWidth, Self.bodyWidth, accuracy: 0.01,
                       "the band's column is the DOCUMENT's page body, so a right-aligned header " +
                       "lands on the page's own right margin at every window size")
    }

    // MARK: - Fixture

    private static let bodyWidth: CGFloat = 400
    private static let bodyHeight: CGFloat = 500
    private static let marginTop: CGFloat = 60
    private static let marginBottom: CGFloat = 40
    private static let marginSide: CGFloat = 50
    private static var paperWidth: CGFloat { marginSide + bodyWidth + marginSide }
    private static var paperHeight: CGFloat { marginTop + bodyHeight + marginBottom }

    /// A paged document with a running header AND footer — the shape that makes the reader paginate
    /// (`PageBandLayoutDelegate.isActive`), which is what printing on the page grid is gated on. Long
    /// enough to need several sheets.
    private func openPaged(headerAndFooter: Bool = true) throws -> (MarkdownDocument, DocumentWindowController) {
        let doc = MarkdownDocument()
        doc.fileURL = temp.appendingPathComponent("paged.docx")
        let body = (1...120).map { i in
            OfficeBlock.paragraph(spans: [Span(text: "Paragraph number \(i) of the body text.")])
        }
        doc.setOfficeContent(
            blocks: body, archive: nil, defaultBodyFontSize: 11,
            pageContentWidth: Self.bodyWidth,
            pageMarginLeft: Self.marginSide, pageMarginRight: Self.marginSide,
            pageContentHeight: Self.bodyHeight,
            pageMarginTop: Self.marginTop, pageMarginBottom: Self.marginBottom,
            pageHeaderDistance: 20, pageFooterDistance: 20,
            headers: headerAndFooter
                ? [OfficeHeaderFooter(appliesTo: .defaultPages,
                                      blocks: [.paragraph(spans: [Span(text: "Running header")])])] : [],
            footers: headerAndFooter
                ? [OfficeHeaderFooter(appliesTo: .defaultPages,
                                      blocks: [.paragraph(spans: [Span(text: "Running footer")])])] : [])
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        settle(wc)
        return (doc, wc)
    }

    private func openMarkdown(_ source: String) throws -> (MarkdownDocument, DocumentWindowController) {
        let url = temp.appendingPathComponent("doc.md")
        try Data(source.utf8).write(to: url)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: Data(source.utf8), ofType: "public.plain-text")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        settle(wc)
        return (doc, wc)
    }

    /// Lay the window out, then the whole document — `printPageCount` reads the laid-out extent, and
    /// asking for it mid-walk is invariant 49's freeze rather than a wrong number.
    private func settle(_ wc: DocumentWindowController) {
        wc.textView.postsFrameChangedNotifications = false
        wc.textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = false
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.updateTextInset()
        if let tc = wc.textView.textContainer { wc.textView.layoutManager?.ensureLayout(for: tc) }
        wc.applyTrailingFooterBand()
    }

    /// Runs the REAL operation ⌘P builds, to a file, and hands back the PDF — no print panel, no
    /// printer, no progress window.
    private func printToPDF(_ wc: DocumentWindowController) throws -> CGPDFDocument {
        let out = temp.appendingPathComponent("out-\(UUID().uuidString).pdf")
        let op = wc.makePrintOperation()
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.printInfo.jobDisposition = .save
        op.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
        XCTAssertTrue(op.run(), "the print job itself must succeed")
        let data = try Data(contentsOf: out)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGPDFDocument(provider))
    }
}
