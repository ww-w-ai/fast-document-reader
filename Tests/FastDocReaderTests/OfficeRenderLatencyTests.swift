import XCTest
import AppKit
@testable import FastDocReader

/// What ONE ⌘+/⌘− press actually costs on a REAL office document, broken down by stage.
///
/// `reRenderPreservingCaret` re-runs the whole render (`OfficeTextBuilder.build` over every block)
/// and then re-lays the document out, so a heavy report — dozens of tables, hundreds of thousands of
/// characters — pays all of it per keypress. This probe exists so that cost is a measured number
/// rather than a guess, and so a future change that makes it worse is visible (the same reason
/// `FloatWrapExclusionSpikeTests` and `CorpusProbeTests` are kept).
///
/// **A PAGED document takes a different road and this probe forks with it.** Since the paged-zoom
/// change, a document that declared a page width (`officePageContentWidth != nil`) answers ⌘+/⌘− with
/// `NSScrollView.magnification` and is never rebuilt, so `renderGeneration` deliberately does NOT
/// move — which is precisely the signal the press timer used to wait on. Left alone, the timer spun
/// its whole 15 s budget, reported `0 ms`, and stayed GREEN, because nothing here asserts. That is a
/// worse failure than a red test: an instrument reporting a number while measuring nothing (invariant
/// 30, one level up). `timePresses` now picks its settle signal per arm and FAILS if that signal
/// never arrives, so this can no longer happen quietly for any future change of model.
///
/// Skips unless `FMD_OFFICE_LATENCY_FILE` points at a .docx/.odt/.hwp/.hwpx. Nothing from the
/// document's contents is printed — only sizes and timings.
///
/// What this probe has already established on a 62-table / 37-image HWP (~19k characters), so it
/// does not have to be re-derived:
///   • Before: 769 ms per press, 1706 ms for a 3-press burst (2.2× — three full rebuilds), and
///     `display(_:)` alone 138 ms because the full storage pass ran three times per render.
///   • After (`settleReadingColumn` + debounce): ~670 ms per press, ~660 ms for a 3-press burst
///     (1.0× — one rebuild), `display(_:)` ~50 ms.
///   • The residual ~216 ms main-thread freeze is the REBUILD itself (build ~100 ms + display
///     ~50 ms + the media/outline tail), not document layout. Time-slicing `precomputeLayout` was
///     tried against it and made things worse — see that function's comment.
///   • Machine noise is real: one run showed 2825 ms/2.1× that did not reproduce. Trust the
///     `rebuilds` count (deterministic) over the wall clock (not).
///
/// And what it establishes about the two arms now that the fork exists, both run under load ~7:
///   • PAGED — the 401,765-character / 129-table 시장구조조사.hwp (page width 368.5 pt, 51,968 cells):
///     **1.2 ms per press, worst hitch 1.2 ms, 0 rebuilds**, a 3-press burst 1.9 ms. Against invariant
///     56b's 65,853 ms deep-⌘+ freeze on this same document, which is what it replaces. `zoom steps`
///     equals the press count exactly, so nothing is coalescing or clamping. The three reflow passes
///     are skipped under a pinned column, and the walk they would otherwise have paid still measures
///     26.8–28.5 ms right below — the saving is the gap between those two lines.
///   • NOT PAGED — `docs/fixtures/office/giant-table.odt` (page width nil, so it takes the fallback
///     arm): 2371 ms per press, worst hitch 2298 ms, 1 rebuild per press, and the 3-press burst
///     collapses to 2 rebuilds at 1.0× one press — today's debounce behaviour, unchanged. Running
///     this file is the only way to exercise that arm on a machine whose sample documents are paged.
final class OfficeRenderLatencyTests: XCTestCase {
    /// The reading size is now SEEDED from a persisted value (`FontSizeStore.startingSize`), so a
    /// test that changes a document's size leaks into every later test's freshly opened document —
    /// which is a property of the feature, not a bug, but it makes test order significant. Reset it
    /// on both sides so this class neither inherits nor exports a size.
    override func setUp() { super.setUp(); FontSizeStore.startingSize = FontSizeStore.defaultSize }
    override func tearDown() { FontSizeStore.startingSize = FontSizeStore.defaultSize; super.tearDown() }
    /// What paragraph STYLES a real HWP actually uses, and how often — the input to
    /// `HwpReader.headingLevel`'s matching. Run before widening that matcher, so the rule follows the
    /// documents instead of a guess about them (the same "measure the corpus before believing it"
    /// discipline invariant 30 records). Skips unless `FMD_HWP_STYLE_PROBE` names an HWP/HWPX.
    func testHwpStyleNameFrequencies() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_HWP_STYLE_PROBE"] else {
            throw XCTSkip("set FMD_HWP_STYLE_PROBE to inspect a real HWP's paragraph styles")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let json = HwpReader.exportDocumentJSON(data),
              let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let blocks = root["blocks"] as? [[String: Any]] else {
            return XCTFail("could not export/parse that document")
        }
        var counts: [String: Int] = [:]
        var headingBlocks = 0
        func walk(_ blocks: [[String: Any]]) {
            for b in blocks {
                switch b["t"] as? String {
                case "para":
                    if b["heading"] != nil, !(b["heading"] is NSNull) { headingBlocks += 1 }
                    let en = (b["styleName"] as? String) ?? "-"
                    let ko = (b["styleLocalName"] as? String) ?? "-"
                    counts["\(en) / \(ko)", default: 0] += 1
                case "table":
                    if let rows = b["rows"] as? [[[String: Any]]] {
                        for row in rows { for cell in row { walk((cell["blocks"] as? [[String: Any]]) ?? []) } }
                    }
                default: break
                }
            }
        }
        walk(blocks)
        var lh: [String: Int] = [:]
        func walkLH(_ blocks: [[String: Any]]) {
            for b in blocks {
                if b["t"] as? String == "para", let h = b["lineHeight"] as? [String: Any] {
                    lh["\(h["type"] ?? "?")=\(h["value"] ?? "?")", default: 0] += 1
                }
                if let rows = b["rows"] as? [[[String: Any]]] {
                    for row in rows { for cell in row { walkLH((cell["blocks"] as? [[String: Any]]) ?? []) } }
                }
            }
        }
        walkLH(blocks)
        print("  line heights: " + lh.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key)×\($0.value)" }.joined(separator: "  "))
        print("  paragraphs by style (english / korean), heading-flagged: \(headingBlocks)")
        for (name, n) in counts.sorted(by: { $0.value > $1.value }).prefix(12) {
            print(String(format: "   %5d  %@", n, name))
        }
    }

    private func ms(_ start: Date) -> Double { Date().timeIntervalSince(start) * 1000 }
    private func stamp(_ label: String, _ start: Date) {
        print(String(format: "  %-38@ %7.1f ms", label as NSString, ms(start)))
    }
    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testFontSizeChangeCostOnARealOfficeDocument() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_OFFICE_LATENCY_FILE"] else {
            throw XCTSkip("set FMD_OFFICE_LATENCY_FILE to measure a real office document")
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let uti: String = {
            switch ext {
            case "odt": return "org.oasis-open.opendocument.text"
            case "hwp", "hwpx": return "com.hancom.hwp"
            default: return "org.openxmlformats.wordprocessingml.document"
            }
        }()

        // The reading size lives on `doc` itself now, not in `UserDefaults` — so unlike the old
        // `FontSizeStore.size` (backed by `UserDefaults.standard` under this process's own bundle
        // identifier, which macOS persisted to DISK and could silently poison a later run), there is
        // no cross-test/cross-process leak to guard against here any more.
        let doc = MarkdownDocument()
        doc.fileURL = url
        var t = Date()
        try doc.read(from: data, ofType: uti)
        stamp("read + parse", t)
        if let start = ProcessInfo.processInfo.environment["FMD_START_FONT"].flatMap(Double.init) {
            doc.readingSize = CGFloat(start)   // reproduce a reader who has already zoomed in
        }

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
        print("  blocks: \(doc.officeBlocks.count), tables: \(tables), images: \(images), "
              + "pageWidth: \(doc.officePageContentWidth.map { String(format: "%.1f", $0) } ?? "nil")")

        t = Date()
        doc.makeWindowControllers()
        stamp("first render (makeWindowControllers)", t)
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        let probeW = Double(ProcessInfo.processInfo.environment["FMD_PROBE_WIDTH"] ?? "1200") ?? 1200
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: probeW, height: 900), display: false)
        spin(2)
        let storage = try XCTUnwrap(wc.textStorageRef)
        print("  characters rendered: \(storage.length)")

        // Stage 1 — the pure string rebuild. For markdown, plain text and an office document with no
        // page width this is what changing the font size fundamentally requires, once per press. A
        // PAGED document no longer pays it on ⌘+ at all (the press is a magnification), so for one of
        // those this stage is the cost of what still DOES rebuild: opening the document, ⌘R, a resize.
        //
        // Build it at the theme the reader would really use. A paged document is pinned to its own
        // default body size (`MarkdownDocument.render`, paged-zoom design D3), so measuring it at a
        // reading size of 20 would time a document with a different amount of line wrapping — and
        // therefore a different number of laid-out lines — than the one on screen.
        let colW = wc.textView.textContainer?.size.width ?? 800
        let rebuildTheme = RenderTheme.current(size: wc.isPaged ? doc.officeDefaultBodyFontSize : 20)
        t = Date()
        let rebuilt = OfficeTextBuilder.build(doc.officeBlocks, theme: rebuildTheme,
                                              columnWidth: colW,
                                              documentDefaultFontSize: doc.officeDefaultBodyFontSize,
                                              pageContentWidth: doc.officePageContentWidth,
                                              // Mirror `MarkdownDocument.render` exactly: tables are
                                              // built at the width they are displayed at.
                                              tableWidth: colW - 2 * (wc.textView.textContainer?.lineFragmentPadding ?? 5),
                                              comments: doc.officeComments)
        stamp("OfficeTextBuilder.build alone", t)
        XCTAssertGreaterThan(rebuilt.length, 0)

        // Stage 2 — `updateTextInset` with the document ALREADY rendered. `render(into:)` calls this
        // before every rebuild, and its two tail passes (tab reanchor + table column re-solve) walk
        // the FULL current storage — which the rebuild is about to throw away.
        //
        // A PAGED document measures something DIFFERENT here, and reading this line as though it were
        // the same number is the trap. Its column is constant for the life of the document, so
        // `updateTextInset` settles the geometry and returns without running the three passes at all
        // (they would provably recompute the values they already hold). What is left is the pin plus
        // the container/frame bookkeeping — which is not free either, since changing the text view's
        // frame width invalidates layout, so this line still swings with whether the frame actually
        // moved. What the SKIPPED passes would have cost is measured directly one stage below; the
        // saving is the gap between the two, which is why they are printed next to each other.
        t = Date()
        wc.updateTextInset()
        stamp("updateTextInset (full storage)", t)

        // Stage 2b — WHY that pass costs what it costs. It is two full-storage walks (fill-margin tab
        // re-anchor, table column re-solve) plus the graphic pass; a document can be cheap in
        // characters and ruinous in STRUCTURE, so count the structure rather than guess from length.
        var tableParagraphs = 0, fillMarginTabs = 0, graphics = 0, distinctTables = Set<ObjectIdentifier>()
        let all = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.paragraphStyle, in: all) { value, _, _ in
            guard let ps = value as? NSParagraphStyle, let block = ps.textBlocks.first as? NSTextTableBlock else { return }
            tableParagraphs += 1
            distinctTables.insert(ObjectIdentifier(block.table))
        }
        storage.enumerateAttribute(MDAttr.fillMarginTab, in: all) { v, _, _ in if v != nil { fillMarginTabs += 1 } }
        storage.enumerateAttribute(MDAttr.officeGraphic, in: all) { v, _, _ in if v != nil { graphics += 1 } }
        print("  structure: \(distinctTables.count) NSTextTables, \(tableParagraphs) cell paragraphs, "
              + "\(fillMarginTabs) fill-margin tabs, \(graphics) graphics")
        // Both paths matter and they are very different: the SAME width (what `display(_:)`'s tail and
        // a repeated pass hit) must cost nothing, and a genuinely CHANGED width (a real resize) pays
        // the one invalidation. Measuring only the first would flatter the change.
        t = Date()
        TableBlockBuilder.resizeTables(in: storage, toWidth: colW - 10)
        stamp("  ↳ resizeTables, width unchanged", t)
        t = Date()
        TableBlockBuilder.resizeTables(in: storage, toWidth: colW - 210)
        stamp("  ↳ resizeTables, width CHANGED", t)
        TableBlockBuilder.resizeTables(in: storage, toWidth: colW - 10)   // put it back

        // Stage 3 — installing the rebuilt string (this is what actually blocks the main thread).
        t = Date()
        wc.display(rebuilt)
        stamp("display(attributed)", t)

        // Stage 3a — the flicker check: after a render, does the resize pass still MOVE anything?
        // Any cell it changes is a cell the reader saw at the wrong width first (table shrinks, then
        // snaps wider). Zero changed = the first paint is the final one.
        do {
            func widths() -> [CGFloat] {
                var out: [CGFloat] = []
                storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
                    if let ps = v as? NSParagraphStyle, let b = ps.textBlocks.first as? NSTextTableBlock {
                        out.append(b.contentWidth)
                    }
                }
                return out
            }
            let before = widths()
            let pad = wc.textView.textContainer?.lineFragmentPadding ?? 5
            TableBlockBuilder.resizeTables(in: storage, toWidth: colW - 2 * pad)
            let after = widths()
            let moved = zip(before, after).filter { abs($0 - $1) > 0.5 }.count
            print("  cells the resize pass still moves after a render: \(moved) of \(before.count)")
        }

        // Stage 3b — the TAIL after the string is installed: laying the whole document out is the
        // one that scales with table count, and it is worth knowing separately from the rebuild.
        //
        // Stage 3c is folded in here because it has to be read at the same instant: how much of the
        // document is laid out the moment `precomputeLayout` RETURNS. That is time-to-interactive —
        // the reader can see and select the part that is laid out — and unlike the settle time it is
        // a deterministic count, not a wall clock. `layoutStepCount` (how many run-loop turns the
        // walk took) is the other deterministic half: it says how finely the rest was sliced.
        do {
            let lm0 = wc.textView.layoutManager
            // Nothing may ASK for a glyph before the measurement: under contiguous layout every
            // glyph query lays the document out up to that glyph, so probing "what does the viewport
            // need" first would lay the viewport out and then report that laying it out was free.
            let t0 = Date()
            wc.precomputeLayout()
            let laidOnReturn = lm0?.firstUnlaidCharacterIndex() ?? 0
            var laid = 0.0
            for _ in 0..<1500 {
                spin(0.005)
                let total = wc.textView.textStorage?.length ?? 0
                if total > 0, (lm0?.firstUnlaidCharacterIndex() ?? 0) >= total { laid = ms(t0); break }
            }
            print(String(format: "  full-document layout alone           %7.1f ms", laid))
            // Now that everything is laid out, asking what the viewport spans costs nothing.
            let visible = wc.visibleCharRange(margin: 0)
            print("  laid out WHEN precomputeLayout returned: \(laidOnReturn) of \(storage.length) chars"
                  + "  (viewport needs \(NSMaxRange(visible)))"
                  + "  · layout run-loop turns: \(wc.layoutStepCount)")
        }

        // Stage 4+ — a press measured to the point the document is FULLY laid out again, which is
        // when it stops feeling busy. Two things make a naive timer lie on the REBUILD arm: `runBusy`
        // defers the work a run-loop turn, and the rebuild is DEBOUNCED — so "layout is complete" is
        // true the instant after the press, before anything has started. Waiting for a signal that
        // the press was actually PICKED UP is what makes this measure the work rather than the wait.
        let lm = try XCTUnwrap(wc.textView.layoutManager)

        /// Is the whole document laid out right now? Both arms have to wait for this, because a press
        /// that returns instantly and leaves the reader looking at unlaid text has not finished.
        func fullyLaidOut() -> Bool {
            let total = wc.textView.textStorage?.length ?? 0
            return total > 0 && lm.firstUnlaidCharacterIndex() >= total
        }

        /// Returns (settle, worstHitch). `worstHitch` is what "slow" actually feels like: a 10 ms
        /// run-loop slice that takes 500 ms to come back means the main thread was blocked that whole
        /// time and the window was frozen. Total settle time can stay the same while the hitch drops,
        /// and the app still feels far better — so both are reported. The presses' own synchronous
        /// cost seeds `worst`, because that is main-thread time too — and on the paged arm it is the
        /// ONLY main-thread time, so a loop that only measured its own slices would report a zero
        /// hitch for work that did happen.
        ///
        /// The settle signal is chosen per arm, and the two are not interchangeable:
        ///   • NOT PAGED — the press rebuilds the string, so wait for `renderGeneration` to advance.
        ///   • PAGED — the press is a view transform and MUST NOT bump `renderGeneration` (step 1's
        ///     whole point), so that signal never arrives; wait for `pageZoomChangeCount` instead and
        ///     assert the rebuild count really did stay put.
        /// If the chosen signal never arrives inside the 15 s budget this FAILS. It used to return 0
        /// and stay green, which is how the paged change silently emptied this probe.
        func timePresses(_ n: Int, _ label: String) -> (Double, Double) {
            // Start every paged gesture from `fit`. Two reasons, both needed: a zoom already pinned at
            // `maxPageZoom` cannot move, so its press would be indistinguishable from a probe that is
            // measuring nothing; and starting all three measurements below from the same zoom is what
            // makes them comparable to each other.
            if wc.isPaged { wc.fitPageZoom(); spin(0.2) }
            let gen = doc.renderGeneration
            let zooms = wc.pageZoomChangeCount
            let zoomBefore = wc.pageZoom
            let start = Date()
            for _ in 0..<n { doc.increaseReaderFontSize(nil) }
            // `settled` is a flag rather than "elapsed != 0" on purpose: a press that costs almost
            // nothing — which is exactly what the paged arm is supposed to cost — must not be
            // indistinguishable from a press that never happened. That conflation is the bug being
            // fixed here, and re-encoding it in the sentinel would smuggle it back in.
            var settled = false
            var elapsed = 0.0, worst = ms(start)
            let pressed: () -> Bool = wc.isPaged
                ? { wc.pageZoomChangeCount > zooms }
                : { doc.renderGeneration > gen }
            for _ in 0..<1500 {
                if pressed(), fullyLaidOut() { elapsed = ms(start); settled = true; break }
                let sliceStart = Date()
                spin(0.01)
                worst = max(worst, ms(sliceStart))
            }
            if !settled {
                // Report BOTH counters, never only the one this arm chose. Verified by running the
                // mutation: forcing the paged arm back onto `renderGeneration` printed "zoom count
                // stayed" while the zoom had in fact moved twice — a diagnostic that named the wrong
                // culprit and would have sent the next reader after the zoom instead of the arm.
                XCTFail("""
                    \(label): the press never settled inside 15 s. \
                    Waiting on \(wc.isPaged ? "pageZoomChangeCount" : "renderGeneration") \
                    (this document is \(wc.isPaged ? "PAGED" : "NOT paged")). \
                    zoom steps \(zooms) → \(wc.pageZoomChangeCount), \
                    zoom \(String(format: "%.3f", zoomBefore)) → \(String(format: "%.3f", wc.pageZoom)) \
                    (max \(DocumentWindowController.maxPageZoom)), \
                    rebuilds \(gen) → \(doc.renderGeneration), fully laid out: \(fullyLaidOut()). \
                    This probe must never report a number it did not measure, so it fails instead of \
                    printing 0 (invariant 30).
                    """)
                return (0, worst)
            }
            // Decisive check for coalescing: how many REBUILDS did this gesture actually cause?
            // Three presses that produce three renders means the debounce is not collapsing them,
            // whatever the wall clock says. On the paged arm the same counter is an ASSERTION rather
            // than an observation — a paged press that rebuilds anything has lost the entire prize
            // (invariant 56b's 65,853 ms freeze), and it must be loud, not a line of output.
            spin(0.5)
            if wc.isPaged {
                XCTAssertEqual(doc.renderGeneration, gen,
                               "\(label): a paged press is a view transform and must not rebuild — "
                               + "\(doc.renderGeneration - gen) rebuild(s) happened")
            }
            print(String(format: "  %-30@ %7.1f ms   worst freeze %6.1f ms   rebuilds %d   zoom %.3f → %.3f (%d steps)",
                         label as NSString, elapsed, worst, doc.renderGeneration - gen,
                         zoomBefore, wc.pageZoom, wc.pageZoomChangeCount - zooms))
            return (elapsed, worst)
        }
        print(wc.isPaged
              ? "  model: PAGED — ⌘+ magnifies, settle signal = pageZoomChangeCount"
              : "  model: REBUILD — ⌘+ re-renders, settle signal = renderGeneration")
        _ = timePresses(1, "first ⌘+ (cold)")
        let warm = timePresses(1, "warm ⌘+ press")
        // The real gesture: three presses as fast as the key repeats. On the rebuild arm, uncoalesced,
        // this is three full rebuilds back to back and the reader waits through all three to see only
        // the last size; on the paged arm it is three bounds transforms and should cost the same as
        // one, which is the number this whole change exists to produce.
        let burst = timePresses(3, "3-press burst")
        print(String(format: "  VERDICT: 1 press %.0f ms (worst freeze %.0f ms) · 3-press burst %.0f ms (%.1f× one press)",
                     warm.0, warm.1, burst.0, warm.0 > 0 ? burst.0 / warm.0 : 0))
    }
}

