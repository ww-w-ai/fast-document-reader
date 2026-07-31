import XCTest
import AppKit
@testable import FastDocReader

/// What it costs to carry an `Equatable`-but-not-`Hashable` Swift value as a text attribute.
///
/// The Swift runtime says this out loud — "Obj-C `-hash` invoked on a Swift value of type
/// `FastDocReader.OfficeGraphicInfo` that is Equatable but not Hashable; this can lead to severe
/// performance problems" — printed on every run of this app that opened an office document, because
/// both `OfficeGraphicInfo` and `FillMarginTabInfo` ride in the text storage as attribute values
/// (invariant 46's mechanism) and `NSMutableAttributedString` hashes attribute values when it decides
/// whether two adjacent runs can coalesce.
///
/// A wall clock cannot answer "how much" here by rebuilding the app twice: this machine's load swings
/// the same measurement by 3x, and the before/after builds cannot be run at the same instant. So both
/// shapes are declared HERE and measured back to back IN ONE PROCESS, alternating, so whatever the
/// machine is doing is done to both arms equally. Only their RATIO is asserted, never a millisecond
/// figure — an absolute threshold in this file would be the flaky test this repo already has too many
/// of (see CLAUDE.md's note on load).
final class AttributeHashingSpikeTests: XCTestCase {
    /// Same stored properties as `OfficeGraphicInfo`, minus the conformance under test.
    private struct EquatableOnly: Equatable {
        var authored: CGSize
        var placeholderLabel: String?
        var basisWidth: CGFloat?
        var isInsideCell: Bool
    }
    private struct AlsoHashable: Hashable {
        var authored: CGSize
        var placeholderLabel: String?
        var basisWidth: CGFloat?
        var isInsideCell: Bool
    }

    private static let key = NSAttributedString.Key("fmd.spike.graphic")

    /// Builds a string whose every paragraph carries the value, then walks it the way the reflow
    /// passes do. `setAttributes` on adjacent equal-valued runs is what triggers the coalescing
    /// comparison, and `enumerateAttribute` is what `resizeOfficeGraphics` actually runs on every
    /// reflow — so this is the app's own shape rather than a synthetic hash loop.
    private func exercise(_ make: (Int) -> Any, runs: Int) -> Double {
        let unit = "graphic paragraph with some text in it\n"
        let s = NSMutableAttributedString(string: String(repeating: unit, count: runs))
        let step = (unit as NSString).length
        let start = Date()
        for i in 0..<runs {
            s.setAttributes([Self.key: make(i)], range: NSRange(location: i * step, length: step))
        }
        var seen = 0
        s.enumerateAttribute(Self.key, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if v != nil { seen += 1 }
        }
        XCTAssertGreaterThan(seen, 0)
        return Date().timeIntervalSince(start) * 1000
    }

    func testHashableAttributeValuesAreNotSlowerAndTheRuntimeStopsComplaining() {
        // Deliberately few DISTINCT values across many runs: that is the real document (a page's
        // pictures share a basis width), and it is also the case where a missing hash hurts most,
        // because every equal-valued neighbour is a coalescing candidate to be compared.
        let distinct = 8
        func eq(_ i: Int) -> Any {
            EquatableOnly(authored: CGSize(width: 100 + i % distinct, height: 80), placeholderLabel: nil,
                          basisWidth: 451.3, isInsideCell: i % 2 == 0)
        }
        func ha(_ i: Int) -> Any {
            AlsoHashable(authored: CGSize(width: 100 + i % distinct, height: 80), placeholderLabel: nil,
                         basisWidth: 451.3, isInsideCell: i % 2 == 0)
        }
        let runs = 4_000
        _ = exercise(eq, runs: 200)                 // warm both paths before timing either
        _ = exercise(ha, runs: 200)

        var eqTimes: [Double] = [], haTimes: [Double] = []
        for _ in 0..<3 {                            // alternate, so load lands on both arms
            eqTimes.append(exercise(eq, runs: runs))
            haTimes.append(exercise(ha, runs: runs))
        }
        let eqMed = eqTimes.sorted()[1], haMed = haTimes.sorted()[1]
        print(String(format: "SPIKE attribute values over %d runs — Equatable-only %.1f ms, Hashable %.1f ms (%.2fx)",
                     runs, eqMed, haMed, eqMed > 0 ? haMed / eqMed : 0))

        // The claim being pinned is the one that justified the change: making these values Hashable
        // does not COST anything. Whether it is dramatically faster depends on how often AppKit
        // chooses to hash, which is not ours to control — so this asserts the direction, generously,
        // rather than a speedup this test cannot promise on every machine.
        XCTAssertLessThan(haMed, eqMed * 1.5,
                          "adding Hashable made attribute handling materially SLOWER, which would "
                          + "invert the reason for the change")
    }
}
