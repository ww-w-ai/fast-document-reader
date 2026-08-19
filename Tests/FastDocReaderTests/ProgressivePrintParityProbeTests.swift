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
    private func pageCount(_ url: URL, progressive: Bool) throws
        -> (pages: Int, chars: Int, seconds: Double, height: CGFloat, placeholders: Int) {
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
        // HEIGHT tells apart the two ways a page count can move: if the laid-out document is a
        // different height, its CONTENT is a different size (an image still at a stand-in height);
        // if the height matches and the page count does not, the difference is in PAGINATION.
        // `placeholders` counts attachments still drawing nothing, which is the first suspect.
        var placeholders = 0
        if let storage = wc.textView.textStorage {
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
                guard let att = v as? NSTextAttachment else { return }
                if att.image == nil, (att.attachmentCell as? SizedAttachmentCell)?.image == nil { placeholders += 1 }
            }
        }
        let result = (wc.printPageCount, wc.textView.textStorage?.length ?? 0,
                      Date().timeIntervalSince(started), wc.textView.frame.height, placeholders)
        doc.windowControllers.forEach { doc.removeWindowController($0) }
        return result
    }

    func testTheSameDocumentPrintsTheSameNumberOfPagesEitherWay() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_PROGRESSIVE_PRINT_FILE"] else {
            throw XCTSkip("set FMD_PROGRESSIVE_PRINT_FILE to a large markdown file")
        }
        let url = URL(fileURLWithPath: path)
        // THREE renders, not two, and the comparison is between the SECOND and THIRD.
        //
        // Rendering the same file twice in one process does not produce the same document: measured
        // on a 553-page HWP, the first render settles to 553 pages in 6.3 s and the second to 545 in
        // 3.2 s, reproducibly, with identical code on both (the switch below only reaches the
        // markdown path). Comparing render #1 against render #2 therefore measures process warmth
        // and calls it a feature difference. Both arms are read from the same ordinal position
        // instead, and #1 vs #2 is reported as what it is.
        let first = try pageCount(url, progressive: false)
        let whole = try pageCount(url, progressive: false)
        let front = try pageCount(url, progressive: true)
        print(String(format: "PRINT-PARITY firstRender=%d pages h=%.0f ph=%d (%.1fs) | whole=%d pages h=%.0f ph=%d (%d chars, %.1fs) | frontFirst=%d pages h=%.0f ph=%d (%d chars, %.1fs)",
                     first.pages, first.height, first.placeholders, first.seconds,
                     whole.pages, whole.height, whole.placeholders, whole.chars, whole.seconds,
                     front.pages, front.height, front.placeholders, front.chars, front.seconds))
        if first.pages != whole.pages {
            print("PRINT-PARITY warm-drift firstRender=\(first.pages) secondRender=\(whole.pages) — process warmth, not this feature")
        }
        // The CONTENT is the assertion. A document that settled short is the failure this probe
        // exists to catch, and it is the one thing here that is deterministic.
        XCTAssertEqual(front.chars, whole.chars, "the front-first build settled with a shorter document")
        // The PAGE count is asserted only where the document declares pages of its own AND both
        // sides were read from the same ordinal position. Printing a NON-paged file headlessly is
        // bounded by the settle deadline and moves with how much lazily-sized media landed inside
        // it, so there is no fixed number to hold it to.
        if whole.pages > 1 {
            XCTAssertEqual(front.pages, whole.pages, "the front-first build would print a different document")
        }
    }
}
