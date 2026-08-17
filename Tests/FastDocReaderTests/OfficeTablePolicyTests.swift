import XCTest
import AppKit
@testable import FastDocReader

/// The document's own answer to "may this table be cut at the foot of a page", from HWP's three-way
/// code to the attribute the paginator reads back off a completed layout.
///
/// Measured across 1,589 real Korean documents (`HwpTablePolicyProbeTests`): of 18,616 tables,
/// **5,878 (32%) forbid cutting**, 12,570 allow it at a row boundary and 168 anywhere — and 558 of
/// the documents contain at least one table that forbids it. Invariant 92 made breaking the reader's
/// default with no way to hear that; this is the hearing.
final class OfficeTablePolicyTests: XCTestCase {

    private let theme = RenderTheme.current(size: 16)

    private func built(_ policy: TablePageBreakPolicy?) -> NSAttributedString {
        var format = TableFormat()
        format.pageBreakPolicy = policy
        let cell = Cell(blocks: [.paragraph(spans: [Span(text: "x")])])
        return OfficeTextBuilder.build([.table(rows: [[cell]], headerRows: 0, columnWidths: [],
                                               format: format)], theme: theme)
    }

    private func keepsWhole(_ s: NSAttributedString) -> Bool {
        var found = false
        s.enumerateAttribute(MDAttr.tableKeepsWhole, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if (v as? Bool) == true { found = true }
        }
        return found
    }

    // MARK: the three codes

    func testHwpPageBreakCodesDecodeToThisReadersVocabulary() {
        XCTAssertEqual(HwpReader.tablePageBreakPolicy("none"), .never)
        XCTAssertEqual(HwpReader.tablePageBreakPolicy("row"), .atRowBoundary)
        XCTAssertEqual(HwpReader.tablePageBreakPolicy("cell"), .anywhere)
        // A parser that grows a fourth answer must read as "said nothing", never as a case that
        // happened to be first in the switch.
        XCTAssertNil(HwpReader.tablePageBreakPolicy("someFutureAnswer"))
        XCTAssertNil(HwpReader.tablePageBreakPolicy(""))
    }

    // MARK: only "never" is stamped

    func testATableForbiddenToSplitCarriesTheAttribute() {
        XCTAssertTrue(keepsWhole(built(.never)))
    }

    func testEveryOtherAnswerLeavesTheTableUnmarked() {
        XCTAssertFalse(keepsWhole(built(.atRowBoundary)))
        XCTAssertFalse(keepsWhole(built(.anywhere)))
        XCTAssertFalse(keepsWhole(built(nil)), "a table that said nothing must be unchanged")
    }

    /// Markdown tables run through the same builder and must be untouched by a field only the HWP
    /// reader ever populates.
    func testAMarkdownTableIsNeverMarked() {
        let out = MarkdownRenderer.render("| a | b |\n|---|---|\n| 1 | 2 |\n", theme: theme)
        XCTAssertFalse(keepsWhole(out))
    }

    // MARK: the heading switch is carried, and is not the same question as having a heading

    func testRepeatHeaderIsCarriedSeparatelyFromHeaderRows() {
        var format = TableFormat()
        format.repeatHeaderRows = true
        XCTAssertEqual(format.repeatHeaderRows, true)
        XCTAssertNil(TableFormat().repeatHeaderRows, "unstated stays unstated")
    }
}
