import XCTest
import AppKit
@testable import FastDocReader

/// Invariant 142 — no line may be taller than the page body it has to sit on.
///
/// A Korean chapter divider states its number as one 580pt character with the document's own 160%
/// line spacing, which resolves to a 928pt line box against a 555.6pt page body. Left alone the line
/// is laid out where it starts and runs 372pt past the page boundary, painting across the next
/// sheet's running header and 바탕쪽. These cases pin the clamp AND its identity half: a paragraph
/// that fits, and a caller that names no page, must come out exactly as they did before the clamp
/// existed (invariant 37).
final class LineTallerThanPageTests: XCTestCase {

    private let theme = RenderTheme.current(size: 16)
    private let bodyHeight: CGFloat = 555.6

    private func lineHeights(_ built: NSAttributedString) -> [(min: CGFloat, max: CGFloat)] {
        var out: [(CGFloat, CGFloat)] = []
        built.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: built.length)) { v, _, _ in
            guard let p = v as? NSParagraphStyle else { return }
            out.append((p.minimumLineHeight, p.maximumLineHeight))
        }
        return out
    }

    /// The divider's own shape: one huge character whose declared line box exceeds the page body.
    private func divider(_ pt: CGFloat) -> [OfficeBlock] {
        [.paragraph(spans: [Span(text: "1", fontSize: 580)],
                    format: ParagraphFormat(lineHeight: .exact(pt)))]
    }

    func testALineTallerThanThePageIsCutToThePage() {
        let built = OfficeTextBuilder.build(divider(928), theme: theme,
                                            columnWidth: 395.72,
                                            documentDefaultFontSize: theme.baseFontSize,
                                            pageContentWidth: 395.72,
                                            pageContentHeight: bodyHeight)
        let heights = lineHeights(built)
        XCTAssertFalse(heights.isEmpty, "the probe found no paragraph style to judge")
        for h in heights {
            XCTAssertLessThanOrEqual(h.min, bodyHeight + 0.01, "a line still claims more than the page")
            XCTAssertLessThanOrEqual(h.max, bodyHeight + 0.01, "the ceiling still lets the line overrun")
        }
        // The ceiling must be STATED, not left at "no cap" — a zero maximum would let the 580pt
        // glyph's own natural height take the line back over the page.
        XCTAssertEqual(heights.first?.max ?? 0, bodyHeight, accuracy: 0.01)
    }

    func testAParagraphThatFITSThePageIsLeftExactlyAsItWas() {
        let blocks = divider(120)
        let capped = OfficeTextBuilder.build(blocks, theme: theme,
                                             columnWidth: 395.72,
                                             documentDefaultFontSize: theme.baseFontSize,
                                             pageContentWidth: 395.72,
                                             pageContentHeight: bodyHeight)
        let untouched = OfficeTextBuilder.build(blocks, theme: theme,
                                                columnWidth: 395.72,
                                                documentDefaultFontSize: theme.baseFontSize,
                                                pageContentWidth: 395.72)
        XCTAssertEqual(lineHeights(capped).map(\.min), lineHeights(untouched).map(\.min))
        XCTAssertEqual(lineHeights(capped).map(\.max), lineHeights(untouched).map(\.max))
        XCTAssertEqual(capped.string, untouched.string)
    }

    /// The page band, the master page and a footnote build through the same builder and name no page
    /// height. They must keep the line box they asked for, however tall.
    func testACallerThatNamesNoPageHeightIsNotClamped() {
        let built = OfficeTextBuilder.build(divider(928), theme: theme,
                                            columnWidth: 395.72,
                                            documentDefaultFontSize: theme.baseFontSize,
                                            pageContentWidth: 395.72)
        XCTAssertEqual(lineHeights(built).first?.min ?? 0, 928, accuracy: 0.5,
                       "a furniture caller's line was clamped by a page it never named")
    }
}
