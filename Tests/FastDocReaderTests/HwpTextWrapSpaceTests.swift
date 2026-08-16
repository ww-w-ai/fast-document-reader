import XCTest
import AppKit
@testable import FastDocReader

/// Whether an anchored object holds SPACE in the text flow.
///
/// HWP says it with `textWrap`: 어울림/자연스럽게/통과/위아래 push the text out of the object's way, so
/// the object occupies the flow; 글 앞으로/글 뒤로 are painted over or behind it and hold nothing.
/// This reader floated BOTH kinds, which took away the space the wrapping ones were holding — and
/// every page that space was making went with it. Measured across 2,066 real documents: 7 lost one
/// or two pages each, and `pic2.hwp` went from 3 pages to 1 with its four pictures piled on top of
/// each other on the only page left.
final class HwpTextWrapSpaceTests: XCTestCase {

    private func envelope(_ blocks: String) -> String {
        """
        {"v":1,"pageContentWidth":395.72,"pageContentHeight":555.59,
         "pageMarginLeft":73.7,"pageMarginTop":110.6,"pageMarginRight":86.2,"pageMarginBottom":87.9,
         "blocks":[\(blocks)]}
        """
    }

    private func picture(wraps: Bool?) -> String {
        let wrap = wraps.map { ",\"wrapsText\":\($0)" } ?? ""
        return """
        {"t":"image","binDataId":7,"w":23400,"h":29600,"mime":"image/png","asChar":false,
         "vertRelTo":"paper","horzRelTo":"paper","vertAlign":"top","horzAlign":"left",
         "offsetX":9574,"offsetY":9900\(wrap)}
        """
    }

    private func pictureProvider() -> ((Int) -> Data?) {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!
        return { _ in png }
    }

    private func isImageBlock(_ block: OfficeBlock) -> Bool {
        if case .image = block { return true }
        return false
    }

    /// 어울림 / 위아래: the object stays in the flow, where it still holds the height it is holding
    /// in the document. It is NOT taken onto the sheet.
    func testAWrappingObjectKeepsItsPlaceInTheFlow() throws {
        let r = try HwpReader.mapJSON(envelope(picture(wraps: true)),
                                      pictureProvider: pictureProvider())
        XCTAssertTrue(r.anchoredObjects.isEmpty, "a wrapping object must not be floated onto the sheet")
        XCTAssertTrue(isImageBlock(try XCTUnwrap(r.blocks.first)), "it stays a block in the text")
    }

    /// 글 앞으로 / 글 뒤로: painted on the sheet at the document's own coordinates, holding no space —
    /// this is the cover artwork that must not push the page apart.
    func testAnInFrontObjectIsFloatedOntoTheSheet() throws {
        let r = try HwpReader.mapJSON(envelope(picture(wraps: false)),
                                      pictureProvider: pictureProvider())
        XCTAssertEqual(r.anchoredObjects.count, 1)
        // Placed by the document's own offsets, not by where text happened to reach.
        let frame = try XCTUnwrap(r.anchoredObjects.first).object.frame
        XCTAssertEqual(frame.minX, 95.74, accuracy: 0.01)
        XCTAssertEqual(frame.minY, 99.0, accuracy: 0.01)
    }

    /// A parser predating the export says nothing, and this reader then treats the object the way it
    /// did before the field existed — floated, which is what the cover needs.
    func testAnObjectWithNoWrapStatedIsFloatedAsBefore() throws {
        let r = try HwpReader.mapJSON(envelope(picture(wraps: nil)),
                                      pictureProvider: pictureProvider())
        XCTAssertEqual(r.anchoredObjects.count, 1)
    }
}
