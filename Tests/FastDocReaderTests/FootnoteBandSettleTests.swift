import XCTest
@testable import FastDocReader

/// The stopping rule for the note-band fixpoint (S13).
///
/// S13 reserves nothing and draws nothing — its deliverable is that the loop S14 is about to build
/// PROVABLY ends, including on the document that motivates the whole clamp: a note taller than the
/// page it is cited on. These tests are therefore about the rule alone and never lay anything out,
/// which is what lets the pathological sequences be written down exactly rather than hunted for in
/// a corpus.
final class FootnoteBandSettleTests: XCTestCase {

    /// The loop's own budget, not a number of this test's choosing — `DocumentWindowController.
    /// maxPagedTableSettles` is DEFINED as this, so the two cannot drift and no test needs to guard
    /// that they haven't.
    private let cap = FootnoteBandSettle.maxRounds

    // MARK: the three stops

    /// Stillness: two rounds in a row asked for the same bands, so the layout is not moving.
    func testTwoIdenticalRoundsStopAsStill() {
        let state: [Int: CGFloat] = [3: 40, 7: 22]
        let outcome = FootnoteBandSettle.step(proposed: state, history: [[3: 12], state], cap: cap)
        XCTAssertEqual(outcome, .stop(state, .still))
    }

    /// A round that changes something and has not been seen before simply runs again.
    func testAFreshProposalRetries() {
        let outcome = FootnoteBandSettle.step(proposed: [1: 30], history: [[:]], cap: cap)
        XCTAssertEqual(outcome, .retry([1: 30]))
    }

    /// The oscillation the type comment describes, and the reason a plain "run until nothing moves"
    /// is not enough: A → B → A. The rule must recognise the repeat rather than spin to the cap.
    func testATwoCycleIsDetectedAndStopsOnTheCycle() {
        let a: [Int: CGFloat] = [4: 36]     // the note fits on page 4
        let b: [Int: CGFloat] = [5: 36]     // …which pushed its marker to page 5
        let outcome = FootnoteBandSettle.step(proposed: a, history: [a, b], cap: cap)
        guard case let .stop(bands, reason) = outcome else { return XCTFail("expected a stop") }
        XCTAssertEqual(reason, .cycle)
        // Both halves of the oscillation are honoured — neither page is left reserving nothing for
        // a note that some round put there.
        XCTAssertEqual(bands, [4: 36, 5: 36])
    }

    /// A sequence that neither settles nor repeats is stopped by the caller's budget, and the
    /// budget is the settle loop's own so the two cannot drift.
    func testACapStopCarriesEveryPageEverAskedFor() {
        let history: [[Int: CGFloat]] = (0..<(cap - 1)).map { [$0: CGFloat(10 + $0)] }
        let outcome = FootnoteBandSettle.step(proposed: [99: 5], history: history, cap: cap)
        guard case let .stop(bands, reason) = outcome else { return XCTFail("expected a stop") }
        XCTAssertEqual(reason, .cap)
        XCTAssertEqual(bands.count, cap)
        XCTAssertEqual(bands[99], 5)
    }

    // MARK: the direction ties are resolved in

    /// `max` is the safe half of an oscillation: reserving too much leaves a gap, reserving too
    /// little draws a note over the body. The resolved state is therefore never BELOW any state the
    /// loop actually visited.
    func testTheResolvedStateIsNeverBelowAnyStateItSaw() {
        let states: [[Int: CGFloat]] = [[1: 10, 2: 50], [1: 44, 2: 8], [2: 31]]
        let resolved = FootnoteBandSettle.pointwiseMax(states)
        for state in states {
            for (page, band) in state {
                XCTAssertGreaterThanOrEqual(resolved[page] ?? 0, band,
                                            "page \(page) resolved below a state that was visited")
            }
        }
        XCTAssertEqual(resolved, [1: 44, 2: 50])
    }

    /// A page that stopped citing a note may be dropped from the dictionary OR zeroed; the rule
    /// must read those as the same state, or the repeat check never fires and every such document
    /// spins to the cap.
    func testAnAbsentPageAndAZeroedPageAreTheSameState() {
        let outcome = FootnoteBandSettle.step(proposed: [1: 20, 2: 0],
                                              history: [[1: 20]], cap: cap)
        XCTAssertEqual(outcome, .stop([1: 20], .still))
    }

    // MARK: the clamp — what makes any of it bounded

    /// The pathological document S13 was asked to terminate on: a note taller than the page it is
    /// cited on. Unclamped it reserves the whole page, the body gets nowhere to go, and the marker
    /// is pushed forward one page per round forever. Clamped, the page always keeps body height.
    func testANoteTallerThanItsPageStillLeavesTheBodyRoom() {
        let content: CGFloat = 555.59
        let band = FootnoteBandSettle.clamped(content * 3, pageContentHeight: content)
        XCTAssertLessThan(band, content, "a band that eats its whole page cannot terminate")
        XCTAssertEqual(band, content * FootnoteBandSettle.maxBandFraction, accuracy: 0.001)
        XCTAssertGreaterThan(content - band, 0)
    }

    /// Nonsense in, nothing reserved — a band cannot be negative, and a page of no height reserves
    /// nothing rather than dividing into one.
    func testNonsenseBandsReserveNothing() {
        XCTAssertEqual(FootnoteBandSettle.clamped(-40, pageContentHeight: 500), 0)
        XCTAssertEqual(FootnoteBandSettle.clamped(.nan, pageContentHeight: 500), 0)
        XCTAssertEqual(FootnoteBandSettle.clamped(.infinity, pageContentHeight: 500),
                       500 * FootnoteBandSettle.maxBandFraction, accuracy: 0.001)
        XCTAssertEqual(FootnoteBandSettle.clamped(40, pageContentHeight: 0), 0)
    }

    // MARK: the bound itself

    /// The deliverable, stated as a property rather than an example: driven by ANY proposal
    /// sequence at all — settling, oscillating, or adversarially never-repeating — the rule reaches
    /// a stop within the cap. Three generators cover the three stops, and a fourth is deliberately
    /// hostile: it invents a state no earlier round produced, every round.
    func testEveryProposalSequenceStopsWithinTheCap() {
        let generators: [(String, (Int) -> [Int: CGFloat])] = [
            ("settles",     { _ in [1: 30] }),
            ("oscillates",  { round in round % 2 == 0 ? [1: 30] : [2: 30] }),
            ("three-cycle", { round in [round % 3: 25] }),
            ("never repeats", { round in [round: CGFloat(round + 1)] }),
        ]
        for (name, generator) in generators {
            var history: [[Int: CGFloat]] = []
            var stopped = false
            // One more turn than the cap allows, so a rule that failed to stop is caught here
            // rather than by a hung loop.
            for round in 0...(cap + 1) {
                switch FootnoteBandSettle.step(proposed: generator(round), history: history, cap: cap) {
                case let .retry(state):
                    history.append(state)
                case .stop:
                    stopped = true
                }
                if stopped { break }
            }
            XCTAssertTrue(stopped, "\(name) never stopped within \(cap) rounds")
            XCTAssertLessThanOrEqual(history.count, cap, "\(name) ran more rounds than the cap")
        }
    }
}