/// `precomputeLayout`'s two load-bearing properties, pinned so neither can be lost silently.
///
/// These do NOT need a real document: they need a document whose STRUCTURE is expensive while its
/// length is not, which is the whole shape of the problem — an office report is a few tens of
/// thousands of characters and hundreds of table cells. GFM tables go through the same
/// `TableBlockBuilder` as office tables (invariant 39), so a markdown file of small tables produces
/// the same `NSTextTableBlock`s at a fraction of the setup.
final class PrecomputeLayoutTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// `tables` small GFM tables, deliberately short: heavy in cells, light in characters.
    private func tableDenseMarkdown(tables: Int) -> String {
        (0..<tables).map { i in
            """
            ## Section \(i)

            | A | B | C |
            | - | - | - |
            | 1 | 2 | 3 |
            | 4 | 5 | 6 |
            | 7 | 8 | 9 |
            """
        }.joined(separator: "\n\n")
    }

    private func open(_ markdown: String) throws -> (MarkdownDocument, DocumentWindowController) {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-precompute-\(UUID().uuidString).md")
        try doc.read(from: Data(markdown.utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        spin(0.5)
        return (doc, wc)
    }

    /// Waits until the document is laid out, bounded so a walk that never terminates fails the test
    /// instead of hanging the suite. Deliberately only a WAIT, not evidence: see the note below on
    /// why "is it laid out" says nothing about whether `precomputeLayout` is what laid it out.
    private func settle(_ wc: DocumentWindowController) -> Bool {
        guard let lm = wc.textView.layoutManager else { return false }
        for _ in 0..<400 {
            spin(0.005)
            let total = wc.textView.textStorage?.length ?? 0
            if total > 0, lm.firstUnlaidCharacterIndex() >= total { return true }
        }
        return false
    }

    // NOT TESTED HERE, and the reason is worth keeping: "after this settles the whole document is
    // laid out" (invariant 2's contract) cannot be asserted in this harness, because it is true
    // whether or not `precomputeLayout` does anything. Written and then withdrawn after the mutation
    // step — shortening every step by 100 characters left it passing, and so did deleting the call
    // entirely: with the window spinning the run loop, AppKit's own lazy layout finishes whatever
    // the walk left, and `firstUnlaidCharacterIndex` reports the same answer either way. A green
    // assertion whose subject is unreachable proves nothing (invariant 30), so it is gone rather
    // than kept as reassurance. What IS reachable is the walk's own step count, below.

    /// A step is bounded by CHARACTERS, and deliberately not also by structure. This document is
    /// exactly the case that makes that look wrong — hundreds of table cells inside a few thousand
    /// characters, so the entire thing is laid out in ONE run-loop turn — and the comment on
    /// `precomputeLayout` records the two measured attempts to fix it, both of which made a real
    /// 38-table docx worse (2 turns / 105–121 ms → 3 turns / 155–170 ms → 10 turns / 186–192 ms)
    /// while never shortening the worst freeze, because the freeze is the rebuild and not this pass.
    ///
    /// So this assertion is not a claim that one turn is ideal. It is a tripwire: a third attempt to
    /// slice by structure changes this count, and has to come with new measurements.
    func testAStepIsBoundedByCharactersNotByStructure() throws {
        // The document must outlive the controller: `NSWindowController.document` is an unowned
        // back-reference, so letting it go here would leave the controller pointing at freed memory.
        let (doc, wc) = try open(tableDenseMarkdown(tables: 60))
        defer { withExtendedLifetime(doc) {} }
        let storage = try XCTUnwrap(wc.textView.textStorage)
        // The premise: structurally heavy (one NSTextTable per section) and short (well under one
        // 20k chunk). If either stops being true the test is measuring something else.
        var cellParagraphs = 0
        var distinctTables = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            guard let ps = v as? NSParagraphStyle, let b = ps.textBlocks.first as? NSTextTableBlock else { return }
            cellParagraphs += 1
            distinctTables.insert(ObjectIdentifier(b.table))
        }
        XCTAssertEqual(distinctTables.count, 60)
        XCTAssertGreaterThan(cellParagraphs, 500)
        XCTAssertLessThan(storage.length, 20_000)

        wc.precomputeLayout()
        XCTAssertTrue(settle(wc))
        let expected = max(1, Int(ceil(Double(storage.length) / 20_000.0)))
        XCTAssertEqual(wc.layoutStepCount, expected,
                       "\(cellParagraphs) cell paragraphs in \(storage.length) characters were laid out in "
                       + "\(wc.layoutStepCount) run-loop turns; the bound is characters, not structure")
    }

    /// A render that lands mid-walk must cancel it: `layoutToken` is what stops a stale walk from
    /// laying out ranges of a document that no longer exists. Two walks started back to back leave
    /// only the second one running, so the step count is the second walk's alone.
    func testANewWalkCancelsTheOneInFlight() throws {
        let (doc, wc) = try open(tableDenseMarkdown(tables: 60))
        defer { withExtendedLifetime(doc) {} }
        wc.precomputeLayout()
        wc.precomputeLayout()
        XCTAssertTrue(settle(wc))
        let storage = try XCTUnwrap(wc.textView.textStorage)
        let expected = max(1, Int(ceil(Double(storage.length) / 20_000.0)))
        XCTAssertEqual(wc.layoutStepCount, expected)
    }
}

