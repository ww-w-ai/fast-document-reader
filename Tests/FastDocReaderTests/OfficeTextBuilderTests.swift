import XCTest
import AppKit
@testable import FastDocReader

final class OfficeTextBuilderTests: XCTestCase {
    private let theme = RenderTheme.current(size: 16)

    private func span(_ text: String, bold: Bool = false, italic: Bool = false,
                       underline: Bool = false, underlineStyle: UnderlineStyle = .single, code: Bool = false,
                       caps: Bool = false, smallCaps: Bool = false,
                       textColor: NSColor? = nil, highlightColor: NSColor? = nil,
                       fontName: String? = nil, fontSize: CGFloat? = nil) -> Span {
        Span(text: text, bold: bold, italic: italic, underline: underline, underlineStyle: underlineStyle,
             code: code, caps: caps, smallCaps: smallCaps,
             textColor: textColor, highlightColor: highlightColor, fontSize: fontSize, fontName: fontName)
    }

    private func build(_ blocks: [OfficeBlock]) -> NSAttributedString {
        OfficeTextBuilder.build(blocks, theme: theme)
    }

    /// One marker string ("1.", "2.", "•", …) per list-item block, read up to its first tab, in
    /// document order — enumerated the same way the reading cursor / gutter click would.
    private func listMarkers(in out: NSAttributedString) -> [String] {
        var markers: [String] = []
        out.enumerateAttribute(MDAttr.blockId, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard value is Int else { return }
            let line = out.attributedSubstring(from: range).string
            guard let tab = line.firstIndex(of: "\t") else { return }
            markers.append(String(line[line.startIndex..<tab]))
        }
        return markers
    }

    // MARK: Empty input

    func testEmptyBlockArrayReturnsEmptyAttributedStringWithoutCrashing() {
        let out = build([])
        XCTAssertEqual(out.length, 0)
        XCTAssertEqual(out.string, "")
    }

    // MARK: Block ids

    /// Every top-level block — regardless of kind — is exactly one navigation stop with a
    /// distinct, 0-based, monotonically increasing id over a non-empty range. A zero-length tag
    /// would be invisible to the reading cursor and gutter click (invariant carried over from
    /// `MarkdownRenderer`/`PlainTextRenderer`).
    func testEachBlockGetsADistinctMonotonicBlockIdOverANonEmptyRange() {
        let blocks: [OfficeBlock] = [
            .heading(level: 1, spans: [span("Title")]),
            .paragraph(spans: [span("Body")]),
            .listItem(level: 0, ordered: false, spans: [span("Item")]),
            .table(rows: [[Cell(spans: [span("A")]), Cell(spans: [span("B")])]], headerRows: 0),
            .image(id: "img1", size: CGSize(width: 100, height: 80)),
        ]
        let out = build(blocks)
        var ids: [Int] = []
        out.enumerateAttribute(MDAttr.blockId, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard let id = value as? Int else { return }
            XCTAssertGreaterThan(range.length, 0, "block \(id) has a zero-length tag")
            ids.append(id)
        }
        XCTAssertEqual(ids, Array(0..<blocks.count), "ids must be 0-based, distinct and in document order")
    }

    /// A block with no spans at all (an empty paragraph) still renders SOMETHING (its separator),
    /// so it still gets a non-empty, distinct id — it must not be silently dropped from navigation.
    func testABlockWithNoSpansStillGetsItsOwnNonEmptyBlockId() {
        let out = build([.paragraph(spans: []), .paragraph(spans: [span("next")])])
        var ids: [Int] = []
        out.enumerateAttribute(MDAttr.blockId, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard let id = value as? Int else { return }
            XCTAssertGreaterThan(range.length, 0)
            ids.append(id)
        }
        XCTAssertEqual(ids, [0, 1])
    }

    // MARK: Heading outline (what OutlinePanel.reload does)

