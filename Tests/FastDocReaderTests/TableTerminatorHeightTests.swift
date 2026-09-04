import XCTest
import AppKit
@testable import FastDocReader

/// The text after a table starts at the table's bottom edge, not one or two blank lines below it.
///
/// A table is closed by two paragraph separators — `TableBlockBuilder.build`'s own and
/// `OfficeTextBuilder.appendTable`'s — and a separator that is a paragraph of its OWN, left bare,
/// is laid out at AppKit's default font: a 14pt line each, 28pt below every table, which no source
/// format draws. Measured on the 388-table reference manual as 646 such lines (invariant 161).
/// The separators stay (they are what keeps the next block out of the last cell); their line boxes
/// must not.
final class TableTerminatorHeightTests: XCTestCase {

    private let theme = RenderTheme.current(size: 16)

    private func build(_ after: OfficeBlock = .paragraph(spans: [Span(text: "표 다음 문단")])) -> NSAttributedString {
        let cells: [[Cell]] = [
            [Cell(blocks: [.paragraph(spans: [Span(text: "머리")])]),
             Cell(blocks: [.paragraph(spans: [Span(text: "Head")])])],
            [Cell(blocks: [.paragraph(spans: [Span(text: "값")])]),
             Cell(blocks: [])],
        ]
        return OfficeTextBuilder.build([.paragraph(spans: [Span(text: "표 앞 문단")]),
                                        .table(rows: cells, headerRows: 1),
                                        after],
                                       theme: theme, tableWidth: 600)
    }

    private func fragments(of attr: NSAttributedString) -> [(rect: NSRect, range: NSRange)] {
        let storage = NSTextStorage(attributedString: attr)
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        storage.addLayoutManager(lm); lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        var out: [(NSRect, NSRange)] = []
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, _, _, gr, _ in
            out.append((rect, lm.characterRange(forGlyphRange: gr, actualGlyphRange: nil)))
        }
        return out
    }

    func testTheTwoSeparatorsThatCloseATableHaveNoLineBoxOfTheirOwn() throws {
        let out = build()
        let ns = out.string as NSString
        let frags = fragments(of: out)
        let after = ns.range(of: "표 다음 문단")
        let lastCell = ns.range(of: "값")
        let afterFrag = try XCTUnwrap(frags.first { NSLocationInRange(after.location, $0.range) })
        let cellFrag = try XCTUnwrap(frags.first { NSLocationInRange(lastCell.location, $0.range) })
        let between = frags.filter { $0.range.location > cellFrag.range.location && $0.range.location < after.location
                                     && !NSLocationInRange($0.range.location, lastCell) }
        // Both separators are laid out — they are still paragraphs — but each is under a point tall.
        let separators = between.filter { ns.substring(with: $0.range) == "\n" && $0.rect.height < 1 }
        XCTAssertGreaterThanOrEqual(separators.count, 2,
                                    "the two closing separators must each be a sub-point line box, got \(between.map { ($0.rect.height, ns.substring(with: $0.range)) })")
        // And the next paragraph therefore starts within the cell's own bottom padding of the last
        // row, not a blank line or two below it. Padding is at most the theme's cell padding on each
        // side; the old bare separators added 28pt on top of that.
        let gap = afterFrag.rect.minY - cellFrag.rect.maxY
        XCTAssertLessThan(gap, 12, "text after a table starts at its bottom edge, gap was \(gap)pt")
    }

    func testATableThatEndsTheDocumentIsStillClosedAndStillCollapsed() {
        let out = build(.paragraph(spans: []))
        // Nothing after the table can be pulled into it: the string still ends in a separator.
        XCTAssertTrue(out.string.hasSuffix("\n"))
        let frags = fragments(of: out)
        let tail = frags.suffix(3).map(\.rect.height)
        XCTAssertTrue(tail.contains { $0 < 1 }, "the closing separators are collapsed even at the end, heights \(tail)")
    }

    /// The collapse must not reach INTO the table: a cell's own terminator keeps the cell's line
    /// height, or the last row would shrink to nothing.
    func testTheCollapseStopsAtTheLastCell() throws {
        let out = build()
        let ns = out.string as NSString
        let lastCell = ns.range(of: "값")
        let ps = try XCTUnwrap(out.attribute(.paragraphStyle, at: lastCell.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertTrue(ps.textBlocks.last is NSTextTableBlock)
        XCTAssertNotEqual(ps.maximumLineHeight, OfficeTextBuilder.collapsedTerminatorLineHeight)
        // The empty cell's terminator, too — it is inside a text block and is not a closing separator.
        var inBlock = 0, collapsed = 0
        out.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: out.length)) { v, _, _ in
            guard let p = v as? NSParagraphStyle else { return }
            if p.textBlocks.last is NSTextTableBlock { inBlock += 1 }
            if p.maximumLineHeight == OfficeTextBuilder.collapsedTerminatorLineHeight { collapsed += 1 }
        }
        XCTAssertGreaterThanOrEqual(inBlock, 4, "every cell still carries its block")
        XCTAssertEqual(collapsed, 1, "exactly one collapsed run: the two separators, coalesced")
    }
}