extension OfficeRenderLatencyTests {
    /// Dumps one real table's resolved geometry — the parsed cell spans on one side, and the
    /// `NSTextTableBlock`s the reader actually laid out on the other. Column edges that disagree
    /// BETWEEN ROWS of the same table are invisible in a unit test and obvious here.
    /// `FMD_TABLE_PROBE=<file>` plus `FMD_TABLE_MATCH=<text in the table>`.
    func testDumpOneRealTableGeometry() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_TABLE_PROBE"] else {
            throw XCTSkip("set FMD_TABLE_PROBE to dump a real document's table geometry")
        }
        let needle = ProcessInfo.processInfo.environment["FMD_TABLE_MATCH"] ?? ""
        let url = URL(fileURLWithPath: path)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: Data(contentsOf: url), ofType: "org.openxmlformats.wordprocessingml.document")

        func describe(_ blocks: [OfficeBlock], depth: Int = 0) {
            for b in blocks {
                guard case let .table(rows, _, widths, format) = b else { continue }
                let text = rows.flatMap { $0 }.flatMap { $0.blocks }.compactMap { blk -> String? in
                    if case let .paragraph(spans, _, _, _, _) = blk { return spans.map(\.text).joined() }
                    return nil
                }.joined()
                guard needle.isEmpty || text.contains(needle) else { continue }
                // One decimal, and the SUM alongside the source total. `Int()` truncates, and nine
                // truncated columns read as 4pt short of a grid that is exactly the page width —
                // which cost a real debugging session chasing a table-geometry bug that did not
                // exist. These are the SOURCE grid columns; the laid-out edges are cumulative and
                // rounded (`GridTextTable.edges(forWidth:)`), so they never drift.
                let sum = widths.reduce(0, +)
                let cols = widths.map { String(format: "%.1f", $0) }.joined(separator: ", ")
                print(String(format: "  TABLE source grid=[%@] sum=%.1f sourceWidth=%.1f",
                             cols, sum, format.sourceWidth ?? -1))
                for (r, row) in rows.enumerated() {
                    let spec = row.map { "(c\($0.colSpan)r\($0.rowSpan)\($0.width.map { ",w\(Int($0))" } ?? ""))" }
                    print("    row\(r): \(row.count) cells \(spec.joined(separator: " "))")
                }
                return
            }
        }
        describe(doc.officeBlocks)

        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 800), display: false)
        wc.updateTextInset()
        let storage = try XCTUnwrap(wc.textStorageRef)
        // Dump the table that CONTAINS the needle, not merely the first one in the document.
        let ns = storage.string as NSString
        var target: ObjectIdentifier?
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { v, r, stop in
            guard target == nil, let ps = v as? NSParagraphStyle,
                  let block = ps.textBlocks.first as? NSTextTableBlock else { return }
            if needle.isEmpty || ns.substring(with: r).contains(needle) {
                target = ObjectIdentifier(block.table); stop.pointee = true
            }
        }
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            guard let ps = v as? NSParagraphStyle, let block = ps.textBlocks.first as? NSTextTableBlock,
                  ObjectIdentifier(block.table) == target else { return }
            let cellText = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).prefix(9)
            print(String(format: "    r%d c%d span%d  content %7.2f  pad %4.1f/%4.1f  border %4.1f/%4.1f  %@",
                         block.startingRow, block.startingColumn, block.columnSpan, block.contentWidth,
                         block.width(for: .padding, edge: .minX), block.width(for: .padding, edge: .maxX),
                         block.width(for: .border, edge: .minX), block.width(for: .border, edge: .maxX),
                         String(cellText)))
        }

        // VERTICAL axis, S5-A: the horizontal dump above never touches a row's height. Walk every
        // laid-out LINE FRAGMENT (the real TextKit measurement, not an estimate) in the target
        // table, tag each with the row/column its paragraphStyle's NSTextTableBlock claims, and
        // roll them up per row (minY/maxY/height/lineCount) and per cell (lineCount, so a
        // multi-line cell's per-line contribution is visible — invariant 161(b) charged exactly
        // this to "a cell's last line is a line, not a line plus its spacing").
        guard let lm = wc.textView.layoutManager, let tc = wc.textView.textContainer else {
            return
        }
        lm.ensureLayout(for: tc)
        struct Frag { let row: Int; let col: Int; let minY: CGFloat; let maxY: CGFloat; let block: NSTextTableBlock }
        var frags: [Frag] = []
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, _, _, glyphRange, _ in
            let charIndex = lm.characterIndexForGlyph(at: glyphRange.location)
            guard charIndex < storage.length,
                  let ps = storage.attribute(.paragraphStyle, at: charIndex, effectiveRange: nil) as? NSParagraphStyle,
                  let block = ps.textBlocks.first as? NSTextTableBlock,
                  ObjectIdentifier(block.table) == target else { return }
            frags.append(Frag(row: block.startingRow, col: block.startingColumn,
                               minY: rect.minY, maxY: rect.maxY, block: block))
        }
        // TEXT bounds = the line fragments themselves (what S5-A first reported). BLOCK bounds =
        // the actual NSTextTableBlock reservation: text bounds widened by that cell's own
        // top/bottom padding AND border (`.padding`/`.border`, edge `.minY`/`.maxY` — the SAME
        // `NSTextBlock.Layer` the horizontal dump above already reads for `.minX`/`.maxX`). A row
        // with zero vertical padding/border makes the two identical; a row that does not is
        // reported as two DIFFERENT numbers below rather than silently picking one, because the
        // vertical gap BETWEEN rows only shows up in block bounds, never in text bounds.
        let byCell = Dictionary(grouping: frags, by: { "\($0.row),\($0.col)" })
        struct CellBounds { let row: Int; let col: Int; let textMinY: CGFloat; let textMaxY: CGFloat
            let blockMinY: CGFloat; let blockMaxY: CGFloat; let lines: Int }
        var cellBounds: [CellBounds] = []
        for key in byCell.keys.sorted() {
            let cellFrags = byCell[key] ?? []
            guard let first = cellFrags.first else { continue }
            let textMinY = cellFrags.map(\.minY).min() ?? 0
            let textMaxY = cellFrags.map(\.maxY).max() ?? 0
            let block = first.block
            let padTop = block.width(for: .padding, edge: .minY)
            let padBottom = block.width(for: .padding, edge: .maxY)
            let borderTop = block.width(for: .border, edge: .minY)
            let borderBottom = block.width(for: .border, edge: .maxY)
            cellBounds.append(CellBounds(row: first.row, col: first.col,
                                          textMinY: textMinY, textMaxY: textMaxY,
                                          blockMinY: textMinY - padTop - borderTop,
                                          blockMaxY: textMaxY + padBottom + borderBottom,
                                          lines: cellFrags.count))
        }
        let byRow = Dictionary(grouping: cellBounds, by: \.row)
        print("  VERTICAL row geometry — TEXT bounds (line fragments) vs BLOCK bounds (+pad/border):")
        for row in byRow.keys.sorted() {
            let cells = byRow[row] ?? []
            let textMinY = cells.map(\.textMinY).min() ?? 0
            let textMaxY = cells.map(\.textMaxY).max() ?? 0
            let blockMinY = cells.map(\.blockMinY).min() ?? 0
            let blockMaxY = cells.map(\.blockMaxY).max() ?? 0
            let lines = cells.reduce(0) { $0 + $1.lines }
            let same = abs(textMinY - blockMinY) < 0.05 && abs(textMaxY - blockMaxY) < 0.05
            print(String(format: "    row%d: TEXT minY=%9.2f maxY=%9.2f h=%7.2f | BLOCK minY=%9.2f maxY=%9.2f h=%7.2f  %@ lines=%d",
                         row, textMinY, textMaxY, textMaxY - textMinY,
                         blockMinY, blockMaxY, blockMaxY - blockMinY,
                         same ? "(identical — pad/border 0)" : "(DIFFERS — see pad/border above)", lines))
        }
        print("  VERTICAL multi-line cells (lines > 1):")
        for key in byCell.keys.sorted() {
            let cellFrags = byCell[key] ?? []
            guard cellFrags.count > 1 else { continue }
            let sorted = cellFrags.sorted { $0.minY < $1.minY }
            let lineDump = sorted.enumerated().map { i, f in
                String(format: "line%d[%.2f,%.2f]", i, f.minY, f.maxY)
            }.joined(separator: " ")
            print("    cell(row\(sorted[0].row),col\(sorted[0].col)) lines=\(cellFrags.count) \(lineDump)")
        }
    }
}

