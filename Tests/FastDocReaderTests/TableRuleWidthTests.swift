import XCTest
import AppKit
@testable import FastDocReader

/// How WIDE a rule is drawn, as against how much room it is charged.
///
/// `NSTextTableBlock` draws a rule at the width it is given, and the width it is given has to be a
/// whole point or the geometry stops adding up (`TableBlockBuilder.laidOutBorderWidth`, invariant
/// 39). So every sub-point rule was handed up rounded and drew at a full point. Measured on a real
/// contract: it declares six widths — 0.28 / 0.34 / 1.13 / 1.42 / 1.70 / 1.98pt — and they came out
/// as two, so a 0.1mm hairline was painted as heavy as the box around the table and the document's
/// own hierarchy of weights was gone. That is what reads as a ragged grid.
///
/// The reserved band stays whole-point; the RULE is drawn at its declared width, centred in it.
final class TableRuleWidthTests: XCTestCase {
    private let theme = RenderTheme.current(size: 16)
    private let pageWidth: CGFloat = 468

    private func table(width: CGFloat) -> OfficeBlock {
        var cell = Cell(blocks: [.paragraph(spans: [Span(text: "A")])])
        let side = BorderSide(width: width, color: .black, style: .solid)
        cell.edgeBorders = EdgeBorders(top: .drawn(side), left: .suppressed,
                                       bottom: .suppressed, right: .suppressed)
        return .table(rows: [[cell]], headerRows: 0, columnWidths: [], format: TableFormat())
    }

    private func block(_ width: CGFloat) throws -> GridTextTableBlock {
        let out = OfficeTextBuilder.build([table(width: width)], theme: theme,
                                          columnWidth: pageWidth, pageContentWidth: pageWidth)
        var found: GridTextTableBlock?
        out.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            guard let ps = value as? NSParagraphStyle,
                  let b = ps.textBlocks.first as? GridTextTableBlock else { return }
            found = found ?? b
        }
        return try XCTUnwrap(found)
    }

    // MARK: plumbing — the geometry is unchanged, the declared width rides beside it

    func testASubPointRuleKeepsItsWholePointBandAndCarriesItsRealWidth() throws {
        let b = try block(0.3)
        XCTAssertEqual(b.width(for: .border, edge: .minY), 1.0, accuracy: 0.001,
                       "layout still reserves a whole point — nothing moves")
        XCTAssertEqual(try XCTUnwrap(b.declaredWidths[.minY]), 0.3, accuracy: 0.001)
        XCTAssertTrue(b.hasStyledEdge, "the block must draw this itself; super would fill the band")
    }

    /// A whole-point rule has nothing to correct, so it keeps the empty dictionary and the path every
    /// markdown table has always taken.
    func testAWholePointRuleIsLeftAlone() throws {
        let b = try block(2)
        XCTAssertTrue(b.declaredWidths.isEmpty)
        XCTAssertFalse(b.hasStyledEdge)
    }

    // MARK: the geometry — what is actually drawn inside the reserved band

    /// Two rules that share a reserved band must not draw the same bar. 0.3pt and 0.9pt both reserve
    /// one point, so comparing widths whose BANDS already differ proves nothing — it passes with the
    /// defect still in place, which is what a first version of this test did.
    func testTwoRulesSharingABandDrawDifferentBars() throws {
        let thin = try block(0.3)
        let thick = try block(0.9)
        let band = NSRect(x: 0, y: 0, width: 100, height: 1)      // the whole-point band both reserve
        let thinBar = thin.rule(in: band, edge: .minY)
        let thickBar = thick.rule(in: band, edge: .minY)
        XCTAssertEqual(thinBar.height, 0.3, accuracy: 0.001)
        XCTAssertEqual(thickBar.height, 0.9, accuracy: 0.001)
        // Centred in the band, so the rule stays on the boundary layout charged for.
        XCTAssertEqual(thinBar.midY, band.midY, accuracy: 0.001)
        XCTAssertEqual(thinBar.width, band.width, accuracy: 0.001, "only the thickness changes")
    }

    /// A rule the document declared is never drawn away to nothing: below about a quarter point it
    /// stops being a line on any display and reads as a MISSING rule rather than a fine one.
    func testAnAlmostInvisibleRuleKeepsAFloor() throws {
        let b = try block(0.05)
        XCTAssertEqual(b.rule(in: NSRect(x: 0, y: 0, width: 100, height: 1), edge: .minY).height,
                       0.25, accuracy: 0.001)
    }

    /// A whole-point rule fills its band exactly as it always did.
    func testAWholePointRuleFillsItsBand() throws {
        let b = try block(2)
        let band = NSRect(x: 0, y: 0, width: 100, height: 2)
        XCTAssertEqual(b.rule(in: band, edge: .minY), band)
    }
}
