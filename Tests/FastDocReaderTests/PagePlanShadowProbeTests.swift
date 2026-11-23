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
        for path in list.split(separator: ":").map(String.init) {
            let url = URL(fileURLWithPath: path)
            let doc = MarkdownDocument()
            doc.readingSize = FontSizeStore.defaultSize
            doc.fileURL = url
            try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
            doc.makeWindowControllers()
            let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
            wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1098, height: 640), display: false)
            let settled = HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
            report.append("SHADOW settled: \(settled)")
            wc.textView.layoutManager?.ensureLayout(for: wc.textView.textContainer!)
            let started = Date()
            let result = PagePlanShadow.run(controller: wc)
            let elapsed = Date().timeIntervalSince(started)
            report.append("SHADOW \(url.lastPathComponent)")
            if let reason = result.skippedReason { report.append("SHADOW   skipped: \(reason)") }
            else { report.append(result.text); report.append(String(format: "SHADOW run %.2fs", elapsed)) }
            // FMD_PLAN_SHADOW_TABLES=<directory>: one "<ordinal>\t<height>\t<crossed>" line per table,
            // for the table-by-table comparison with the host that has no TextKit (S3).
            if let directory = env["FMD_PLAN_SHADOW_TABLES"] {
                let lines = result.tableHeights.enumerated().map { "\($0.offset)\t\(String(format: "%.2f", Double($0.element.height)))\t\($0.element.crossed ? 1 : 0)" }
                try? (lines.joined(separator: "\n") + "\n").write(
                    toFile: directory + "/" + url.lastPathComponent + ".tables.tsv", atomically: true, encoding: .utf8)
            }
            doc.close()
        }
        report.forEach { print($0) }
        if let out = env["FMD_PLAN_SHADOW_OUT"] {
            try? (report.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}
