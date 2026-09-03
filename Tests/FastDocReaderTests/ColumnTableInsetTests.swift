import XCTest
import AppKit
@testable import FastDocReader

/// Invariant 143 — a column placement must not flatten a table cell's own place across the column.
///
/// `ColumnGeometry.placements` answers with an absolute `x`, and for a line of prose that `x` IS the
/// column's left edge. A cell's is not: two cells of one row differ by nothing else, so assigning the
/// column's `x` to both drew them on top of each other. These cases pin the carry AND its identity
/// half — a run with no table in it must produce exactly the map it produced before.
final class ColumnTableInsetTests: XCTestCase {

    private let columns = [ColumnGeometry.Column(x: 0, width: 200),
                           ColumnGeometry.Column(x: 220, width: 200)]

    func testACellKeepsItsPlaceAcrossTheColumn() {
        let placed = ColumnGeometry.placements(
            lines: [(location: 0, top: 0, height: 14, insetX: 0),
                    (location: 10, top: 0, height: 14, insetX: 60),
                    (location: 20, top: 0, height: 14, insetX: 140)],
            runOrigin: 0, firstPage: 0, columns: columns,
            columnHeight: 500, pitch: 600, leadingBand: 0)
        XCTAssertEqual(placed[0]?.x, 0)
        XCTAssertEqual(placed[10]?.x, 60, "the second cell of the row lost its own place")
        XCTAssertEqual(placed[20]?.x, 140, "the third cell of the row lost its own place")
        // All three are one row: same y, three different x. That is the whole point.
        XCTAssertEqual(placed[0]?.y, placed[10]?.y)
        XCTAssertEqual(placed[0]?.y, placed[20]?.y)
    }

    func testTheSecondColumnCarriesTheInsetToo() {
        // A line far enough down the run to belong to column 2.
        let placed = ColumnGeometry.placements(
            lines: [(location: 0, top: 600, height: 14, insetX: 60)],
            runOrigin: 0, firstPage: 0, columns: columns,
            columnHeight: 500, pitch: 600, leadingBand: 0)
        XCTAssertEqual(placed[0]?.x, 220 + 60)
    }

    /// The shape every caller had before this existed. A run of prose is unchanged, byte for byte.
    func testAProseRunIsPlacedExactlyAsItWasBefore() {
        let prose: [(location: Int, top: CGFloat, height: CGFloat)] =
            [(0, 0, 14), (10, 20, 14), (20, 520, 14), (30, 700, 14)]
        let old = ColumnGeometry.placements(lines: prose, runOrigin: 0, firstPage: 0,
                                            columns: columns, columnHeight: 500,
                                            pitch: 600, leadingBand: 0)
        let new = ColumnGeometry.placements(lines: prose.map { ($0.0, $0.1, $0.2, 0) },
                                            runOrigin: 0, firstPage: 0, columns: columns,
                                            columnHeight: 500, pitch: 600, leadingBand: 0)
        XCTAssertEqual(old.count, new.count)
        for (k, v) in old {
            XCTAssertEqual(new[k]?.x, v.x)
            XCTAssertEqual(new[k]?.y, v.y)
        }
        // And it really is the column's own edge, not something the inset invented.
        XCTAssertEqual(old[0]?.x, 0)
        XCTAssertEqual(old[20]?.x, 220)
    }
}

/// Invariant 145 — the boundaries a column map crosses are OPEN boundaries.
///
/// A columned line never reaches the between-page rule, so nothing else can know that the pages
/// under a columned run were really broken. `joiningUnopenedBoundaries` reads an unopened boundary
/// as "layout never broke here" and welds — which drew the reference manual's whole two-column
/// appendix as two sheets 11 and 10 pages tall.
final class ColumnCrossedBoundaryTests: XCTestCase {

    private func map(_ ys: [CGFloat]) -> [Int: (x: CGFloat, y: CGFloat)] {
        Dictionary(uniqueKeysWithValues: ys.enumerated().map { ($0.offset, (x: 0, y: $0.element)) })
    }

    func testEveryBoundaryBetweenTheFirstAndLastPageIsOpen() {
        // pitch 100, no leading band: pages 0, 2 and 5 occupied.
        let out = ColumnGeometry.crossedBoundaries(placements: map([10, 250, 530]),
                                                   leadingBand: 0, pitch: 100)
        XCTAssertEqual(out, Set(0..<5),
                       "a page inside a continuous run cannot be empty, so its boundary is real")
    }

