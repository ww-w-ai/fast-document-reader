import XCTest
import AppKit
@testable import FastDocReader

/// W2-border: what colour a table rule draws at, and — the part that is easy to get wrong —
/// which of invariant 47's THREE edge states each answer belongs to.
///
/// Word's `w:color="auto"` means "the application decides", and Word decides BLACK. This reader
/// decided `Palette.tableBorder`, a 16%-alpha warm grey, so an ordinary ruled contract table
/// rendered washed out beside its own text — and ragged, because the edges of the same table that
/// DID state a hex colour drew dark right next to it. Measured across three real reports (10,832
/// drawn cell edges): 2,184 of them are `auto` with no colour stated anywhere above them.
///
/// The fix is deliberately narrow, and these tests are the fence around that narrowness: only an
/// edge the DOCUMENT DREW, in a PAGED document, whose colour the document left to us, changes. An
/// edge nobody mentioned keeps the reader's own faint stand-in (it is our invention, not the
/// author's rule); a suppressed edge still draws nothing; a stated colour still wins; and nothing
/// non-paged moves at all.
final class TableRuleColourTests: XCTestCase {
    private let theme = RenderTheme.current(size: 16)
    private let pageWidth: CGFloat = 468        // 6.5in body — any positive value makes the build PAGED

    private func span(_ text: String) -> Span { Span(text: text) }

    private func build(_ blocks: [OfficeBlock], paged: Bool) -> NSAttributedString {
        OfficeTextBuilder.build(blocks, theme: theme, columnWidth: pageWidth,
                                pageContentWidth: paged ? pageWidth : nil)
    }

