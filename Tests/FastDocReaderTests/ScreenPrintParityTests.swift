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
        PageViewOptionsStore.startingOptions = PageViewOptions(outline: true)
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
}
