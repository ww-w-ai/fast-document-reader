import XCTest
import AppKit
@testable import FastDocReader

/// THE SCREEN AND THE PAPER MUST AGREE.
///
/// Two defects shipped in one night from the same crack: the window ignored every page break the
/// author placed while `--pdf` honoured them all (the break locations were read before the text was
/// installed, and only printing re-reads them), and then the fix for that inverted it — printing
/// ignored them while the window obeyed (the locations were cleared on the path printing takes).
/// Each time, every check that went through ONE path passed.
///
/// So the property under test is not "does pagination work" — it is "do the two paths answer the
/// same question the same way". A viewer that shows something the printout does not is a bug even
/// when both look plausible on their own.
final class ScreenPrintParityTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PageViewOptionsStore.current = PageViewOptions(outline: true)
    }

    override func tearDown() {
        PageViewOptionsStore.reset()
        super.tearDown()
    }

    /// A paged document with the author's own break in it, opened the way the app opens one.
    private func openPagedDocument(breakAt: [Int] = [1]) throws -> (MarkdownDocument, DocumentWindowController) {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-parity-\(UUID().uuidString).hwp")
        let body = (0..<40).map { i in
            OfficeBlock.paragraph(spans: [Span(text: "paragraph number \(i) with enough words to wrap once or twice")])
        }
        doc.setOfficeContent(
            blocks: body, comments: [], archive: nil, images: [:], defaultBodyFontSize: 11,
            pageContentWidth: 400, pageMarginLeft: 60, pageMarginRight: 60,
            pageContentHeight: 300, pageMarginTop: 60, pageMarginBottom: 60,
            headers: [OfficeHeaderFooter(appliesTo: .defaultPages,
                                         blocks: [.paragraph(spans: [Span(text: "running head")])])],
            footers: [], masterPages: [], sectionStartBlocks: [0],
            pageBreakBlocks: breakAt, keepWithNextBlocks: [],
            sections: [], anchoredObjects: [], lineGridPitch: nil)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        return (doc, wc)
    }

    /// The instruction itself must survive BOTH paths. This is the exact pair of defects, caught
    /// from either side: whichever path is re-applied last, the breaks are still there.
    func testTheDocumentsBreaksSurviveTheScreenPathAndThePrintPath() throws {
        let (doc, wc) = try openPagedDocument()
        let onScreen = wc.pageBandDelegate.documentPageBreaks
        XCTAssertFalse(onScreen.isEmpty, "the screen path must honour the document's own breaks")

        doc.applyPageBand(to: wc, forPrinting: true)
        XCTAssertEqual(wc.pageBandDelegate.documentPageBreaks, onScreen,
                       "the print path must honour exactly the same breaks — a page count that " +
                       "differs between the window and the PDF is the defect this file exists for")

        doc.applyPageBand(to: wc)
        XCTAssertEqual(wc.pageBandDelegate.documentPageBreaks, onScreen,
                       "and going back to the screen path must not change them either")
    }

    /// The PAGE GRID must be the same grid. `printSheets` is what `--pdf` and ⌘P put on paper;
    /// `pageSheets` is what the window draws. They are allowed to differ in exactly one way — the
    /// screen JOINS sheets across a boundary layout never opened, so a page break is never drawn
    /// through a table — and in no other.
    func testTheScreenDrawsTheSameSheetsThePrinterPrints() throws {
        let (_, wc) = try openPagedDocument()
        let printed = wc.printSheets
        let drawn = wc.pageSheets
        XCTAssertFalse(printed.isEmpty, "a paged document must produce sheets")

        XCTAssertEqual(printed.first?.origin.x, drawn.first?.origin.x,
                       "both paths put the paper in the same place horizontally")
        XCTAssertEqual(printed.first?.width, drawn.first?.width,
                       "and give it the same width")
        XCTAssertLessThanOrEqual(drawn.count, printed.count,
                                 "the screen may JOIN sheets (never split them), so it can only " +
                                 "ever have fewer")
        // Every drawn sheet is a union of consecutive printed sheets: its top is some printed
        // sheet's top and its bottom is some printed sheet's bottom.
        let tops = Set(printed.map { $0.minY.rounded() })
        let bottoms = Set(printed.map { $0.maxY.rounded() })
        for sheet in drawn {
            XCTAssertTrue(tops.contains(sheet.minY.rounded()),
                          "a drawn sheet must start where a printed one does — got \(sheet.minY)")
            XCTAssertTrue(bottoms.contains(sheet.maxY.rounded()),
                          "…and end where a printed one does — got \(sheet.maxY)")
        }
    }

    /// A page the AUTHOR ended is a page the reader DRAWS. The screen joins sheets across a boundary
    /// layout never opened so a break is never drawn through a table — but a document page break
    /// leaves the rest of its page empty, and an empty page has no line of its own to open the next
    /// boundary. Read naively that says "layout never broke here", and two sheets were welded into
    /// one double-height page carrying two running heads and two page numbers.
    func testAPageTheDocumentEndsIsNotWeldedToTheNextOne() throws {
        // Breaks close together, so the pages between them hold almost nothing — exactly the case
        // that produced the welded sheet.
        let (_, wc) = try openPagedDocument(breakAt: [1, 2, 3])
        let printed = wc.printSheets
        let drawn = wc.pageSheets
        XCTAssertEqual(drawn.count, printed.count,
                       "no table is involved, so nothing may be joined: the window must draw the " +
                       "same \(printed.count) sheets the printer prints, not \(drawn.count)")
        for (a, b) in zip(drawn, printed) {
            XCTAssertEqual(a.minY, b.minY, accuracy: 0.5)
            XCTAssertEqual(a.maxY, b.maxY, accuracy: 0.5)
        }
    }

    /// The page COUNT the reader reports is the page count it prints. `printPageCount` feeds both
    /// the printout's page range and the painter's "is this the last page" decision, so a
    /// disagreement here puts a footer on the wrong sheet as well as changing the PDF's length.
    func testThePageCountIsOneNumberBothPathsUse() throws {
        let (doc, wc) = try openPagedDocument()
        let screenCount = wc.printPageCount
        let screenSheets = wc.printSheets.count
        XCTAssertEqual(screenCount, screenSheets, "the sheets ARE the pages")

        doc.applyPageBand(to: wc, forPrinting: true)
        XCTAssertEqual(wc.printPageCount, screenCount,
                       "re-applying the band for printing must not change how many pages there are")
    }

    /// A document with NO breaks must be identical through both paths too — otherwise the parity
    /// above could be satisfied by both paths being equally wrong.
    func testAnUnbrokenDocumentPaginatesIdenticallyThroughBothPaths() throws {
        let (doc, wc) = try openPagedDocument(breakAt: [])
        XCTAssertTrue(wc.pageBandDelegate.documentPageBreaks.isEmpty)
        let before = wc.printPageCount
        doc.applyPageBand(to: wc, forPrinting: true)
        XCTAssertEqual(wc.printPageCount, before)
        XCTAssertTrue(wc.pageBandDelegate.documentPageBreaks.isEmpty,
                      "no breaks in, none invented on either path")
    }

    #if FMD_RUST_ENGINE
    // MARK: - S5C2-03/05: the engine's own sheets are the SAME sheets the screen draws

    /// A real fixture, opened the way the app opens one. `openPagedDocument`'s synthetic blocks
    /// carry no `documentData`, so `officeEngineHandle` stays `nil` under EITHER build and the
    /// tests above never actually reach the engine even when this file is compiled with the flag
    /// — this helper is what makes a flagged run of THIS file mean something for `printSheets`/
    /// `settlePagedTables`, the same real-fixture shape `RustEngineBridgeTests` uses.
    private func openRealPagedFixture(_ relativePath: String) throws -> DocumentWindowController {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(relativePath) is not in this checkout (docs/ is local-only)")
        }
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        return wc
    }

    /// S5C2-03: the same parity property `testTheScreenDrawsTheSameSheetsThePrinterPrints` proves
    /// for the host's own arithmetic, proven again on a real document whose `officeEngineHandle`
    /// is non-nil — so `printSheets` actually reaches `fastdoc_office_sheets` rather than the
    /// `#else` fallback, and `pageSheets` (unmodified by this sprint) still derives from it.
    /// Mutation: make `pageSheets` recompute instead of derive from `printSheets` — this must
    /// fail, exactly as the unflagged test's own mutation does (invariant 59). Mutation: ignore
    /// the engine's answer at the `printSheets` call site (always fall through to the `#else`
    /// arithmetic) — `answeredQueries` must have grown, or this test fails on that assertion
    /// alone, the same observable S5C-1's own band test used for the same reason.
    func testTheEnginesSheetsAreTheSameSheetsTheScreenDraws() throws {
        let wc = try openRealPagedFixture("docs/fixtures/office/bus-headings.docx")
        XCTAssertTrue(wc.pageBandDelegate.isActive, "this fixture must actually paginate")
        let handle = try XCTUnwrap(wc.mdDocument?.officeEngineHandle,
                                   "the engine must have opened this document for this test to mean anything")
        let answeredBefore = handle.answeredQueries
        let printed = wc.printSheets
        XCTAssertGreaterThan(printed.count, 1,
                             "the fixture must produce MORE THAN ONE page, or a parity check proves nothing")
        XCTAssertGreaterThan(handle.answeredQueries, answeredBefore,
                             "printSheets must have actually asked the engine, not merely agreed with the host")

        let drawn = wc.pageSheets
        XCTAssertLessThanOrEqual(drawn.count, printed.count)
        let tops = Set(printed.map { $0.minY.rounded() })
        let bottoms = Set(printed.map { $0.maxY.rounded() })
        for sheet in drawn {
            XCTAssertTrue(tops.contains(sheet.minY.rounded()),
                          "a drawn sheet must start where an engine-sourced printed one does")
            XCTAssertTrue(bottoms.contains(sheet.maxY.rounded()),
                          "…and end where an engine-sourced printed one does")
        }
    }

    /// S5C2-05: parity — the engine's own sheet rectangles must equal the host's OWN pure
    /// `PagePagination.sheets` arithmetic for the identical inputs, within 0.5pt, on a document
    /// asserted to produce MORE THAN ONE page before anything is compared (a one-page document
    /// agrees trivially and proves nothing — S5C-2's own pre-mortem #2).
    func testEnginesSheetsAgreeWithTheHostsOwnArithmeticOnARealMultiPageDocument() throws {
        let wc = try openRealPagedFixture("docs/fixtures/office/bus-headings.docx")
        XCTAssertTrue(wc.pageBandDelegate.isActive)
        wc.settlePagedTablesFully()
        let engineSheets = wc.printSheets
        XCTAssertGreaterThan(engineSheets.count, 1,
                             "docs/fixtures/office/bus-headings.docx must produce more than one page")

        // The host's OWN formula, called DIRECTLY rather than through `printSheets` — this is
        // deliberately NOT the fallback arithmetic `printSheets` itself would take if the engine
        // refused; it is the independent reference the engine's answer is judged against.
        let pitch = PagePagination.pitch(pageContentHeight: wc.pageBandDelegate.pageContentHeight,
                                         band: wc.pageBandDelegate.band)
        let width = try XCTUnwrap(wc.pagedDocumentWidth)
        let topMargin = PagePagination.topMargin(declared: wc.mdDocument?.officePageMarginTop,
                                                  band: wc.pageBandDelegate.band - wc.pageBandDelegate.deskGap)
        let hostSheets = PagePagination.sheets(count: wc.printPageCount, width: width,
                                               textOriginY: wc.textView.textContainerOrigin.y,
                                               leadingBand: wc.pageBandDelegate.leadingBand,
                                               pitch: pitch, topMargin: topMargin,
                                               deskGap: wc.pageBandDelegate.deskGap)
        XCTAssertEqual(engineSheets.count, hostSheets.count)
        for (a, b) in zip(engineSheets, hostSheets) {
            XCTAssertEqual(a.minX, b.minX, accuracy: 0.5)
            XCTAssertEqual(a.minY, b.minY, accuracy: 0.5)
            XCTAssertEqual(a.width, b.width, accuracy: 0.5)
            XCTAssertEqual(a.height, b.height, accuracy: 0.5)
        }
    }

    /// S5C2-04's engine half: the toggle must still reach the engine's own table-placement
    /// decision. Judged the same way `testTheSettingDecidesBetweenBreakingATableAndCarryingItDown`
    /// judges the host's arithmetic — the reference report's first overrunning table lands a page
    /// earlier when breaking is allowed — but on a document proven to have reached the engine
    /// (`answeredQueries` grew), so a build that hardcoded one behaviour Rust-side and dropped the
    /// live toggle would fail THIS assertion even though the host-only test above could not see it.
    func testTheEnginesTablePlacementStillObeysTheSplitTablesToggle() throws {
        func firstTableTop(_ split: Bool) throws -> (top: CGFloat, answered: Int) {
            PageViewOptionsStore.current = PageViewOptions(outline: true, splitTables: split)
            let wc = try openRealPagedFixture("docs/fixtures/office/bus-headings.docx")
            let handle = try XCTUnwrap(wc.mdDocument?.officeEngineHandle)
            let before = handle.answeredQueries
            wc.settlePagedTablesFully()
            let layout = try XCTUnwrap(wc.textView.layoutManager)
            let container = try XCTUnwrap(wc.textView.textContainer)
            let storage = try XCTUnwrap(wc.textView.textStorage)
            var top = CGFloat.greatestFiniteMagnitude
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, gr, stop in
                let cr = layout.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
                guard cr.location < storage.length,
                      let style = storage.attribute(.paragraphStyle, at: cr.location,
                                                    effectiveRange: nil) as? NSParagraphStyle,
                      style.textBlocks.first is NSTextTableBlock else { return }
                top = min(top, rect.minY)
                stop.pointee = true
            }
            return (top, handle.answeredQueries - before)
        }
        let whole = try firstTableTop(false)
        let split = try firstTableTop(true)
        XCTAssertGreaterThan(whole.answered, 0, "the whole-tables run must have reached the engine")
        XCTAssertGreaterThan(split.answered, 0, "the split-tables run must have reached the engine")
        XCTAssertLessThan(split.top, whole.top,
                          "breaking leaves the table where it started; keeping it whole carries it " +
                          "down to the next page, so its top is lower — through the engine's own " +
                          "decision, not just the host's")
    }
    #endif
}
