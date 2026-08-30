import XCTest
import AppKit
@testable import FastDocReader

/// What it COSTS the host to rebuild a finished attributed string from runs — the ceiling on any
/// design that moves markdown typography into the engine and ships the result over a wire.
///
/// Measured before building the wire, because the wire is only worth writing if this number is
/// well under what it replaces. The shape is taken from the engine's own census of what the ported
/// renderer puts on `demo/` (`markdown_attribute_census`): 1,247,986 source characters became
/// 47,025 runs carrying font, colour, paragraph style, and a scattering of custom keys.
///
/// This deliberately does NOT parse or lay out anything. It is the floor: allocate the string,
/// then apply N attribute dictionaries over it.
final class AttributedRunMaterializationProbeTests: XCTestCase {
    func testWhatItCostsToRebuildAFinishedStringFromRuns() {
        let characters = 1_247_986
        let runCount = 47_025

        // One pool of each, as an interned wire would hand over — 47,025 runs share a few dozen
        // values, so the host builds those once and the runs reference them.
        let fonts = (0..<24).map { NSFont.systemFont(ofSize: CGFloat(12 + $0 % 8)) }
        let colors = (0..<8).map { NSColor(white: CGFloat($0) / 8.0, alpha: 1) }
        let styles: [NSParagraphStyle] = (0..<16).map { i in
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = CGFloat(i)
            return p
        }

        // Repeat by the unit's own UTF-16 length, not a guessed one: the first version divided by
        // 18 for a 14-unit unit and came out 22% short, which the length guard caught.
        let unit = "가나다라 abcdefgh "
        let text = String(repeating: unit, count: characters / unit.utf16.count + 1)
        let runLength = max(1, text.utf16.count / runCount)

        let start = DispatchTime.now().uptimeNanoseconds
        let built = NSMutableAttributedString(string: text)
        built.beginEditing()
        var location = 0
        var applied = 0
        while location + runLength <= built.length {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: fonts[applied % fonts.count],
                .foregroundColor: colors[applied % colors.count],
                .paragraphStyle: styles[applied % styles.count],
            ]
            built.setAttributes(attrs, range: NSRange(location: location, length: runLength))
            location += runLength
            applied += 1
        }
        built.endEditing()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        print(String(format: "RUN-MATERIALIZE %d chars, %d runs applied  %8.1f ms",
                     built.length, applied, ms))
        // Without this an empty string would be the fastest arm of any comparison this feeds.
        XCTAssertGreaterThan(applied, runCount / 2, "the probe did not apply a realistic run count")
        XCTAssertGreaterThanOrEqual(built.length, characters)
    }

    /// The other half of the host's bill: getting the runs off the wire at all.
    ///
    /// Materialising is only the floor if the decode is free, and this repo has already been
    /// surprised there once — P3 found the host's office cost was the `Decodable` pass, not the
    /// JSON scan, and P4b then took 20% off it by removing repeated nested containers. So the run
    /// wire is measured in the shape it would actually have: a flat array of small integers, with
    /// the values interned into pools the runs point at.
    func testWhatItCostsToGetTheRunsOffAJSONWire() throws {
        struct Run: Decodable { let l: Int; let n: Int; let f: Int; let c: Int; let p: Int }
        struct Wire: Decodable { let text: String; let runs: [Run] }

        let unit = "가나다라 abcdefgh "
        let text = String(repeating: unit, count: 1_247_986 / unit.utf16.count + 1)
        var json = Data(#"{"text":"#.utf8)
        json.append(try JSONEncoder().encode(text))
        json.append(Data(#","runs":["#.utf8))
        var first = true
        var location = 0
        for i in 0..<47_025 {
            if !first { json.append(0x2C) }
            first = false
            json.append(Data(#"{"l":\#(location),"n":26,"f":\#(i % 24),"c":\#(i % 8),"p":\#(i % 16)}"#.utf8))
            location += 26
        }
        json.append(Data("]}".utf8))

        var best = Double.greatestFiniteMagnitude
        var runs = 0
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let wire = try JSONDecoder().decode(Wire.self, from: json)
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            runs = wire.runs.count
        }
        print(String(format: "RUN-WIRE-DECODE %d bytes, %d runs  %8.1f ms", json.count, runs, best))
        XCTAssertEqual(runs, 47_025, "a wire that decoded to nothing would be the fastest arm")
    }
}
