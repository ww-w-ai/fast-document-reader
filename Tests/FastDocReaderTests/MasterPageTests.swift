import XCTest
import AppKit
@testable import FastDocReader

/// The 바탕쪽 path: rhwp's `masterPages` export → `OfficeMasterPage` → where the painter puts each
/// object on a sheet. Synthetic envelopes only, so no HWP file or FFI is needed — the same discipline
/// `HwpMappingTests` uses for every other field of the same export.
final class MasterPageTests: XCTestCase {

    /// One master page carrying every object kind, in the export's own shape. `section` defaults to
    /// the body section so the filter is not what a test about mapping is measuring.
    private func envelope(section: Int = 2, bodySection: Int? = 2, applyTo: String = "both",
                          objects: String) -> String {
        let body = bodySection.map { "\"bodySection\":\($0)," } ?? ""
        return """
        {"v":1,\(body)"masterPages":[{"section":\(section),"applyTo":"\(applyTo)","objects":[\(objects)]}],"blocks":[]}
        """
    }

    /// A text box at the bottom right of the sheet with a page-number field in it — the number box a
    /// real Korean manual puts its page number in (measured at (446, 680) on the 편람).
    private let numberBox = """
    {"x":44600,"y":67986,"w":3700,"h":2200,"kind":"text",
     "blocks":[{"t":"para","spans":[{"text":"1","pageNumberField":"page"}]}]}
    """

    private let sideTab = """
    {"x":50062,"y":21855,"w":6483,"h":11368,"kind":"shape",
     "paths":[{"d":[["M",0,0],["L",6483,0],["L",6483,11368],["Z"]],
               "stroke":{"type":"solid","widthPt":1,"color":"#000000"}}]}
    """

    // MARK: mapping

    func testMasterPageObjectsDecodeWithPaperCoordinatesInPoints() throws {
        // HWPUNIT ÷100 = points, the same conversion every other extent in this export uses.
        let r = try HwpReader.mapJSON(envelope(objects: numberBox + "," + sideTab))
        XCTAssertEqual(r.masterPages.count, 1)
        let objects = r.masterPages[0].objects
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(objects[0].frame, CGRect(x: 446, y: 679.86, width: 37, height: 22))
        XCTAssertEqual(objects[1].frame, CGRect(x: 500.62, y: 218.55, width: 64.83, height: 113.68))
        guard case .text = objects[0].content else { return XCTFail("number box should map to text") }
        guard case .drawing = objects[1].content else { return XCTFail("side tab should map to a drawing") }
    }

    func testMasterPageOfAnotherSectionIsDropped() throws {
        // Invariant 77's rule, applied to paper furniture: a template belonging to the COVER section
        // would otherwise stamp the cover's artwork onto every body page.
        let r = try HwpReader.mapJSON(envelope(section: 0, objects: numberBox))
        XCTAssertTrue(r.masterPages.isEmpty)
    }

    func testEverySectionIsKeptWhenTheParserNamedNoBodySection() throws {
        // A parser predating `bodySection` leaves it nil, and then filtering by it would drop
        // everything — the same degradation the running-head filter makes.
        let r = try HwpReader.mapJSON(envelope(section: 7, bodySection: nil, objects: numberBox))
        XCTAssertEqual(r.masterPages.count, 1)
    }

    func testDegenerateTextBoxIsDroppedRatherThanGivenAnInventedWidth() throws {
        // Measured on the 편람: one master text box states a width of ZERO (a rotated tab label).
        let zeroWidth = """
        {"x":55559,"y":6129,"w":0,"h":27116,"kind":"text",
         "blocks":[{"t":"para","spans":[{"text":"제1편"}]}]}
        """
        XCTAssertTrue(try HwpReader.mapJSON(envelope(objects: zeroWidth)).masterPages.isEmpty)
    }

    func testAbsentMasterPagesMeansNone() throws {
        // A parser built before the export behaves exactly as this reader did before the feature.
        XCTAssertTrue(try HwpReader.mapJSON("{\"v\":1,\"blocks\":[]}").masterPages.isEmpty)
    }

    func testAnObjectThatCarriesBothAFrameAndTextProducesBoth() throws {
        // A Korean number box is a rounded rectangle WITH a number in it — the paths and the blocks
        // are not alternatives, and the frame must be drawn under the text.
        let framedNumber = """
        {"x":44600,"y":67986,"w":3700,"h":2200,"kind":"text",
         "paths":[{"d":[["M",0,0],["L",3700,0]],"stroke":{"type":"solid","widthPt":1,"color":"#000000"}}],
         "blocks":[{"t":"para","spans":[{"text":"1","pageNumberField":"page"}]}]}
        """
        let objects = try HwpReader.mapJSON(envelope(objects: framedNumber)).masterPages[0].objects
        XCTAssertEqual(objects.count, 2)
        guard case .drawing = objects[0].content else { return XCTFail("the frame draws first") }
        guard case .text = objects[1].content else { return XCTFail("the number draws on top") }
    }

    // MARK: draw order

