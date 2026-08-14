import XCTest
import AppKit
@testable import FastDocReader

/// The View menu's three page toggles — page outline, header, footer
/// (`paged-view-options-design.md`).
///
/// The property the whole feature rests on, and the one the design doc warns is easy to get wrong:
/// this is NOT a visibility flag. The comments panel can set a bool and repaint because its marks sit
/// on top of glyphs that do not move (invariant 38); "쭉 연결되어 보이고" means the band must not be
/// RESERVED, and the reservation is layout. So the tests below assert on the reservation
/// (`PageBandLayoutDelegate.band`/`shiftCount`) and on laid-out HEIGHT, not on what was painted.
final class PageViewOptionsTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-viewopts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        FontSizeStore.startingSize = FontSizeStore.defaultSize
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        PageViewOptionsStore.reset()
    }

    override func tearDownWithError() throws {
        FontSizeStore.startingSize = FontSizeStore.defaultSize
        PageViewOptionsStore.reset()
        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: - (1) The rule, on its own

    /// The three toggles resolve to two derived answers, and each one is load-bearing somewhere else:
    /// whether the band exists at all when nothing is drawn in it, and whether the page-break
    /// hairline is drawn.
    func testTheDerivedRules() {
        XCTAssertTrue(PageViewOptions(outline: true).separatesPages,
                      "the outline needs the space between sheets even with nothing in it")
        XCTAssertFalse(PageViewOptions(outline: false).separatesPages)
    }

    /// The outline is the master: with no page drawn there is nothing for a header, a footer or a
    /// table break to be about, so the store reports all three off while KEEPING what was chosen.
    func testTheOutlineIsTheMasterSwitch() {
        let chosen = PageViewOptions(outline: false, splitTables: true)
        XCTAssertEqual(chosen.underOutlineRule,
                       PageViewOptions(outline: false, masterPage: false, splitTables: false),
                       "the master page is under the outline too — no sheet, nothing to put on it")
        let withPages = PageViewOptions(outline: true, splitTables: true)
        XCTAssertEqual(withPages.underOutlineRule, withPages, "with a page, nothing is derived away")

        PageViewOptionsStore.reset()
        defer { PageViewOptionsStore.reset() }
        PageViewOptionsStore.current = chosen
        XCTAssertEqual(PageViewOptionsStore.current.header, false, "the reader shows no header")
        XCTAssertEqual(PageViewOptionsStore.intent.splitTables, true, "the split choice is remembered")
    }

    /// Defaults are all on, and a never-written preference must read that way rather than as the
    /// `false` `UserDefaults.bool(forKey:)` hands back for a missing key.
    func testAFreshMachineGetsTheDefaultsNotFalse() {
        PageViewOptionsStore.reset()
        XCTAssertEqual(PageViewOptionsStore.current, PageViewOptions.default)
        XCTAssertEqual(PageViewOptions.default, PageViewOptions(outline: true))
    }

    // MARK: - (2) All three off IS the pre-paged code path

    /// THE design doc's own acceptance test: with everything off the document must lay out exactly as
    /// one whose reader found no header or footer at all — same height, and no line shifted. Asserted
    /// against a SECOND document that genuinely has none, rather than against a remembered number.
    func testWithEverythingOffTheDocumentLaysOutLikeOneWithNoHeaderOrFooter() throws {
        PageViewOptionsStore.current = PageViewOptions(outline: false)
        let (_, withFurniture) = try openPaged()
        let (_, without) = try openPaged(headerAndFooter: false)

        XCTAssertFalse(withFurniture.pageBandDelegate.isActive,
                       "everything off must reserve no band — that is the pre-paged path")
        XCTAssertEqual(withFurniture.pageBandDelegate.shiftCount, 0, "…so no line was moved")
        XCTAssertEqual(height(of: withFurniture), height(of: without), accuracy: 0.01,
                       "and the laid-out extent is identical to a document that never had either")
    }

    /// The outline alone reserves the document's own two margins between sheets, even with nothing
    /// drawn in them — otherwise the sheets would sit edge to edge and read as one long page.
    func testTheOutlineAloneStillSeparatesTheSheets() throws {
        PageViewOptionsStore.current = PageViewOptions(outline: true)
        let (_, wc) = try openPaged()
        XCTAssertTrue(wc.pageBandDelegate.isActive)
        XCTAssertEqual(wc.pageBandDelegate.band,
                       Self.marginTop + Self.marginBottom + RenderTheme.pageDeskGap, accuracy: 0.01,
                       "the space between two sheets is the document's own two margins (invariant 57e) " +
                       "plus the desk the reader draws between them — the one part no document states")
        XCTAssertGreaterThan(wc.pageBandDelegate.shiftCount, 0, "…and lines really were moved for it")
    }

    // MARK: - (3) The three act independently

    /// Header and footer are the PAGE's, not two toggles of their own — they live in its two margins,
    /// so hiding the page hides them and there is no configuration in which one is drawn without the
    /// other. (Two separate menu items existed for a while and were REMOVED at the owner's
    /// instruction: *"아웃라인 보이면 같이 보이는거고, 아니면 함께 안 보이는 것임"*.)
    func testTheOutlineCarriesBothHeaderAndFooter() throws {
        PageViewOptionsStore.current = PageViewOptions(outline: true)
        let (_, on) = try openPaged()
        let content = try XCTUnwrap(on.pageBandContent)
        XCTAssertFalse(content.headers.isEmpty, "a page draws its own header")
        XCTAssertFalse(content.footers.isEmpty, "and its own footer")
        XCTAssertGreaterThan(content.headerHeight, 0)
        XCTAssertGreaterThan(content.footerHeight, 0)

        PageViewOptionsStore.current = PageViewOptions(outline: false)
        let (_, off) = try openPaged()
        XCTAssertNil(off.pageBandContent, "no page, no band — and so neither of the two")
        XCTAssertFalse(off.pageBandDelegate.isActive, "…and nothing reserved for them")
    }


    /// The outer margins are the SHEET's. With no sheet drawn, the only reason to reserve room above
    /// the first line or below the last is a header or footer that needs it — so hiding them takes
    /// the room with them, which is what "쭉 연결되어" has to mean at the document's two ends.
    func testWithNoOutlineTheOuterMarginsBelongToTheHeaderAndFooterAlone() throws {
        PageViewOptionsStore.current = PageViewOptions(outline: false)
        let (_, wc) = try openPaged()
        XCTAssertEqual(wc.pageBandDelegate.leadingBand, 0, accuracy: 0.01)
        XCTAssertEqual(wc.pageBandDelegate.trailingBand, 0, accuracy: 0.01)

        PageViewOptionsStore.current = PageViewOptions(outline: true)
        let (_, sheets) = try openPaged()
        XCTAssertEqual(sheets.pageBandDelegate.leadingBand, Self.marginTop, accuracy: 0.01,
                       "…and with a sheet drawn, page 1 gets its own full top margin")
        XCTAssertEqual(sheets.pageBandDelegate.trailingBand, Self.marginBottom, accuracy: 0.01)
    }

    /// Turning the outline off leaves NO band at all — the header and footer go with it, so there is
    /// nothing left to paint and nothing left to mark a boundary with. (The page-break hairline this
    /// case used to check no longer exists: it only ever drew in the band-without-sheets state, which
    /// the outline's master rule removed.)
    func testWithNoOutlineThereIsNoBandToPaint() throws {
        PageViewOptionsStore.current = PageViewOptions(outline: true)
        let (_, on) = try openPaged()
        XCTAssertNotNil(on.pageBandContent)
        XCTAssertTrue(on.pageBandDelegate.isActive)

        PageViewOptionsStore.current = PageViewOptions(outline: false)
        let (_, off) = try openPaged()
        XCTAssertNil(off.pageBandContent, "a header the outline turned off must not be painted")
        XCTAssertFalse(off.pageBandDelegate.isActive, "…and must not reserve space either")
    }

    // MARK: - (4) A toggle must not rebuild, and must not lose the reader's place

    /// Invariant 57: a paged document is reproduced, not re-typeset. A toggle changes where lines
    /// SIT; it must never reach `MarkdownDocument.render`, whose rebuild is invariant 56b's freeze.
    func testTogglingRebuildsNothing() throws {
        let (doc, wc) = try openPaged()
        let generation = doc.renderGeneration
        let column = try XCTUnwrap(wc.textView.textContainer?.size.width)
        let length = wc.textStorageRef?.length

        wc.togglePageOutline(nil)
        waitForAsyncTail()

        XCTAssertEqual(wc.pageOptionChangeCount, 1, "the toggle must actually do something")
        XCTAssertEqual(doc.renderGeneration, generation, "…but never rebuild the document")
        XCTAssertEqual(try XCTUnwrap(wc.textView.textContainer?.size.width), column,
                       "…nor re-wrap it: the reading column of a paged document never moves")
        XCTAssertEqual(wc.textStorageRef?.length, length, "…nor change a character of it")
    }

    /// Invariant 24/55a, and the design doc's own warning to measure this DEEP rather than at the
    /// top: the document's height changes by `band × pageCount`, so a toggle that restored a raw
    /// scroll offset — or restored before the new layout existed — would land the reader somewhere
    /// else entirely. Judged on the CHARACTER at the top of the viewport, which is what a reader
    /// actually keeps.
    func testTheReadingPositionSurvivesAToggleFromDeepInTheDocument() throws {
        let (_, wc) = try openPaged()
        let storage = try XCTUnwrap(wc.textStorageRef)
        let deep = Int(Double(storage.length) * 0.75)
        wc.scrollCharToTop(deep)
        let before = wc.topVisibleCharIndex()
        XCTAssertGreaterThan(before, storage.length / 2,
                             "precondition: the reader really is deep in the document, not at the top")

        wc.togglePageOutline(nil)
        waitForAsyncTail(0.8)

        let after = wc.topVisibleCharIndex()
        // A line's worth of slack: the anchor restores the character to the same HEIGHT, and every
        // line below the change moved by a whole band, so landing on a neighbouring character is
        // correct behaviour rather than drift. Losing the place looks like `after` near zero.
        XCTAssertEqual(Double(after), Double(before), accuracy: Double(storage.length) * 0.05,
                       "the reader must still be looking at the same part of the document")
    }

    // MARK: - (5) It is a preference, not a window's own state

    /// Global, so a second open document follows immediately rather than the next time it happens to
    /// re-render — which would make the setting look per-window without being it.
    func testTogglingOneWindowUpdatesEveryOpenPagedDocument() throws {
        let (docA, first) = try openPaged()
        let (docB, second) = try openPaged()
        // The reach is `NSDocumentController.shared.documents`, so both have to actually be open as
        // far as AppKit is concerned — which they are in the app and are not in a test that builds
        // documents directly. Registered here and removed again so nothing leaks into another case.
        NSDocumentController.shared.addDocument(docA)
        NSDocumentController.shared.addDocument(docB)
        defer {
            NSDocumentController.shared.removeDocument(docA)
            NSDocumentController.shared.removeDocument(docB)
        }
        XCTAssertTrue(first.pageBandDelegate.isActive)
        XCTAssertTrue(second.pageBandDelegate.isActive)

        first.togglePageOutline(nil)   // outline off — header and footer follow it (master switch)
        waitForAsyncTail()
        XCTAssertEqual(second.pageOptionChangeCount, 1,
                       "the other window re-solved its own band from the same preference")
        XCTAssertNil(second.pageBandContent,
                     "…and has no band left, because the outline took the header and footer with it")
    }

    /// Markdown, plain text and an office document with no page width have no paper. The menu greys
    /// out, and the action is inert even if something calls it anyway.
    func testANonPagedDocumentHasNothingToToggle() throws {
        let (_, wc) = try openMarkdown("# Heading\n\nSome prose.\n")
        XCTAssertFalse(wc.isPaged)
        let item = NSMenuItem(title: "Page Outline",
                              action: #selector(DocumentWindowController.togglePageOutline(_:)),
                              keyEquivalent: "")
        XCTAssertFalse(wc.validateMenuItem(item), "greyed out for a document with no paper")

        let stored = PageViewOptionsStore.current
        wc.togglePageOutline(nil)
        XCTAssertEqual(wc.pageOptionChangeCount, 0, "and the action does nothing")
        XCTAssertEqual(PageViewOptionsStore.current, stored, "…including to the preference")
    }

    /// The menu shows all three states at once — checked, not retitled.
    func testTheMenuReportsEachToggleAsACheckmark() throws {
        PageViewOptionsStore.current = PageViewOptions(outline: true)
        let (_, wc) = try openPaged()
        func state(_ selector: Selector) -> NSControl.StateValue {
            let item = NSMenuItem(title: "", action: selector, keyEquivalent: "")
            _ = wc.validateMenuItem(item)
            return item.state
        }
        XCTAssertEqual(state(#selector(DocumentWindowController.togglePageOutline(_:))), .on)
        // Header and Footer are no longer separate items — they ARE the outline (`PageViewOptions`).
    }

    // MARK: - (6) What is drawn is what is printed

    /// The sheets a reader sees and the sheets that come out of the printer are the SAME rectangles,
    /// from the same function — not two implementations that agree today.
    func testTheSheetsOnScreenAreTheSheetsOnPaper() throws {
        let (_, wc) = try openPaged()
        XCTAssertFalse(wc.pageSheets.isEmpty)
        XCTAssertEqual(wc.pageSheets, wc.printSheets)

        // PAPER DOES NOT HAVE A TOGGLE, and the page breaks belong to the FILE rather than to the
        // View menu — so printing applies the paged shape itself (`beginPrintLayout`) no matter what
        // the reader is currently showing. Before that, a printout taken with the outline off came
        // out as one continuous run with no header, no footer and no page margins.
        PageViewOptionsStore.current = PageViewOptions(outline: false)
        let (_, noOutline) = try openPaged()
        XCTAssertTrue(noOutline.pageSheets.isEmpty, "no outline, nothing to DRAW on screen")
        let info = noOutline.makePrintOperation().printInfo
        XCTAssertFalse(noOutline.printSheets.isEmpty, "printing puts the pages back regardless")
        XCTAssertEqual(info.paperSize.width, try XCTUnwrap(noOutline.pagedDocumentWidth), accuracy: 0.5,
                       "paper is still the document's own page")
        XCTAssertGreaterThan(info.paperSize.height, 0)
    }

    /// **The printed sheets must TILE — no strip may belong to no page.** On screen the band also
    /// carries `RenderTheme.pageDeskGap`, which is desk rather than paper; leaving it in the print
    /// grid makes each sheet 12pt shorter than the grid advances, so anything laid out in that strip
    /// is drawn into the PDF and lands on no sheet at all. Measured on a real 147-page report: a line
    /// overrunning its page by more than the bottom margin vanished from the printout while
    /// `pdftotext` still found its text in the file, and the next line printed half-cut at the top of
    /// the following page. `applyPageBand(forPrinting:)` drops the gap, which is what makes the
    /// sheets meet exactly.
    func testPrintedSheetsTileWithNoGapBetweenThem() throws {
        let (_, wc) = try openPaged()
        wc.beginPrintLayout()
        let sheets = wc.printSheets
        try XCTSkipIf(sheets.count < 2, "needs a document that paginates")
        for i in 1..<sheets.count {
            XCTAssertEqual(sheets[i].minY, sheets[i - 1].maxY, accuracy: 0.01,
                           "sheet \(i) must begin exactly where sheet \(i - 1) ended")
        }
        // Tiling alone is satisfied by a sheet as tall as the grid, so the SIZE is asserted too:
        // dropping the gap from the delegate but leaving it in the band tiles perfectly onto paper
        // 12pt taller than the document's own page. Both halves have to be right, and each is a
        // separate line of code — mutating either one must turn this red.
        let doc = try XCTUnwrap(wc.mdDocument)
        let paper = try XCTUnwrap(doc.officePageContentHeight)
                  + (doc.officePageMarginTop ?? 0) + (doc.officePageMarginBottom ?? 0)
        XCTAssertEqual(sheets[0].height, paper, accuracy: 0.5,
                       "the sheet is the DOCUMENT's own page, never the page plus the screen's desk")
    }

    /// The drawn sheets must NOT touch — the desk between them is the whole reason they read as
    /// separate pieces of paper. Asserted against the band the layout actually reserved, so a desk
    /// the painter drew but layout never made room for (or the reverse) shows up here.
    func testTheDrawnSheetsAreSeparatedByExactlyTheDeskTheBandReserved() throws {
        let (_, wc) = try openPaged()
        let sheets = wc.pageSheets
        XCTAssertGreaterThan(sheets.count, 1, "precondition: more than one page to separate")
        for i in 1..<sheets.count {
            XCTAssertEqual(sheets[i].minY - sheets[i - 1].maxY, RenderTheme.pageDeskGap, accuracy: 0.01,
                           "sheet \(i) must sit one desk gap below sheet \(i - 1), not touch it")
        }
        // …and the paper is the document's own, desk excluded.
        XCTAssertEqual(sheets[0].height,
                       Self.marginTop + Self.bodyHeight + Self.marginBottom, accuracy: 0.01)
    }

    // MARK: - (7) Where the page sits, and what happens where a table crosses a boundary

    /// A page break must never be drawn THROUGH a table. A line inside a table cannot be shifted
    /// (invariant 55/58), so a table crossing a boundary overruns it and layout opens no band there —
    /// and a sheet drawn on the arithmetic grid put its edge, and the desk behind it, in the middle of
    /// the table. Joining the two sheets says the true thing: this page ran longer than its paper.
    func testSheetsJoinAcrossABoundaryLayoutCouldNotOpen() {
        let sheets = PagePagination.sheets(count: 4, width: 500, textOriginY: 0, leadingBand: 0,
                                           pitch: 200, topMargin: 20, deskGap: 10)
        // Every boundary opened — nothing joins.
        XCTAssertEqual(PagePagination.joiningUnopenedBoundaries(sheets, openedBoundaries: [0, 1, 2]),
                       sheets)
        // Boundary 1 blocked by a table: sheets 1 and 2 become one, and the join swallows the desk
        // between them so no gap is drawn inside the table either.
        let joined = PagePagination.joiningUnopenedBoundaries(sheets, openedBoundaries: [0, 2])
        XCTAssertEqual(joined.count, 3)
        XCTAssertEqual(joined[1].minY, sheets[1].minY, accuracy: 0.01)
        XCTAssertEqual(joined[1].maxY, sheets[2].maxY, accuracy: 0.01)
        XCTAssertEqual(joined[1].height, sheets[1].height + 10 + sheets[2].height, accuracy: 0.01)
        // No information (a test, or the print path) leaves every boundary standing.
        XCTAssertEqual(PagePagination.joiningUnopenedBoundaries(sheets, openedBoundaries: nil), sheets)
    }

    /// The page is centred on the PAPER's width, not the text view's frame — AppKit keeps widening
    /// that frame back to the clip view, and a frame equal to the clip can never satisfy
    /// `frame < clip`, which is how the page ended up hugging the left edge after a zoom or a sidebar
    /// toggle.
    func testTheClipViewCentresOnThePaperNotTheFrame() {
        let clip = PageCenteringClipView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let tv = ReaderTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 2000))
        clip.documentView = tv

        // A frame AppKit has widened to the clip, around a 600pt sheet: still centred.
        tv.pagedPaperWidth = 600
        let paged = clip.constrainBoundsRect(NSRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(paged.origin.x, (600 - 800) / 2, accuracy: 0.01)

        // Markdown states no paper, so the frame is the content and nothing is centred.
        tv.pagedPaperWidth = nil
        let flowing = clip.constrainBoundsRect(NSRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(flowing.origin.x, 0, accuracy: 0.01)
    }

    /// A panel taking width away shrinks the page to fit — and NEVER enlarges it, which is what keeps
    /// this from being the "zoom follows the window" rule that was deliberately removed. The owner
    /// stated the bound: *"무리하게 줄이진 말고, 창이 우측으로 삐져나가지 않도록 축소해서 맞추라는 뜻"*.
    func testThePageShrinksToFitTheReadingAreaAndNeverGrows() throws {
        let (_, wc) = try openPaged()
        let opening = wc.pageZoom
        XCTAssertGreaterThan(opening, 0)

        // Plenty of room: nothing moves, however much desk there is.
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 2400, height: 900), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.shrinkPageZoomToFit()
        XCTAssertEqual(wc.pageZoom, opening, accuracy: 0.0001,
                       "a wider reading area must not enlarge the reader's own zoom")

        // Now squeeze it until the page cannot fit, and it scales down rather than running off.
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 420, height: 900), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.shrinkPageZoomToFit()
        XCTAssertLessThan(wc.pageZoom, opening, "…and shrinks when it does not")
        let paper = try XCTUnwrap(wc.pagedDocumentWidth)
        XCTAssertLessThanOrEqual(paper * wc.pageZoom, 420, "the page must now fit the reading area")
    }

    // MARK: - (8) Every path applies the WHOLE paged view state, not a subset

    /// The structural fault behind the centring bugs: five rules describe a paged view, and five
    /// different paths each applied a different subset — the View-menu toggle applied NONE. So the
    /// desk colour survived switching the outline off, and each fix landed in one path while another
    /// undid it.
    ///
    /// Asserted on the two rules a toggle actually changes and that nothing else in this file covers:
    /// the paper registered for centring, and the desk colour beside the page.
    func testTogglingTheOutlineReappliesTheWholeViewStateNotPartOfIt() throws {
        let (_, wc) = try openPaged()
        let paper = try XCTUnwrap(wc.pagedDocumentWidth)
        XCTAssertEqual(wc.textView.pagedPaperWidth, paper,
                       "precondition: the page is registered for centring")
        XCTAssertEqual(wc.deskBackgroundColorForTesting, Palette.pageDesk,
                       "precondition: with sheets drawn, the space beside them is desk")

        // IMMEDIATELY — no run-loop turn. This is what makes the test bite: the layout walk the toggle
        // kicks off ends in `sizeTextViewToFit`, which applies the same state, so waiting for the async
        // tail passes whether or not the TOGGLE itself did it. Mutation-checked both ways.
        wc.togglePageOutline(nil)          // outline OFF — the document flows continuously
        XCTAssertEqual(wc.deskBackgroundColorForTesting, NSColor.textBackgroundColor,
                       "no sheets, so no desk — and not one frame later, which is what a reader sees")

        wc.togglePageOutline(nil)          // and back ON
        XCTAssertEqual(wc.deskBackgroundColorForTesting, Palette.pageDesk)
        XCTAssertEqual(wc.textView.pagedPaperWidth, paper, "…and the page is still centred on its paper")
        // The async tail must not undo any of it either.
        waitForAsyncTail()
        XCTAssertEqual(wc.deskBackgroundColorForTesting, Palette.pageDesk)
    }

    /// The desk gap is ONE fact, owned by the layout that reserved it — never re-read from the
    /// preference at draw time. Between a toggle writing the preference and the band being re-solved
    /// there is a window where the two would disagree and every sheet would mis-tile by 12pt.
    func testTheDeskGapComesFromTheLayoutThatReservedItNotThePreference() throws {
        let (_, wc) = try openPaged()
        XCTAssertEqual(wc.pageBandDelegate.deskGap, RenderTheme.pageDeskGap, accuracy: 0.01)

        // Write the preference WITHOUT re-solving the band — the racy window, made explicit.
        PageViewOptionsStore.current = PageViewOptions(outline: false)
        XCTAssertEqual(wc.pageBandDelegate.deskGap, RenderTheme.pageDeskGap, accuracy: 0.01,
                       "still what layout reserved, because nothing has re-solved it yet")
        let sheets = wc.printSheets
        if sheets.count > 1 {
            XCTAssertEqual(sheets[1].minY - sheets[0].maxY, RenderTheme.pageDeskGap, accuracy: 0.01,
                           "so the sheets still tile against the band that actually exists")
        }
    }

    // MARK: - Fixture

    private static let bodyWidth: CGFloat = 400
    private static let bodyHeight: CGFloat = 500
    private static let marginTop: CGFloat = 60
    private static let marginBottom: CGFloat = 40
    private static let marginSide: CGFloat = 50

    private func openPaged(headerAndFooter: Bool = true) throws -> (MarkdownDocument, DocumentWindowController) {
        let doc = MarkdownDocument()
        doc.fileURL = temp.appendingPathComponent("paged-\(UUID().uuidString).docx")
        let body = (1...120).map { i in
            OfficeBlock.paragraph(spans: [Span(text: "Paragraph number \(i) of the body text.")])
        }
        doc.setOfficeContent(
            blocks: body, archive: nil, defaultBodyFontSize: 11,
            pageContentWidth: Self.bodyWidth,
            pageMarginLeft: Self.marginSide, pageMarginRight: Self.marginSide,
            pageContentHeight: Self.bodyHeight,
            pageMarginTop: Self.marginTop, pageMarginBottom: Self.marginBottom,
            pageHeaderDistance: 20, pageFooterDistance: 20,
            headers: headerAndFooter
                ? [OfficeHeaderFooter(appliesTo: .defaultPages,
                                      blocks: [.paragraph(spans: [Span(text: "Running header")])])] : [],
            footers: headerAndFooter
                ? [OfficeHeaderFooter(appliesTo: .defaultPages,
                                      blocks: [.paragraph(spans: [Span(text: "Running footer")])])] : [])
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        settle(wc)
        return (doc, wc)
    }

    private func openMarkdown(_ source: String) throws -> (MarkdownDocument, DocumentWindowController) {
        let url = temp.appendingPathComponent("doc.md")
        try Data(source.utf8).write(to: url)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: Data(source.utf8), ofType: "public.plain-text")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        settle(wc)
        return (doc, wc)
    }

    private func settle(_ wc: DocumentWindowController) {
        wc.textView.postsFrameChangedNotifications = false
        wc.textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = false
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.updateTextInset()
        if let tc = wc.textView.textContainer { wc.textView.layoutManager?.ensureLayout(for: tc) }
        wc.applyTrailingFooterBand()
    }

    private func height(of wc: DocumentWindowController) -> CGFloat {
        guard let lm = wc.textView.layoutManager, let tc = wc.textView.textContainer else { return 0 }
        lm.ensureLayout(for: tc)
        return lm.usedRect(for: tc).height
    }

    private func waitForAsyncTail(_ seconds: TimeInterval = 0.4) {
        let exp = expectation(description: "async tail settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 2)
    }
}
