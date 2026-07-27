import XCTest
import AppKit
@testable import FastDocReader

/// Pure unit tests for the headless `--extract` serializer: `[OfficeBlock] -> Markdown`. No zip, no
/// AppKit layout — the block vocabulary is built by hand so every mapping and every degrade-to-`<raw>`
/// decision is asserted directly. (The reader→serializer wiring is proven separately in
/// `OfficeDocumentTests` through the real `DocumentTypes.readOffice` dispatch.)
final class OfficeMarkdownSerializerTests: XCTestCase {
    private func md(_ blocks: [OfficeBlock]) -> String { OfficeMarkdownSerializer.serialize(blocks) }
    private func cell(_ text: String) -> Cell { Cell(blocks: [.paragraph(spans: [Span(text: text)])]) }

    // MARK: - Block mapping

    func testHeadingLevels() {
        let s = md([.heading(level: 1, spans: [Span(text: "One")]),
                    .heading(level: 3, spans: [Span(text: "Three")])])
        XCTAssertTrue(s.contains("# One"))
        XCTAssertTrue(s.contains("### Three"))
    }

    func testHeadingLevelClampedToSix() {
        XCTAssertTrue(md([.heading(level: 9, spans: [Span(text: "Deep")])]).contains("###### Deep"))
    }

    func testParagraphInlineFormatting() {
        let s = md([.paragraph(spans: [
            Span(text: "b", bold: true), Span(text: " "),
            Span(text: "i", italic: true), Span(text: " "),
            Span(text: "s", strikethrough: true), Span(text: " "),
            Span(text: "c", code: true), Span(text: " "),
            Span(text: "site", link: "https://ww-w.ai"),
        ])])
        XCTAssertTrue(s.contains("**b**"), s)
        XCTAssertTrue(s.contains("*i*"), s)
        XCTAssertTrue(s.contains("~~s~~"), s)
        XCTAssertTrue(s.contains("`c`"), s)
        XCTAssertTrue(s.contains("[site](https://ww-w.ai)"), s)
    }

    func testBoldItalicCombined() {
        XCTAssertTrue(md([.paragraph(spans: [Span(text: "x", bold: true, italic: true)])]).contains("***x***"))
    }

    func testInlineCodeIsVerbatimAndNotDoublyFormatted() {
        // A code span that is ALSO flagged bold must stay verbatim (no ** inside a code span).
        let s = md([.paragraph(spans: [Span(text: "a*b", bold: true, code: true)])])
        XCTAssertTrue(s.contains("`a*b`"), s)
        XCTAssertFalse(s.contains("**"), s)
    }

    func testInlineCodeWithBacktickBumpsTheFence() {
        XCTAssertTrue(md([.paragraph(spans: [Span(text: "a`b", code: true)])]).contains("``a`b``"))
    }

    // MARK: - Lists

    func testUnorderedListUsesDash() {
        XCTAssertTrue(md([.listItem(level: 0, ordered: false, spans: [Span(text: "x")])]).contains("- x"))
    }

    func testOrderedListPreservesResolvedMarkerLiterally() {
        // A real clause number the reader shows (e.g. "1.1.2") must survive, not be auto-renumbered.
        let s = md([.listItem(level: 0, ordered: true, spans: [Span(text: "clause")], marker: "1.1.2")])
        XCTAssertTrue(s.contains("1.1.2 clause"), s)
    }

    func testOrderedListWithoutMarkerFallsBackToOneDot() {
        XCTAssertTrue(md([.listItem(level: 0, ordered: true, spans: [Span(text: "x")])]).contains("1. x"))
    }

    func testNestedListIndents() {
        XCTAssertTrue(md([.listItem(level: 2, ordered: false, spans: [Span(text: "deep")])]).contains("    - deep"))
    }

    func testConsecutiveListItemsAreOneList() {
        let s = md([.listItem(level: 0, ordered: false, spans: [Span(text: "a")]),
                    .listItem(level: 0, ordered: false, spans: [Span(text: "b")])])
        XCTAssertEqual(s, "- a\n- b")   // single newline between items, no blank line
    }

    // MARK: - Tables

    func testSimpleGridBecomesPipeTable() {
        let s = md([.table(rows: [[cell("A"), cell("B")], [cell("1"), cell("2")]], headerRows: 1)])
        XCTAssertTrue(s.contains("| A | B |"), s)
        XCTAssertTrue(s.contains("| --- | --- |"), s)
        XCTAssertTrue(s.contains("| 1 | 2 |"), s)
        XCTAssertFalse(s.contains(OfficeMarkdownSerializer.rawOpen), "a simple table must not degrade to <raw>")
    }

    func testPipeCellEscapesBar() {
        let s = md([.table(rows: [[cell("a|b"), cell("c")]], headerRows: 1)])
        XCTAssertTrue(s.contains("a\\|b"), s)   // the literal bar can't split the column
    }

