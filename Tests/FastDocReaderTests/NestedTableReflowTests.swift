import XCTest
import AppKit
@testable import FastDocReader

/// A nested grid follows its cell through a reflow. `resizeTables` runs one pass per nesting depth:
/// the outermost tables at the reading column, then each inner table at the content width its
/// parent cell settled on — the width the inner grid was built at (invariant 168).
final class NestedTableReflowTests: XCTestCase {

    private let theme = RenderTheme.current(size: 16)

    private func span(_ t: String) -> Span { Span(text: t) }

    private func nestedDocument() -> NSAttributedString {
        let inner: OfficeBlock = .table(rows: [[Cell(spans: [span("Nested")]), Cell(spans: [span("Twice")])]], headerRows: 0)
        let outer = Cell(blocks: [.paragraph(spans: [span("Outer")]), inner, .paragraph(spans: [span("After")])])
        return OfficeTextBuilder.build([.table(rows: [[outer, Cell(spans: [span("Right")])]], headerRows: 0)],
                                       theme: theme, columnWidth: 400)
    }

    private func box(_ b: NSTextTableBlock) -> CGFloat {
        b.contentWidth + b.width(for: .padding, edge: .minX) + b.width(for: .padding, edge: .maxX)
            + b.width(for: .border, edge: .minX) + b.width(for: .border, edge: .maxX)
    }

    private func blocks(_ storage: NSAttributedString, at text: String) -> [NSTextTableBlock] {
        let at = (storage.string as NSString).range(of: text).location
        return (storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?
            .textBlocks.compactMap { $0 as? NSTextTableBlock } ?? []
    }

    func testAnInnerGridIsReSolvedAtItsParentCellsNewWidth() throws {
        let storage = NSTextStorage(attributedString: nestedDocument())
        let before = blocks(storage, at: "Nested")
        XCTAssertEqual(before.count, 2)
        let outerBefore = before[0].contentWidth
        let moved = TableBlockBuilder.resizeTables(in: storage, toWidth: 800)
        XCTAssertGreaterThan(moved, 0, "a wider column moves the outer cells")
        let nested = blocks(storage, at: "Nested")
        let twice = blocks(storage, at: "Twice")
        XCTAssertGreaterThan(nested[0].contentWidth, outerBefore + 50, "the outer cell widened")
        XCTAssertEqual(box(nested[1]) + box(twice[1]), nested[0].contentWidth, accuracy: 2,
                       "the inner grid fills the outer cell's NEW content width, not its build width")
    }

    func testAReflowAtTheBuildWidthMovesNoInnerCell() {
        let storage = NSTextStorage(attributedString: nestedDocument())
        let before = blocks(storage, at: "Nested").map(\.contentWidth)
        _ = TableBlockBuilder.resizeTables(in: storage, toWidth: 400)
        XCTAssertEqual(blocks(storage, at: "Nested").map(\.contentWidth), before)
    }
}
