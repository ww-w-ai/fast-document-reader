import XCTest
import AppKit
@testable import FastDocReader

/// A rule's STYLE — the thing all three office formats state and this reader used to drop, so a
/// dotted frame rendered as a solid one. `NSTextTableBlock` carries a width and a colour per edge
/// and nothing else, which is why the style rides on `GridTextTableBlock` and is painted there.
///
/// Two layers are checked, because either alone passes while the picture is wrong: the style
/// reaching the block (plumbing) and the pixels it produces (the picture). The pixel scan is the
/// only thing that can tell a dotted rule from a solid one — `width`/`borderColor` are identical
/// for both — and it is how invariant 74's cut alignment was measured too.
final class TableRuleStyleTests: XCTestCase {
    private let theme = RenderTheme.current(size: 16)
    private let pageWidth: CGFloat = 468

    private func table(topStyle: BorderLineStyle) -> OfficeBlock {
        var cell = Cell(blocks: [.paragraph(spans: [Span(text: "A")])])
        let side = BorderSide(width: 2, color: .black, style: topStyle)
        cell.edgeBorders = EdgeBorders(top: .drawn(side), left: .suppressed,
                                       bottom: .suppressed, right: .suppressed)
        return .table(rows: [[cell]], headerRows: 0, columnWidths: [], format: TableFormat())
    }

    private func block(_ out: NSAttributedString) throws -> GridTextTableBlock {
        var found: GridTextTableBlock?
        out.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            guard let ps = value as? NSParagraphStyle,
                  let b = ps.textBlocks.first as? GridTextTableBlock else { return }
            found = found ?? b
        }
        return try XCTUnwrap(found)
    }

    /// The block records only a NON-solid style, so every table of ordinary rules — markdown's
    /// included — keeps an empty dictionary and draws through `super` exactly as before.
    func testOnlyANonSolidStyleReachesTheBlock() throws {
        let dotted = try block(OfficeTextBuilder.build([table(topStyle: .dotted)], theme: theme,
                                                       columnWidth: pageWidth, pageContentWidth: pageWidth))
        XCTAssertEqual(dotted.edgeStyles[.minY], .dotted)
        XCTAssertTrue(dotted.hasStyledEdge)

        let solid = try block(OfficeTextBuilder.build([table(topStyle: .solid)], theme: theme,
                                                      columnWidth: pageWidth, pageContentWidth: pageWidth))
        XCTAssertTrue(solid.edgeStyles.isEmpty)
        XCTAssertFalse(solid.hasStyledEdge)
    }

    /// The picture. A dotted rule is drawn with GAPS along its length; a solid one is continuous.
    /// Counting dark→light transitions along the darkest painted row separates them without
    /// depending on where exactly the rule lands or how wide the dash pattern is.
    func testADottedRuleIsPaintedWithGapsAndASolidOneIsNot() throws {
        func darkRunCount(_ style: BorderLineStyle) throws -> Int {
            let out = OfficeTextBuilder.build([table(topStyle: style)], theme: theme,
                                              columnWidth: pageWidth, pageContentWidth: pageWidth)
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: pageWidth + 24, height: 120))
            tv.textContainerInset = NSSize(width: 12, height: 12)
            tv.textContainer?.containerSize = NSSize(width: pageWidth, height: .greatestFiniteMagnitude)
            tv.textContainer?.widthTracksTextView = false
            tv.backgroundColor = .white
            tv.textStorage?.setAttributedString(out)
            tv.layoutManager?.ensureLayout(for: tv.textContainer!)
            let rep = try XCTUnwrap(tv.bitmapImageRepForCachingDisplay(in: tv.bounds))
            tv.cacheDisplay(in: tv.bounds, to: rep)

            // The row carrying the most dark pixels IS the rule — the glyph "A" is one narrow column
            // and cannot outweigh a rule spanning the table's width.
            var best = (row: 0, dark: 0)
            for y in 0..<Int(rep.pixelsHigh) {
                var dark = 0
                for x in 0..<Int(rep.pixelsWide) {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.brightnessComponent < 0.5 {
                        dark += 1
                    }
                }
                if dark > best.dark { best = (y, dark) }
            }
            // Runs of dark pixels along that row: 1 for a continuous rule, many for a dashed one.
            var runs = 0, wasDark = false
            for x in 0..<Int(rep.pixelsWide) {
                let isDark = (rep.colorAt(x: x, y: best.row)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.5
                if isDark && !wasDark { runs += 1 }
                wasDark = isDark
            }
            return runs
        }
        let solidRuns = try darkRunCount(.solid)
        let dottedRuns = try darkRunCount(.dotted)
        XCTAssertLessThanOrEqual(solidRuns, 2, "a solid rule is one continuous run (the glyph may add one)")
        XCTAssertGreaterThan(dottedRuns, 5, "a dotted rule is drawn in pieces, not as one bar")
    }
}
