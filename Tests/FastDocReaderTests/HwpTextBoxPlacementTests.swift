import XCTest
import AppKit
@testable import FastDocReader

/// Where the words INSIDE a drawing's text box are laid out.
///
/// A Korean document builds its cover and its foreword out of a picture frame with a box of text
/// sitting inside it. Before this, those paragraphs flowed down the full body column — beside the
/// frame they belong in rather than within it. The box states where it is in ITS OWN DRAWING's
/// frame, so the reader adds that drawing's origin and turns what is left into an indent.
final class HwpTextBoxPlacementTests: XCTestCase {

    /// Paper 555.6 × 754 with a 73.7pt left margin and a 395.7pt body column — the 편람's own numbers,
    /// so the arithmetic below is the arithmetic a real document produces.
    private func envelope(_ blocksJSON: String) -> String {
        """
        {"v":1,"pageContentWidth":395.72,"pageContentHeight":555.59,
         "pageMarginLeft":73.7,"pageMarginTop":110.56,
         "pageMarginRight":86.17,"pageMarginBottom":87.87,
         "blocks":[\(blocksJSON)]}
        """
    }

    /// A paper-anchored picture, 476.4pt wide (HWPUNIT ×100), pinned 20pt in from the paper's left
    /// edge. The offset is deliberately NOT zero: a frame at the origin makes "the box is measured
    /// from its drawing" and "the box is measured from the paper" produce the same answer, and a test
    /// that cannot tell those apart proves nothing.
    private let frameOriginX: CGFloat = 20
    private let frameImage = """
    {"t":"image","binDataId":354,"w":47640,"h":68880,"mime":"image/png","asChar":false,
     "vertRelTo":"paper","horzRelTo":"paper","vertAlign":"top","horzAlign":"left",
     "offsetX":2000,"offsetY":0}
    """

    /// A 1×1 PNG, so the image branch that RECORDS the owner's frame is actually taken — without
    /// bytes the reader leaves the picture in the flow and there is no frame to measure against.
    private func pictureProvider() -> ((Int) -> Data?) {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
        return { _ in png }
    }

    private func format(_ block: OfficeBlock) -> ParagraphFormat? {
        if case .paragraph(_, _, _, _, let format) = block { return format }
        return nil
    }

    // MARK: the box moves the paragraph

    func testABoxedParagraphIsIndentedToItsOwnBox() throws {
        // Box at x 108pt, 309.1pt wide, in the frame's own coordinates. The frame sits at paper x 20,
        // so the box is at paper x 128 — 54.3pt inside the body column, which starts at 73.7.
        let para = """
        {"t":"para","spans":[{"text":"발간사"}],
         "boxX":10800,"boxY":36720,"boxW":30910,"boxH":23620}
        """
        let blocks = try HwpReader.mapJSON(envelope("\(frameImage),\(para)"),
                                           pictureProvider: pictureProvider()).blocks
        let f = try XCTUnwrap(format(blocks[1]))
        let boxPaperX = frameOriginX + 108.0
        XCTAssertEqual(try XCTUnwrap(f.indentStart), boxPaperX - 73.7, accuracy: 0.05)
        // What is left of the column once the box's own width is taken off the near edge.
        XCTAssertEqual(try XCTUnwrap(f.indentEnd), 395.72 - (boxPaperX - 73.7) - 309.1, accuracy: 0.05)
        // The paragraph is left with the box's own width, which is the whole point.
        let width = 395.72 - f.indentStart! - f.indentEnd!
        XCTAssertEqual(width, 309.1, accuracy: 0.05)
    }

    // MARK: what must NOT happen

    /// The first attempt at this took a group child's `common` offsets for paper coordinates. They
    /// are not coordinates at all — a child's `common` is empty — so 1,510 paragraphs of the 편람 took
    /// an indent that left them almost no width and the document went 520 pages to 436. A box that
    /// does not leave a readable column is refused rather than obeyed.
    func testABoxTooNarrowToReadIsIgnored() throws {
        let para = """
        {"t":"para","spans":[{"text":"x"}],
         "boxX":10800,"boxY":0,"boxW":2000,"boxH":1000}
        """
        let blocks = try HwpReader.mapJSON(envelope("\(frameImage),\(para)"),
                                           pictureProvider: pictureProvider()).blocks
        let f = try XCTUnwrap(format(blocks[1]))
        XCTAssertNil(f.indentStart, "a 20pt column is not a placement, it is a misread coordinate")
        XCTAssertNil(f.indentEnd)
    }

