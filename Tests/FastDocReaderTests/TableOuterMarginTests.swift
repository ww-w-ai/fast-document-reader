import XCTest
import AppKit
@testable import FastDocReader

/// An HWP table declares its own OUTER margin (`Table.outer_margin_left/right/top/bottom`) — the
/// gap between the table OBJECT and what surrounds it, distinct from a cell's own padding (inside
/// the border) and from `TableFormat.defaultPadding` (the table-wide cell-padding fallback).
/// `HwpReader` decodes all FOUR edges onto `TableFormat.outerMargin`, but only HALF of them are
/// ever applied to the built table.
///
/// HORIZONTAL (left/right) is expressed purely as GEOMETRY: `GridTextTable.edges(forWidth:)`
/// narrows the grid every column is solved across and shifts its starting edge to `outerMarginLeft`
/// — never a second `NSTextBlock` `.margin` box on the perimeter cells. That second box WAS the
/// first shape this shipped with, and it was measured wrong: AppKit charges a block's
/// margin/border/padding/content OUT OF the column's own proportion-derived slot rather than
/// growing the table to accommodate them, so a cell whose content width was ALREADY computed from
/// the narrowed grid lost the same margin a second time — 74,513 glyphs (1.4%) missing from a real
/// 545-page manual, confirmed through `--pdf`, with `--extract` proving the text still EXISTS in
/// the model (clipped in LAYOUT, not dropped from the document).
///
/// VERTICAL (top/bottom) is CARRIED ON THE MODEL AND NEVER DRAWN — the same shape invariant 97
/// already names for six of a char shape's sixteen decorations. A `.minY`/`.maxY` margin box on the
/// first/last row was ALSO tried, and measured far worse than the horizontal defect: on the same
/// real manual, 38 pages lost glyphs and several — 105, 118, 120, 174, 177, 185 among them —
/// rendered COMPLETELY EMPTY, because a table crossing a page boundary lands its first/last row at
/// the top or bottom of a SHEET, where the page-band reservation, the page-break arithmetic and the
/// table's own mid-page splitting (`GridTextTableBlock`, invariants 61/64/72/96) all read that same
/// cell's box geometry — a margin box is not a shape that machinery was built to absorb. Re-adopting
/// it needs new evidence against those four invariants first, not a retry of this shape.
///
/// A consequence worth stating plainly about the HALF that ships: it does NOT visibly shift the
/// table's own POSITION — confirmed by grep, every reader of `edges(forWidth:)`'s return value
/// (`build`, `resizeTables`) consumes it as a DIFFERENCE (`edges[c1] - edges[c0]`), never `edges[0]`
/// itself, and AppKit positions a table's columns from `columnProportions` against the container's
/// own line width, which this array never touches. A cell paragraph's own `headIndent`/
/// `tailIndent` (the mechanism `applyParagraphFormat` uses for ordinary text) was also measured and
/// found to have NO effect on an `NSTextTableBlock`'s position at all. So the table renders
/// NARROWER by the declared horizontal margin, in place, rather than inset from the left — the
/// honest shape of what AppKit's primitives can express here, not a compromise this suite is hiding.
final class TableOuterMarginTests: XCTestCase {
    private let theme = RenderTheme.current(size: 16)

