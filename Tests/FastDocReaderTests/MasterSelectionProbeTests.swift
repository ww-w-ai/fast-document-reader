import XCTest
import AppKit
import Darwin
import CFastdocEngine
@testable import FastDocReader

/// S5C3-06 — the probe `.ww-w-ai/cowork-sprint/plans/s5c3.md` ("What the probe reports, and who
/// decides on it") asks for, and only that: measurement, not adjudication. It answers the sprint's
/// real question — is the engine's ABSOLUTE per-draw-pass and per-print cost small enough that a
/// reader cannot feel it — with the five numbers the plan names, over the plan's own two named
/// regions (BASELINE = the whole draw pass `ReaderTextView.drawBackground(in:)` pays today;
/// SELECTION = only the arithmetic `MasterPagePainter.applicablePage` does). The owner rules on the
/// numbers; this file only produces them.
///
/// Env-gated in the house style of the 57 skips CLAUDE.md names — `FMD_MASTER_SELECTION_FILE` must
/// point at the plan's own fixture, `Vendor/rhwp-src/samples/2025 행정업무운영 편람(최종).hwp` (NOT
/// its `.hwpx` twin — the plan states why, and this probe does not re-derive it). `n` for numbers
/// 1/2 defaults to 30 (`FMD_MASTER_SELECTION_N`), matching the plan's own requirement; the plan's own
/// escape valve — "if it proves prohibitive, reduce n and say so" — is the only reason this is an
/// env var and not a literal 30.
///
/// **Numbers 3/4 only exist in a build linked against the Rust engine** (`FMD_RUST_ENGINE=1`) —
/// `fastdoc_office_master_selection` (S5C3-01/03, the real port) is C ABI this test calls
/// directly, the same way `RustEngineOfficeDocument.swift` calls every other export on that page,
/// and that symbol is simply absent from a flag-OFF build (`Package.swift` only adds the
/// `FastdocEngine` binary target when the flag is set). A flag-OFF run of this file still reports
/// numbers 1/2/5-baseline and says plainly that 3/4/5-with-engine were not built, rather than
/// skipping the whole probe. These are the DEFINITIVE numbers 3/4 — S5C3-06a's stand-in lower
/// bound is retired; the stand-in export no longer exists.
final class MasterSelectionProbeTests: XCTestCase {
    override func setUp() { super.setUp(); FontSizeStore.startingSize = FontSizeStore.defaultSize }
    override func tearDown() { FontSizeStore.startingSize = FontSizeStore.defaultSize; super.tearDown() }