    /// A box coordinate is measured from a drawing's frame. With no drawing before it there is no
    /// frame to measure from, and guessing the paper's own origin would put the words somewhere the
    /// document never said.
    func testABoxWithNoOwningDrawingIsIgnored() throws {
        let para = """
        {"t":"para","spans":[{"text":"x"}],
         "boxX":10800,"boxY":36720,"boxW":30910,"boxH":23620}
        """
        let blocks = try HwpReader.mapJSON(envelope(para)).blocks
        let f = try XCTUnwrap(format(blocks[0]))
        XCTAssertNil(f.indentStart)
    }

    /// An ordinary body paragraph is untouched — the box path must not reach it.
    func testABodyParagraphKeepsTheFullColumn() throws {
        let blocks = try HwpReader.mapJSON(
            envelope("\(frameImage),{\"t\":\"para\",\"spans\":[{\"text\":\"본문\"}]}"),
            pictureProvider: pictureProvider()).blocks
        let f = try XCTUnwrap(format(blocks[1]))
        XCTAssertNil(f.indentStart)
        XCTAssertNil(f.indentEnd)
    }
}

/// What each SECTION says its own paper is.
///
/// HWP defines a page per section, and this reader kept only the section with the most paragraphs
/// (invariant 73) — so a document whose appendix declares a different sheet was typeset on the
/// body's. Measured on `2025 행정업무운영 편람`: the body's 396.9 × 555.6pt against the appendix's
/// 413.9 × 612.3pt, which threw away 56.7pt of every appendix page.
final class HwpSectionPaperTests: XCTestCase {

    func testEachSectionCarriesTheSheetItDeclared() throws {
        let json = """
        {"v":1,"pageContentWidth":396.86,"pageContentHeight":555.59,
         "sections":[
           {"page":{"contentWidth":396.86,"contentHeight":555.59,"marginLeft":73.7,
                    "marginRight":86.2,"marginTop":110.6,"marginBottom":87.9}},
           {"page":{"contentWidth":413.87,"contentHeight":612.32,"marginLeft":70.9,
                    "marginRight":70.9,"marginTop":70.8,"marginBottom":70.8},"hideHeader":true}],
         "blocks":[]}
        """
        let sections = try HwpReader.mapJSON(json).sections
        XCTAssertEqual(sections.count, 2)
        let body = try XCTUnwrap(sections[0].paper)
        let appendix = try XCTUnwrap(sections[1].paper)
        XCTAssertEqual(body.contentHeight, 555.59, accuracy: 0.01)
        XCTAssertEqual(appendix.contentHeight, 612.32, accuracy: 0.01)
        // The whole point: the two sheets are NOT the same, and the reader can now tell.
        XCTAssertNotEqual(body, appendix)
        // The paper a page is cut from, margins included.
        XCTAssertEqual(appendix.paperWidth, 70.9 + 413.87 + 70.9, accuracy: 0.01)
        XCTAssertEqual(appendix.paperHeight, 70.8 + 612.32 + 70.8, accuracy: 0.01)
        // The section's other declarations still decode beside it.
        XCTAssertTrue(sections[1].hidesHeader)
    }

    /// A section that states no page of its own says so, rather than inheriting a sheet nobody
    /// declared — the same distinction invariant 83 keeps for everything else in this vocabulary.
    func testASectionThatDeclaredNoPageSaysSo() throws {
        let sections = try HwpReader.mapJSON(
            "{\"v\":1,\"sections\":[{\"hideFooter\":true}],\"blocks\":[]}").sections
        XCTAssertNil(try XCTUnwrap(sections.first).paper)
    }
}
