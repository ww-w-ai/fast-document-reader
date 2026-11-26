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

    private func oneCellTable(_ cell: OfficeBlock, grid: CGFloat? = nil) -> NSAttributedString {
        OfficeTextBuilder.build([.table(rows: [[Cell(blocks: [cell])]], headerRows: 0)],
                                theme: theme, documentDefaultFontSize: 16, pageContentWidth: 400,
                                tableWidth: 400, lineGridPitch: grid)
    }

    /// 한글's cell rule (161b) — a one-paragraph cell's last line is a line without its spacing — is
    /// HWP's. A docx line grid is the whole line in a cell too: Word adds the pitch to every cell line
    /// when the document asks (`w:adjustLineHeightInTable`), so a one-line 10pt cell on an 18pt grid
    /// stands 18pt, not 10 (invariant 207, the OpenAPI guide's 740 cell lines).
    func testAOneLineCellOnALineGridKeepsTheWholePitch() throws {
        let out = oneCellTable(.paragraph(spans: [Span(text: "격자", fontSize: 10)]), grid: 18)
        let s = try style(out, of: "격자")
        XCTAssertEqual(s.minimumLineHeight, 18, accuracy: 0.01, "the grid floors the cell's line")
        XCTAssertEqual(s.lineSpacing, 0, accuracy: 0.01)
        XCTAssertEqual(s.paragraphSpacing, 0, accuracy: 0.01, "and its last line keeps the pitch")
    }

    /// Unpaged, the cell floor is this reader's own rhythm and its last line still hands the gap
    /// back — a flow-printed table (giant-table.odt) keeps its row height (invariant 207).
    func testAnUnpagedCellKeepsTheReadersOwnLastLineRule() throws {
        let out = OfficeTextBuilder.build([.table(rows: [[Cell(blocks: [.paragraph(spans: [Span(text: "흐름", fontSize: 10)])])]],
                                                  headerRows: 0)],
                                          theme: theme, tableWidth: 400)
        let s = try style(out, of: "흐름")
        XCTAssertLessThan(s.paragraphSpacing, 0, "the one-paragraph cell's last line drops its gap")
    }

    func testAOneLineHwpCellStillHandsItsSpacingBack() throws {
        let out = oneCellTable(paragraph("한글", below: true))
        let s = try style(out, of: "한글")
        XCTAssertEqual(s.minimumLineHeight, 10.5, accuracy: 0.01)
        XCTAssertEqual(s.lineSpacing, 6.3, accuracy: 0.01)
        XCTAssertEqual(s.paragraphSpacing, -6.3, accuracy: 0.01, "the last line is the character size alone")
    }

    /// A blank HWP body paragraph stands at its own char shape's size — 한글 stores
    /// `LineSeg.line_height` = that size for all 228 blank body paragraphs of s9-picture-crop.hwp —
    /// not at AppKit's bare-terminator 14pt line (invariant 207).
    func testABlankHwpBodyParagraphCarriesItsDeclaredSize() throws {
        var f = ParagraphFormat()
        f.lineHeight = .atLeast(4.8)
        f.lineSpacingBelow = true
        let out = OfficeTextBuilder.build([.paragraph(spans: [Span(text: "", fontSize: 3)], format: f),
                                           .paragraph(spans: [Span(text: "끝", fontSize: 10)], format: f)],
                                          theme: theme, documentDefaultFontSize: 16, pageContentWidth: 400)
        XCTAssertEqual(out.string.first, "\n")
        let font = try XCTUnwrap(out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 3, accuracy: 0.01)
        var g = ParagraphFormat()
        g.lineHeight = .atLeast(4.8)
        let other = OfficeTextBuilder.build([.paragraph(spans: [Span(text: "", fontSize: 3)], format: g)],
                                            theme: theme, documentDefaultFontSize: 16, pageContentWidth: 400)
        XCTAssertNil(other.attribute(.font, at: 0, effectiveRange: nil), "a non-HWP blank is unchanged")
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