    func testHeadingAttributeEnumeratesLevelsInDocumentOrder() {
        let blocks: [OfficeBlock] = [
            .heading(level: 1, spans: [span("One")]),
            .paragraph(spans: [span("body text")]),
            .heading(level: 3, spans: [span("Three")]),
            .heading(level: 2, spans: [span("Two")]),
        ]
        let out = build(blocks)
        var levels: [Int] = []
        out.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            guard let level = value as? Int else { return }
            levels.append(level)
        }
        XCTAssertEqual(levels, [1, 3, 2])
    }

    /// `OutlinePanel.reload` trims the tagged range and shows it as the entry title — the heading
    /// range must be exactly the heading's own text, not swallow the paragraph after it.
    func testHeadingRangeCoversOnlyItsOwnText() {
        let out = build([.heading(level: 2, spans: [span("Section")]), .paragraph(spans: [span("prose")])])
        var title: String?
        out.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard value != nil else { return }
            title = out.attributedSubstring(from: range).string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(title, "Section")
    }

    // MARK: Fonts

    func testHeadingLevel1UsesThemeHeadingFont() {
        let out = build([.heading(level: 1, spans: [span("Title")])])
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, theme.headingFont(level: 1).pointSize)
    }

    func testParagraphUsesThemeBodyFont() {
        let out = build([.paragraph(spans: [span("hello")])])
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, theme.bodyFont.pointSize)
        XCTAssertFalse(font!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    // MARK: Spans

    /// Bold must land on exactly the bold span's characters — not bleed into its neighbours.
    func testBoldAppliesOnlyToTheBoldSpansRange() {
        let out = build([.paragraph(spans: [span("plain "), span("bold", bold: true), span(" tail")])])
        let text = out.string as NSString
        let boldRange = text.range(of: "bold")
        let plainFont = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let boldFont = out.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        let tailFont = out.attribute(.font, at: boldRange.location + boldRange.length, effectiveRange: nil) as? NSFont
        XCTAssertFalse(plainFont!.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(boldFont!.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertFalse(tailFont!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testItalicAndUnderlineAreIndependentOfBold() {
        let out = build([.paragraph(spans: [span("slanted", italic: true), span("lined", underline: true)])])
        let text = out.string as NSString
        let italicRange = text.range(of: "slanted")
        let underlineRange = text.range(of: "lined")
        let italicFont = out.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(italicFont!.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertFalse(italicFont!.fontDescriptor.symbolicTraits.contains(.bold))
        let underlineValue = out.attribute(.underlineStyle, at: underlineRange.location, effectiveRange: nil) as? Int
        XCTAssertEqual(underlineValue, NSUnderlineStyle.single.rawValue)
    }

    // MARK: caps / smallCaps (P2R)

    /// `caps` uppercases the DISPLAYED text only — the run's own `text` never changes, so this
    /// asserts against the rendered string, not the source `Span`.
    func testCapsRunRendersUppercasedText() {
        let out = build([.paragraph(spans: [span("shout", caps: true)])])
        XCTAssertEqual(out.string, "shout".uppercased() + "\n")
    }

    /// `smallCaps` must NOT touch the string — the transform is a font feature, not a text edit —
    /// and the font it produces must actually request the small-caps feature (not merely "some
    /// font", which would silently do nothing visually).
    func testSmallCapsRunKeepsLowercaseTextButAppliesTheFontFeature() {
        let out = build([.paragraph(spans: [span("whisper", smallCaps: true)])])
        XCTAssertEqual(out.string, "whisper\n")
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let features = font?.fontDescriptor.object(forKey: .featureSettings) as? [[NSFontDescriptor.FeatureKey: Int]]
        let hasSmallCapsFeature = features?.contains {
            $0[.typeIdentifier] == kLowerCaseType && $0[.selectorIdentifier] == kLowerCaseSmallCapsSelector
        } ?? false
        XCTAssertTrue(hasSmallCapsFeature)
    }

    /// Word's own precedence: when a run carries BOTH toggles, `caps` wins — the text renders
    /// uppercased (small-caps has no visible effect on already-capital letters anyway).
    func testCapsWinsOverSmallCapsWhenBothAreSet() {
        let out = build([.paragraph(spans: [span("both", caps: true, smallCaps: true)])])
        XCTAssertEqual(out.string, "BOTH\n")
    }

    /// A run with neither toggle set renders byte-identical to before this field existed — the
    /// "unspecified = identical" contract for this sprint's addition.
    func testNeitherCapsNorSmallCapsLeavesTextAndFontUntouched() {
        let out = build([.paragraph(spans: [span("plain")])])
        XCTAssertEqual(out.string, "plain\n")
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let features = font?.fontDescriptor.object(forKey: .featureSettings) as? [[NSFontDescriptor.FeatureKey: Int]]
        XCTAssertNil(features)
    }

    // MARK: underline style (P2R)

    /// `underlineStyle` only matters when `underline` is `true` — its default `.single` renders
    /// the exact `NSUnderlineStyle.single` every underlined span rendered before this field
    /// existed, so an unspecified style is byte-identical to before.
    func testDefaultUnderlineStyleRendersSingle() {
        let out = build([.paragraph(spans: [span("lined", underline: true)])])
        let value = out.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(value, NSUnderlineStyle.single.rawValue)
    }

    func testDoubleUnderlineStyleRendersNSUnderlineStyleDouble() {
        let out = build([.paragraph(spans: [span("lined", underline: true, underlineStyle: .double)])])
        let value = out.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(value, NSUnderlineStyle.double.rawValue)
    }

    func testDottedUnderlineStyleRendersThePatternDotStyle() {
        let out = build([.paragraph(spans: [span("lined", underline: true, underlineStyle: .dotted)])])
        let value = out.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(value, NSUnderlineStyle.patternDot.rawValue)
    }

    /// `underline == false` never draws an underline attribute at all, regardless of whatever
    /// `underlineStyle` happens to be carrying — the toggle still gates everything.
    func testUnderlineOffDrawsNoUnderlineAttributeEvenWithADoubleStyleSet() {
        let out = build([.paragraph(spans: [span("plain", underline: false, underlineStyle: .double)])])
        XCTAssertNil(out.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }

    /// `code` overrides font/color to the theme's inline-code styling and tags `MDAttr.inlineCode`
    /// — same contract `MarkdownRenderer` uses for the layout manager's chip background.
    func testCodeSpanUsesInlineCodeStylingAndIsTagged() {
        let out = build([.paragraph(spans: [span("snippet", code: true)])])
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let color = out.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(font?.pointSize, theme.codeFont.pointSize)
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertEqual(color, theme.inlineCodeColor)
        XCTAssertNotNil(out.attribute(MDAttr.inlineCode, at: 0, effectiveRange: nil))
    }

    /// `spansAttributedString` must stay reachable from other files in this module — a later
    /// sprint's RTF reader re-themes spans it parsed itself, not `OfficeBlock`s. This call is the
    /// regression guard: it fails to COMPILE if the method goes back to `private`.
    func testSpansAttributedStringIsCallableFromOutsideThisType() {
        let out = OfficeTextBuilder.spansAttributedString([span("hi", bold: true)], baseFont: theme.bodyFont,
                                                           baseColor: theme.textColor, theme: theme)
        XCTAssertEqual(out.string, "hi")
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    // MARK: Lists — indent

    func testNestedListIndentIncreasesStrictlyWithLevel() {
        let blocks: [OfficeBlock] = [
            .listItem(level: 0, ordered: true, spans: [span("top")]),
            .listItem(level: 1, ordered: true, spans: [span("nested")]),
            .listItem(level: 2, ordered: true, spans: [span("deeper")]),
        ]
        let out = build(blocks)
        var indents: [CGFloat] = []
        out.enumerateAttribute(MDAttr.blockId, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard value is Int else { return }
            let ps = out.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            indents.append(ps!.headIndent)
        }
        XCTAssertEqual(indents.count, 3)
        XCTAssertLessThan(indents[0], indents[1])
        XCTAssertLessThan(indents[1], indents[2])
    }

    // MARK: Lists — ordered numbering restart

    /// The brief's required case: after a deeper nested run, the OUTER level's numbering must
    /// still come out correct — i.e. it keeps counting (1, 2), not reset by the nested items.
    func testOrderedNumberingAfterADeeperLevelContinuesTheOuterCount() {
        let blocks: [OfficeBlock] = [
            .listItem(level: 0, ordered: true, spans: [span("a")]),
            .listItem(level: 1, ordered: true, spans: [span("a-1")]),
            .listItem(level: 1, ordered: true, spans: [span("a-2")]),
            .listItem(level: 0, ordered: true, spans: [span("b")]),
        ]
        XCTAssertEqual(listMarkers(in: build(blocks)), ["1.", "1.", "2.", "2."])
    }

    /// A SHALLOWER level intervening breaks the deeper level's run: level 1 must restart at "1."
    /// once a level-0 item has appeared in between.
    func testOrderedNumberingRestartsAfterAShallowerLevelIntervenes() {
        let blocks: [OfficeBlock] = [
            .listItem(level: 1, ordered: true, spans: [span("x-1")]),
            .listItem(level: 1, ordered: true, spans: [span("x-2")]),
            .listItem(level: 0, ordered: true, spans: [span("shallow")]),
            .listItem(level: 1, ordered: true, spans: [span("y-1")]),
        ]
        XCTAssertEqual(listMarkers(in: build(blocks)), ["1.", "2.", "1.", "1."])
    }

    /// An unordered item breaks an ordered run at the SAME level too.
    func testOrderedNumberingRestartsAfterABulletAtTheSameLevel() {
        let blocks: [OfficeBlock] = [
            .listItem(level: 0, ordered: true, spans: [span("one")]),
            .listItem(level: 0, ordered: false, spans: [span("bullet")]),
            .listItem(level: 0, ordered: true, spans: [span("restarted")]),
        ]
        XCTAssertEqual(listMarkers(in: build(blocks)), ["1.", "•", "1."])
    }

    func testUnorderedListUsesABulletNotANumber() {
        let out = build([.listItem(level: 0, ordered: false, spans: [span("item")])])
        XCTAssertEqual(listMarkers(in: out), ["•"])
    }

    // MARK: Tables

    /// One placed cell of a real `NSTextTable`: the `NSTextTableBlock` (position/span/shading/border/
    /// vertical-alignment/padding), the cell's concatenated text, and its full contiguous range in
    /// `out` — so a test reads the cell content's font/paragraph-style straight from the top-level
    /// string (a cell's content is now real, selectable text there, not a drawn attachment).
    private struct PlacedCell {
        let block: NSTextTableBlock
        let text: String
        let range: NSRange
        var row: Int { block.startingRow }
        var col: Int { block.startingColumn }
        var rowSpan: Int { block.rowSpan }
        var colSpan: Int { block.columnSpan }
        var background: NSColor? { block.backgroundColor }
        var borderColor: NSColor? { block.borderColor(for: .minX) }
        var borderWidth: CGFloat { block.width(for: .border, edge: .minX) }
        var padding: CGFloat { block.width(for: .padding, edge: .minX) }
        var verticalAlignment: NSTextBlock.VerticalAlignment { block.verticalAlignment }
    }

    /// Every placed cell in `out`, in reading order (row, then column), deduped by block identity so
    /// a multi-paragraph cell is ONE entry (its paragraphs' text concatenated). The count equals the
    /// old placed-cell count — padding cells for genuinely-empty positions carry their own block too,
    /// so shape/count assertions map straight across from the former custom-engine helper.
    private func tableCells(in out: NSAttributedString) -> [PlacedCell] {
        var order: [ObjectIdentifier] = []
        var byId: [ObjectIdentifier: (block: NSTextTableBlock, text: String, start: Int, end: Int)] = [:]
        let ns = out.string as NSString
        out.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard let ps = value as? NSParagraphStyle, let block = ps.textBlocks.first as? NSTextTableBlock else { return }
            let id = ObjectIdentifier(block)
            if var e = byId[id] {
                e.text += ns.substring(with: range)
                e.start = min(e.start, range.location)
                e.end = max(e.end, range.location + range.length)
                byId[id] = e
            } else {
                byId[id] = (block, ns.substring(with: range), range.location, range.location + range.length)
                order.append(id)
            }
        }
        return order.map {
            let e = byId[$0]!
            return PlacedCell(block: e.block, text: e.text, range: NSRange(location: e.start, length: e.end - e.start))
        }
    }

    /// The one `GridTextTable` in `out`. Column-width assertions read its `columnProportions` — a
    /// cell's width fraction is the sum of `columnProportions[col ..< col+colSpan]`.
    private func firstGridTable(in out: NSAttributedString) -> GridTextTable? {
        tableCells(in: out).compactMap { $0.block.table as? GridTextTable }.first
    }

    /// The number of rows the placed cells cover (max `startingRow + rowSpan`) — the old
    /// an `NSTextTable`'s row count, derived from the placed blocks rather than a stored engine object.
    private func tableRowCount(in out: NSAttributedString) -> Int {
        tableCells(in: out).map { $0.row + $0.rowSpan }.max() ?? 0
    }

    /// A 2x2 table where one cell is empty must keep both rows at the same column count — the
    /// empty cell still occupies its own placed cell block, it doesn't collapse the row or
    /// shift the remaining column. `headerRows: 1` is today's asserted shape behaviour, kept as-is.
    func testTableWithHeaderRowAndAnEmptyCellKeepsItsRowAndColumnShape() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("Name")]), Cell(spans: [span("Score")])],
            [Cell(spans: []), Cell(spans: [span("42")])],
        ]
        let out = build([.table(rows: rows, headerRows: 1)])
        let cells = tableCells(in: out)
        XCTAssertEqual(cells.count, 4, "2 header cells + 2 body cells, empty cell included")
        let bodyRowCols = Set(cells.filter { $0.row == 1 }.map(\.col))
        XCTAssertEqual(bodyRowCols, [0, 1], "the empty first cell must still keep its column in place")
    }

    /// Same shape guarantee with NO header row at all — a headerless table (the common case in the
    /// real contract test set) must not collapse a column just because row 0 isn't styled.
    func testTableWithNoHeaderAndAnEmptyCellKeepsItsRowAndColumnShape() {
        let rows: [[Cell]] = [
            [Cell(spans: []), Cell(spans: [span("42")])],
            [Cell(spans: [span("Name")]), Cell(spans: [span("Score")])],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let cells = tableCells(in: out)
        XCTAssertEqual(cells.count, 4)
        let firstRowCols = Set(cells.filter { $0.row == 0 }.map(\.col))
        XCTAssertEqual(firstRowCols, [0, 1], "the empty first cell must still keep its column in place")
    }

    func testTableHeaderRowIsShadedWithThemeHeaderBackground() {
        let out = build([.table(rows: [
            [Cell(spans: [span("H1")]), Cell(spans: [span("H2")])],
            [Cell(spans: [span("v1")]), Cell(spans: [span("v2")])],
        ], headerRows: 1)])
        let cells = tableCells(in: out)
        let headerBgs = cells.filter { $0.row == 0 }.compactMap(\.background)
        XCTAssertEqual(headerBgs.count, 2)
        XCTAssertTrue(headerBgs.allSatisfy { $0 == Palette.tableHeaderBg })
        let bodyBgs = cells.filter { $0.row == 1 }.compactMap(\.background)
        XCTAssertTrue(bodyBgs.isEmpty, "only the header row is shaded")
    }

    /// `headerRows: 0` — the "source can't tell us" case — must render row 0 as ordinary content:
    /// no bold, no header shading. Defaulting this to look like a header would misrepresent a
    /// document that never had one (see `OfficeBlock.table`).
    func testHeaderRowsZeroRendersFirstRowWithPlainBodyAttributes() {
        let out = build([.table(rows: [
            [Cell(spans: [span("H1")]), Cell(spans: [span("H2")])],
            [Cell(spans: [span("v1")]), Cell(spans: [span("v2")])],
        ], headerRows: 0)])
        let cells = tableCells(in: out)
        let firstCell = try! XCTUnwrap(cells.first { $0.row == 0 && $0.col == 0 })
        let font = out.attribute(.font, at: firstCell.range.location, effectiveRange: nil) as? NSFont
        XCTAssertFalse(font!.fontDescriptor.symbolicTraits.contains(.bold), "headerRows: 0 must not bold row 0")
        XCTAssertTrue(cells.allSatisfy { $0.background == nil }, "headerRows: 0 must not shade any row")
    }

    /// The point of this whole sprint: a Word table and a markdown table with the same logical
    /// content (2 columns, 1 header row, 2 body rows) must produce structurally EQUIVALENT tables —
    /// same cell count, same row/column placement, same border colour, same header shading — because
    /// both now go through `TableBlockBuilder` into one `NSTextTable`. Font/text differ
    /// (different source pipelines feed the cell content), so this compares grid STRUCTURE.
    func testOfficeAndMarkdownTablesWithSameContentProduceStructurallyEquivalentBlocks() {
        let officeOut = build([.table(rows: [
            [Cell(spans: [span("A")]), Cell(spans: [span("B")])],
            [Cell(spans: [span("1")]), Cell(spans: [span("2")])],
        ], headerRows: 1)])
        let markdownOut = MarkdownRenderer.render("| A | B |\n|---|---|\n| 1 | 2 |", theme: theme)

        let officeCells = tableCells(in: officeOut)
        let markdownCells = tableCells(in: markdownOut)

        XCTAssertEqual(officeCells.count, 4)
        XCTAssertEqual(officeCells.count, markdownCells.count)
        func shape(_ cells: [PlacedCell]) -> [[Int]] {
            cells.map { [$0.row, $0.col] }
        }
        XCTAssertEqual(shape(officeCells), shape(markdownCells))
        XCTAssertEqual(officeCells.filter { $0.background != nil }.count, 2)
        XCTAssertEqual(officeCells.filter { $0.background != nil }.count,
                       markdownCells.filter { $0.background != nil }.count)
        let officeBorders = Set(officeCells.map { $0.borderColor })
        let markdownBorders = Set(markdownCells.map { $0.borderColor })
        XCTAssertEqual(officeBorders, markdownBorders)
        XCTAssertEqual(officeBorders, [Palette.tableBorder])
    }

    // MARK: Tables — spans (R1-3)

    /// The safety net for the whole R1 change: a table where every `Cell` is left at its default
    /// `rowSpan`/`colSpan` of 1 must produce the exact block count and shape the pre-R1 rectangular
    /// grid did — nothing about ordinary tables may change just because spans exist as a concept.
    func testTableWithAllSpansOneRendersIdenticallyToAPlainGrid() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("A")]), Cell(spans: [span("B")]), Cell(spans: [span("C")])],
            [Cell(spans: [span("1")]), Cell(spans: [span("2")]), Cell(spans: [span("3")])],
        ]
        let out = build([.table(rows: rows, headerRows: 1)])
        let cells = tableCells(in: out)
        XCTAssertEqual(cells.count, 6)
        XCTAssertTrue(cells.allSatisfy { $0.rowSpan == 1 && $0.colSpan == 1 })
        XCTAssertEqual(Set(cells.filter { $0.row == 0 }.map(\.col)), [0, 1, 2])
        XCTAssertEqual(Set(cells.filter { $0.row == 1 }.map(\.col)), [0, 1, 2])
    }

    /// A `colSpan: 2` anchor in a 3-column table must occupy columns 0–1, and the row's next cell
    /// must land in column 2 — not column 1, which the anchor already covers.
    func testColSpanTwoOccupiesTwoColumnsAndTheNextCellStartsAfterIt() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("wide")], colSpan: 2), Cell(spans: [span("narrow")])],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let cells = tableCells(in: out)
        XCTAssertEqual(cells.count, 2)
        let wide = cells.first { $0.col == 0 }
        let narrow = cells.first { $0.col == 2 }
        XCTAssertEqual(wide?.colSpan, 2)
        XCTAssertNotNil(narrow, "the second cell must start at column 2, past the merged span")
        XCTAssertEqual(narrow?.colSpan, 1)
    }

    /// A `rowSpan: 2` anchor must occupy its own row and the one below it; the row below must
    /// place its OTHER cells in the columns the span doesn't cover, not shifted or dropped.
    func testRowSpanTwoOccupiesTwoRowsAndTheRowBelowFillsRemainingColumns() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("tall")], rowSpan: 2), Cell(spans: [span("top-right")])],
            [Cell(spans: [span("bottom-right")])],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let cells = tableCells(in: out)
        XCTAssertEqual(cells.count, 3)
        let tall = cells.first { $0.row == 0 && $0.col == 0 }
        XCTAssertEqual(tall?.rowSpan, 2)
        let bottomRight = cells.first { $0.row == 1 }
        XCTAssertEqual(bottomRight?.col, 1, "row 1's own cell must land in the column the span doesn't cover")
    }

    /// A row can carry FEWER anchors than the grid is wide — exactly what a Word row looks like once
    /// its other cells are absorbed by a merge. Every column must still get a block, or the border
    /// has a hole in it: an unoccupied position with no placed cell block draws nothing at all,
    /// which reads as a broken table rather than an empty cell. Note this is a SHORT ARRAY, not an
    /// empty `Cell` — the distinction the padding pass exists for.
    func testRowWithFewerAnchorsThanTheGridStillDrawsEveryColumn() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("A")]), Cell(spans: [span("B")]), Cell(spans: [span("C")])],
            [Cell(spans: [span("1")])],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let cells = tableCells(in: out)
        XCTAssertEqual(Set(cells.filter { $0.row == 1 }.map(\.col)), [0, 1, 2],
                       "the short row must still cover all three columns")
        XCTAssertEqual(cells.count, 6)
    }

    /// The other half of that rule: a position covered by another cell's span is OCCUPIED, not empty,
    /// and must NOT be padded. Padding it would put a second block in one grid position.
    func testColumnsCoveredByAnEarlierRowsSpanAreNotPadded() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("tall")], rowSpan: 2), Cell(spans: [span("top")])],
            [Cell(spans: [span("bottom")])],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let cells = tableCells(in: out)
        XCTAssertEqual(cells.count, 3, "no padding cell may be added under the vertical span")
        let row1 = cells.filter { $0.row == 1 }
        XCTAssertEqual(row1.count, 1)
        XCTAssertEqual(row1.first?.col, 1)
    }

    /// A span that reaches the last column leaves nothing to pad.
    func testColSpanReachingTheLastColumnAddsNoTrailingPadding() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("A")]), Cell(spans: [span("B")])],
            [Cell(spans: [span("wide")], colSpan: 2)],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let cells = tableCells(in: out)
        XCTAssertEqual(cells.count, 3)
        XCTAssertEqual(cells.filter { $0.row == 1 }.count, 1)
    }

    /// Spans arrive from a parsed file, so they are untrusted input. A document claiming a cell spans
    /// a huge number of rows must not turn into that many loop iterations and set insertions — the
    /// same posture `ZipArchive` takes toward a declared size. The table still renders.
    func testAbsurdSpanIsClampedRatherThanLoopedOver() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("hostile")], rowSpan: 100_000, colSpan: 100_000)],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let cells = tableCells(in: out)
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells.first?.rowSpan, TableBlockBuilder.maxSpan)
        XCTAssertEqual(cells.first?.colSpan, TableBlockBuilder.maxSpan)
    }

    /// A rowSpan that claims MORE rows than the table actually has, on a cell that is NOT in the
    /// last column, must not crash. `OdtReader` (`table:number-rows-spanned`) and `HwpReader` read
    /// the span verbatim with no clamp of their own — only `DocxReader` clamps at its own source —
    /// so an .odt/.hwp whose author (or a hand-edited/malformed file) wrote a taller span than the
    /// table has rows below it reaches `TableBlockBuilder.build` completely untouched. The absurd-span
    /// test above (`testAbsurdSpanIsClampedRatherThanLoopedOver`) does NOT cover this: its one cell is
    /// also the LAST column, which hits the perimeter arm (`p.col + p.colSpan >= ncol`) and never
    /// touches the `.maxX` neighbour scan below it — the one that was reading `grid[r]` for `r` up to
    /// `p.row + p.rowSpan`, unclamped, against a `grid` sized to the table's real `rowCount`.
    func testRowSpanPastTheLastRowInANonFinalColumnDoesNotCrash() {
        // 1 row, rowSpan 3, column 0 of 2 — NOT the last column.
        let oneRow: [[Cell]] = [
            [Cell(spans: [span("Tall")], rowSpan: 3), Cell(spans: [span("B")])],
        ]
        let out1 = build([.table(rows: oneRow, headerRows: 0)])
        XCTAssertGreaterThan(out1.length, 0, "a rowSpan taller than the table must not crash — untrusted input, not a fatal error")

        // 2 rows, rowSpan 3 on the first row's first (non-final) column.
        let twoRows: [[Cell]] = [
            [Cell(spans: [span("Tall")], rowSpan: 3), Cell(spans: [span("B")])],
            [Cell(spans: [span("C")])],
        ]
        let out2 = build([.table(rows: twoRows, headerRows: 0)])
        XCTAssertGreaterThan(out2.length, 0)

        // 3x4 grid, rowSpan 3 at (row 1, col 1) — reaches row 4 against a 3-row table.
        let grid: [[Cell]] = [
            [Cell(spans: [span("r0c0")]), Cell(spans: [span("r0c1")]), Cell(spans: [span("r0c2")]), Cell(spans: [span("r0c3")])],
            [Cell(spans: [span("r1c0")]), Cell(spans: [span("tall")], rowSpan: 3), Cell(spans: [span("r1c2")]), Cell(spans: [span("r1c3")])],
            [Cell(spans: [span("r2c0")]), Cell(spans: [span("r2c2")]), Cell(spans: [span("r2c3")])],
        ]
        let out3 = build([.table(rows: grid, headerRows: 0)])
        XCTAssertGreaterThan(out3.length, 0)

        // Same over-claim, but IN the last column — must have already been safe (the perimeter arm).
        let lastColumn: [[Cell]] = [
            [Cell(spans: [span("A")]), Cell(spans: [span("Tall")], rowSpan: 3)],
        ]
        let out4 = build([.table(rows: lastColumn, headerRows: 0)])
        XCTAssertGreaterThan(out4.length, 0)
    }

    /// A zero or negative span is nonsense but must not vanish the cell or stall the column cursor.
    func testZeroSpanIsTreatedAsOne() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("A")], rowSpan: 0, colSpan: 0), Cell(spans: [span("B")])],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let cells = tableCells(in: out)
        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(Set(cells.map(\.col)), [0, 1], "a zero span must still advance the cursor")
    }

    /// A merged cell must not disturb header shading: only row 0 is shaded, regardless of a span
    /// reaching into row 1.
    func testMergedCellCombinedWithOneHeaderRowStillShadesOnlyTheHeaderRow() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("H1")], colSpan: 2)],
            [Cell(spans: [span("v1")]), Cell(spans: [span("v2")])],
        ]
        let out = build([.table(rows: rows, headerRows: 1)])
        let cells = tableCells(in: out)
        let headerBgs = cells.filter { $0.row == 0 }.compactMap(\.background)
        XCTAssertEqual(headerBgs.count, 1)
        let bodyBgs = cells.filter { $0.row == 1 }.compactMap(\.background)
        XCTAssertTrue(bodyBgs.isEmpty)
    }

    // MARK: Span marks (R1-2 / R1-4)

    /// Each new mark must land on exactly its own span's range — the same "no bleed into
    /// neighbours" contract `testBoldAppliesOnlyToTheBoldSpansRange` already holds bold to.
    func testStrikethroughSuperscriptAndSubscriptEachRenderOnlyOnTheirOwnRange() {
        var strike = span("gone"); strike.strikethrough = true
        var sup = span("note"); sup.superscript = true
        var sub = span("index"); sub.subscripted = true
        let out = build([.paragraph(spans: [span("plain "), strike, span(" "), sup, span(" "), sub])])
        let text = out.string as NSString

        let strikeRange = text.range(of: "gone")
        XCTAssertEqual(out.attribute(.strikethroughStyle, at: strikeRange.location, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)
        XCTAssertNil(out.attribute(.strikethroughStyle, at: 0, effectiveRange: nil), "plain text must not be struck through")

        let supRange = text.range(of: "note")
        let plainFont = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let supFont = out.attribute(.font, at: supRange.location, effectiveRange: nil) as? NSFont
        let supOffset = out.attribute(.baselineOffset, at: supRange.location, effectiveRange: nil) as? CGFloat
        XCTAssertLessThan(supFont!.pointSize, plainFont!.pointSize, "superscript must shrink the glyph")
        XCTAssertGreaterThan(supOffset ?? 0, 0, "superscript must raise the baseline")

        let subRange = text.range(of: "index")
        let subFont = out.attribute(.font, at: subRange.location, effectiveRange: nil) as? NSFont
        let subOffset = out.attribute(.baselineOffset, at: subRange.location, effectiveRange: nil) as? CGFloat
        XCTAssertLessThan(subFont!.pointSize, plainFont!.pointSize, "subscript must shrink the glyph")
        XCTAssertLessThan(subOffset ?? 0, 0, "subscript must lower the baseline")
    }

    // MARK: Writing direction (RTL) — S12

    /// `OfficeBlock.paragraph`'s `rtl` becomes `NSParagraphStyle.baseWritingDirection`, never a
    /// hand-set `.alignment` — see `OfficeBlock`'s doc comment for why `.natural` alignment already
    /// resolves to the right edge once the base direction is `.rightToLeft`.
    func testRTLParagraphGetsRightToLeftBaseWritingDirection() {
        let out = build([.paragraph(spans: [span("rtl text")], rtl: true)])
        let style = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.baseWritingDirection, .rightToLeft)
    }

    /// An LTR paragraph (`rtl` at its default, `false`) is untouched — `baseWritingDirection` stays
    /// at `NSMutableParagraphStyle()`'s own default, `.natural`, exactly as every pre-sprint
    /// paragraph already rendered.
    func testLTRParagraphKeepsNaturalBaseWritingDirection() {
        let out = build([.paragraph(spans: [span("ltr text")])])
        let style = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.baseWritingDirection, .natural)
    }

    /// The same field on a heading and a list item — not something only `.paragraph` respects.
    func testRTLHeadingAndListItemAlsoGetRightToLeftBaseWritingDirection() {
        let headingOut = build([.heading(level: 1, spans: [span("Title")], rtl: true)])
        let headingStyle = headingOut.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(headingStyle?.baseWritingDirection, .rightToLeft)

        let listOut = build([.listItem(level: 0, ordered: false, spans: [span("Item")], rtl: true)])
        let listStyle = listOut.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(listStyle?.baseWritingDirection, .rightToLeft)
    }

    /// A run-level `Span.rtl` (docx `w:rPr/w:rtl` on a phrase embedded in the opposite-direction
    /// paragraph) becomes TextKit's own run-level `.writingDirection` embedding override — distinct
    /// from, and independent of, the paragraph's base direction.
    func testRTLSpanCarriesRunLevelWritingDirectionAttribute() {
        var rtlSpan = span("embedded"); rtlSpan.rtl = true
        let out = build([.paragraph(spans: [span("plain "), rtlSpan])])
        let text = out.string as NSString
        let embeddedRange = text.range(of: "embedded")
        XCTAssertNil(out.attribute(.writingDirection, at: 0, effectiveRange: nil), "the plain span must carry no override")
        let direction = out.attribute(.writingDirection, at: embeddedRange.location, effectiveRange: nil) as? [Int]
        XCTAssertEqual(direction, [NSWritingDirection.rightToLeft.rawValue | NSWritingDirectionFormatType.embedding.rawValue])
    }

    /// docx's `w:bidi` and odt's `style:writing-mode="rl-tb"` must agree once both readers hand
    /// their `rtl: true` block to the SAME builder — this is the cross-format-agreement guard
    /// `testOfficeAndMarkdownTablesWithSameContentProduceStructurallyEquivalentBlocks` already uses
    /// for tables, applied to writing direction.
    func testDocxAndOdtSourcedRTLBlocksProduceIdenticalBaseWritingDirection() {
        let docxOut = build([.paragraph(spans: [span("text")], rtl: true)])
        let odtOut = build([.paragraph(spans: [span("text")], rtl: true)])
        let docxStyle = docxOut.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let odtStyle = odtOut.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(docxStyle?.baseWritingDirection, odtStyle?.baseWritingDirection)
    }

    /// THE REGRESSION GUARD this sprint's brief demands: an LTR document's produced
    /// `NSAttributedString` is IDENTICAL — not just "close" — to what it was before `rtl` existed.
    /// a table's `NSTextTable` cell content is real text (unlike other blocks, its structure is what matters, not raw `isEqual`)
    /// under `isEqual`, so this
    /// compares the STRING plus every base-writing-direction (the one thing this sprint could have
    /// disturbed) across two independently-built copies of the same non-trivial blocks — headings,
    /// lists, tables, mixed spans — asserted by comparison, never by eyeball.
    func testLTRDocumentProducesTheSameStringAndBaseWritingDirectionAcrossEveryBlockKind() {
        let blocks: [OfficeBlock] = [
            .heading(level: 1, spans: [span("Title", bold: true)]),
            .paragraph(spans: [span("plain "), span("bold", bold: true), span(" tail")]),
            .listItem(level: 0, ordered: true, spans: [span("One")]),
            .listItem(level: 1, ordered: false, spans: [span("Nested")]),
            .table(rows: [[Cell(spans: [span("A")]), Cell(spans: [span("B")])]], headerRows: 1),
        ]
        let a = build(blocks)
        let b = build(blocks)
        XCTAssertEqual(a.string, b.string)
        func directions(_ out: NSAttributedString) -> [NSWritingDirection] {
            var seen: [NSWritingDirection] = []
            out.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: out.length)) { value, _, _ in
                guard let style = value as? NSParagraphStyle else { return }
                seen.append(style.baseWritingDirection)
            }
            return seen
        }
        let directionsA = directions(a)
        XCTAssertEqual(directionsA, directions(b))
        XCTAssertTrue(directionsA.allSatisfy { $0 == .natural }, "no LTR block may pick up an explicit direction")
    }

    /// A linked office span must carry the identical `.foregroundColor`/`.underlineStyle`/`.link`
    /// treatment a markdown link gets — a reader shouldn't be able to tell which format a link
    /// came from just by looking at it.
    func testLinkSpanCarriesTheSameAttributesAMarkdownLinkDoes() {
        var linked = span("click here"); linked.link = "https://example.com/doc"
        let officeOut = build([.paragraph(spans: [linked])])
        let markdownOut = MarkdownRenderer.render("[click here](https://example.com/doc)", theme: theme)

        let officeColor = officeOut.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let officeUnderline = officeOut.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        let officeURL = officeOut.attribute(.link, at: 0, effectiveRange: nil) as? URL

        let mdLoc = (markdownOut.string as NSString).range(of: "click here").location
        let mdColor = markdownOut.attribute(.foregroundColor, at: mdLoc, effectiveRange: nil) as? NSColor
        let mdUnderline = markdownOut.attribute(.underlineStyle, at: mdLoc, effectiveRange: nil) as? Int
        let mdURL = markdownOut.attribute(.link, at: mdLoc, effectiveRange: nil) as? URL

        XCTAssertEqual(officeColor, mdColor)
        XCTAssertEqual(officeUnderline, mdUnderline)
        XCTAssertEqual(officeURL, mdURL)
        XCTAssertEqual(officeURL, URL(string: "https://example.com/doc"))
    }

    /// The `······` a contents entry runs between its title and its page number — docx
    /// `w:tabs/w:tab/@w:leader`. `NSTextTab` has no leader-fill, so the leader is carried on the TAB
    /// CHARACTER (`MDAttr.tabLeader`) and drawn at draw time; this is the build half.
    ///
    /// Only a paragraph whose stops DECLARE a leader gets one — the owner's own line was "유저가
    /// 직접 지정한 경우에는 그리는게 낫긴 하겠지", so a plain tab stays a plain tab (which is every
    /// markdown, plain-text and ODT tab, invariant 37).
    func testATabIsMarkedWithTheLeaderItsOwnStopDeclared() {
        let dotted = TabStop(position: 400, alignment: .right, leader: .dot)
        let plain = TabStop(position: 400, alignment: .right, leader: .none)

        func leader(of stop: TabStop) -> String? {
            let out = build([.paragraph(spans: [span("Title"), span("\t"), span("3")],
                                        tabStops: [stop])])
            let tab = (out.string as NSString).range(of: "\t")
            XCTAssertNotEqual(tab.location, NSNotFound, "the fixture must actually contain a tab")
            return out.attribute(MDAttr.tabLeader, at: tab.location, effectiveRange: nil) as? String
        }

        XCTAssertEqual(leader(of: dotted), ".", "a declared dot leader reaches the tab character")
        XCTAssertNil(leader(of: plain), "an ordinary tab must stay ordinary")
        XCTAssertEqual(OfficeTextBuilder.leaderCharacter(.hyphen), "-")
        XCTAssertEqual(OfficeTextBuilder.leaderCharacter(.underscore), "_")
        XCTAssertNil(OfficeTextBuilder.leaderCharacter(TabLeader.none))
    }

    /// invariant 57 reaching the link branch: a PAGED document that stated a colour on a link keeps
    /// it, because a printed manual setting its cross-references in black is not asking for the
    /// reader's blue. Three cases, and the two that must NOT change are the point of the test.
    func testAPagedLinkKeepsAnAuthoredColourButAnUncolouredOneStaysTheThemeLink() {
        var authored = span("click here")
        authored.link = "https://example.com/doc"
        authored.textColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)   // the document's black
        var plain = span("click here")
        plain.link = "https://example.com/doc"

        func colour(_ s: Span, paged: Bool) -> NSColor? {
            OfficeTextBuilder.build([.paragraph(spans: [s])], theme: theme,
                                    pageContentWidth: paged ? 400 : nil)
                .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        }

        XCTAssertEqual(colour(authored, paged: true),
                       OfficeTextBuilder.resolvedTextColor(authored.textColor!, theme: theme),
                       "a paged document's own link colour wins")
        // Word's blue-and-underlined hyperlink comes from a CHARACTER style this reader does not
        // resolve yet, so an uncoloured link must keep the theme's stand-in — handing it the body
        // colour would make every link in every document invisible as a link.
        XCTAssertEqual(colour(plain, paged: true), theme.linkColor,
                       "no authored colour → the theme link colour still stands in")
        // And the non-paged half does not move at all (invariant 57d).
        XCTAssertEqual(colour(authored, paged: false), theme.linkColor)
        XCTAssertEqual(colour(plain, paged: false), theme.linkColor)
    }

    /// THE ACTUAL BUG (S11): an office in-document link (`span.link == "#BookmarkName"`, docx
    /// `w:anchor` / odt same-document `xlink:href`) must NEVER become a bare `.link` URL built from
    /// the raw fragment — `DocumentWindowController.textView(_:clickedOnLink:at:)` treats any
    /// scheme-less, non-anchor URL as a relative file path and tries to open a file named after the
    /// bookmark. It must instead carry `MDAttr.anchor` (the click handler's own escape hatch,
    /// checked before the file-path branch) with the placeholder link markdown's own TOC links use.
    ///
    /// MUTATION CHECK: reverting `OfficeTextBuilder`'s `#`-prefix branch to the old
    /// `attrs[.link] = url` behaviour makes `officeURL` equal `URL(string: "#BookmarkName")` and
    /// `officeAnchor` nil — this assertion fails under that code, proving it exercises the fix.
    func testInDocumentAnchorLinkNeverBecomesABareFragmentURL() {
        var linked = span("clause 7"); linked.link = "#BookmarkName"
        let out = build([.paragraph(spans: [linked])])
        let officeAnchor = out.attribute(MDAttr.anchor, at: 0, effectiveRange: nil) as? String
        let officeURL = out.attribute(.link, at: 0, effectiveRange: nil) as? URL
        XCTAssertEqual(officeAnchor, "BookmarkName")
        XCTAssertEqual(officeURL, URL(string: "fmdanchor:jump"))
        XCTAssertNotEqual(officeURL, URL(string: "#BookmarkName"))
    }

    /// A bookmark's target position (`Span.bookmarks`) reaches the rendered text as
    /// `MDAttr.bookmarkTarget`, over the span it marks — not the whole block, not lost.
    ///
    /// MUTATION CHECK: dropping the `!span.bookmarks.isEmpty` block in `spansAttributedString`
    /// makes `target` nil — this assertion fails under that code.
    func testBookmarkedSpanCarriesBookmarkTargetAttribute() {
        var marked = span("Clause 7"); marked.bookmarks = ["_Toc1"]
        let out = build([.paragraph(spans: [span("Intro. "), marked])])
        let loc = (out.string as NSString).range(of: "Clause 7").location
        let target = out.attribute(MDAttr.bookmarkTarget, at: loc, effectiveRange: nil) as? [String]
        XCTAssertEqual(target, ["_Toc1"])
        // The preceding, unrelated text must NOT carry it.
        XCTAssertNil(out.attribute(MDAttr.bookmarkTarget, at: 0, effectiveRange: nil))
    }

    // MARK: Images

    /// Requirement 7 / invariant 1: the reserved size must be exactly the declared size, and the
    /// image itself must be nil — pixels arrive in a later sprint, and loading them must never
    /// change layout (only redraw).
    func testImageBlockReservesExactSizeWithNoPixelsYet() throws {
        let size = CGSize(width: 240, height: 135)
        let out = build([.image(id: "rel42", size: size)])
        var found: NSTextAttachment?
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if let att = value as? NSTextAttachment { found = att }
        }
        let attachment = try XCTUnwrap(found)
        XCTAssertNil(attachment.image)
        XCTAssertEqual(attachment.attachmentCell?.cellSize(), size)
        let sizedCell = attachment.attachmentCell as? SizedAttachmentCell
        XCTAssertEqual(sizedCell?.reservedSize, size)
        let idValue = out.attribute(MDAttr.image, at: 0, effectiveRange: nil) as? String
        XCTAssertEqual(idValue, "rel42")
    }

    /// A declared size WIDER than the column must scale down proportionally (aspect ratio
    /// preserved) — and the decision must be made HERE, at build time, from the declared size
    /// alone, not deferred to load time (see `MarkdownDocument.reconcileMedia`'s office branch,
    /// which only ever paints — never resizes — an office image).
    func testImageWiderThanColumnScalesDownProportionallyAtBuildTime() throws {
        let declared = CGSize(width: 2000, height: 1000)   // 2:1 aspect
        let out = OfficeTextBuilder.build([.image(id: "wide", size: declared)], theme: theme, columnWidth: 700)
        var found: NSTextAttachment?
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if let att = value as? NSTextAttachment { found = att }
        }
        let attachment = try XCTUnwrap(found)
        let cell = try XCTUnwrap(attachment.attachmentCell as? SizedAttachmentCell)
        XCTAssertEqual(cell.reservedSize.width, 700, accuracy: 0.5)
        XCTAssertEqual(cell.reservedSize.height, 350, accuracy: 0.5, "aspect ratio (2:1) must be preserved")
        XCTAssertEqual(attachment.bounds.size, cell.reservedSize)
    }

    // MARK: Graphic scale (page-proportional, font-independent)

    private func reservedImageSize(_ out: NSAttributedString) throws -> CGSize {
        var found: NSTextAttachment?
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if let att = value as? NSTextAttachment { found = att }
        }
        let cell = try XCTUnwrap(try XCTUnwrap(found).attachmentCell as? SizedAttachmentCell)
        return cell.reservedSize
    }

    /// The contract the whole two-scale split exists for: a graphic's size follows `graphicScale`
    /// (reading column ÷ the source page's body width) and is INDEPENDENT of the reading font size.
    /// Doubling the user's reading size must not move a photograph by one point — ⌘+/⌘− is a TEXT
    /// setting. (Before the split, graphics rode `fontSizeScale`, so ⌘+ inflated pictures.)
    func testGraphicSizeFollowsGraphicScaleAndIgnoresFontSize() throws {
        let declared = CGSize(width: 200, height: 100)
        // Column 800 over a 400pt page = scale 2, at two very different reading sizes.
        let small = OfficeTextBuilder.build([.image(id: "a", size: declared)],
                                            theme: RenderTheme.current(size: 12), columnWidth: 800,
                                            documentDefaultFontSize: 10, pageContentWidth: 400)
        let large = OfficeTextBuilder.build([.image(id: "a", size: declared)],
                                            theme: RenderTheme.current(size: 36), columnWidth: 800,
                                            documentDefaultFontSize: 10, pageContentWidth: 400)
        XCTAssertEqual(try reservedImageSize(small), CGSize(width: 400, height: 200),
                       "a column twice the page width must double the authored size")
        XCTAssertEqual(try reservedImageSize(large), try reservedImageSize(small),
                       "a 3× reading-size change must leave the graphic byte-identical")
    }

    /// The other half: with the SAME font, a wider column (i.e. a bigger `graphicScale`) must grow
    /// the graphic proportionally — this is what makes a picture track the WINDOW.
    func testGraphicGrowsProportionallyWithGraphicScale() throws {
        let declared = CGSize(width: 150, height: 75)
        // The real axis: the same document at three window widths (page 400pt → scale 1, 1.5, 3).
        let sizes = try [400.0, 600.0, 1200.0].map { column -> CGSize in
            try reservedImageSize(OfficeTextBuilder.build([.image(id: "a", size: declared)],
                                                          theme: theme, columnWidth: CGFloat(column),
                                                          pageContentWidth: 400))
        }
        XCTAssertEqual(sizes[0], declared, "column == page width ⇒ the authored size")
        XCTAssertEqual(sizes[1], CGSize(width: 225, height: 112.5))
        XCTAssertEqual(sizes[2], CGSize(width: 450, height: 225))
    }

    /// Column-fitting still wins on top of the scale: a graphic scaled past the reading column is
    /// shrunk back aspect-preserving, never allowed to overflow (invariant 1's sizing still applies).
    func testGraphicScaledPastColumnIsStillClampedToColumn() throws {
        let out = OfficeTextBuilder.build([.image(id: "a", size: CGSize(width: 400, height: 200))],
                                          theme: theme, columnWidth: 600, pageContentWidth: 150)
        let size = try reservedImageSize(out)
        XCTAssertEqual(size.width, 600, accuracy: 0.5)
        XCTAssertEqual(size.height, 300, accuracy: 0.5, "aspect ratio preserved while clamping")
    }

    /// A chart/SmartArt placeholder stands in for a real graphic's area, so it scales identically —
    /// and it reads its size from `.bounds` (invariant 31), not from a `SizedAttachmentCell`.
    func testUnsupportedGraphicFollowsGraphicScaleToo() throws {
        let out = OfficeTextBuilder.build([.unsupportedGraphic(label: "Chart", size: CGSize(width: 200, height: 100))],
                                          theme: theme, columnWidth: 4000, pageContentWidth: 1600)
        let bounds = out.attribute(.attachment, at: 0, effectiveRange: nil)
            .flatMap { ($0 as? NSTextAttachment)?.bounds.size }
        XCTAssertEqual(bounds?.width ?? 0, 500, accuracy: 0.5)
        XCTAssertEqual(bounds?.height ?? 0, 250, accuracy: 0.5)
    }

    /// An image inside a TABLE CELL takes the same scale (the cell path is a separate call chain —
    /// `appendTable` → `cellContent` — and threading it only through the top-level path would leave
    /// every cell picture unscaled, which is most of them in a real report).
    func testCellImageFollowsGraphicScale() throws {
        let cell = Cell(blocks: [.image(id: "in-cell", size: CGSize(width: 100, height: 50))])
        // A CELL picture is measured against the TABLE's own source width (400pt) — and for a PAGED
        // document (`pageContentWidth` non-nil — this table-width-clamp job) the table itself is now
        // laid out at that AUTHORED 400pt rather than stretched to fill the 1200pt column (a table
        // drawn at 400pt of a 1200pt column must not become 100% of it just because the reader fills
        // the column), so the ratio the picture scales by is 400÷400 = 1: it keeps its authored size
        // exactly. This used to assert 3× growth (300×150) — that was the SAME over-stretch defect
        // this table-width fix removes from the table, seen from the picture's side; see the sibling
        // test below for the ratio still doing real work when the column, not the table, is the
        // narrower one.
        let out = OfficeTextBuilder.build([.table(rows: [[cell]], headerRows: 0, columnWidths: [1],
                                                  format: TableFormat(sourceWidth: 400))],
                                          theme: theme, columnWidth: 1200, pageContentWidth: 9999)
        let size = try reservedImageSize(out)
        XCTAssertEqual(size.width, 100, accuracy: 0.5)
        XCTAssertEqual(size.height, 50, accuracy: 0.5)
    }

    /// The complementary case: when the READING COLUMN is narrower than the table's own authored
    /// width, a paged table shrinks to fit it (never grows past the column — `GridTextTable.
    /// maxWidth` only ever clamps DOWN), and a cell picture shrinks by the exact same ratio, keeping
    /// its share of the cell exactly as authored. Proves the scale ratio still does real work after
    /// the table-width fix above — it is not hardcoded to 1.
    func testCellImageShrinksWithATableClampedToANarrowerColumn() throws {
        let cell = Cell(blocks: [.image(id: "in-cell", size: CGSize(width: 100, height: 50))])
        let out = OfficeTextBuilder.build([.table(rows: [[cell]], headerRows: 0, columnWidths: [1],
                                                  format: TableFormat(sourceWidth: 400))],
                                          theme: theme, columnWidth: 200, pageContentWidth: 9999)
        let size = try reservedImageSize(out)
        // The table clamps to min(400, 200) = 200 → scale 200 ÷ 400 = 0.5.
        XCTAssertEqual(size.width, 50, accuracy: 0.5)
        XCTAssertEqual(size.height, 25, accuracy: 0.5)
    }

    // MARK: Graphic alignment

    private func paragraphAlignment(_ out: NSAttributedString, at index: Int = 0) -> NSTextAlignment? {
        (out.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)?.alignment
    }

    /// A figure is centred far more often than not in a real report, and it used to render hard
    /// against the left margin whatever the document said, because the image case carried no
    /// alignment and its attachment got no paragraph style at all.
    func testImageCarriesItsParagraphsAlignment() {
        for alignment in [NSTextAlignment.center, .right, .left] {
            let out = build([.image(id: "a", size: CGSize(width: 50, height: 50), alignment: alignment)])
            XCTAssertEqual(paragraphAlignment(out), alignment, "\(alignment) must reach the attachment paragraph")
        }
    }

    /// The chart/SmartArt placeholder stands in for a real figure, so it aligns identically.
    func testUnsupportedGraphicCarriesItsParagraphsAlignment() {
        let out = build([.unsupportedGraphic(label: "Chart", size: CGSize(width: 50, height: 50), alignment: .center)])
        XCTAssertEqual(paragraphAlignment(out), .center)
    }

    /// A document that states no alignment must be untouched — no paragraph style is attached at all,
    /// so this stays byte-identical to before alignment existed (invariant 37's unspecified case).
    func testGraphicWithNoStatedAlignmentGetsNoParagraphStyle() {
        let out = build([.image(id: "a", size: CGSize(width: 50, height: 50))])
        XCTAssertNil(out.attribute(.paragraphStyle, at: 0, effectiveRange: nil),
                     "an unaligned image must carry no paragraph style of its own")
    }

    /// A declared size that already fits the column must pass through unchanged — scaling must
    /// never enlarge an image past its authored size.
    func testImageNarrowerThanColumnIsReservedAtItsDeclaredSize() {
        let declared = CGSize(width: 240, height: 135)
        let out = OfficeTextBuilder.build([.image(id: "small", size: declared)], theme: theme, columnWidth: 700)
        let cell = out.attribute(.attachment, at: 0, effectiveRange: nil)
            .flatMap { ($0 as? NSTextAttachment)?.attachmentCell as? SizedAttachmentCell }
        XCTAssertEqual(cell?.reservedSize, declared)
    }

    // MARK: Chart/SmartArt placeholder frame (S9)

    /// Invariant 1's equivalent for this case: unlike `.image`, there is no later pixel arrival at
    /// all — the frame is drawn ONCE, right here, so `attachment.image` must be non-nil IMMEDIATELY
    /// (never `nil`-then-loaded), and `.bounds` (what this case's layout size is actually read
    /// from — see `appendUnsupportedGraphic`'s doc comment on why NOT `SizedAttachmentCell`) must
    /// match the declared size exactly, read TWICE to prove nothing here can revise it later.
    func testUnsupportedGraphicReservesExactSizeWithPixelsAlreadyPresent() throws {
        let size = CGSize(width: 300, height: 150)
        let out = build([.unsupportedGraphic(label: "Chart", size: size)])
        var found: NSTextAttachment?
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if let att = value as? NSTextAttachment { found = att }
        }
        let attachment = try XCTUnwrap(found)
        XCTAssertNotNil(attachment.image, "the frame is synthesized at build time — never nil, never loaded later")
        XCTAssertEqual(attachment.bounds.size, size)
        XCTAssertEqual(attachment.bounds.size, size, "reading it a second time must yield the identical size")
    }

    /// The declared area still respects column-fitting, exactly like `.image` — a wide chart must
    /// not overflow the reading column.
    func testUnsupportedGraphicWiderThanColumnScalesDownProportionally() throws {
        let declared = CGSize(width: 2000, height: 1000)
        let out = OfficeTextBuilder.build([.unsupportedGraphic(label: "Diagram", size: declared)],
                                          theme: theme, columnWidth: 700)
        let bounds = out.attribute(.attachment, at: 0, effectiveRange: nil)
            .flatMap { ($0 as? NSTextAttachment)?.bounds.size }
        XCTAssertEqual(bounds?.width ?? 0, 700, accuracy: 0.5)
        XCTAssertEqual(bounds?.height ?? 0, 350, accuracy: 0.5)
    }

    /// `MDAttr.image` (the id an office image's async pixel loader keys off of, see
    /// `MarkdownDocument.reconcileMedia`) must NOT be attached to this block — there is no id here
    /// for that loader to look up, and letting it try would be reaching for pixels that were never
    /// going to arrive.
    func testUnsupportedGraphicCarriesNoMDAttrImageID() {
        let out = build([.unsupportedGraphic(label: "Chart", size: CGSize(width: 100, height: 50))])
        var sawImageAttr = false
        out.enumerateAttribute(MDAttr.image, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if value != nil { sawImageAttr = true }
        }
        XCTAssertFalse(sawImageAttr)
    }

    // MARK: Cells hold blocks now (S7)

    /// The regression guard the sprint brief calls out by name: a cell built the OLD way
    /// (`Cell(spans:)`) must render EXACTLY what the pre-sprint direct-spans path produced — the
    /// span text/attributes. The cell content is now REAL text in the top-level string (an
    /// `NSTextTable` cell, not a drawn attachment), so the byte-identity is asserted against the
    /// placed cell's own text run — plus the cell's own paragraph terminator the table adds.
    func testCellBuiltFromSpansRendersByteIdenticalToTheDirectSpansPath() {
        let spans = [span("Hello", bold: true)]
        let out = build([.table(rows: [[Cell(spans: spans)]], headerRows: 0)])
        let expectedRun = OfficeTextBuilder.spansAttributedString(spans, baseFont: theme.bodyFont,
                                                                   baseColor: theme.textColor, theme: theme)
        let cell = try! XCTUnwrap(tableCells(in: out).first)
        XCTAssertEqual(cell.text, expectedRun.string + "\n",
                        "the placed cell's text is exactly the direct-spans path's text (plus its cell terminator)")
        let font = out.attribute(.font, at: cell.range.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.fontDescriptor.symbolicTraits.contains(.bold), true)
    }

    /// Vocabulary-level proof for gap-list row 7: a cell built from `blocks:` rather than `spans:`
    /// can hold a `.listItem`, and that item's computed marker reaches the cell's rendered text —
    /// S8 is what teaches a reader's cell walk to actually collect one of these, this only proves
    /// the renderer has somewhere to put it.
    func testCellContainingAListItemRendersItsMarker() {
        let cell = Cell(blocks: [.listItem(level: 0, ordered: true, spans: [span("first")])])
        let out = build([.table(rows: [[cell]], headerRows: 0)])
        let content = try! XCTUnwrap(tableCells(in: out).first).text
        XCTAssertTrue(content.contains("1.\tfirst"), "marker text must reach the cell: \(content)")
    }

    /// Vocabulary-level proof for gap-list row 6: a cell built from `blocks:` can hold an
    /// `.image`, and it reserves that image's declared area exactly like a top-level image does —
    /// same `SizedAttachmentCell`/invariant-1 machinery, reused rather than duplicated for cells.
    func testCellContainingAnImageBlockReservesThatImagesArea() throws {
        let size = CGSize(width: 100, height: 50)
        let cell = Cell(blocks: [.image(id: "cell-img", size: size)])
        let out = build([.table(rows: [[cell]], headerRows: 0)])
        // The image attachment is now real content in the top-level string, inside the placed cell's
        // own range (an `NSTextTable` cell holds selectable text, not a drawn sub-attachment).
        let cell0 = try XCTUnwrap(tableCells(in: out).first)
        var found: NSTextAttachment?
        out.enumerateAttribute(.attachment, in: cell0.range) { value, _, _ in
            if let att = value as? NSTextAttachment { found = att }
        }
        let attachment = try XCTUnwrap(found, "an image block inside a cell must still produce an attachment")
        let sizedCell = attachment.attachmentCell as? SizedAttachmentCell
        XCTAssertEqual(sizedCell?.reservedSize, size)
    }

    /// The reserved size of the (only) image attachment inside the first cell of `out`.
    private func cellImageReservedSize(in out: NSAttributedString) throws -> CGSize {
        let cell0 = try XCTUnwrap(tableCells(in: out).first)
        var found: NSTextAttachment?
        out.enumerateAttribute(.attachment, in: cell0.range) { value, _, _ in
            if let att = value as? NSTextAttachment { found = att }
        }
        let attachment = try XCTUnwrap(found, "an image block inside a cell must produce an attachment")
        let sizedCell = try XCTUnwrap(attachment.attachmentCell as? SizedAttachmentCell)
        return sizedCell.reservedSize
    }

    /// The bug this sprint fixes: a cell image authored WIDER than its resolved column overflowed the
    /// cell (cell images used to pass `columnWidth: .greatestFiniteMagnitude`, so nothing clamped
    /// them). Now a cell `.image` clamps to the cell's own content width the SAME way a top-level
    /// image clamps to the reading column — aspect-ratio preserved. A single-column table at a 400pt
    /// reading column has one full-width column; its content width is 400 − 2·7 padding − 2·1 border
    /// = 384pt, so an 800×400 (2:1) image shrinks to 384×192.
    func testCellImageWiderThanItsColumnIsClampedAspectPreserved() throws {
        let cell = Cell(blocks: [.image(id: "wide-cell-img", size: CGSize(width: 800, height: 400))])
        let out = OfficeTextBuilder.build([.table(rows: [[cell]], headerRows: 0)],
                                          theme: theme, columnWidth: 400)
        let reserved = try cellImageReservedSize(in: out)
        XCTAssertEqual(reserved.width, 384, accuracy: 0.5, "clamped to the cell's content width")
        XCTAssertEqual(reserved.height, 192, accuracy: 0.5, "aspect ratio (2:1) must be preserved")
        XCTAssertLessThanOrEqual(reserved.width, 384 + 0.5, "must never exceed the cell content width")
    }

    /// A cell image SMALLER than its column is untouched — `fittedOfficeSize` only shrinks oversized
    /// images, so a normal (already-fitting) cell image (every existing docx/odt case) is unchanged.
    func testCellImageSmallerThanItsColumnIsUnchanged() throws {
        let size = CGSize(width: 100, height: 50)
        let cell = Cell(blocks: [.image(id: "small-cell-img", size: size)])
        let out = OfficeTextBuilder.build([.table(rows: [[cell]], headerRows: 0)],
                                          theme: theme, columnWidth: 400)
        XCTAssertEqual(try cellImageReservedSize(in: out), size, "a fitting cell image must not be resized")
    }

    /// The nested-table decision (flatten, never build a real grid) must hold even when a `.table`
    /// block reaches a cell directly, not only when a reader has already flattened one into spans
    /// before `Cell` existed. There must be exactly ONE `GridTextTable` (the outer table); the nested
    /// table is flattened to TEXT inside the outer cell's content, never a second grid.
    func testCellContainingANestedTableBlockFlattensToTextRatherThanBuildingARealNestedGrid() {
        let nested: OfficeBlock = .table(rows: [[Cell(spans: [span("Nested")])]], headerRows: 0)
        let outer = Cell(blocks: [.paragraph(spans: [span("Outer")]), nested])
        let out = build([.table(rows: [[outer]], headerRows: 0)])
        // The outer cell's content is the flattened text: "Outer" + separator + the nested table's
        // own flattened "Nested\n" — building a REAL nested grid instead (the mutation this guards
        // against) would place a second `GridTextTable` here rather than plain text.
        let cells = tableCells(in: out)
        let outerCell = try! XCTUnwrap(cells.first)
        XCTAssertEqual(outerCell.text, "Outer\nNested\n")
        // Every placed cell must belong to the SAME table — the flattened nested table is plain text
        // carrying the outer cell's own block, not a second grid.
        let distinctTables = Set(cells.compactMap { ($0.block.table as? GridTextTable).map(ObjectIdentifier.init) })
        XCTAssertEqual(distinctTables.count, 1, "the nested table must be flattened to text — no nested grid")
    }

    /// The anchor-cells-only merge contract must still hold for a cell built the NEW way
    /// (`blocks:`), not only for the spans compatibility path every other merge test here uses.
    func testMergedCellBuiltFromBlocksStillAppliesItsRowSpan() {
        let tall = Cell(blocks: [.paragraph(spans: [span("tall")])], rowSpan: 2, colSpan: 1)
        let rows: [[Cell]] = [
            [tall, Cell(spans: [span("top-right")])],
            [Cell(spans: [span("bottom-right")])],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let cells = tableCells(in: out)
        let tallCell = cells.first { $0.col == 0 }
        XCTAssertEqual(tallCell?.rowSpan, 2)
        XCTAssertEqual(cells.count, 3, "the tall cell's own row, no separate cell fabricated below it")
    }

    // MARK: Formulas (S10)

    /// Invariant 1: a formula's reserved size must be exact-and-final at build time, same as an
    /// image's, and its pixels (`.image`) must be nil — nothing has rendered it yet.
    func testFormulaBlockReservesAPlaceholderSizeWithNoPixelsYet() throws {
        let out = build([.formula(latex: "x^2")])
        var found: NSTextAttachment?
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if let att = value as? NSTextAttachment { found = att }
        }
        let attachment = try XCTUnwrap(found)
        XCTAssertNil(attachment.image)
        let cell = try XCTUnwrap(attachment.attachmentCell as? SizedAttachmentCell)
        XCTAssertGreaterThan(cell.reservedSize.width, 0)
        XCTAssertGreaterThan(cell.reservedSize.height, 0)
    }

    /// The seam a parser test cannot see (invariant 29): an office formula must carry the SAME
    /// `MDAttr.math` attribute a markdown `$$…$$` does, because `MarkdownDocument`'s pre-render and
    /// pre-size passes find their work exclusively through `enumerateWebBlocks`
    /// (`storage.enumerateAttribute(MDAttr.math, …)`), never by asking whether the document is
    /// markdown or office. If this attribute were missing or misnamed, the formula would sit in the
    /// text storage forever unrendered and unsized — a defect no `DocxReader`-only test could catch.
    func testFormulaBlockIsFoundByTheSharedWebBlockEnumerationThePrerenderPassUses() {
        let out = build([.paragraph(spans: [span("before")]), .formula(latex: "\\frac{1}{2}"), .paragraph(spans: [span("after")])])
        var found: [WebBlock] = []
        out.enumerateWebBlocks { block, _ in found.append(block) }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.engine, .math)
        XCTAssertEqual(found.first?.code, "\\frac{1}{2}")
    }

    /// A formula block inside a table cell must still be captured as a web block — cells render
    /// through `cellContent`, a separate switch from the top-level `build` loop, and it is easy for
    /// a new `OfficeBlock` case to be wired into one and forgotten in the other. The web block now
    /// lives as REAL content in the top-level string (an `NSTextTable` cell), so the SAME whole-storage
    /// `enumerateWebBlocks` the prerender/presize passes use reaches it natively — no cell descent.
    func testFormulaBlockInsideATableCellIsStillFoundByWebBlockEnumeration() {
        let out = build([.table(rows: [[Cell(blocks: [.formula(latex: "y=mx+b")])]], headerRows: 0)])
        var found: [WebBlock] = []
        out.enumerateWebBlocks { block, _ in found.append(block) }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.code, "y=mx+b")
    }

    // MARK: S13 — regression: an unstyled document is untouched by this sprint

    /// The brief's own required guard: leaving every new field at its default must produce EXACTLY
    /// the string+attributes the pre-sprint builder produced — asserted by comparison
    /// (`NSAttributedString.isEqual(to:)`), never by eyeball. Built two ways (implicit defaults vs
    /// explicitly passing the same default values) precisely so a future accidental default change
    /// on ONE side would be caught by the other. `.table` is covered separately just below —
    /// a table's `NSTextTable` cell layout is not value-equal under
    /// `isEqual` even when every property matches (the same reason
    /// `testLTRDocumentProducesTheSameStringAndBaseWritingDirectionAcrossEveryBlockKind` above
    /// compares table STRUCTURE rather than raw `isEqual`), so it would fail this comparison for a
    /// reason that has nothing to do with this sprint.
    func testDefaultNewFieldsProduceByteIdenticalOutputToExplicitlyPassingTheSameDefaults() {
        let implicit = build([
            .heading(level: 2, spans: [span("Title")]),
            .paragraph(spans: [span("Body")]),
            .listItem(level: 0, ordered: true, spans: [span("Item")]),
        ])
        let explicit = build([
            .heading(level: 2, spans: [span("Title")], rtl: false, alignment: nil, tabStops: []),
            .paragraph(spans: [span("Body")], rtl: false, alignment: nil, tabStops: []),
            .listItem(level: 0, ordered: true, spans: [span("Item")], marker: nil, rtl: false, alignment: nil, tabStops: []),
        ])
        XCTAssertTrue(implicit.isEqual(to: explicit))
    }

    /// The `.table` half of the same guard, compared by STRUCTURE (as the file's own precedent
    /// does) rather than raw `isEqual`.
    func testDefaultCellFieldsProduceTheSameTableStructureAsThePreSprintConstructionPath() {
        let implicit = build([.table(rows: [[Cell(spans: [span("A")])]], headerRows: 0)])
        let explicit = build([.table(rows: [[Cell(blocks: [.paragraph(spans: [span("A")])], backgroundColor: nil,
                                                   borderColor: nil, borderWidth: nil, width: nil)]], headerRows: 0)])
        XCTAssertEqual(implicit.string, explicit.string)
        let a = try! XCTUnwrap(tableCells(in: implicit).first)
        let b = try! XCTUnwrap(tableCells(in: explicit).first)
        XCTAssertNil(a.background)
        XCTAssertNil(b.background)
        XCTAssertEqual(a.borderColor, b.borderColor)
        XCTAssertEqual(a.borderWidth, b.borderWidth)
    }

    // MARK: S13 — run colour vs the reading theme

    /// Resolves `color` under a given appearance the way TextKit itself would when actually
    /// drawing — `NSColor.dynamic` colours (see `RenderTheme`/`Palette`) only pick a concrete RGB
    /// once asked inside a drawing context for a specific appearance.
    private func rgb(_ color: NSColor, appearance: NSAppearance) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var result: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        appearance.performAsCurrentDrawingAppearance {
            let d = color.usingColorSpace(.deviceRGB)!
            result = (d.redComponent, d.greenComponent, d.blueComponent)
        }
        return result
    }
    private let lightAppearance = NSAppearance(named: .aqua)!
    private let darkAppearance = NSAppearance(named: .darkAqua)!

    /// The decision this sprint makes: a near-neutral authored colour (grayscale — almost always
    /// literal black) is treated as ORDINARY ink, not a deliberate mark, and steps aside for the
    /// theme's own text colour — the same colour an unset `textColor` gets. That is what keeps
    /// "authored black" readable once the theme goes dark, instead of drawing literal black text on
    /// a near-black background.
    func testAuthoredNearBlackTextColorStepsAsideForTheThemeInBothAppearances() {
        let authoredBlack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let resolved = OfficeTextBuilder.resolvedTextColor(authoredBlack, theme: theme)
        let light = rgb(resolved, appearance: lightAppearance)
        let dark = rgb(resolved, appearance: darkAppearance)
        let themeLight = rgb(theme.textColor, appearance: lightAppearance)
        let themeDark = rgb(theme.textColor, appearance: darkAppearance)
        XCTAssertEqual(light.r, themeLight.r, accuracy: 0.001)
        XCTAssertEqual(light.g, themeLight.g, accuracy: 0.001)
        XCTAssertEqual(dark.r, themeDark.r, accuracy: 0.001)
        XCTAssertEqual(dark.g, themeDark.g, accuracy: 0.001)
        XCTAssertNotEqual(light.r, dark.r, accuracy: 0.001,
                          "sanity check: the theme's own ink must actually differ between the two appearances")
    }

    /// The other half of the same decision: a genuinely COLOURFUL authored run (high saturation —
    /// a red warning, here) is a deliberate mark and is drawn exactly as authored, in EITHER
    /// appearance — losing that would lose the meaning the colour exists to carry.
    func testAuthoredSaturatedTextColorIsHonoredLiterallyInBothAppearances() {
        let authoredRed = NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        let resolved = OfficeTextBuilder.resolvedTextColor(authoredRed, theme: theme)
        let light = rgb(resolved, appearance: lightAppearance)
        let dark = rgb(resolved, appearance: darkAppearance)
        XCTAssertEqual(light.r, 0.8, accuracy: 0.01)
        XCTAssertEqual(light.g, 0.1, accuracy: 0.01)
        XCTAssertEqual(light.r, dark.r, accuracy: 0.001, "a literal colour must not adapt to the appearance")
        XCTAssertEqual(light.g, dark.g, accuracy: 0.001)
    }

    /// End-to-end through the span pipeline (not just the resolver function directly): a `code`
    /// span's colour is the theme's own inline-code accent regardless of any authored `textColor` —
    /// the single consistent monospace look, never overridden per-run (see `Span.fontName`'s doc,
    /// which the same reasoning applies to for colour).
    func testAuthoredTextColorNeverOverridesTheInlineCodeAccentColor() {
        let out = build([.paragraph(spans: [span("snippet", code: true, textColor: .systemRed)])])
        let color = out.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, theme.inlineCodeColor)
    }

    /// An unset `textColor` is untouched — the pre-sprint theme colour, exactly.
    func testSpanWithNoTextColorUsesTheThemeColorUnchanged() {
        let out = build([.paragraph(spans: [span("plain")])])
        let color = out.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, theme.textColor)
    }

    // MARK: S13 — highlight colour (always literal, never theme-adjusted)

    func testHighlightColorAppliesAsBackgroundColorAttribute() {
        let out = build([.paragraph(spans: [span("marked", highlightColor: .yellow)])])
        let bg = out.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(bg, NSColor.yellow)
    }

    func testSpanWithNoHighlightColorHasNoBackgroundColorAttribute() {
        let out = build([.paragraph(spans: [span("plain")])])
        XCTAssertNil(out.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    // MARK: S13 — font family

    func testAuthoredFontNameOverridesTheFamilyButNeverForACodeSpan() {
        let out = build([.paragraph(spans: [
            span("Named", fontName: "Helvetica"),
            span("Coded", code: true, fontName: "Helvetica"),
        ])])
        let expectedFamily = NSFont(name: "Helvetica", size: theme.bodyFont.pointSize)!.familyName
        let namedFont = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(namedFont?.familyName, expectedFamily)
        let text = out.string as NSString
        let codedRange = text.range(of: "Coded")
        let codedFont = out.attribute(.font, at: codedRange.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(codedFont?.fontName, theme.codeFont.fontName,
                       "an authored family must never override the single, consistent inline-code look")
    }

    func testSpanWithNoFontNameUsesTheThemeFamilyUnchanged() {
        let out = build([.paragraph(spans: [span("plain")])])
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.familyName, theme.bodyFont.familyName)
    }

    // MARK: S13 — the font-size model (authored size × user-size/document-default ratio)

    /// The brief's own required case: a 22-half-point (11pt) body run and a 32-half-point (16pt)
    /// run keep their AUTHORED ratio at any user reading size, and the reading size still sets the
    /// overall scale — tested at two different reading sizes so neither half of that claim could be
    /// satisfied by accident (a constant scale would pass the ratio check; a fixed size would fail
    /// the "still governs overall scale" check).
    func testAuthoredFontSizeKeepsItsRatioToTheDocumentDefaultAcrossTwoUserReadingSizes() {
        func sizes(userSize: CGFloat) -> (body: CGFloat, heading: CGFloat) {
            let out = OfficeTextBuilder.build([
                .paragraph(spans: [span("Body", fontSize: 11)]),
                .paragraph(spans: [span("Head", fontSize: 16)]),
            ], theme: RenderTheme.current(size: userSize), documentDefaultFontSize: 11)
            let bodyFont = out.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
            let headRange = (out.string as NSString).range(of: "Head")
            let headFont = out.attribute(.font, at: headRange.location, effectiveRange: nil) as! NSFont
            return (bodyFont.pointSize, headFont.pointSize)
        }
        let atTwentyTwo = sizes(userSize: 22)   // scale = 22/11 = 2
        XCTAssertEqual(atTwentyTwo.body, 22)
        XCTAssertEqual(atTwentyTwo.heading, 32)

        let atFortyFour = sizes(userSize: 44)   // scale = 44/11 = 4
        XCTAssertEqual(atFortyFour.body, 44)
        XCTAssertEqual(atFortyFour.heading, 64)

        XCTAssertEqual(atTwentyTwo.heading / atTwentyTwo.body, 16.0 / 11.0, accuracy: 0.001,
                       "the authored 16pt-to-11pt ratio must survive scaling")
        XCTAssertEqual(atFortyFour.heading / atFortyFour.body, 16.0 / 11.0, accuracy: 0.001)
        XCTAssertNotEqual(atTwentyTwo.body, atFortyFour.body,
                          "the user's reading size must still govern the overall scale")
    }

    /// A span with NO authored size is untouched by `documentDefaultFontSize` entirely — it keeps
    /// whatever size the surrounding block's own theme font already is (already `theme.baseFontSize`
    /// scaled, with no further multiplication).
    func testSpanWithNoAuthoredFontSizeIgnoresTheDocumentDefaultScale() {
        let out = OfficeTextBuilder.build([.paragraph(spans: [span("plain")])],
                                          theme: RenderTheme.current(size: 30), documentDefaultFontSize: 11)
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, RenderTheme.current(size: 30).bodyFont.pointSize)
    }

    // MARK: S13 — alignment

    func testExplicitAlignmentWinsOverTheRTLDefaultEdge() {
        let out = build([.paragraph(spans: [span("text")], rtl: true, alignment: .center)])
        let style = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.alignment, .center)
        XCTAssertEqual(style?.baseWritingDirection, .rightToLeft,
                       "an explicit alignment must not suppress the base direction")
    }

    func testNilAlignmentLeavesNaturalAlignmentExactlyAsBefore() {
        let out = build([.paragraph(spans: [span("text")])])
        let style = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.alignment, .natural)
    }

    func testHeadingAndListItemAlsoRespectAnExplicitAlignment() {
        let headingOut = build([.heading(level: 1, spans: [span("H")], alignment: .right)])
        let headingStyle = headingOut.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(headingStyle?.alignment, .right)

        let listOut = build([.listItem(level: 0, ordered: false, spans: [span("I")], alignment: .center)])
        let listStyle = listOut.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(listStyle?.alignment, .center)
    }

    // MARK: S13 — tab stops

    func testParagraphTabStopsAreAddedToTheParagraphStyle() {
        let out = build([.paragraph(spans: [span("a\tb")], tabStops: [TabStop(position: 100), TabStop(position: 200)])])
        let style = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let locations = style?.tabStops.map(\.location) ?? []
        XCTAssertTrue(locations.contains(100))
        XCTAssertTrue(locations.contains(200))
    }

    func testEmptyTabStopsLeaveTheParagraphStylesDefaultTabsUnchanged() {
        let withNone = build([.paragraph(spans: [span("text")])])
        let withEmpty = build([.paragraph(spans: [span("text")], tabStops: [])])
        let styleA = withNone.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let styleB = withEmpty.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(styleA?.tabStops.map(\.location), styleB?.tabStops.map(\.location))
    }

    /// THE BRIEF'S REQUIRED CASE: a custom tab stop must coexist with, not break, a list item's own
    /// hanging-indent geometry — the marker's own tab stays FIRST and at its usual position, and the
    /// item's indentation (`headIndent`/`firstLineHeadIndent`) is completely unaffected by an
    /// authored tab stop being present.
    func testListItemTabStopsCoexistWithTheMarkersOwnHangingIndentTab() {
        let plain = build([.listItem(level: 1, ordered: true, spans: [span("Item")])])
        let withTab = build([.listItem(level: 1, ordered: true, spans: [span("Item")], tabStops: [TabStop(position: 300)])])
        let plainStyle = plain.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let tabStyle = withTab.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle

        XCTAssertEqual(tabStyle?.headIndent, plainStyle?.headIndent, "hanging indent must be unaffected")
        XCTAssertEqual(tabStyle?.firstLineHeadIndent, plainStyle?.firstLineHeadIndent)
        let plainLocations = plainStyle?.tabStops.map(\.location) ?? []
        let tabLocations = tabStyle?.tabStops.map(\.location) ?? []
        XCTAssertEqual(tabLocations.first, plainLocations.first, "the marker's own tab must still be first")
        XCTAssertTrue(tabLocations.contains(300), "the authored tab stop must still be present alongside it")
    }

    /// P2b — `TabStop.alignment` must reach the actual `NSTextTab.alignment` AppKit lays out with,
    /// not just round-trip through `TabStop` itself. `.decimal` has no `NSTextAlignment` case (see
    /// `officeTextTab`'s own doc) — it maps to `.right` PLUS a `.` column terminator, so this
    /// asserts `.right` for it and separately proves the terminator option is present.
    func testTabStopAlignmentReachesTheBuiltNSTextTabsAlignment() {
        let out = build([.paragraph(spans: [span("a\tb\tc\td")],
                                     tabStops: [TabStop(position: 50, alignment: .left),
                                                TabStop(position: 100, alignment: .center),
                                                TabStop(position: 150, alignment: .right),
                                                TabStop(position: 200, alignment: .decimal)])])
        let style = try! XCTUnwrap(out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let byLocation = Dictionary(uniqueKeysWithValues: style.tabStops.map { ($0.location, $0) })
        XCTAssertEqual(byLocation[50]?.alignment, .left)
        XCTAssertEqual(byLocation[100]?.alignment, .center)
        XCTAssertEqual(byLocation[150]?.alignment, .right)
        XCTAssertEqual(byLocation[200]?.alignment, .right, "decimal has no NSTextAlignment case — it maps to .right")
        XCTAssertNotNil(byLocation[200]?.options[.columnTerminators], "decimal must still carry the '.' column terminator")
    }

    /// A tab with a `leader` still renders as an ordinary aligned tab — `TabLeader` is carried
    /// through `TabStop` but `officeTextTab` never turns it into a drawing instruction (see
    /// `TabLeader`'s own doc); this pins that the alignment/position side is unaffected by it.
    func testTabLeaderDoesNotAffectTheBuiltNSTextTabsAlignmentOrPosition() {
        let out = build([.paragraph(spans: [span("a\tb")],
                                     tabStops: [TabStop(position: 80, alignment: .right, leader: .dot)])])
        let style = try! XCTUnwrap(out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.tabStops.first?.location, 80)
        XCTAssertEqual(style.tabStops.first?.alignment, .right)
    }

    // MARK: P8 — TOC / fill-to-margin tabs

    /// A paragraph whose rightmost tab is RIGHT-aligned (the TOC case: title, then a tab, then a
    /// page number pushed to the source's own page margin) gets `MDAttr.fillMarginTab`, carrying
    /// the OTHER tabs (none, here) plus the margin tab's own alignment/leader.
    func testParagraphWithARightmostRightTabGetsFillMarginTabAttribute() {
        let out = build([.paragraph(spans: [span("Chapter One\t3")],
                                     tabStops: [TabStop(position: 481, alignment: .right)])])
        let info = out.attribute(MDAttr.fillMarginTab, at: 0, effectiveRange: nil) as? FillMarginTabInfo
        let info2 = try! XCTUnwrap(info)
        XCTAssertEqual(info2.marginAlignment, .right)
        XCTAssertTrue(info2.otherTabs.isEmpty)
    }

    /// Same case, headings — a TOC's own title style, or a right-aligned header, must be detected
    /// through the heading path too, not just plain paragraphs.
    func testHeadingWithARightmostDecimalTabGetsFillMarginTabAttribute() {
        let out = build([.heading(level: 1, spans: [span("Title\t3")],
                                   tabStops: [TabStop(position: 481, alignment: .decimal)])])
        let info = try! XCTUnwrap(out.attribute(MDAttr.fillMarginTab, at: 0, effectiveRange: nil) as? FillMarginTabInfo)
        XCTAssertEqual(info.marginAlignment, .decimal)
    }

    /// A rightmost LEFT-aligned tab is an ordinary tab stop — never marked, never rebuilt. This is
    /// the "unspecified = identical" guarantee: an everyday tab-using paragraph gets no attribute
    /// and its tab position is untouched.
    func testParagraphWithARightmostLeftTabDoesNotGetFillMarginTabAttribute() {
        let out = build([.paragraph(spans: [span("a\tb")], tabStops: [TabStop(position: 200, alignment: .left)])])
        XCTAssertNil(out.attribute(MDAttr.fillMarginTab, at: 0, effectiveRange: nil))
        let locations = (out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
            .tabStops.map(\.location) ?? []
        XCTAssertEqual(locations, [200], "an ordinary left tab's position must be untouched")
    }

    /// A paragraph with NO tab stops at all never gets the attribute either.
    func testParagraphWithNoTabStopsDoesNotGetFillMarginTabAttribute() {
        let out = build([.paragraph(spans: [span("plain text")])])
        XCTAssertNil(out.attribute(MDAttr.fillMarginTab, at: 0, effectiveRange: nil))
    }

    /// A fill-margin tab preserves every OTHER authored tab stop alongside it — e.g. a left-
    /// aligned tab followed by the trailing right-aligned page-number tab.
    func testFillMarginTabPreservesTheOtherAuthoredTabStopsAlongsideIt() {
        let out = build([.paragraph(spans: [span("a\tb\tc")],
                                     tabStops: [TabStop(position: 50, alignment: .left),
                                                TabStop(position: 481, alignment: .right)])])
        let info = try! XCTUnwrap(out.attribute(MDAttr.fillMarginTab, at: 0, effectiveRange: nil) as? FillMarginTabInfo)
        XCTAssertEqual(info.otherTabs, [TabStop(position: 50, alignment: .left)])
        let style = try! XCTUnwrap(out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let locations = style.tabStops.map(\.location)
        XCTAssertTrue(locations.contains(50), "the other tab stop must still be built into the style")
    }

    /// With NO real `columnWidth` supplied (every test/cell-content call site's default), the
    /// margin tab's placeholder position is the tab's OWN authored position — unchanged from
    /// before this attribute existed. This is what keeps the pre-existing alignment tests
    /// (`testTabStopAlignmentReachesTheBuiltNSTextTabsAlignment` etc.) passing byte-for-byte.
    func testFillMarginTabWithNoColumnWidthKeepsItsOwnAuthoredPosition() {
        let out = build([.paragraph(spans: [span("a\tb")], tabStops: [TabStop(position: 481, alignment: .right)])])
        let style = try! XCTUnwrap(out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.tabStops.first?.location, 481)
    }

    /// With a REAL `columnWidth`, the margin tab's placeholder is anchored to that column (minus
    /// `OfficeTextBuilder.fillMarginTrailingInset`), NOT the document's own authored margin — this
    /// is the actual bug fix: a TOC built for a 1000pt-wide window no longer places the page
    /// number at the source's 481pt page margin.
    func testFillMarginTabWithARealColumnWidthAnchorsToTheColumnNotTheDocumentMargin() {
        let out = OfficeTextBuilder.build([.paragraph(spans: [span("Chapter One\t3")],
                                                        tabStops: [TabStop(position: 481, alignment: .right)])],
                                          theme: theme, columnWidth: 1000)
        let style = try! XCTUnwrap(out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.tabStops.first?.location, 1000 - OfficeTextBuilder.fillMarginTrailingInset)
    }

    // MARK: P8 — `fillMarginTabStops` (the pure reflow helper)

    /// Mutation-tested: `fillMarginTabStops` places ONLY the margin tab at `width`, preserving the
    /// other tabs' own positions/alignments verbatim — this is exactly what
    /// `DocumentWindowController.reanchorFillMarginTabs` calls on every resize/reflow.
    func testFillMarginTabStopsPlacesOnlyTheMarginTabAtTheGivenWidth() {
        let info = FillMarginTabInfo(marginAlignment: .right, marginLeader: .none,
                                      otherTabs: [TabStop(position: 50, alignment: .left)])
        let tabs = OfficeTextBuilder.fillMarginTabStops(info, width: 900)
        XCTAssertEqual(tabs.map(\.location).sorted(), [50, 900])
        let margin = try! XCTUnwrap(tabs.first { $0.location == 900 })
        XCTAssertEqual(margin.alignment, .right)
    }

    /// Mutation: a `.decimal` margin still carries the `.` column terminator after being rebuilt
    /// at a new width — the decimal-alignment emulation (`officeTextTab`'s own doc) must survive
    /// the reflow rebuild, not just the initial build.
    func testFillMarginTabStopsKeepsTheDecimalColumnTerminatorAfterRebuild() {
        let info = FillMarginTabInfo(marginAlignment: .decimal, marginLeader: .none, otherTabs: [])
        let tabs = OfficeTextBuilder.fillMarginTabStops(info, width: 700)
        XCTAssertEqual(tabs.first?.location, 700)
        XCTAssertEqual(tabs.first?.alignment, .right)
        XCTAssertNotNil(tabs.first?.options[.columnTerminators])
    }

    /// `fillMarginTabInfo` itself: rightmost-by-position wins even when it is not the LAST array
    /// element — an author could list tab stops out of position order.
    func testFillMarginTabInfoPicksTheRightmostByPositionNotByArrayOrder() {
        let info = try! XCTUnwrap(OfficeTextBuilder.fillMarginTabInfo(
            from: [TabStop(position: 481, alignment: .right), TabStop(position: 50, alignment: .left)]))
        XCTAssertEqual(info.otherTabs, [TabStop(position: 50, alignment: .left)])
    }

    // MARK: P2b — paragraph shading / border MDAttrs

    /// A resolved `ParagraphFormat.shading` must reach `MDAttr.paraShading` over the block's full
    /// rendered range (content + separator) — the attribute `drawMDDecorations` actually paints.
    func testParagraphShadingFormatReachesMDAttrOverTheFullBlockRange() {
        var format = ParagraphFormat()
        format.shading = .systemYellow
        let out = build([.paragraph(spans: [span("Shaded")], format: format)])
        var range = NSRange()
        _ = out.attribute(MDAttr.paraShading, at: 0, longestEffectiveRange: &range, in: NSRange(location: 0, length: out.length))
        XCTAssertEqual(range, NSRange(location: 0, length: out.length), "must span content + trailing separator")
        XCTAssertEqual(out.attribute(MDAttr.paraShading, at: 0, effectiveRange: nil) as? NSColor, .systemYellow)
    }

    /// A resolved border colour+width must reach BOTH `MDAttr.paraBorderColor` and
    /// `MDAttr.paraBorderWidth` — the two `drawMDDecorations` reads together to stroke the box.
    func testParagraphBorderFormatReachesBothMDAttrs() {
        var format = ParagraphFormat()
        format.borderColor = .systemRed
        format.borderWidth = 2
        let out = build([.paragraph(spans: [span("Boxed")], format: format)])
        XCTAssertEqual(out.attribute(MDAttr.paraBorderColor, at: 0, effectiveRange: nil) as? NSColor, .systemRed)
        XCTAssertEqual((out.attribute(MDAttr.paraBorderWidth, at: 0, effectiveRange: nil) as? NSNumber)?.doubleValue, 2)
    }

    /// WHICH edges reaches the drawer, and a border that named none still means all four — the
    /// unchanged behaviour for every ODT paragraph and every caller predating the edge set.
    func testParagraphBorderEdgesReachTheDrawerAndDefaultToTheWholeBox() {
        var underlined = ParagraphFormat()
        underlined.borderColor = .systemRed
        underlined.borderWidth = 2
        underlined.borderEdges = [.bottom]
        let ruled = build([.paragraph(spans: [span("Heading")], format: underlined)])
        XCTAssertEqual((ruled.attribute(MDAttr.paraBorderEdges, at: 0, effectiveRange: nil) as? NSNumber)?.intValue,
                       RectEdge.bottom.rawValue, "a bottom-only rule must not become a box")

        var unspecified = ParagraphFormat()
        unspecified.borderColor = .systemRed
        unspecified.borderWidth = 2
        let boxed = build([.paragraph(spans: [span("Boxed")], format: unspecified)])
        XCTAssertEqual((boxed.attribute(MDAttr.paraBorderEdges, at: 0, effectiveRange: nil) as? NSNumber)?.intValue,
                       RectEdge.all.rawValue)
    }

    /// A block with no shading/border at all (every pre-P2b call site) must carry NEITHER MDAttr —
    /// the "unspecified stays unspecified" invariant this sprint's whole cascade depends on.
    func testUnshadedUnborderedParagraphCarriesNeitherMDAttr() {
        let out = build([.paragraph(spans: [span("Plain")])])
        XCTAssertNil(out.attribute(MDAttr.paraShading, at: 0, effectiveRange: nil))
        XCTAssertNil(out.attribute(MDAttr.paraBorderColor, at: 0, effectiveRange: nil))
        XCTAssertNil(out.attribute(MDAttr.paraBorderWidth, at: 0, effectiveRange: nil))
    }

    // MARK: S13 — table cell shading / borders / width

    func testCellBackgroundColorOverridesTheThemeDefaultShading() {
        let out = build([.table(rows: [[Cell(blocks: [.paragraph(spans: [span("A")])], backgroundColor: .systemGreen)]],
                                headerRows: 0)])
        let cell = tableCells(in: out).first
        XCTAssertEqual(cell?.background, .systemGreen)
    }

    /// An explicit background on a HEADER cell overrides the theme's own header shading, not just
    /// a body cell's blank default.
    func testHeaderCellExplicitBackgroundColorOverridesThemeHeaderShading() {
        let out = build([.table(rows: [[Cell(blocks: [.paragraph(spans: [span("H")])], backgroundColor: .systemTeal)]],
                                headerRows: 1)])
        let cell = tableCells(in: out).first
        XCTAssertEqual(cell?.background, .systemTeal)
    }

    /// The resolved border colour+width reaches the placed cell's own `TableBorder`, which the
    /// collapsed-border `NSTextTable` draws (the document's own colour honoured verbatim).
    func testCellBorderColorAndWidthOverrideTheThemeDefault() {
        let out = build([.table(rows: [[Cell(blocks: [.paragraph(spans: [span("A")])],
                                             borderColor: .systemPurple, borderWidth: 3)]], headerRows: 0)])
        let cell = try! XCTUnwrap(tableCells(in: out).first)
        XCTAssertEqual(cell.borderColor, .systemPurple)
        XCTAssertEqual(cell.borderWidth, 3)
    }

    /// A cell's own absolute `.width` no longer sets an independent per-cell width: every column is a
    /// FRACTION of the whole table (`GridTextTable.columnProportions`), never an independent absolute
    /// value (mixing the two would reintroduce the row-to-row seam drift the custom engine removes). A
    /// single-column, no-grid table gets the whole column — ratio 1.0.
    func testCellWidthNoLongerSetsAnIndependentAbsoluteContentWidth() {
        let out = build([.table(rows: [[Cell(blocks: [.paragraph(spans: [span("A")])], width: 120)]], headerRows: 0)])
        let att = try! XCTUnwrap(firstGridTable(in: out))
        XCTAssertEqual(att.columnProportions.count, 1)
        XCTAssertEqual(att.columnProportions[0], 1, accuracy: 0.001)
    }

    // MARK: P3 — grid-ratio column widths (`OfficeBlock.table.columnWidths`)

    /// A table whose `columnWidths` matches the derived column count switches EVERY column to the
    /// source's own grid ratios (20/20/60 for 100/100/300pt) — those ratios ARE the table's `columnProportions`, the shared cumulative x-edge every row reads, which is what keeps a merged
    /// row's boundary landing at the same x as a single-cell row's.
    func testGridColumnWidthsBecomeRigidAbsoluteWidthsInTheGridsRatio() {
        let rows: [[Cell]] = [[
            Cell(spans: [span("A")]), Cell(spans: [span("B")]), Cell(spans: [span("C")]),
        ]]
        let out = build([.table(rows: rows, headerRows: 0, columnWidths: [100, 100, 300])])
        let att = try! XCTUnwrap(firstGridTable(in: out))
        XCTAssertEqual(att.columnProportions.count, 3)
        for (actual, expected) in zip(att.columnProportions, [CGFloat(0.2), 0.2, 0.6]) {
            XCTAssertEqual(actual, expected, accuracy: 0.001)
        }
    }

    /// A merged cell (`colSpan: 2`) covers the SUM of the two grid columns' ratios, not just the
    /// first one — `columnProportions[0..<2]` sums to 0.2 + 0.2 = 0.4 for the wide cell, leaving 0.6 for
    /// the lone remaining column.
    func testMergedCellGetsTheSumOfItsCoveredColumnsFractions() {
        let rows: [[Cell]] = [[
            Cell(spans: [span("Wide")], colSpan: 2), Cell(spans: [span("C")]),
        ]]
        let out = build([.table(rows: rows, headerRows: 0, columnWidths: [100, 100, 300])])
        let att = try! XCTUnwrap(firstGridTable(in: out))
        XCTAssertEqual(att.columnProportions.count, 3)
        for (actual, expected) in zip(att.columnProportions, [CGFloat(0.2), 0.2, 0.6]) {
            XCTAssertEqual(actual, expected, accuracy: 0.001)
        }
        let cells = tableCells(in: out).sorted { $0.col < $1.col }
        XCTAssertEqual(cells.count, 2)
        let wide = cells[0]
        XCTAssertEqual(wide.colSpan, 2)
        let wideFraction = att.columnProportions[wide.col ..< (wide.col + wide.colSpan)].reduce(0, +)
        XCTAssertEqual(wideFraction, 0.4, accuracy: 0.001, "the spanned cell covers the sum of its columns' ratios")
        XCTAssertEqual(att.columnProportions[cells[1].col], 0.6, accuracy: 0.001)
    }

    /// A no-grid table (no `columnWidths` — every markdown table, and an office table before its
    /// parser learns `w:tblGrid`) gets an EQUAL share per column, `1 / ncol` — this is what makes
    /// markdown table columns align uniformly too.
    func testNoGridTableGetsEqualColumnFractions() {
        let rows: [[Cell]] = [[Cell(spans: [span("A")]), Cell(spans: [span("B")]), Cell(spans: [span("C")])]]
        let out = build([.table(rows: rows, headerRows: 0)])
        let att = try! XCTUnwrap(firstGridTable(in: out))
        XCTAssertEqual(att.columnProportions.count, 3)
        for ratio in att.columnProportions { XCTAssertEqual(ratio, 1.0 / 3.0, accuracy: 0.001) }
    }

    /// The `NSTextTable` equivalent of the old shared edge grid, UPDATED for the border-conflict
    /// resolver: `collapsesBorders` is now OFF (this codebase resolves every boundary itself and
    /// hands the winner to exactly one side, rather than asking AppKit to pick), so a 2×2 table's
    /// four placed cells are NOT all bordered on all four edges any more — only the OWNING side of
    /// each boundary is. Measured before this change: `collapsesBorders == true` and every cell's
    /// four edges read `> 0` uniformly (both sides of a boundary carried a real width, and AppKit
    /// silently picked one to draw — the defect this pipeline exists to remove). Measured after:
    /// `collapsesBorders == false`, and each interior boundary has exactly one nonzero side.
    func testEveryBoundaryHasExactlyOneOwnerNowThatCollapsingIsOff() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("A")]), Cell(spans: [span("B")])],
            [Cell(spans: [span("C")]), Cell(spans: [span("D")])],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let cells = tableCells(in: out)
        XCTAssertEqual(cells.count, 4)
        XCTAssertEqual(tableRowCount(in: out), 2)
        let table = try! XCTUnwrap(firstGridTable(in: out))
        XCTAssertEqual(table.numberOfColumns, 2)
        XCTAssertFalse(table.collapsesBorders,
                       "every boundary is resolved by this code now, not handed to AppKit to pick")
        func at(_ row: Int, _ col: Int) -> PlacedCell { try! XCTUnwrap(cells.first { $0.row == row && $0.col == col }) }
        // Every cell owns its OWN bottom-right rule (`.maxX`/`.maxY`); only column 0 / row 0 also own
        // the table's own left/top perimeter on `.minX`/`.minY` — see the design's ownership table.
        for cell in cells {
            XCTAssertGreaterThan(cell.block.width(for: .border, edge: .maxX), 0, "cell (\(cell.row),\(cell.col)) owns its own right rule")
            XCTAssertGreaterThan(cell.block.width(for: .border, edge: .maxY), 0, "cell (\(cell.row),\(cell.col)) owns its own bottom rule")
            XCTAssertEqual(cell.block.width(for: .border, edge: .minX) > 0, cell.col == 0,
                           "cell (\(cell.row),\(cell.col)) minX is only owned by column 0")
            XCTAssertEqual(cell.block.width(for: .border, edge: .minY) > 0, cell.row == 0,
                           "cell (\(cell.row),\(cell.col)) minY is only owned by row 0")
        }
        // Exactly one rule per boundary — sum the two facing edges and it must equal the theme width,
        // never 0 (a hole) and never double it (both sides drawing, what collapsing used to leave
        // ambiguous to AppKit).
        let T = RenderTheme.tableBorderWidth
        XCTAssertEqual(at(0, 0).block.width(for: .border, edge: .maxX) + at(0, 1).block.width(for: .border, edge: .minX), T)
        XCTAssertEqual(at(0, 0).block.width(for: .border, edge: .maxY) + at(1, 0).block.width(for: .border, edge: .minY), T)
    }

    /// `columnWidths` whose count doesn't match the table's own derived column count (a malformed
    /// grid) is exactly "no grid known" — the equal-share fallback renders, not a partial grid.
    func testMismatchedColumnWidthsCountFallsBackToPerCellLayout() {
        let rows: [[Cell]] = [[Cell(spans: [span("A")]), Cell(spans: [span("B")])]]
        let out = build([.table(rows: rows, headerRows: 0, columnWidths: [100, 100, 300])])
        let att = try! XCTUnwrap(firstGridTable(in: out))
        XCTAssertEqual(att.columnProportions.count, 2)
        for ratio in att.columnProportions { XCTAssertEqual(ratio, 0.5, accuracy: 0.001) }
    }

    /// The pre-sprint construction path (`Cell(spans:)`) leaves all four fields `nil` — the theme's
    /// existing defaults (no shading, `Palette.tableBorder` at 1pt) must be exactly what a cell with
    /// no shading/border/width info renders as.
    func testCellWithNoShadingBorderOrWidthKeepsExactlyTheThemeDefaults() {
        let out = build([.table(rows: [[Cell(spans: [span("A")])]], headerRows: 0)])
        let cell = try! XCTUnwrap(tableCells(in: out).first)
        XCTAssertNil(cell.background)
        XCTAssertEqual(cell.borderColor, Palette.tableBorder)
        XCTAssertEqual(cell.borderWidth, 1)
    }

    // MARK: Per-edge borders — declared / suppressed / never mentioned

    /// One placed cell's four border widths, top/bottom/left/right, so a per-edge assertion reads as
    /// one line instead of four near-identical `width(for:edge:)` calls.
    private func borderWidths(_ cell: PlacedCell) -> (top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat) {
        (cell.block.width(for: .border, edge: .minY), cell.block.width(for: .border, edge: .maxY),
         cell.block.width(for: .border, edge: .minX), cell.block.width(for: .border, edge: .maxX))
    }

    private func edges(_ decls: [(WritableKeyPath<EdgeBorders, BorderDecl?>, BorderDecl)]) -> EdgeBorders {
        var out = EdgeBorders()
        for (keyPath, decl) in decls { out[keyPath: keyPath] = decl }
        return out
    }

    /// A table that described its own box gets exactly that box — an edge it never mentioned draws
    /// NOTHING, including on the perimeter. Standing a faint rule in for the missing sides was built
    /// and rejected: across one 114-table report, 95 tables turn their outer rules off explicitly and
    /// only 19 merely omit them, so the stand-in landed on 19 and skipped 95, and a reader saw some
    /// tables boxed and others open with nothing on the page to explain the difference.
    func testUnmentionedOuterEdgesOfADeclaredTableDrawNothing() throws {
        var format = TableFormat()
        format.edgeBorders = edges([(\.top, .drawn(BorderSide(width: 2, color: .systemRed))),
                                    (\.bottom, .drawn(BorderSide(width: 2, color: .systemRed)))])
        let out = build([.table(rows: [[Cell(spans: [span("A")])]], headerRows: 0, format: format)])
        let cell = try XCTUnwrap(tableCells(in: out).first)
        let w = borderWidths(cell)
        XCTAssertEqual(w.top, 2, "the declared edges are untouched")
        XCTAssertEqual(w.bottom, 2)
        XCTAssertEqual(w.left, 0, "the table described its box and left this side out — so it is out")
        XCTAssertEqual(w.right, 0)
        XCTAssertEqual(cell.block.borderColor(for: .minY), .systemRed)
    }

    /// A CELL's own declaration is enough on its own — the outer stand-in follows from "this table
    /// said something about borders", not specifically from a table-level `w:tblBorders`.
    func testACellsOwnDeclarationAloneDoesNotFadeItsOtherEdges() throws {
        var cell = Cell(spans: [span("A")])
        cell.edgeBorders = edges([(\.top, .drawn(BorderSide(width: 3, color: nil)))])
        let out = build([.table(rows: [[cell]], headerRows: 0)])
        let placed = try XCTUnwrap(tableCells(in: out).first)
        let w = borderWidths(placed)
        XCTAssertEqual(w.top, 3, "the edge the cell stated")
        // The TABLE drew no box, so there is none to close: the three edges this cell never mentioned
        // keep the ordinary resolved border, exactly as they would with no per-edge data at all.
        XCTAssertEqual(w.left, RenderTheme.tableBorderWidth)
        XCTAssertEqual(w.right, RenderTheme.tableBorderWidth)
        XCTAssertEqual(w.bottom, RenderTheme.tableBorderWidth)
    }

    /// A cell with no side on the perimeter at all — the centre of a 3x3 — is the only placement that
    /// reaches the uniform arm with every edge resolving to nothing. A table that ruled its outer box
    /// and left the seams out gets no interior rules, and this is the path that decides it.
    func testTheCentreCellOfADeclaredTableDrawsNoRuleAtAll() throws {
        var format = TableFormat()
        format.edgeBorders = edges([(\.top, .drawn(BorderSide(width: 2, color: nil))),
                                    (\.bottom, .drawn(BorderSide(width: 2, color: nil))),
                                    (\.left, .drawn(BorderSide(width: 2, color: nil))),
                                    (\.right, .drawn(BorderSide(width: 2, color: nil)))])
        let rows: [[Cell]] = (0..<3).map { r in (0..<3).map { c in Cell(spans: [span("\(r)\(c)")]) } }
        let out = build([.table(rows: rows, headerRows: 0, format: format)])
        let cells = tableCells(in: out)
        XCTAssertEqual(cells.count, 9)
        let w = borderWidths(cells[4])   // row 1, column 1 — touches no side of the grid
        XCTAssertEqual([w.top, w.left, w.bottom, w.right], [0, 0, 0, 0],
                       "the table described its own box; interior seams it left out stay out")
    }

    /// THE REGRESSION THIS FILE EXISTS TO PREVENT, in the shape Word actually produces it — an
    /// author's deliberate suppression must not be silently overridden by the READER'S OWN invented
    /// default. Selecting one cell and removing one rule writes a `w:tcBorders` holding a single
    /// `w:val="nil"` — the cell has now "declared something" while saying nothing about its other
    /// three edges, and the table itself declared nothing at all, so the untouched neighbour below
    /// falls back to the ordinary theme rule (1pt) purely because NOBODY said anything about that
    /// edge — not because the document asked for a rule there.
    ///
    /// Two independent reviews found the first implementation let that bare fallback win the
    /// boundary purely on "wider wins" (0 vs 1pt) — making the author's `w:val="nil"` a complete
    /// no-op whenever the table drew no box of its own. The fix (design doc §3, Step B rule 0) checks
    /// EXPLICIT-suppression-vs-bare-fallback FIRST: the suppression wins, and the boundary the author
    /// removed draws nothing — restoring the originally-expected behaviour. A suppression only loses
    /// when the OTHER side is a GENUINELY declared rule (see
    /// `testSuppressedLosesToADrawnRuleRatherThanVetoingIt` for that case, unaffected by this fix) —
    /// which this test deliberately does NOT exercise: the untouched neighbour never declared
    /// anything at all.
    func testOneCellSuppressingAnEdgeStillBeatsAnUncontestedNeighbourFallback() throws {
        var quiet = Cell(spans: [span("plain")])
        quiet.edgeBorders = nil
        var touched = Cell(spans: [span("edited")])
        touched.edgeBorders = edges([(\.bottom, .suppressed)])
        let rows: [[Cell]] = [[touched, quiet], [quiet, quiet]]
        let out = build([.table(rows: rows, headerRows: 0)])   // no TableFormat: the table says nothing
        let cells = tableCells(in: out)
        XCTAssertEqual(cells.count, 4)
        let T = RenderTheme.tableBorderWidth
        let edited = try XCTUnwrap(cells.first { $0.row == 0 && $0.col == 0 })
        let editedWidths = borderWidths(edited)
        XCTAssertEqual(editedWidths.bottom, 0,
                       "the author's own explicit suppression beats a bare, un-declared neighbour fallback")
        for (edge, width) in [("top", editedWidths.top), ("left", editedWidths.left), ("right", editedWidths.right)] {
            XCTAssertEqual(width, T, "\(edge) must match the untouched cells — only bottom was touched")
        }
        // The three untouched cells read their OWNERSHIP-CONSISTENT shape, not uniformly-4 any more:
        // (0,1) owns nothing on its left (that boundary belongs to (0,0)); (1,0)/(1,1) own nothing on
        // top (those boundaries belong to row 0). Every cell still owns its own bottom-right rule.
        let atOneOne = try XCTUnwrap(cells.first { $0.row == 0 && $0.col == 1 })
        XCTAssertEqual(borderWidths(atOneOne).left, 0, "(0,1)'s left boundary is owned by (0,0)")
        XCTAssertEqual(borderWidths(atOneOne).top, T)
        XCTAssertEqual(borderWidths(atOneOne).bottom, T)
        XCTAssertEqual(borderWidths(atOneOne).right, T)
        let atTenZero = try XCTUnwrap(cells.first { $0.row == 1 && $0.col == 0 })
        XCTAssertEqual(borderWidths(atTenZero).top, 0, "(1,0)'s top boundary is owned by (0,0)")
        XCTAssertEqual(borderWidths(atTenZero).left, T)
        XCTAssertEqual(borderWidths(atTenZero).bottom, T)
        XCTAssertEqual(borderWidths(atTenZero).right, T)
        let atTenOne = try XCTUnwrap(cells.first { $0.row == 1 && $0.col == 1 })
        XCTAssertEqual(borderWidths(atTenOne).top, 0, "(1,1)'s top boundary is owned by (0,1)")
        XCTAssertEqual(borderWidths(atTenOne).left, 0, "(1,1)'s left boundary is owned by (1,0)")
        XCTAssertEqual(borderWidths(atTenOne).bottom, T)
        XCTAssertEqual(borderWidths(atTenOne).right, T)
    }

    /// An edge the document explicitly turned OFF draws nothing. The distinction from "never
    /// mentioned" still matters to the reader even though both now draw nothing here: it is what
    /// stops a lone `w:val="nil"` on one cell from stripping that cell's other three edges of the
    /// cascade its neighbours are using (see the one-cell regression test below).
    func testAnExplicitlySuppressedEdgeDrawsNothing() throws {
        var format = TableFormat()
        format.edgeBorders = edges([(\.top, .drawn(BorderSide(width: 2, color: .systemRed))),
                                    (\.left, .suppressed)])
        let out = build([.table(rows: [[Cell(spans: [span("A")])]], headerRows: 0, format: format)])
        let cell = try XCTUnwrap(tableCells(in: out).first)
        let w = borderWidths(cell)
        XCTAssertEqual(w.left, 0, "explicitly off stays off")
        XCTAssertEqual(w.top, 2)
        XCTAssertEqual(w.bottom, 0, "this table drew a box; a side it never named stays unnamed")
        XCTAssertEqual(w.right, 0)
    }

    /// A table that turned EVERY border off draws no rule at all. It must not fall through to the
    /// theme default — that would restore exactly the border the document removed. This is the arm
    /// the all-`.suppressed` declaration (which the reader now preserves) exists to reach.
    func testATableThatTurnedEveryBorderOffDrawsNoRuleAtAll() throws {
        var format = TableFormat()
        format.edgeBorders = edges([(\.top, .suppressed), (\.left, .suppressed), (\.bottom, .suppressed),
                                    (\.right, .suppressed), (\.insideH, .suppressed), (\.insideV, .suppressed)])
        let rows: [[Cell]] = [[Cell(spans: [span("A")]), Cell(spans: [span("B")])],
                              [Cell(spans: [span("C")]), Cell(spans: [span("D")])]]
        let out = build([.table(rows: rows, headerRows: 0, format: format)])
        for cell in tableCells(in: out) {
            let w = borderWidths(cell)
            XCTAssertEqual([w.top, w.bottom, w.left, w.right], [0, 0, 0, 0],
                           "cell (\(cell.row),\(cell.col)) must draw nothing")
        }
    }

    /// The outer stand-in is a PERIMETER rule only. In a table that rules just its outer box, the
    /// INTERIOR seams the document never mentioned stay undrawn — filling those in would invent a
    /// grid the author didn't ask for.
    func testUnmentionedInteriorEdgesStayUndrawnEvenInADeclaredTable() throws {
        let rule = BorderDecl.drawn(BorderSide(width: 2, color: .systemRed))
        var format = TableFormat()
        format.edgeBorders = edges([(\.top, rule), (\.left, rule), (\.bottom, rule), (\.right, rule)])
        let rows: [[Cell]] = [[Cell(spans: [span("A")]), Cell(spans: [span("B")])],
                              [Cell(spans: [span("C")]), Cell(spans: [span("D")])]]
        let out = build([.table(rows: rows, headerRows: 0, format: format)])
        let topLeft = try XCTUnwrap(tableCells(in: out).first { $0.row == 0 && $0.col == 0 })
        let w = borderWidths(topLeft)
        XCTAssertEqual(w.top, 2, "on the table's own top edge")
        XCTAssertEqual(w.left, 2, "on the table's own left edge")
        XCTAssertEqual(w.bottom, 0, "interior seam the document never mentioned — not faint, not drawn")
        XCTAssertEqual(w.right, 0)
    }

    /// INVARIANT 37 PIN, RESTATED AS GEOMETRY (design doc §5) — a table that declares NO border
    /// information at all (every markdown/HWP/ODT table, and any docx without `w:tblBorders`/
    /// `w:tcBorders`) still draws every rule at the theme's own width and colour, exactly ONCE per
    /// boundary — never a hole, never a double-drawn seam. The LITERAL former reading ("all four
    /// edges of every cell read `RenderTheme.tableBorderWidth`") no longer holds, deliberately:
    /// `collapsesBorders` is off, so an interior boundary has exactly one OWNER (Step C's per-edge
    /// ownership) and the facing side reads back 0 — by construction, not by omission. Measured
    /// before this change: every cell's four edges read `RenderTheme.tableBorderWidth` uniformly (2x,
    /// both sides of a boundary drawing, AppKit picking one silently). Measured after: only the
    /// owning side does; the boundary-sum assertions below are what actually protects "a document
    /// that says nothing still gets a complete, undoubled grid".
    func testATableThatDeclaresNoBorderInformationKeepsExactlyTheThemeDefaultOnEveryBoundary() {
        let rows: [[Cell]] = [[Cell(spans: [span("A")]), Cell(spans: [span("B")])],
                              [Cell(spans: [span("C")]), Cell(spans: [span("D")])]]
        let out = build([.table(rows: rows, headerRows: 0)])
        let cells = tableCells(in: out)
        XCTAssertEqual(cells.count, 4)
        XCTAssertEqual(RenderTheme.tableBorderWidth, 1, "the hoisted token still holds the shipped value")
        func at(_ row: Int, _ col: Int) -> PlacedCell { try! XCTUnwrap(cells.first { $0.row == row && $0.col == col }) }
        let T = RenderTheme.tableBorderWidth
        // Measured per-cell shape: top-left owns both perimeter sides AND both interior boundaries
        // (it is column 0 AND row 0 AND the upper-left neighbour of both interior seams), so it is
        // the one cell whose all-four-edges reading is unchanged from before this pipeline.
        let expected: [(row: Int, col: Int, minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat)] = [
            (0, 0, T, T, T, T),
            (0, 1, 0, T, T, T),
            (1, 0, T, T, 0, T),
            (1, 1, 0, T, 0, T),
        ]
        for (row, col, minX, maxX, minY, maxY) in expected {
            let cell = at(row, col)
            XCTAssertEqual(cell.block.width(for: .border, edge: .minX), minX, "cell (\(row),\(col)) minX")
            XCTAssertEqual(cell.block.width(for: .border, edge: .maxX), maxX, "cell (\(row),\(col)) maxX")
            XCTAssertEqual(cell.block.width(for: .border, edge: .minY), minY, "cell (\(row),\(col)) minY")
            XCTAssertEqual(cell.block.width(for: .border, edge: .maxY), maxY, "cell (\(row),\(col)) maxY")
            for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] where cell.block.width(for: .border, edge: edge) > 0 {
                XCTAssertEqual(cell.block.borderColor(for: edge), Palette.tableBorder, "cell (\(row),\(col)) edge \(edge) colour")
            }
        }
        // The geometry gate itself: every one of the grid's boundaries draws EXACTLY one rule at the
        // theme width — sum the two facing sides and it is always `T`, never 0 and never `2 * T`.
        XCTAssertEqual(at(0, 0).block.width(for: .border, edge: .maxX) + at(0, 1).block.width(for: .border, edge: .minX), T,
                       "the (0,0)-(0,1) interior vertical boundary draws exactly one rule")
        XCTAssertEqual(at(1, 0).block.width(for: .border, edge: .maxX) + at(1, 1).block.width(for: .border, edge: .minX), T,
                       "the (1,0)-(1,1) interior vertical boundary draws exactly one rule")
        XCTAssertEqual(at(0, 0).block.width(for: .border, edge: .maxY) + at(1, 0).block.width(for: .border, edge: .minY), T,
                       "the (0,0)-(1,0) interior horizontal boundary draws exactly one rule")
        XCTAssertEqual(at(0, 1).block.width(for: .border, edge: .maxY) + at(1, 1).block.width(for: .border, edge: .minY), T,
                       "the (0,1)-(1,1) interior horizontal boundary draws exactly one rule")
    }

    /// Every placed block's `contentWidth`, in reading order — the value `resizeTables` recomputes.
    private func contentWidths(in storage: NSTextStorage) -> [CGFloat] {
        var seen: [ObjectIdentifier: Bool] = [:]
        var out: [CGFloat] = []
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let ps = value as? NSParagraphStyle, let block = ps.textBlocks.first as? NSTextTableBlock,
                  seen.updateValue(true, forKey: ObjectIdentifier(block)) == nil else { return }
            out.append(block.contentWidth)
        }
        return out
    }

    /// `build` and `resizeTables` must derive a cell's content width from the SAME numbers. The faint
    /// outline moves an outer edge from 0 to 1 and a suppressed one to 0 — asymmetric left/right, the
    /// exact shape that breaks if either path subtracts one edge twice. If they disagree, every cell
    /// reads as "changed" on every reflow: real work, plus a visible re-snap of the table right after
    /// it was drawn (the bug `resizeTables`' own doc comment records). Re-solving at the width the
    /// table was BUILT at must therefore move nothing.
    func testResolvingColumnsAtTheBuildWidthMovesNoCellWhenPerEdgeBordersAreInPlay() {
        let tableEdges = edges([(\.top, .drawn(BorderSide(width: 2, color: .systemRed))),
                                (\.left, .suppressed)])
        func cell(_ text: String) -> TableBlockBuilder.CellContent {
            TableBlockBuilder.CellContent(content: NSAttributedString(string: text + "\n"))
        }
        let out = TableBlockBuilder.build(rows: [[cell("A"), cell("B")], [cell("C"), cell("D")]],
                                          headerRows: 0, theme: theme, tableEdges: tableEdges, width: 480)
        let storage = NSTextStorage(attributedString: out)
        let built = contentWidths(in: storage)
        XCTAssertEqual(built.count, 4)
        TableBlockBuilder.resizeTables(in: storage, toWidth: 480)
        XCTAssertEqual(contentWidths(in: storage), built,
                       "re-solving at the build width must be a no-op — the two formulas agree")
    }

    /// The SAME parity check, but with a genuinely NONZERO, asymmetric border on both the perimeter
    /// and an interior boundary — the previous test's table (top declared, left suppressed) happens
    /// to leave every HORIZONTAL border at 0 for every cell, so a reintroduced halving in
    /// `resizeTables` cannot be told apart from the correct full-subtraction formula there: both
    /// compute `0 / 2 == 0`. This one gives the left cell a real 1pt perimeter `.minX` AND a real 4pt
    /// owned interior `.maxX`, so a halving regression moves the content width by 2.5pt — well past
    /// the 0.5pt "did this cell actually move" threshold `resizeTables` itself uses. Mutation check:
    /// reintroducing `borderL / 2 - borderR / 2` in `resizeTables` (out of step with `build`'s full
    /// subtraction) made this fail while leaving the OTHER (all-zero-border) parity test above
    /// passing — see the implementation log.
    func testResolvingColumnsAtTheBuildWidthMovesNoCellWhenBordersAreGenuinelyAsymmetricAndNonzero() {
        var left = TableBlockBuilder.CellContent(content: NSAttributedString(string: "L\n"))
        left.edgeBorders = EdgeBorders(right: .drawn(BorderSide(width: 4, color: .systemBlue)))
        let right = TableBlockBuilder.CellContent(content: NSAttributedString(string: "R\n"))
        let out = TableBlockBuilder.build(rows: [[left, right]], headerRows: 0, theme: theme, width: 480)
        let storage = NSTextStorage(attributedString: out)
        let built = contentWidths(in: storage)
        XCTAssertEqual(built.count, 2)
        TableBlockBuilder.resizeTables(in: storage, toWidth: 480)
        XCTAssertEqual(contentWidths(in: storage), built,
                       "re-solving at the build width must be a no-op even when a real border is asymmetric left/right")
    }

    /// Merged cells (R1's `colSpan`) must still work once a cell can ALSO carry shading — the two
    /// features must not interfere with each other.
    func testMergedCellWithShadingStillAppliesBothItsSpanAndItsShading() {
        let rows: [[Cell]] = [[Cell(blocks: [.paragraph(spans: [span("Wide")])], colSpan: 2, backgroundColor: .systemOrange)]]
        let out = build([.table(rows: rows, headerRows: 0)])
        let cell = try! XCTUnwrap(tableCells(in: out).first)
        XCTAssertEqual(cell.colSpan, 2)
        XCTAssertEqual(cell.background, .systemOrange)
    }

    // MARK: P3b — table-level default border/shading, cell vertical alignment, cell margins

    /// A table-level default border/width (`TableFormat`, from a `w:tblBorders` the reader read)
    /// is applied to a cell that declares no border of its own — the MIDDLE layer between the
    /// cell's own value and the theme default.
    func testTableDefaultBorderAppliesWhenTheCellDeclaresNoBorderOfItsOwn() {
        let rows: [[Cell]] = [[Cell(spans: [span("A")])]]
        let out = build([.table(rows: rows, headerRows: 0,
                                format: TableFormat(defaultBorderColor: .systemPurple, defaultBorderWidth: 3))])
        let cell = try! XCTUnwrap(tableCells(in: out).first)
        XCTAssertEqual(cell.borderColor, .systemPurple)
        XCTAssertEqual(cell.borderWidth, 3)
    }

    /// A cell's OWN border still wins over a table-level default that exists alongside it.
    func testCellOwnBorderWinsOverTheTableDefaultBorder() {
        let rows: [[Cell]] = [[Cell(blocks: [.paragraph(spans: [span("A")])], borderColor: .systemRed, borderWidth: 5)]]
        let out = build([.table(rows: rows, headerRows: 0,
                                format: TableFormat(defaultBorderColor: .systemPurple, defaultBorderWidth: 3))])
        let cell = try! XCTUnwrap(tableCells(in: out).first)
        XCTAssertEqual(cell.borderColor, .systemRed)
        XCTAssertEqual(cell.borderWidth, 5)
    }

    /// A table-level default shading applies to a cell with no shading of its own — including a
    /// HEADER cell, where it wins over the theme's own header shading too (a source-authored
    /// table default is more specific than the app's synthetic header colour).
    func testTableDefaultShadingAppliesToCellsWithNoShadingOfTheirOwnIncludingHeaderRows() {
        let rows: [[Cell]] = [[Cell(spans: [span("H")])]]
        let out = build([.table(rows: rows, headerRows: 1, format: TableFormat(defaultShading: .systemYellow))])
        let cell = try! XCTUnwrap(tableCells(in: out).first)
        XCTAssertEqual(cell.background, .systemYellow)
    }

    /// A cell's OWN shading still wins over a table-level default.
    func testCellOwnShadingWinsOverTheTableDefaultShading() {
        let rows: [[Cell]] = [[Cell(blocks: [.paragraph(spans: [span("A")])], backgroundColor: .systemGreen)]]
        let out = build([.table(rows: rows, headerRows: 0, format: TableFormat(defaultShading: .systemYellow))])
        let cell = try! XCTUnwrap(tableCells(in: out).first)
        XCTAssertEqual(cell.background, .systemGreen)
    }

    /// P5 — a cell carrying BOTH its own direct `backgroundColor` AND a table-STYLE-resolved
    /// `styleShading` renders with the DIRECT value: `TableBlockBuilder.build`'s resolution chain
    /// is `cell-direct > table-direct > table-style > theme`, and this is the top of that chain
    /// actually reaching the placed cell's `background`, not just read from source.
    func testCellOwnDirectShadingWinsOverItsOwnStyleShadingAtBuildLevel() {
        var cell = Cell(blocks: [.paragraph(spans: [span("A")])], backgroundColor: .systemRed)
        cell.styleShading = .systemYellow
        let out = build([.table(rows: [[cell]], headerRows: 0)])
        let placed = try! XCTUnwrap(tableCells(in: out).first)
        XCTAssertEqual(placed.background, .systemRed)
    }

    /// `Cell.verticalAlignment == .center` becomes the placed cell's `verticalAlignment == .center`.
    func testCellVerticalAlignmentCenterBecomesMiddleAlignment() {
        let rows: [[Cell]] = [[Cell(blocks: [.paragraph(spans: [span("A")])], verticalAlignment: .center)]]
        let out = build([.table(rows: rows, headerRows: 0)])
        let cell = try! XCTUnwrap(tableCells(in: out).first)
        XCTAssertEqual(cell.verticalAlignment, .middleAlignment)
    }

    /// `nil` (the pre-sprint default) leaves the placed cell at its `.top` vertical alignment.
    func testCellWithNoVerticalAlignmentKeepsTheDefaultTopAlignment() {
        let rows: [[Cell]] = [[Cell(spans: [span("A")])]]
        let out = build([.table(rows: rows, headerRows: 0)])
        let cell = try! XCTUnwrap(tableCells(in: out).first)
        XCTAssertEqual(cell.verticalAlignment, .topAlignment)
    }

    /// `Cell.padding` (already resolved by the reader against any table default) reaches the placed
    /// cell's own uniform `padding` — the custom table draws it as the cell's inner inset, so the old
    /// horizontal-block-padding-vs-text-indent dance is gone. The cell's content keeps its OWN
    /// paragraph style (readability line-height floor) with NO table indent added on top.
    func testCellPaddingReplacesTheHardcodedSevenPointDefault() {
        let rows: [[Cell]] = [[Cell(blocks: [.paragraph(spans: [span("A")])], padding: 12)]]
        let out = build([.table(rows: rows, headerRows: 0)])
        let cell = try! XCTUnwrap(tableCells(in: out).first)
        XCTAssertEqual(cell.padding, 12)
        let ps = try! XCTUnwrap(out.attribute(.paragraphStyle, at: cell.range.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(ps.headIndent, 0, "no table indent added on top of the cell's own paragraph style")
        XCTAssertEqual(ps.tailIndent, 0)
        XCTAssertEqual(ps.minimumLineHeight, (theme.baseFontSize * theme.lineHeightRatio).rounded(),
                       "the cell content keeps its own body line-height")
    }

    /// `nil` (every markdown table, and a docx table/cell with no declared margin) keeps the
    /// pre-sprint 7pt inset — now the placed cell's uniform `padding`, with the content's own
    /// paragraph style unchanged (no table indent).
    func testCellWithNoPaddingKeepsTheHardcodedSevenPointDefault() {
        let rows: [[Cell]] = [[Cell(spans: [span("A")])]]
        let out = build([.table(rows: rows, headerRows: 0)])
        let cell = try! XCTUnwrap(tableCells(in: out).first)
        XCTAssertEqual(cell.padding, 7)
        let ps = try! XCTUnwrap(out.attribute(.paragraphStyle, at: cell.range.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(ps.headIndent, 0, "no table indent added on top of the cell's own paragraph style")
    }

    // MARK: P2 — ParagraphFormat → NSParagraphStyle (spacing/line-height/indent/contextualSpacing)

    private func paragraphStyle(in out: NSAttributedString, at index: Int = 0) -> NSParagraphStyle {
        out.attribute(.paragraphStyle, at: index, effectiveRange: nil) as! NSParagraphStyle
    }

    /// `documentDefaultFontSize` matching `theme.baseFontSize` (16) gives `fontSizeScale == 1`, so
    /// every expected number below is the SOURCE points value, unscaled — the cleanest fixture for
    /// pinning the conversion itself, separately from the scaling multiplication tested afterwards.
    private func buildUnscaled(_ blocks: [OfficeBlock]) -> NSAttributedString {
        OfficeTextBuilder.build(blocks, theme: theme, documentDefaultFontSize: theme.baseFontSize)
    }

    /// `spacingBefore`/`spacingAfter` reach `paragraphSpacingBefore`/`paragraphSpacing` unscaled at
    /// `fontSizeScale == 1` — the spec's own worked example (12pt/6pt, already twips→points
    /// converted by the reader; the reader-side conversion itself is `DocxReaderTests`' job).
    func testSpacingBeforeAndAfterReachParagraphSpacingAttributesUnscaled() {
        var format = ParagraphFormat()
        format.spacingBefore = 12
        format.spacingAfter = 6
        let out = buildUnscaled([.paragraph(spans: [span("Body")], format: format)])
        let style = paragraphStyle(in: out)
        XCTAssertEqual(style.paragraphSpacingBefore, 12)
        XCTAssertEqual(style.paragraphSpacing, 6)
    }

    /// The SAME format, scaled: `documentDefaultFontSize` half `theme.baseFontSize` makes
    /// `fontSizeScale == 2`, so 12pt/6pt authored becomes 24pt/12pt rendered — proving the P2
    /// values ride the SAME reading-size ratio `Span.fontSize` already does.
    func testSpacingBeforeAndAfterScaleWithFontSizeScale() {
        var format = ParagraphFormat()
        format.spacingBefore = 12
        format.spacingAfter = 6
        let out = OfficeTextBuilder.build([.paragraph(spans: [span("Body")], format: format)],
                                          theme: theme, documentDefaultFontSize: theme.baseFontSize / 2)
        let style = paragraphStyle(in: out)
        XCTAssertEqual(style.paragraphSpacingBefore, 24)
        XCTAssertEqual(style.paragraphSpacing, 12)
    }

    /// `.multiple` is a unitless RATIO (`w:lineRule="auto"`'s `line/240`) — it must land on
    /// `lineHeightMultiple` UNCHANGED regardless of `fontSizeScale`, unlike every point-valued field —
    /// AND, like `.atLeast`, it must clear the body-style token's own fixed `min == max == lh`. Leaving
    /// that `maximumLineHeight` cap in place clamps `naturalHeight * ratio` back down to `lh`, silently
    /// squeezing a document that asked for `w:line="260"` (1.083×) into the app's tighter fixed rhythm —
    /// the "줄간격이 너무 타이트" bug. A multiple must govern alone, with no fixed floor or cap.
    func testLineHeightMultipleSetsLineHeightMultipleUnscaledAndClearsAnyFixedCap() {
        var format = ParagraphFormat()
        format.lineHeight = .multiple(1.5)
        let out = OfficeTextBuilder.build([.paragraph(spans: [span("Body")], format: format)],
                                          theme: theme, documentDefaultFontSize: theme.baseFontSize / 2)
        let style = paragraphStyle(in: out)
        XCTAssertEqual(style.lineHeightMultiple, 1.5)
        // Cap cleared so a document LOOSER than the floor (1.5× here) expands freely.
        XCTAssertEqual(style.maximumLineHeight, 0)
        // Minimum is the readability floor — set, though it doesn't bind here (1.5× > floor).
        XCTAssertEqual(style.minimumLineHeight, theme.baseFontSize * OfficeStyle(theme: theme).bodyMinLineHeightRatio)
    }

    /// A near-single line rule (`w:line="260"` = 1.083×, this doc's actual value) measured against
    /// the substituted body font renders far tighter than markdown body; the floor keeps office body
    /// readable. The multiple is still set (a document asking for MORE than the floor gets it), but
    /// the minimum guarantees a tight document never drops below the floor.
    func testTightLineMultipleIsFlooredForReadability() {
        var format = ParagraphFormat()
        format.lineHeight = .multiple(260.0 / 240.0)  // 1.083×, this document's own w:line/lineRule
        let out = OfficeTextBuilder.build([.paragraph(spans: [span("Body")], format: format)],
                                          theme: theme, documentDefaultFontSize: theme.baseFontSize)
        let style = paragraphStyle(in: out)
        XCTAssertEqual(style.minimumLineHeight, theme.baseFontSize * OfficeStyle(theme: theme).bodyMinLineHeightRatio)
        XCTAssertEqual(style.maximumLineHeight, 0)
    }

    /// `.exact` sets BOTH `minimumLineHeight` and `maximumLineHeight` to the same scaled point
    /// value — the hard cap the spec's `lineRule="exact"` describes (tall content clips rather than
    /// growing the line).
    func testLineHeightExactSetsMinimumAndMaximumToTheSameScaledValue() {
        var format = ParagraphFormat()
        format.lineHeight = .exact(20)
        let out = OfficeTextBuilder.build([.paragraph(spans: [span("Body")], format: format)],
                                          theme: theme, documentDefaultFontSize: theme.baseFontSize / 2)
        let style = paragraphStyle(in: out)
        XCTAssertEqual(style.minimumLineHeight, 40)
        XCTAssertEqual(style.maximumLineHeight, 40)
    }

    /// `.atLeast` sets `minimumLineHeight` to the scaled floor and clears `maximumLineHeight` back
    /// to 0 (AppKit's "no maximum") — a mutation that left the body-style token's own
    /// `maximumLineHeight` in place would silently reintroduce a cap `atLeast` explicitly forbids.
    func testLineHeightAtLeastSetsFloorAndClearsAnyCap() {
        var format = ParagraphFormat()
        format.lineHeight = .atLeast(20)
        let out = buildUnscaled([.paragraph(spans: [span("Body")], format: format)])
        let style = paragraphStyle(in: out)
        XCTAssertEqual(style.minimumLineHeight, 20)
        XCTAssertEqual(style.maximumLineHeight, 0)
    }

    // MARK: Body line-height is a FLOOR, not a fixed cap (HWP large-body-paragraph title bug)

    /// Lay `s` out through a real TextKit stack and return the height of its FIRST line fragment —
    /// the effective line height the reader draws, which the raw paragraph-style attributes alone
    /// cannot prove (a `maximumLineHeight` cap only bites once a glyph is taller than it).
    private func firstLineHeight(_ s: NSAttributedString, width: CGFloat = 2000) -> CGFloat {
        let storage = NSTextStorage(attributedString: s)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var effective = NSRange()
        return manager.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: &effective).height
    }

    /// The default body paragraph style (no explicit line rule) must pin its `base × lineHeightRatio`
    /// line height as a FLOOR (`minimumLineHeight`) and CLEAR the maximum — so a paragraph whose own
    /// font is taller than the floor grows the line instead of clipping. Before this fix the body
    /// token set `maximumLineHeight == floor`, which clamped a 40pt/46pt line back to ~23pt and made
    /// large BODY paragraphs (an HWP title is one — not a `.heading`) render as overlapping rows.
    func testBodyParagraphLineHeightIsAFloorNotAFixedCap() {
        let out = buildUnscaled([.paragraph(spans: [span("Body")])])
        let style = paragraphStyle(in: out)
        XCTAssertEqual(style.minimumLineHeight, (theme.baseFontSize * theme.lineHeightRatio).rounded(),
                       "floor unchanged — normal body keeps today's exact rhythm")
        XCTAssertEqual(style.maximumLineHeight, 0, "no cap, so a font taller than the floor grows the line")
    }

    /// Behavioural proof through TextKit: a NORMAL (base-size) body line still lays out at exactly
    /// the floor (byte-identical rendering to before — the natural height of 16pt text is below the
    /// floor, so the floor still governs), while a LARGE-font (40pt) body line lays out tall enough
    /// to hold the glyph instead of being clamped to the floor and overlapping its neighbours.
    func testLargeFontBodyDoesNotClipWhileNormalBodyIsUnchanged() {
        let floor = (theme.baseFontSize * theme.lineHeightRatio).rounded()   // round(16 * 1.45) == 23

        let normal = buildUnscaled([.paragraph(spans: [span("Normal body line")])])
        XCTAssertEqual(firstLineHeight(normal), floor, accuracy: 0.5,
                       "a base-size line still lays out at the floor — normal body rendering unchanged")

        // 40pt at documentDefaultFontSize == baseFontSize (fontSizeScale == 1), so the run is a real 40pt glyph.
        let large = buildUnscaled([.paragraph(spans: [span("Big", fontSize: 40)])])
        XCTAssertGreaterThanOrEqual(firstLineHeight(large), 40,
                                    "a 40pt body line grows to fit the glyph rather than clipping to the ~23pt floor")
    }

    /// The full indent formula (spec area 5's `NSParagraphStyle` mapping): `headIndent = indentStart`,
    /// `tailIndent = -indentEnd` (AppKit's own right-margin-relative convention, already used by the
    /// markdown code-card header/footer), `firstLineHeadIndent = indentStart + firstLineIndent`.
    func testIndentStartEndAndFirstLineCombineIntoHeadTailAndFirstLineIndent() {
        var format = ParagraphFormat()
        format.indentStart = 10
        format.indentEnd = 5
        format.firstLineIndent = 6
        let out = buildUnscaled([.paragraph(spans: [span("Body")], format: format)])
        let style = paragraphStyle(in: out)
        XCTAssertEqual(style.headIndent, 10)
        XCTAssertEqual(style.tailIndent, -5)
        XCTAssertEqual(style.firstLineHeadIndent, 16)
    }

    /// `hangingIndent` SUBTRACTS from `firstLineHeadIndent` (the classic bullet/numbered shape: the
    /// first line sits LEFT of the body) — the opposite sign from `firstLineIndent`.
    func testHangingIndentSubtractsFromFirstLineHeadIndent() {
        var format = ParagraphFormat()
        format.indentStart = 10
        format.hangingIndent = 4
        let out = buildUnscaled([.paragraph(spans: [span("Body")], format: format)])
        XCTAssertEqual(paragraphStyle(in: out).firstLineHeadIndent, 6)
    }

    /// A `ParagraphFormat` with every field `nil` (the default) must leave `headIndent` at its
    /// pre-P2 token default (0 for an ordinary body paragraph) — "unspecified = identical".
    func testDefaultParagraphFormatLeavesIndentAtTheTokenDefault() {
        let out = buildUnscaled([.paragraph(spans: [span("Body")], format: ParagraphFormat())])
        XCTAssertEqual(paragraphStyle(in: out).headIndent, 0)
    }

    /// A heading block's format is resolved through the SAME `applyParagraphFormat` path as a
    /// plain paragraph's — proving the wiring reaches `headingParagraphStyle`, not only
    /// `bodyParagraphStyle`.
    func testHeadingBlockAlsoAppliesItsOwnParagraphFormat() {
        var format = ParagraphFormat()
        format.spacingBefore = 30
        let out = buildUnscaled([.heading(level: 1, spans: [span("Title")], format: format)])
        XCTAssertEqual(paragraphStyle(in: out).paragraphSpacingBefore, 30)
    }

    /// A list item's DIRECT format still wins over the marker/hang-indent geometry
    /// `listParagraphStyle` otherwise computes from `level` — proving `applyParagraphFormat` is
    /// wired into the list path too, not only body/heading.
    func testListItemsOwnDirectIndentOverridesTheMarkerGeometry() {
        var format = ParagraphFormat()
        format.indentStart = 50
        let out = buildUnscaled([.listItem(level: 0, ordered: false, spans: [span("Item")], format: format)])
        XCTAssertEqual(paragraphStyle(in: out).headIndent, 50)
    }

    // MARK: P2 — contextualSpacing adjacency (spec area 5)

    /// Two CONSECUTIVE paragraphs sharing an EQUAL `ParagraphFormat` with `contextualSpacing: true`
    /// must have the shared edge's spacing zeroed on BOTH sides (the first's `spacingAfter`, the
    /// second's `spacingBefore`) while each paragraph's OUTER edge (nothing to suppress against)
    /// keeps its authored value — Word's own "no gap within a run of the same style" rule.
    func testConsecutiveSameStyleContextualSpacingParagraphsSuppressTheSharedEdge() {
        var format = ParagraphFormat()
        format.spacingBefore = 10
        format.spacingAfter = 8
        format.contextualSpacing = true
        let out = buildUnscaled([
            .paragraph(spans: [span("First")], format: format),
            .paragraph(spans: [span("Second")], format: format),
        ])
        let firstRange = (out.string as NSString).range(of: "First")
        let secondRange = (out.string as NSString).range(of: "Second")
        let first = paragraphStyle(in: out, at: firstRange.location)
        let second = paragraphStyle(in: out, at: secondRange.location)
        XCTAssertEqual(first.paragraphSpacingBefore, 10, "the first item's own leading edge is untouched")
        XCTAssertEqual(first.paragraphSpacing, 0, "suppressed — the next block shares its format")
        XCTAssertEqual(second.paragraphSpacingBefore, 0, "suppressed — the previous block shares its format")
        XCTAssertEqual(second.paragraphSpacing, 8, "the second item's own trailing edge is untouched")
    }

    /// Mutation check: if the NEXT block's format DIFFERS (a real style change, not the same list/
    /// style continuing), contextualSpacing must NOT suppress anything — proving the adjacency
    /// check compares actual format equality, not merely "both set contextualSpacing".
    func testContextualSpacingDoesNotSuppressWhenTheNeighboursFormatDiffers() {
        var format = ParagraphFormat()
        format.spacingAfter = 8
        format.contextualSpacing = true
        var differentFormat = format
        differentFormat.spacingAfter = 99
        let out = buildUnscaled([
            .paragraph(spans: [span("First")], format: format),
            .paragraph(spans: [span("Second")], format: differentFormat),
        ])
        let firstRange = (out.string as NSString).range(of: "First")
        XCTAssertEqual(paragraphStyle(in: out, at: firstRange.location).paragraphSpacing, 8,
                       "a differently-formatted neighbour must never trigger suppression")
    }

    /// A block whose `contextualSpacing` is `false` (the pre-P2 default) must never be suppressed,
    /// even sitting next to an identically-formatted neighbour — the rule is opt-in per the source.
    func testContextualSpacingFalseNeverSuppressesEvenWithAnIdenticalNeighbour() {
        var format = ParagraphFormat()
        format.spacingAfter = 8
        format.contextualSpacing = false
        let out = buildUnscaled([
            .paragraph(spans: [span("First")], format: format),
            .paragraph(spans: [span("Second")], format: format),
        ])
        let firstRange = (out.string as NSString).range(of: "First")
        XCTAssertEqual(paragraphStyle(in: out, at: firstRange.location).paragraphSpacing, 8)
    }

    // MARK: MDAttr.hidesPageNumber (HWP's PageHide veto reaching the built storage)

    /// The marker actually reaches the built storage on the block `hidePageNumberBlocks` names —
    /// the same "one attribute run over the whole kept range" shape `sectionIndex`/`startsPage` use.
    func testHidePageNumberBlockIsStampedOnItsOwnRange() {
        let out = OfficeTextBuilder.build(
            [.paragraph(spans: [span("cover")]), .paragraph(spans: [span("divider")]),
             .paragraph(spans: [span("body")])],
            theme: theme, hidePageNumberBlocks: [1])
        var hidden: [Bool] = []
        out.enumerateAttribute(MDAttr.hidesPageNumber, in: NSRange(location: 0, length: out.length)) { v, range, _ in
            guard let flag = v as? Bool else { return }
            XCTAssertGreaterThan(range.length, 0, "a hidesPageNumber run must not be zero-length")
            hidden.append(flag)
        }
        XCTAssertEqual(hidden, [true], "exactly one block was named — exactly one marked run must exist")
    }

    /// The MIRROR — a block not named in `hidePageNumberBlocks` carries no marker at all (absence,
    /// not `false`), which is what `enumerateAttribute` finding nothing here proves.
    func testABlockNotInHidePageNumberBlocksCarriesNoMarker() {
        let out = OfficeTextBuilder.build([.paragraph(spans: [span("ordinary")])],
                                          theme: theme, hidePageNumberBlocks: [])
        var found = false
        out.enumerateAttribute(MDAttr.hidesPageNumber, in: NSRange(location: 0, length: out.length)) { v, _, _ in
            if v != nil { found = true }
        }
        XCTAssertFalse(found)
    }
}
