import XCTest
import AppKit
@testable import FastDocReader

/// What a char shape does beyond bold and italic, from HWP's own table to the text attributes
/// TextKit draws with.
///
/// Measured over 1,589 real Korean documents, 221,747 char shapes (`HwpCharDecorProbeTests`), which
/// is what decided the split between drawn and merely carried — see invariant 97. Letter spacing is
/// the one that matters most: 1,539 of the 1,589 documents state it, and it changes how much text
/// fits on a line, which is a page count (the 편람 moves 520 → 513 pages).
final class OfficeCharDecorTests: XCTestCase {

    private let theme = RenderTheme.current(size: 16)

    private func attributes(_ span: Span) -> [NSAttributedString.Key: Any] {
        let out = OfficeTextBuilder.build([.paragraph(spans: [span])], theme: theme)
        return out.attributes(at: 0, effectiveRange: nil)
    }

    private func span(_ text: String = "한글 text") -> Span { Span(text: text) }

    // MARK: the all-slots-agree rule

    func testAValueIsTakenOnlyWhenEverySlotAgrees() {
        XCTAssertEqual(HwpReader.uniformValue([-5, -5, -5, -5, -5, -5, -5]), -5)
        XCTAssertNil(HwpReader.uniformValue([-5, 0, -5, -5, -5, -5, -5]),
                     "a shape whose scripts disagree carries nothing rather than one script's answer")
        XCTAssertNil(HwpReader.uniformValue([-5, -5, -5]), "a partial answer is not an answer")
        XCTAssertNil(HwpReader.uniformValue([]))
        XCTAssertNil(HwpReader.uniformValue(nil))
    }

    // MARK: letter spacing and baseline shift are shares of the run's own em

    func testLetterSpacingBecomesPointsAgainstTheRunsOwnFont() {
        var s = span()
        s.fontSize = 20
        s.letterSpacingPercent = -10
        let attrs = attributes(s)
        let font = attrs[.font] as? NSFont
        let kern = attrs[.kern] as? CGFloat
        XCTAssertNotNil(font)
        XCTAssertNotNil(kern)
        // The point size the builder actually resolved — the reading size scales it, so the test
        // asks for the RELATION rather than a hardcoded number.
        XCTAssertEqual(kern!, font!.pointSize * -0.10, accuracy: 0.0001)
    }

    func testBaselineOffsetBecomesPointsAgainstTheRunsOwnFont() {
        var s = span()
        s.fontSize = 20
        s.baselineOffsetPercent = 25
        let attrs = attributes(s)
        let font = attrs[.font] as? NSFont
        XCTAssertEqual(attrs[.baselineOffset] as? CGFloat ?? 0, font!.pointSize * 0.25, accuracy: 0.0001)
    }

    func testAZeroOrUnstatedValueSetsNothingAtAll() {
        XCTAssertNil(attributes(span())[.kern])
        XCTAssertNil(attributes(span())[.baselineOffset])
        var zero = span()
        zero.letterSpacingPercent = 0
        zero.baselineOffsetPercent = 0
        XCTAssertNil(attributes(zero)[.kern], "an explicit zero is the font's own spacing, not an override")
        XCTAssertNil(attributes(zero)[.baselineOffset])
    }

    // MARK: a decoration's own colour rides only with the decoration

    func testUnderlineColourAppliesOnlyWhenThereIsAnUnderline() {
        var underlined = span()
        underlined.underline = true
        underlined.underlineColor = .red
        XCTAssertEqual(attributes(underlined)[.underlineColor] as? NSColor, .red)

        var noUnderline = span()
        noUnderline.underlineColor = .red
        XCTAssertNil(attributes(noUnderline)[.underlineColor],
                     "a colour for a decoration that is not drawn is a fact about nothing")
    }

    func testStrikethroughColourAppliesOnlyWhenThereIsAStrikethrough() {
        var struck = span()
        struck.strikethrough = true
        struck.strikethroughColor = .blue
        XCTAssertEqual(attributes(struck)[.strikethroughColor] as? NSColor, .blue)

        var notStruck = span()
        notStruck.strikethroughColor = .blue
        XCTAssertNil(attributes(notStruck)[.strikethroughColor])
    }

    /// 음영 paints a background behind the glyphs, which is the same pixels `highlightColor` already
    /// paints for a docx highlighter — so the reader maps it onto that rather than growing a second
    /// attribute for the same effect.
    func testShadingIsCarriedAsTheRunsBackground() {
        var s = span()
        s.highlightColor = .yellow
        XCTAssertEqual(attributes(s)[.backgroundColor] as? NSColor, .yellow)
    }
}
