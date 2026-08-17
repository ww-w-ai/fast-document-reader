import XCTest
import AppKit
@testable import FastDocReader

/// A PICTURE pinned to its paragraph — which is what a scanned 도장 in a Korean contract is.
///
/// The drawing branch has had this since invariant 81 ("a seal over a signature line, an arrow onto
/// the table beside it"); the picture branch never did. `anchoredFrame` answers only for paper- and
/// page-relative objects, so a 문단 기준 picture fell through to the flow and was drawn inline at its
/// paragraph's own left edge with BOTH declared offsets discarded. Measured on a real contract: the
/// seal declares column + 285.9pt, 155.3pt below its line, and was drawn at the body margin — 264pt
/// left of where the document puts it, on the page whose whole purpose is the signature block.
final class HwpSealAnchorTests: XCTestCase {

    private func envelope(_ blocks: String) -> String {
        """
        {"v":1,"pageContentWidth":481.9,"pageContentHeight":700.14,
         "pageMarginLeft":56.69,"pageMarginTop":70.87,
         "pageMarginRight":56.69,"pageMarginBottom":70.87,
         "blocks":[\(blocks)]}
        """
    }

    /// The contract's own seal: 48 × 48pt, 어울림 없음, column-relative + 285.9pt across,
    /// paragraph-relative + 155.3pt down.
    private let seal = """
    {"t":"image","binDataId":9,"w":4800,"h":4800,"mime":"image/png","asChar":false,
     "vertRelTo":"para","horzRelTo":"column","vertAlign":"top","horzAlign":"left",
     "offsetX":28590,"offsetY":15530}
    """

    private func provider() -> ((Int) -> Data?) {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!
        return { _ in png }
    }

    func testASealPinnedToItsParagraphIsPlacedByItsOwnOffsets() throws {
        let r = try HwpReader.mapJSON(envelope(seal), pictureProvider: provider())
        let anchored = try XCTUnwrap(r.anchoredObjects.first, "a 문단 기준 seal must leave the flow")
        // Horizontal is settled at read time: the column's left edge plus the declared offset.
        XCTAssertEqual(anchored.object.frame.minX, 56.69 + 285.9, accuracy: 0.05)
        XCTAssertEqual(anchored.object.frame.width, 48, accuracy: 0.05)
        // Vertical is NOT settled here — only layout knows where the anchoring line ended up, so the
        // reader hands on the rule instead of a number (invariant 81).
        let anchor = try XCTUnwrap(anchored.paragraphAnchor)
        XCTAssertEqual(anchor.align, .top)
        XCTAssertEqual(anchor.offset, 155.3, accuracy: 0.05)
        // And nothing is left in the flow to push the signature block around.
        if case .image = r.blocks.first { XCTFail("the seal must not also be drawn inline") }
    }

    /// A seal that WRAPS text holds its space and stays in the flow — the same rule invariant 86
    /// measured for every other anchored object.
    func testAWrappingPictureStaysInTheFlow() throws {
        let wrapping = seal.replacingOccurrences(of: "\"asChar\":false",
                                                 with: "\"asChar\":false,\"wrapsText\":true")
        let r = try HwpReader.mapJSON(envelope(wrapping), pictureProvider: provider())
        XCTAssertTrue(r.anchoredObjects.isEmpty)
        if case .image = try XCTUnwrap(r.blocks.first) {} else { XCTFail("expected an inline image") }
    }
}
