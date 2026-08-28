import XCTest
@testable import FastDocReader

/// The CHOICE `DocumentWindowController.settleFootnoteBands` makes, on its own.
///
/// Invariant 103's point, one level above the bridge: `FootnoteBandSettleEngineParityTests` proves
/// the engine gives the right answer, and proves nothing about whether the reader USES it. Nothing
/// in this suite constructs a window controller, so a mutation that asks the engine and then throws
/// the reply away leaves all 48 footnote tests green — measured, not assumed. `resolve` is that
/// choice extracted to somewhere a test can reach. Unguarded on purpose: the choice exists in both
/// builds, so it is checked in both.
final class FootnoteBandSettleResolveTests: XCTestCase {
    private let host = FootnoteBandSettle.Outcome.stop([1: 11], .still)
    private let engine = FootnoteBandSettle.Outcome.retry([1: 22])

    func testTheEnginesAnswerIsTheOneUsed() {
        XCTAssertEqual(FootnoteBandSettle.resolve(engine: engine, host: host), engine,
                       "asking the engine and then using the host's own answer is the defect this test exists for")
    }

    func testTheHostAnswersWhenTheEngineCannot() {
        XCTAssertEqual(FootnoteBandSettle.resolve(engine: nil, host: host), host)
    }

    func testTheHostArithmeticIsNotPaidWhenTheEngineAnswered() {
        var hostRuns = 0
        func hostAnswer() -> FootnoteBandSettle.Outcome { hostRuns += 1; return host }
        _ = FootnoteBandSettle.resolve(engine: engine, host: hostAnswer())
        XCTAssertEqual(hostRuns, 0, "the fallback is a fallback, not a second computation run every round")
        _ = FootnoteBandSettle.resolve(engine: nil, host: hostAnswer())
        XCTAssertEqual(hostRuns, 1)
    }
}

/// The HOST's own proposal, against the payload the ENGINE is handed for the same round.
///
/// `settleFootnoteBands` builds two separate answers to one question — which notes each page cites
/// and how tall that makes its band. The engine gets `footnotePages` mapped into per-page note
/// heights; the host arm calls `proposedNoteBands()`. Only the engine's side was ever checked,
/// because `FootnoteBandSettle.resolve` takes `host:` as an autoclosure and never evaluates it
/// while a handle answers — so on every real document the host arithmetic is dead at runtime, and
/// it comes alive exactly for a document whose handle failed to open. Measured: adding 9pt to every
/// band `proposedNoteBands()` returns changed no verdict in the whole suite.
///
/// This is the same shape the table-pagination fallback needed
/// (`PagedTableOverrunTests.testTheHostsOwnPaginationReachesTheSameAnswerAsTheEngineOnARealReport`)
/// — compare the two answers rather than assert a one-sided property about one of them.
final class FootnoteProposalAgreesWithTheEnginesPayloadTests: XCTestCase {
    func testTheHostsProposalMatchesWhatTheEngineIsAskedAboutOnARealDocument() throws {
        let path = "Vendor/rhwp-src/samples/footnote-01.hwp"
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("needs \(path) — an HWP that CITES footnotes")
        }
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "hwp")
        XCTAssertFalse(doc.officeFootnotes.isEmpty, "wrong fixture: this document cites no footnote")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.textView.postsFrameChangedNotifications = false
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.updateTextInset()
        wc.textView.layoutManager?.ensureLayout(for: try XCTUnwrap(wc.textView.textContainer))

        let pages = wc.footnotePages
        XCTAssertFalse(pages.isEmpty, "no page of this document cites a note — nothing is being compared")

        let host = wc.proposedNoteBands()
        let engine = try XCTUnwrap(
            doc.officeEngineHandle?.footnoteBandSettle(
                pages: pages.map { page, numbers in
                    (pageIndex: page, noteHeights: numbers.compactMap { wc.footnoteHeights[$0] },
                     separator: wc.footnoteSeparator(forPage: page))
                },
                history: [], pageContentHeight: wc.pageBandDelegate.pageContentHeight, cap: 8),
            "the engine must answer this round, or there is nothing to compare against")

        // Only a `retry`/`stop` carries bands; either way the bands are what the two sides had to
        // agree about, and an empty answer would make the comparison vacuous.
        let engineBands: [Int: CGFloat]
        switch engine {
        case let .retry(bands): engineBands = bands
        case let .stop(bands, _): engineBands = bands
        }
        XCTAssertFalse(engineBands.isEmpty, "the engine reserved nothing — this proves nothing")
        XCTAssertEqual(Set(host.keys), Set(engineBands.keys),
                       "the two sides disagree about WHICH pages reserve a band")
        for (page, hostBand) in host {
            XCTAssertEqual(try XCTUnwrap(engineBands[page]), hostBand, accuracy: 0.5,
                           "page \(page): the host proposes a different band than the engine")
        }
    }
}
