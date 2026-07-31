import XCTest
import AppKit
@testable import FastDocReader

/// Every picture is on the paper, including the ones the reader never scrolled to.
///
/// Pixels are held lazily, for a window either side of the viewport (invariant 1), which is right for
/// reading and wrong for printing: paper has no viewport. Measured on a 14.4 MB report carrying 28
/// PNGs — printing it straight after opening produced a 50-page PDF with ONE image object in it and a
/// file 1.9 MB long, where the fixed path gives 43 and 14.1 MB. Nothing warned; the pictures simply
/// came out as blank reserved space in a file meant to be sent to someone.
///
/// The window here is deliberately tiny, which is the whole test: at 1200×900 a small fixture's
/// images all fall inside the ±1.5-screen keep-range and the bug is invisible. Shrinking the viewport
/// puts them outside it, which is what a long document does to its own later pages for free.
///
/// Asserted on the ATTACHMENTS rather than by parsing the produced PDF, so the failure names the
/// cause ("this attachment has no pixels") instead of a byte count, and so the test does not depend
/// on how Quartz chooses to encode an image object.
final class PrintMediaCompletenessTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private static func fixture(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/fixtures/office/\(name)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(name) is not in this checkout (docs/ is gitignored)")
        }
        return url
    }

    /// Counts attachments that reserve space but hold no pixels. An UNDRAWABLE picture is excluded on
    /// purpose: a WMF this reader cannot decode legitimately has no image and names its format instead
    /// (invariant 54), so counting it here would demand something impossible and make the test lie.
    private func attachmentsWithoutPixels(_ storage: NSTextStorage) -> Int {
        var missing = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            guard let att = v as? NSTextAttachment else { return }
            guard let cell = att.attachmentCell as? SizedAttachmentCell else { return }
            if att.image == nil && cell.undrawableLabel == nil { missing += 1 }
        }
        return missing
    }

    func testPreparingToPrintLoadsEveryPicture() throws {
        let url = try Self.fixture("embed.docx")
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: Data(contentsOf: url), ofType: "org.openxmlformats.wordprocessingml.document")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        // Small enough that most of the document — and its pictures — is outside the keep-range.
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 500, height: 240), display: false)
        spin(1.0)
        let storage = try XCTUnwrap(wc.textStorageRef)

        let attachments = storage.length > 0 ? {
            var n = 0
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
                if v is NSTextAttachment { n += 1 }
            }
            return n
        }() : 0
        try XCTSkipIf(attachments == 0, "this fixture no longer carries any pictures to lose")

        _ = wc.makePrintOperation()
        XCTAssertEqual(attachmentsWithoutPixels(storage), 0,
                       "preparing to print must fill every attachment that CAN hold pixels — "
                       + "\(attachments) attachment(s) in this document")
    }
}