    /// The one placed cell of a single-cell table. A 1×1 grid is deliberate: every one of its four
    /// edges is a perimeter edge with no neighbour to contest it, so each edge's colour is purely
    /// this cell's own resolution — the thing under test — rather than the boundary-winner fold.
    private func onlyCell(_ out: NSAttributedString) throws -> NSTextTableBlock {
        var found: NSTextTableBlock?
        out.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            guard let ps = value as? NSParagraphStyle,
                  let block = ps.textBlocks.first as? NSTextTableBlock else { return }
            found = found ?? block
        }
        return try XCTUnwrap(found)
    }

    private func colours(_ block: NSTextTableBlock) -> [NSRectEdge: NSColor?] {
        var out: [NSRectEdge: NSColor?] = [:]
        for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
            out[edge] = block.width(for: .border, edge: edge) > 0 ? block.borderColor(for: edge) : nil
        }
        return out
    }

    private func table(_ cell: Cell, format: TableFormat = TableFormat()) -> OfficeBlock {
        .table(rows: [[cell]], headerRows: 0, columnWidths: [], format: format)
    }

    private func cellDrawing(_ side: BorderSide?) -> Cell {
        var cell = Cell(blocks: [.paragraph(spans: [span("A")])])
        if let side {
            cell.edgeBorders = EdgeBorders(top: .drawn(side), left: .drawn(side),
                                           bottom: .drawn(side), right: .drawn(side))
        }
        return cell
    }

    // MARK: The change itself

    /// A PAGED document's edge that the document DREW and left the colour of draws the authored
    /// rule. This is the whole point: `w:color="auto"` reaches `DocxReader` as a `nil` colour on a
    /// `.drawn` side, and the cascade's last resort is what decides how it looks.
    func testPagedDrawnEdgeWithNoStatedColourUsesTheAuthoredRule() throws {
        let out = build([table(cellDrawing(BorderSide(width: 1, color: nil)))], paged: true)
        let block = try onlyCell(out)
        for (edge, colour) in colours(block) {
            XCTAssertEqual(colour, Palette.tableBorderAuthored, "edge \(edge)")
            XCTAssertNotEqual(colour, Palette.tableBorder, "edge \(edge) must no longer be the faint tint")
        }
    }

    /// The authored rule is meaningfully darker than the faint tint — the defect was a VALUE, not a
    /// plumbing bug, so the value is asserted rather than left to whatever the token happens to say.
    /// Measured as the composite over a white page: the faint tint lands at ~223/255 (a barely-there
    /// grey) and the authored rule at ~85/255, a real dark rule, and one step back from Word's own
    /// pure black so the prose stays the darkest thing on the page.
    func testTheAuthoredRuleIsDarkAndTheFaintTintIsNot() {
        let light = NSAppearance(named: .aqua)!
        func composite(_ colour: NSColor) -> CGFloat {
            var out: CGFloat = 0
            light.performAsCurrentDrawingAppearance {
                let c = colour.usingColorSpace(.sRGB)!
                // over a white page
                out = (c.redComponent * c.alphaComponent + 1 * (1 - c.alphaComponent)) * 255
            }
            return out
        }
        XCTAssertEqual(composite(Palette.tableBorder), 223, accuracy: 2, "the faint tint is unchanged")
        XCTAssertEqual(composite(Palette.tableBorderAuthored), 85, accuracy: 2, "the authored rule is dark")
        // Still lighter than the reader's own body text — a rule that outweighs the prose it rules
        // inverts the hierarchy a reader wants.
        XCTAssertGreaterThan(composite(Palette.tableBorderAuthored), composite(Palette.text),
                             "the grid must not read heavier than the words")
    }

    // MARK: The three states stay straight

    /// invariant 47, state 3 — an edge the document NEVER MENTIONED, in a table that drew no box,
    /// still gets the reader's own faint stand-in even on a paged page. That rule is our invention;
    /// making it dark would assert a rule nobody asked for.
    func testPagedEdgeTheDocumentNeverMentionedKeepsTheFaintStandIn() throws {
        let out = build([table(cellDrawing(nil))], paged: true)      // no `edgeBorders` at all
        let block = try onlyCell(out)
        for (edge, colour) in colours(block) {
            XCTAssertEqual(block.width(for: .border, edge: edge), RenderTheme.tableBorderWidth, "edge \(edge) width")
            XCTAssertEqual(colour, Palette.tableBorder, "edge \(edge) is the reader's stand-in, not the author's rule")
        }
    }

    /// The two states inside ONE cell, which is the arrangement that actually reaches a reader: a
    /// docx cell that turns one edge on and says nothing about the other three (`tableDrewABox` is
    /// false, so those three fall back). The drawn edge goes dark; the three silent ones do not.
    func testOneCellCanCarryBothAnAuthoredRuleAndAFaintStandIn() throws {
        var cell = Cell(blocks: [.paragraph(spans: [span("A")])])
        cell.edgeBorders = EdgeBorders(bottom: .drawn(BorderSide(width: 1, color: nil)))
        let block = try onlyCell(build([table(cell)], paged: true))
        let byEdge = colours(block)
        XCTAssertEqual(byEdge[.maxY], Palette.tableBorderAuthored, "the edge the document drew")
        for edge in [NSRectEdge.minX, .maxX, .minY] {
            XCTAssertEqual(byEdge[edge], Palette.tableBorder, "edge \(edge) was never mentioned")
        }
    }

    /// invariant 47, state 2 — an edge the document explicitly turned OFF draws nothing, so there is
    /// no colour for this change to reach. (A single-cell table has no neighbour whose own rule
    /// could still win the boundary.)
    func testPagedSuppressedEdgeStillDrawsNothing() throws {
        var cell = Cell(blocks: [.paragraph(spans: [span("A")])])
        cell.edgeBorders = EdgeBorders(top: .suppressed, left: .suppressed,
                                       bottom: .suppressed, right: .suppressed)
        let block = try onlyCell(build([table(cell)], paged: true))
        for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
            XCTAssertEqual(block.width(for: .border, edge: edge), 0, "edge \(edge) must draw nothing")
        }
    }

    /// A colour the document DID state still wins — at every layer of the cascade. The change only
    /// replaces the last resort, so anything that stops the cascade earlier is untouched.
    func testAStatedColourStillWinsAtEveryLayer() throws {
        // the edge's own colour
        let own = try onlyCell(build([table(cellDrawing(BorderSide(width: 1, color: .systemRed)))], paged: true))
        XCTAssertEqual(colours(own)[.minX], .systemRed)
        // the cell's uniform colour, under an edge that stated none
        var uniform = cellDrawing(BorderSide(width: 1, color: nil))
        uniform.borderColor = .systemGreen
        XCTAssertEqual(colours(try onlyCell(build([table(uniform)], paged: true)))[.minX], .systemGreen)
        // the table's own default, under a cell that stated none
        var format = TableFormat()
        format.defaultBorderColor = .systemBlue
        let fromTable = try onlyCell(build([table(cellDrawing(BorderSide(width: 1, color: nil)), format: format)],
                                           paged: true))
        XCTAssertEqual(colours(fromTable)[.minX], .systemBlue)
        // the named table STYLE, under a cell and table that stated none
        var styled = cellDrawing(BorderSide(width: 1, color: nil))
        styled.styleBorderColor = .systemOrange
        XCTAssertEqual(colours(try onlyCell(build([table(styled)], paged: true)))[.minX], .systemOrange)
    }

    // MARK: Nothing non-paged moves

    /// The same two tables built NON-paged render exactly as they did before this split existed —
    /// the faint tint, for a drawn edge and an unmentioned one alike. Markdown's own tables are held
    /// to the same thing by `RenderThemeParityTests`; this covers the office document with no page
    /// width, which that harness does not reach.
    func testNonPagedTablesAreUnchanged() throws {
        let drawn = try onlyCell(build([table(cellDrawing(BorderSide(width: 1, color: nil)))], paged: false))
        let silent = try onlyCell(build([table(cellDrawing(nil))], paged: false))
        for block in [drawn, silent] {
            for (edge, colour) in colours(block) {
                XCTAssertEqual(colour, Palette.tableBorder, "edge \(edge)")
            }
        }
    }

    /// A markdown table goes through the same builder with `paged` defaulting to false — the
    /// parameter's default is what keeps every pre-existing call site inert, so it is asserted
    /// rather than assumed.
    func testTableBlockBuilderDefaultsToNonPaged() throws {
        var cell = TableBlockBuilder.CellContent(content: NSAttributedString(string: "A"))
        cell.edgeBorders = EdgeBorders(top: .drawn(BorderSide(width: 1, color: nil)))
        let out = TableBlockBuilder.build(rows: [[cell]], headerRows: 0, theme: theme)
        XCTAssertEqual(colours(try onlyCell(out))[.minY], Palette.tableBorder)
    }
}