/// A table must occupy the SAME width whatever its column count. It did not: cells subtracted their
/// full left and right border from their content while `collapsesBorders` makes AppKit charge a
/// shared interior border ONCE, so every extra column cost another border-width and a 9-column table
/// finished 8.5pt short of a 2-column one at the same reading width. Two tables in one report then
/// ended at visibly different x — the "tables look ragged" complaint, underneath the border colours.
/// Measured before the fix: 2 cols -1.5, 3 cols -2.5, 5 cols -4.5, 9 cols -8.5 against a 600pt target.
///
/// With `collapsesBorders` off and every boundary resolved to exactly one owner (the table-border-
/// conflict rewrite), the table lands EXACTLY on `target` — not "within 1pt" — for every shape tested,
/// plain or merged. Every exactness measurement below runs the layout container `containerSlack`
/// points WIDER than `target`: a container sized exactly at `target` silently CLIPS any overshoot, so
/// "laidOut == target" measured in a same-size container is ambiguous between "genuinely exact" and
/// "overshot and got clipped to look exact" — a real trap this rewrite hit once during its own
/// measurement spike. A wide container can't clip, so it is the only honest way to claim exactness.
final class TableWidthIndependenceTests: XCTestCase {
    private func laidOutWidth(of attr: NSAttributedString, containerWidth: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: attr)
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: containerWidth, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        storage.addLayoutManager(lm); lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        return lm.usedRect(for: tc).width
    }

    private func laidOutWidth(columns ncol: Int, target: CGFloat, containerSlack: CGFloat = 200) -> CGFloat {
        let theme = RenderTheme.current(size: 16)
        let row = (0..<ncol).map { TableBlockBuilder.CellContent(content: NSAttributedString(string: "c\($0)")) }
        let attr = TableBlockBuilder.build(rows: [row, row], headerRows: 0, theme: theme,
                                           columnWidths: Array(repeating: target / CGFloat(ncol), count: ncol),
                                           width: target)
        return laidOutWidth(of: attr, containerWidth: target + containerSlack)
    }

    /// Every distinct `NSTextTableBlock` in `attr`, in reading (row, column) order — the shared
    /// helper this file's boundary/merge/geometry tests read block widths and spans back through.
    private func placedBlocks(in attr: NSAttributedString) -> [NSTextTableBlock] {
        var seen = Set<ObjectIdentifier>()
        var out: [NSTextTableBlock] = []
        attr.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: attr.length)) { value, _, _ in
            guard let ps = value as? NSParagraphStyle, let block = ps.textBlocks.first as? NSTextTableBlock,
                  seen.insert(ObjectIdentifier(block)).inserted else { return }
            out.append(block)
        }
        return out.sorted { ($0.startingRow, $0.startingColumn) < ($1.startingRow, $1.startingColumn) }
    }

    func testATableIsTheSameWidthWhateverItsColumnCount() {
        let target: CGFloat = 600
        let widths = [2, 3, 5, 9, 13].map { laidOutWidth(columns: $0, target: target) }
        let spread = (widths.max() ?? 0) - (widths.min() ?? 0)
        XCTAssertLessThanOrEqual(spread, 0.01,
            "column count must not change the table's width — got \(widths)")
        for w in widths {
            XCTAssertEqual(w, target, accuracy: 0.01,
                "a table must fill its reading column EXACTLY, not fall short of it or overshoot it — got \(w)")
        }
    }
}

