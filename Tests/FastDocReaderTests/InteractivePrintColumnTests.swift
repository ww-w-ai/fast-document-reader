import XCTest
import AppKit
@testable import FastDocReader

/// ⌘P must produce the same document whatever size the reader's window happens to be.
///
/// `--pdf` was fixed by seeding its off-screen window to the paper column (invariant 127), which
/// left the interactive path — the one an actual reader uses — still scaling the window's own
/// layout down onto the sheet through `.fit`. These drive `makePrintOperation` directly, because
/// that is the one function both paths come through and the only place the question can be asked
/// without a print panel.
final class InteractivePrintColumnTests: XCTestCase {

    /// Each paragraph must actually WRAP at the widest column under test, or the window's width
    /// cannot change the page count and the check passes for a reason that has nothing to do with
    /// the fix. Measured: a one-line paragraph laid out identically at a 619pt and a 1519pt
    /// container — same used height to twelve decimal places — and the test passed with the fix
    /// reverted. This one is long enough to take several lines even at 1519pt.
    private static let body = (1...200)
        .map { n in
            "Paragraph \(n) — 본문 한 줄, and then a good deal more of it, because a paragraph "
            + "that fits on a single line is laid out identically at every column width under "
            + "test and therefore cannot show a page-count difference at all; this sentence "
            + "keeps going until it is certain to wrap several times even against the widest "
            + "reading measure this test asks for, which is the paper's own column."
        }
        .joined(separator: "\n\n")

    func testTheWindowWidthDoesNotDecideTheType() throws {
        let narrow = try pageCount(windowWidth: 700)
        let wide = try pageCount(windowWidth: 1600)
        XCTAssertGreaterThan(narrow, 1, "the fixture must span sheets or the count proves nothing")
        XCTAssertEqual(narrow, wide,
                       "a 700pt window printed \(narrow) pages and a 1600pt window \(wide) — the "
                       + "printout is still a photograph of the window")
    }

    /// The borrowed column is GIVEN BACK. The print panel is modal, so a reader never sees the
    /// paper-width layout — unless it is left behind, in which case the document stays at the
    /// wrong width until the next resize and every reading-position offset moves under them.
    func testTheReadingColumnIsPutBackAfterPrinting() throws {
        let (doc, wc) = try open(Self.body, windowWidth: 1200)
        defer { withExtendedLifetime(doc) {} }
        let before = try XCTUnwrap(wc.textView.textContainer).containerSize.width
        let frameBefore = wc.textView.frame.width
        let insetBefore = wc.textView.textContainerInset.width

        let op = wc.makePrintOperation()
        let borrowed = try XCTUnwrap(wc.textView.textContainer).containerSize.width
        XCTAssertNotEqual(borrowed, before, accuracy: 0.5,
                          "the print must lay the text out at the paper's column, not the window's")
        _ = op

        wc.printDidRun(op, success: true, contextInfo: nil)
        XCTAssertEqual(try XCTUnwrap(wc.textView.textContainer).containerSize.width, before,
                       accuracy: 0.001, "the reading column must come back")
        XCTAssertEqual(wc.textView.frame.width, frameBefore, accuracy: 0.001)
        XCTAssertEqual(wc.textView.textContainerInset.width, insetBefore, accuracy: 0.001)
    }

    // MARK: -

    /// Sheets the laid-out text would fill, computed rather than asked for.
    ///
    /// `NSTextView.knowsPageRange` is the call the operation itself makes, and asking it outside a
    /// live print context segfaults — it consults `NSPrintOperation.current`, which is nil here.
    /// The height the text actually occupies at the operation's own column, divided by the sheet's
    /// imageable height, is the same number without needing a context or a temporary file.
    private func pageCount(windowWidth: CGFloat) throws -> Int {
        let (doc, wc) = try open(Self.body, windowWidth: windowWidth)
        defer { withExtendedLifetime(doc) {} }
        let op = wc.makePrintOperation()
        let container = try XCTUnwrap(wc.textView.textContainer)
        let manager = try XCTUnwrap(wc.textView.layoutManager)
        manager.ensureLayout(for: container)
        let height = manager.usedRect(for: container).height
        let info = op.printInfo
        let sheet = max(1, info.paperSize.height - info.topMargin - info.bottomMargin)
        wc.printDidRun(op, success: true, contextInfo: nil)
        return Int(ceil(height / sheet))
    }

    private func open(_ markdown: String, windowWidth: CGFloat) throws
        -> (MarkdownDocument, DocumentWindowController) {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-print-col-\(UUID().uuidString).md")
        try doc.read(from: Data(markdown.utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: windowWidth, height: 700), display: false)
        spin(0.5)
        return (doc, wc)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