    /// A run that never leaves one page opens nothing — otherwise a short columned block would split
    /// the sheet it sits on.
    func testARunOnASinglePageOpensNothing() {
        XCTAssertTrue(ColumnGeometry.crossedBoundaries(placements: map([10, 40, 90]),
                                                       leadingBand: 0, pitch: 100).isEmpty)
        XCTAssertTrue(ColumnGeometry.crossedBoundaries(placements: [:],
                                                       leadingBand: 0, pitch: 100).isEmpty)
        XCTAssertTrue(ColumnGeometry.crossedBoundaries(placements: map([10, 250]),
                                                       leadingBand: 0, pitch: 0).isEmpty)
    }

    /// The leading band shifts the whole grid down, exactly as `PageBandLayoutDelegate.page` reads it.
    func testTheLeadingBandIsHonoured() {
        let out = ColumnGeometry.crossedBoundaries(placements: map([60, 160]),
                                                   leadingBand: 50, pitch: 100)
        XCTAssertEqual(out, Set([0]))
    }
}

/// Invariant 150 — a line pushed off a column foot takes the lines under it along.
///
/// `placements` moves a line WHOLE to the next column when it would straddle the foot, which is the
/// answer the page band gives a line that would straddle a sheet. The page band also moves
/// everything under it; this map did not, so the pushed line arrived at the next column's top while
/// the lines after it kept their unpushed places and were drawn under it.
final class ColumnPushCarryTests: XCTestCase {

    private let columns = [ColumnGeometry.Column(x: 0, width: 200),
                           ColumnGeometry.Column(x: 220, width: 200)]

    /// Column height 100, lines of 30: three fit (0, 30, 60), the fourth would end at 120 and is
    /// pushed to column 1. The fifth must follow it there, not sit at column 1's top on top of it.
    func testTheLinesAfterAPushMoveWithIt() {
        let lines: [(location: Int, top: CGFloat, height: CGFloat, insetX: CGFloat)] =
            [(0, 0, 30, 0), (1, 30, 30, 0), (2, 60, 30, 0), (3, 90, 30, 0), (4, 120, 30, 0)]
        let placed = ColumnGeometry.placements(lines: lines, runOrigin: 0, firstPage: 0,
                                               columns: columns, columnHeight: 100,
                                               pitch: 1000, leadingBand: 0)
        XCTAssertEqual(placed[3]?.x, 220, "the straddling line belongs to the next column")
        XCTAssertEqual(placed[3]?.y, 0, "…at its top")
        XCTAssertEqual(placed[4]?.x, 220, "and the line after it is in that column too")
        XCTAssertEqual(placed[4]?.y, 30,
                       "one line below it — without the carry it lands at 20, INSIDE the 30pt line "
                       + "above, which is exactly how the appendix drew a cut cell over the row "
                       + "that followed it")
        // The pair the census measures: no two lines in one column may occupy the same space.
        for a in 3...4 {
            for b in 3...4 where a < b {
                guard let p = placed[a], let q = placed[b] else { return XCTFail("both must place") }
                XCTAssertFalse(p.x == q.x && abs(p.y - q.y) < 30, "lines \(a) and \(b) overlap")
            }
        }
    }

    /// A run that never straddles must be placed exactly as it was before the carry existed.
    func testARunThatNeverStraddlesIsUnchanged() {
        let lines: [(location: Int, top: CGFloat, height: CGFloat, insetX: CGFloat)] =
            [(0, 0, 20, 0), (1, 20, 20, 0), (2, 100, 20, 0), (3, 120, 20, 0)]
        let placed = ColumnGeometry.placements(lines: lines, runOrigin: 0, firstPage: 0,
                                               columns: columns, columnHeight: 100,
                                               pitch: 1000, leadingBand: 0)
        XCTAssertEqual(placed[0]?.y, 0)
        XCTAssertEqual(placed[1]?.y, 20)
        XCTAssertEqual(placed[2]?.x, 220, "the second column begins exactly at the column height")
        XCTAssertEqual(placed[2]?.y, 0)
        XCTAssertEqual(placed[3]?.y, 20)
    }
}
