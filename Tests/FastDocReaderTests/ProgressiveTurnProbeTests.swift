import XCTest
import AppKit
@testable import FastDocReader

/// WHAT THE READER FEELS AFTER THE WINDOW APPEARS — `FMD_FIRSTPAINT_FILE=<abs path>`.
///
/// First paint is only half the question. The rest of the document is built on the MAIN thread
/// (invariant 55: building off it was measured and rejected — `NSTextTable`/`NSParagraphStyle`
/// construction is not documented as thread-safe), so however it is sliced, each slice is a turn the
/// reader cannot scroll through. This measures the slices: the longest single main-thread turn after
/// the window is up, how many turns there were, and how long until the document is whole.
///
/// A turn is timed the way it is felt — one `RunLoop.run(until:)` with a 1 ms horizon takes as long
/// as the work it happens to drain, so a long turn shows up as a long call.
final class ProgressiveTurnProbeTests: XCTestCase {
    func testTurnsAfterFirstPaint() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_FIRSTPAINT_FILE"] else {
            throw XCTSkip("set FMD_FIRSTPAINT_FILE")
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: data, ofType: "net.daringfireball.markdown")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        var t = Date()
        doc.makeWindowControllers()
        let firstPaintMs = Date().timeIntervalSince(t) * 1000
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 900), display: false)

        var worstMs = 0.0, turns = 0, longTurns = 0
        let render = doc.progressiveRender
        let started = Date()
        t = Date()
        while doc.isProgressiveRenderPending, Date().timeIntervalSince(started) < 120 {
            let turnStart = Date()
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            let ms = Date().timeIntervalSince(turnStart) * 1000
            turns += 1
            worstMs = max(worstMs, ms)
            if ms > 100 { longTurns += 1 }   // 100 ms is where a scroll starts to feel stuck
        }
        let wholeMs = Date().timeIntervalSince(started) * 1000
        let chunks = render?.chunksHandedOut ?? 0
        // ARRIVED is not FINISHED. Whichever way the tail is divided, the same layout has to happen
        // — one shape pays it between the pieces and the other pays it afterwards, so comparing the
        // two on arrival alone credits the undivided one with work it has not done yet. Keep going
        // until the laid-out height stops moving.
        var stableHeight = CGFloat(-1), stablePolls = 0
        while stablePolls < 20, Date().timeIntervalSince(started) < 180 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            let h = wc.textView.frame.height
            stablePolls = (h == stableHeight) ? stablePolls + 1 : 0
            stableHeight = h
        }
        let settledMs = Date().timeIntervalSince(started) * 1000
        // `polls` is how often the loop looked, NOT how many pieces the document arrived in — the
        // render itself is the only thing that knows that, and reporting the poll count as "turns"
        // once made a 20-piece tail read as 650.
        print(String(format: "TURNS firstPaint=%.0fms worstTurn=%.0fms turnsOver100ms=%d chunks=%d polls=%d untilWhole=%.0fms untilSettled=%.0fms chars=%d",
                     firstPaintMs, worstMs, longTurns, chunks, turns, wholeMs, settledMs,
                     wc.textView.textStorage?.length ?? 0))
        doc.windowControllers.forEach { doc.removeWindowController($0) }
    }
}
