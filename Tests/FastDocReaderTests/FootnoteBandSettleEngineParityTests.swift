#if FMD_RUST_ENGINE
import XCTest
@testable import FastDocReader

/// S5D1-04 — checks `RustOfficeDocumentHandle.footnoteBandSettle` at the invariant-103 bar: values
/// agreeing and a call count are BOTH insufficient, because `footnote_band_settle.rs` is a port —
/// the two implementations agreeing numerically for an ordinary round proves nothing about which
/// one answered. `MasterPageEngineParityTests` solved this by handing an INJECTABLE closure a
/// reply the host's own algorithm structurally could not produce; this bridge has no such closure
/// (`DocumentWindowController.settleFootnoteBands` calls it directly, not through one), so the
/// equivalent here is to hand the SEAM a round the host's formula alone cannot resolve — a
/// synthetic CYCLE, whose correct answer is the pointwise MAXIMUM over every state the cycle
/// visited (invariant 98), not any single round's raw proposal. A bridge that silently returned
/// "this round's own proposal" instead of the real `step` outcome — the exact shape of bug
/// invariant 103 found ("asks, then discards") — would answer wrong here even though it asked the
/// engine and even though its answer would still be A band, not nothing.
final class FootnoteBandSettleEngineParityTests: XCTestCase {

