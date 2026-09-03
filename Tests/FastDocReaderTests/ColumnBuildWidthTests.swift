import XCTest
import AppKit
@testable import FastDocReader

/// Invariant 144 — a block under a multi-column declaration is BUILT at its column's width.
///
/// `colW` already reached the tab stops, the pictures and the grid, but the two things that decide
/// how wide a block actually DRAWS did not follow it: a prose line was still wrapped by the text
/// container, and a table was still solved across `tableWidth`, the page-wide reading column. Both
/// then drew straight across the neighbouring column.
final class ColumnBuildWidthTests: XCTestCase {

    private let twoColumns = OfficeColumnLayout(count: 2, spacing: 20)

    private func declaring(_ layout: OfficeColumnLayout?, text: String) -> OfficeBlock {
        var span = Span(text: text)
        span.columnLayout = layout
        return .paragraph(spans: [span])
    }

    private func cell(_ text: String) -> Cell {
        Cell(blocks: [.paragraph(spans: [Span(text: text)])])
    }

    /// The declaration's own paragraph and every paragraph after it narrow to the column.
    func testProseNarrowsToTheColumn() {
        let blocks = [declaring(twoColumns, text: "first"),
                      declaring(nil, text: "second")]
        let out = OfficeTextBuilder.build(blocks, theme: .current(size: 11), columnWidth: 400,
                                          pageContentWidth: 400)
        // 400 wide, two columns, 20 apart → each column is 190.
        let expected = -(400 - 190.0)
        for location in [0, out.length - 2] {
            let ps = out.attribute(.paragraphStyle, at: location,
                                   effectiveRange: nil) as? NSParagraphStyle
            XCTAssertEqual(ps?.tailIndent ?? 0, expected, accuracy: 0.5,
                           "a line at \(location) still wraps at the page width")
        }
    }

    /// A single-column document is byte-identical — no tail indent invented (invariant 37).
    func testASingleColumnDocumentIsUntouched() {
        let plain = [declaring(nil, text: "first"), declaring(nil, text: "second")]
        let out = OfficeTextBuilder.build(plain, theme: .current(size: 11), columnWidth: 400,
                                          pageContentWidth: 400)
        let ps = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(ps?.tailIndent ?? 0, 0)
        // And a declaration of ONE column is a declaration to STOP, not to narrow.
        let stopped = [declaring(OfficeColumnLayout(count: 1), text: "first")]
        let out2 = OfficeTextBuilder.build(stopped, theme: .current(size: 11), columnWidth: 400,
                                           pageContentWidth: 400)
        let ps2 = out2.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(ps2?.tailIndent ?? 0, 0)
    }

    /// The grid is capped to the column, and the cap TRAVELS with the table so the next reflow
    /// (`TableBlockBuilder.resizeTables`, which re-solves against the full reading column) cannot
    /// stretch it back out across its neighbour.
    func testATableUnderAColumnDeclarationIsCappedToIt() {
        let blocks: [OfficeBlock] = [
            declaring(twoColumns, text: "intro"),
            .table(rows: [[cell("a"), cell("b")]], headerRows: 0),
        ]
        let out = OfficeTextBuilder.build(blocks, theme: .current(size: 11), columnWidth: 400,
                                          pageContentWidth: 400, tableWidth: 390)
        var table: GridTextTable?
        out.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: out.length)) { v, _, stop in
            if let block = (v as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock,
               let grid = block.table as? GridTextTable {
                table = grid
                stop.pointee = true
            }
        }
        let grid = try? XCTUnwrap(table)
        // 190 (the column) minus the 10 points `tableWidth` already took off the page width.
        XCTAssertEqual(grid?.maxWidth ?? 0, 180, accuracy: 0.5)
        XCTAssertLessThanOrEqual(grid?.edges(forWidth: 390).last ?? 0, 181,
                                 "a later reflow at the full column stretched the table back out")
    }

    /// A table in a single-column document keeps the ceiling it always had: its own authored width,
    /// or none at all.
    func testATableOutsideAColumnRunKeepsItsOwnCeiling() {
        let blocks: [OfficeBlock] = [.table(rows: [[cell("a"), cell("b")]], headerRows: 0)]
        let out = OfficeTextBuilder.build(blocks, theme: .current(size: 11), columnWidth: 400,
                                          pageContentWidth: 400, tableWidth: 390)
        var table: GridTextTable?
        out.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: out.length)) { v, _, stop in
            if let block = (v as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock,
               let grid = block.table as? GridTextTable {
                table = grid
                stop.pointee = true
            }
        }
        XCTAssertNil(table?.maxWidth, "a single-column table was given a ceiling it never had")
    }
}