    private func ms(_ start: Date) -> Double { Date().timeIntervalSince(start) * 1000 }
    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    private func f(_ x: Double) -> String { String(format: "%.3f", x) }
    private func loadAvg() -> Double { var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); return l[0] }
    private func perf(_ line: String) { print("PERF " + line) }

    private func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }

    /// One line, reported for numbers 1-4: `n`, median, max — over `values` — plus the divisor
    /// (draw passes walked) and the 1-minute load average, exactly as the plan's own "Each of 1-4"
    /// paragraph requires.
    private func reportPopulation(_ label: String, values: [Double], divisor: Int, note: String = "") {
        perf("stage=master_selection metric=\(label) n=\(values.count) median=\(f(median(values))) "
             + "max=\(f(values.max() ?? 0)) divisor=\(divisor) loadavg1m=\(f(loadAvg()))"
             + (note.isEmpty ? "" : " note=\"\(note)\""))
    }

    // MARK: - Opening the fixture once, laid out and paginated, shared by every measurement below

    func testMasterSelectionCost() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_MASTER_SELECTION_FILE"] else {
            throw XCTSkip("set FMD_MASTER_SELECTION_FILE to the plan's fixture "
                          + "(Vendor/rhwp-src/samples/2025 행정업무운영 편람(최종).hwp) to run S5C3-06")
        }
        let requestedN = Int(ProcessInfo.processInfo.environment["FMD_MASTER_SELECTION_N"] ?? "") ?? 30
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)

        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: data, ofType: "public.data")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 900), display: false)
        spin(2)

        guard let lm = wc.textView.layoutManager, let storage = wc.textStorageRef else {
            return XCTFail("no layout manager/text storage after first paint")
        }
        wc.precomputeLayout()
        var laidOut = storage.length == 0
        for _ in 0..<24000 where !laidOut {
            spin(0.005)
            if lm.firstUnlaidCharacterIndex() >= storage.length { laidOut = true }
        }
        guard laidOut else {
            return XCTFail("the fixture never finished laying out — \(lm.firstUnlaidCharacterIndex()) of "
                           + "\(storage.length) chars")
        }
        wc.applyTrailingFooterBand()
        let sheets = wc.printSheets
        XCTAssertGreaterThan(sheets.count, 1, "precondition: the plan's fixture is a paged, "
                             + "434-page document — a non-paged open means the wrong file was passed")
        perf("stage=master_selection_doc file=\(url.lastPathComponent) pages=\(sheets.count) "
             + "chars=\(storage.length) n=\(requestedN)")

        // MARK: Numbers 1/2 — the BASELINE region: the WHOLE draw pass, today, no engine anywhere.
        // `requestedN` full downward walks of the SAME laid-out document — reopening per walk would
        // charge every sample for parse+layout the plan's own region deliberately excludes.
        guard let scrollView = wc.textView.enclosingScrollView else {
            return XCTFail("no enclosing scroll view for the read-through walk")
        }
        let clip = scrollView.contentView
        let viewportHeight = max(1, clip.bounds.height)
        let totalHeight = wc.textView.bounds.height
        guard let frameRep = wc.textView.bitmapImageRepForCachingDisplay(in: wc.textView.visibleRect) else {
            return XCTFail("could not allocate a bitmap to draw the read-through into")
        }

        var walkAggregatesMs: [Double] = []
        var walkWorstMs: [Double] = []
        var stepsPerWalk = 0
        let walkStart = Date()
        for walk in 0..<requestedN {
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: 0))
            scrollView.reflectScrolledClipView(clip)
            var y: CGFloat = 0
            var stepTimes: [Double] = []
            var reachedBottom = totalHeight <= viewportHeight
            let stepCap = 2000
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
            guard !stepTimes.isEmpty, reachedBottom else {
                return XCTFail("walk \(walk) did not reach the bottom within \(stepCap) steps — "
                               + "viewport \(viewportHeight)pt, document \(totalHeight)pt")
            }
            walkAggregatesMs.append(stepTimes.reduce(0, +))
            walkWorstMs.append(stepTimes.max() ?? 0)
            stepsPerWalk = stepTimes.count
        }
        let wallSeconds = Date().timeIntervalSince(walkStart)
        if wallSeconds > 3600 {
            perf("stage=master_selection_budget walkSeconds=\(f(wallSeconds)) "
                 + "note=\"exceeded the plan's 1-hour budget with n=\(requestedN) — reported below anyway\"")
        }
        reportPopulation("baseline_aggregate", values: walkAggregatesMs, divisor: stepsPerWalk,
                         note: "number 1 — total ms per whole 434-page walk; per-draw-pass = value/divisor")
        reportPopulation("baseline_worst", values: walkWorstMs, divisor: stepsPerWalk,
                         note: "number 2 — worst single draw pass within a walk")

        // MARK: Numbers 3/4 — the SELECTION region: the engine's ADDED cost only, from the stand-in
        // (S5C3-06a). Not measured in the live draw path (there is none yet, pre-S5C3-04) — this is a
        // probe-local replica of the marshal-in/guard/marshal-out sequence the real export will pay,
        // built from THIS document's own master pages, veto set and per-visible-page section answers.
        if let content = wc.masterPageContent, !content.pages.isEmpty {
            measureSelectionAddedCost(content: content, sheets: sheets, sectionOfPage: wc.sectionOfPage,
                                      n: max(requestedN, 30))
        } else {
            perf("stage=master_selection metric=selection_added note=\"this document's own master "
                 + "page content was empty at probe time (the document's masterPage option off, "
                 + "or the fixture declares no 바탕쪽) — numbers 3/4 not measured\"")
        }

        // MARK: Number 5 — total `--pdf` time, today, and (disclosed) the projected figure with the
        // engine. `--pdf` never calls the engine's selection today (S5C3-04 is not done), so "with
        // the engine" cannot be a live measurement yet — it is baseline + the SELECTION region's own
        // added-aggregate-per-call (numbers 3/above) times the pages this print job actually printed,
        // stated as a projection, never as something this probe watched happen.
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-s5c3-06-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let outURL = tempDir.appendingPathComponent("out.pdf")
        let tPdf = Date()
        let exitCode = HeadlessPDF.run([url.path, "-o", outURL.path])
        let pdfMs = ms(tPdf)
        XCTAssertEqual(exitCode, 0, "--pdf must succeed on the plan's own fixture")
        var printedPages = 0
        if let pdfData = try? Data(contentsOf: outURL),
           let provider = CGDataProvider(data: pdfData as CFData),
           let pdfDoc = CGPDFDocument(provider) {
            printedPages = pdfDoc.numberOfPages
        }
        perf("stage=master_selection metric=pdf_total_today n=1 median=\(f(pdfMs)) max=\(f(pdfMs)) "
             + "pages=\(printedPages) note=\"number 5 — no divisor, a whole-job total\"")
        if let addedPerCall = Self.lastSelectionAggregateMedianMs, printedPages > 0 {
            let projected = pdfMs + addedPerCall
            perf("stage=master_selection metric=pdf_total_with_engine_PROJECTED n=1 "
                 + "median=\(f(projected)) max=\(f(projected)) pages=\(printedPages) "
                 + "note=\"PROJECTION, not a live measurement — --pdf does not call the engine's "
                 + "selection before S5C3-04; = today's pdf_total + one stand-in call's added "
                 + "aggregate (median), since S5C3-03 batches every visible page into one call per "
                 + "draw/print pass\"")
        }
    }

    /// Carries number 3's median out of `measureSelectionAddedCost` to the `--pdf` projection
    /// below — a stored static rather than a return value because `testMasterSelectionCost` is one
    /// long XCTest method and this keeps the print-projection step reading as a continuation of the
    /// same measurement rather than a second, disconnected one.
    private static var lastSelectionAggregateMedianMs: Double?

    /// Numbers 3/4: calls `fastdoc_office_master_selection` `n` times over THIS document's own
    /// payload — every visible page's `(pageIndex, section?)`, this document's own master-page
    /// templates and its own section-veto set — and reports the per-call cost.
    ///
    /// One call answers every visible page in the walk (S5C3-03's own batching contract: "ONE call
    /// per draw pass"), so a call's own timing IS already a per-draw-pass figure — there is no
    /// aggregate to divide by a page count the way the baseline's scroll steps are. `divisor=1`
    /// records that rather than leaving it unstated. Numbers 3 (aggregate) and 4 (worst single) are
    /// therefore the SAME population here — one call, one draw pass — reported under both labels
    /// because a batched call has no "several draw passes inside one aggregate" to tell them apart,
    /// unlike the baseline's scroll-step aggregate.
    private func measureSelectionAddedCost(
        content: MasterPageContent, sheets: [CGRect], sectionOfPage: (Int) -> Int?, n: Int
    ) {
        func tag(_ a: HeaderFooterApplicability) -> Int32 {
            switch a {
            case .defaultPages: return 0
            case .firstPage: return 1
            case .evenPages: return 2
            }
        }
        let templates = content.pages.map {
            FastdocMasterTemplateDesc(section: Int64($0.section), applies_to: tag($0.appliesTo))
        }
        let vetoed = content.sectionsHidingMasterPage.map { Int64($0) }
        let pages: [FastdocMasterPageQuery] = (0..<sheets.count).map { index in
            let section = sectionOfPage(index)
            return FastdocMasterPageQuery(page_index: Int64(index), has_section: section != nil,
                                          section: Int64(section ?? 0))
        }
        var out = [Int64](repeating: -2, count: pages.count)

        var callTimesMs: [Double] = []
        callTimesMs.reserveCapacity(n)
        for callIndex in 0..<n {
            let t0 = Date()
            let ok = templates.withUnsafeBufferPointer { templatesBuf in
                vetoed.withUnsafeBufferPointer { vetoedBuf in
                    pages.withUnsafeBufferPointer { pagesBuf in
                        out.withUnsafeMutableBufferPointer { outBuf in
                            fastdoc_office_master_selection(
                                templatesBuf.baseAddress, templatesBuf.count,
                                vetoedBuf.baseAddress, vetoedBuf.count,
                                pagesBuf.baseAddress, pagesBuf.count,
                                outBuf.baseAddress, outBuf.count)
                        }
                    }
                }
            }
            let elapsed = ms(t0)
            guard ok else {
                XCTFail("fastdoc_office_master_selection returned false")
                return
            }
            // ASSERT THE OUTPUT, not just `ok` — a measurement whose instrument cannot fail is
            // not a measurement. One index per queried page (never the -2 sentinel this loop
            // pre-fills with, which would mean the export left an entry untouched), and on the
            // plan's own fixture (13 declared templates) at least one page must resolve to a
            // real template — a build that always answered "-1, no template" would still read
            // `ok == true` and pass a check that only inspected the return value.
            if callIndex == 0 {
                XCTAssertEqual(out.count, pages.count,
                               "one output index per queried page")
                XCTAssertFalse(out.contains(-2),
                               "every output entry must be written — -2 means the export left one untouched")
                XCTAssertTrue(out.contains(where: { $0 >= 0 }),
                              "the fixture declares 13 master-page templates — at least one of "
                              + "\(pages.count) visible pages must resolve to a real template, or "
                              + "the export is answering \"no template\" for everything")
            }
            callTimesMs.append(elapsed)
        }
        Self.lastSelectionAggregateMedianMs = median(callTimesMs)
        reportPopulation("selection_added_aggregate", values: callTimesMs, divisor: 1,
                         note: "number 3 — one call already answers one whole draw pass "
                               + "(\(pages.count) visible pages, S5C3-03's batching contract), so "
                               + "divisor=1 rather than a page count")
        reportPopulation("selection_added_worst", values: callTimesMs, divisor: 1,
                         note: "number 4 — same population as number 3 for a batched export; "
                               + "measured in a probe-local replica of the marshal-in/guard/"
                               + "marshal-out sequence, NOT inside the shipped draw path (no engine "
                               + "call exists there before S5C3-04)")
    }
}
