import XCTest
import AppKit
@testable import FastDocReader

/// When the decoded-image caches are dropped.
///
/// Only the WHEN is tested here, deliberately. `NSCache` exposes no count and no enumeration, so
/// "the images really went away" has no assertion available to it and was verified by measuring the
/// shipped app instead: opening a 10.7 MB HWP took the process to 212 MB and closing it returned it
/// to 115 MB, against 234 MB → 234 MB with this hook removed — the mutation this file cannot perform
/// (invariant 56's precedent for a property whose only honest evidence is a measurement, written
/// down where the next author will look rather than faked as a green assertion).
///
/// The half that CAN regress silently is the trigger, which is why it has a counter and a test: the
/// guard is `NSDocumentController.shared.documents.isEmpty` read one run-loop turn after
/// `super.close()`, and both parts are load-bearing. Read it any earlier — on
/// `NSWindow.willCloseNotification`, say — and the closing document is still registered, so the
/// count is never zero and the purge never runs at all.
final class ImageCachePurgeTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func openDocument(_ markdown: String) throws -> MarkdownDocument {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-purge-\(UUID().uuidString).md")
        try doc.read(from: Data(markdown.utf8), ofType: "net.daringfireball.markdown")
        NSDocumentController.shared.addDocument(doc)
        return doc
    }

    func testClosingTheLastDocumentPurgesTheImageCaches() throws {
        // Anything already open in this test process would make the count non-zero for reasons that
        // have nothing to do with this test — the suite shares one NSDocumentController.
        for existing in NSDocumentController.shared.documents { existing.close() }
        spin(0.2)

        let before = MarkdownDocument.imageCachePurgeCount
        let doc = try openDocument("# only document\n\ntext\n")
        doc.close()
        spin(0.3)                       // the purge is deferred exactly one run-loop turn
        XCTAssertEqual(MarkdownDocument.imageCachePurgeCount, before + 1,
                       "closing the last document should have dropped the decoded-image caches")
    }

    func testClosingOneOfTwoDocumentsPurgesNothing() throws {
        for existing in NSDocumentController.shared.documents { existing.close() }
        spin(0.2)

        let stays = try openDocument("# stays open\n")
        let goes = try openDocument("# closes\n")
        let before = MarkdownDocument.imageCachePurgeCount
        goes.close()
        spin(0.3)
        XCTAssertEqual(MarkdownDocument.imageCachePurgeCount, before,
                       "a document that is still open is still using those images — purging here "
                       + "would make scrolling back to a picture re-decode it")
        stays.close()
        spin(0.3)
    }
}
