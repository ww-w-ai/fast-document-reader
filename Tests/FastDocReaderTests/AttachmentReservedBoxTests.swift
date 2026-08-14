import XCTest
import AppKit
@testable import FastDocReader

/// The defect: pixels arriving on `attachment.image` make AppKit drop the sized cell and lay the
/// picture out from its NATURAL size, so the drawn image and the clickable/selectable box stop
/// agreeing with the reserved box the document asked for.
final class AttachmentReservedBoxTests: XCTestCase {

    private func pixels(_ size: NSSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        return img
    }

    func testTheLaidOutBoxStaysTheReservedOneWhenPixelsArriveOnTheCell() {
        let reserved = NSSize(width: 348, height: 79)          // what the document declared
        let att = NSTextAttachment()
        att.bounds = NSRect(origin: .zero, size: reserved)
        let cell = SizedAttachmentCell(reservedSize: reserved)
        att.attachmentCell = cell
        let attr = NSMutableAttributedString(attachment: att)

        // The picture's own pixels are a completely different shape (measured worst case: 593×363
        // against a 348×79 box, a 2.7× aspect difference).
        cell.pixels = pixels(NSSize(width: 593, height: 363))

        let storage = NSTextStorage(attributedString: attr)
        let lm = NSLayoutManager(); storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0; lm.addTextContainer(tc); lm.ensureLayout(for: tc)
        let bounds = lm.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: tc)
        XCTAssertEqual(bounds.height, reserved.height, accuracy: 0.5,
                       "the reserved box governs layout, whether pixels are loaded or not")
        XCTAssertNotNil(att.attachmentCell as? SizedAttachmentCell,
                        "the cell must survive the pixels arriving (invariant 31)")
    }

    func testPixelsOnTheATTACHMENTAreWhatBreaksIt() {
        // The same picture, attached the tempting way — kept as the record of WHY the cell holds
        // the pixels. AppKit drops the cell and lays out from the image instead.
        let reserved = NSSize(width: 348, height: 79)
        let att = NSTextAttachment()
        att.bounds = NSRect(origin: .zero, size: reserved)
        att.attachmentCell = SizedAttachmentCell(reservedSize: reserved)
        att.image = pixels(NSSize(width: 593, height: 363))
        XCTAssertNil(att.attachmentCell as? SizedAttachmentCell,
                     "setting .image discards the sized cell — invariant 31")
    }
}
