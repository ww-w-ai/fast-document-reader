import XCTest
import AppKit
@testable import FastDocReader

/// Step 1 of the paged-zoom design. For a **paged** document — one whose reader found a page body
/// width (`officePageContentWidth != nil`) — ⌘+/⌘−/⌘0 stop rebuilding the document and become a
/// view transform over a reading column that never moves. Markdown, plain text, and an office
/// document whose reader found NO page width keep the font-size model exactly as it was.
///
/// The load-bearing property is the first test's, and it is the reason the whole change exists:
/// invariant 56b's 65,853 ms freeze is AppKit filling layout holes inside `NSTextTable` during
/// `drawRect:`. Magnification is a bounds transform and creates none — but a zoom that rebuilds the
/// document, or that moves the text container's width by even a point, re-wraps it and brings the
/// freeze straight back. Both halves are therefore asserted DETERMINISTICALLY
/// (`MarkdownDocument.renderGeneration`, `textContainer.size.width`,
/// `DocumentWindowController.pageZoomChangeCount`) and never on a stopwatch: this machine's timings
/// swing 3× under load, so a timing assertion here would be noise (see CLAUDE.md's flaky list).
///
/// The gate is `officePageContentWidth != nil` and never `kind == .office`. Test four is what pins
/// that distinction from the other side — an office document with no page width must still track the
/// window AND still re-typeset on ⌘+ — and five existing cases in `OfficeDocumentTests` go red the
/// moment it is lost.
///
/// Test three covers what was, before this file, a genuine blind spot: nothing anywhere asserted
/// that a MARKDOWN document's column tracks the window. Pinning markdown by accident would have
/// surfaced only as a font-size failure whose message says nothing about width.
final class PagedZoomTests: XCTestCase {
    /// A press that reaches the font-size model records its result as the seed for the next document
    /// (`FontSizeStore.startingSize`), so test four would otherwise export a size to every later
    /// test's freshly opened document. Reset on both sides, exactly as `PerDocumentFontSizeTests`
    /// does, so this class neither inherits nor exports one.
    override func setUp() {
        super.setUp()
        FontSizeStore.startingSize = FontSizeStore.defaultSize
        clearSavedWindowFrame()
    }
    override func tearDown() { FontSizeStore.startingSize = FontSizeStore.defaultSize; super.tearDown() }

    private var temp: URL!