    func testMergedCellTableDegradesToRaw() {
        let rows = [[Cell(blocks: [.paragraph(spans: [Span(text: "wide")])], colSpan: 2)],
                    [cell("a"), cell("b")]]
        let s = md([.table(rows: rows, headerRows: 0)])
        XCTAssertTrue(s.contains(OfficeMarkdownSerializer.rawOpen), s)
        XCTAssertTrue(s.contains("wide"), "raw dump must keep the cell text")
        XCTAssertFalse(s.contains("| --- |"), "a merged table must NOT be emitted as a pipe table")
    }

    func testBlockContentInCellDegradesToRaw() {
        // A list item inside a cell is more than a pipe table can hold → raw, not a fabricated grid.
        let rows = [[Cell(blocks: [.listItem(level: 0, ordered: false, spans: [Span(text: "x")])]), cell("b")]]
        let s = md([.table(rows: rows, headerRows: 0)])
        XCTAssertTrue(s.contains(OfficeMarkdownSerializer.rawOpen), s)
        XCTAssertFalse(s.contains("| --- |"), s)
    }

    // MARK: - Graphics / formula

    func testImageIsPlaceholder() {
        XCTAssertTrue(md([.image(id: "media/pic.png", size: .zero)]).contains("![image](media/pic.png)"))
    }

    func testUnsupportedGraphicIsHonestPlaceholder() {
        XCTAssertTrue(md([.unsupportedGraphic(label: "Chart", size: .zero)]).contains("*[Chart]*"))
    }

    func testFormulaBecomesDisplayMath() {
        XCTAssertEqual(md([.formula(latex: "a^2 + b^2")]), "$$\na^2 + b^2\n$$")
    }

    // MARK: - Structure / spacing

    func testParagraphsSeparatedByBlankLine() {
        XCTAssertEqual(md([.paragraph(spans: [Span(text: "one")]),
                           .paragraph(spans: [Span(text: "two")])]), "one\n\ntwo")
    }

    func testEmptyParagraphIsSkipped() {
        let s = md([.paragraph(spans: [Span(text: "one")]),
                    .paragraph(spans: []),
                    .paragraph(spans: [Span(text: "two")])])
        XCTAssertEqual(s, "one\n\ntwo")   // the empty paragraph adds no stray blank block
    }

    // MARK: - Blocker 4: font-substitution splits must not leak into Markdown delimiters

    /// `FontSubstitutionResolver` splits one logical run into several `Span`s purely so
    /// `OfficeTextBuilder` can assign each piece its own on-screen substitute FONT — a rendering
    /// concern this serializer has no notion of. Two adjacent spans that differ ONLY in
    /// `resolvedFontDescriptor` (exactly the shape that split leaves behind) must render as ONE
    /// `**…**`, never two glued back to back (`**18****년**`).
    func testAdjacentSpansThatDifferOnlyInResolvedFontDescriptorCoalesceBeforeEmittingDelimiters() {
        var first = Span(text: "18", bold: true)
        first.resolvedFontDescriptor = NSFont.boldSystemFont(ofSize: 12).fontDescriptor
        var second = Span(text: "년", bold: true)
        second.resolvedFontDescriptor = NSFont.systemFont(ofSize: 12, weight: .semibold).fontDescriptor
        let s = md([.paragraph(spans: [first, second])])
        XCTAssertEqual(s, "**18년**", s)
        XCTAssertFalse(s.contains("****"), s)
    }

    /// The coalescing must not over-merge: two adjacent spans with GENUINELY different formatting
    /// (not merely a different `resolvedFontDescriptor`) must stay separate.
    func testAdjacentSpansWithDifferentFormattingDoNotCoalesce() {
        let s = md([.paragraph(spans: [Span(text: "a", bold: true), Span(text: "b", bold: false)])])
        XCTAssertEqual(s, "**a**b", s)
    }

    /// End-to-end through the real resolver (not a hand-built split): a bold run mixing digits and a
    /// trailing Korean character — the report's own repro (`'18년`) — genuinely splits under font
    /// substitution (digits are covered by the declared bold Latin font, `년` is not), and the
    /// serializer must still emit it as one Markdown span.
    func testBoldRunSplitByRealFontSubstitutionSerializesAsOneMarkdownSpan() {
        let block = OfficeBlock.paragraph(spans: [Span(text: "\u{2018}18년", bold: true)])   // '18년
        let resolved = block.resolvingFontSubstitution()
        guard case let .paragraph(resolvedSpans, _, _, _, _) = resolved else {
            return XCTFail("must stay a paragraph")
        }
        XCTAssertGreaterThan(resolvedSpans.count, 1,
                             "sanity: this probe text must genuinely be split by real font substitution, " +
                             "or this test would pass vacuously regardless of the coalescing fix")
        let extracted = OfficeMarkdownSerializer.serialize([resolved])
        XCTAssertEqual(extracted, "**\u{2018}18년**", extracted)
        XCTAssertFalse(extracted.contains("****"), extracted)
    }
}
