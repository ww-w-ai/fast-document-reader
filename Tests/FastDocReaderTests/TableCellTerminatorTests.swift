import XCTest
import AppKit
@testable import FastDocReader

/// A table cell must cost ONE attribute run, not two.
///
/// A cell is emitted as its content plus a terminating `"\n"`. That newline used to be appended with
/// NO attributes, so the paragraph-style loop in `TableBlockBuilder.build` handed it a fresh
/// `NSMutableParagraphStyle()` — default alignment, no font, no colour — an attribute dictionary that
/// can never equal the cell content's own. Every cell therefore cost TWO runs, and an attribute run
/// is what installing a string into a live text view is priced by: ~50 µs each, measured indifferent
/// to WHICH attributes the run carries (a 341k-character plain string with ONE run installs in 13 ms;
/// the same document at 108k runs takes 5,585 ms). On the 51,816-cell report that is 53,522 runs of
/// pure overhead — half of that document's runs, and it is paid by EVERY document with a table.
///
/// Measured through `OfficeTextBuilder.build` at a 700pt column, before → after this change:
///   • 2017년기준 시장구조조사.hwp   107,934 → 56,560 runs (−47.6%); 51,643 cell terminators, 2 left un-merged
///   • 2025 행정업무운영 편람.hwp     17,389 → 15,308 runs (−12.0%); 4,216 terminators, 73 left un-merged
///   • office fixtures               1,514 →    951 (tago-tables.odt), 1,243 → 797 (bus-headings.docx)
/// and the laid-out height of all ten of those documents is IDENTICAL to five decimal places
/// (433,489.48 pt and 312,098.54 pt on the two reports) — this buys runs, it does not move a pixel.
/// `testTheLaidOutGeometryIsUnchanged` is that claim as an assertion rather than a memory.
final class TableCellTerminatorTests: XCTestCase {
    private let theme = RenderTheme.current(size: 16)

    /// Every attribute run in `attr`, as (text, keys) — the shape these tests assert on.
    private func runs(in attr: NSAttributedString) -> [(text: String, attrs: [NSAttributedString.Key: Any])] {
        var out: [(String, [NSAttributedString.Key: Any])] = []
        attr.enumerateAttributes(in: NSRange(location: 0, length: attr.length)) { a, r, _ in
            out.append(((attr.string as NSString).substring(with: r), a))
        }
        return out
    }

