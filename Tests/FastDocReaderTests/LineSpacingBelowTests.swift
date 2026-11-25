import XCTest
import AppKit
@testable import FastDocReader

/// A format whose line spacing sits UNDER the glyphs (HWP) is carried as `size + lineSpacing`, and
/// at the foot of a page only the glyphs have to fit — the spacing may run into the band, as 한글
/// draws it. Floored at the full pitch, the last line of a page went to the next page whenever its
/// spacing did not fit: measured on the reference manual as 23pt of foot gap per page against
/// Hancom's, 41 pages against 13 whose text reached the last 6pt of the body (invariant 161).
final class LineSpacingBelowTests: XCTestCase {

    private let theme = RenderTheme.current(size: 16)

    private func paragraph(_ text: String, below: Bool?) -> OfficeBlock {
        var f = ParagraphFormat()
        f.lineHeight = .atLeast(16.8)
        f.lineSpacingBelow = below
        return .paragraph(spans: [Span(text: text, fontSize: 10.5)], format: f)
    }

    private func style(_ out: NSAttributedString, of text: String) throws -> NSParagraphStyle {
        let r = (out.string as NSString).range(of: text)
        XCTAssertNotEqual(r.location, NSNotFound)
        return try XCTUnwrap(out.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)
    }

    func testABodyParagraphWithSpacingBelowCarriesItsPitchAsSizePlusSpacing() throws {
        let out = OfficeTextBuilder.build([paragraph("아래", below: true), paragraph("위", below: nil)],
                                          theme: theme, documentDefaultFontSize: 16, pageContentWidth: 400)
        let below = try style(out, of: "아래")
        XCTAssertEqual(below.minimumLineHeight, 10.5, accuracy: 0.01, "the line is the character size")
        XCTAssertEqual(below.maximumLineHeight, 10.5, accuracy: 0.01)
        XCTAssertEqual(below.lineSpacing, 6.3, accuracy: 0.01, "and the rest of the 160% pitch is spacing under it")
        XCTAssertEqual(below.paragraphSpacing, 0, accuracy: 0.01, "a body paragraph keeps every line's spacing")
        let above = try style(out, of: "위")
        XCTAssertEqual(above.minimumLineHeight, 16.8, accuracy: 0.01, "a format that says nothing keeps the floor")
        XCTAssertEqual(above.lineSpacing, 0, accuracy: 0.01)
    }

    /// Nine 15pt line boxes on a 100pt page with a 20pt band, as the plan places them. `trailing` is
    /// the spacing under the glyphs of each line: the seventh line's glyphs end at 100 and its spacing
    /// at 105.
    private func targets(trailing: Double) throws -> [Int: (page: Int, top: Double)] {
        let block: [String: Any] = ["key": 1, "kind": "text", "lines": [Double](repeating: 15, count: 9),
                                    "lineLocs": Array(0..<9), "trailing": trailing]
        let plan = try XCTUnwrap(PlanPagination.ask(["planVersion": 1, "contentHeight": 100, "band": 20, "blocks": [block]]))
        var out: [Int: (page: Int, top: Double)] = [:]
        for t in (plan["targets"] as? [[String: Any]]) ?? [] {
            out[(t["loc"] as? Int) ?? -1] = ((t["page"] as? Int) ?? -1, (t["top"] as? Double) ?? -1)
        }
        return out
    }

    func testTheLastLineStaysWhenOnlyItsSpacingUnderTheGlyphsOverflows() throws {
        let placed = try targets(trailing: 5)
        XCTAssertEqual(placed[6]?.page, 0)
        XCTAssertEqual(try XCTUnwrap(placed[6]).top, 90, accuracy: 0.5, "glyphs 90–100 fit the 100pt body; the spacing to 105 hangs")
        XCTAssertEqual(placed[7]?.page, 1, "the next line begins the next page")
        XCTAssertEqual(try XCTUnwrap(placed[7]).top, 0, accuracy: 0.5)
    }

    func testAFloorThatOverflowsIsStillPushedWhole() throws {
        let placed = try targets(trailing: 0)
        XCTAssertEqual(placed[6]?.page, 1, "a 15pt floor at 90 does not fit 100 and moves whole")
        XCTAssertEqual(try XCTUnwrap(placed[6]).top, 0, accuracy: 0.5)
    }
}
