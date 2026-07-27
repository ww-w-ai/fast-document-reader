import XCTest
import AppKit
@testable import FastDocReader

/// `windowDidResize` fires per FRAME during a live window-edge drag. A purely VERTICAL drag (only
/// the height changes — a bottom-edge drag, or any resize that leaves the reading column's width
/// untouched) has nothing width-dependent to redo: `updateTextInset` re-wraps text and re-solves
/// table/tab geometry entirely from the column WIDTH. Gating on the width actually changing — the
/// same test `viewportChanged` applies on its own — is what these tests pin down.
///
/// `resizeGateReflowCount` (not `textInsetUpdateCount`) is the counter used for every POSITIVE
/// assertion here (proving the gate does NOT over-reject a real width change), and deliberately so:
/// the text view is itself autoresized to the window's width, so the very same width-changing
/// `setFrame` call that a test drives ALSO fires `viewportChanged` via
/// `NSView.frameDidChangeNotification`, which runs `updateTextInset` through its own, independent
/// gate. A counter incremented by `updateTextInset` itself (from ANY caller) cannot tell "windowDidResize's
/// own gate passed" apart from "viewportChanged did the work instead" — a mutation that makes
/// `windowDidResize`'s gate reject EVERYTHING can hide behind that confound and still show the
/// counter incrementing. `resizeGateReflowCount` is incremented inside `windowDidResize` itself,
/// strictly after its own gate, before it calls `updateTextInset` — nothing else can move it.
final class WindowResizeGateTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-resize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    private func open(_ source: String) throws -> (MarkdownDocument, DocumentWindowController) {
        let url = temp.appendingPathComponent("doc.md")
        try Data(source.utf8).write(to: url)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: Data(source.utf8), ofType: "public.plain-text")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        // These tests exist to isolate `windowDidResize`'s OWN gate — but `textView` is itself
        // autoresized to the window's width (`autoresizingMask = [.width]`), so ANY `setFrame` a
        // test drives (including the one establishing the 800x600 baseline size right below) ALSO
        // fires `viewportChanged` (via `NSView.frameDidChangeNotification` on the text view, and
        // `NSView.boundsDidChangeNotification` on the scroll view's content view) — which runs
        // `updateTextInset` through its OWN, independent width check and can legitimately win the
        // race, syncing `lastClipWidth` before this test's explicit `windowDidResize` call even
        // runs. That is correct, desired de-duplication in the real app (see `windowDidResize`'s
        // own doc) — but it would make `resizeGateReflowCount` stay put for a reason that has
        // nothing to do with `windowDidResize`'s own logic, hiding exactly the over-gating bug
        // these tests exist to catch. Silencing both notification paths BEFORE the very first
        // `setFrame` removes that confound so every assertion below — including "the first resize
        // establishes the baseline" — reflects `windowDidResize` alone.
        wc.textView.postsFrameChangedNotifications = false
        wc.textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = false
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: true)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        return (doc, wc)
    }

    /// A resize event whose width is UNCHANGED from the last one `windowDidResize` saw must not
    /// count as a reflow `windowDidResize` itself performed.
    func testVerticalOnlyResizeDoesNotReflow() throws {
        let (_, wc) = try open("# Title\n\nSome paragraph text that will wrap across the column.\n")

        wc.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: wc.window))
        let baseline = wc.resizeGateReflowCount
        XCTAssertGreaterThanOrEqual(baseline, 1, "the first resize event must still establish lastClipWidth")

        // A purely vertical drag: grow the window's HEIGHT only, width held fixed — mirrors a
        // bottom-edge drag exactly (only the height component of the frame changes).
        for newHeight: CGFloat in [650, 500, 720, 480] {
            wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: newHeight), display: true)
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            wc.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: wc.window))
        }
        XCTAssertEqual(wc.resizeGateReflowCount, baseline,
                       "a resize event with unchanged width must not be counted as windowDidResize's own reflow")
    }

    /// The mirror check: a resize that genuinely changes the WIDTH (with or without a height change
    /// alongside it) must still reflow through `windowDidResize`'s OWN gate — using
    /// `resizeGateReflowCount`, not the confoundable `textInsetUpdateCount` (see the file doc).
    func testWidthChangingResizeStillReflows() throws {
        let (_, wc) = try open("# Title\n\nSome paragraph text that will wrap across the column.\n")

        wc.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: wc.window))
        let baseline = wc.resizeGateReflowCount

        // Width alone.
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 500, height: 600), display: true)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: wc.window))
        XCTAssertEqual(wc.resizeGateReflowCount, baseline + 1, "a width-only change must still reflow")

        // Width AND height together (the common case for a corner drag).
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: true)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: wc.window))
        XCTAssertEqual(wc.resizeGateReflowCount, baseline + 2,
                       "a resize that changes width alongside height must still reflow")
    }

    /// The sidebar/split-animation path (invariant 24) must keep working: `suspendReflow` is set
    /// while it animates, and `windowDidResize` must still refuse ALL work then — width-changed or
    /// not — exactly as before this change (the new gate must not weaken the existing one).
    func testSuspendedReflowStillBlocksEverythingRegardlessOfWidth() throws {
        let (_, wc) = try open("# Title\n\nSome paragraph text.\n")
        wc.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: wc.window))
        let baseline = wc.resizeGateReflowCount

        // The REAL path that sets `suspendReflow` (invariant 24) — no test-only hook needed.
        wc.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: wc.window))
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 500, height: 600), display: true)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: wc.window))
        XCTAssertEqual(wc.resizeGateReflowCount, baseline,
                       "suspendReflow must still block windowDidResize even when width DID change")
    }

    /// Regression: `lastClipWidth` must stay CURRENT even when the caller that changes it runs on a
    /// deferred turn. `windowDidEndLiveResize` no longer writes it directly — only `updateTextInset`
    /// does, from whatever width is actually current when its (`runBusy`-deferred) work runs. Before
    /// this, a live-resize drag ending, immediately followed by ANOTHER resize before that deferred
    /// work had run, could leave `lastClipWidth` pinned to the FIRST drag's end-width — so a LATER
    /// resize landing back on that same number would be wrongly rejected as "unchanged" even though
    /// the column had genuinely moved on in between.
    func testLastClipWidthStaysCurrentAcrossADeferredEndOfDragReflow() throws {
        let (_, wc) = try open("# Title\n\nSome paragraph text that will wrap across the column.\n")
        wc.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: wc.window))

        // Drag to 500 and release — `windowDidEndLiveResize` queues (but does not synchronously
        // run) the deferred reflow that used to be the only thing writing `lastClipWidth` here.
        wc.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: wc.window))
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 500, height: 600), display: true)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: wc.window))
        // Let the deferred (`DispatchQueue.main.async`) reflow inside `reflow(keeping:)` actually
        // run, so `updateTextInset` records the true current width. A single long `RunLoop.run`
        // call is not reliable for draining `DispatchQueue.main.async` work in this test host —
        // repeated short pumps is the pattern already established by `RealEditLatencyTests.spinRunLoop`.
        spinRunLoop(seconds: 1)

        let baseline = wc.resizeGateReflowCount

        // A later, genuinely different width — this must NOT be rejected as "unchanged". (Note:
        // `setFrame` itself can synchronously drive the real `NSWindowDelegate` callback in this
        // host, same as `windowDidResize` called explicitly right after — either way, the total
        // change from `baseline` for one genuine width change must be exactly one.)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 700, height: 600), display: true)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: wc.window))
        XCTAssertEqual(wc.resizeGateReflowCount, baseline + 1,
                       "a real width change after a drag must not be rejected by a stale lastClipWidth")
    }

    /// Repeated short pumps drains `DispatchQueue.main.async` work reliably in this test host,
    /// where a single long `RunLoop.run(before:)` call was observed not to (see
    /// `RealEditLatencyTests.spinRunLoop`, the established precedent this mirrors).
    private func spinRunLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}