    override func setUpWithError() throws {
        temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-pagedzoom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    // MARK: (1) The rule the freeze depends on — a paged press neither rebuilds nor re-wraps

    /// THE step-1 property. A paged ⌘+ must leave the document exactly as it is and move only the
    /// magnification: `renderGeneration` unchanged (nothing was rebuilt) and the text container's
    /// width unchanged (nothing was re-wrapped, so AppKit has no layout holes to fill — invariant
    /// 56b). `pageZoomChangeCount` is asserted alongside them because without it this test would
    /// still pass if the menu action became a no-op: "nothing was rebuilt" is only interesting when
    /// something DID happen.
    ///
    /// The second pair of assertions runs after an async tail, and it is NOT redundant — measured,
    /// it is the pair that actually bites. A paged press is synchronous (it returns before anything
    /// is queued), but the font-size road it replaces is not: `reRenderPreservingCaret`'s leading
    /// edge hands the rebuild to `runBusy`'s `DispatchQueue.main.async`, so `renderGeneration` does
    /// not move until the NEXT run-loop turn. Deleting the paged fork from `increaseReaderFontSize`
    /// therefore leaves the synchronous check above green and is caught only here. Anyone tempted to
    /// drop this second pair as duplication should re-run that mutation first.
    func testAPagedZoomPressRebuildsNothingAndLeavesTheReadingColumnUntouched() throws {
        let (doc, wc) = try openPaged(pageContentWidth: 400)
        XCTAssertTrue(wc.isPaged, "precondition: a declared page width is what makes this paged")

        let generationBefore = doc.renderGeneration
        let columnBefore = try XCTUnwrap(wc.textView.textContainer?.size.width)
        let zoomChangesBefore = wc.pageZoomChangeCount
        let zoomBefore = wc.pageZoom

        doc.increaseReaderFontSize(nil)

        XCTAssertEqual(wc.pageZoomChangeCount, zoomChangesBefore + 1,
                       "the press must actually zoom — otherwise the assertions below are vacuous")
        XCTAssertGreaterThan(wc.pageZoom, zoomBefore, "…and zoom IN")
        XCTAssertEqual(doc.renderGeneration, generationBefore,
                       "a paged ⌘+ must not rebuild the document — the rebuild IS invariant 56b's freeze")
        XCTAssertEqual(try XCTUnwrap(wc.textView.textContainer?.size.width), columnBefore,
                       "a paged ⌘+ must not move the reading column by even a point: changing the " +
                       "container width re-wraps the document and brings the freeze back")

        // The rebuild this replaces is debounced and deferred, so a regression that only postpones
        // it would look synchronous-clean. Give that turn a chance to happen and re-check.
        waitForAsyncTail()
        XCTAssertEqual(doc.renderGeneration, generationBefore,
                       "…and no rebuild arrives on a later turn either")
        XCTAssertEqual(try XCTUnwrap(wc.textView.textContainer?.size.width), columnBefore,
                       "…nor a deferred re-wrap")
    }

    // MARK: (2) A paged document's column IS its page, and the window does not get a vote

    /// The pin. A paged document is shown at its own scale, so the reading column is the page body
    /// width the document declared and stays there at every window size — the window changes how
    /// much of it you see (the zoom), never how the text wraps.
    func testAPagedDocumentsColumnIsItsPageWidthAndDoesNotTrackTheWindow() throws {
        let page: CGFloat = 400
        let (_, wc) = try openPaged(pageContentWidth: page)

        for windowWidth: CGFloat in [700, 1300] {
            settle(wc, windowWidth: windowWidth)
            XCTAssertEqual(try XCTUnwrap(wc.textView.textContainer?.size.width), page, accuracy: 0.5,
                           "the column must be the DOCUMENT's page body at a \(Int(windowWidth))pt window, " +
                           "not a share of the window")
        }
    }

    // MARK: (3) Markdown still fills the window — the property nothing else in the suite asserts

    /// Markdown has no page, so it keeps the fill-the-window model: a wider window is a wider column.
    /// Before this test the suite had no assertion of that anywhere — every `textContainer?.size.width`
    /// check in it was in an office test — so pinning markdown by accident would have shown up only
    /// as a font-size failure whose message says nothing about width.
    func testAMarkdownDocumentsColumnStillTracksTheWindow() throws {
        let (_, wc) = try openMarkdown("# Title\n\nA paragraph long enough to wrap across the column.\n")
        XCTAssertFalse(wc.isPaged, "precondition: markdown declares no page, so it is never paged")

        settle(wc, windowWidth: 700)
        let narrow = try XCTUnwrap(wc.textView.textContainer?.size.width)
        settle(wc, windowWidth: 1300)
        let wide = try XCTUnwrap(wc.textView.textContainer?.size.width)

        // Today's formula is `max(200, clipWidth - 2 * minSideInset)`, so 600 pt more window is 600 pt
        // more column. Asserted as the DIFFERENCE rather than as two absolute numbers, because the
        // clip's own width depends on the scroller style this machine happens to be set to, while the
        // difference between two widths does not.
        XCTAssertEqual(wide - narrow, 600, accuracy: 1,
                       "a markdown column must grow point for point with the window (narrow \(narrow), wide \(wide))")
        XCTAssertLessThan(narrow, 700,
                          "…and it is the window minus its margins, not a fixed page width")
    }

    // MARK: (4) The gate is the PAGE WIDTH, not the file format

    /// The mirror of test one, and the reason the predicate is `officePageContentWidth != nil`.
    /// An office document whose reader found no page width (a real, tested state in all three
    /// formats) is not paged: its column still tracks the window and ⌘+ still re-typesets it. Key
    /// the switch on `kind == .office` instead and both halves of this go red — as do five existing
    /// cases in `OfficeDocumentTests` whose fixtures declare no page.
    func testAnOfficeDocumentWithNoPageWidthStillTracksTheWindowAndStillReTypesetsOnZoom() throws {
        let (doc, wc) = try openPaged(pageContentWidth: nil)
        XCTAssertFalse(wc.isPaged, "precondition: no page width ⇒ not paged, whatever the file format is")

        settle(wc, windowWidth: 700)
        let narrow = try XCTUnwrap(wc.textView.textContainer?.size.width)
        settle(wc, windowWidth: 1300)
        let wide = try XCTUnwrap(wc.textView.textContainer?.size.width)
        XCTAssertEqual(wide - narrow, 600, accuracy: 1,
                       "the no-page-width fallback still fills the window (narrow \(narrow), wide \(wide))")

        let generationBefore = doc.renderGeneration
        let fontBefore = try bodyFontPointSize(wc)
        let zoomChangesBefore = wc.pageZoomChangeCount

        doc.increaseReaderFontSize(nil)
        waitForAsyncTail()   // the font-size road is debounced and rebuilds on a later turn

        XCTAssertGreaterThan(doc.renderGeneration, generationBefore,
                             "an unpaged office document must still REBUILD on ⌘+ — that is the model it kept")
        XCTAssertGreaterThan(try bodyFontPointSize(wc), fontBefore,
                             "…and its text must actually get bigger")
        XCTAssertEqual(wc.pageZoomChangeCount, zoomChangesBefore,
                       "…and nothing may be magnified: there is no page to zoom")
    }

    // MARK: (5) Stepping and the two clamps

    /// Each press multiplies (or divides) by `pageZoomStep`, and the zoom stops at the two bounds.
    /// A press AT a bound is a no-op — asserted through `pageZoomChangeCount` rather than by
    /// comparing floats, because "the magnification happens to be the same number" and "nothing was
    /// applied" are different claims and only the second one is what a clamp promises.
    func testZoomStepsByTheStepFactorAndStopsDeadAtBothClamps() throws {
        let (doc, wc) = try openPaged(pageContentWidth: 400)
        // States the zoom this test steps FROM instead of inheriting it. A no-op as things stand —
        // the document already opened fitted — but it keeps the arithmetic below independent of how
        // the opening zoom is chosen, which is a separate decision with its own test (D1, below).
        wc.fitPageZoom()
        let start = wc.pageZoom

        doc.increaseReaderFontSize(nil)
        XCTAssertEqual(wc.pageZoom, start * DocumentWindowController.pageZoomStep, accuracy: 0.0001,
                       "one press is exactly one step")
        doc.decreaseReaderFontSize(nil)
        XCTAssertEqual(wc.pageZoom, start, accuracy: 0.0001, "and the opposite press undoes it exactly")

        // Up to the ceiling. 40 presses from any starting zoom inside the range overshoots it by a
        // wide margin, so the only thing that can stop it is the clamp.
        for _ in 0..<40 { doc.increaseReaderFontSize(nil) }
        XCTAssertEqual(wc.pageZoom, DocumentWindowController.maxPageZoom, accuracy: 0.0001,
                       "zoom must stop at maxPageZoom")
        var changes = wc.pageZoomChangeCount
        doc.increaseReaderFontSize(nil)
        XCTAssertEqual(wc.pageZoomChangeCount, changes,
                       "a press at the ceiling must apply nothing at all, not re-apply the same value")

        // …and down to the floor.
        for _ in 0..<40 { doc.decreaseReaderFontSize(nil) }
        XCTAssertEqual(wc.pageZoom, DocumentWindowController.minPageZoom, accuracy: 0.0001,
                       "zoom must stop at minPageZoom")
        changes = wc.pageZoomChangeCount
        doc.decreaseReaderFontSize(nil)
        XCTAssertEqual(wc.pageZoomChangeCount, changes, "a press at the floor must apply nothing either")
    }

    // MARK: (6) The zoom belongs to the document, not to the app

    /// Mirrors `RenderThemeParityTests`' per-document reading-size proof one level up: zooming one
    /// open document must not move another. The reading size used to live in one shared global and
    /// leaked between windows exactly this way, so a zoom kept in a static — or read back out of
    /// `UserDefaults` on every press — would be the same defect wearing new clothes.
    func testZoomingOneOpenDocumentLeavesAnotherOpenDocumentsZoomUntouched() throws {
        let (docA, wcA) = try openPaged(pageContentWidth: 400)
        let (_, wcB) = try openPaged(pageContentWidth: 400)
        let zoomB = wcB.pageZoom
        let changesB = wcB.pageZoomChangeCount

        docA.increaseReaderFontSize(nil)
        docA.increaseReaderFontSize(nil)

        XCTAssertGreaterThan(wcA.pageZoom, zoomB, "precondition: A really did zoom in")
        XCTAssertEqual(wcB.pageZoom, zoomB, accuracy: 0.0001,
                       "an untouched document's page must not react to another document's ⌘+")
        XCTAssertEqual(wcB.pageZoomChangeCount, changesB,
                       "…and nothing may even be applied to it")
    }

    // MARK: (7) ⌘0 fits the page — it does not go to 100%

    /// Design decisions D1 and D2 together. A paged document OPENS at `defaultPageZoom` and ⌘0
    /// returns it there rather than to "actual size", `ZoomScrollView.fit()` being the in-repo
    /// precedent for the same key.
    ///
    /// The expected zoom is taken from the OPENING seed rather than by calling `fitPageZoom()` in
    /// setup, and deliberately: a reset mutated to `applyMagnification(1)` would drag such a setup
    /// call to 1.0 with it, leaving the real assertion comparing 1.0 against 1.0 and passing. Read
    /// from the seed the two numbers stay independent, and BOTH mutations — a reset that goes to
    /// 100%, and a seed that opens at 100% — go red on the assertion that matters.
    ///
    /// Reading the seed this way is only sound because the window is never resized AFTER it: the
    /// seed fits the page to the width the window had when it opened, so a later resize would make
    /// the reset legitimately land on a different number and the comparison meaningless. The helper
    /// settles once, before anything here runs, and nothing moves it again — `fitWindowToPage` is
    /// skipped for a window that was never ordered front.
    func testAPagedDocumentOpensAtTheDefaultZoomAndResetPutsItBackThere() throws {
        let (doc, wc) = try openPaged(pageContentWidth: 400)
        let opening = wc.pageZoom
        // THE NUMBER HAS MOVED TWICE AND BOTH MOVES WERE MEASURED, so read this before changing it
        // again. It began as fit-to-window, which opened documents 1.5×–2.9× oversized. It was then
        // pinned to 1.0 on the claim that "Word and Pages open at 100%" — a claim nobody had
        // measured, and it is FALSE: on the owner's machine Word opens at 120%, Pages at 125%, and
        // Hancom's HWP Viewer at ~115%, so 1.0 made this reader the smallest of the four and the
        // owner reported that in turn. `defaultPageZoom` is Word's own 120%.
        //
        // Asserting against the constant rather than a literal is deliberate: the property under
        // test is "opening zoom and ⌘0 agree", which must survive a future re-tuning of the number.
        XCTAssertEqual(opening, DocumentWindowController.defaultPageZoom, accuracy: 0.0001,
                       "a paged document opens at the default zoom, in the 1.15–1.25 band Word, " +
                       "Pages and Hancom's viewer occupy — not at 1.0, which no peer uses")

        doc.increaseReaderFontSize(nil)
        doc.increaseReaderFontSize(nil)
        XCTAssertNotEqual(wc.pageZoom, opening, accuracy: 0.0001, "precondition: the zoom really did move away")

        let generationBefore = doc.renderGeneration
        doc.resetReaderFontSize(nil)

        XCTAssertEqual(wc.pageZoom, opening, accuracy: 0.0001,
                       "⌘0 restores the opening state — the default zoom — rather than leaving the " +
                       "reader wherever they zoomed to")
        XCTAssertEqual(doc.renderGeneration, generationBefore,
                       "…and like the other two keys it rebuilds nothing")
    }

    // MARK: - Fixtures

    /// An office document driven through `setOfficeContent`, the one seam that can declare a page
    /// width without building XML: essentially no XML-built office fixture in this suite declares
    /// one, which is why every untouched office test lands on the unpaged arm. Shape copied from
    /// `UndrawablePictureTests.openOffice(…pageContentWidth:)`.
    ///
    /// `pageContentWidth: nil` is the fallback arm — the same fixture, not paged.
    ///
    /// The window is settled to a known width here rather than left at its default, and that is what
    /// makes the OPENING zoom deterministic too: headless, the window `makeWindowControllers` builds
    /// has never been laid out, so `fitPageZoomValue` finds no width to fit against and declines to
    /// seed. The seed therefore happens on this first settle — at 800 pt, the number this file
    /// chose — instead of at whatever width AppKit restored.
    private func openPaged(pageContentWidth: CGFloat?) throws -> (MarkdownDocument, DocumentWindowController) {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-pagedzoom-\(UUID().uuidString).docx")
        doc.setOfficeContent(
            blocks: [.paragraph(spans: [Span(text: "Body text long enough to wrap in a narrow column.")]),
                     .paragraph(spans: [Span(text: "A second paragraph, so the document has some height.")])],
            archive: nil, defaultBodyFontSize: 10, pageContentWidth: pageContentWidth)
        clearSavedWindowFrame()
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        silenceResizeNotifications(wc)
        settle(wc, windowWidth: 800)
        return (doc, wc)
    }

    private func openMarkdown(_ source: String) throws -> (MarkdownDocument, DocumentWindowController) {
        let url = temp.appendingPathComponent("doc.md")
        try Data(source.utf8).write(to: url)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: Data(source.utf8), ofType: "public.plain-text")
        clearSavedWindowFrame()
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        silenceResizeNotifications(wc)
        settle(wc, windowWidth: 800)
        return (doc, wc)
    }

