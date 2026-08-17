import XCTest
import AppKit
@testable import FastDocReader

/// Where a document says its lines may be broken, from HWP's `ParaShape` bits to the paragraph style
/// TextKit actually lays out with.
///
/// Two thirds of the 454,134 paragraphs measured across 1,589 real Korean documents state this, and
/// the two settings put a different number of characters on a line — which is a different number of
/// lines, and eventually a different number of pages. See `OfficeTextBuilder.applyLineBreaking` for
/// the whole table, and `HwpLineBreakProbeTests` for the probe that produced it.
final class OfficeLineBreakingTests: XCTestCase {

    private let theme = RenderTheme.current(size: 16)

    private func style(_ format: ParagraphFormat) -> NSParagraphStyle? {
        let out = OfficeTextBuilder.build([.paragraph(spans: [Span(text: "한글 텍스트 sample")],
                                                      format: format)], theme: theme)
        return out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    }

    // MARK: the platform baseline the two branches are measured against

    /// AppKit's own default does NOT prefer Hangul word boundaries, so "break between characters"
    /// is what an unconfigured paragraph already does. That is the fact that makes the `.word`
    /// branch the load-bearing one — and if a future macOS flips this default, this test fails and
    /// says so, rather than the `.character` branch silently becoming the load-bearing one instead.
    func testAppKitDefaultDoesNotPreferHangulWordBoundaries() {
        XCTAssertFalse(NSMutableParagraphStyle().lineBreakStrategy.contains(.hangulWordPriority))
    }

    // MARK: the two Hangul settings reach the paragraph style

    func testWordUnitAsksForHangulWordPriority() {
        var f = ParagraphFormat()
        f.eastAsianLineBreak = .word
        XCTAssertEqual(style(f)?.lineBreakStrategy.contains(.hangulWordPriority), true)
    }

    func testCharacterUnitDoesNotAskForHangulWordPriority() {
        var f = ParagraphFormat()
        f.eastAsianLineBreak = .character
        XCTAssertEqual(style(f)?.lineBreakStrategy.contains(.hangulWordPriority), false)
    }

    /// A paragraph whose source never spoke is left exactly as the theme built it — the property
    /// every unstated field in `ParagraphFormat` has, and what keeps markdown and docx unchanged by
    /// a field only the HWP reader populates.
    func testUnstatedLeavesTheThemesOwnStrategyAlone() {
        let untouched = style(ParagraphFormat())?.lineBreakStrategy
        XCTAssertEqual(untouched, NSMutableParagraphStyle().lineBreakStrategy)
    }

    // MARK: Latin

    func testLatinCharacterUnitWrapsWithinAWord() {
        var f = ParagraphFormat()
        f.latinLineBreak = .character
        XCTAssertEqual(style(f)?.lineBreakMode, .byCharWrapping)
    }

    /// `.hyphen` is HWP's middle setting and TextKit already breaks at a hyphen, so it must NOT be
    /// turned into character wrapping — that would split words the document meant to keep whole.
    func testLatinHyphenUnitIsNotCharacterWrapping() {
        var f = ParagraphFormat()
        f.latinLineBreak = .hyphen
        XCTAssertNotEqual(style(f)?.lineBreakMode, .byCharWrapping)
    }

    // MARK: the HWP codes, decoded

    func testHwpBreakCodesDecodeToTheMeasuredMeanings() {
        // Hangul: the nominal schema says the opposite of what Hancom does; rhwp measured it three
        // ways and its own line breaker uses this reading (`composer/line_breaking.rs`, #2185).
        XCTAssertEqual(HwpReader.hangulBreak(0), .word)
        XCTAssertEqual(HwpReader.hangulBreak(1), .character)
        XCTAssertEqual(HwpReader.latinBreak(0), .word)
        XCTAssertEqual(HwpReader.latinBreak(1), .hyphen)
        XCTAssertEqual(HwpReader.latinBreak(2), .character)
        // A code outside the format's own range is not guessed at.
        XCTAssertNil(HwpReader.hangulBreak(2))
        XCTAssertNil(HwpReader.latinBreak(3))
    }
}
