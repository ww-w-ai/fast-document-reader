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
        XCTAssertTrue(PageViewOptions(outline: true, header: false, footer: false).separatesPages,
                      "the outline needs the space between sheets even with nothing in it")
        XCTAssertFalse(PageViewOptions(outline: false, header: true, footer: true).separatesPages)

        XCTAssertFalse(PageViewOptions(outline: true, header: true, footer: true).drawsDivider,
                       "a real sheet edge says it better than a rule across the column")
        XCTAssertTrue(PageViewOptions(outline: false, header: true, footer: false).drawsDivider,
                      "band but no sheet — the hairline is the only thing marking the page ending")
        XCTAssertFalse(PageViewOptions(outline: false, header: false, footer: false).drawsDivider,
                       "nothing to mark")
    }

    /// Defaults are all on, and a never-written preference must read that way rather than as the
    /// `false` `UserDefaults.bool(forKey:)` hands back for a missing key.
    func testAFreshMachineGetsTheDefaultsNotFalse() {
        PageViewOptionsStore.reset()
        XCTAssertEqual(PageViewOptionsStore.current, PageViewOptions.default)
        XCTAssertEqual(PageViewOptions.default, PageViewOptions(outline: true, header: true, footer: true))
    }

    // MARK: - (2) All three off IS the pre-paged code path

    /// THE design doc's own acceptance test: with everything off the document must lay out exactly as
    /// one whose reader found no header or footer at all — same height, and no line shifted. Asserted
    /// against a SECOND document that genuinely has none, rather than against a remembered number.
    func testWithEverythingOffTheDocumentLaysOutLikeOneWithNoHeaderOrFooter() throws {
        PageViewOptionsStore.current = PageViewOptions(outline: false, header: false, footer: false)
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
        PageViewOptionsStore.current = PageViewOptions(outline: true, header: false, footer: false)
        let (_, wc) = try openPaged()
        XCTAssertTrue(wc.pageBandDelegate.isActive)
        XCTAssertEqual(wc.pageBandDelegate.band,
                       Self.marginTop + Self.marginBottom + RenderTheme.pageDeskGap, accuracy: 0.01,
                       "the space between two sheets is the document's own two margins (invariant 57e) " +
                       "plus the desk the reader draws between them — the one part no document states")
        XCTAssertGreaterThan(wc.pageBandDelegate.shiftCount, 0, "…and lines really were moved for it")
    }

    // MARK: - (3) The three act independently

    func testHidingTheHeaderRemovesItFromBothHalvesOfTheBand() throws {
        PageViewOptionsStore.current = PageViewOptions(outline: true, header: false, footer: true)
        let (_, wc) = try openPaged()
        let content = try XCTUnwrap(wc.pageBandContent)
        XCTAssertTrue(content.headers.isEmpty, "nothing to paint")
        XCTAssertEqual(content.headerHeight, 0, accuracy: 0.01, "and nothing measured for it either")
        XCTAssertFalse(content.footers.isEmpty, "the footer is untouched")
        XCTAssertGreaterThan(content.footerHeight, 0)
    }

    func testHidingTheFooterRemovesItFromBothHalvesOfTheBand() throws {
        PageViewOptionsStore.current = PageViewOptions(outline: true, header: true, footer: false)
        let (_, wc) = try openPaged()
        let content = try XCTUnwrap(wc.pageBandContent)
        XCTAssertTrue(content.footers.isEmpty)
        XCTAssertEqual(content.footerHeight, 0, accuracy: 0.01)
        XCTAssertFalse(content.headers.isEmpty)
        // The room below the last line is still reserved, and that is the SHEET's, not the footer's:
        // with the outline on the last page keeps its own bottom margin whether or not anything is
        // printed in it, exactly as the first page keeps its top one.
        XCTAssertEqual(wc.pageBandDelegate.trailingBand, Self.marginBottom, accuracy: 0.01)
    }

    /// The outer margins are the SHEET's. With no sheet drawn, the only reason to reserve room above
    /// the first line or below the last is a header or footer that needs it — so hiding them takes
    /// the room with them, which is what "쭉 연결되어" has to mean at the document's two ends.
    func testWithNoOutlineTheOuterMarginsBelongToTheHeaderAndFooterAlone() throws {
        PageViewOptionsStore.current = PageViewOptions(outline: false, header: false, footer: false)
        let (_, wc) = try openPaged()
        XCTAssertEqual(wc.pageBandDelegate.leadingBand, 0, accuracy: 0.01)
        XCTAssertEqual(wc.pageBandDelegate.trailingBand, 0, accuracy: 0.01)

        PageViewOptionsStore.current = PageViewOptions(outline: true, header: false, footer: false)
        let (_, sheets) = try openPaged()
        XCTAssertEqual(sheets.pageBandDelegate.leadingBand, Self.marginTop, accuracy: 0.01,
                       "…and with a sheet drawn, page 1 gets its own full top margin")
        XCTAssertEqual(sheets.pageBandDelegate.trailingBand, Self.marginBottom, accuracy: 0.01)
    }

    /// The outline replaces the page-break hairline rather than joining it.
    func testTheDividerYieldsToTheSheetEdge() throws {
        PageViewOptionsStore.current = PageViewOptions(outline: true, header: true, footer: true)
        let (_, on) = try openPaged()
        XCTAssertFalse(try XCTUnwrap(on.pageBandContent).drawsDivider)

        PageViewOptionsStore.current = PageViewOptions(outline: false, header: true, footer: true)
        let (_, off) = try openPaged()
        XCTAssertTrue(try XCTUnwrap(off.pageBandContent).drawsDivider)
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

        first.togglePageOutline(nil)   // outline off; header and footer still on, so the band stays
        waitForAsyncTail()
        XCTAssertEqual(second.pageOptionChangeCount, 1,
                       "the other window re-solved its own band from the same preference")
        XCTAssertTrue(try XCTUnwrap(second.pageBandContent).drawsDivider,
                      "…and now shows the hairline, because it no longer shows a sheet")
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
        PageViewOptionsStore.current = PageViewOptions(outline: true, header: false, footer: true)
        let (_, wc) = try openPaged()
        func state(_ selector: Selector) -> NSControl.StateValue {
            let item = NSMenuItem(title: "", action: selector, keyEquivalent: "")
            _ = wc.validateMenuItem(item)
            return item.state
        }
        XCTAssertEqual(state(#selector(DocumentWindowController.togglePageOutline(_:))), .on)
        XCTAssertEqual(state(#selector(DocumentWindowController.togglePageHeader(_:))), .off)
        XCTAssertEqual(state(#selector(DocumentWindowController.togglePageFooter(_:))), .on)
    }

    // MARK: - (6) What is drawn is what is printed

    /// The sheets a reader sees and the sheets that come out of the printer are the SAME rectangles,
    /// from the same function — not two implementations that agree today.
    func testTheSheetsOnScreenAreTheSheetsOnPaper() throws {
        let (_, wc) = try openPaged()
        XCTAssertFalse(wc.pageSheets.isEmpty)
        XCTAssertEqual(wc.pageSheets, wc.printSheets)

        PageViewOptionsStore.current = PageViewOptions(outline: false, header: true, footer: true)
        let (_, noOutline) = try openPaged()
        XCTAssertTrue(noOutline.pageSheets.isEmpty, "no outline, nothing to draw")
        XCTAssertFalse(noOutline.printSheets.isEmpty,
                       "…but printing still puts it on its own pages: paper does not have a toggle")
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
