import XCTest
import AppKit
@testable import FastDocReader

/// The Finder preview builds the document through the reader's own path, so what it shows is the
/// document's real text rather than a second, simpler rendering of it. Quick Look itself cannot be
/// driven from a test — what CAN be checked here is the part that would silently rot: that
/// `preparePreviewOfFile` produces a live view carrying the document's own words.
///
/// What this cannot see (invariant 29's seam, checked by hand): whether macOS actually routes a file
/// to this extension. Measured by previewing one of each format and watching which extension process
/// runs — `.md`, `.hwp` and the config-file types come to us; `.docx`/`.odt` are kept by Apple's own.
@MainActor
final class QuickLookPreviewTests: XCTestCase {

    func testThePreviewCarriesTheDocumentsOwnText() async throws {
        let url = repoRoot().appendingPathComponent("demo/code-blocks.md")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))

        let controller = QuickLookPreviewController()
        _ = controller.view                       // force loadView, as Quick Look does
        try await controller.preparePreviewOfFile(at: url)

        let text = firstTextView(in: controller.view)
        XCTAssertNotNil(text, "the preview installed no text view — nothing would be drawn")
        let shown = text?.string ?? ""
        let source = try String(contentsOf: url, encoding: .utf8)
        // A heading from the fixture, as the RENDERED text (the marker itself is consumed), which is
        // what tells a real render apart from dumping the file's bytes into a box.
        let heading = "Every language the reader highlights"
        XCTAssertTrue(shown.contains(heading), "expected the document's own heading in the preview")
        XCTAssertFalse(shown.contains("# " + heading),
                       "the preview is showing raw Markdown source — it must render like the reader")
        XCTAssertTrue(source.contains("# " + heading), "fixture changed; pick another anchor")
    }

    func testAnUnreadableFileFailsInsteadOfShowingAnEmptyPreview() async {
        let controller = QuickLookPreviewController()
        _ = controller.view
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).docx")
        do {
            try await controller.preparePreviewOfFile(at: missing)
            XCTFail("a file that cannot be read must throw, so Quick Look can fall back")
        } catch {
            // expected
        }
    }

    // MARK: - How much of a document a preview renders

    func testAShortDocumentIsShownWhole() {
        let text = "# Title\n\nA paragraph.\n"
        XCTAssertEqual(QuickLookPreviewController.previewSource(text), text)
    }

    func testALongDocumentIsCutAtABlankLineAndSaysSo() {
        let para = String(repeating: "word ", count: 40) + "\n\n"
        let text = String(repeating: para, count: 200)          // well past any sane limit
        let head = QuickLookPreviewController.previewSource(text, limit: 1_000)

        XCTAssertLessThan(head.count, 1_400, "the cut must actually bound the work")
        XCTAssertTrue(head.contains("Preview shows the beginning"),
                      "a shortened preview must say it is shortened — silent truncation is the one "
                    + "thing this must not do")
        let body = head.components(separatedBy: "\n\n---\n\n")[0]
        XCTAssertTrue(body.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("word"),
                      "cut at a blank line, not mid-sentence")
    }

    func testACutInsideACodeFenceClosesIt() {
        let text = "intro\n\n```swift\n" + String(repeating: "let x = 1\n", count: 500) + "```\n"
        let head = QuickLookPreviewController.previewSource(text, limit: 200)
        XCTAssertEqual(head.components(separatedBy: "```").count % 2, 1,
                       "an unclosed fence would render the rest of the preview as code")
    }

    // MARK: - Content only, no paper

    func testAPagedDocumentPreviewsAsContentWithoutItsPage() throws {
        let fixture = repoRoot().appendingPathComponent("docs/fixtures/office/paged-visual/tablepage.docx")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path))

        let paged = MarkdownDocument()
        paged.fileURL = fixture
        try paged.read(from: try Data(contentsOf: fixture), ofType: "public.data")
        XCTAssertNotNil(paged.officePageContentWidth, "fixture must be a paged document to prove anything")

        let previewed = MarkdownDocument()
        previewed.fileURL = fixture
        try previewed.read(from: try Data(contentsOf: fixture), ofType: "public.data")
        previewed.flattenPagesForPreview()
        XCTAssertNil(previewed.officePageContentWidth, "a preview shows content, not paper")
        XCTAssertNil(previewed.officePageMarginLeft)
        XCTAssertTrue(previewed.officeHeaders.isEmpty, "no running header in a preview panel")
        XCTAssertTrue(previewed.officeFooters.isEmpty)
    }

    private func firstTextView(in view: NSView) -> NSTextView? {
        if let t = view as? NSTextView { return t }
        for sub in view.subviews {
            if let found = firstTextView(in: sub) { return found }
        }
        return nil
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
