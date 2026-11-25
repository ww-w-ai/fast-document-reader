import XCTest
import AppKit
@testable import FastDocReader

/// S2 of `docs/plans/pagination-to-engine.md`: the engine's page plan run in shadow beside TextKit.
///
/// `FMD_PLAN_SHADOW=<document>[:<document>...]` lays each document out exactly as `--pdf` does,
/// hands the finished layout's measurements to `fastdoc_office_page_plan_json`, and reports where the
/// plan and TextKit disagree on the page of a block or a line. `FMD_PLAN_SHADOW_OUT=<path>` also
/// writes the report. Nothing in the reader calls this, so it costs a document nothing at open
/// (invariants 55/65/101/113); cutting macOS over to the plan is S6.
///
/// The document is laid out as `--pdf` prints it (`PagePlanShadow.layOutForPrint`), so the page
/// count the probe reports is the count `--pdf` gives. The report also compares, page by page, the
/// sheet itself (section, running head and foot, master page, printed number), the footnote bands and
/// which page cites which note, and — for a columned document — every line of every columned run
/// against the reader's column map. `FMD_PLAN_SHADOW_COLUMNS=1` lists each such line and the first
/// differences in the stack the columns are dealt from. Dumps for diagnosis, each into the named
/// directory: `FMD_PLAN_SHADOW_BLOCKS` (one row per block, TextKit against the plan),
/// `FMD_PLAN_SHADOW_STATE` (the reader's settle records), `FMD_PLAN_SHADOW_TABLES`; and into the report:
/// `FMD_PLAN_SHADOW_CELLS=<block>,..` (cell lines against the plan, with both sides' pulls),
/// `FMD_PLAN_SHADOW_ROWS=<block>,..` (row extents as measured), `FMD_PLAN_SHADOW_PLACEMENTS=<block>,..`.
///
/// More dumps: `FMD_PLAN_SHADOW_CELLBOX=<block>,..` (every cell's box and lines in TextKit, and those
/// of the tables nested one level down), `FMD_PLAN_SHADOW_SPIN=<seconds>` (run the main loop after a
/// document closes). Each document's report starts with "before print", where the reader's own
/// asynchronous settle stood when the probe took over.
///
/// A document's paper layout no longer depends on that: the 편람 prints 391 sheets whether it follows
/// `1790387_prep_final_report.hwpx` in the process or not (`makePrintOperation` finishes the screen
/// settle itself, because the storage keeps what a settle did to it).
final class PagePlanShadowProbeTests: XCTestCase {