    private func build(margin: EdgePadding?, cellText: String = "c",
                       target: CGFloat = 600, ncol: Int = 2) -> (attr: NSAttributedString, block: NSTextTableBlock) {
        let row = (0..<ncol).map { col -> Cell in
            Cell(blocks: [.paragraph(spans: [Span(text: cellText.isEmpty ? "c\(col)" : cellText)])])
        }
        var format = TableFormat()
        format.outerMargin = margin
        let attr = OfficeTextBuilder.build([.table(rows: [row, row], headerRows: 0, format: format)],
                                           theme: theme, tableWidth: target)
        var firstBlock: NSTextTableBlock?
        attr.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: attr.length)) { value, _, stop in
            guard let ps = value as? NSParagraphStyle, let block = ps.textBlocks.first as? NSTextTableBlock
            else { return }
            firstBlock = block
            stop.pointee = true
        }
        return (attr, firstBlock!)
    }

    private func laidOutRect(margin: EdgePadding?, target: CGFloat = 600, ncol: Int = 2) -> NSRect {
        let (attr, _) = build(margin: margin, target: target, ncol: ncol)
        let storage = NSTextStorage(attributedString: attr)
        let lm = NSLayoutManager()
        // Deliberately far wider than the target — a container sized AT the target silently CLIPS
        // an overshoot into looking exact (invariant 50's own trap).
        let tc = NSTextContainer(size: NSSize(width: target + 200, height: 4000))
        tc.lineFragmentPadding = 0
        storage.addLayoutManager(lm); lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        return lm.usedRect(for: tc)
    }

    // MARK: horizontal — this is the axis that ships

    /// No declared margin renders byte-identically to before this existed — `nil` costs nothing,
    /// same discipline as every other `TableFormat` field.
    func testNoDeclaredMarginLaysOutExactlyAsBefore() {
        let bare = laidOutRect(margin: nil)
        XCTAssertEqual(bare.width, 600, accuracy: 0.01)
        XCTAssertEqual(bare.origin.x, 0, accuracy: 0.01)
    }

    /// LEFT/RIGHT narrow the table's own laid-out box by EXACTLY the two margins, in place — the
    /// requested width was 600, the declared margins total 70, and the table now measures 530: one
    /// subtraction, not the two the original defect charged. `firstCellX` does NOT move — see this
    /// file's own header for why a real position shift is not something these primitives express.
    func testLeftAndRightMarginNarrowTheLaidOutBoxByExactlyTheDeclaredAmount() {
        let margin = EdgePadding(top: nil, left: 50, bottom: nil, right: 20)
        let withMargin = laidOutRect(margin: margin, target: 600)
        let bare = laidOutRect(margin: nil, target: 600)
        XCTAssertEqual(withMargin.width, bare.width - 70, accuracy: 0.01,
                       "50 + 20 declared — the box must narrow by exactly that, once")
    }

    /// A margin declared on only ONE horizontal edge leaves the other narrowing proportional to
    /// itself alone — `nil` per edge, not a whole-format on/off switch.
    func testASingleDeclaredHorizontalEdgeNarrowsByOnlyItsOwnAmount() {
        let leftOnly = EdgePadding(top: nil, left: 40, bottom: nil, right: nil)
        let withMargin = laidOutRect(margin: leftOnly)
        let bare = laidOutRect(margin: nil)
        XCTAssertEqual(withMargin.width, bare.width - 40, accuracy: 0.01,
                       "the one declared edge must still narrow the box")
    }

    /// `resizeTables` re-solving the SAME table at the SAME width must not touch a single cell —
    /// invariant 48's own gate ("cells the resize pass still moves after a render: 0 of N"),
    /// applied to a table that declares a horizontal outer margin.
    func testResizeAtTheSameWidthMovesNoCell() {
        let margin = EdgePadding(top: nil, left: 25, bottom: nil, right: 25)
        let row = (0..<3).map { col in Cell(blocks: [.paragraph(spans: [Span(text: "c\(col)")])]) }
        var format = TableFormat()
        format.outerMargin = margin
        let attr = OfficeTextBuilder.build([.table(rows: [row, row], headerRows: 0, format: format)],
                                           theme: theme, tableWidth: 600)
        let storage = NSTextStorage(attributedString: attr)
        var before: [ObjectIdentifier: CGFloat] = [:]
        var reached = 0
        storage.enumerateAttribute(NSAttributedString.Key.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let ps = value as? NSParagraphStyle,
                  let block = ps.textBlocks.first as? NSTextTableBlock else { return }
            before[ObjectIdentifier(block)] = block.contentWidth
            reached += 1
        }
        XCTAssertGreaterThan(reached, 0, "the table must actually be reached before the parity check means anything")
        TableBlockBuilder.resizeTables(in: storage, toWidth: 600)
        var moved = 0
        storage.enumerateAttribute(NSAttributedString.Key.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let ps = value as? NSParagraphStyle,
                  let block = ps.textBlocks.first as? NSTextTableBlock else { return }
            if let was = before[ObjectIdentifier(block)], abs(was - block.contentWidth) > 0.5 { moved += 1 }
        }
        XCTAssertEqual(moved, 0, "resizeTables must re-derive the identical margined grid, not a different one")
    }

    /// A zero-value `EdgePadding` field is not a declaration — mirrors `HwpReader`'s own decode
    /// contract (a declared 0 and an absent key are indistinguishable at the wire, and both must
    /// leave the laid-out box exactly as undeclared).
    func testAllZeroHorizontalMarginLaysOutIdenticallyToNil() {
        let zero = EdgePadding(top: nil, left: 0, bottom: nil, right: 0)
        let withZero = laidOutRect(margin: zero)
        let bare = laidOutRect(margin: nil)
        XCTAssertEqual(withZero.width, bare.width, accuracy: 0.01)
    }

    /// THE DEFECT'S OWN SHAPE, caught directly: a horizontal margin must be subtracted from a
    /// cell's content width EXACTLY ONCE (inside the narrowed grid `edges(forWidth:)` solves), and
    /// no `NSTextBlock` `.margin` box may ALSO sit on the perimeter cell's `.minX`/`.maxX` — that
    /// second box is what charged the same margin twice and clipped real text. A test that only
    /// compares the overall laid-out BOX (as this file's earlier draft did) cannot see this: the box
    /// came back to exactly the requested width either way, because the double subtraction and the
    /// margin box's own addition net out arithmetically — the box was never the thing that
    /// overflowed, the CELL'S OWN CONTENT WIDTH was too narrow inside it, whatever the box read.
    /// Verified by mutation before this shipped: reintroducing the `.minX`/`.maxX` margin stamping
    /// makes this test fail immediately (`block.width(for: .margin, edge: .minX)` reads 50, not 0).
    func testHorizontalMarginChargesCellContentWidthExactlyOnce() {
        let margin = EdgePadding(top: nil, left: 50, bottom: nil, right: 20)
        let (_, block) = build(margin: margin, target: 600, ncol: 1)
        // NO `.margin` box on either horizontal edge — the regression's own fingerprint.
        XCTAssertEqual(block.width(for: .margin, edge: .minX), 0, accuracy: 0.01,
                       "a horizontal margin box double-charges the grid's own narrowing")
        XCTAssertEqual(block.width(for: .margin, edge: .maxX), 0, accuracy: 0.01,
                       "a horizontal margin box double-charges the grid's own narrowing")
        // Content width must be derived from ONE subtraction: (600 - 50 - 20) minus this cell's own
        // padding and border — read the padding/border back from the SAME block rather than
        // hardcoding them, so this stays correct if their defaults ever change.
        let padL = block.width(for: .padding, edge: .minX)
        let padR = block.width(for: .padding, edge: .maxX)
        let borderL = block.width(for: .border, edge: .minX)
        let borderR = block.width(for: .border, edge: .maxX)
        let expectedContent = (600 - 50 - 20) - padL - padR - borderL - borderR
        XCTAssertEqual(block.contentWidth, expectedContent, accuracy: 0.5,
                       "content width must reflect the margin ONCE — a second charge is the defect")
    }

    /// A general glyph-preservation sanity check for the axis that ships: cell text long enough to
    /// actually NEED the column's full width must still get every glyph laid out when a horizontal
    /// margin is declared — wrapping to MORE lines is the correct, expected cost of a narrower
    /// column; losing characters is not. NOTE, told plainly rather than overclaimed: this harness
    /// (a single isolated cell, an unclipped container) did NOT reproduce the real clipping even
    /// with the `.minX`/`.maxX` regression deliberately reintroduced — that defect only showed up
    /// against the real, paginated, multi-table 편람 through `--pdf`. It passes here in both the
    /// correct and the defective state, so it is kept as a general regression guard against a
    /// DIFFERENT class of bug (a truncating line-break mode, a negative content width), not as the
    /// discriminator for THIS one — `testHorizontalMarginChargesCellContentWidthExactlyOnce` is.
    func testLongCellTextKeepsEveryGlyphWhenAHorizontalMarginIsDeclared() {
        let long = String(repeating: "이것은 표 안의 긴 문단입니다. ", count: 12)
        let margin = EdgePadding(top: nil, left: 200, bottom: nil, right: 200)
        func glyphCountAndLines(_ margin: EdgePadding?) -> (glyphs: Int, lines: Int) {
            let (attr, _) = build(margin: margin, cellText: long, target: 600, ncol: 1)
            let storage = NSTextStorage(attributedString: attr)
            let lm = NSLayoutManager()
            let tc = NSTextContainer(size: NSSize(width: 600, height: 4000))
            tc.lineFragmentPadding = 0
            storage.addLayoutManager(lm); lm.addTextContainer(tc)
            lm.ensureLayout(for: tc)
            var lines = 0
            var glyphIndex = 0
            while glyphIndex < lm.numberOfGlyphs {
                var lineRange = NSRange(location: 0, length: 0)
                lm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
                lines += 1
                glyphIndex = lineRange.location + max(lineRange.length, 1)
            }
            return (lm.numberOfGlyphs, lines)
        }
        let bare = glyphCountAndLines(nil)
        XCTAssertGreaterThan(bare.lines, 1, "the bare case must actually wrap before its baseline means anything")
        let margined = glyphCountAndLines(margin)
        XCTAssertEqual(margined.glyphs, bare.glyphs,
                       "a narrower column must wrap the SAME text onto more lines, never drop glyphs")
        XCTAssertGreaterThanOrEqual(margined.lines, bare.lines,
                                    "a narrower column wraps to at least as many lines, never fewer")
    }

    // MARK: vertical — carried on the model, never applied to the built table

    /// The document's top/bottom values arrive on `TableFormat.outerMargin` exactly like left/right
    /// — `HwpReader`'s decode does not know or care which half is later applied.
    func testVerticalMarginArrivesOnTheFormat() {
        let margin = EdgePadding(top: 30, left: nil, bottom: 15, right: nil)
        var format = TableFormat()
        format.outerMargin = margin
        XCTAssertEqual(format.outerMargin?.top, 30)
        XCTAssertEqual(format.outerMargin?.bottom, 15)
    }

    /// …but is NEVER APPLIED: a table declaring only top/bottom lays out IDENTICALLY to one
    /// declaring no margin at all — no `.margin` box, no height change, nothing. This is the
    /// regression guard for the SECOND defect: reintroducing a `.minY`/`.maxY` `NSTextBlock` margin
    /// box on the first/last row would grow `withMargin.height` past `bare.height` and this test
    /// would catch it, the same way the horizontal test above catches its own axis.
    func testTopAndBottomMarginIsCarriedButNeverAppliedToTheBuiltTable() {
        let margin = EdgePadding(top: 30, left: nil, bottom: 15, right: nil)
        let withMargin = laidOutRect(margin: margin)
        let bare = laidOutRect(margin: nil)
        XCTAssertGreaterThan(bare.height, 0, "the check below is vacuous unless a real table laid out")
        XCTAssertEqual(withMargin.height, bare.height, accuracy: 0.01,
                       "top/bottom must NOT reach the built table — see this file's own header for why")
        let (_, block) = build(margin: margin, target: 600, ncol: 1)
        XCTAssertEqual(block.width(for: .margin, edge: .minY), 0, accuracy: 0.01,
                       "no vertical margin box may ever be stamped on the built table")
        XCTAssertEqual(block.width(for: .margin, edge: .maxY), 0, accuracy: 0.01,
                       "no vertical margin box may ever be stamped on the built table")
    }

    /// A table declaring ALL FOUR edges still only narrows horizontally — mixing the two axes in
    /// one declaration must not let the vertical half sneak through via some other code path.
    func testAllFourEdgesDeclaredStillOnlyNarrowsHorizontally() {
        let margin = EdgePadding(top: 30, left: 50, bottom: 15, right: 20)
        let withMargin = laidOutRect(margin: margin)
        let bare = laidOutRect(margin: nil)
        XCTAssertEqual(withMargin.width, bare.width - 70, accuracy: 0.01)
        XCTAssertEqual(withMargin.height, bare.height, accuracy: 0.01,
                       "the declared top/bottom must not add height even alongside a declared left/right")
    }
}
