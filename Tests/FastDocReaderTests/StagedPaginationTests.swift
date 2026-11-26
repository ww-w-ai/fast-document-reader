import XCTest
import AppKit
@testable import FastDocReader

/// A pagination generation spread over main-thread turns (invariant 207): the observation taken in
/// steps is the one-call observation, a change under the walk starts it again, and nothing it
/// observed outlives a cancellation.
final class StagedPaginationTests: XCTestCase {
    private var savedBudget: TimeInterval = 0

    override func setUp() {
        super.setUp()
        savedBudget = DocumentWindowController.StagedPagination.turnBudget
        PageViewOptionsStore.startingOptions = PageViewOptions(outline: true)
    }

    override func tearDown() {
        DocumentWindowController.StagedPagination.turnBudget = savedBudget
        PageViewOptionsStore.reset()
        super.tearDown()
    }

    private func open() throws -> (MarkdownDocument, DocumentWindowController) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/fixtures/office/bus-headings.docx")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("docs/ is local-only") }
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        return (doc, wc)
    }

    private func spin(until done: () -> Bool, _ seconds: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    }

    /// Laid and read in small steps, the observation gives the plan the same input as the one-call walk.
    func testTheObservationTakenInStepsIsTheOneCallObservation() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        spin(until: { !wc.isPaginationPending })
        let storage = try XCTUnwrap(wc.textView.textStorage)
        let container = try XCTUnwrap(wc.textView.textContainer)
        let whole = try XCTUnwrap(PlanInputBuilder.naturalInput(controller: wc))

        let walk = PlanObservation.Walk(storage: storage, like: container)
        var steps = 0
        while !walk.isLaidOut { walk.lay(characters: 700); steps += 1 }
        while !walk.isCollected { walk.collect(glyphs: 150); steps += 1 }
        XCTAssertGreaterThan(steps, 4, "the fixture must take several steps")
        let stepped = try XCTUnwrap(PlanInputBuilder.naturalInput(controller: wc, observation: walk.finish()))
        XCTAssertEqual(storage.layoutManagers.count, 1, "the observer is given back")
        XCTAssertEqual(stepped.observation.fragments.count, whole.observation.fragments.count)
        let a = try JSONSerialization.jsonObject(with: try XCTUnwrap(PlanJSON.data(stepped.input)))
        let b = try JSONSerialization.jsonObject(with: try XCTUnwrap(PlanJSON.data(whole.input)))
        XCTAssertTrue(PlanParityProbeTests.sameAsTheEngineReadsIt(a, b), "the plan is asked the same question")
    }

    /// The text changes while the generation runs: it observes again, and the answer it adopts is the
    /// one a synchronous generation gives for the changed text.
    func testAChangeUnderTheWalkObservesAgainAndAdoptsNoStaleAnswer() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        spin(until: { !wc.isPaginationPending })
        let storage = try XCTUnwrap(wc.textView.textStorage)
        DocumentWindowController.StagedPagination.turnBudget = 0
        wc.precomputeLayout()
        spin(until: { (wc.stagedPagination?.turns ?? 0) >= 2 })
        XCTAssertTrue(wc.isPaginationPending, "the generation must still be running when the text changes")
        // A longer first paragraph: every later line moves.
        storage.replaceCharacters(in: NSRange(location: 0, length: 0),
                                  with: String(repeating: "A longer opening line that wraps. ", count: 40))
        spin(until: { !wc.isPaginationPending })
        XCTAssertEqual(wc.lastStagedPaginationRestarts, 1, "the change starts the observation again")
        XCTAssertEqual(storage.layoutManagers.count, 1, "the discarded observer is given back")
        let staged = wc.pageBandDelegate.targets
        XCTAssertFalse(staged.isEmpty)
        wc.paginateNow()
        let reference = wc.pageBandDelegate.targets
        XCTAssertEqual(staged.count, reference.count)
        for (loc, target) in reference {
            let adopted = try XCTUnwrap(staged[loc], "line \(loc) has no target in the staged answer")
            XCTAssertEqual(adopted.y, target.y, accuracy: 0.01, "line \(loc) is placed from a stale observation")
        }
    }

    /// Before the plan is laid out, marking the view for display lays no text out: AppKit's resize of
    /// the growing view once laid the whole 편람 out that way, against a plan about to be replaced.
    func testMarkingTheViewForDisplayBeforeThePlanIsLaidOutLaysNothing() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        let lm = try XCTUnwrap(wc.textView.layoutManager)
        XCTAssertTrue(wc.pageCountFollowsLaidText)
        let laid = lm.firstUnlaidCharacterIndex()
        XCTAssertLessThan(laid, wc.textView.textStorage?.length ?? 0, "the fixture must not be laid out at first paint")
        // The cascade itself needs a document as long as the 편람 (`FMD_FIRSTPAINT_FILE` measures it);
        // what is held here is that the view is told to avoid it, and AppKit's idle layout is off.
        XCTAssertTrue(wc.textView.displayAvoidsLayout)
        XCTAssertFalse(lm.backgroundLayoutEnabled, "nor does AppKit's idle layout")
        spin(until: { !wc.pageCountFollowsLaidText })
        XCTAssertGreaterThanOrEqual(lm.firstUnlaidCharacterIndex(), wc.textView.textStorage?.length ?? 0)
        XCTAssertFalse(wc.textView.displayAvoidsLayout, "once the walk has laid the plan out, display lays out again")
        XCTAssertTrue(lm.backgroundLayoutEnabled)
    }

    /// Closing the window mid-walk adopts nothing and leaves no observer on the text.
    func testClosingTheWindowMidWalkGivesTheObserverBack() throws {
        let (doc, wc) = try open()
        spin(until: { !wc.isPaginationPending })
        let storage = try XCTUnwrap(wc.textView.textStorage)
        let plans = wc.planCallCount
        DocumentWindowController.StagedPagination.turnBudget = 0
        wc.precomputeLayout()
        spin(until: { (wc.stagedPagination?.turns ?? 0) >= 1 })
        XCTAssertTrue(wc.isPaginationPending)
        XCTAssertEqual(storage.layoutManagers.count, 2, "the observer is on the text while it walks")
        wc.window?.close()
        XCTAssertFalse(wc.isPaginationPending)
        XCTAssertEqual(storage.layoutManagers.count, 1)
        spin(until: { false }, 0.3)
        XCTAssertEqual(wc.planCallCount, plans, "a cancelled generation adopts nothing")
        doc.close()
    }

    /// A synchronous generation (⌘P) during a staged one replaces it, and the apply walk still finishes.
    func testPrintingMidWalkAnswersAtOnceAndTheWalkStillFinishes() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        spin(until: { !wc.isPaginationPending })
        let storage = try XCTUnwrap(wc.textView.textStorage)
        DocumentWindowController.StagedPagination.turnBudget = 0
        wc.precomputeLayout()
        spin(until: { (wc.stagedPagination?.turns ?? 0) >= 1 })
        let plans = wc.planCallCount
        wc.paginateNow()
        XCTAssertFalse(wc.isPaginationPending)
        XCTAssertEqual(wc.planCallCount, plans + 1)
        XCTAssertEqual(storage.layoutManagers.count, 1)
        spin(until: { !wc.pageCountFollowsLaidText })
        XCTAssertFalse(wc.pageCountFollowsLaidText, "the apply walk the staged generation was holding still runs")
        XCTAssertEqual(wc.planCallCount, plans + 1, "and asks for no second plan")
    }
}
