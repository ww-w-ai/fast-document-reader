import XCTest
import AppKit
@testable import FastDocReader

/// What the painters read — opened boundaries, where each gap is, the page numbers a veto hides —
/// comes from the plan, and it describes the layout the plan produced. The painters draw into these
/// gaps; a state that disagrees with the lines puts a header or a page number across the text.
final class PlanPainterStateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PageViewOptionsStore.startingOptions = PageViewOptions(outline: true)
    }

    override func tearDown() {
        PageViewOptionsStore.reset()
        super.tearDown()
    }

    private func openPaged(hidingNumberAtBlock hidden: Int? = nil,
                           restartingAtBlock restart: Int? = nil) throws -> DocumentWindowController {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-painter-state-\(UUID().uuidString).hwp")
        let body = (0..<160).map { i in
            OfficeBlock.paragraph(spans: [Span(text: "paragraph number \(i) with enough words to wrap once or twice")])
        }
        doc.setOfficeContent(
            blocks: body, comments: [], archive: nil, images: [:], defaultBodyFontSize: 11,
            pageContentWidth: 400, pageMarginLeft: 60, pageMarginRight: 60,
            pageContentHeight: 300, pageMarginTop: 60, pageMarginBottom: 60,
            headers: [OfficeHeaderFooter(appliesTo: .defaultPages,
                                         blocks: [.paragraph(spans: [Span(text: "running head")])])],
            footers: [], masterPages: [], sectionStartBlocks: [0],
            pageBreakBlocks: [], keepWithNextBlocks: [],
            hidePageNumberBlocks: hidden.map { [$0] } ?? [],
            pageNumberRestartBlocks: restart.map { [OfficePageNumberRestart(block: $0, number: 1)] } ?? [],
            sections: [], anchoredObjects: [], lineGridPitch: nil)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        wc.paginateNow()
        return wc
    }

    private func lineRects(_ wc: DocumentWindowController) throws -> [NSRect] {
        let lm = try XCTUnwrap(wc.textView.layoutManager)
        let tc = try XCTUnwrap(wc.textView.textContainer)
        lm.ensureLayout(for: tc)
        var out: [NSRect] = []
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, _, _, _, _ in out.append(rect) }
        return out
    }

    /// Every boundary between two pages that both hold lines is an opened boundary, and its band
    /// begins where the last line above it ends and ends where the first line below it begins — on
    /// the screen grid, desk gap included.
    func testOpenedBoundariesAndBandsDescribeTheAppliedLines() throws {
        let wc = try openPaged()
        let d = wc.pageBandDelegate
        let pitch = d.pageContentHeight + d.band
        XCTAssertGreaterThan(d.deskGap, 0, "the screen grid carries a desk gap, or this proves nothing about it")
        let rects = try lineRects(wc)
        var byPage: [Int: [NSRect]] = [:]
        for rect in rects {
            byPage[Int(PageBandLayoutDelegate.page(of: rect.minY, leadingBand: d.leadingBand, pitch: pitch)), default: []].append(rect)
        }
        let pages = byPage.keys.sorted()
        XCTAssertGreaterThan(pages.count, 2, "the document must cross several page boundaries")
        for page in pages.dropLast() {
            guard let above = byPage[page], let below = byPage[page + 1] else { continue }
            XCTAssertTrue(d.openedBoundaries.contains(page), "boundary after page \(page + 1) is open")
            let band = try XCTUnwrap(d.openedBands[page], "an opened boundary has a gap")
            XCTAssertEqual(band.top, above.map(\.maxY).max()!, accuracy: 0.6, "the gap begins under the page's last line")
            XCTAssertEqual(band.top + band.height, below.map(\.minY).min()!, accuracy: 0.6,
                           "…and ends at the next page's first line")
        }
    }

    /// The delegate puts every line the plan names at the plan's top, and the first line of every page
    /// after the first starts that page's body: the plan moved it there, the typesetter alone would
    /// have left it running across the band.
    func testEveryTargetedLineStandsAtItsPlanTopAndEachPageStartsAtItsBody() throws {
        let wc = try openPaged()
        let d = wc.pageBandDelegate
        let lm = try XCTUnwrap(wc.textView.layoutManager)
        let tc = try XCTUnwrap(wc.textView.textContainer)
        let length = try XCTUnwrap(wc.textView.textStorage).length
        lm.ensureLayout(for: tc)
        let lines = PlanAppliedParity.lines(of: lm, tc, length: length)
        XCTAssertFalse(d.targets.isEmpty, "the plan names targets")
        for (loc, target) in d.targets {
            let line = try XCTUnwrap(lines[loc], "line at \(loc) is laid out")
            XCTAssertEqual(line.y, target.y, accuracy: 0.6, "line at \(loc) stands at its plan top")
        }
        let pitch = d.pageContentHeight + d.band
        var firstTop: [Int: CGFloat] = [:]
        for line in lines.values {
            let page = Int(PageBandLayoutDelegate.page(of: line.y, leadingBand: d.leadingBand, pitch: pitch))
            firstTop[page] = min(firstTop[page] ?? .greatestFiniteMagnitude, line.y)
        }
        XCTAssertGreaterThan(firstTop.count, 2, "the document must cross several page boundaries")
        for (page, top) in firstTop where page > 0 {
            XCTAssertEqual(top, d.leadingBand + CGFloat(page) * pitch, accuracy: 0.6,
                           "page \(page + 1)'s first line starts its body")
        }
    }

    /// A page that cites a note reserves its foot for it, the plan names which note it cites, and no
    /// body line on that page runs into the reservation.
    func testANoteBandIsReservedWhereThePlanCitesTheNote() throws {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-note-state-\(UUID().uuidString).hwp")
        func paragraph(_ i: Int) -> OfficeBlock {
            var spans = [Span(text: "paragraph number \(i) with enough words to wrap once or twice")]
            if i % 40 == 0 {
                var marker = Span(text: "\(i / 40 + 1))")
                marker.superscript = true
                marker.footnoteRef = i / 40 + 1
                spans.append(marker)
            }
            return .paragraph(spans: spans)
        }
        doc.setOfficeContent(
            blocks: (0..<160).map(paragraph), comments: [], archive: nil, images: [:], defaultBodyFontSize: 11,
            pageContentWidth: 400, pageMarginLeft: 60, pageMarginRight: 60,
            pageContentHeight: 300, pageMarginTop: 60, pageMarginBottom: 60,
            headers: [OfficeHeaderFooter(appliesTo: .defaultPages,
                                         blocks: [.paragraph(spans: [Span(text: "running head")])])],
            footers: [],
            footnotes: (1...4).map { OfficeFootnote(number: $0, blocks: [.paragraph(spans: [Span(text: "note \($0) text that is long enough to take a line or two of its own")])]) },
            masterPages: [], sectionStartBlocks: [0],
            pageBreakBlocks: [], keepWithNextBlocks: [],
            sections: [], anchoredObjects: [], lineGridPitch: nil)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        wc.paginateNow()
        let d = wc.pageBandDelegate
        XCTAssertFalse(wc.footnotePages.isEmpty, "the plan must say which page cites which note")
        XCTAssertEqual(Set(wc.footnotePages.values.flatMap { $0 }), [1, 2, 3, 4], "every cited note is placed")
        let pitch = d.pageContentHeight + d.band
        for (page, _) in wc.footnotePages {
            let band = try XCTUnwrap(d.noteBands[page], "page \(page + 1) cites a note, so it reserves room for it")
            XCTAssertGreaterThan(band, 0)
            for rect in try lineRects(wc) where Int(PageBandLayoutDelegate.page(of: rect.minY, leadingBand: d.leadingBand, pitch: pitch)) == page {
                XCTAssertLessThanOrEqual(rect.maxY - d.leadingBand, d.textBottom(ofPage: CGFloat(page)) + 0.6,
                                         "a body line on page \(page + 1) must stay above its note band")
            }
        }
    }

    /// A plan top-aligns the cells of the tables it flows line by line, and the next plan gives the
    /// document's own alignment back to a table it no longer flows: the observation always sees the
    /// document as authored, and the apply layout always agrees with the plan about which cells are top.
    func testCellAlignmentFollowsWhichTablesThePlanFlows() throws {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-align-state-\(UUID().uuidString).hwp")
        let rows: [[Cell]] = (0..<24).map { i in
            [Cell(blocks: [.paragraph(spans: [Span(text: "row \(i) of a table that is taller than its page")])],
                  verticalAlignment: .center)]
        }
        doc.setOfficeContent(
            blocks: [.paragraph(spans: [Span(text: "before")]), .table(rows: rows, headerRows: 0)],
            comments: [], archive: nil, images: [:], defaultBodyFontSize: 11,
            pageContentWidth: 400, pageMarginLeft: 60, pageMarginRight: 60,
            pageContentHeight: 200, pageMarginTop: 60, pageMarginBottom: 60,
            headers: [OfficeHeaderFooter(appliesTo: .defaultPages,
                                         blocks: [.paragraph(spans: [Span(text: "running head")])])],
            footers: [], masterPages: [], sectionStartBlocks: [0],
            pageBreakBlocks: [], keepWithNextBlocks: [],
            sections: [], anchoredObjects: [], lineGridPitch: nil)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        let storage = try XCTUnwrap(wc.textStorageRef)
        func alignments(authored: Bool = false) -> Set<Int> {
            var out = Set<Int>()
            storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                for block in (value as? NSParagraphStyle)?.textBlocks ?? [] {
                    if let cell = block as? NSTextTableBlock {
                        out.insert((authored ? cell.authoredVerticalAlignment : cell.verticalAlignment).rawValue)
                    }
                }
            }
            return out
        }
        let top = NSTextBlock.VerticalAlignment.topAlignment.rawValue
        let middle = NSTextBlock.VerticalAlignment.middleAlignment.rawValue

        wc.paginateNow()
        XCTAssertGreaterThan(((wc.lastPlan?["flowedTables"] as? [Any]) ?? []).count, 0,
                             "a table taller than its page is broken where it stands")
        XCTAssertEqual(alignments(), [top], "the cells of a table the plan flows are top-aligned")
        XCTAssertEqual(alignments(authored: true), [middle], "…and what the document asked for is remembered")

        // The same document on a page tall enough to hold the table: nothing is flowed any more.
        wc.configurePageBand(pageContentHeight: 5000, band: wc.pageBandDelegate.band)
        wc.paginateNow()
        XCTAssertEqual(((wc.lastPlan?["flowedTables"] as? [Any]) ?? []).count, 0,
                       "on a page that holds it the table is not flowed")
        XCTAssertEqual(alignments(), [middle], "…and its cells go back to the alignment the document asked for")
    }

    /// The plan's veto is the veto the painter reads, and the number a page shows follows the plan.
    func testThePageNumberTheDocumentVetoesIsTheOneThePlanHides() throws {
        let plain = try openPaged()
        XCTAssertTrue(plain.hiddenPageNumberPages.isEmpty)
        let vetoed = try openPaged(hidingNumberAtBlock: 80)
        XCTAssertFalse(vetoed.hiddenPageNumberPages.isEmpty, "the document's veto must reach the painter through the plan")
        XCTAssertLessThan(vetoed.hiddenPageNumberPages.count, vetoed.printPageCount,
                          "it hides the page the marked paragraph is on, not every page")
    }

    func testARestartIsCountedByThePlan() throws {
        let wc = try openPaged(restartingAtBlock: 80)
        let restartedPage = try XCTUnwrap((0..<wc.printPageCount).first { wc.displayedPageNumber($0) == 1 && $0 > 0 },
                                          "the page the restart marks must show 1 again")
        XCTAssertEqual(wc.displayedPageNumber(restartedPage + 1), 2)
        XCTAssertEqual(wc.displayedPageNumber(0), 1)
    }
}