    private func styledCell(_ text: String, size: CGFloat = 16,
                            alignment: NSTextAlignment = .right) -> TableBlockBuilder.CellContent {
        let ps = NSMutableParagraphStyle()
        ps.alignment = alignment
        ps.lineHeightMultiple = 1.4
        return TableBlockBuilder.CellContent(content: NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: ps,
        ]))
    }

    /// The unit itself: one styled cell = ONE run covering its text AND its terminator.
    func testAStyledCellCostsOneAttributeRunNotTwo() {
        let out = TableBlockBuilder.build(rows: [[styledCell("발간등록번호"), styledCell("11-1130000")]],
                                          headerRows: 0, theme: theme, width: 600)
        let cellRuns = runs(in: out).filter { $0.text.contains("발간") || $0.text.contains("11-1130000") }
        XCTAssertEqual(cellRuns.count, 2, "two cells must be two runs, not four — got \(runs(in: out).map(\.text))")
        for run in cellRuns {
            XCTAssertTrue(run.text.hasSuffix("\n"),
                          "the cell's terminator must be INSIDE its content's run, not a run of its own — got \(run.text.debugDescription)")
        }
    }

    /// …and the terminator carries the cell's own font/colour/paragraph style, which is WHY it merges.
    func testTheTerminatorCarriesTheCellsOwnAttributes() throws {
        let out = TableBlockBuilder.build(rows: [[styledCell("A")]], headerRows: 0, theme: theme, width: 400)
        let ns = out.string as NSString
        let newline = ns.range(of: "\n").location
        XCTAssertNotEqual(newline, NSNotFound)
        let atText = out.attributes(at: newline - 1, effectiveRange: nil)
        let atTerm = out.attributes(at: newline, effectiveRange: nil)
        XCTAssertEqual(atTerm[.font] as? NSFont, atText[.font] as? NSFont)
        XCTAssertEqual(atTerm[.foregroundColor] as? NSColor, atText[.foregroundColor] as? NSColor)
        let textStyle = try XCTUnwrap(atText[.paragraphStyle] as? NSParagraphStyle)
        let termStyle = try XCTUnwrap(atTerm[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(termStyle.alignment, textStyle.alignment,
                       "a fresh NSMutableParagraphStyle's .natural alignment is exactly what used to split this run")
        XCTAssertEqual(termStyle.lineHeightMultiple, textStyle.lineHeightMultiple)
        XCTAssertTrue(termStyle.textBlocks.first === textStyle.textBlocks.first,
                      "and it is still the SAME table block — the terminator belongs to its own cell")
    }

    /// THE TRAP, and what is really left of it. An EMPTY cell has no preceding character of its own:
    /// the character before its terminator is the PREVIOUS cell's last one. Copying "the character
    /// before" on the FINISHED string — which is how the throwaway measurement that produced the
    /// −49% figure did it — hands the empty cell the previous cell's `NSTextTableBlock` and merges
    /// two cells into one. Inside `build` that half is already prevented by the loop below the append,
    /// which re-stamps `ps.textBlocks = [block]` on every run of the cell regardless; MEASURED by
    /// mutation (inheriting from the result string instead of the cell left every block correct).
    /// What is NOT prevented, and what this test pins, is the cell's STYLE bleeding sideways: an empty
    /// cell would take its neighbour's font, colour and alignment, and its line height with them. An
    /// empty cell has no attributes of its own, so it keeps the bare terminator — byte-identical to
    /// before this change, and free, since a cell with no content is one run either way. The report
    /// has 383 wholly empty cells and the 600-page reference manual 2,674, so this is the common
    /// case, not a corner.
    func testAnEmptyCellKeepsItsOwnTableBlockAndNeverTheNeighbours() throws {
        let empty = TableBlockBuilder.CellContent(content: NSAttributedString())
        let out = TableBlockBuilder.build(rows: [[styledCell("A"), empty, styledCell("C")]],
                                          headerRows: 0, theme: theme, width: 600)
        // The empty cell's terminator carries NOTHING from its neighbours — not the block (which the
        // re-stamp would have covered anyway), and not the style, which nothing else covers.
        var emptyTerminators = 0
        out.enumerateAttributes(in: NSRange(location: 0, length: out.length)) { a, r, _ in
            guard (out.string as NSString).substring(with: r) == "\n",
                  let ps = a[.paragraphStyle] as? NSParagraphStyle,
                  let b = ps.textBlocks.first as? NSTextTableBlock, b.startingColumn == 1 else { return }
            emptyTerminators += 1
            XCTAssertEqual(a.count, 1, "an empty cell inherits no font or colour from its neighbour")
            XCTAssertNil(a[.font], "…specifically not the neighbour's font, which would set its line height")
            XCTAssertEqual(ps.alignment, .natural, "…nor the neighbour's alignment (the styled cells are .right)")
            XCTAssertEqual(ps.lineHeightMultiple, 0, "…nor the neighbour's line height")
        }
        XCTAssertEqual(emptyTerminators, 1, "the empty cell must still be present as its own cell")
        // Column 1 is the empty cell: find the newline run whose block starts at column 1.
        var emptyBlocks: [NSTextTableBlock] = []
        out.enumerateAttributes(in: NSRange(location: 0, length: out.length)) { a, r, _ in
            guard (out.string as NSString).substring(with: r) == "\n",
                  let b = (a[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock,
                  b.startingColumn == 1 else { return }
            emptyBlocks.append(b)
        }
        let block = try XCTUnwrap(emptyBlocks.first, "the empty cell must still be a cell of its own")
        XCTAssertEqual(block.startingColumn, 1)
        XCTAssertEqual(block.columnSpan, 1)
        // Three cells, three DISTINCT blocks — nothing was merged into a neighbour.
        var distinct = Set<ObjectIdentifier>()
        out.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: out.length)) { v, _, _ in
            if let b = (v as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock {
                distinct.insert(ObjectIdentifier(b))
            }
        }
        XCTAssertEqual(distinct.count, 3, "three cells must stay three blocks")
    }

    /// A cell ending in a PICTURE keeps the old bare terminator: an attachment's attributes describe
    /// a glyph, not a paragraph, and inheriting them would put the image's whole attribute set on the
    /// newline. The allow-list is what enforces this, so a cell that draws is left exactly as it was.
    func testATerminatorNeverInheritsAnAttachmentOrAnythingElseThatDraws() {
        let picture = NSTextAttachment()
        picture.image = NSImage(size: NSSize(width: 10, height: 10))
        let imageCell = TableBlockBuilder.CellContent(content: NSAttributedString(attachment: picture))

        let highlighted = NSAttributedString(string: "H", attributes: [
            .font: NSFont.systemFont(ofSize: 16), .backgroundColor: NSColor.systemYellow,
        ])
        let underlined = NSAttributedString(string: "U", attributes: [
            .font: NSFont.systemFont(ofSize: 16), .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        for (name, content) in [("attachment", imageCell.content), ("highlight", highlighted), ("underline", underlined)] {
            let out = TableBlockBuilder.build(rows: [[TableBlockBuilder.CellContent(content: content)]],
                                              headerRows: 0, theme: theme, width: 400)
            let ns = out.string as NSString
            let newline = ns.range(of: "\n").location
            let atTerm = out.attributes(at: newline, effectiveRange: nil)
            XCTAssertNil(atTerm[.attachment], "\(name): a terminator must never carry an attachment")
            XCTAssertNil(atTerm[.backgroundColor], "\(name): nor a highlight that would trail past the last glyph")
            XCTAssertNil(atTerm[.underlineStyle], "\(name): nor a rule that would trail past the last glyph")
            XCTAssertEqual(atTerm.count, 1, "\(name): it falls back to the bare terminator — paragraph style only")
        }
    }

    /// Invariant 37's shape for this change: it buys RUNS and moves NO geometry. Compares the built
    /// table against the same table with every terminator stripped back to the old bare newline —
    /// laid out through a real `NSLayoutManager`, in a container wider than the table so an overshoot
    /// cannot be clipped into looking exact (the trap `TableWidthIndependenceTests` records).
    ///
    /// Mutation-tested, and the results are the REASON this change is safe rather than the hope that
    /// it is. NOTHING put on the terminator moves this measurement: a `lineHeightMultiple` of 5 with
    /// 40pt paragraph spacing — nothing; a 96pt font — nothing; a whole attachment (what deleting
    /// `inheritableTerminatorAttributes` does) — nothing. Three reasons, in order: TextKit resolves a
    /// paragraph's metrics at its START, a trailing newline contributes no glyph of its own, and
    /// AppKit only builds an attachment glyph for U+FFFC, never for a newline that merely carries the
    /// attribute. So this test cannot fail on a terminator ATTRIBUTE, and saying so is the point of
    /// it — the allow-list is defended by `testATerminatorNeverInheritsAnAttachmentOrAnythingElseThatDraws`
    /// (which that same deletion does kill), not by geometry.
    ///
    /// The harness itself is live, so this is not a green assertion with an unreachable subject: the
    /// one plausible slip in this very function that DOES move geometry — appending the terminator
    /// twice — fails it immediately (192.0 against 188.0 on the first case alone).
    func testTheLaidOutGeometryIsUnchanged() {
        let picture = NSTextAttachment()
        picture.image = NSImage(size: NSSize(width: 40, height: 40))
        picture.bounds = NSRect(x: 0, y: 0, width: 40, height: 40)
        let pictureCell = TableBlockBuilder.CellContent(content: NSAttributedString(attachment: picture))
        let built = TableBlockBuilder.build(rows: [[pictureCell, styledCell("옆 칸")]],
                                            headerRows: 0, theme: theme, columnWidths: [300, 300], width: 600)
        let pictureNew = laidOut(built), pictureOld = laidOut(strippingTerminatorAttributes(built))
        XCTAssertEqual(pictureNew.height, pictureOld.height, accuracy: 0.001,
                       "a cell ending in a picture must lay out at exactly the height it always did — "
                       + "the image is laid out ONCE, for its own U+FFFC and nothing else")
        XCTAssertEqual(pictureNew.width, pictureOld.width, accuracy: 0.001)

        for size in [8.0, 12.0, 16.0, 24.0] as [CGFloat] {
            for multiple in [1.0, 2.0, 3.0] as [CGFloat] {
                let ps = NSMutableParagraphStyle()
                ps.lineHeightMultiple = multiple
                ps.paragraphSpacing = 9
                ps.paragraphSpacingBefore = 5
                let content = NSAttributedString(string: "셀 내용 that wraps a little", attributes: [
                    .font: NSFont.systemFont(ofSize: size), .paragraphStyle: ps, .foregroundColor: NSColor.textColor,
                ])
                let row = Array(repeating: TableBlockBuilder.CellContent(content: content), count: 3)
                let built = TableBlockBuilder.build(rows: [row, row, row], headerRows: 1, theme: theme,
                                                    columnWidths: [120, 200, 280], width: 600)
                let old = strippingTerminatorAttributes(built)
                let new = laidOut(built), was = laidOut(old)
                XCTAssertEqual(new.height, was.height, accuracy: 0.001,
                               "font \(size) × lineHeight \(multiple): the terminator's attributes must not move the height")
                XCTAssertEqual(new.width, was.width, accuracy: 0.001,
                               "font \(size) × lineHeight \(multiple): nor the width")
            }
        }
    }

    /// The same geometry claim on a REAL office table built through `OfficeTextBuilder` — a unit test
    /// on the builder cannot tell you the builder is reached (invariant 29), and the office path is
    /// the one that pays for this.
    func testARealOfficeTableIsReachedAndItsGeometryIsUnchanged() {
        let cells: [[Cell]] = [
            [Cell(blocks: [.paragraph(spans: [Span(text: "머리")])]),
             Cell(blocks: [.paragraph(spans: [Span(text: "Head")])])],
            [Cell(blocks: [.paragraph(spans: [Span(text: "값이 조금 긴 셀 내용")])]),
             Cell(blocks: [])],                       // an EMPTY cell, on the real path
        ]
        let out = OfficeTextBuilder.build([.table(rows: cells, headerRows: 1)],
                                          theme: theme, tableWidth: 600)
        let ns = out.string as NSString
        XCTAssertTrue(ns.contains("머리"), "the office table must actually be in the output")
        // Every non-empty cell's text run ends at its own terminator.
        var mergedCells = 0
        out.enumerateAttributes(in: NSRange(location: 0, length: out.length)) { a, r, _ in
            guard (a[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first is NSTextTableBlock else { return }
            let text = ns.substring(with: r)
            if text.count > 1, text.hasSuffix("\n") { mergedCells += 1 }
        }
        XCTAssertEqual(mergedCells, 3, "each of the three non-empty cells is one run ending in its own terminator")
        let new = laidOut(out), was = laidOut(strippingTerminatorAttributes(out))
        XCTAssertEqual(new.height, was.height, accuracy: 0.001)
        XCTAssertEqual(new.width, was.width, accuracy: 0.001)
    }

    /// A MARKDOWN table goes through the same builder and must gain the same way — measured through
    /// the real `MarkdownRenderer.render` path, not through `TableBlockBuilder` directly.
    func testAMarkdownTableCellIsAlsoOneRun() {
        let md = """
        | a | b |
        |---|---|
        | 1 | 2 |
        """
        let out = MarkdownRenderer.render(md, theme: theme)
        let ns = out.string as NSString
        var cellRuns = 0, bareTerminators = 0
        out.enumerateAttributes(in: NSRange(location: 0, length: out.length)) { a, r, _ in
            guard (a[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first is NSTextTableBlock else { return }
            let text = ns.substring(with: r)
            if text == "\n" { bareTerminators += 1 } else if text.hasSuffix("\n") { cellRuns += 1 }
        }
        XCTAssertEqual(cellRuns, 4, "each of the four markdown cells is ONE run, terminator included")
        XCTAssertEqual(bareTerminators, 0, "no markdown cell may still pay for a bare terminator run")
    }

    /// Invariant 48: re-solving the columns at the width the table was BUILT at must still move zero
    /// cells. The terminator now shares the content's paragraph style OBJECT, so `resizeTables`, which
    /// walks `.paragraphStyle` runs, sees one run per cell where it used to see two — the cell must
    /// still be found, and still not move.
    func testResizeTablesStillMovesNoCellAfterABuildAtTheSameWidth() {
        let row = [styledCell("A"), styledCell("긴 셀 내용이 들어간다"), TableBlockBuilder.CellContent(content: NSAttributedString())]
        let out = TableBlockBuilder.build(rows: [row, row], headerRows: 1, theme: theme,
                                          columnWidths: [100, 300, 200], width: 600)
        let storage = NSTextStorage(attributedString: out)
        var before: [CGFloat] = []
        var seen = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            guard let b = (v as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock,
                  seen.insert(ObjectIdentifier(b)).inserted else { return }
            before.append(b.contentWidth)
        }
        XCTAssertEqual(before.count, 6, "six cells must still be visible to a paragraph-style walk")
        TableBlockBuilder.resizeTables(in: storage, toWidth: 600)
        var after: [CGFloat] = []
        seen.removeAll()
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            guard let b = (v as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock,
                  seen.insert(ObjectIdentifier(b)).inserted else { return }
            after.append(b.contentWidth)
        }
        XCTAssertEqual(after, before, "re-solving at the build width must move no cell")
    }

    // MARK: helpers

    /// The OLD behaviour, reconstructed: every cell terminator back to a bare newline carrying only a
    /// fresh default paragraph style that keeps the cell's table block.
    private func strippingTerminatorAttributes(_ attr: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: attr)
        let ns = m.string as NSString
        for i in 0..<m.length where ns.character(at: i) == 10 {
            guard let ps = m.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle,
                  !ps.textBlocks.isEmpty else { continue }
            let fresh = NSMutableParagraphStyle()
            fresh.textBlocks = ps.textBlocks
            m.setAttributes([.paragraphStyle: fresh], range: NSRange(location: i, length: 1))
        }
        return m
    }

    private func laidOut(_ attr: NSAttributedString, containerSlack: CGFloat = 200) -> NSRect {
        let storage = NSTextStorage(attributedString: attr)
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: 600 + containerSlack, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        storage.addLayoutManager(lm); lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        return lm.usedRect(for: tc)
    }
}
