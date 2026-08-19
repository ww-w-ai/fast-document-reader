import XCTest
import AppKit
@testable import FastDocReader

/// DOES PAINTING THE FRONT FIRST CHANGE WHAT GETS PRINTED? Both answers, in one process, on one
/// real document — `FMD_PROGRESSIVE_PRINT_FILE=<abs path to a large .md>`.
///
/// A headless print has no app run loop, so it drains the main queue against a DEADLINE
/// (`HeadlessPDF.waitForRenderToSettle`). Anything still arriving when that deadline passes is
/// simply not in the file, and a short PDF looks exactly like a correct one. This reports the page
/// count with the front-first path ON and OFF so the difference is a number rather than a worry.
final class ProgressivePrintParityProbeTests: XCTestCase {
    /// Reads the document, settles it the way `--pdf` does, and reports what the reader would print.
    private func pageCount(_ url: URL, progressive: Bool) throws -> (pages: Int, chars: Int, seconds: Double) {
        let previous = MarkdownDocument.progressiveFirstPaintEnabled
        MarkdownDocument.progressiveFirstPaintEnabled = progressive
        defer { MarkdownDocument.progressiveFirstPaintEnabled = previous }

        let started = Date()
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 900), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
        if let tc = wc.textView.textContainer { wc.textView.layoutManager?.ensureLayout(for: tc) }
        wc.applyTrailingFooterBand()
        let result = (wc.printPageCount, wc.textView.textStorage?.length ?? 0,
                      Date().timeIntervalSince(started))
        doc.windowControllers.forEach { doc.removeWindowController($0) }
        return result
    }

    func testTheSameDocumentPrintsTheSameNumberOfPagesEitherWay() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_PROGRESSIVE_PRINT_FILE"] else {
            throw XCTSkip("set FMD_PROGRESSIVE_PRINT_FILE to a large markdown file")
        }
        let url = URL(fileURLWithPath: path)
        let whole = try pageCount(url, progressive: false)
        let front = try pageCount(url, progressive: true)
        print(String(format: "PRINT-PARITY whole=%d pages (%d chars, %.1fs) frontFirst=%d pages (%d chars, %.1fs)",
                     whole.pages, whole.chars, whole.seconds,
                     front.pages, front.chars, front.seconds))
        // The CONTENT is the assertion. A document that settled short is the failure this probe
        // exists to catch, and it is the one thing here that is deterministic.
        XCTAssertEqual(front.chars, whole.chars, "the front-first build settled with a shorter document")
        // The PAGE count is reported, not asserted, unless the document declares pages of its own.
        // Printing a non-paged markdown file headlessly is NOT deterministic: the settle loop is
        // bounded, and how much lazily-sized media landed inside that bound moves the total. The
        // build this feature was added to varied 1,844 / 1,845 / 1,862 over three runs of the same
        // file, before any of this existed.
        if whole.pages > 1 {
            XCTAssertEqual(front.pages, whole.pages, "the front-first build would print a different document")
        }
    }
}