extension TableWidthIndependenceTests {
    /// MERGED rows were never measured. A header that spans three columns crosses interior boundaries
    /// that are not drawn, so its border accounting differs from the unmerged row below it. Plain /
    /// merged / mixed all land EXACTLY on `target` — merging is not a separate case for width (the
    /// agent brief's own "do not assume merging is the culprit" — verified again here, now as a real
    /// assertion instead of a print).
    func testMeasureMergedVsUnmergedRowWidth() {
        let target: CGFloat = 600
        let ncol = 13
        func cell(_ s: String, span: Int = 1) -> TableBlockBuilder.CellContent {
            TableBlockBuilder.CellContent(content: NSAttributedString(string: s), columnSpan: span)
        }
        let widths = Array(repeating: target / CGFloat(ncol), count: ncol)
        let theme = RenderTheme.current(size: 16)

        // row A: 13 plain cells.   row B: 1 + four 3-column spans (the real shape in the report).
        let plain = (0..<ncol).map { cell("c\($0)") }
        let merged = [cell("지역")] + (0..<4).map { cell("y\($0)", span: 3) }

        for (name, rows) in [("plain only", [plain, plain]),
                             ("merged only", [merged, merged]),
                             ("merged + plain", [merged, plain])] {
            let attr = TableBlockBuilder.build(rows: rows, headerRows: 0, theme: theme,
                                               columnWidths: widths, width: target)
            let used = laidOutWidth(of: attr, containerWidth: target + 200)
            print(String(format: "  %-16@ used=%.4f  target=%.1f  차이 %+.4f",
                         name as NSString, used, target, used - target))
            XCTAssertEqual(used, target, accuracy: 0.01, "\(name) must land exactly on target — got \(used)")
        }
    }

    // MARK: Boundary resolution (design doc §3, Step B) — measured through the SAME laid-out-block
    // readback the rest of this file uses, never argued from source.

