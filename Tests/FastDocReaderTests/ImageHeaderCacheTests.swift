import XCTest
import AppKit
@testable import FastDocReader

/// `presizeKnownMedia` calls `imagePixelSize` (an ImageIO header-only read, no full decode) for
/// EVERY local image in the document, from FOUR async tails: `render(into:)` (every ⌘+ press),
/// `spliceRender` (every edit), plus the diagram- and remote-image-measurement passes. A local
/// image's own pixel dimensions never change between those passes, so re-reading the header each
/// time was pure waste — measured 0.117 ms/image elsewhere (406 images ≈ 48 ms per pass). These
/// tests pin the deterministic knob: `MarkdownDocument.imageHeaderReadCount` (a cache-MISS-only
/// counter) must equal the document's local-image count on the very first pass, and 0 more on
/// every pass after — not a screenshot, not a stopwatch.
final class ImageHeaderCacheTests: XCTestCase {
    /// The reading size is now SEEDED from a persisted value (`FontSizeStore.startingSize`), so a
    /// test that changes a document's size leaks into every later test's freshly opened document —
    /// which is a property of the feature, not a bug, but it makes test order significant. Reset it
    /// on both sides so this class neither inherits nor exports a size.
    override func setUp() { super.setUp(); FontSizeStore.startingSize = FontSizeStore.defaultSize }
    override func tearDown() { FontSizeStore.startingSize = FontSizeStore.defaultSize; super.tearDown() }
    private var temp: URL!

    override func setUpWithError() throws {
        temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-imgcache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
        // No FontSizeStore.reset() needed any more: the reading size lives on each MarkdownDocument
        // instance now, not in UserDefaults, so there's nothing here that can leak into another test.
    }

    /// A tiny real PNG (decodes via ImageIO) — not just arbitrary bytes, since the header-read path
    /// genuinely parses what it's given. Mirrors `OfficeImageLoadingTests.pngData`.
    private func pngData(width: Int, height: Int) -> Data {
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        img.unlockFocus()
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    /// The async tails this cache is measured across (`render(into:)`/`spliceRender`) dispatch via
    /// plain `DispatchQueue.main.async`, chained through `runBusy`'s own async hop for a font-size
    /// change — this drains the queue the same way `OfficeImageLoadingTests` does for its own
    /// (differently-sourced) async image loads.
    private func waitForAsyncTail(_ seconds: TimeInterval = 0.3) {
        let exp = expectation(description: "async tail settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 2)
    }

    private func openMarkdown(_ source: String, at url: URL) throws -> (MarkdownDocument, DocumentWindowController) {
        try Data(source.utf8).write(to: url)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: Data(source.utf8), ofType: "public.plain-text")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
        return (doc, wc)
    }

    func testHeaderIsReadOnceThenReusedAcrossAFontSizeChangeAndAnEdit() throws {
        let imageCount = 5
        var markdown = ""
        for i in 0..<imageCount {
            let imgURL = temp.appendingPathComponent("img\(i).png")
            try pngData(width: 40 + i, height: 30 + i).write(to: imgURL)
            markdown += "![pic \(i)](\(imgURL.path))\n\n"
        }
        markdown += "Some trailing paragraph.\n"
        let (doc, wc) = try openMarkdown(markdown, at: temp.appendingPathComponent("doc.md"))

        waitForAsyncTail()
        XCTAssertEqual(doc.imageHeaderReadCount, imageCount,
                       "the first render must read each distinct local image's header exactly once")

        // ⌘+ : the document re-renders at a new font size — every local image is presized again,
        // but none moved on disk, so the header cache must absorb this entirely.
        doc.increaseReaderFontSize(nil)
        waitForAsyncTail()
        XCTAssertEqual(doc.imageHeaderReadCount, imageCount,
                       "a font-size change must reuse cached headers, not re-read them")

        // An edit: spliceRender's async tail also calls presizeKnownMedia for the WHOLE document —
        // same expectation, since none of the images are anywhere near the edited block either.
        let storage = try XCTUnwrap(wc.textStorageRef)
        let spans = BlockEdit.spans(in: storage)
        doc.applySourceEdit(spans[spans.count - 1], with: "Some trailing paragraph, now edited.",
                           actionName: "Edit")
        waitForAsyncTail()
        XCTAssertEqual(doc.imageHeaderReadCount, imageCount,
                       "an edit must reuse cached headers too")
    }

    /// ⌘R re-reads the file from disk — a local image can have changed size since the last read
    /// (the file this test writes is a case in point), so the cache must be forgotten on reload,
    /// not carried forward as if the picture on disk were immutable.
    func testReloadClearsTheCacheSoAChangedImageIsPickedUpAgain() throws {
        let imgURL = temp.appendingPathComponent("img.png")
        try pngData(width: 40, height: 30).write(to: imgURL)
        let (doc, _) = try openMarkdown("![pic](\(imgURL.path))\n", at: temp.appendingPathComponent("doc.md"))
        waitForAsyncTail()
        XCTAssertEqual(doc.imageHeaderReadCount, 1)

        // The picture on disk changes size — a reload must re-measure it, never trust a stale
        // cached size left over from before the change.
        try pngData(width: 400, height: 300).write(to: imgURL)
        doc.reloadDocument(nil)
        waitForAsyncTail()
        XCTAssertEqual(doc.imageHeaderReadCount, 2,
                       "reload must re-read the header rather than reuse a stale cached size")
    }
}
