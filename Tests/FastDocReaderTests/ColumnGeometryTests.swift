import XCTest
@testable import FastDocReader

/// S16 — the arithmetic of a multi-column declaration, with nothing laid out and nothing drawn.
///
/// Measured over the 637-sample corpus (`examples/scan_columns.rs`): 64 documents (10.0%) declare
/// more than one column, 149 declarations in all, and 57 of those (38%) do NOT want equal columns.
/// Those two numbers are why this exists as arithmetic first — a wrong split is wrong on every page
/// of a document, and it is cheaper to be sure of it here than inside a layout pass.
final class ColumnGeometryTests: XCTestCase {

    // MARK: a document that declares nothing keeps the geometry it always had

    /// The single most important property: a caller never has to ask "is this multi-column".
    func testASingleColumnIsTheWholeWidth() {
        for layout in [OfficeColumnLayout(count: 1),
                       OfficeColumnLayout(count: 1, spacing: 20),
                       OfficeColumnLayout(count: 0)] {
            let cols = ColumnGeometry.columns(inWidth: 400, layout: layout)
            XCTAssertEqual(cols, [ColumnGeometry.Column(x: 0, width: 400)])
        }
    }

    func testAWidthOfNothingProducesOneColumnRatherThanNegativeOnes() {
        XCTAssertEqual(ColumnGeometry.columns(inWidth: 0, layout: OfficeColumnLayout(count: 3)),
                       [ColumnGeometry.Column(x: 0, width: 0)])
    }

    // MARK: the equal split, which 92 of the 149 declarations ask for

    func testEqualColumnsSplitWhatIsLeftAfterTheGaps() {
        let cols = ColumnGeometry.columns(inWidth: 440,
                                          layout: OfficeColumnLayout(count: 2, spacing: 40))
        XCTAssertEqual(cols.count, 2)
        XCTAssertEqual(cols[0].x, 0, accuracy: 0.001)
        XCTAssertEqual(cols[0].width, 200, accuracy: 0.001)
        XCTAssertEqual(cols[1].x, 240, accuracy: 0.001)
        XCTAssertEqual(cols[1].width, 200, accuracy: 0.001)
    }

    /// Three columns have TWO gaps, not three — the trailing edge is the page's, not a gap.
    func testThreeColumnsHaveTwoGaps() {
        let cols = ColumnGeometry.columns(inWidth: 320,
                                          layout: OfficeColumnLayout(count: 3, spacing: 10))
        XCTAssertEqual(cols.map(\.width), [100, 100, 100])
        XCTAssertEqual(cols.map(\.x), [0, 110, 220])
        XCTAssertEqual(cols.last!.x + cols.last!.width, 320, accuracy: 0.001)
    }

    /// A gap wider than the page would give every column a negative width and put the text outside
    /// the paper. Too wide is a document that will not fit, not one to draw inside out.
    func testAnImpossibleGapFallsBackToOneColumn() {
        let cols = ColumnGeometry.columns(inWidth: 100,
                                          layout: OfficeColumnLayout(count: 2, spacing: 200))
        XCTAssertEqual(cols, [ColumnGeometry.Column(x: 0, width: 100)])
    }

    // MARK: the widths a document listed itself — 57 of 149 declarations

    /// HWP 5 states shares summing to 32,768. This is a real declaration, read off
    /// `samples/basic/KTX.hwp`: two columns of 13,722 and 18,456 with a 590 gap between them.
    func testProportionalWidthsAreSharesOfTheBodyWidth() {
        let layout = OfficeColumnLayout(count: 2,
                                        widths: [13722, 18456], gaps: [590, 0], proportional: true)
        let cols = ColumnGeometry.columns(inWidth: 32768 / 100, layout: layout)   // 1 share = 0.01pt
        XCTAssertEqual(cols.count, 2)
        XCTAssertEqual(cols[0].width, 137.22, accuracy: 0.01)
        XCTAssertEqual(cols[1].x, (13722 + 590) / 100, accuracy: 0.01)
        XCTAssertEqual(cols[1].width, 184.56, accuracy: 0.01)
        // The columns and their gap fill the width exactly — this is what a share IS.
        XCTAssertEqual(cols[1].x + cols[1].width, 32768 / 100, accuracy: 0.05)
    }

    /// The shares are taken against their own TOTAL rather than the format's constant, so a document
    /// whose numbers are slightly off lands inside the page instead of overflowing it by its own
    /// rounding error.
    func testSharesThatDoNotSumToTheFormatConstantStillFillThePage() {
        let layout = OfficeColumnLayout(count: 2, widths: [1, 1], gaps: [0, 0], proportional: true)
        let cols = ColumnGeometry.columns(inWidth: 300, layout: layout)
        XCTAssertEqual(cols.map(\.width), [150, 150])
    }

    /// HWPX states absolute points instead. Same field, different unit — `proportional` is what
    /// separates them, and nothing else in this type may assume one or the other.
    func testAbsoluteWidthsAreUsedAsGiven() {
        let layout = OfficeColumnLayout(count: 2, widths: [120, 180], gaps: [20, 0])
        let cols = ColumnGeometry.columns(inWidth: 320, layout: layout)
        XCTAssertEqual(cols.map(\.x), [0, 140])
        XCTAssertEqual(cols.map(\.width), [120, 180])
    }

    /// Absolute widths can simply be wrong for this page — a document written for wider paper. The
    /// equal split keeps the text on the sheet, which matters more than honouring a number that
    /// does not fit.
    func testAbsoluteWidthsTooWideForThePageFallBackToTheEqualSplit() {
        let layout = OfficeColumnLayout(count: 2, spacing: 20, widths: [400, 400], gaps: [20, 0])
        let cols = ColumnGeometry.columns(inWidth: 320, layout: layout)
        XCTAssertEqual(cols.map(\.width), [150, 150], "the equal split, not 400pt off the page")
    }