    /// Two neighbours declaring DIFFERENT widths resolve to exactly ONE rule, at the WIDER winner's
    /// width and colour, assigned to the OWNER side (the left cell's `.maxX` for an interior vertical
    /// boundary) — the other side (the right cell's `.minX`) always reads 0. Mutation check: flipping
    /// the tie-break comparison from `>` to `<` (narrower-wins) made this read 0.5 instead of 4 and
    /// the assertion failed as predicted — see the implementation log.
    func testDifferingNeighbourWidthsResolveToExactlyOneRuleOnTheOwnerSide() {
        let theme = RenderTheme.current(size: 16)
        var left = TableBlockBuilder.CellContent(content: NSAttributedString(string: "L"))
        left.edgeBorders = EdgeBorders(right: .drawn(BorderSide(width: 1, color: .systemBlue)))
        var right = TableBlockBuilder.CellContent(content: NSAttributedString(string: "R"))
        right.edgeBorders = EdgeBorders(left: .drawn(BorderSide(width: 4, color: .systemRed)))
        let attr = TableBlockBuilder.build(rows: [[left, right]], headerRows: 0, theme: theme, width: 400)
        let blocks = placedBlocks(in: attr)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].width(for: .border, edge: .maxX), 4, "the wider neighbour's width wins the boundary")
        XCTAssertEqual(blocks[0].borderColor(for: .maxX), .systemRed, "and its colour travels with the winning width")
        XCTAssertEqual(blocks[1].width(for: .border, edge: .minX), 0, "the non-owner side always reads 0")
    }

    /// `.suppressed` LOSES to a drawn rule rather than vetoing it (design doc §3, Step B rule 1 —
    /// `nil` counts as width 0, so any real width beats it) — matching Word: removing one cell's own
    /// border still leaves the neighbour's visible.
    func testSuppressedLosesToADrawnRuleRatherThanVetoingIt() {
        let theme = RenderTheme.current(size: 16)
        var left = TableBlockBuilder.CellContent(content: NSAttributedString(string: "L"))
        left.edgeBorders = EdgeBorders(right: .suppressed)
        var right = TableBlockBuilder.CellContent(content: NSAttributedString(string: "R"))
        right.edgeBorders = EdgeBorders(left: .drawn(BorderSide(width: 2, color: .systemGreen)))
        let attr = TableBlockBuilder.build(rows: [[left, right]], headerRows: 0, theme: theme, width: 400)
        let blocks = placedBlocks(in: attr)
        XCTAssertEqual(blocks[0].width(for: .border, edge: .maxX), 2,
                       "the drawn rule wins even though the OWNER side suppressed its own")
        XCTAssertEqual(blocks[0].borderColor(for: .maxX), .systemGreen)
        XCTAssertEqual(blocks[1].width(for: .border, edge: .minX), 0)
    }

    /// Two suppressed sides draw nothing — suppression only loses to a REAL rule, it never conjures
    /// one out of another suppression.
    func testBothSidesSuppressedDrawsNothing() {
        let theme = RenderTheme.current(size: 16)
        var left = TableBlockBuilder.CellContent(content: NSAttributedString(string: "L"))
        left.edgeBorders = EdgeBorders(right: .suppressed)
        var right = TableBlockBuilder.CellContent(content: NSAttributedString(string: "R"))
        right.edgeBorders = EdgeBorders(left: .suppressed)
        let attr = TableBlockBuilder.build(rows: [[left, right]], headerRows: 0, theme: theme, width: 400)
        let blocks = placedBlocks(in: attr)
        XCTAssertEqual(blocks[0].width(for: .border, edge: .maxX), 0)
        XCTAssertEqual(blocks[1].width(for: .border, edge: .minX), 0)
    }

    /// Equal width defers to whichever side was actually DECLARED over a bare theme fallback (Step B
    /// rule 2) — here the OWNER (left) never declared anything (pure fallback) and the NON-owner
    /// (right) explicitly declared the same width in a different colour; the explicit declaration's
    /// colour wins the tie even though it has to travel onto the owner's own edge to be drawn.
    func testEqualWidthTieBreaksTowardTheExplicitlyDeclaredSideNotTheBareFallback() {
        let theme = RenderTheme.current(size: 16)
        let left = TableBlockBuilder.CellContent(content: NSAttributedString(string: "L"))   // no edgeBorders — bare theme fallback
        var right = TableBlockBuilder.CellContent(content: NSAttributedString(string: "R"))
        right.edgeBorders = EdgeBorders(left: .drawn(BorderSide(width: RenderTheme.tableBorderWidth, color: .systemPurple)))
        let attr = TableBlockBuilder.build(rows: [[left, right]], headerRows: 0, theme: theme, width: 400)
        let blocks = placedBlocks(in: attr)
        XCTAssertEqual(blocks[0].width(for: .border, edge: .maxX), RenderTheme.tableBorderWidth,
                       "equal width either way — the boundary still draws at the theme width")
        XCTAssertEqual(blocks[0].borderColor(for: .maxX), .systemPurple,
                       "the explicitly declared side wins the tie over a bare fallback, even from the non-owner")
        XCTAssertEqual(blocks[1].width(for: .border, edge: .minX), 0)
    }

    /// Still tied (both sides explicitly declared, same width, different colour) keeps the OWNER's
    /// own colour — deterministic regardless of which side of the boundary happens to be scanned
    /// first (Step B rule 3).
    func testEqualWidthTieBetweenTwoExplicitDeclarationsKeepsTheOwnersOwnColour() {
        let theme = RenderTheme.current(size: 16)
        var left = TableBlockBuilder.CellContent(content: NSAttributedString(string: "L"))
        left.edgeBorders = EdgeBorders(right: .drawn(BorderSide(width: 2, color: .systemBlue)))
        var right = TableBlockBuilder.CellContent(content: NSAttributedString(string: "R"))
        right.edgeBorders = EdgeBorders(left: .drawn(BorderSide(width: 2, color: .systemRed)))
        let attr = TableBlockBuilder.build(rows: [[left, right]], headerRows: 0, theme: theme, width: 400)
        let blocks = placedBlocks(in: attr)
        XCTAssertEqual(blocks[0].width(for: .border, edge: .maxX), 2)
        XCTAssertEqual(blocks[0].borderColor(for: .maxX), .systemBlue,
                       "both sides explicit and equal width — the OWNER's own colour wins")
        XCTAssertEqual(blocks[1].width(for: .border, edge: .minX), 0)
    }

    /// MERGED-CELL UNIFORMITY (design doc §3, Step C) — a cell spanning rows 0…2 owns its `.maxX` for
    /// its WHOLE span, so it takes the WIDEST of its three right-neighbours' left declarations (0.5,
    /// 3.0 — deliberately the MIDDLE row, ruling out "just takes the first/last neighbour" as an
    /// accidental correct answer — and 1.0) and draws that one rule uniformly down the whole merge:
    /// `.maxX == 3.0`, not 0.5 (narrowest) or 1.0 (its own theme default) or an average. Mirrors the
    /// design spike's Q3 measurement exactly. Mutation check: flipping the tie-break to "narrower
    /// wins" folded this to 0.5 and the assertion failed as predicted — see the implementation log.
    func testAVerticallyMergedCellTakesTheWidestOfItsRightNeighboursAndDrawsOneUniformRule() {
        let theme = RenderTheme.current(size: 16)
        let merged = TableBlockBuilder.CellContent(content: NSAttributedString(string: "M"), rowSpan: 3)
        func neighbour(_ w: CGFloat) -> TableBlockBuilder.CellContent {
            var c = TableBlockBuilder.CellContent(content: NSAttributedString(string: "n"))
            c.edgeBorders = EdgeBorders(left: .drawn(BorderSide(width: w, color: .black)))
            return c
        }
        let rows: [[TableBlockBuilder.CellContent]] = [[merged, neighbour(0.5)], [neighbour(3.0)], [neighbour(1.0)]]
        let attr = TableBlockBuilder.build(rows: rows, headerRows: 0, theme: theme, width: 400)
        let blocks = placedBlocks(in: attr)
        let mergedBlock = try! XCTUnwrap(blocks.first { $0.rowSpan == 3 })
        XCTAssertEqual(mergedBlock.width(for: .border, edge: .maxX), 3.0,
                       "the widest of the three right-neighbour claims wins, uniformly down the whole merge")
        let neighbours = blocks.filter { $0.startingColumn == 1 }
        XCTAssertEqual(neighbours.count, 3)
        for n in neighbours {
            XCTAssertEqual(n.width(for: .border, edge: .minX), 0,
                           "a right-neighbour never draws its own side of a boundary the merge owns")
        }
    }

    /// TIE-BREAK DETERMINISM among MERGED-CELL neighbours (`wider`'s own fold). When several right-
    /// neighbours tie at the SAME widest width but declare DIFFERENT colours, the winner must be the
    /// SAME cell on every launch — not whichever a `Set<Int>`'s per-process-randomised hash-seed
    /// iteration happened to visit first. Measured before `.sorted()`: 14 separate process launches
    /// of this identical construction resolved red 6×, blue 5×, green 3× — the merged cell's rule
    /// changed colour from launch to launch with nothing in the document asking for that, reintroducing
    /// from a different direction the exact fault this whole pipeline exists to remove. Folding over
    /// `neighbours.sorted()` (ascending placement index) makes the TOPMOST (row 0) neighbour's colour
    /// the deterministic, reproducible winner. A single in-process run cannot force a second hash
    /// seed to prove the OLD bug directly — the multi-process reproduction is in the mutation report.
    func testTiedNeighbourWidthsResolveToTheSameColourDeterministically() {
        let theme = RenderTheme.current(size: 16)
        let merged = TableBlockBuilder.CellContent(content: NSAttributedString(string: "M"), rowSpan: 3)
        func neighbour(_ color: NSColor) -> TableBlockBuilder.CellContent {
            var c = TableBlockBuilder.CellContent(content: NSAttributedString(string: "n"))
            c.edgeBorders = EdgeBorders(left: .drawn(BorderSide(width: 3, color: color)))
            return c
        }
        let rows: [[TableBlockBuilder.CellContent]] = [[merged, neighbour(.systemRed)],
                                                        [neighbour(.systemGreen)], [neighbour(.systemBlue)]]
        let attr = TableBlockBuilder.build(rows: rows, headerRows: 0, theme: theme, width: 400)
        let blocks = placedBlocks(in: attr)
        let mergedBlock = try! XCTUnwrap(blocks.first { $0.rowSpan == 3 })
        XCTAssertEqual(mergedBlock.width(for: .border, edge: .maxX), 3.0)
        XCTAssertEqual(mergedBlock.borderColor(for: .maxX), .systemRed,
                       "a width tie across neighbours must deterministically pick the TOPMOST (row 0) " +
                       "one, not whichever a Set's hash-randomised iteration visited first")
    }

    /// MARKDOWN GEOMETRY PROBE — a GFM table passes NO border arguments at all (invariant 37's "the
    /// document said nothing" case), so this exercises the exact call shape `MarkdownRenderer.
    /// visitTable` uses. Two things this rewrite must hold for it: (1) every row of the SAME table
    /// reads the SAME integer column boundary — measured here by reading back two DIFFERENT rows'
    /// (one plain, one containing a 2-column merge) implied x-position (padding + border + content,
    /// cumulative) and asserting they agree, the actual invariant-39 promise, proven from laid-out
    /// blocks rather than argued from the shared `columnProportions` source; and (2) the laid-out
    /// total moves from the measured pre-rewrite production baseline of `target − 0.5` (collapsing
    /// ON + the halved-interior formula + the `width − 1` slack together — see `GridTextTable.edges(
    /// forWidth:)`'s doc comment) to EXACTLY `target` now that collapsing is off and nothing is
    /// double-counted. Isolating just the slack (mutation check: reverting `edges(forWidth:)` alone
    /// back to `width − 1` while leaving collapsing off) lands at `target − 1`, not `target − 0.5` —
    /// the 0.5 was specific to the OLD three-part combination; with collapsing off there is no
    /// halving left to partially offset a reintroduced slack, so a single-part regression here is a
    /// full point, not half of one. Both numbers are real measurements, not the same claim twice.
    func testMarkdownTableGeometryColumnBoundariesAgreeAcrossRowsAndTotalIsExact() {
        let target: CGFloat = 600
        let ncol = 4
        func cell(_ s: String, span: Int = 1) -> TableBlockBuilder.CellContent {
            TableBlockBuilder.CellContent(content: NSAttributedString(string: s), columnSpan: span)
        }
        let plain = (0..<ncol).map { cell("c\($0)") }
        let mixed = [cell("wide", span: 2), cell("x"), cell("y")]
        let theme = RenderTheme.current(size: 16)
        // NO border arguments — exactly `MarkdownRenderer.visitTable`'s call shape.
        let attr = TableBlockBuilder.build(rows: [plain, mixed], headerRows: 1, theme: theme, width: target)

        let blocks = placedBlocks(in: attr)
        func impliedRightX(_ block: NSTextTableBlock) -> CGFloat {
            var x: CGFloat = 0
            for b in blocks where b.startingRow == block.startingRow && b.startingColumn < block.startingColumn {
                x += b.width(for: .padding, edge: .minX) + b.width(for: .padding, edge: .maxX)
                     + b.width(for: .border, edge: .minX) + b.width(for: .border, edge: .maxX) + b.contentWidth
            }
            x += block.width(for: .padding, edge: .minX) + block.width(for: .padding, edge: .maxX)
                 + block.width(for: .border, edge: .minX) + block.width(for: .border, edge: .maxX) + block.contentWidth
            return x
        }
        // Row 0 (plain, header) column 2 ends where row 1's merged (colSpan 2) cell also ends — the
        // SAME boundary, read back from two structurally different rows of the same table.
        let row0Col1 = try! XCTUnwrap(blocks.first { $0.startingRow == 0 && $0.startingColumn == 1 })
        let row1Merged = try! XCTUnwrap(blocks.first { $0.startingRow == 1 && $0.columnSpan == 2 })
        XCTAssertEqual(impliedRightX(row0Col1), impliedRightX(row1Merged), accuracy: 0.01,
                       "the plain row and the merged row must agree on the SAME column boundary")

        let used = laidOutWidth(of: attr, containerWidth: target + 200)
        XCTAssertEqual(used, target, accuracy: 0.01,
                       "a markdown table (no border arguments) must land EXACTLY on target now — got \(used); " +
                       "the measured pre-rewrite PRODUCTION baseline (collapsing on) was target − 0.5")
    }

    /// FRACTIONAL reading-column widths must never OVERSHOOT. `edges(forWidth:)` cumulates each
    /// column's edge with plain `.rounded()` (round-half-away-from-zero); at a width whose fractional
    /// part sits in [0.5, 1.0) — 705.5, say — the FINAL edge used to round UP to 706, half a point
    /// past the container, which then CLIPS the overshoot and silently drops the last column's right
    /// rule — reintroducing, from a different angle, the exact clip condition the deleted `width - 1`
    /// slack existed to prevent. The production column width is built from integer terms only
    /// (`scrollView.contentSize.width - 64 - 2·lineFragmentPadding`), so this has not been observed
    /// live, but nothing guarantees it stays that way (a split-view divider, a scaled display, or a
    /// future inset change could all hand this a fractional width) — the fix (`edges(forWidth:)`
    /// clamps only its LAST edge to `usable`'s floor) removes the exposure rather than waiting for it.
    func testFractionalReadingColumnWidthsNeverOvershoot() {
        let theme = RenderTheme.current(size: 16)
        for target: CGFloat in [705.5, 600.5, 833.5] {
            let ncol = 5
            let row = (0..<ncol).map { TableBlockBuilder.CellContent(content: NSAttributedString(string: "c\($0)")) }
            let attr = TableBlockBuilder.build(rows: [row, row], headerRows: 0, theme: theme,
                                               columnWidths: Array(repeating: target / CGFloat(ncol), count: ncol),
                                               width: target)
            let used = laidOutWidth(of: attr, containerWidth: target + 200)
            XCTAssertLessThanOrEqual(used, target, "a fractional target must never be exceeded — got \(used) at target \(target)")
            XCTAssertGreaterThan(used, target - 1, "the shortfall must stay under 1pt, not the old width-1-style full point of slack — got \(used) at target \(target)")
        }
        // Integer widths must stay UNCHANGED — the clamp is a no-op once `usable` is already integer.
        for target: CGFloat in [600, 400] {
            let ncol = 5
            let row = (0..<ncol).map { TableBlockBuilder.CellContent(content: NSAttributedString(string: "c\($0)")) }
            let attr = TableBlockBuilder.build(rows: [row, row], headerRows: 0, theme: theme,
                                               columnWidths: Array(repeating: target / CGFloat(ncol), count: ncol),
                                               width: target)
            let used = laidOutWidth(of: attr, containerWidth: target + 200)
            XCTAssertEqual(used, target, accuracy: 0.01, "an integer target must stay exact")
        }
    }

    /// NARROW COLUMNS — the doc comment on `edges(forWidth:)` used to claim exactness "for any column
    /// count and any merge shape", unconditionally. It does not hold once a column is too narrow to
    /// fit `TableBlockBuilder.defaultCellPadding` (7pt) on both sides: the 1pt content-width floor
    /// then costs a real, per-column overshoot, and the container clips the last column's right rule
    /// to hide it — measured before `build` shrank padding to fit: 40 cols/600pt overshot by 41pt,
    /// 60 cols/600pt by 361pt, and a `w:gridCol w:w="0"` hidden column (`[0, 500, 100]`) by 17pt.
    /// `build` now shrinks PADDING first (never a border — invariant 47 already decided those), down
    /// to an INTEGER floor of 0 (invariant 42), before the content floor is ever reached — this is
    /// bounded, not exact, and this test pins the bound rather than re-claiming exactness.
    func testNarrowColumnsOvershootIsBoundedNotUnlimited() {
        let theme = RenderTheme.current(size: 16)
        func laidOut(columnWidths: [CGFloat], target: CGFloat) -> CGFloat {
            let row = columnWidths.indices.map { TableBlockBuilder.CellContent(content: NSAttributedString(string: "c\($0)")) }
            let attr = TableBlockBuilder.build(rows: [row], headerRows: 0, theme: theme,
                                               columnWidths: columnWidths, width: target)
            return laidOutWidth(of: attr, containerWidth: target + 600)
        }
        // 40/60 equal-width columns at 600pt — padding alone (or padding+border) exceeds the column,
        // so it shrinks; the residual is the 1pt content floor, not the un-shrunk 7pt padding.
        let cols40 = laidOut(columnWidths: Array(repeating: 600.0 / 40, count: 40), target: 600)
        let cols60 = laidOut(columnWidths: Array(repeating: 600.0 / 60, count: 60), target: 600)
        XCTAssertLessThan(cols40 - 600, 41, "must not regress past the measured pre-shrink overshoot")
        XCTAssertLessThan(cols60 - 600, 120, "the padding shrink must cut this well below the pre-shrink 361pt")
        // A genuinely 0pt source column (a hidden `w:gridCol`) and a 1pt spacer column.
        let hiddenCol = laidOut(columnWidths: [0, 500, 100], target: 600)
        let spacerCol = laidOut(columnWidths: [1, 9999], target: 10000)
        XCTAssertLessThan(hiddenCol - 600, 4, "a hidden 0pt column must cost single digits, not the 17pt un-shrunk overshoot")
        XCTAssertLessThan(spacerCol - 10000, 3)
        for (name, delta) in [("40 cols", cols40 - 600), ("60 cols", cols60 - 600),
                              ("hidden col", hiddenCol - 600), ("spacer col", spacerCol - 10000)] {
            XCTAssertGreaterThanOrEqual(delta, 0, "\(name) must never fall SHORT of target — only bounded overshoot is expected")
        }
    }

    /// The padding shrink must not touch a REALISTIC table at all — every shape this file already
    /// measures as exact (2·3·5·9·13 plain columns, and the merged/mixed shapes) stays exactly on
    /// target, because `availableForPadding` comfortably exceeds `defaultCellPadding` for all of them.
    func testRealisticColumnCountsStayExactAfterThePaddingShrink() {
        let target: CGFloat = 600
        for ncol in [2, 3, 5, 9, 13] {
            let w = laidOutWidth(columns: ncol, target: target)
            XCTAssertEqual(w, target, accuracy: 0.01, "\(ncol) columns must stay exact — the shrink is for narrow columns only")
        }
    }
}