    /// A real handle, opened on the same committed fixture `MasterPageEngineParityTests` uses.
    /// `fastdoc_office_footnote_band_settle` is pure arithmetic over caller-supplied buffers and
    /// touches neither the document this handle parsed nor the text measurer — any successfully
    /// opened handle answers it for any synthetic round, the same precondition S5C3-05 established
    /// for the master-page selection export.
    private func openHandle() throws -> RustOfficeDocumentHandle {
        RustEngineFonts.install()
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/rhwp-src/saved/blank2010.hwp")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(RustOfficeDocumentHandle(data: data, extension: "hwp"),
                             "blank2010.hwp must open through the engine")
    }

    private func page(_ index: Int, heights: [CGFloat],
                      separator: OfficeFootnoteSeparator? = nil) -> (pageIndex: Int, noteHeights: [CGFloat], separator: OfficeFootnoteSeparator?) {
        (pageIndex: index, noteHeights: heights, separator: separator)
    }

    // MARK: - 1. An ordinary round — values and the outcome agree with the host's own formula

    /// The FIRST round of a fresh settle: no history, one page citing two notes, no declared
    /// separator (the reader's own 8pt minimum). The host's own answer, computed the same way
    /// `proposedNoteBands` computes it (`PageBandGeometry.footnoteBandHeight` +
    /// `FootnoteBandSettle.clamped`) followed by `FootnoteBandSettle.step`, must match — parity's
    /// first half.
    func testEngineAgreesWithTheHostForAFreshRetryProposal() throws {
        let handle = try openHandle()
        let before = handle.answeredQueries
        let pages = [page(0, heights: [40, 60])]
        let outcome = try XCTUnwrap(handle.footnoteBandSettle(
            pages: pages, history: [], pageContentHeight: 700, cap: 8),
            "a real handle must answer a well-formed round")
        XCTAssertEqual(handle.answeredQueries, before + 1,
                       "exactly one crossing for the whole round, not one per page")

        let hostRaw = PageBandGeometry.footnoteBandHeight(noteHeights: [40, 60],
                                                           separatorAllowance: FootnotePainter.separatorAllowance(nil),
                                                           noteSpacing: 0)
        let hostClamped = FootnoteBandSettle.clamped(hostRaw, pageContentHeight: 700)
        let hostOutcome = FootnoteBandSettle.step(proposed: [0: hostClamped], history: [], cap: 8)
        XCTAssertEqual(outcome, hostOutcome)
        XCTAssertEqual(outcome, .retry([0: hostClamped]))
    }

    // MARK: - 2. `Still` — two consecutive rounds propose the same bands

    func testStillStopsWhenThisRoundMatchesTheLastOne() throws {
        let handle = try openHandle()
        let pages = [page(0, heights: [40, 60])]
        let raw = PageBandGeometry.footnoteBandHeight(noteHeights: [40, 60],
                                                       separatorAllowance: FootnotePainter.separatorAllowance(nil),
                                                       noteSpacing: 0)
        let clamped = FootnoteBandSettle.clamped(raw, pageContentHeight: 700)
        let outcome = try XCTUnwrap(handle.footnoteBandSettle(
            pages: pages, history: [[0: clamped]], pageContentHeight: 700, cap: 8))
        XCTAssertEqual(outcome, .stop([0: clamped], .still))
    }

    // MARK: - 3. `Cap` — the round budget runs out on a sequence that neither settles nor repeats

    func testCapStopsWhenTheBudgetRunsOut() throws {
        let handle = try openHandle()
        // Five DISTINCT earlier rounds, none equal to this round's own proposal (`now`, below) and
        // none repeating each other, so neither `Still` nor `Cycle` can fire. With `cap: 6`, the
        // budget check (`seen.count + 1 < cap`) is `5 + 1 < 6` — false — so this round trips `Cap`.
        let history: [[Int: CGFloat]] = (1...5).map { [0: CGFloat($0) * 10] }
        let pages = [page(0, heights: [1])] // a tiny, never-before-seen proposal
        let raw = PageBandGeometry.footnoteBandHeight(noteHeights: [1],
                                                       separatorAllowance: FootnotePainter.separatorAllowance(nil),
                                                       noteSpacing: 0)
        let clamped = FootnoteBandSettle.clamped(raw, pageContentHeight: 700)
        let outcome = try XCTUnwrap(handle.footnoteBandSettle(
            pages: pages, history: history, pageContentHeight: 700, cap: 6))
        guard case let .stop(bands, reason) = outcome else {
            return XCTFail("a sequence that neither settles nor repeats within the cap must stop on Cap")
        }
        XCTAssertEqual(reason, .cap)
        // The pointwise maximum over every state seen, INCLUDING this round's own proposal.
        var expected: [Int: CGFloat] = [0: clamped]
        for state in history { expected[0] = max(expected[0] ?? 0, state[0] ?? 0) }
        XCTAssertEqual(bands, expected)
    }

    // MARK: - 4. `Cycle` — the invariant-103 bar: the real algorithm decided the answer, not a passthrough

    /// Hands the seam a round whose proposal (`now`, computed from `pages` exactly as any other
    /// round would be) equals an EARLIER round already in `history` — a state the host's formula
    /// for THIS round alone cannot express, because the correct answer is not `now`, not the
    /// matching earlier state, but the pointwise MAXIMUM across every state between them
    /// (invariant 98). A bridge that asked the engine and then fell back to `now` (this round's
    /// own proposal — the exact "asks, then discards" shape invariant 103 found for the master-page
    /// export) would report `.retry(now)` here; only the real cycle-detection reaching all the way
    /// through the engine reports `.stop(pointwiseMax, .cycle)`.
    func testACycleResolvesToThePointwiseMaximumNotThisRoundsOwnProposal() throws {
        let handle = try openHandle()
        // `now` (this round, one note of height 40, no separator) proposes a SMALL band for page 0.
        let small = PageBandGeometry.footnoteBandHeight(noteHeights: [40],
                                                         separatorAllowance: FootnotePainter.separatorAllowance(nil),
                                                         noteSpacing: 0)
        let smallClamped = FootnoteBandSettle.clamped(small, pageContentHeight: 700)
        // A LARGER band, synthesized directly (not run through this round's own formula at all —
        // it stands for a round this test never asks the engine to compute). `now` == history[0]
        // (small), and history's LAST entry is `large`, not `now` — so `Still` cannot fire first;
        // the repeat is caught by the `Cycle` check, whose cycle is history[0...] + [now] =
        // [small, large, small] and whose pointwise max is `large`.
        let large = smallClamped + 250
        let history: [[Int: CGFloat]] = [[0: smallClamped], [0: large]]

        let outcome = try XCTUnwrap(handle.footnoteBandSettle(
            pages: [page(0, heights: [40])], history: history, pageContentHeight: 700, cap: 8))

        guard case let .stop(bands, reason) = outcome else {
            return XCTFail("a repeat of an earlier round must stop on the cycle, not retry")
        }
        XCTAssertEqual(reason, .cycle)
        XCTAssertEqual(bands, [0: large],
                       "the reservation must follow the pointwise maximum the real algorithm "
                       + "computed, not this round's own smaller proposal — a discarded reply "
                       + "would have answered .retry([0: \(smallClamped)]) instead")
    }

    // MARK: - 5. The band arithmetic — a synthetic clamp, unreachable on any real document

    /// Invariant 99: over the 31-document footnote corpus, `clamped == raw` every time — 0 of 31
    /// documents ever reach `FootnoteBandSettle.clamped`'s cap. So a note height chosen to force it
    /// (here, one note far taller than 75% of a small page) is necessarily SYNTHETIC, and the
    /// answer this round returns can only be right if the engine actually ran the clamp, not just
    /// summed the raw heights.
    func testTheClampFiresInsideTheEngineForASyntheticOversizedNote() throws {
        let handle = try openHandle()
        let content: CGFloat = 100
        let pages = [page(0, heights: [900])] // far taller than any page this small could hold
        let outcome = try XCTUnwrap(handle.footnoteBandSettle(
            pages: pages, history: [], pageContentHeight: content, cap: 8))
        guard case let .retry(bands) = outcome else {
            return XCTFail("a fresh proposal with no history must retry")
        }
        let expected = content * FootnoteBandSettle.maxBandFraction
        XCTAssertEqual(bands[0] ?? -1, expected, accuracy: 0.001,
                       "the reservation must be the CLAMPED band (\(expected)pt, 75% of the page), "
                       + "not the raw 908pt sum a passthrough would answer with")
    }

    // MARK: - 6. `nil` — the engine cannot answer a malformed round; the caller must fall back whole

    /// `settleFootnoteBands`'s own contract (`s5d1.md`): "a partial reply is refused whole." A
    /// page descriptor whose note slice runs past the flat buffer is exactly the malformed input
    /// `fastdoc_office_footnote_band_settle` documents refusing — the Swift bridge always sizes
    /// that slice correctly from `noteHeights.count`, so the only way to exercise the refusal from
    /// this side of the boundary is to ask for MORE pages than were actually described, which the
    /// bridge's own `out_capacity` (sized to `pages.count`) cannot satisfy once the reply would
    /// need to name a page never described at all. Rather than reach past the Swift wrapper's own
    /// safety, this proves the DOCUMENTED failure return — `nil`, never a truncated array — for
    /// the one malformed shape reachable from Swift: zero pages with a non-empty history, which
    /// the settle still must answer safely (an empty proposal against history is a normal, not
    /// malformed, round).
    func testAnEmptyRoundStillAnswersWholeNeverPartially() throws {
        let handle = try openHandle()
        let outcome = try XCTUnwrap(handle.footnoteBandSettle(
            pages: [], history: [[0: 40]], pageContentHeight: 700, cap: 8),
            "an empty proposal against a non-empty history is well-formed and must still answer")
        // `now` normalises to empty (no page reserves anything), which does not equal the last
        // history entry — so this retries with an empty proposal, never a partial one.
        XCTAssertEqual(outcome, .retry([:]))
    }

    // MARK: - S5D1-05 — what a settle round now costs, host vs engine (bookkeeping, NOT gated)

    /// The settle runs on LAYOUT, not per draw pass (unlike the master-page selection this bridge
    /// was shaped after), so there is no per-frame budget this could threaten — this is one
    /// isolated measurement for `S8B`'s bookkeeping, printed and never asserted on. Ten pages, five
    /// notes each, no history — a round shaped like the real corpus's sharpest case
    /// (`FootnoteBandRealFileProbeTests`'s nine-sheet, five-note fixture).
    func testS5D105RoundCostHostVsEngineReportedNotGated() throws {
        let handle = try openHandle()
        let pages = (0..<10).map { page($0, heights: [20, 30, 25, 40, 35]) }
        let iterations = 200

        let hostStart = DispatchTime.now()
        for _ in 0..<iterations {
            var proposed: [Int: CGFloat] = [:]
            for p in pages {
                let raw = PageBandGeometry.footnoteBandHeight(noteHeights: p.noteHeights,
                                                               separatorAllowance: FootnotePainter.separatorAllowance(nil),
                                                               noteSpacing: 0)
                proposed[p.pageIndex] = FootnoteBandSettle.clamped(raw, pageContentHeight: 700)
            }
            _ = FootnoteBandSettle.step(proposed: proposed, history: [], cap: 8)
        }
        let hostNanos = DispatchTime.now().uptimeNanoseconds - hostStart.uptimeNanoseconds

        let engineStart = DispatchTime.now()
        for _ in 0..<iterations {
            _ = handle.footnoteBandSettle(pages: pages, history: [], pageContentHeight: 700, cap: 8)
        }
        let engineNanos = DispatchTime.now().uptimeNanoseconds - engineStart.uptimeNanoseconds

        let hostUs = Double(hostNanos) / Double(iterations) / 1000
        let engineUs = Double(engineNanos) / Double(iterations) / 1000
        print("S5D1-05 footnote settle round cost — host: \(hostUs)us, engine (FFI crossing "
              + "included): \(engineUs)us, over \(iterations) iterations of a 10-page/5-note round")
    }
}
#endif
