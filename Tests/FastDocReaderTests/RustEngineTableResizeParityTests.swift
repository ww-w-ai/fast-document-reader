import XCTest
import AppKit
@testable import FastDocReader

/// S5B2a-03: compares the host's own resize arithmetic (`TableBlockBuilder.resizeTables`, still
/// the one production writes) against the engine's answer for the SAME table — never the reverse.
/// Only ever run in a build that links the Rust engine (`FMD_RUST_ENGINE=1`); the production
/// reflow path this test walks alongside is completely untouched (`OfficeRenderLatencyTests`
/// covers that no cell moved and the 62-table latency did not regress).
final class RustEngineTableResizeParityTests: XCTestCase {
    private let theme = RenderTheme.current(size: 16)

    /// One resized table's payload, gathered the SAME way `resizeTables` itself reads a block: the
    /// shared grid inputs off the table object once, and per touched cell its span, padding, and
    /// border. Returns the host's own already-written `contentWidth` for every cell alongside the
    /// payload, so the caller can drive the engine with the identical inputs and compare answers
    /// without a second traversal that could read something different.
    private struct Gathered {
        var columnProportions: [CGFloat] = []
        var outerMarginLeft: CGFloat = 0
        var outerMarginRight: CGFloat = 0
        var maxWidth: CGFloat?
        var cells: [RustEngineTableResize.Cell] = []
        var hostWidths: [CGFloat] = []
    }

    private func gather(_ attr: NSAttributedString, width: CGFloat) -> Gathered {
        let storage = NSTextStorage(attributedString: attr)
        TableBlockBuilder.resizeTables(in: storage, toWidth: width)
        var result = Gathered()
        var sawTable = false
        storage.enumerateAttribute(
            NSAttributedString.Key.paragraphStyle, in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            guard let ps = value as? NSParagraphStyle,
                  let block = ps.textBlocks.first as? NSTextTableBlock,
                  let table = block.table as? GridTextTable, !table.columnProportions.isEmpty
            else { return }
            if !sawTable {
                result.columnProportions = table.columnProportions
                result.outerMarginLeft = table.outerMarginLeft
                result.outerMarginRight = table.outerMarginRight
                result.maxWidth = table.maxWidth
                sawTable = true
            }
            result.cells.append(RustEngineTableResize.Cell(
                startingColumn: block.startingColumn, columnSpan: block.columnSpan,
                padLeft: block.width(for: .padding, edge: .minX),
                padRight: block.width(for: .padding, edge: .maxX),
                borderLeft: block.width(for: .border, edge: .minX),
                borderRight: block.width(for: .border, edge: .maxX)))
            result.hostWidths.append(block.contentWidth)
        }
        XCTAssertTrue(sawTable, "the table must actually be reached before a parity check means anything")
        return result
    }

    private func assertParity(_ attr: NSAttributedString, width: CGFloat,
                              file: StaticString = #filePath, line: UInt = #line) {
        let g = gather(attr, width: width)
        let engineWidths = RustEngineTableResize.targetWidths(
            columnProportions: g.columnProportions, availableWidth: width,
            outerMarginLeft: g.outerMarginLeft, outerMarginRight: g.outerMarginRight,
            maxWidth: g.maxWidth, cells: g.cells)
        guard let engineWidths else {
            XCTFail("engine refused a payload the host itself just answered", file: file, line: line)
            return
        }
        XCTAssertEqual(engineWidths.count, g.hostWidths.count, file: file, line: line)
        for (i, (host, engine)) in zip(g.hostWidths, engineWidths).enumerated() {
            XCTAssertEqual(engine, host, accuracy: 0.5,
                           "cell \(i): host=\(host) engine=\(engine)", file: file, line: line)
        }
    }

    /// A plain 3-column table, no merges — the simplest shape the payload has to answer for.
    func testThreeEqualColumnsAgreeWithTheHostsOwnAnswer() {
        let row = (0..<3).map { col in Cell(blocks: [.paragraph(spans: [Span(text: "c\(col)")])]) }
        let attr = OfficeTextBuilder.build([.table(rows: [row, row], headerRows: 0, format: TableFormat())],
                                           theme: theme, tableWidth: 480)
        assertParity(attr, width: 480)
    }

    /// A table with a genuine column-span merge — the shape that actually exercises the payload's
    /// `startingColumn`/`columnSpan` clamp (`min(_, ncol)`), which a table with no merges never
    /// reaches at all.
    func testAMergedCellAgreesWithTheHostsOwnAnswer() {
        let merged = Cell(blocks: [.paragraph(spans: [Span(text: "merged")])], colSpan: 2)
        let plain = Cell(blocks: [.paragraph(spans: [Span(text: "c")])])
        let rowWithMerge = [merged, plain]
        let plainRow = [plain, plain, plain]
        let attr = OfficeTextBuilder.build(
            [.table(rows: [rowWithMerge, plainRow], headerRows: 0, format: TableFormat())],
            theme: theme, tableWidth: 600)
        assertParity(attr, width: 600)
    }

    /// A declared outer margin — the grid's own starting edge moves, not just its width, so a
    /// payload that forgot `outerMarginLeft`/`outerMarginRight` would still pass the equal-column
    /// case above but diverge here.
    func testAnOuterMarginAgreesWithTheHostsOwnAnswer() {
        let row = (0..<2).map { col in Cell(blocks: [.paragraph(spans: [Span(text: "c\(col)")])]) }
        var format = TableFormat()
        format.outerMargin = EdgePadding(top: nil, left: 30, bottom: nil, right: 15)
        let attr = OfficeTextBuilder.build([.table(rows: [row, row], headerRows: 0, format: format)],
                                           theme: theme, tableWidth: 500)
        assertParity(attr, width: 500)
    }
}
