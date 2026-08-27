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

/// The running head's half of the same per-section rule (invariant 78): entries are kept for every
/// section and chosen by the page's own, and the band furniture is anchored to the PAPER rather than
/// to the gap layout happened to open.
final class SectionRunningHeadTests: XCTestCase {

    func testAnEntryFromAnotherSectionIsNotPaintedOnThisPage() {
        let appendix = OfficeHeaderFooter(appliesTo: .defaultPages, blocks: [], section: 12)
        let body = OfficeHeaderFooter(appliesTo: .defaultPages, blocks: [], section: 2)
        XCTAssertEqual(PageBandPainter.applicableEntry([appendix, body], pageIndex: 4, section: 2), body)
        XCTAssertEqual(PageBandPainter.applicableEntry([appendix, body], pageIndex: 4, section: 12), appendix)
    }

    func testAnEntryThatNamesNoSectionStillApplies() {
        // docx and odt never say which section a header came from, and must keep behaving as before.
        let anySection = OfficeHeaderFooter(appliesTo: .defaultPages, blocks: [])
        XCTAssertEqual(PageBandPainter.applicableEntry([anySection], pageIndex: 0, section: 7), anySection)
    }

    func testTheFooterSitsAtThePAPERBottomEvenWhenTheGapOpensMidPage() {
        // Measured on a real manual's appendix: a page whose last line ended early opens a gap that
        // begins in the middle of the sheet, and dividing THAT gap printed the page number at y≈451
        // of 754 — across the middle of the page.
        let gap = (top: CGFloat(300), height: CGFloat(400))
        let sheetEdge = PageBandPainter.sheetEdge(gridTop: 600, gap: gap, bottomMargin: 60)
        XCTAssertEqual(sheetEdge, 660)
        let top = PageBandPainter.footerTop(gap: gap, sheetEdge: sheetEdge, distance: nil, footerHeight: 20)
        XCTAssertEqual(top, 640, "the footer belongs just above the paper's edge, not in the middle of the gap")
    }

    func testTheHeaderSitsBelowTheSheetEdgeRatherThanOnThePreviousPage() {
        // The same fallback put the NEXT page's number at the bottom of the PREVIOUS page's paper.
        let gap = (top: CGFloat(300), height: CGFloat(400))
        let top = PageBandPainter.headerTop(gap: gap, sheetEdge: 660, distance: nil, headerHeight: 20)
        XCTAssertEqual(top, 660)
    }
}

/// Ink pinned to a sheet stays ON that sheet. The screen draws every page into ONE continuous view,
/// so an object bigger than its paper — a chapter divider's numeral is 736pt on a 754pt sheet — ran
/// off the page, across the desk and onto the next one.
final class MasterPageSheetClipTests: XCTestCase {

    /// Drawn into a canvas holding TWO sheets with a desk gap between them, with an object on the
    /// first that is taller than the paper. Nothing may be painted below the first sheet's bottom.
    func testAnObjectTallerThanItsPaperDoesNotPaintOnTheNextSheet() throws {
        let sheet = CGRect(x: 10, y: 10, width: 80, height: 100)
        let canvas = NSImage(size: NSSize(width: 100, height: 260))

        let art = NSImage(size: NSSize(width: 60, height: 200))
        art.lockFocus(); NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 60, height: 200).fill(); art.unlockFocus()

        let object = OfficeMasterObject(frame: CGRect(x: 10, y: 40, width: 60, height: 200),
                                        content: .image(art))
        let content = MasterPageContent(pages: [], theme: RenderTheme(baseFontSize: 13),
                                        documentDefaultFontSize: 11,
                                        pageContentWidth: 80)

        // A bitmap with the SAME flipped CTM the text view draws under — `lockFocusFlipped` is not
        // that: it sets a flag the AppKit helpers consult while raw geometry keeps the unflipped
        // axis, so a clip and a picture end up in two different coordinate systems and the test
        // measures the harness instead of the painter.
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 260, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let g = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        // Painted white FIRST: a transparent pixel reads as rgb(0,0,0) through `colorAt`, so an
        // unpainted canvas would look like solid ink everywhere.
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 100, height: 260).fill()
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: 260)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        MasterPagePainter.draw(object, onSheet: sheet, pageIndex: 0, totalPages: 2,
                               content: content, visibleRect: NSRect(x: 0, y: 0, width: 100, height: 260))
        NSGraphicsContext.restoreGraphicsState()
        _ = canvas

        func isInk(_ x: Int, _ y: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return c.redComponent < 0.5 && c.greenComponent < 0.5 && c.blueComponent < 0.5
        }
        XCTAssertTrue(isInk(40, 100), "the object must still be drawn inside its own sheet")
        XCTAssertFalse(isInk(40, 130), "nothing may be painted on the desk below the sheet")
        XCTAssertFalse(isInk(40, 180), "and certainly not on the next sheet")
    }
}

