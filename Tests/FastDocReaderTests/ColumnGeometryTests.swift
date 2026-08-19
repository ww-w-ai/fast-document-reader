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

    // MARK: what width each block is typeset at

    private func para(_ text: String, layout: OfficeColumnLayout? = nil) -> OfficeBlock {
        var span = Span(text: text)
        span.columnLayout = layout
        return .paragraph(spans: [span])
    }

    /// A run is typeset at the COLUMN's width, not the page's — the line has to break at the column
    /// edge before anything can place it there, and a table would otherwise stay page-wide inside a
    /// narrow column (244 of the corpus's tables sit under a column declaration).
    func testBlocksUnderADeclarationAreTypesetAtTheColumnWidth() {
        let blocks = [para("before"),
                      para("first of the run", layout: OfficeColumnLayout(count: 2, spacing: 20)),
                      para("still in the run")]
        let widths = OfficeTextBuilder.columnWidthPerBlock(blocks, bodyWidth: 420)
        XCTAssertEqual(widths[0], 420, "nothing above the declaration is narrowed")
        XCTAssertEqual(widths[1], 200, accuracy: 0.001, "the declaration takes effect where it sits")
        XCTAssertEqual(widths[2], 200, accuracy: 0.001, "and holds for what follows")
    }

    /// A declaration of ONE column is how a document goes back to a single column — an END, not a
    /// run. Dropping it would leave the previous declaration in force to the end of the document.
    func testADeclarationOfOneColumnEndsTheRun() {
        let blocks = [para("a", layout: OfficeColumnLayout(count: 2, spacing: 20)),
                      para("b"),
                      para("c", layout: OfficeColumnLayout(count: 1)),
                      para("d")]
        let widths = OfficeTextBuilder.columnWidthPerBlock(blocks, bodyWidth: 420)
        XCTAssertEqual(widths[1], 200, accuracy: 0.001)
        XCTAssertEqual(widths[2], 420, "back to the full width")
        XCTAssertEqual(widths[3], 420)
    }

    /// A document with no declaration anywhere is byte-for-byte what it was — the property that
    /// makes this invisible to the 90% of the corpus that never asks for columns.
    func testADocumentWithNoDeclarationIsUnchanged() {
        let widths = OfficeTextBuilder.columnWidthPerBlock([para("x"), para("y")], bodyWidth: 420)
        XCTAssertEqual(widths, [420, 420])
    }

    // MARK: where every line of a run goes

    private func line(_ loc: Int, _ top: CGFloat, _ h: CGFloat = 15)
        -> (location: Int, top: CGFloat, height: CGFloat) { (loc, top, h) }

    /// The flow reads down column 1 of a sheet, then column 2, then the next sheet — which is the
    /// whole behaviour, stated as one assertion.
    func testAFlowFillsColumnOneThenColumnTwoThenTheNextPage() {
        let columns = ColumnGeometry.columns(inWidth: 420,
                                             layout: OfficeColumnLayout(count: 2, spacing: 20))
        let h: CGFloat = 300
        let pitch: CGFloat = 320
        let lines = [line(0, 0), line(10, 150), line(20, 300), line(30, 450),
                     line(40, 600), line(50, 750)]
        let out = ColumnGeometry.placements(lines: lines, runOrigin: 0, firstPage: 0,
                                            columns: columns, columnHeight: h,
                                            pitch: pitch, leadingBand: 0)
        XCTAssertEqual(out[0]?.x, 0);              XCTAssertEqual(out[0]?.y, 0)
        XCTAssertEqual(out[10]?.x, 0);             XCTAssertEqual(out[10]?.y, 150)
        // 300 into the flow = the top of column 2, same sheet.
        XCTAssertEqual(out[20]?.x, columns[1].x);  XCTAssertEqual(out[20]?.y, 0)
        XCTAssertEqual(out[30]?.x, columns[1].x);  XCTAssertEqual(out[30]?.y, 150)
        // 600 = both columns full, so the next SHEET's first column.
        XCTAssertEqual(out[40]?.x, 0);             XCTAssertEqual(out[40]?.y, pitch)
        XCTAssertEqual(out[50]?.x, 0);             XCTAssertEqual(out[50]?.y, pitch + 150)
    }

    /// Three columns, to prove nothing is hard-coded for two.
    func testThreeColumnsFillInOrder() {
        let columns = ColumnGeometry.columns(inWidth: 320,
                                             layout: OfficeColumnLayout(count: 3, spacing: 10))
        let out = ColumnGeometry.placements(lines: [line(0, 0), line(1, 100), line(2, 200), line(3, 300)],
                                            runOrigin: 0, firstPage: 0, columns: columns,
                                            columnHeight: 100, pitch: 120, leadingBand: 0)
        XCTAssertEqual(out[0]?.x, columns[0].x)
        XCTAssertEqual(out[1]?.x, columns[1].x)
        XCTAssertEqual(out[2]?.x, columns[2].x)
        XCTAssertEqual(out[3]?.x, columns[0].x, "past the last column is the next page")
        XCTAssertEqual(out[3]?.y, 120)
    }

    /// A line that would hang off the foot of its column is carried whole to the next one — the same
    /// answer the page band gives a line that would straddle a sheet boundary.
    func testALineThatWouldOverhangIsCarriedToTheNextColumn() {
        let columns = ColumnGeometry.columns(inWidth: 420,
                                             layout: OfficeColumnLayout(count: 2, spacing: 20))
        let out = ColumnGeometry.placements(lines: [line(0, 290, 30)], runOrigin: 0, firstPage: 0,
                                            columns: columns, columnHeight: 300,
                                            pitch: 320, leadingBand: 0)
        XCTAssertEqual(out[0]?.x, columns[1].x, "not left hanging over the foot of column 1")
        XCTAssertEqual(out[0]?.y, 0)
    }

    /// The run's own origin and page are honoured — a run does not have to start at the document's
    /// first line, and the leading band shifts every answer by the same amount.
    ///
    /// `runOrigin` is 28pt BELOW page 3's own top here, which is a run that begins partway down a
    /// sheet: the lines above it belong to the single-column flow. Its columns therefore start where
    /// the RUN starts, not where the page does — placing them at the page top draws the run over
    /// text that is already there.
    func testARunIsPlacedRelativeToItsOwnStart() {
        let columns = ColumnGeometry.columns(inWidth: 420,
                                             layout: OfficeColumnLayout(count: 2, spacing: 20))
        let out = ColumnGeometry.placements(lines: [line(0, 1000), line(1, 1300)],
                                            runOrigin: 1000, firstPage: 3, columns: columns,
                                            columnHeight: 300, pitch: 320, leadingBand: 12)
        XCTAssertEqual(out[0]?.y, 1000, "the run's first line stays where the run begins")
        XCTAssertEqual(out[1]?.x, columns[1].x)
        XCTAssertEqual(out[1]?.y, 1000, "column 2 of the SAME sheet begins where column 1 did")
    }

    /// A run beginning partway down a sheet has TWO column heights: what is left of the sheet it
    /// starts on, and the whole body of every sheet after it. Passing only the leftover made every
    /// later sheet as short as the first, so the columns stopped partway down the page and the run
    /// spilled onto sheets it did not need.
    ///
    /// Page 3's body is 300 tall and the run starts 100 into it, so its first sheet holds 200 per
    /// column (400 of flow) and every later sheet 300 per column (600).
    func testALaterSheetGetsItsWholeBodyNotTheFirstSheetsLeftover() {
        let columns = ColumnGeometry.columns(inWidth: 420,
                                             layout: OfficeColumnLayout(count: 2, spacing: 20))
        let origin: CGFloat = 3 * 320 + 12 + 100
        let out = ColumnGeometry.placements(
            lines: [line(0, origin), line(1, origin + 200), line(2, origin + 400),
                    line(3, origin + 700), line(4, origin + 1000)],
            runOrigin: origin, firstPage: 3, columns: columns,
            columnHeight: 300, pitch: 320, leadingBand: 12, firstColumnHeight: 200)
        // The short first sheet: 0…200 is column 1, 200…400 column 2, both starting at the run.
        XCTAssertEqual(out[0]?.x, columns[0].x)
        XCTAssertEqual(out[0]?.y, origin)
        XCTAssertEqual(out[1]?.x, columns[1].x, "200 into a 200-tall first column is the next column")
        XCTAssertEqual(out[1]?.y, origin)
        // 400 of flow fills that sheet, so the next line opens sheet 4 AT ITS TOP with a FULL column.
        XCTAssertEqual(out[2]?.x, columns[0].x)
        XCTAssertEqual(out[2]?.y, 4 * 320 + 12, "a later sheet starts at its own top")
        let sheet4Top: CGFloat = 4 * 320 + 12
        XCTAssertEqual(out[3]?.x, columns[1].x, "300 into sheet 4's 300-tall column 1 is column 2")
        XCTAssertEqual(out[3]?.y, sheet4Top)
        // 400 (first sheet) + 600 (sheet 4) of flow is exactly the start of the sheet after it.
        XCTAssertEqual(out[4]?.x, columns[0].x)
        XCTAssertEqual(out[4]?.y, 5 * 320 + 12, "a full later sheet holds 600, so 1000 opens sheet 5")
    }

    /// …and when the run DOES begin at a page top the two heights are equal and every answer is the
    /// one this function gave before it could tell them apart. This is what keeps every run that
    /// already worked provably untouched.
    func testEqualHeightsReduceToTheOriginalArithmetic() {
        let columns = ColumnGeometry.columns(inWidth: 420,
                                             layout: OfficeColumnLayout(count: 2, spacing: 20))
        let lines = (0..<9).map { line($0, CGFloat($0) * 155) }
        let withDefault = ColumnGeometry.placements(lines: lines, runOrigin: 0, firstPage: 0,
                                                    columns: columns, columnHeight: 300,
                                                    pitch: 320, leadingBand: 0)
        let spelledOut = ColumnGeometry.placements(lines: lines, runOrigin: 0, firstPage: 0,
                                                   columns: columns, columnHeight: 300,
                                                   pitch: 320, leadingBand: 0,
                                                   firstColumnHeight: 300)
        XCTAssertEqual(withDefault.count, spelledOut.count)
        for (k, v) in withDefault {
            XCTAssertEqual(v.x, spelledOut[k]?.x, "line \(k) x")
            XCTAssertEqual(v.y, spelledOut[k]?.y, "line \(k) y")
        }
    }

    /// A single column places nothing: there is no column to move a line into, and every document
    /// that declares none must be left exactly as it was.
    func testASingleColumnPlacesNothing() {
        let one = ColumnGeometry.columns(inWidth: 420, layout: OfficeColumnLayout(count: 1))
        XCTAssertTrue(ColumnGeometry.placements(lines: [line(0, 0), line(1, 500)], runOrigin: 0,
                                                firstPage: 0, columns: one, columnHeight: 300,
                                                pitch: 320, leadingBand: 0).isEmpty)
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
