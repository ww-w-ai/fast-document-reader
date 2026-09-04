import XCTest
import AppKit
@testable import FastDocReader

/// A cell's last line is a LINE, not a line plus its spacing — the rule 한글 measures a row by.
///
/// rhwp's `height_measurer` (`include_trailing_ls`): every line in a cell is `line_height +
/// line_spacing` EXCEPT the cell's last, which contributes `line_height` alone when the cell holds one
/// paragraph, or always in a block table that breaks at row boundaries. This reader floored every
/// line at the full pitch, so a one-line 25pt cell at 180% stood 45pt tall against the source's 25,
/// and every single-line form cell at 160% carried 60% of its font size the source does not draw
/// (invariant 161). The pitch is now carried as `size + lineSpacing`, and the trailing gap comes back
/// off as a negative `paragraphSpacing` — the one paragraph-level knob TextKit lets shorten a last
/// line's box (it cancels `lineSpacing`; it cannot cut into a `minimumLineHeight` floor).
final class CellLastLineTrailingGapTests: XCTestCase {

    private let theme = RenderTheme.current(size: 16)

    /// A cell whose paragraphs ask for a percent-style floor well above their font.
    private func cell(_ text: String, size: CGFloat, pitch: CGFloat, paragraphs: Int = 1) -> Cell {
        var f = ParagraphFormat()
        f.lineHeight = .atLeast(pitch)
        let para = OfficeBlock.paragraph(spans: [Span(text: text, fontSize: size)], format: f)
        return Cell(blocks: Array(repeating: para, count: paragraphs))
    }

    private func build(_ rows: [[Cell]], format: TableFormat = TableFormat()) -> NSAttributedString {
        OfficeTextBuilder.build([.table(rows: rows, headerRows: 0, format: format)],
                                theme: theme, documentDefaultFontSize: 16, tableWidth: 300)
    }

    /// The style at the `nth` occurrence of `text`.
    private func style(of out: NSAttributedString, at text: String, nth: Int = 1) throws -> NSParagraphStyle {
        let ns = out.string as NSString
        var r = ns.range(of: text)
        for _ in 1..<nth where r.location != NSNotFound {
            let from = r.location + r.length
            r = ns.range(of: text, options: [], range: NSRange(location: from, length: ns.length - from))
        }
        XCTAssertNotEqual(r.location, NSNotFound)
        return try XCTUnwrap(out.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)
    }

    /// The laid-out line box of the fragment holding `text`.
    private func fragmentHeight(_ attr: NSAttributedString, of text: String) -> CGFloat {
        let storage = NSTextStorage(attributedString: attr)
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        storage.addLayoutManager(lm); lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        let r = (attr.string as NSString).range(of: text)
        return lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: r.location), effectiveRange: nil).height
    }

    func testASingleParagraphCellCarriesItsPitchAsSizePlusSpacingAndGivesTheLastGapBack() throws {
        let out = build([[cell("36.", size: 25, pitch: 45)]])
        let ps = try style(of: out, at: "36.")
        XCTAssertEqual(ps.minimumLineHeight, 25, accuracy: 0.01, "the line is the character size")
        XCTAssertEqual(ps.maximumLineHeight, 25, accuracy: 0.01)
        XCTAssertEqual(ps.lineSpacing, 20, accuracy: 0.01, "and the rest of the pitch is spacing")
        XCTAssertEqual(ps.paragraphSpacing, -20, accuracy: 0.01, "which the cell's last line hands back")
    }

    func testTheGapIsMeasuredNotAssumed() throws {
        // 45pt pitch at 25pt: the last line lays out 25pt tall, and 45pt with the gap put back.
        let with = build([[cell("36.", size: 25, pitch: 45)]])
        XCTAssertEqual(fragmentHeight(with, of: "36."), 25, accuracy: 0.5)
        let kept = NSMutableAttributedString(attributedString: with)
        let ns = kept.string as NSString
        let r = ns.range(of: "36.")
        let back = (kept.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as! NSParagraphStyle)
            .mutableCopy() as! NSMutableParagraphStyle
        back.paragraphSpacing = 0
        kept.addAttribute(.paragraphStyle, value: back, range: ns.paragraphRange(for: r))
        XCTAssertEqual(fragmentHeight(kept, of: "36."), 45, accuracy: 0.5)
    }

    func testAMultiParagraphCellKeepsTheGapUnlessTheTableBreaksAtRows() throws {
        let twoParas = [[cell("본문", size: 10, pitch: 16, paragraphs: 2)]]
        // No policy: a two-paragraph cell keeps its last line's spacing (the source's own rule).
        let plain = build(twoParas)
        let plainLast = try style(of: plain, at: "본문", nth: 2)
        XCTAssertEqual(plainLast.lineSpacing, 6, accuracy: 0.01)
        XCTAssertEqual(plainLast.paragraphSpacing, 0, accuracy: 0.01)
        // A block table that breaks at row boundaries: the last line never carries its spacing.
        var format = TableFormat()
        format.pageBreakPolicy = .atRowBoundary
        let block = build(twoParas, format: format)
        let blockLast = try style(of: block, at: "본문", nth: 2)
        XCTAssertEqual(blockLast.paragraphSpacing, -6, accuracy: 0.01, "16pt pitch at 10pt: 6pt of spacing given back")
        // And the first paragraph of that cell is untouched — only the cell's LAST line qualifies.
        let blockFirst = try style(of: block, at: "본문", nth: 1)
        XCTAssertEqual(blockFirst.lineSpacing, 6, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(blockFirst.paragraphSpacing, 0)
    }

    func testAnExactLineHeightAFloorBelowTheFontAndAPictureKeepTheirBoxes() throws {
        var exact = ParagraphFormat(); exact.lineHeight = .exact(45)
        var low = ParagraphFormat(); low.lineHeight = .atLeast(8)
        var tall = ParagraphFormat(); tall.lineHeight = .atLeast(45)
        let rows = [[Cell(blocks: [.paragraph(spans: [Span(text: "고정", fontSize: 25)], format: exact)]),
                     Cell(blocks: [.paragraph(spans: [Span(text: "낮음", fontSize: 25)], format: low)]),
                     Cell(blocks: [.paragraph(spans: [Span(text: "그림", fontSize: 25),
                                                      Span(text: "\u{FFFC}", fontSize: 25)], format: tall)])]]
        let out = build(rows)
        for text in ["고정", "낮음", "그림"] {
            let ps = try style(of: out, at: text)
            XCTAssertEqual(ps.lineSpacing, 0, accuracy: 0.01, text)
            XCTAssertEqual(ps.paragraphSpacing, 0, accuracy: 0.01, text)
        }
        XCTAssertEqual(try style(of: out, at: "그림").minimumLineHeight, 45, accuracy: 0.01,
                       "a paragraph with a picture keeps the floor — a picture is not a glyph")
    }
}