    /// The shared state a ZOOM test inherits, and the subtle one. `makeWindowControllers` gives
    /// every document window the frame autosave name "FastMDReaderDoc", so AppKit restores whatever
    /// width some earlier window (this class, another class, an earlier run) left behind — and a
    /// restored frame also means the window is LAID OUT the moment it is built, which is where the
    /// opening zoom gets seeded. Measured: the same document seeded at 1.6875 (fit against 800 pt)
    /// in one ordering and at 2.765 (fit against 1300 pt) in another, with nothing in the test
    /// changed.
    ///
    /// Cleared immediately before the window is built rather than only in `setUp`, and that
    /// distinction is the fix: AppKit writes a window's frame back on a LATER run-loop turn, so a
    /// previous test's save can land after `setUp` has already cleared it (observed exactly that
    /// way). With no saved frame the window opens at the controller's own default and, headless, is
    /// never laid out — `fitPageZoomValue` finds no width, declines to seed, and the seed instead
    /// happens on this file's own first `settle`, at the width this file chose.
    private func clearSavedWindowFrame() {
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
    }

    /// Copied from `WindowResizeGateTests.open` and for its reason: a `setFrame` also fires
    /// `viewportChanged` through the text view's frame notification and the clip view's bounds
    /// notification, each running `updateTextInset` through its own independent gate. Left on, those
    /// extra passes make counters (`pageZoomChangeCount`, `renderGeneration`) move for reasons that
    /// have nothing to do with the press under test. Silenced BEFORE the first `setFrame`, so every
    /// reflow below is the one this file asked for.
    private func silenceResizeNotifications(_ wc: DocumentWindowController) {
        wc.textView.postsFrameChangedNotifications = false
        wc.textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = false
    }

    /// Resize to a width and re-solve the reading column from it — the driver `OfficeDocumentTests`
    /// uses for every window-width case.
    private func settle(_ wc: DocumentWindowController, windowWidth: CGFloat) {
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: windowWidth, height: 600), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.updateTextInset()
    }

    private func bodyFontPointSize(_ wc: DocumentWindowController) throws -> CGFloat {
        let storage = try XCTUnwrap(wc.textStorageRef)
        let font = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        return font.pointSize
    }

    /// The font-size rebuild rides a leading-edge debounce plus `runBusy`'s
    /// `DispatchQueue.main.async`, so it lands on a later run-loop turn. Mirrors
    /// `PerDocumentFontSizeTests.waitForAsyncTail`. A PAGED press needs none of this — it returns
    /// before anything is queued — and test one uses it only to prove no rebuild arrives late.
    private func waitForAsyncTail(_ seconds: TimeInterval = 0.3) {
        let exp = expectation(description: "async tail settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 2)
    }
}
