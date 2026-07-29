import XCTest
import AppKit
@testable import FastDocReader

/// A measurement spike, kept as a test for the same reason `PageBandShiftSpikeTests` and
/// `FloatWrapExclusionSpikeTests` are: it makes a claim about APPKIT, not about our code, and the
/// next person to design against it should read numbers rather than re-derive them.
///
/// THE QUESTION. A document can declare a table rule thinner than a point — Word writes `w:sz="4"`
/// (eighths of a point) for the half-point rules its own default table styles use, and this reader
/// draws every one of them at a full point. CLAUDE.md invariant 57(c) records that AppKit CEILS a
/// declared border for DRAWING; what the design for a custom block turns on is whether it also
/// charges the ceiled width in LAYOUT, and by how much. An earlier note in this repo recorded the
/// error in the opposite direction (a 9-column table falling SHORT, to 594.0), which is why the
/// direction is measured here rather than quoted.
///
/// WHAT IT FOUND, and it is not what either earlier note said. Measured through the reader's own
/// `TableBlockBuilder` at a 600pt target (the table is in the test below):
///   • A WHOLE-point border lays out EXACTLY — 1.0pt and 2.0pt both land on 600.00 at 2, 3, 5, 9 and
///     13 columns. The arithmetic invariant 50 built is right; the INPUT is what it cannot take.
///   • Every FRACTIONAL width overshoots, by roughly a point per column boundary, growing linearly
///     with the column count: a 13-column table of Word's ordinary half-point rules finishes 13pt
///     past the column it was solved for. How big the fraction is barely matters — 0.10 and 0.25
///     behave alike, 0.50 and 0.75 behave alike — so no friendlier number tunes this away.
///   • `NSTextTableBlock` reads its border width back as the value it was GIVEN (0.5), never the one
///     it lays out with, so `TableBlockBuilder` cannot detect any of this by asking the block.
///
/// TWO EARLIER CLAIMS ARE WITHDRAWN BY THIS, and both were measured through a HAND-ROLLED
/// `NSTextTable` rather than the reader's builder: "9 columns of 0.5pt rules fall 6pt SHORT, to
/// 594.0" and "…overrun to 609.0". This spike's own first draft was hand-rolled too and reproduced
/// 594.0 exactly — at a plain 1.0pt border, where the shipping builder is exact to 0.01. So that
/// number is a property of a probe, not of AppKit, and anyone designing from it would be solving the
/// wrong problem. Measure through `TableBlockBuilder`.
///
/// WHAT THAT MEANS FOR THE DESIGN (not built here — this spike exists so it can be designed once):
/// a sub-point rule has to be drawn by US, with AppKit's own width set to 0 so it reserves nothing,
/// and `TableBlockBuilder`'s content-width arithmetic has to subtract the width we intend to STROKE
/// rather than the width the block was told. Both halves are needed: setting 0 without stroking
/// loses the rule, and stroking without setting 0 keeps the overshoot measured here. The exactness
/// tests (`TableWidthIndependenceTests`) are the gate that change has to keep passing.
final class SubPointRuleSpikeTests: XCTestCase {