/// `sectionsHidingMasterPage` — a section that says "no 바탕쪽" gets none, however many templates it
/// declares (`MasterPagePainter.swift:71-74`). Drives the SHEET-WALK overload, which no other test
/// in this file calls, using the same flipped-bitmap harness `MasterPageSheetClipTests` built —
/// an object is a solid black image so "drew nothing" is a pixel read rather than a fresh mechanism.
final class MasterPageSectionVetoTests: XCTestCase {

    private func blackImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    /// One sheet, one master page belonging to section 2 with a black square covering the middle of
    /// it, drawn through `draw(_:sheets:totalPages:visibleRect:sectionOfPage:)`. Returns whether ink
    /// landed at the square's centre.
    private func drewInk(hiding: Set<Int>, sectionOfPage: @escaping (Int) -> Int?) throws -> Bool {
        let sheet = CGRect(x: 10, y: 10, width: 80, height: 100)
        let object = OfficeMasterObject(frame: CGRect(x: 0, y: 0, width: 60, height: 60),
                                        content: .image(blackImage(size: NSSize(width: 60, height: 60))))
        let page = OfficeMasterPage(section: 2, appliesTo: .defaultPages, objects: [object])
        let content = MasterPageContent(pages: [page], sectionsHidingMasterPage: hiding,
                                        theme: RenderTheme(baseFontSize: 13),
                                        documentDefaultFontSize: 11, pageContentWidth: 80)

        // The same flipped-bitmap setup `MasterPageSheetClipTests` uses — a real CTM, not
        // `lockFocusFlipped`, which leaves the clip and the picture in two different coordinate
        // systems and would measure the harness instead of the painter.
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 120, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let g = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 100, height: 120).fill()
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: 120)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        MasterPagePainter.draw(content, sheets: [sheet], totalPages: 1,
                               visibleRect: NSRect(x: 0, y: 0, width: 100, height: 120),
                               sectionOfPage: sectionOfPage)
        NSGraphicsContext.restoreGraphicsState()

        guard let colour = rep.colorAt(x: 40, y: 40)?.usingColorSpace(.deviceRGB) else { return false }
        return colour.redComponent < 0.5 && colour.greenComponent < 0.5 && colour.blueComponent < 0.5
    }

    func testASectionOnTheHideListDrawsNothing() throws {
        let drewInk = try drewInk(hiding: [2], sectionOfPage: { _ in 2 })
        XCTAssertFalse(drewInk, "section 2 vetoed its own master page — nothing should have painted")
    }

    func testASectionNotOnTheHideListStillDrawsItsTemplate() throws {
        // Selective, not a global switch: the SAME page's template still paints when the veto names
        // a different section.
        let drewInk = try drewInk(hiding: [5], sectionOfPage: { _ in 2 })
        XCTAssertTrue(drewInk, "the veto names a different section — section 2's template should still paint")
    }

    func testTheVetoDoesNotFireWhenTheSectionOfThePageIsUnknown() throws {
        // `sectionOfPage` returning nil is "the parser never said where a section starts"
        // (`MasterPagePainter.swift:70`'s `if let section` guard) — even naming section 2 on the hide
        // list must not suppress the fallback-to-every-template page this produces.
        let drewInk = try drewInk(hiding: [2], sectionOfPage: { _ in nil })
        XCTAssertTrue(drewInk, "an unknown section must fall back to every template, not to the veto")
    }
}

/// Where an object the document pins to the PAPER lands — rhwp's own placement rule, restated for
/// the two references this reader can honour (invariant 78).
final class AnchoredObjectPlacementTests: XCTestCase {

    private let paper = HwpReader.PaperGeometry(contentWidth: 400, contentHeight: 600,
                                                marginLeft: 70, marginTop: 80,
                                                marginRight: 60, marginBottom: 90)

    func testPaperRelativeTopLeftIsTheSheetsOwnCorner() {
        let f = HwpReader.anchoredFrame(size: CGSize(width: 100, height: 50),
                                        vertRelTo: "paper", horzRelTo: "paper",
                                        vertAlign: "top", horzAlign: "left",
                                        offset: CGPoint(x: 10, y: 20), page: paper)
        XCTAssertEqual(f, CGRect(x: 10, y: 20, width: 100, height: 50))
    }

    func testPageRelativeMeasuresFromTheBodyArea() {
        let f = HwpReader.anchoredFrame(size: CGSize(width: 100, height: 50),
                                        vertRelTo: "page", horzRelTo: "page",
                                        vertAlign: "top", horzAlign: "left",
                                        offset: .zero, page: paper)
        XCTAssertEqual(f, CGRect(x: 70, y: 80, width: 100, height: 50))
    }

