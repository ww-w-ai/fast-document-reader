import XCTest
import AppKit
@testable import FastDocReader

/// P5's gate: **a draw pass must not rebuild the page grid.**
///
/// `pageSheets` and `printSheets` are computed properties, and one draw pass reads them three times
/// over — `ReaderTextView.drawPageSheets` (the joined grid, which itself builds the printed one),
/// `ReaderTextView.drawMasterPages` (the printed grid again) and `PageNumberDeskView.draw` (the
/// joined one again). Each build is an engine crossing plus one `CGRect` per page, so on the
/// 542-page reference document a single scrolled frame built ~1,600 rectangles and crossed the FFI
/// twice. The same shape is in `ReaderTextView.rectForPage`, which AppKit asks a few times per page:
/// one print job of that document rebuilt the whole grid a couple of thousand times.
///
/// Nothing could see it. The RECTANGLES are identical either way — that is what makes this a latency
/// regression rather than a defect, and latency is what no other test here can see (invariant 113).
/// So this counts grid builds rather than milliseconds, for the same reason
/// `testTheResizeWalksTheStorageOnceRatherThanOncePerLayerItReplaced` counts attribute queries: this
/// suite is flaky under load, so a clock-based budget is either too loose to catch the regression or
/// too tight to survive a busy machine.
///
/// The counter is `DocumentWindowController.pageGridComputations` and it deliberately is NOT
/// `RustOfficeDocumentHandle.answeredQueries`: when no engine handle is open, `printSheets` builds
/// exactly the same rectangles from `PagePagination.sheets` while answering no query at all, so the
/// shared counter would report a clean frame for a grid rebuilt from scratch.
///
/// Proven to bite — four value substitutions, each restored and the file `diff`-checked after:
///
/// | mutation | caught by |
/// |---|---|
/// | the counter stops counting (`+= 1` → `+= 0`) | the rebuild test |
/// | the printed grid is never memoised (`printGridMemo = nil`) | the rebuild test |
/// | the key compares only the page count | both |
/// | the joined grid is never memoised (`joinedGridMemo = nil`) | the draw test, **0 → 24** |
///
/// The two tests catch different halves and neither is redundant. This fixture is a docx, so it has
/// no 바탕쪽 and `drawMasterPages` returns before it reads `printSheets` — the draw therefore
/// exercises the JOINED memo, and the printed one is reached only through the rebuild test. On an
/// HWP with a master page the same draw reads both.
///
/// The draw test was a shell when it was first written: it passed under the mutation that removes
/// the printed memo, because a draw that never asks for the grid is indistinguishable from a memo
/// working perfectly. The entry assertion below is what closed that, and it is the reason the
/// numbers above are measured rather than reasoned about.
final class PageGridMemoTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PageViewOptionsStore.current = PageViewOptions(outline: true)
    }

    override func tearDown() {
        PageViewOptionsStore.current = PageViewOptions(outline: false)
        super.tearDown()
    }

    /// Scrolling moves none of the inputs the grid is derived from — the page count, the paper
    /// width, the text origin, the band, the pitch, the top margin and the desk gap are all the same
    /// numbers at the bottom of a document as at the top. So a scrolled frame has nothing to
    /// rebuild, and the memo's value key says so without anyone having to invalidate it from the
    /// reflow paths (which is the objection `rectForPage`'s own comment used to raise against a
    /// cache here, and which a value key does not have to answer).
    func testDrawingManyViewportsDoesNotRebuildThePageGridOncePerFrame() throws {
        let wc = try openRealPagedFixture("docs/fixtures/office/bus-headings.docx")
        XCTAssertTrue(wc.pageBandDelegate.isActive, "this fixture must actually paginate")
        let pages = wc.printSheets.count
        XCTAssertGreaterThan(pages, 1,
                             "the fixture must produce MORE THAN ONE page, or a grid gate proves nothing")

        guard let scrollView = wc.textView.enclosingScrollView else {
            return XCTFail("no enclosing scroll view to drive the draw passes from")
        }
        let clip = scrollView.contentView
        guard let frameRep = wc.textView.bitmapImageRepForCachingDisplay(in: wc.textView.visibleRect) else {
            return XCTFail("could not allocate a bitmap to draw into")
        }
        let viewportHeight = max(1, clip.bounds.height)
        let totalHeight = wc.textView.bounds.height
        func drawFrame(at y: CGFloat) {
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clip)
            // `cacheDisplay` rather than `display()`: this window is never ordered on screen and
            // AppKit is free to skip drawing a view whose window is not visible, which would report
            // every frame as free because nothing was painted. Same reason `ReaderPerfProbeTests`
            // draws into a bitmap it owns.
            wc.textView.cacheDisplay(in: wc.textView.visibleRect, to: frameRep)
        }

        // FIRST, prove the draw pass actually reaches the grid. Without this the measurement below
        // is a shell: a draw that never asks for the sheets rebuilds nothing, which is
        // indistinguishable from a memo working perfectly. Measured — the version of this test
        // without this step PASSED under the mutation that removes the memo entirely.
        //
        // Moving the desk gap is what makes the question answerable with no test-only API: it is a
        // real input to the key, so the next read must rebuild, and if the draw is the thing doing
        // that read the counter moves.
        wc.pageBandDelegate.deskGap += 6
        let beforeEntry = wc.pageGridComputations
        drawFrame(at: 0)
        XCTAssertGreaterThan(wc.pageGridComputations, beforeEntry,
                             "the draw pass never asked for the page grid — nothing below is tested")

        // THEN the property itself: scrolling is not a reason to rebuild.
        let frames = 12
        let before = wc.pageGridComputations
        var drawn = 0
        for step in 1...frames {
            drawFrame(at: min(CGFloat(step) * viewportHeight * 0.9, max(0, totalHeight - viewportHeight)))
            drawn += 1
        }
        let rebuilt = wc.pageGridComputations - before

        XCTAssertEqual(drawn, frames, "the loop must actually have drawn every frame")
        XCTAssertLessThanOrEqual(rebuilt, 1, """
            \(frames) drawn viewports rebuilt the page grid \(rebuilt) times on a \(pages)-page \
            document. Scrolling changes none of the grid's inputs, so a scrolled frame has nothing \
            to rebuild — each rebuild is an engine crossing plus one CGRect per page, and this \
            document's draw pass asks for the grid twice a frame (measured: 24 rebuilds over these \
            12 frames with the memo gone).
            """)
    }

    /// The other half of the same property, and the one that keeps the memo honest: a grid whose
    /// inputs MOVED must be rebuilt. A memo that never rebuilds would pass the test above perfectly
    /// while drawing a 40-page document's sheets over a 542-page one.
    ///
    /// `deskGap` is moved rather than the window, deliberately: the paper width of a paged document
    /// does NOT follow the window (that is the point of paper), and page zoom is a view transform
    /// that leaves the grid alone (invariant 46's neighbourhood), so neither of the obvious gestures
    /// actually changes an input. The desk gap does — it is how much of the reserved band is desk
    /// rather than paper, it is read straight from the layout that reserved it, and every sheet's
    /// height is `pitch - deskGap`.
    func testAGridWhoseInputsMovedIsRebuiltRatherThanServedFromTheMemo() throws {
        let wc = try openRealPagedFixture("docs/fixtures/office/bus-headings.docx")
        let first = wc.printSheets
        XCTAssertGreaterThan(first.count, 1, "the fixture must paginate for this to mean anything")

        let settled = wc.pageGridComputations
        _ = wc.printSheets
        XCTAssertEqual(wc.pageGridComputations, settled,
                       "an unchanged grid must come from the memo, not be rebuilt")

        // Nothing here invalidates anything by hand — the key simply stops matching.
        wc.pageBandDelegate.deskGap += 6
        let second = wc.printSheets
        XCTAssertGreaterThan(wc.pageGridComputations, settled,
                             "a moved input must rebuild the grid rather than be served the old one")
        XCTAssertEqual(second.count, first.count, "the desk gap changes sheet HEIGHT, not page count")
        XCTAssertNotEqual(second.first?.height, first.first?.height,
                          "a 6pt wider desk must make each sheet 6pt shorter — if the heights are "
                          + "identical the memo answered from the stale key after all")
    }

    /// `docs/` is gitignored, so a fresh clone has no fixtures — skip rather than fail there.
    private func openRealPagedFixture(_ relativePath: String) throws -> DocumentWindowController {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(relativePath) is not in this checkout (docs/ is local-only)")
        }
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        return wc
    }
}
