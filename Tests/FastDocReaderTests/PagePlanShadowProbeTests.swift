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
/// Known, not fixed: a document laid out for paper AFTER `1790387_prep_final_report.hwpx` in the same
/// process settles to a different table-line trajectory on TextKit's side (the 편람 prints 395 pages
/// where it prints 391 alone or after any other baseline document); the plan's input is identical in
/// both orders. Run the 편람 first or alone.
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
            let settled = HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
            report.append("SHADOW settled: \(settled)")
            wc.textView.layoutManager?.ensureLayout(for: wc.textView.textContainer!)
            PagePlanShadow.layOutForPrint(wc)
            let started = Date()
            let result = PagePlanShadow.run(controller: wc)
            let elapsed = Date().timeIntervalSince(started)
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
        }
        report.forEach { print($0) }
        if let out = env["FMD_PLAN_SHADOW_OUT"] {
            try? (report.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}
