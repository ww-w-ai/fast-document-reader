import XCTest
import AppKit
import Darwin
@testable import FastDocReader

/// End-to-end cost of opening and reading a REAL large document, broken into the same stages a
/// reader actually pays through: parse the bytes, paint the first frame, lay the whole thing out,
/// zoom, resize the reading column, and scroll to the end. Where `OfficeRenderLatencyTests` isolates
/// ONE press's cost and `GiantTableDeferralTests` proves a specific deferral contract, this probe
/// exists to answer a different question — "what does a reader actually experience opening THIS
/// file" — as one ordered run rather than several narrow ones, so a future change that makes one
/// stage worse while making another better is still visible as a single before/after.
///
/// Reuses `OfficeRenderLatencyTests`' own approach rather than inventing a second one: env-gated
/// with `XCTSkip` naming the variable, the same extension→UTI table, the same `spin`/settle pattern,
/// the same "ask `firstUnlaidCharacterIndex()` BEFORE any other glyph query" rule (asking anything
/// else first would lay the document out and then report that laying it out was free), and the same
/// paged/non-paged fork for a ⌘+ press (a paged document answers with `NSScrollView.magnification`
/// and must NOT rebuild — invariant 56/57 — so the settle signal and the assertion both differ).
///
/// Every reported line is `PERF key=value key=value…` so a caller can aggregate several runs by
/// grepping `PERF `. This probe follows CLAUDE.md's rule for every latency instrument in this repo:
/// it FAILS rather than print a number it did not measure — a settle signal that never arrives is an
/// `XCTFail` naming what it was waiting on, never a silent 0 (invariant 30's lesson, restated by
/// `OfficeRenderLatencyTests.timePresses`'s own comment after the paged fork once made that mistake).
///
/// Skips unless `FMD_PERF_FILE` names an absolute path to a real document. `FMD_PERF_WIDTH` /
/// `FMD_PERF_HEIGHT` (default 1200×900) size the probe window — large enough that a real reading
/// column is exercised, not so large the numbers stop meaning anything on a laptop screen.
final class ReaderPerfProbeTests: XCTestCase {
    /// The reading size is SEEDED from a persisted value (`FontSizeStore.startingSize`), so a test
    /// that zooms leaks into whatever opens next — `OfficeRenderLatencyTests` and
    /// `GiantTableDeferralTests` both carry this same guard for the same reason.
    override func setUp() { super.setUp(); FontSizeStore.startingSize = FontSizeStore.defaultSize }
    override func tearDown() { FontSizeStore.startingSize = FontSizeStore.defaultSize; super.tearDown() }

    private func ms(_ start: Date) -> Double { Date().timeIntervalSince(start) * 1000 }
    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    private func f(_ x: Double) -> String { String(format: "%.1f", x) }
    private func perf(_ line: String) { print("PERF " + line) }

