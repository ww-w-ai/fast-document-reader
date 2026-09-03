import XCTest
@testable import FastDocReader

/// What a real HWP declares about CHARACTER WIDTH (장평) and letter spacing (자간), and whether the
/// export carries it at all.
///
/// Measured against rhwp on the administrative manual: at an identical 367.2pt of column and an
/// identical 12.0pt font, rhwp sets 39 Korean characters on a line where this reader sets 37 —
/// 9.42pt per character against 12pt of em, which no full-width Hangul face produces on its own.
/// HWP's char shape carries a per-script width ratio; this reader has no notion of one, so the
/// first question is whether the number even reaches it.
///
/// `FMD_HWP_CHAR_RATIO=<file>`. Skipped by default, following the `FMD_HWP_STYLE_PROBE` family.
final class HwpCharRatioProbeTests: XCTestCase {
    func testWhatTheCharShapesDeclare() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_HWP_CHAR_RATIO"] else {
            throw XCTSkip("set FMD_HWP_CHAR_RATIO=<document> to inspect char-shape widths")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let json = HwpReader.exportDocumentJSON(data),
              let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return XCTFail("could not export/parse that document")
        }
        print("PROBE top-level keys : \(root.keys.sorted().joined(separator: " "))")
        for key in ["charShapes", "charShapeDecor"] {
            guard let table = root[key] as? [[String: Any]] else { continue }
            print("PROBE \(key): \(table.count) rows")
            var keys: [String: Int] = [:]
            for row in table { for k in row.keys { keys[k, default: 0] += 1 } }
            print("PROBE \(key) fields: " + keys.sorted { $0.value > $1.value }
                .map { "\($0.key)(\($0.value))" }.joined(separator: " "))
            if let first = table.first { print("PROBE \(key)[0]: \(first)") }
            // The width ratio is the field this probe exists for: count what the document declares.
            for name in ["ratios", "spacings", "kerning", "charOffsets"] {
                var vals: [String: Int] = [:]
                for row in table {
                    guard let v = row[name] else { continue }
                    if let arr = v as? [Any] {
                        vals[arr.map { "\($0)" }.joined(separator: ","), default: 0] += 1
                    } else {
                        vals["\(v)", default: 0] += 1
                    }
                }
                if !vals.isEmpty {
                    print("PROBE \(key).\(name) (\(vals.count) distinct): "
                        + vals.sorted { $0.value > $1.value }.prefix(6)
                            .map { "[\($0.key)]×\($0.value)" }.joined(separator: "  "))
                }
            }
        }
        // And what a SPAN carries, since that is what the builder reads.
        var spanKeys: [String: Int] = [:]
        var sample: [String: Any]?
        func walk(_ blocks: [[String: Any]]) {
            for b in blocks {
                if let spans = b["spans"] as? [[String: Any]] {
                    for s in spans {
                        for k in s.keys { spanKeys[k, default: 0] += 1 }
                        if sample == nil, (s["text"] as? String)?.isEmpty == false { sample = s }
                    }
                }
                for key in ["blocks", "cells", "rows", "children"] {
                    if let nested = b[key] as? [[String: Any]] { walk(nested) }
                    if let rows = b[key] as? [[[String: Any]]] { for r in rows { walk(r) } }
                }
            }
        }
        walk((root["blocks"] as? [[String: Any]]) ?? [])
        print("PROBE span fields    : " + spanKeys.sorted { $0.value > $1.value }
            .map { "\($0.key)(\($0.value))" }.joined(separator: " "))
        if let sample { print("PROBE span sample    : \(sample)") }
    }
}