    func testBottomAndCentreMeasureTheWayTheRendererDoes() {
        // `calc_shape_bottom_y`: centre puts the object in the middle of the reference and ADDS the
        // offset; bottom measures the offset UP from the reference's own bottom edge.
        let centred = HwpReader.anchoredFrame(size: CGSize(width: 100, height: 50),
                                              vertRelTo: "paper", horzRelTo: "paper",
                                              vertAlign: "center", horzAlign: "center",
                                              offset: .zero, page: paper)
        XCTAssertEqual(centred?.midY ?? 0, paper.paperHeight / 2, accuracy: 0.01)
        XCTAssertEqual(centred?.midX ?? 0, paper.paperWidth / 2, accuracy: 0.01)
        let bottom = HwpReader.anchoredFrame(size: CGSize(width: 100, height: 50),
                                             vertRelTo: "paper", horzRelTo: "paper",
                                             vertAlign: "bottom", horzAlign: "left",
                                             offset: CGPoint(x: 0, y: 30), page: paper)
        XCTAssertEqual(bottom?.maxY ?? 0, paper.paperHeight - 30, accuracy: 0.01)
    }

    func testAParagraphAnchoredObjectIsNotPlacedByTheSheetRule() {
        // Its VERTICAL reference is a paragraph, whose position only layout knows, so the sheet rule
        // must not answer for it — `paragraphAnchoredPlacement` does, and finishes at draw time.
        XCTAssertNil(HwpReader.anchoredFrame(size: CGSize(width: 10, height: 10),
                                             vertRelTo: "para", horzRelTo: "para",
                                             vertAlign: "top", horzAlign: "left",
                                             offset: .zero, page: paper))
    }

    // MARK: Anchored to the PARAGRAPH (invariant 81's remaining half)

    func testParagraphAnchoredHorizontalIsSettledAtReadTime() {
        // `para`/`column` measure horizontally against the text column, which this reader lays out
        // at one fixed width — so there is nothing here for layout to answer.
        let p = HwpReader.paragraphAnchoredPlacement(
            size: CGSize(width: 100, height: 50), vertRelTo: "para", horzRelTo: "column",
            vertAlign: "top", horzAlign: "left", offset: CGPoint(x: 12, y: 34), page: paper)
        XCTAssertEqual(p?.frame.minX, paper.marginLeft + 12)
        XCTAssertEqual(p?.frame.width, 100)
        XCTAssertEqual(p?.frame.height, 50)
        XCTAssertEqual(p?.anchor, ParagraphAnchor(align: .top, offset: 34))
    }

    func testParagraphAnchoredHorizontalHonoursCentreAndRight() {
        let centred = HwpReader.paragraphAnchoredPlacement(
            size: CGSize(width: 100, height: 50), vertRelTo: "para", horzRelTo: "paper",
            vertAlign: "top", horzAlign: "center", offset: .zero, page: paper)
        XCTAssertEqual(centred?.frame.midX ?? 0, paper.paperWidth / 2, accuracy: 0.01)
        let right = HwpReader.paragraphAnchoredPlacement(
            size: CGSize(width: 100, height: 50), vertRelTo: "para", horzRelTo: "column",
            vertAlign: "top", horzAlign: "right", offset: CGPoint(x: 20, y: 0), page: paper)
        XCTAssertEqual(right?.frame.maxX ?? 0, paper.marginLeft + paper.contentWidth - 20, accuracy: 0.01)
    }

    func testAPaperAnchoredObjectIsNotAnsweredTwice() {
        // The two placement rules must partition the vocabulary: a paper/page-relative object is
        // already fully placed, and answering it here as well would give it two positions.
        XCTAssertNil(HwpReader.paragraphAnchoredPlacement(
            size: CGSize(width: 10, height: 10), vertRelTo: "paper", horzRelTo: "paper",
            vertAlign: "top", horzAlign: "left", offset: .zero, page: paper))
    }

    /// The vertical half, finished the way the draw pass finishes it: the reference is the anchoring
    /// LINE, and the align says which of its edges the offset is measured from.
    func testParagraphAnchorMeasuresFromTheAlignedEdgeOfTheLine() {
        let top = ParagraphAnchor(align: .top, offset: 6)
        XCTAssertEqual(top.top(lineTop: 200, lineHeight: 18, objectHeight: 40), 206)

        let centre = ParagraphAnchor(align: .center, offset: 0)
        XCTAssertEqual(centre.top(lineTop: 200, lineHeight: 18, objectHeight: 40), 200 + (18 - 40) / 2,
                       "centre puts the object's middle on the line's middle, even when it is taller")

        let bottom = ParagraphAnchor(align: .bottom, offset: 5)
        XCTAssertEqual(bottom.top(lineTop: 200, lineHeight: 18, objectHeight: 40) + 40, 200 + 18 - 5,
                       "bottom measures the offset UP from the line's own bottom edge")
    }

    /// The defect the rejected float layer shipped: with the offsets alone, every object is placed as
    /// if it were top-aligned. This asserts the three aligns actually DIVERGE, so a regression that
    /// dropped the align would fail here rather than look plausible.
    func testTheThreeAlignsDoNotAgree() {
        let ys = [ParagraphAnchor.Align.top, .center, .bottom].map {
            ParagraphAnchor(align: $0, offset: 4).top(lineTop: 100, lineHeight: 60, objectHeight: 20)
        }
        XCTAssertEqual(Set(ys).count, 3, "top/center/bottom must land in three different places: \(ys)")
    }
}