// MARK: - Document-faithful table geometry (paged padding + table width, "표가 너무 큼")

extension TableWidthIndependenceTests {
    /// JOB 1 — PADDING is a FALLBACK for paged, not a FLOOR: a cell's own declared value survives at
    /// ANY size including 0, and each of the four edges is independent. Reproduces the owner's own
    /// measured report shape: a 4-column table, 10pt document default, cells declaring Word's stock
    /// `w:tblCellMar` (`top=bottom=0, left=right=5.4pt`) — before this fix every cell read
    /// `max(2, 7) = 7` on ALL four edges (the floor bug at `TableBlockBuilder.swift`'s old line 271,
    /// smeared onto top/bottom by `DocxReader`'s old single-edge `cellMargin`); after it, the block
    /// reads back EXACTLY what the document declared.
    func testPagedCellPaddingUsesTheDocumentsOwnZeroNotTheFloor() {
        let theme = RenderTheme.current(size: 16)
        var cell = TableBlockBuilder.CellContent(content: NSAttributedString(string: "x"))
        cell.edgePadding = EdgePadding(top: 0, left: 5, bottom: 0, right: 5)
        let attr = TableBlockBuilder.build(rows: [[cell]], headerRows: 0, theme: theme,
                                           paged: true, width: 400)
        let block = try! XCTUnwrap(placedBlocks(in: attr).first)
        XCTAssertEqual(block.width(for: .padding, edge: .minY), 0, "a declared ZERO top must survive, not float up to the 7pt floor")
        XCTAssertEqual(block.width(for: .padding, edge: .maxY), 0, "same for bottom")
        XCTAssertEqual(block.width(for: .padding, edge: .minX), 5, "the declared 5pt side must be used exactly, not maxed against 7")
        XCTAssertEqual(block.width(for: .padding, edge: .maxX), 5)
    }