    func testAColumnOfZeroWidthIsNotDrawn() {
        let layout = OfficeColumnLayout(count: 2, spacing: 10, widths: [0, 300], gaps: [0, 0])
        let cols = ColumnGeometry.columns(inWidth: 310, layout: layout)
        XCTAssertEqual(cols.count, 2, "falls back to the equal split rather than an empty column")
        XCTAssertEqual(cols.map(\.width), [150, 150])
    }

    // MARK: which column a point of the flow is in

    /// Text fills column 0 to the bottom, then starts at the TOP of column 1 — so the offset from
    /// the start of the run divides by the column height exactly as a page divides by its pitch.
    func testTheFlowFillsOneColumnBeforeStartingTheNext() {
        let h: CGFloat = 500
        XCTAssertEqual(ColumnGeometry.column(atFlowOffset: 0, columnHeight: h, count: 2)?.index, 0)
        XCTAssertEqual(ColumnGeometry.column(atFlowOffset: 499, columnHeight: h, count: 2)?.index, 0)
        XCTAssertEqual(ColumnGeometry.column(atFlowOffset: 500, columnHeight: h, count: 2)?.index, 1)
        let deep = ColumnGeometry.column(atFlowOffset: 620, columnHeight: h, count: 2)
        XCTAssertEqual(deep?.index, 1)
        XCTAssertEqual(deep?.offsetInColumn ?? 0, 120, accuracy: 0.001)
    }

    /// The same hair of tolerance the page rule carries, for the same measured reason: a line placed
    /// at exactly a boundary comes back a fraction under it, and a bare floor would read as the
    /// column before — the mistake that stops a settle converging (invariant 61).
    func testAPointExactlyOnABoundaryBelongsToTheColumnItStarts() {
        let atEdge = 500 - 1e-9
        XCTAssertEqual(ColumnGeometry.column(atFlowOffset: atEdge, columnHeight: 500, count: 3)?.index, 1)
    }

    /// Past the last column is the text overflowing the run. Answering with a wrong column would
    /// draw it on top of something; `nil` leaves that decision where it belongs.
    func testPastTheLastColumnIsNotAColumn() {
        XCTAssertNil(ColumnGeometry.column(atFlowOffset: 1000, columnHeight: 500, count: 2))
        XCTAssertNil(ColumnGeometry.column(atFlowOffset: -1, columnHeight: 500, count: 2))
        XCTAssertNil(ColumnGeometry.column(atFlowOffset: 10, columnHeight: 0, count: 2))
    }

    // MARK: what the declaration itself says

    func testADeclarationOfOneColumnDoesNotSplitAnything() {
        XCTAssertFalse(OfficeColumnLayout(count: 1, separatorType: 1).splitsText)
        XCTAssertFalse(OfficeColumnLayout(count: 1, separatorType: 1).drawsSeparator,
                       "a rule between one column is a rule between nothing")
        XCTAssertTrue(OfficeColumnLayout(count: 2).splitsText)
    }

    /// 93 of the 149 declarations draw no rule; the other 56 do.
    func testARuleIsDrawnOnlyWhenTheDocumentAsksForOne() {
        XCTAssertFalse(OfficeColumnLayout(count: 2, separatorType: 0).drawsSeparator)
        XCTAssertTrue(OfficeColumnLayout(count: 2, separatorType: 7).drawsSeparator)
    }

    // MARK: the decode, from the JSON the exporter really sends

    func testAColumnDeclarationSurvivesTheDecoder() throws {
        let json = """
        {"v":1,"blocks":[{"t":"para","spans":[\
        {"text":"","columnDef":{"columnCount":2,"direction":"leftToRight","sameWidth":true,\
        "separatorType":7,"separatorWidth":7,"separatorColor":"AEAEAE","columnSpacingPt":28.35}}]}]}
        """
        guard case let .paragraph(spans, _, _, _, _)? = try HwpReader.mapJSON(json).blocks.first else {
            return XCTFail("expected one paragraph")
        }
        guard let layout = spans.compactMap(\.columnLayout).first else {
            return XCTFail("the declaration did not reach the reader")
        }
        XCTAssertEqual(layout.count, 2)
        XCTAssertEqual(layout.spacing, 28.35, accuracy: 0.001)
        XCTAssertTrue(layout.drawsSeparator)
        XCTAssertGreaterThan(layout.separatorWidthPt, 0, "a declared rule has a thickness")
    }

    /// The other real shape — `samples/basic/KTX.hwp`, which states shares rather than equal columns.
    func testUnequalColumnsSurviveTheDecoder() throws {
        let json = """
        {"v":1,"blocks":[{"t":"para","spans":[\
        {"text":"","columnDef":{"columnCount":2,"direction":"leftToRight",\
        "proportionalWidths":true,"columnWidths":[13722.0,18456.0],"columnGaps":[590.0,0.0]}}]}]}
        """
        guard case let .paragraph(spans, _, _, _, _)? = try HwpReader.mapJSON(json).blocks.first,
              let layout = spans.compactMap(\.columnLayout).first else {
            return XCTFail("the declaration did not reach the reader")
        }
        XCTAssertTrue(layout.proportional)
        XCTAssertEqual(layout.widths, [13722, 18456])
        XCTAssertEqual(layout.gaps, [590, 0])
        XCTAssertFalse(layout.drawsSeparator, "this one declares no rule")
    }
}
