import XCTest
import AppKit
@testable import FastDocReader

/// S17 feasibility spike — NOT the feature. A controlled experiment against this app's REAL TextKit 1
/// stack to answer the one question the whole multi-column design rests on, BEFORE any production
/// code is written.
///
/// **The question**: this reader has ONE `NSTextContainer` (`DocumentWindowController` builds exactly
/// one, and an `NSTextView` cannot have more), so TextKit's own multi-container column flow is not
/// available without replacing the view. What IS available is the mechanism invariant 58's page band
/// already uses — `shouldSetLineFragmentRect` moving a line before it is set. A page band only ever
/// pushes a line DOWN. A column flow must do the opposite at every column break: the first line of
/// column 2 goes back UP to the top of the body and across to the right. **Does the typesetter accept
/// a line placed above its predecessor, and carry the following lines with it?**
///
/// If it does not, the columns can only be built by replacing the text view — and that cost belongs
/// in the record before anyone proposes it, exactly as invariant 31 recorded the floating-wrap
/// measurement that stopped that feature from being re-proposed.
///
/// Measured, not reasoned: this file makes the same claim invariant 58's own spike does, in the
/// opposite direction — and then measures the thing that claim does NOT cover, which is what
/// actually decided the design.
///
/// **What the first version of this spike got wrong.** It asserted only that SOME lines ended up in
/// the left column and SOME in the right, which a rule that moves one line per column break also
/// satisfies. Built against a real document, that rule drew a narrow single column: the typesetter
/// carries a moved line's `y` to the following lines but re-derives their `x` from the paragraph, so
/// every line after the first returned to the left edge — 32 lines moved and 1,200 stayed on
/// `samples/basic/shortcut.hwp`. `testTheTypesetterDoesNotCarryAMovedLinesX` below is that finding,
/// asserted directly, and it is why columns are placed from a character-keyed map
/// (`ColumnGeometry.placements`) rather than by a rule that reads the laid-out page.
final class ColumnFlowSpikeTests: XCTestCase {

    /// Two equal columns of a fixed height, in one container, moving lines only.
    private final class ColumnFlowDelegate: NSObject, NSLayoutManagerDelegate {
        let columnHeight: CGFloat
        let columns: [ColumnGeometry.Column]
        /// Lines this rule actually moved — a test can assert something HAPPENED without
        /// hand-deriving where every line went.
        private(set) var moved = 0

        init(columnHeight: CGFloat, columns: [ColumnGeometry.Column]) {
            self.columnHeight = columnHeight
            self.columns = columns
        }

        func layoutManager(_ layoutManager: NSLayoutManager,
                           shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                           lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                           baselineOffset: UnsafeMutablePointer<CGFloat>,
                           in textContainer: NSTextContainer,
                           forGlyphRange glyphRange: NSRange) -> Bool {
            let rect = lineFragmentRect.pointee
            // Where this line sits in the FLOW — the single tall stack the typesetter builds. The
            // column it belongs to is that offset divided by the column height, which is the same
            // division the page rule makes, and it is derived from the incoming rect rather than
            // counted, so re-laying out a range partway through cannot double-count.
            guard let placed = ColumnGeometry.column(atFlowOffset: rect.minY,
                                                     columnHeight: columnHeight,
                                                     count: columns.count),
                  placed.index > 0 else { return false }
            let column = columns[placed.index]
            var moved = rect
            moved.origin.y = placed.offsetInColumn      // back UP to the top of the body
            moved.origin.x = column.x                   // and across
            moved.size.width = column.width
            lineFragmentRect.pointee = moved
            var used = lineFragmentUsedRect.pointee
            used.origin.y = moved.origin.y
            used.origin.x = column.x
            lineFragmentUsedRect.pointee = used
            self.moved += 1
            return true
        }
    }