    /// The laid-out width of a table built by THIS READER, with every cell declaring `borderWidth`.
    ///
    /// Through `TableBlockBuilder`, not a hand-rolled `NSTextTable`: a table assembled by hand in the
    /// probe measures the PROBE, and the first version of this spike proved exactly that — it
    /// reported a 9-column table landing 6pt short and a 13-column one 2pt short at a plain 1.0pt
    /// border, numbers the shipping builder does not produce at all (invariant 50 measures it exact
    /// to 0.01 at those very column counts). Whatever the hand-rolled version was missing, the answer
    /// this design needs is about the reader's own arithmetic meeting AppKit, so it is asked there.
    private func laidOutWidth(borderWidth: CGFloat, columns ncol: Int, target: CGFloat = 600) -> CGFloat {
        let theme = RenderTheme.current(size: 16)
        let row = (0..<ncol).map { col -> TableBlockBuilder.CellContent in
            var cell = TableBlockBuilder.CellContent(content: NSAttributedString(string: "c\(col)"))
            cell.borderWidth = borderWidth
            return cell
        }
        let attr = TableBlockBuilder.build(rows: [row, row], headerRows: 0, theme: theme,
                                           columnWidths: Array(repeating: target / CGFloat(ncol), count: ncol),
                                           width: target)
        let storage = NSTextStorage(attributedString: attr)
        let lm = NSLayoutManager()
        // Deliberately far wider than the target: a container sized AT the target silently CLIPS an
        // overshoot into looking exact, the trap invariant 50's own measurements record.
        let tc = NSTextContainer(size: NSSize(width: target + 400, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        storage.addLayoutManager(lm); lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        return lm.usedRect(for: tc).width
    }

    /// THE MEASUREMENT that produced `TableBlockBuilder.laidOutBorderWidth`, and the check that it
    /// still holds. Overshoot in points against a 600pt target, at 2 / 3 / 5 / 9 / 13 columns,
    /// BEFORE the fix — i.e. while the builder subtracted the width a document DECLARED:
    ///
    ///     0.10pt   +3  +4  +6  +10  +14        1.00pt    0   0   0    0    0
    ///     0.25pt   +3  +4  +6  +10  +14        1.25pt   +3  +4  +6  +10  +14
    ///     0.50pt   +2  +3  +5   +9  +13        1.50pt   +2  +3  +5   +9  +13
    ///     0.75pt   +2  +3  +5   +9  +13        2.00pt    0   0   0    0    0
    ///
    /// Only WHOLE-point widths landed exactly; every fraction overshot by about a point per column
    /// boundary and grew with the count, so a 13-column table of Word's ordinary half-point rules
    /// ended 13pt past its column. The size of the fraction barely mattered (0.10 behaves like 0.25,
    /// 0.50 like 0.75), which is what ruled out picking a friendlier number: AppKit charges whole
    /// points for a border whatever it is told, and the builder was subtracting something else.
    ///
    /// AFTER: every width lands exactly, because the same rounded-up number is both set on the block
    /// and subtracted from its content. All eight are asserted, not just the fractions — the two
    /// whole-point widths are the control that says the fix did not buy exactness by breaking what
    /// already worked.
    func testEveryBorderWidthNowLaysOutExactlyWhateverTheColumnCount() {
        let target: CGFloat = 600
        for declared: CGFloat in [0.1, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
            for ncol in [2, 3, 5, 9, 13] {
                XCTAssertEqual(laidOutWidth(borderWidth: declared, columns: ncol, target: target),
                               target, accuracy: 0.01,
                               "\(declared)pt × \(ncol) columns must land exactly on \(target)")
            }
        }
    }

    /// The rounding itself, stated once so the arithmetic above has a named rule to point at.
    func testLaidOutBorderWidthRoundsUpToAWholePointAndLeavesZeroAlone() {
        XCTAssertEqual(TableBlockBuilder.laidOutBorderWidth(0), 0, "no border costs no space")
        XCTAssertEqual(TableBlockBuilder.laidOutBorderWidth(0.1), 1)
        XCTAssertEqual(TableBlockBuilder.laidOutBorderWidth(0.5), 1)
        XCTAssertEqual(TableBlockBuilder.laidOutBorderWidth(1.0), 1, "a whole point is already exact")
        XCTAssertEqual(TableBlockBuilder.laidOutBorderWidth(1.25), 2)
        XCTAssertEqual(TableBlockBuilder.laidOutBorderWidth(2.0), 2)
    }

    /// Why `TableBlockBuilder` cannot notice this by itself: the block answers with what it was told.
    func testABlockReportsTheWidthItWasGivenNotTheWidthItCharges() {
        let table = NSTextTable()
        table.numberOfColumns = 1
        let block = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1,
                                     startingColumn: 0, columnSpan: 1)
        block.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .minX)
        XCTAssertEqual(block.width(for: .border, edge: .minX), 0.5,
                       "the block echoes 0.5 while laying out as 1.0 — the gap is invisible from here")
    }
}