    /// The cascade's THIRD layer: an edge NEITHER the cell nor the table declared still falls back to
    /// `defaultCellPadding` (7) — the fallback only disappears where the document actually spoke.
    func testPagedCellPaddingFallsBackToTheComfortableDefaultWhenNothingIsDeclared() {
        let theme = RenderTheme.current(size: 16)
        let cell = TableBlockBuilder.CellContent(content: NSAttributedString(string: "x"))   // no edgePadding at all
        let attr = TableBlockBuilder.build(rows: [[cell]], headerRows: 0, theme: theme, paged: true, width: 400)
        let block = try! XCTUnwrap(placedBlocks(in: attr).first)
        for edge: NSRectEdge in [.minX, .maxX, .minY, .maxY] {
            XCTAssertEqual(block.width(for: .padding, edge: edge), TableBlockBuilder.defaultCellPadding,
                           "an undeclared edge must still get the theme's own comfortable default")
        }
    }

    /// The TABLE's own default (`tablePadding`, docx `w:tblCellMar`) is the layer BENEATH a cell's own
    /// edge, exactly mirroring `EdgeBorders`' cell-then-table cascade — a cell that says nothing
    /// inherits the table's declared default rather than skipping straight to the 7pt fallback.
    func testPagedCellPaddingInheritsTheTablesOwnDefaultBeforeFallingBackToTheTheme() {
        let theme = RenderTheme.current(size: 16)
        let cell = TableBlockBuilder.CellContent(content: NSAttributedString(string: "x"))   // no edgePadding
        let tablePadding = EdgePadding(top: 0, left: 3, bottom: 0, right: 3)
        let attr = TableBlockBuilder.build(rows: [[cell]], headerRows: 0, theme: theme,
                                           tablePadding: tablePadding, paged: true, width: 400)
        let block = try! XCTUnwrap(placedBlocks(in: attr).first)
        XCTAssertEqual(block.width(for: .padding, edge: .minY), 0, "inherits the TABLE's own zero top")
        XCTAssertEqual(block.width(for: .padding, edge: .minX), 3, "inherits the TABLE's own 3pt side")
    }

    /// The NON-paged model must stay BYTE IDENTICAL: `edgePadding`/`tablePadding` are simply never
    /// consulted, and the floor (`max`, never a document's smaller number) still governs — this is
    /// the exact call shape (no `paged:`) every markdown table and every non-paged office table uses.
    func testNonPagedCellPaddingStaysAFloorRegardlessOfEdgePadding() {
        let theme = RenderTheme.current(size: 16)
        var cell = TableBlockBuilder.CellContent(content: NSAttributedString(string: "x"))
        cell.edgePadding = EdgePadding(top: 0, left: 0, bottom: 0, right: 0)   // must be IGNORED
        cell.padding = 2
        let attr = TableBlockBuilder.build(rows: [[cell]], headerRows: 0, theme: theme, width: 400)   // paged defaults false
        let block = try! XCTUnwrap(placedBlocks(in: attr).first)
        for edge: NSRectEdge in [.minX, .maxX, .minY, .maxY] {
            XCTAssertEqual(block.width(for: .padding, edge: edge), TableBlockBuilder.defaultCellPadding,
                           "non-paged: `max(2, 7) == 7` on every edge, edgePadding ignored entirely")
        }
    }

    /// JOB 2 — a PAGED table's own authored width (`maxWidth`, `TableFormat.sourceWidth`) is what it
    /// lays out at, clamped DOWN from the column — never stretched to fill it. Reproduces the "표가
    /// 너무 큼" shape: a 300pt table inside a 600pt column lands at EXACTLY 300, not 600 (the
    /// pre-fix 2.0× stretch — the owner's real report measured 1.43×, same defect at a different
    /// ratio). The wide-container discipline (`laidOutWidth`'s own doc) still applies: a container
    /// sized exactly at the CLAMPED width would silently clip an overshoot into looking exact.
    func testPagedTableLaysOutAtItsOwnAuthoredWidthNotTheColumn() {
        let theme = RenderTheme.current(size: 16)
        let ncol = 3
        let row = (0..<ncol).map { TableBlockBuilder.CellContent(content: NSAttributedString(string: "c\($0)")) }
        let attr = TableBlockBuilder.build(rows: [row, row], headerRows: 0, theme: theme,
                                           columnWidths: Array(repeating: 100, count: ncol),   // sums to 300
                                           paged: true, maxWidth: 300, width: 600)
        let used = laidOutWidth(of: attr, containerWidth: 600 + 200)
        XCTAssertEqual(used, 300, accuracy: 0.01,
                       "a paged table narrower than the column must lay out at its OWN width, not stretch to 600")
    }

    /// The clamp only ever narrows: a table whose authored width is WIDER than the column still fills
    /// the column exactly (unchanged from before this concept existed) — `maxWidth` never grows a
    /// table past what the reading column actually has.
    func testPagedTableNeverGrowsPastTheColumnEvenWithAWiderAuthoredWidth() {
        let theme = RenderTheme.current(size: 16)
        let ncol = 3
        let row = (0..<ncol).map { TableBlockBuilder.CellContent(content: NSAttributedString(string: "c\($0)")) }
        let attr = TableBlockBuilder.build(rows: [row, row], headerRows: 0, theme: theme,
                                           columnWidths: Array(repeating: 100, count: ncol),
                                           paged: true, maxWidth: 900, width: 600)
        let used = laidOutWidth(of: attr, containerWidth: 600 + 200)
        XCTAssertEqual(used, 600, accuracy: 0.01, "maxWidth must never stretch a table PAST the reading column")
    }

    /// A non-paged table (`maxWidth` never even passed) is untouched — the exact call shape every
    /// existing markdown/office call site used before Job 2 existed.
    func testNonPagedTableIgnoresMaxWidthEntirely() {
        let target: CGFloat = 600
        let w = laidOutWidth(columns: 5, target: target)   // uses the file's own helper — no maxWidth param at all
        XCTAssertEqual(w, target, accuracy: 0.01)
    }

    /// FORMULA PARITY (invariant 48) for the PAGED clamp specifically: `resizeTables` is asked for the
    /// FULL, unclamped reading column (900) — exactly what a real reflow does — and the table must
    /// still land on its own 300pt authored width, not snap out to fill the column. This is the
    /// concrete risk `GridTextTable.maxWidth` exists to remove: without it, `edges(forWidth:)` would
    /// solve at whatever `resizeTables` passes, re-stretching a paged table on the very next reflow.
    func testResizeTablesRespectsThePagedTablesOwnMaxWidthOnAFullColumnReflow() {
        let theme = RenderTheme.current(size: 16)
        let ncol = 3
        let row = (0..<ncol).map { TableBlockBuilder.CellContent(content: NSAttributedString(string: "c\($0)")) }
        let attr = TableBlockBuilder.build(rows: [row, row], headerRows: 0, theme: theme,
                                           columnWidths: Array(repeating: 100, count: ncol),
                                           paged: true, maxWidth: 300, width: 600)
        let storage = NSTextStorage(attributedString: attr)
        // A real reflow passes the FULL reading column (900), not the table's own clamped width.
        TableBlockBuilder.resizeTables(in: storage, toWidth: 900)
        let used = laidOutWidth(of: NSAttributedString(attributedString: storage), containerWidth: 900 + 200)
        XCTAssertEqual(used, 300, accuracy: 0.01,
                       "a full-column reflow must not re-stretch a paged table past its own authored width")
    }

    /// FORMULA PARITY, the OTHER half: build and resizeTables must derive the SAME cells-moved answer
    /// for a PAGED table too, not just the plain shapes the pre-existing suite already covers — a
    /// render immediately followed by a resize to the SAME (already-clamped) width must move NOTHING.
    func testResizeTablesMovesNothingForAPagedTableAlreadyAtItsOwnWidth() {
        let theme = RenderTheme.current(size: 16)
        var cell = TableBlockBuilder.CellContent(content: NSAttributedString(string: "x"))
        cell.edgePadding = EdgePadding(top: 0, left: 5, bottom: 0, right: 5)
        let rows = [[cell], [cell]]
        let attr = TableBlockBuilder.build(rows: rows, headerRows: 0, theme: theme,
                                           paged: true, maxWidth: 300, width: 600)
        let storage = NSTextStorage(attributedString: attr)
        func widths() -> [CGFloat] {
            var out: [CGFloat] = []
            storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
                if let ps = v as? NSParagraphStyle, let b = ps.textBlocks.first as? NSTextTableBlock { out.append(b.contentWidth) }
            }
            return out
        }
        let before = widths()
        // A resize to the FULL column (900) — the paged clamp must reproduce the identical 300pt
        // solve `build` already did, so nothing here should be treated as "moved".
        TableBlockBuilder.resizeTables(in: storage, toWidth: 900)
        let after = widths()
        let moved = zip(before, after).filter { abs($0 - $1) > 0.5 }.count
        print("  [paged] cells the resize pass still moves after a render: \(moved) of \(before.count)")
        XCTAssertEqual(moved, 0, "formula parity: build and resizeTables must agree on a paged table's clamped width")
    }

}
