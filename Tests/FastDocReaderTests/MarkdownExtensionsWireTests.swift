import XCTest
import CFastdocEngine
import AppKit
@testable import FastDocReader

/// What the engine's markdown extensions look like after the host replays them: the new wire
/// columns (background fill, baseline offset), a script-size face that still names its role, the
/// alert kind the bar is tinted by, and footnote / `{#id}` bookmarks that arrive as a plain string.
///
/// The Rust side proves the engine PRODUCES each attribute (`markdown_extensions.rs`); this proves
/// the host MATERIALISES it — a column the decoder or the materializer forgets is dropped silently.
final class MarkdownExtensionsWireTests: XCTestCase {

    private let theme = RenderTheme.current(size: 16)

    private func render(_ source: String) throws -> NSAttributedString {
        try XCTUnwrap(RustMarkdownEngine.render(source, theme: theme),
                      RustMarkdownEngine.lastFailure ?? "the engine returned nil")
    }

    private func index(of needle: String, in string: NSAttributedString) throws -> Int {
        let range = (string.string as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "\(needle) not in \(string.string)")
        return range.location
    }

    func testHighlightAndSpoilerBecomeABackgroundFill() throws {
        let s = try render("a <mark>hot</mark> and ==marked== and ||quiet||\n")
        for word in ["hot", "marked", "quiet"] {
            let at = try index(of: word, in: s)
            XCTAssertNotNil(s.attribute(.backgroundColor, at: at, effectiveRange: nil), word)
        }
        XCTAssertNil(s.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    func testSuperAndSubscriptShiftTheBaselineAndShrink() throws {
        let s = try render("body H<sub>2</sub>O and x<sup>3</sup>\n")
        let body = try XCTUnwrap(s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let sup = try index(of: "3", in: s), sub = try index(of: "2", in: s)
        XCTAssertGreaterThan((s.attribute(.baselineOffset, at: sup, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0, 0)
        XCTAssertLessThan((s.attribute(.baselineOffset, at: sub, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0, 0)
        for at in [sup, sub] {
            let font = try XCTUnwrap(s.attribute(.font, at: at, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.pointSize, body.pointSize * 0.75, accuracy: 0.05,
                           "a script face keeps its role and is rebuilt at script size")
        }
    }

    func testStrikeUnderlineAndLineBreakFromHTML() throws {
        let s = try render("<s>old</s> <u>under</u> line<br>two\n")
        XCTAssertNotNil(s.attribute(.strikethroughStyle, at: try index(of: "old", in: s), effectiveRange: nil))
        XCTAssertNotNil(s.attribute(.underlineStyle, at: try index(of: "under", in: s), effectiveRange: nil))
        XCTAssertTrue(s.string.contains("line\u{2028}two"))
        XCTAssertFalse(s.string.contains("<"))
    }

    func testAnAlertCarriesItsKindForTheBar() throws {
        let s = try render("> [!WARNING]\n> careful now\n")
        let at = try index(of: "careful", in: s)
        XCTAssertTrue((s.attribute(MDAttr.alert, at: at, effectiveRange: nil) as? String)?.hasPrefix("warning:") == true)
        XCTAssertNotNil(s.attribute(MDAttr.blockQuote, at: at, effectiveRange: nil))
        XCTAssertTrue(s.string.hasPrefix("Warning\n"))
    }

    func testFootnoteTargetsAndHeadingIdsArriveAsStrings() throws {
        let s = try render("# Title {#my-id}\n\nClaim[^n].\n\n[^n]: The note.\n")
        XCTAssertEqual(s.attribute(MDAttr.bookmarkTarget, at: 0, effectiveRange: nil) as? String, "my-id")
        let ref = try index(of: "Claim", in: s) + "Claim".count
        XCTAssertEqual(s.attribute(MDAttr.anchor, at: ref, effectiveRange: nil) as? String, "fn:n")
        XCTAssertEqual(s.attribute(MDAttr.bookmarkTarget, at: ref, effectiveRange: nil) as? String, "fnref:n")
        let note = try index(of: "1.\tThe note.", in: s)
        XCTAssertEqual(s.attribute(MDAttr.bookmarkTarget, at: note, effectiveRange: nil) as? String, "fn:n")
    }

    func testAnOrderedListStartsAtItsOwnNumber() throws {
        XCTAssertTrue(try render("3. three\n4. four\n").string.hasPrefix("3.\tthree\n4.\tfour"))
    }

    func testTableAlignmentReachesTheCellParagraph() throws {
        let s = try render("| l | c | r |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n")
        func alignment(_ needle: String) throws -> NSTextAlignment {
            let at = try index(of: needle, in: s)
            return (s.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?.alignment ?? .natural
        }
        XCTAssertEqual(try alignment("2"), .center)
        XCTAssertEqual(try alignment("3"), .right)
    }

    func testCodeAndQuotesInAListItemSitUnderTheItemTextAndATableKeepsItsCells() throws {
        let s = try render("- item\n\n  ```\n  code line\n  ```\n\n  | a | b |\n  |---|---|\n  | 1 | 2 |\n")
        let hang = theme.baseFontSize * 1.7
        let code = try index(of: "code line", in: s)
        XCTAssertEqual((s.attribute(MDAttr.codeInset, at: code, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0,
                       Double(hang), accuracy: 0.01)
        let cell = try index(of: "1", in: s)
        let style = try XCTUnwrap(s.attribute(.paragraphStyle, at: cell, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertFalse(style.textBlocks.isEmpty, "a table in a list item keeps its cells")
        XCTAssertEqual(style.headIndent, 0, "a cell paragraph takes no indent")
    }

    func testHTMLBlocksKeepTheirText() throws {
        let s = try render("<details>\n<summary>Why</summary>\n\nBecause.\n\n</details>\n")
        XCTAssertTrue(s.string.contains("Why") && s.string.contains("Because."))
        XCTAssertFalse(s.string.contains("<"))
    }
}