    /// Twenty short paragraphs, laid out narrow enough that the flow is much taller than one column.
    private func layout(columnHeight: CGFloat, columnWidth: CGFloat,
                        columns: [ColumnGeometry.Column])
        -> (NSTextStorage, NSLayoutManager, NSTextContainer, ColumnFlowDelegate) {
        let storage = NSTextStorage()
        for i in 0..<20 {
            storage.append(NSAttributedString(
                string: "line \(i) of the flowing text\n",
                attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        }
        let lm = NSLayoutManager()
        // The whole point of the experiment: ONE container, whose width is the COLUMN's, because a
        // line has to break at the column's edge before anything can move it there.
        let tc = NSTextContainer(size: NSSize(width: columnWidth, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        storage.addLayoutManager(lm)
        let delegate = ColumnFlowDelegate(columnHeight: columnHeight, columns: columns)
        lm.delegate = delegate
        lm.ensureLayout(for: tc)
        return (storage, lm, tc, delegate)
    }

    /// (a) The typesetter accepts a line moved ABOVE its predecessor, and does not simply put it back.
    /// (b) It carries the following lines with it, rather than keeping its own cursor.
    /// (c) The result is two columns: some lines in the left one, some in the right, none in between.
    func testALineCanBeMovedBackUpAndAcrossIntoASecondColumn() {
        let columns = ColumnGeometry.columns(inWidth: 420,
                                             layout: OfficeColumnLayout(count: 2, spacing: 20))
        let (storage, lm, tc, delegate) = layout(columnHeight: 120, columnWidth: columns[0].width,
                                                columns: columns)
        XCTAssertGreaterThan(delegate.moved, 0, "the flow is taller than one column, so some line moved")

        var lefts: [CGFloat] = []
        var tops: [CGFloat] = []
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) {
            rect, _, _, _, _ in
            lefts.append(rect.minX)
            tops.append(rect.minY)
        }
        XCTAssertGreaterThan(lefts.count, 4, "several lines were laid out")

        let inLeft = lefts.filter { $0 < 1 }.count
        let inRight = lefts.filter { abs($0 - columns[1].x) < 0.5 }.count
        XCTAssertGreaterThan(inLeft, 0, "some lines stayed in the first column")
        XCTAssertGreaterThan(inRight, 0, "and some really landed in the second — x moved")
        XCTAssertEqual(inLeft + inRight, lefts.count, "no line landed between the columns")

        // (a)+(b): the moved lines are ABOVE the tallest line of the first column, which cannot
        // happen if the typesetter ignored the rect or kept its own downward cursor.
        let deepestLeft = zip(lefts, tops).filter { $0.0 < 1 }.map(\.1).max() ?? 0
        let highestRight = zip(lefts, tops).filter { abs($0.0 - columns[1].x) < 0.5 }.map(\.1).min() ?? 0
        XCTAssertLessThan(highestRight, deepestLeft,
                          "the second column starts above where the first one ended")
        XCTAssertLessThan(highestRight, 20, "and it starts near the TOP of the body")
        _ = (tc, storage)
    }

    /// THE finding that decided the design: a moved line's `x` is NOT inherited by the line after it.
    ///
    /// The delegate above moves a line into column 2 and leaves the following lines alone (its rule
    /// only fires for lines whose flow offset is past the first column). If the typesetter carried
    /// `x` the way it carries `y`, those following lines would arrive already at column 2's left
    /// edge. They do not: they come back at 0, which means a rule cannot read a line's column off
    /// the page it is being laid out into.
    func testTheTypesetterDoesNotCarryAMovedLinesX() {
        let columns = ColumnGeometry.columns(inWidth: 420,
                                             layout: OfficeColumnLayout(count: 2, spacing: 20))
        let (storage, lm, _, delegate) = layout(columnHeight: 120, columnWidth: columns[0].width,
                                                columns: columns)
        var lefts: [CGFloat] = []
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) {
            rect, _, _, _, _ in lefts.append(rect.minX)
        }
        let moved = lefts.filter { abs($0 - columns[1].x) < 0.5 }.count
        XCTAssertEqual(moved, delegate.moved,
                       "exactly the lines this rule touched are in column 2 — no line inherited the x")
        XCTAssertLessThan(moved, lefts.count / 2,
                          "and most lines are still at the left edge, which is what a page of this "
                          + "rule's output actually looks like")
        _ = storage
    }

    /// Idempotence, the property invariant 58 says a counter cannot have: laying the same text out
    /// again from scratch must put every line in the same place. A rule that counted column breaks
    /// as it went would move a line one further column on the second pass.
    func testTheRuleIsIdempotentUnderRelayout() {
        let columns = ColumnGeometry.columns(inWidth: 420,
                                             layout: OfficeColumnLayout(count: 2, spacing: 20))
        func run() -> [NSRect] {
            let (storage, lm, _, _) = layout(columnHeight: 120, columnWidth: columns[0].width, columns: columns)
            var out: [NSRect] = []
            lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) {
                rect, _, _, _, _ in out.append(rect)
            }
            _ = storage
            return out
        }
        let first = run()
        let second = run()
        XCTAssertEqual(first.count, second.count)
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.minX, b.minX, accuracy: 0.001)
            XCTAssertEqual(a.minY, b.minY, accuracy: 0.001)
        }
    }

    /// The cost of the whole experiment, so the design can be argued about with a number rather than
    /// an intuition. Asserts only that it completes — a wall clock on a shared machine is not a
    /// budget (invariant 67's method), and the figure is for the record.
    func testTheColumnRuleCostsSomethingBoundedOnALongFlow() {
        let columns = ColumnGeometry.columns(inWidth: 420,
                                             layout: OfficeColumnLayout(count: 2, spacing: 20))
        let started = ProcessInfo.processInfo.systemUptime
        let (storage, lm, _, delegate) = layout(columnHeight: 120, columnWidth: columns[0].width,
                                                columns: columns)
        let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
        XCTAssertGreaterThan(lm.numberOfGlyphs, 0)
        _ = storage
        print("[column-flow spike] \(delegate.moved) lines moved, layout \(String(format: "%.1f", ms)) ms")
    }
}
