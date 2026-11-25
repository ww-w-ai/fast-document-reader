import XCTest
import AppKit
@testable import FastDocReader

/// The page plan across the FFI, and the plan-vs-applied parity check on real documents.
///
/// `FMD_PLAN_PARITY=<document>[:<document>...]` lays each document out exactly as `--pdf` does (the
/// same `makePrintOperation`: print layout, one plan generation, trailing band) and reads the layout
/// back against the plan that placed it (`PlanAppliedParity`): every target line stands where the
/// plan said, the layout fills the sheets the plan counted, and a second layout of the same text
/// changes nothing. Run each document ALONE in its own process, and set `FMD_PLAN_PARITY_OUT=<path>`
/// so the verdict is not lost to stdout interleaving between XCTest and the swift-testing runner.
final class PlanParityProbeTests: XCTestCase {

    private func plan(_ input: String) throws -> [String: Any] {
        let reply = try XCTUnwrap(PlanPagination.envelope(json: Data(input.utf8)))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        return try XCTUnwrap(envelope["ok"] as? [String: Any])
    }

    /// The Swift side of the FFI: a plan comes back in the envelope, keyed by the caller's keys.
    func testThePlanCrossesTheFFIFromSwift() throws {
        let plan = try plan("""
        {"planVersion":1,"contentHeight":100,"splitTables":true,"noteBands":[],
         "blocks":[{"key":501,"kind":"text","lines":[60,60]},{"key":502,"kind":"atomic","height":30}]}
        """)
        XCTAssertEqual(plan["pageCount"] as? Int, 2)
        let pages = try XCTUnwrap(plan["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.first?["firstKey"] as? Int, 501)
        // The second line of block 501 opens page 1, so 501 is also the first block on it.
        XCTAssertEqual(pages.last?["firstKey"] as? Int, 501)
        let placements = try XCTUnwrap(plan["placements"] as? [[String: Any]])
        XCTAssertEqual(placements.first?["key"] as? Int, 502)
        XCTAssertEqual(placements.first?["page"] as? Int, 1)
    }

    /// The answer names every located line by character location, the grid it is on, and how many
    /// leading pages a longer document cannot change.
    func testTargetsAndFinalPagesCrossTheFFIFromSwift() throws {
        let plan = try plan("""
        {"planVersion":1,"contentHeight":100,"band":20,"truncated":true,
         "blocks":[{"key":1,"kind":"text","lines":[60,60],"lineLocs":[0,12]},
                    {"key":2,"kind":"text","lines":[60],"lineLocs":[30]}]}
        """)
        let targets = try XCTUnwrap(plan["targets"] as? [[String: Any]])
        XCTAssertEqual(targets.map { $0["loc"] as? Int }, [0, 12, 30])
        XCTAssertEqual(targets.map { $0["page"] as? Int }, [0, 1, 2])
        XCTAssertEqual(plan["pitchUsed"] as? Double, 120)
        XCTAssertEqual(plan["finalPages"] as? Int, 2, "the page the last block starts on is still open")
        XCTAssertEqual((plan["flowedTables"] as? [Int]) ?? [-1], [])
    }

    /// The state the painters read — opened boundaries and where their gaps are — comes back from the
    /// plan, on the print grid.
    func testPainterStateCrossesTheFFIFromSwift() throws {
        let plan = try plan("""
        {"planVersion":1,"contentHeight":100,"band":20,
         "blocks":[{"key":1,"kind":"text","lines":[40,40,40,40],"lineLocs":[0,10,20,30]}]}
        """)
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
        let reply = try XCTUnwrap(PlanPagination.envelope(json: Data(#"{"planVersion":9,"contentHeight":100,"blocks":[]}"#.utf8)))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        XCTAssertNil(envelope["ok"])
        XCTAssertEqual((envelope["error"] as? [String: Any])?["kind"] as? String, "invalidArgument")
    }

    /// First paint plans only the head of the text, and what it places agrees with the full plan the
    /// walk takes afterwards: the viewport must not jump when the full answer lands.
    func testTheFirstPaintPlanAgreesWithTheFullPlanOnItsPages() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/fixtures/office/bus-headings.docx")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("docs/ is local-only") }
        PageViewOptionsStore.startingOptions = PageViewOptions(outline: true)
        defer { PageViewOptionsStore.reset() }
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        wc.paginateNow()
        let full = wc.pageBandDelegate.targets
        let fullPages = wc.printPageCount
        XCTAssertGreaterThan(fullPages, 4, "the fixture must be longer than the head the first paint plans")

        wc.pageBandDelegate.resetPlan()
        let before = wc.prefixPlanCount
        wc.paginateForFirstPaint()
        XCTAssertEqual(wc.prefixPlanCount, before + 1, "the first paint makes exactly one plan call")
        let head = wc.pageBandDelegate.targets
        XCTAssertFalse(head.isEmpty)
        XCTAssertLessThan(head.count, full.count, "the head plan places fewer lines than the whole document has")
        for (loc, target) in head {
            let reference = try XCTUnwrap(full[loc], "line \(loc) has a target in the head plan and none in the full one")
            XCTAssertEqual(target.y, reference.y, accuracy: 0.01, "line \(loc) moves when the full plan lands")
        }
    }

    /// Two parsed JSON values as the engine reads them: numbers by the `Double` their digits round to
    /// (Foundation parses a long decimal as an `NSDecimalNumber`, which compares by digits), booleans apart
    /// from numbers.
    static func sameAsTheEngineReadsIt(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case let (x as [String: Any], y as [String: Any]):
            return x.count == y.count && x.allSatisfy { key, value in y[key].map { sameAsTheEngineReadsIt(value, $0) } ?? false }
        case let (x as [Any], y as [Any]):
            return x.count == y.count && zip(x, y).allSatisfy { sameAsTheEngineReadsIt($0, $1) }
        case let (x as NSNumber, y as NSNumber):
            let boolean = CFBooleanGetTypeID()
            // From the digits: `NSDecimalNumber.doubleValue` does not round correctly, the engine does.
            return (CFGetTypeID(x) == boolean) == (CFGetTypeID(y) == boolean) && Double(x.stringValue) == Double(y.stringValue)
        case let (x as String, y as String): return x == y
        default: return a is NSNull && b is NSNull
        }
    }

    /// Between first paint and the full plan, counting pages lays out nothing more: that layout would
    /// be laid against the head plan and thrown away (invariant 207). After `paginateNow` it counts all.
    func testCountingPagesBeforeTheFullPlanLaysNoMoreText() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/fixtures/office/bus-headings.docx")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("docs/ is local-only") }
        PageViewOptionsStore.startingOptions = PageViewOptions(outline: true)
        defer { PageViewOptionsStore.reset() }
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        let lm = try XCTUnwrap(wc.textView.layoutManager)
        let length = try XCTUnwrap(wc.textView.textStorage?.length)
        XCTAssertTrue(wc.pageCountFollowsLaidText)
        let early = wc.printPageCount
        XCTAssertLessThan(lm.firstUnlaidCharacterIndex(), length, "counting pages laid the whole text out")
        wc.paginateNow()
        XCTAssertFalse(wc.pageCountFollowsLaidText)
        XCTAssertGreaterThan(wc.printPageCount, early)
        doc.close()
    }

    func testAppliedLayoutAgainstThePlanOnRealDocuments() throws {
        let env = ProcessInfo.processInfo.environment
        guard let list = env["FMD_PLAN_PARITY"] else { throw XCTSkip("set FMD_PLAN_PARITY=<document>[:<document>...]") }
        var report: [String] = []
        var failures = 0
        for path in list.split(separator: ":").map(String.init) {
            let url = URL(fileURLWithPath: path)
            let doc = MarkdownDocument()
            doc.readingSize = FontSizeStore.defaultSize
            doc.fileURL = url
            try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
            doc.makeWindowControllers()
            let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
            wc.window?.setFrame(NSRect(x: 0, y: 0, width: 820, height: 640), display: false)
            _ = HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
            // The engine reads the same input from `PlanJSON` as it would from `JSONSerialization`.
            if let built = PlanInputBuilder.naturalInput(controller: wc) {
                let ours = try JSONSerialization.jsonObject(with: try XCTUnwrap(PlanJSON.data(built.input)))
                let foundation = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: built.input))
                if !Self.sameAsTheEngineReadsIt(ours, foundation) { failures += 1; report.append("PARITY input encoding differs: \(url.lastPathComponent)") }
            }
            let result = PlanAppliedParity.run(controller: wc)
            report.append("PARITY \(url.lastPathComponent)")
            report.append(result.text)
            if result.skipped == nil, result.differing > 0 || result.unstable > 0 || result.pagesPlan != result.pagesApplied { failures += 1 }
            doc.close()
        }
        let text = report.joined(separator: "\n") + "\n"
        print(text)
        if let out = env["FMD_PLAN_PARITY_OUT"] { try text.write(toFile: out, atomically: true, encoding: .utf8) }
        XCTAssertEqual(failures, 0, "a document's applied layout differs from the plan it was built from")
    }
}