    func testALowerZOrderDrawsFirstEvenWhenItIsStoredLast() throws {
        // Measured on the 편람: the full-page artwork is stored FIRST and the running title SECOND,
        // and the artwork declares the LOWER z-order. Drawn as stored, the picture painted over the
        // title on all 434 pages. Asserted with two TEXT boxes rather than the picture itself, which
        // would need an image provider to survive the map — the comparison is the same one.
        let low = """
        {"x":0,"y":0,"w":100,"h":100,"kind":"text","plane":2,"z":9,
         "blocks":[{"t":"para","spans":[{"text":"front"}]}]}
        """
        let high = """
        {"x":0,"y":0,"w":100,"h":100,"kind":"text","plane":2,"z":1,
         "blocks":[{"t":"para","spans":[{"text":"back"}]}]}
        """
        let objects = try HwpReader.mapJSON(envelope(objects: low + "," + high)).masterPages[0].objects
        XCTAssertEqual(objects.count, 2)
        guard case .text(let firstDrawn) = objects[0].content,
              case .paragraph(let spans, _, _, _, _) = firstDrawn[0] else {
            return XCTFail("expected two text boxes")
        }
        XCTAssertEqual(spans.first?.text, "back", "the lower z-order draws first")
    }

    func testTheBehindTextBandDrawsUnderAnOrdinaryObjectWithALowerZOrder() throws {
        // Plane beats z-order, exactly as rhwp's own `paper_node_sort_key` compares them.
        let behind = """
        {"x":0,"y":0,"w":100,"h":100,"kind":"text","plane":1,"z":99,
         "blocks":[{"t":"para","spans":[{"text":"behind"}]}]}
        """
        let ordinary = """
        {"x":0,"y":0,"w":100,"h":100,"kind":"text","plane":2,"z":1,
         "blocks":[{"t":"para","spans":[{"text":"ordinary"}]}]}
        """
        let objects = try HwpReader.mapJSON(envelope(objects: ordinary + "," + behind)).masterPages[0].objects
        guard case .text(let firstDrawn) = objects[0].content,
              case .paragraph(let spans, _, _, _, _) = firstDrawn[0] else {
            return XCTFail("expected two text boxes")
        }
        XCTAssertEqual(spans.first?.text, "behind")
    }

    func testObjectsWithNoOrderingKeepTheirStoredOrder() throws {
        // A parser predating `plane`/`z` — the stored order is all there is, and it must survive.
        let a = """
        {"x":0,"y":0,"w":100,"h":100,"kind":"text","blocks":[{"t":"para","spans":[{"text":"a"}]}]}
        """
        let b = """
        {"x":0,"y":0,"w":100,"h":100,"kind":"text","blocks":[{"t":"para","spans":[{"text":"b"}]}]}
        """
        let objects = try HwpReader.mapJSON(envelope(objects: a + "," + b)).masterPages[0].objects
        guard case .text(let first) = objects[0].content,
              case .paragraph(let spans, _, _, _, _) = first[0] else { return XCTFail("expected text") }
        XCTAssertEqual(spans.first?.text, "a")
    }

    // MARK: which template covers which page

    func testEvenTemplateCoversEvenPageNumbers() {
        let even = OfficeMasterPage(section: 2, appliesTo: .evenPages, objects: [])
        let both = OfficeMasterPage(section: 2, appliesTo: .defaultPages, objects: [])
        // pageIndex is 0-based, so index 1 is the human's page 2.
        XCTAssertEqual(MasterPagePainter.applicablePage([both, even], pageIndex: 1), even)
        XCTAssertEqual(MasterPagePainter.applicablePage([both, even], pageIndex: 0), both)
        XCTAssertEqual(MasterPagePainter.applicablePage([both, even], pageIndex: 2), both)
    }

    func testAnEvenOnlyDocumentLeavesOddPagesToItsOwnOnlyTemplate() {
        // `applyTo:"odd"` folds into `.defaultPages` (see `HeaderFooterApplicability`), so a document
        // declaring only an even template has nothing else to fall back to — its own entry stands
        // rather than the page being silently blank.
        let even = OfficeMasterPage(section: 2, appliesTo: .evenPages, objects: [])
        XCTAssertEqual(MasterPagePainter.applicablePage([even], pageIndex: 0), even)
    }

    // MARK: the section a page is on

    func testATemplateFromAnotherSectionIsNotUsedForThisPage() {
        // The defect this exists to prevent, reported on sight: one section's chapter title printed
        // on the cover, on the table of contents and on 400 pages of other chapters.
        let cover = OfficeMasterPage(section: 0, appliesTo: .defaultPages, objects: [])
        let body = OfficeMasterPage(section: 2, appliesTo: .defaultPages, objects: [])
        XCTAssertEqual(MasterPagePainter.applicablePage([cover, body], pageIndex: 0, section: 0), cover)
        XCTAssertEqual(MasterPagePainter.applicablePage([cover, body], pageIndex: 9, section: 2), body)
    }

    func testASectionWithNoTemplateOfItsOwnDrawsNothing() {
        // Measured on the 편람: two of its 14 sections declare no master page at all, and one more
        // declares a pair with no objects in them. Borrowing another section's would be an invention.
        let body = OfficeMasterPage(section: 2, appliesTo: .defaultPages, objects: [])
        XCTAssertNil(MasterPagePainter.applicablePage([body], pageIndex: 0, section: 0))
    }

    func testAnUnknownSectionFallsBackToEveryTemplate() {
        // A parser that never said where a section starts — the single-answer behaviour this had
        // before per-page selection, rather than a blank document.
        let body = OfficeMasterPage(section: 2, appliesTo: .defaultPages, objects: [])
        XCTAssertEqual(MasterPagePainter.applicablePage([body], pageIndex: 0, section: nil), body)
    }
}
