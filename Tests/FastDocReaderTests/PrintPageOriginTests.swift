import XCTest
import AppKit
@testable import FastDocReader

/// A document starts at the top of the page.
///
/// `NSPrintInfo` centres its content BOTH ways by default and nothing here ever turned that off, so
/// a file whose text did not fill a sheet printed floating in the middle of it — reported from the
/// print panel's own preview on a short `.txt`, where a few lines of SQL sat halfway down an
/// otherwise empty page. It reads as an accident rather than a document.
///
/// Pinned on the PRINT INFO rather than by measuring ink on a rendered page: the flags are what the
/// bug was, they are read by AppKit rather than by us, and a test that re-derived a glyph's position
/// from a PDF would fail for a dozen reasons that have nothing to do with this.
///
/// Both formats are checked because they take DIFFERENT branches of `makePrintOperation` — a paged
/// document sets its own paper and margins, an unpaged one falls through to `.fit`. Centring is a
/// no-op for the paged branch today (its page rects are exactly paper-sized), which is precisely why
/// it is asserted: that is a property of today's rects, not a guarantee, and leaving the flag at
/// AppKit's default would make the paged path quietly depend on it.
final class PrintPageOriginTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func openAndPrintInfo(_ name: String, _ uti: String) throws -> NSPrintInfo {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/fixtures/office/\(name)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(name) is not in this checkout (docs/ is gitignored)")
        }
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: Data(contentsOf: url), ofType: uti)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 800), display: false)
        spin(0.6)
        return wc.makePrintOperation().printInfo
    }

    func testAPagedDocumentPrintsFromTheTopLeftOfItsPage() throws {
        let info = try openAndPrintInfo("bus-headings.docx", "org.openxmlformats.wordprocessingml.document")
        XCTAssertFalse(info.isVerticallyCentered, "a page must begin at its top margin, not halfway down")
        XCTAssertFalse(info.isHorizontallyCentered, "and at its left margin, not halfway across")
    }

    func testAShortPlainTextDocumentPrintsFromTheTopToo() throws {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-origin-\(UUID().uuidString).txt")
        // Deliberately far shorter than a page: this is the only shape that shows the bug at all.
        try doc.read(from: Data("CREATE TABLE t (\n  id INT\n);\n".utf8), ofType: "public.plain-text")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 800), display: false)
        spin(0.6)
        let info = wc.makePrintOperation().printInfo
        XCTAssertFalse(info.isVerticallyCentered, "a few lines must print at the top of the sheet")
        XCTAssertFalse(info.isHorizontallyCentered)
    }
}
