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
