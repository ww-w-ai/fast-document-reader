import XCTest
import AppKit
@testable import FastDocReader

/// Regression coverage for the reading-size ownership fix. The size used to live in ONE shared,
/// `UserDefaults`-backed `FontSizeStore.size` that every open document's render read from — so
/// pressing ⌘+ in one window silently changed what every OTHER window would draw the next time
/// ANYTHING made it re-render, even a window nobody had touched (measured: two documents open,
/// one ⌘+ press, exactly one re-render — the untouched window kept its old pixels only because
/// nothing had made it redraw yet). `MarkdownDocument.readingSize` fixes this: each document owns
/// its own value, SEEDED once at creation from `FontSizeStore.startingSize` (the last size the
/// reader chose, which is what keeps "remembered next time" true across launches) and never read
/// from anywhere again — that single read at creation, and the absence of any later one, is the
/// whole distinction between the two designs.
///
/// Both tests assert on the RENDERED attributed string (the `.font` attribute a real render leaves
/// on the storage) — never on a stored number. A passing assertion on `doc.readingSize` alone would
/// prove the property was set, not that anything on screen actually reflects it.
final class PerDocumentFontSizeTests: XCTestCase {
    /// The reading size is now SEEDED from a persisted value (`FontSizeStore.startingSize`), so a
    /// test that changes a document's size leaks into every later test's freshly opened document —
    /// which is a property of the feature, not a bug, but it makes test order significant. Reset it
    /// on both sides so this class neither inherits nor exports a size.
    override func setUp() { super.setUp(); FontSizeStore.startingSize = FontSizeStore.defaultSize }
    override func tearDown() { FontSizeStore.startingSize = FontSizeStore.defaultSize; super.tearDown() }
    private var temp: URL!

    override func setUpWithError() throws {
        temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-perdocfont-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    /// Opens a markdown document through the real read + window-controller path, backed by a real
    /// file on disk — `reloadDocument` (used below to force a SECOND document to re-render for a
    /// reason that has nothing to do with font size) reads from disk, so the document needs one.
    private func open(_ source: String, name: String) throws -> (MarkdownDocument, DocumentWindowController) {
        let url = temp.appendingPathComponent(name)
        try Data(source.utf8).write(to: url)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: Data(source.utf8), ofType: "public.plain-text")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
        return (doc, wc)
    }

    /// ⌘+/⌘−'s rebuild runs on a `runBusy` dispatch (`DispatchQueue.main.async`, plus a leading-edge
    /// debounce) rather than synchronously — mirrors `ImageHeaderCacheTests.waitForAsyncTail`.
    private func waitForAsyncTail(_ seconds: TimeInterval = 0.3) {
        let exp = expectation(description: "async tail settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 2)
    }

    private func bodyFontPointSize(_ wc: DocumentWindowController) throws -> CGFloat {
        let storage = try XCTUnwrap(wc.textStorageRef)
        let font = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        return font.pointSize
    }

    // MARK: (a) Isolation

    /// ⌘+ in document A must not move what document B draws — not immediately, and not the next
    /// time something ELSE makes B re-render either. The second half is the part the old shared
    /// `FontSizeStore.size` broke: A's press changed the one global, so the moment anything (here,
    /// ⌘R — chosen specifically because it has nothing to do with font size) forced B to rebuild
    /// its attributed string, B would silently jump to A's size even though nobody had touched B's
    /// font at all.
    func testIncreasingOneDocumentsFontSizeLeavesAnotherDocumentUntouchedEvenAfterItReRenders() throws {
        let (docA, wcA) = try open("Alpha body text.\n", name: "a.md")
        let (docB, wcB) = try open("Bravo body text.\n", name: "b.md")

        XCTAssertEqual(try bodyFontPointSize(wcA), FontSizeStore.defaultSize)
        XCTAssertEqual(try bodyFontPointSize(wcB), FontSizeStore.defaultSize)

        docA.increaseReaderFontSize(nil)
        waitForAsyncTail()
        XCTAssertEqual(try bodyFontPointSize(wcA), FontSizeStore.defaultSize + 1,
                       "document A's own rendered text must grow")

        // B has not been touched at all — its rendered text must be exactly what it was.
        XCTAssertEqual(try bodyFontPointSize(wcB), FontSizeStore.defaultSize,
                       "an untouched document's rendered text must not react to another document's ⌘+")

        // Now force B to re-render for a reason that has NOTHING to do with font size — this is
        // exactly the moment the old shared global used to leak into it.
        docB.reloadDocument(nil)
        XCTAssertEqual(try bodyFontPointSize(wcB), FontSizeStore.defaultSize,
                       "B re-rendering for an unrelated reason (reload) must still draw at B's OWN " +
                       "size, not the size A happens to be at now")
    }

    // MARK: (b) A new document is SEEDED, and the seed is read exactly once

    /// A newly created document starts at the last size the reader chose — that single read at
    /// creation is what keeps "remembered next time" true. What it must NOT do is keep reading:
    /// once C exists, changing A again cannot move C. Both halves are asserted here, because the
    /// first one alone is satisfied by the very shared-global design this replaced.
    func testANewDocumentStartsAtTheLastChosenSizeAndThenStopsListening() throws {
        let (docA, wcA) = try open("Alpha body text.\n", name: "a.md")
        docA.increaseReaderFontSize(nil)
        docA.increaseReaderFontSize(nil)
        docA.increaseReaderFontSize(nil)
        waitForAsyncTail()
        let raised = FontSizeStore.defaultSize + 3
        XCTAssertEqual(try bodyFontPointSize(wcA), raised,
                       "sanity: A must actually have moved, or this test proves nothing")

        let (_, wcC) = try open("Charlie body text.\n", name: "c.md")
        XCTAssertEqual(try bodyFontPointSize(wcC), raised,
                       "a newly opened document starts at the last size the reader chose")

        // The half that catches a regression back to shared state: A moves again, C must not.
        docA.increaseReaderFontSize(nil)
        waitForAsyncTail()
        XCTAssertEqual(try bodyFontPointSize(wcA), raised + 1, "A moved")
        XCTAssertEqual(try bodyFontPointSize(wcC), raised,
                       "C was seeded at creation and never listens again — A's later change cannot reach it")
    }

    // MARK: The seed persists; a document's own size does not leak

    /// The reader's chosen size survives a relaunch — the README and the App Store description both
    /// promise it — and it is implemented as a SEED that a new document reads once, never as a value
    /// an open document consults while rendering. That distinction is the whole fix: the old design
    /// kept the same promise with one shared mutable value that every render read, which is exactly
    /// how one window's ⌘+ silently changed another's.
    func testChangingTheReadingSizeRecordsTheSeedForTheNextDocument() throws {
        UserDefaults.standard.removeObject(forKey: "baseFontSize")
        XCTAssertEqual(FontSizeStore.startingSize, FontSizeStore.defaultSize,
                       "with nothing stored, a new document starts at the default")

        let (doc, _) = try open("Body.\n", name: "persist.md")
        doc.increaseReaderFontSize(nil)
        waitForAsyncTail()
        XCTAssertEqual(FontSizeStore.startingSize, FontSizeStore.defaultSize + 1,
                       "the chosen size is recorded, so the next launch reopens at it")
        XCTAssertEqual(UserDefaults.standard.object(forKey: "baseFontSize") as? Double,
                       Double(FontSizeStore.defaultSize + 1),
                       "and it is recorded in the key a 1.0 install already uses, so an existing reader's remembered size still applies")
    }
}