    /// The Swift side of the FFI: a plan comes back in the envelope, keyed by the caller's keys.
    func testThePlanCrossesTheFFIFromSwift() throws {
        let input = """
        {"planVersion":1,"contentHeight":100,"splitTables":true,"noteBands":[],
         "blocks":[{"key":501,"kind":"text","lines":[60,60]},{"key":502,"kind":"atomic","height":30}]}
        """
        let reply = try XCTUnwrap(PagePlanShadow.plan(json: Data(input.utf8)))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        let plan = try XCTUnwrap(envelope["ok"] as? [String: Any])
        XCTAssertEqual(plan["pageCount"] as? Int, 2)
        let pages = try XCTUnwrap(plan["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.first?["firstKey"] as? Int, 501)
        // The second line of block 501 opens page 1, so 501 is also the first block on it.
        XCTAssertEqual(pages.last?["firstKey"] as? Int, 501)
        let placements = try XCTUnwrap(plan["placements"] as? [[String: Any]])
        XCTAssertEqual(placements.first?["key"] as? Int, 502)
        XCTAssertEqual(placements.first?["page"] as? Int, 1)
    }

    /// S6b2-0b: the answer names every located line by character location, the grid it is on, and how
    /// many leading pages a longer document cannot change.
    func testTargetsAndFinalPagesCrossTheFFIFromSwift() throws {
        let input = """
        {"planVersion":1,"contentHeight":100,"band":20,"truncated":true,
         "blocks":[{"key":1,"kind":"text","lines":[60,60],"lineLocs":[0,12]},
                    {"key":2,"kind":"text","lines":[60],"lineLocs":[30]}]}
        """
        let reply = try XCTUnwrap(PagePlanShadow.plan(json: Data(input.utf8)))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        let plan = try XCTUnwrap(envelope["ok"] as? [String: Any])
        let targets = try XCTUnwrap(plan["targets"] as? [[String: Any]])
        XCTAssertEqual(targets.map { $0["loc"] as? Int }, [0, 12, 30])
        XCTAssertEqual(targets.map { $0["page"] as? Int }, [0, 1, 2])
        XCTAssertEqual(plan["pitchUsed"] as? Double, 120)
        XCTAssertEqual(plan["finalPages"] as? Int, 2, "the page the last block starts on is still open")
        XCTAssertEqual((plan["flowedTables"] as? [Int]) ?? [-1], [])
    }

    /// S6b2-0e: the state the painters read — opened boundaries and where their gaps are — comes back
    /// from the plan, additively, on the print grid.
    func testPainterStateCrossesTheFFIFromSwift() throws {
        let input = """
        {"planVersion":1,"contentHeight":100,"band":20,
         "blocks":[{"key":1,"kind":"text","lines":[40,40,40,40],"lineLocs":[0,10,20,30]}]}
        """
        let reply = try XCTUnwrap(PagePlanShadow.plan(json: Data(input.utf8)))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        let plan = try XCTUnwrap(envelope["ok"] as? [String: Any])
        XCTAssertEqual((plan["openedBoundaries"] as? [Int]) ?? [], [0])
        let bands = try XCTUnwrap(plan["openedBands"] as? [[String: Any]])
        XCTAssertEqual(bands.count, 1)
        XCTAssertEqual(bands[0]["page"] as? Int, 0)
        XCTAssertEqual(bands[0]["top"] as? Double, 80)
        XCTAssertEqual(bands[0]["height"] as? Double, 40)
        XCTAssertEqual((plan["straddledBoundaries"] as? [Int]) ?? [-1], [])
        XCTAssertEqual((plan["columnOpenedBoundaries"] as? [Int]) ?? [-1], [])
    }

    func testAnUnsupportedPlanVersionIsAnErrorEnvelope() throws {
        let reply = try XCTUnwrap(PagePlanShadow.plan(json: Data(#"{"planVersion":9,"contentHeight":100,"blocks":[]}"#.utf8)))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        XCTAssertNil(envelope["ok"])
        XCTAssertEqual((envelope["error"] as? [String: Any])?["kind"] as? String, "invalidArgument")
    }

    func testShadowAgainstRealDocuments() throws {
        let env = ProcessInfo.processInfo.environment
        guard let list = env["FMD_PLAN_SHADOW"] else { throw XCTSkip("set FMD_PLAN_SHADOW=<document>[:<document>...]") }
        var report: [String] = []
        for (ordinal, path) in list.split(separator: ":").map(String.init).enumerated() {
            let url = URL(fileURLWithPath: path)
            let doc = MarkdownDocument()
            doc.readingSize = FontSizeStore.defaultSize
            doc.fileURL = url
            try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
            doc.makeWindowControllers()
            let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
            wc.window?.setFrame(NSRect(x: 0, y: 0, width: 820, height: 640), display: false)
            let waited = Date()
            let settled = HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
            report.append("SHADOW settled: \(settled)")
            // Where the reader's own async settle stood when the probe took over (a leak bisect).
            let d0 = wc.pageBandDelegate
            report.append(String(format: "SHADOW before print: waited %.2fs, generation %d, frame %.1f, pushed %d, oversized %d, pulled %d, bands %d, deferred tables %d, progressive pending %@",
                                 Date().timeIntervalSince(waited), doc.renderGeneration, Double(wc.textView.frame.height),
                                 d0.pushedTables.count, d0.oversizedPieces.count, d0.pullToNextPage.count, d0.openedBands.count,
                                 doc.deferredTables.count, doc.isProgressiveRenderPending ? "yes" : "no"))
            wc.textView.layoutManager?.ensureLayout(for: wc.textView.textContainer!)
            PagePlanShadow.layOutForPrint(wc)
            let started = Date()
            // FMD_PLAN_SHADOW_NATURAL=1: the plan is asked from a layout nobody paginated (S6b2-0a,
            // `PlanObservation`), and is still compared with the pages TextKit's reader printed.
            let natural = env["FMD_PLAN_SHADOW_NATURAL"] == "1"
            // FMD_PLAN_APPLY=1 (S6b2-0c, needs the natural observation): every line the reader printed
            // is read back BEFORE the shadow lays the document out again, then the plan is applied on a
            // layout manager of its own and compared with it.
            let apply = natural && env["FMD_PLAN_APPLY"] == "1"
            var readerLines: [Int: PlanApplyProbe.Line] = [:]
            let readerPages = wc.printPageCount
            let readerColumnRuns = wc.columnRunRanges()
            if natural, let lm = wc.textView.layoutManager, let tc = wc.textView.textContainer, let storage = wc.textView.textStorage {
                readerLines = PlanApplyProbe.lines(of: lm, tc, length: storage.length)
            }
            report.append("SHADOW observation: \(natural ? "natural" : "paginated")")
            let result = PagePlanShadow.run(controller: wc, natural: natural, drawn: readerLines.mapValues(\.y))
            let elapsed = Date().timeIntervalSince(started)
            if apply, let answer = result.planAnswer {
                report.append("APPLY \(url.lastPathComponent)")
                report.append(contentsOf: PlanApplyProbe.run(
                    wc: wc, plan: answer, reader: readerLines, readerPages: readerPages, leading: result.gridLeading,
                    pageContentHeight: result.gridPageContentHeight, band: result.gridBand, columnRuns: readerColumnRuns,
                    bodyWidth: result.gridBodyWidth, insetX: result.columnLineInset))
            }
            report.append("SHADOW \(url.lastPathComponent)")
            if let reason = result.skippedReason { report.append("SHADOW   skipped: \(reason)"); report.append("SHADOW print pages: \(result.macPages)") }
            else { report.append(result.text); report.append(String(format: "SHADOW run %.2fs", elapsed)) }
            // FMD_PLAN_SHADOW_TABLES=<directory>: one "<ordinal>\t<height>\t<crossed>" line per table,
            // for the table-by-table comparison with the host that has no TextKit (S3).
            if let directory = env["FMD_PLAN_SHADOW_TABLES"] {
                let lines = result.tableHeights.enumerated().map { "\($0.offset)\t\(String(format: "%.2f", Double($0.element.height)))\t\($0.element.crossed ? 1 : 0)" }
                try? (lines.joined(separator: "\n") + "\n").write(
                    toFile: directory + "/" + (ordinal > 0 ? "\(ordinal)-" : "") + url.lastPathComponent + ".tables.tsv", atomically: true, encoding: .utf8)
            }
            // FMD_PLAN_SHADOW_BLOCKS=<directory>: one row per block, TextKit against the plan, so two
            // runs of one document (alone, after another) can be diffed block by block.
            if let directory = env["FMD_PLAN_SHADOW_BLOCKS"] {
                try? (result.blockRows.joined(separator: "\n") + "\n").write(
                    toFile: directory + "/" + (ordinal > 0 ? "\(ordinal)-" : "") + url.lastPathComponent + ".blocks.tsv", atomically: true, encoding: .utf8)
            }
            // FMD_PLAN_SHADOW_STATE=<directory>: what the reader's settle recorded, sorted, so two runs
            // of one document can be diffed.
            if let directory = env["FMD_PLAN_SHADOW_STATE"] {
                let d = wc.pageBandDelegate
                var lines: [String] = []
                lines += d.pushedTables.keys.sorted().map { "pushed \($0) h \(d.pushedTables[$0]!.height) inset \(d.pushedTables[$0]!.topInset)" }
                lines += d.oversizedPieces.keys.sorted().map { "oversized \($0)-\(d.oversizedPieces[$0]!)" }
                lines += d.pullToNextPage.sorted().map { "pull \($0)" }
                lines += d.openedBands.keys.sorted().map { "band \($0) top \(d.openedBands[$0]!.top) h \(d.openedBands[$0]!.height)" }
                lines += d.documentPageBreaks.sorted().map { "break \($0)" }
                try? (lines.joined(separator: "\n") + "\n").write(
                    toFile: directory + "/" + (ordinal > 0 ? "\(ordinal)-" : "") + url.lastPathComponent + ".state.txt", atomically: true, encoding: .utf8)
            }
            doc.close()
            // FMD_PLAN_SHADOW_SPIN=<seconds>: let whatever the closed document left on the main queue
            // run before the next one opens (a leak bisect).
            if let spin = env["FMD_PLAN_SHADOW_SPIN"].flatMap(Double.init) {
                RunLoop.main.run(until: Date().addingTimeInterval(spin))
            }
        }
        report.forEach { print($0) }
        if let out = env["FMD_PLAN_SHADOW_OUT"] {
            try? (report.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}