    /// `resident_size` alone is not what a reader FEELS as memory pressure — it counts pages the
    /// kernel has already compressed away. `phys_footprint` is Apple's own answer to "how much RAM is
    /// this process actually costing right now" (the number Activity Monitor's "Memory" column shows),
    /// so both are sampled: resident as the traditional figure, phys_footprint as the honest one.
    /// Returns `nil` only if `task_info` itself fails — a host-level problem this probe cannot repair,
    /// so the caller fails loudly rather than printing a zero for memory it did not measure.
    private func memorySnapshotMB() -> (residentMB: Double, physFootprintMB: Double)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (Double(info.resident_size) / 1_048_576, Double(info.phys_footprint) / 1_048_576)
    }

    private func reportMemory(_ point: String) throws {
        guard let m = memorySnapshotMB() else {
            XCTFail("task_info(TASK_VM_INFO) failed at \(point) — cannot measure memory on this host")
            return
        }
        perf("stage=memory point=\(point) residentMB=\(f(m.residentMB)) physFootprintMB=\(f(m.physFootprintMB))")
    }

    func testReaderPerformanceOnARealDocument() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_PERF_FILE"] else {
            throw XCTSkip("set FMD_PERF_FILE to an absolute path naming a real document to measure")
        }
        let probeWidth = CGFloat(Double(ProcessInfo.processInfo.environment["FMD_PERF_WIDTH"] ?? "1200") ?? 1200)
        let probeHeight = CGFloat(Double(ProcessInfo.processInfo.environment["FMD_PERF_HEIGHT"] ?? "900") ?? 900)

        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let supported: Set<String> = ["docx", "docm", "dotx", "dotm", "odt", "hwp", "hwpx", "md", "markdown", "txt"]
        guard supported.contains(ext) else {
            throw XCTSkip("FMD_PERF_FILE has extension \".\(ext)\", which this probe does not support "
                          + "(supported: \(supported.sorted().joined(separator: ", ")))")
        }
        // Mirrors `OfficeRenderLatencyTests`' own table exactly for the office formats, and adds the
        // two text kinds — markdown reads through `net.daringfireball.markdown`, everything else this
        // probe accepts that is not office renders verbatim as `public.plain-text` (`DocumentTypes`'s
        // own fork does not care which plain-text extension it is, only that it isn't markdown/office).
        let uti: String = {
            switch ext {
            case "odt": return "org.oasis-open.opendocument.text"
            case "hwp", "hwpx": return "com.hancom.hwp"
            case "md", "markdown": return "net.daringfireball.markdown"
            case "txt": return "public.plain-text"
            default: return "org.openxmlformats.wordprocessingml.document"
            }
        }()

        perf("stage=doc file=\(url.lastPathComponent) ext=\(ext)")
        try reportMemory("baseline")

        let data = try Data(contentsOf: url)
        let doc = MarkdownDocument()
        doc.fileURL = url

        // Stage 1 — read + parse, the real path (`MarkdownDocument.read`), not a bare parser call:
        // invariant 29's lesson is that a parser can be entirely correct and still be UNREACHED by the
        // app, so this probe goes through the same door a double-click does.
        var t = Date()
        try doc.read(from: data, ofType: uti)
        let readMs = ms(t)

        // Recursive so a table's own cells are counted too — the same walk
        // `OfficeRenderLatencyTests.testFontSizeChangeCostOnARealOfficeDocument` uses, because a
        // document can be cheap in characters and ruinous in STRUCTURE (invariant 48), and only
        // counting top-level blocks would hide exactly that.
        var tables = 0, images = 0
        func countBlocks(_ blocks: [OfficeBlock]) {
            for b in blocks {
                switch b {
                case let .table(rows, _, _, _):
                    tables += 1
                    for row in rows { for cell in row { countBlocks(cell.blocks) } }
                case .image: images += 1
                default: break
                }
            }
        }
        countBlocks(doc.officeBlocks)
        let pageWidthStr = doc.officePageContentWidth.map { String(format: "%.1f", $0) } ?? "nil"
        perf("stage=read_parse ms=\(f(readMs)) bytes=\(data.count) blocks=\(doc.officeBlocks.count) "
             + "tables=\(tables) images=\(images) pageWidth=\(pageWidthStr)")

        // Stage 2 — first paint. `makeWindowControllers()` is what a double-click actually runs
        // (`render(into:)` + `display(_:)`); the frame is set and spun AFTER the timed call, exactly
        // like `OfficeRenderLatencyTests` does, because the reading column a real window would settle
        // into does not exist until a frame does — timing that settle inside "first paint" would
        // charge this stage for window-manager work that is not the render.
        t = Date()
        doc.makeWindowControllers()
        let firstPaintMs = ms(t)
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: probeWidth, height: probeHeight), display: false)
        spin(2)
        let storage = try XCTUnwrap(wc.textStorageRef)
        perf("stage=first_paint ms=\(f(firstPaintMs)) chars=\(storage.length)")
        try reportMemory("after_first_paint")

        // Stage 3 — time to interactive + full layout. `firstUnlaidCharacterIndex()` is read the
        // INSTANT `precomputeLayout()` returns and before anything else touches a glyph — invariant
        // 49 measured that the visible page is already laid out by then (451 of 452 characters on its
        // reference document), so asking the viewport a question first would lay it out and then
        // report the walk did nothing. `layoutStepCount` is the deterministic twin of the wall clock
        // (invariant 49's own instrument): the stopwatch swings up to 3× under load on this machine,
        // the step count does not.
        guard let lm = wc.textView.layoutManager else { return XCTFail("no layout manager after first paint") }
        let total = storage.length
        let t3 = Date()
        wc.precomputeLayout()
        let laidOnReturn = lm.firstUnlaidCharacterIndex()
        var layoutMs = 0.0
        var laidOut = total == 0
        // 120 s, not the 15 s the other probes in this repo use: those measure fixtures, and the whole
        // point of this matrix is documents an order of magnitude larger (a 20 MB HWPX runs to
        // hundreds of pages). A budget that fits the fixtures would turn the interesting half of the
        // matrix into failures that say nothing except that the budget was too small.
        for _ in 0..<24000 where !laidOut {
            spin(0.005)
            if lm.firstUnlaidCharacterIndex() >= total { layoutMs = ms(t3); laidOut = true }
        }
        guard laidOut else {
            return XCTFail("full layout never completed within budget — \(lm.firstUnlaidCharacterIndex()) of "
                           + "\(total) chars laid out, \(wc.layoutStepCount) layout steps taken")
        }
        perf("stage=layout ms=\(f(layoutMs)) charsAtReturn=\(laidOnReturn) charsTotal=\(total) "
             + "steps=\(wc.layoutStepCount)")
        try reportMemory("after_full_layout")

        /// Whether the WHOLE document is laid out right now — the same predicate
        /// `OfficeRenderLatencyTests.timePresses` waits on, because a press or a resize that returns
        /// instantly and leaves the reader looking at unlaid text has not actually finished.
        func fullyLaidOut() -> Bool {
            let len = wc.textView.textStorage?.length ?? 0
            return len == 0 || lm.firstUnlaidCharacterIndex() >= len
        }

        // Stage 4 — zoom. One warm press, then a 3-press burst, exactly as
        // `OfficeRenderLatencyTests.timePresses` measures them, including its two load-bearing rules:
        // the settle signal is chosen PER ARM (a paged document answers `pageZoomChangeCount`, never
        // `renderGeneration` — the whole point of the paged model is that it must NOT rebuild), and a
        // signal that never arrives is a hard failure rather than a silent 0.
        func timeZoomPresses(_ n: Int, _ label: String) {
            if wc.isPaged { _ = wc.fitPageZoom(); spin(0.2) }
            let gen = doc.renderGeneration
            let zooms = wc.pageZoomChangeCount
            let start = Date()
            for _ in 0..<n { doc.increaseReaderFontSize(nil) }
            var settled = false
            var elapsed = 0.0
            // Seeded with the presses' own synchronous cost, same as the existing test — on the paged
            // arm that press IS all the main-thread time there is, so a loop that only measured its
            // own slices below would report a zero hitch for work that genuinely happened.
            var worst = ms(start)
            let pressed: () -> Bool = wc.isPaged
                ? { wc.pageZoomChangeCount > zooms }
                : { doc.renderGeneration > gen }
            for _ in 0..<1500 {
                if pressed(), fullyLaidOut() { elapsed = ms(start); settled = true; break }
                let sliceStart = Date()
                spin(0.01)
                worst = max(worst, ms(sliceStart))
            }
            guard settled else {
                XCTFail("""
                    zoom \(label): the press never settled inside 15 s, waiting on \
                    \(wc.isPaged ? "pageZoomChangeCount" : "renderGeneration") \
                    (this document is \(wc.isPaged ? "PAGED" : "NOT paged")). \
                    zoom steps \(zooms) → \(wc.pageZoomChangeCount), \
                    rebuilds \(gen) → \(doc.renderGeneration), fully laid out: \(fullyLaidOut()).
                    """)
                return
            }
            let rebuilds = doc.renderGeneration - gen
            if wc.isPaged {
                XCTAssertEqual(rebuilds, 0, "zoom \(label): a paged press is a view transform and must "
                               + "not rebuild — \(rebuilds) rebuild(s) happened")
            }
            perf("stage=zoom press=\(label) ms=\(f(elapsed)) worstMs=\(f(worst)) rebuilds=\(rebuilds) "
                 + "paged=\(wc.isPaged)")
        }
        timeZoomPresses(1, "cold")
        timeZoomPresses(1, "warm")
        timeZoomPresses(3, "burst3")

        // Before stages 5 and 6, put the reader back where a freshly opened document starts. The zoom
        // stage above deliberately left the document three presses in, and a document at a larger
        // reading size has MORE laid-out lines and therefore more scroll steps — so measuring the
        // width change and the read-through from wherever stage 4 happened to stop would make those
        // numbers incomparable between two documents that merely zoomed differently.
        if wc.isPaged { _ = wc.fitPageZoom() } else { doc.resetReaderFontSize(nil) }
        var backToDefault = false
        for _ in 0..<1200 where !backToDefault {
            spin(0.01)
            backToDefault = fullyLaidOut()
        }
        guard backToDefault else { return XCTFail("the document never settled back to its default zoom") }

        // Stage 5 — width change. A different cost from zoom: the reading COLUMN moves, which for a
        // non-paged document re-wraps every paragraph and re-solves every table/tab/graphic
        // (invariant 48's three full-storage passes), while a paged document only re-centres its
        // fixed-width page (invariant 57).
        //
        // The number here is deliberately TWO numbers, because a single one is a lie in this app.
        // `updateTextInset` changes the text container's width, and AppKit's layout is lazy: the call
        // returns as soon as the geometry is invalidated, long before a single paragraph has been
        // re-wrapped. An earlier version of this probe reported only that synchronous half and printed
        // 5.3 ms for re-wrapping a 1.2-million-character document — a number that measured the
        // invalidation and charged the re-wrap to whatever ran next. `syncMs` is the part that blocks
        // the drag; `relayoutMs` is the rest of what the reader waits through before the document is
        // whole again, and it is the larger half.
        //
        // The two counters are the anti-fake-green check and are not decoration: a probe that reported
        // timings without them could not tell "the resize was cheap" from "the resize never happened".
        // BOTH are needed, and which one moves is itself the finding. `setFrame` reaches the
        // width-changed gate by two independent routes — `windowDidResize` and, because the text view
        // autoresizes with the window, `NSView.frameDidChangeNotification` → `viewportChanged` — and
        // whichever arrives first does the work while the second correctly sees its own width already
        // matched and skips. Only the first route bumps `resizeGateReflowCount`, so measuring that
        // alone reports `reflows=0` for a resize that demonstrably re-wrapped the whole document.
        // `textInsetUpdateCount` is incremented inside `updateTextInset` itself, so it counts the work
        // whichever route asked for it — that is the honest witness.
        func timeWidthChange(_ label: String, toWidth: CGFloat) {
            guard let window = wc.window else { return XCTFail("no window for width-change stage") }
            let reflowsBefore = wc.resizeGateReflowCount
            let insetsBefore = wc.textInsetUpdateCount
            var frame = window.frame
            frame.size.width = toWidth
            let start = Date()
            window.setFrame(frame, display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            wc.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
            let syncMs = ms(start)
            let reflows = wc.resizeGateReflowCount - reflowsBefore
            let insetUpdates = wc.textInsetUpdateCount - insetsBefore
            XCTAssertGreaterThan(insetUpdates, 0,
                                 "width change \(label): the reading column never actually re-solved, "
                                 + "so every timing below it would be measuring nothing")

            // Now the deferred half: everything the invalidation above left for later.
            let tRelayout = Date()
            wc.precomputeLayout()
            var relaidOut = fullyLaidOut()
            var worstSlice = 0.0
            for _ in 0..<12000 where !relaidOut {
                let sliceStart = Date()
                spin(0.005)
                worstSlice = max(worstSlice, ms(sliceStart))
                relaidOut = fullyLaidOut()
            }
            guard relaidOut else {
                return XCTFail("width change \(label): the document never finished re-laying out")
            }
            let relayoutMs = ms(tRelayout)
            perf("stage=width_change label=\(label) syncMs=\(f(syncMs)) relayoutMs=\(f(relayoutMs)) "
                 + "totalMs=\(f(syncMs + relayoutMs)) worstMs=\(f(max(syncMs, worstSlice))) "
                 + "reflows=\(reflows) insetUpdates=\(insetUpdates)")
        }
        let originalWidth = wc.window?.frame.width ?? probeWidth
        timeWidthChange("narrow", toWidth: originalWidth - 220)
        timeWidthChange("restore", toWidth: originalWidth)

        // Stage 6a — jump to end, with the document already fully laid out (see above), so this
        // isolates the cost of the jump itself rather than the layout it would otherwise trigger.
        let storageNow = try XCTUnwrap(wc.textStorageRef)
        let lastChar = max(0, storageNow.length - 1)
        let tJump = Date()
        wc.textView.scrollRangeToVisible(NSRange(location: lastChar, length: 1))
        let jumpMs = ms(tJump)
        perf("stage=scroll_jump ms=\(f(jumpMs)) target=lastChar")

        // Stage 6b — read-through. A scroll that only moves the clip view's origin measures nothing:
        // invariant 56b's freeze lives in `drawRect:` filling LAYOUT holes (AppKit's own
        // `_NSFastFillAllGlyphHolesForGlyphRange`), so each step has to make the glyphs actually be
        // DRAWN, once per frame, exactly as a mouse wheel or a page-down key would.
        //
        // `display()` is the obvious call and it is not trustworthy here: this probe's window is never
        // ordered on screen, and AppKit is free to skip drawing a view whose window is not visible —
        // which would report a scroll as free because nothing was painted. `cacheDisplay(in:to:)`
        // renders into a bitmap this probe owns, so the draw provably happens whether or not anything
        // is on screen. The rep is allocated ONCE and reused: the viewport's size never changes, and
        // allocating one per step would charge every step for a buffer a real scroll never allocates.
        //
        // Capped at `stepCap` as a backstop against a pathological document rather than as a target: a
        // real corpus document tops out at a few hundred steps at this step size, so hitting the cap is
        // itself a signal worth seeing in the output (`reachedBottom=false`) rather than silently
        // truncating the measurement.
        guard let scrollView = wc.textView.enclosingScrollView else {
            return XCTFail("no enclosing scroll view for the read-through stage")
        }
        let clip = scrollView.contentView
        let viewportHeight = max(1, clip.bounds.height)
        let totalHeight = wc.textView.bounds.height
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: 0))
        scrollView.reflectScrolledClipView(clip)
        guard let frameRep = wc.textView.bitmapImageRepForCachingDisplay(in: wc.textView.visibleRect) else {
            return XCTFail("could not allocate a bitmap to draw the read-through into")
        }
        var y: CGFloat = 0
        var stepTimes: [Double] = []
        let stepCap = 2000
        var reachedBottom = totalHeight <= viewportHeight
        while stepTimes.count < stepCap, !reachedBottom {
            y = min(y, max(0, totalHeight - viewportHeight))
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clip)
            let visible = wc.textView.visibleRect
            let t0 = Date()
            wc.textView.cacheDisplay(in: visible, to: frameRep)
            stepTimes.append(ms(t0))
            if y >= totalHeight - viewportHeight { reachedBottom = true } else { y += viewportHeight * 0.9 }
        }
        guard !stepTimes.isEmpty else {
            return XCTFail("read-through took zero steps — viewport \(viewportHeight)pt, "
                           + "document \(totalHeight)pt")
        }
        let totalReadMs = stepTimes.reduce(0, +)
        let worstStep = stepTimes.max() ?? 0
        let sortedSteps = stepTimes.sorted()
        let medianStep = sortedSteps[sortedSteps.count / 2]
        perf("stage=scroll_readthrough steps=\(stepTimes.count) totalMs=\(f(totalReadMs)) "
             + "worstMs=\(f(worstStep)) medianMs=\(f(medianStep)) reachedBottom=\(reachedBottom)")

        // Stage 7 (final sample) — after the read-through, so the four memory points bracket exactly
        // the four stages that could plausibly grow the footprint: parsing the bytes, painting the
        // first frame, laying the whole document out, and forcing every page to draw.
        try reportMemory("after_readthrough")
    }
}
