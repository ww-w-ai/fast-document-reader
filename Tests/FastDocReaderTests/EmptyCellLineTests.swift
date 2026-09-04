import XCTest
import AppKit
@testable import FastDocReader

/// An empty cell paragraph is a line of ITS OWN character size, not AppKit's default.
///
/// An empty paragraph builds to an empty string, and an empty string carries no attributes, so the
/// cell reached `TableBlockBuilder` as a bare terminator laid out at Helvetica 12 — a 14pt line in a
/// cell the document set at 9pt. 한글 lays an empty paragraph at its own char shape's size, and a
/// one-paragraph cell's last line carries no spacing. `OfficeTextBuilder.emptyCellLine` makes the
/// paragraph its own separator carrying that size (invariant 169).
final class EmptyCellLineTests: XCTestCase {

    private let theme = RenderTheme.current(size: 16)

    private func build(_ rows: [[Cell]], paged: Bool = true) -> NSAttributedString {
        OfficeTextBuilder.build([.table(rows: rows, headerRows: 0)], theme: theme,
                                documentDefaultFontSize: 16,
                                pageContentWidth: paged ? 400 : nil, tableWidth: 300)
    }

    private func fragmentHeights(_ attr: NSAttributedString) -> [CGFloat] {
        let storage = NSTextStorage(attributedString: attr)
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        storage.addLayoutManager(lm); lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        var out: [CGFloat] = []
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, _, _, _, _ in out.append(rect.height) }
        return out
    }

    func testAnEmptyParagraphStandsAtItsDeclaredSizeWithNoSpacing() throws {
        var f = ParagraphFormat(); f.lineHeight = .atLeast(14.4)   // 160% of 9pt, the form's rule
        let empty = Cell(blocks: [.paragraph(spans: [Span(text: "", fontSize: 9)], format: f)])
        let out = build([[empty]])
        XCTAssertEqual(out.string, "\n\n\n", "the paragraph is its own terminator; two closing separators follow")
        let attrs = out.attributes(at: 0, effectiveRange: nil)
        let font = try XCTUnwrap(attrs[.font] as? NSFont)
        XCTAssertEqual(font.pointSize, 9, accuracy: 0.01)
        let ps = try XCTUnwrap(attrs[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(ps.minimumLineHeight, 9, accuracy: 0.01)
        XCTAssertEqual(ps.maximumLineHeight, 9, accuracy: 0.01)
        XCTAssertEqual(ps.lineSpacing, 0, accuracy: 0.01)
        XCTAssertTrue(ps.textBlocks.last is NSTextTableBlock, "it is still the cell's own paragraph")
        XCTAssertEqual(try XCTUnwrap(fragmentHeights(out).first), 9, accuracy: 0.5)
    }

    /// A paragraph with no vouched size is still its own line — at the cell's base font and its own
    /// paragraph style — so a TRAILING empty paragraph beside content, which used to contribute no
    /// line at all, gets the line Word draws (invariant 170).
    func testATrailingEmptyParagraphWithNoDeclaredSizeStillGetsItsLine() throws {
        let beside = Cell(blocks: [.paragraph(spans: [Span(text: "위")]), .paragraph(spans: [])])
        let out = build([[beside]])
        XCTAssertEqual(out.string, "위\n\n\n\n", "one line for 위, one for the empty paragraph, two closes")
        let empty = (out.string as NSString).range(of: "위\n").location + 2
        let font = try XCTUnwrap(out.attribute(.font, at: empty, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, theme.bodyFont.pointSize, accuracy: 0.01)
        XCTAssertEqual(fragmentHeights(out).count, 4)
    }

    /// A docx paragraph mark carries a face: the line is the face's own — the declared ratio when
    /// it has one (맑은 고딕 at 9pt is 15.6, invariant 163), never the bare size.
    func testAMarkWithADeclaredFaceTakesThatFacesLine() throws {
        let empty = Cell(blocks: [.paragraph(spans: [Span(text: "", fontSize: 9, fontName: "맑은 고딕")])])
        let out = build([[empty]])
        let ps = try XCTUnwrap(out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(ps.minimumLineHeight, 15.6, accuracy: 0.01)
        XCTAssertEqual(ps.maximumLineHeight, 0, "a floor, the way a text line of that face is floored")
    }

    func testAnEmptyParagraphBetweenTwoOthersIsItsOwnSeparator() throws {
        let cell = Cell(blocks: [.paragraph(spans: [Span(text: "위", fontSize: 9)]),
                                 .paragraph(spans: [Span(text: "", fontSize: 9)]),
                                 .paragraph(spans: [Span(text: "아래", fontSize: 9)])])
        let out = build([[cell]])
        XCTAssertEqual(out.string, "위\n\n아래\n\n\n", "one separator per paragraph, none doubled")
        let middle = (out.string as NSString).range(of: "\n\n").location + 1
        let ps = try XCTUnwrap(out.attribute(.paragraphStyle, at: middle, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(ps.maximumLineHeight, 9, accuracy: 0.01)
        XCTAssertEqual(fragmentHeights(out).count, 5)
    }
}
