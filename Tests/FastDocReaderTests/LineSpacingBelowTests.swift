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

    /// Seven 15pt lines on a 100pt page: the seventh's glyphs end at 100 and its spacing at 105.
    private func lineRects(spacingBelow: Bool) -> [NSRect] {
        let delegate = PageBandLayoutDelegate(pageContentHeight: 100, band: 20)
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        lm.allowsNonContiguousLayout = false
        lm.delegate = delegate
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        let ps = NSMutableParagraphStyle()
        if spacingBelow {
            ps.minimumLineHeight = 10; ps.maximumLineHeight = 10; ps.lineSpacing = 5
        } else {
            ps.minimumLineHeight = 15; ps.maximumLineHeight = 15
        }
        let text = NSMutableAttributedString()
        for i in 0..<9 {
            text.append(NSAttributedString(string: "line \(i)\n",
                                           attributes: [.font: NSFont.systemFont(ofSize: 8), .paragraphStyle: ps]))
        }
        storage.setAttributedString(text)
        lm.ensureLayout(for: tc)
        var rects: [NSRect] = []
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, _, _, _, _ in rects.append(rect) }
        return rects
    }

    func testTheLastLineStaysWhenOnlyItsSpacingUnderTheGlyphsOverflows() {
        let rects = lineRects(spacingBelow: true)
        XCTAssertGreaterThanOrEqual(rects.count, 9)
        XCTAssertEqual(rects[6].minY, 90, accuracy: 0.5, "glyphs 90–100 fit the 100pt body; the spacing to 105 hangs")
        XCTAssertEqual(rects[7].minY, 120, accuracy: 0.5, "the next line begins the next page (pitch 120)")
    }

    func testAFloorThatOverflowsIsStillPushedWhole() {
        let rects = lineRects(spacingBelow: false)
        XCTAssertGreaterThanOrEqual(rects.count, 9)
        XCTAssertEqual(rects[6].minY, 120, accuracy: 0.5, "a 15pt floor at 90 does not fit 100 and moves whole")
    }
}
