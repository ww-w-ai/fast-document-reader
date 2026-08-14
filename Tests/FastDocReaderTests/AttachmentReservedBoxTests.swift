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

    // MARK: The other half of holding the pixels: THIS cell now draws them

    /// The regression that shipped with the move. Once the pixels live on the cell, the app makes
    /// the draw call itself — and `draw(in:from:operation:fraction:)` ignores a flipped context, so
    /// every picture in every office document came out upside down. A whole-page cover reads as an
    /// obvious mirror; a photograph just reads as wrong.
    ///
    /// Drawn into a FLIPPED canvas, which is what the text view is. The source picture is red on
    /// top and blue underneath, so "which colour is at the top of the result" is the whole test.
    func testAPictureIsNotDrawnUpsideDownInAFlippedContext() throws {
        let source = NSImage(size: NSSize(width: 20, height: 20))
        source.lockFocus()
        NSColor.red.setFill();  NSRect(x: 0, y: 10, width: 20, height: 10).fill()   // image-space TOP
        NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 20, height: 10).fill()
        source.unlockFocus()

        let frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let cell = SizedAttachmentCell(reservedSize: frame.size)
        cell.attachment = NSTextAttachment()
        cell.pixels = source

        let canvas = NSImage(size: frame.size)
        canvas.lockFocusFlipped(true)
        cell.draw(withFrame: frame, in: nil)
        let rep = try XCTUnwrap(NSBitmapImageRep(focusedViewRect: frame))
        canvas.unlockFocus()

        // Row 0 is the TOP of the bitmap.
        let top = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: 4)?.usingColorSpace(.deviceRGB))
        let bottom = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2,
                                               y: rep.pixelsHigh - 5)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(top.redComponent, 0.5,
                             "the picture's own top must be at the top — got r\(top.redComponent) b\(top.blueComponent)")
        XCTAssertGreaterThan(bottom.blueComponent, 0.5,
                             "and its bottom at the bottom — got r\(bottom.redComponent) b\(bottom.blueComponent)")
    }
}
