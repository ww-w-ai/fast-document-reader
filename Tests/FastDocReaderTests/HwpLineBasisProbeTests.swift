import XCTest
@testable import FastDocReader

/// What a real HWP DECLARES about line height, in the export's own field names.
///
/// This reader resolves a percent line height as `basis × percent / 100` and installs it as a
/// FLOOR. rhwp — the reference renderer for this format, and the parser this reader links — only
/// computes that product when the stored line metrics are unusable; normally it uses what Hangul
/// itself wrote into the file. Measured on the same document the two disagree by a page count of
/// 534 to 394, so the declarations have to be read rather than reasoned about.
///
/// `FMD_HWP_LINE_BASIS=<file>`. Skipped by default, following the `FMD_HWP_STYLE_PROBE` family.
final class HwpLineBasisProbeTests: XCTestCase {
    func testWhatTheDocumentDeclaresAboutLineHeight() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_HWP_LINE_BASIS"] else {
            throw XCTSkip("set FMD_HWP_LINE_BASIS=<document> to measure the line-height basis")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let json = HwpReader.exportDocumentJSON(data),
              let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let blocks = root["blocks"] as? [[String: Any]] else {
            return XCTFail("could not export/parse that document")
        }

        var paragraphs = 0
        var byType: [String: Int] = [:]
        var percentValues: [Int: Int] = [:]
        var basisHistogram: [Int: Int] = [:]        // resolved floor, rounded to the point
        var mixed = 0, sized = 0
        var sampleShapes: [String] = []
        var totalChars = 0
        var floorTimesChars = 0.0                    // Σ (resolved floor × characters)

        func walk(_ blocks: [[String: Any]]) {
            for b in blocks {
                if let spans = b["spans"] as? [[String: Any]] {
                    paragraphs += 1
                    let sizes: [(Double, Int)] = spans.compactMap {
                        guard let v = $0["size"] as? Double, v > 0 else { return nil }
                        return (v / 100.0, ($0["text"] as? String)?.count ?? 0)
                    }
                    let chars = spans.reduce(0) { $0 + (($1["text"] as? String)?.count ?? 0) }
                    totalChars += chars
                    let base = (b["baseSizePt"] as? Double) ?? 10.0
                    let maxSize = sizes.map(\.0).max() ?? base
                    if !sizes.isEmpty {
                        sized += 1
                        let wt = chars > 0
                            ? sizes.reduce(0.0) { $0 + $1.0 * Double($1.1) } / Double(max(chars, 1))
                            : maxSize
                        if maxSize > wt * 1.02 { mixed += 1 }
                    }
                    if let lh = b["lineHeight"] as? [String: Any] {
                        if sampleShapes.count < 3 { sampleShapes.append("\(lh)") }
                        // The export tags the variant by its key, so read whichever is present.
                        for (k, v) in lh {
                            byType[k, default: 0] += 1
                            let value = (v as? Double) ?? ((v as? [String: Any])?["value"] as? Double) ?? 0
                            if k.lowercased().contains("percent") || k.lowercased().contains("multiple") {
                                percentValues[Int(value.rounded()), default: 0] += 1
                                let floor = maxSize * value / (value > 10 ? 100.0 : 1.0)
                                basisHistogram[Int(floor.rounded()), default: 0] += 1
                                floorTimesChars += floor * Double(chars)
                            } else if value > 0 {
                                basisHistogram[Int(value.rounded()), default: 0] += 1
                                floorTimesChars += value * Double(chars)
                            }
                        }
                    } else {
                        byType["<none>", default: 0] += 1
                    }
                }
                for key in ["blocks", "cells", "rows", "children"] {
                    if let nested = b[key] as? [[String: Any]] { walk(nested) }
                    if let rows = b[key] as? [[[String: Any]]] { for r in rows { walk(r) } }
                }
            }
        }
        walk(blocks)

        print("PROBE paragraphs                 : \(paragraphs)   chars \(totalChars)")
        print("PROBE lineHeight variants        : " + byType.sorted { $0.value > $1.value }
            .map { "\($0.key)×\($0.value)" }.joined(separator: " "))
        print("PROBE sample shapes              : \(sampleShapes.joined(separator: " | "))")
        print("PROBE percent values             : " + percentValues.sorted { $0.value > $1.value }
            .prefix(8).map { "\($0.key)×\($0.value)" }.joined(separator: " "))
        print("PROBE resolved floor histogram   : " + basisHistogram.sorted { $0.value > $1.value }
            .prefix(10).map { "\($0.key)pt×\($0.value)" }.joined(separator: " "))
        if totalChars > 0 {
            print("PROBE char-weighted floor        : \(String(format: "%.2f", floorTimesChars / Double(totalChars))) pt")
        }
        print("PROBE mixed-size paragraphs      : \(mixed) of \(sized) sized")
    }
}
