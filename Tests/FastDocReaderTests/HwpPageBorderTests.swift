import XCTest
@testable import FastDocReader

/// The 쪽 테두리/배경 a section rules around its whole page.
///
/// rhwp's model has carried this since the beginning (`PageBorderFill`) and the export never
/// mentioned it, so a form that draws a frame around every page arrived as blank paper with no way
/// to tell that from a document that draws none (found by the export audit, invariant 83).
final class HwpPageBorderTests: XCTestCase {

    /// One fill table entry per test: id 1 rules a real 1pt line on all four edges, id 2 turns every
    /// edge off — which is what most HWP files' page fill actually is.
    private let fills = """
    {"left":{"type":"solid","widthPt":1,"color":"000000"},
     "right":{"type":"solid","widthPt":1,"color":"000000"},
     "top":{"type":"solid","widthPt":1,"color":"000000"},
     "bottom":{"type":"solid","widthPt":1,"color":"000000"}},
    {"left":{"type":"none"},"right":{"type":"none"},"top":{"type":"none"},"bottom":{"type":"none"}}
    """

    private func read(_ sections: String) throws -> [OfficeSectionDeclaration] {
        try HwpReader.mapJSON(
            "{\"v\":1,\"borderFills\":[\(fills)],\"sections\":[\(sections)],\"blocks\":[]}").sections
    }

    func testASectionCarriesTheFrameItRules() throws {
        let s = try read("""
        {"pageBorder":{"borderFillId":1,"spacingLeftHwpUnit":1417,"spacingRightHwpUnit":1417,
                       "spacingTopHwpUnit":1000,"spacingBottomHwpUnit":1000,"basis":"paper"}}
        """)
        let border = try XCTUnwrap(s.first?.pageBorder)
        // Resolved through the SAME table a cell's fill uses, at read time — the table does not
        // outlive the read, so an id kept for later would point at nothing.
        XCTAssertNotNil(border.borders?.top)
        XCTAssertTrue(border.drawsAnything)
        XCTAssertEqual(border.spacing.left, 14.17, accuracy: 0.01)
        XCTAssertEqual(border.spacing.top, 10.0, accuracy: 0.01)
        XCTAssertTrue(border.measuredFromPaper)
    }

    /// The basis is not decoration: measuring from the body area instead of the sheet moves the frame
    /// by a whole margin, so it has to arrive rather than be assumed.
    func testABodyBasedFrameSaysSo() throws {
        let s = try read("{\"pageBorder\":{\"borderFillId\":1,\"basis\":\"body\"}}")
        XCTAssertFalse(try XCTUnwrap(s.first?.pageBorder).measuredFromPaper)
    }

    /// A declaration that points at an all-off fill is a declaration of NO frame. Real HWP files are
    /// full of them, so a reader that painted on the declaration alone would rule a box around most
    /// documents that draw none.
    func testAFillWithEveryEdgeOffDrawsNothing() throws {
        let s = try read("{\"pageBorder\":{\"borderFillId\":2,\"basis\":\"paper\"}}")
        XCTAssertFalse(try XCTUnwrap(s.first?.pageBorder).drawsAnything)
    }

    /// A section that rules no frame says nothing, which is what tells it apart from one whose frame
    /// this reader failed to read.
    func testASectionWithNoFrameCarriesNone() throws {
        XCTAssertNil(try read("{\"hideHeader\":true}").first?.pageBorder)
    }
}
