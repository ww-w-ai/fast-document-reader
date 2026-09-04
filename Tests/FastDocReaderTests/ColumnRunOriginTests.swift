import XCTest
import AppKit
@testable import FastDocReader

/// A column run begins where the FLOWED document puts it, not where a single-column layout did.
///
/// Every run's placements were computed from one layout in which no run had been flowed yet, so a
/// run's origin — its first line's top in that layout — carried the full single-column height of
/// every run above it. Once those runs were flowed into their columns they shrank, and the later run
/// stayed where the unflowed layout had left it: on the reference manual the appendix began 7,646pt
/// (nine blank printed sheets) below the end of the two-column regulation that precedes it
/// (invariant 161). Runs are now settled in document order, each against the layout that already
/// holds the placements of the runs before it.
final class ColumnRunOriginTests: XCTestCase {

    private func twoColumnDocument(linesPerRun: Int, preamble: Int = 0) throws -> (MarkdownDocument, DocumentWindowController) {
        let doc = MarkdownDocument()
        // A file URL so the document IS an office one — `kind` is decided by the extension.
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-column-origin-\(UUID().uuidString).hwp")
        func line(_ i: Int, layout: OfficeColumnLayout? = nil) -> OfficeBlock {
            .paragraph(spans: [Span(text: "line \(i)", columnLayout: layout)])
        }
        // Single-column text before the first run, so the run begins some sheets into the document.
        var blocks: [OfficeBlock] = (0..<preamble).map { line(5000 + $0) }
        let firstStart = blocks.count
        blocks.append(line(0, layout: OfficeColumnLayout(count: 2, spacing: 20)))
        for i in 1..<linesPerRun { blocks.append(line(i)) }
        let secondStart = blocks.count
        // A different spacing, so the two declarations stay two runs rather than one coalesced
        // attribute range — and the second run starts a page, as a section does.
        blocks.append(line(1000, layout: OfficeColumnLayout(count: 2, spacing: 24)))
        for i in 1001..<(1000 + linesPerRun) { blocks.append(line(i)) }
        doc.setOfficeContent(
            blocks: blocks, archive: nil, defaultBodyFontSize: 11,
            pageContentWidth: 400, pageMarginLeft: 60, pageMarginRight: 60,
            pageContentHeight: 500, pageMarginTop: 60, pageMarginBottom: 60,
            headers: [OfficeHeaderFooter(appliesTo: .defaultPages,
                                         blocks: [.paragraph(spans: [Span(text: "head")])])],
            sectionStartBlocks: [0, firstStart, secondStart].filter { $0 > 0 || firstStart == 0 },
            pageBreakBlocks: firstStart > 0 ? [firstStart, secondStart] : [secondStart])
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        XCTAssertTrue(HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc), "the render must settle")
        return (doc, wc)
    }

    private func fragments(_ wc: DocumentWindowController, in range: NSRange) -> [NSRect] {
        guard let lm = wc.textView.layoutManager, let tc = wc.textView.textContainer else { return [] }
        lm.ensureLayout(for: tc)
        var out: [NSRect] = []
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        lm.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in out.append(rect) }
        return out
    }

    func testTheSecondRunBeginsOnTheSheetAfterTheFirstRunsLastLine() throws {
        let (_, wc) = try twoColumnDocument(linesPerRun: 200)
        let runs = wc.columnRunRanges()
        XCTAssertEqual(runs.count, 2, "two declarations with different spacing are two runs")
        guard runs.count == 2 else { return }
        let first = fragments(wc, in: runs[0].range)
        let second = fragments(wc, in: runs[1].range)
        XCTAssertGreaterThan(first.count, 100)
        XCTAssertGreaterThan(second.count, 100)
        let pitch = PagePagination.pitch(pageContentHeight: wc.pageBandDelegate.pageContentHeight,
                                         band: wc.pageBandDelegate.band)
        XCTAssertGreaterThan(pitch, 0)
        let firstBottom = try XCTUnwrap(first.map(\.maxY).max())
        let secondTop = try XCTUnwrap(second.map(\.minY).min())
        // The first run flowed into two columns is about half its single-column height. The second
        // run starts a page, so at most one sheet may lie between the two — never the sheets the
        // first run gave back by flowing.
        XCTAssertLessThan(secondTop - firstBottom, pitch + 1,
                          "the second run began \((secondTop - firstBottom) / pitch) sheets after the first — " +
                          "its origin was taken from a layout in which the first run had not been flowed yet")
        // And every line of the second run is in a column: the run's own placements were made.
        let placed = (runs[1].range.location..<NSMaxRange(runs[1].range))
            .filter { wc.pageBandDelegate.columnPlacements[$0] != nil }.count
        XCTAssertGreaterThan(placed, 100, "the second run's lines must be placed in its columns")
    }

    /// The print grid is not the screen grid — the desk gap between sheets goes, so every sheet
    /// after the first begins at a different `y` — and placements are absolute positions on a grid.
    /// Entering print layout must settle them again, or the run lands where the SCREEN grid put it.
    func testEnteringPrintLayoutSettlesTheRunsAgainstThePrintGrid() throws {
        let (_, wc) = try twoColumnDocument(linesPerRun: 60, preamble: 120)
        let runs = wc.columnRunRanges()
        XCTAssertEqual(runs.count, 2)
        guard let firstRun = runs.first else { return }
        let screenPitch = PagePagination.pitch(pageContentHeight: wc.pageBandDelegate.pageContentHeight,
                                               band: wc.pageBandDelegate.band)
        wc.beginPrintLayout()
        wc.settlePagedTablesFully()
        wc.applyTrailingFooterBand()
        let printPitch = PagePagination.pitch(pageContentHeight: wc.pageBandDelegate.pageContentHeight,
                                              band: wc.pageBandDelegate.band)
        XCTAssertNotEqual(screenPitch, printPitch, accuracy: 0.5,
                          "the two grids must differ for this test to see anything")
        XCTAssertFalse(wc.pageBandDelegate.columnPlacements.isEmpty, "the runs are settled again on paper")
        let top = try XCTUnwrap(fragments(wc, in: firstRun.range).map(\.minY).min())
        // The run starts a page, so its first line sits at a page top OF THE PRINT GRID. On stale
        // screen placements it sits at a screen page top instead — off by the desk gap per sheet.
        let intoPage = (top - wc.pageBandDelegate.leadingBand).truncatingRemainder(dividingBy: printPitch)
        XCTAssertEqual(min(intoPage, printPitch - intoPage), 0, accuracy: 0.5,
                       "the first run's first line is \(intoPage)pt into a print sheet")
        XCTAssertGreaterThan(top, printPitch, "the preamble must push the run past the first sheet")
    }
}
