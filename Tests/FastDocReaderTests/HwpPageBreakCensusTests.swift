import XCTest
@testable import FastDocReader

/// How many page breaks this reader believes a real HWP declares, and WHICH signal declared them.
///
/// A break the document did not ask for costs a whole sheet: the page it opens carries whatever
/// spilled onto it and nothing else. Measured on the administrative manual, 85 of 534 sheets carry
/// under 80 characters while rhwp renders the same document in 394 pages, so the two signals this
/// reader reads (`breakBefore`, and the style's `pageBreakBefore`) have to be counted separately
/// before either is trusted.
///
/// `FMD_HWP_BREAK_CENSUS=<file>`. Skipped by default, following the `FMD_HWP_STYLE_PROBE` family.
final class HwpPageBreakCensusTests: XCTestCase {
    func testWhichSignalDeclaresAPageBreak() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_HWP_BREAK_CENSUS"] else {
            throw XCTSkip("set FMD_HWP_BREAK_CENSUS=<document> to count declared page breaks")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let json = HwpReader.exportDocumentJSON(data),
              let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let blocks = root["blocks"] as? [[String: Any]] else {
            return XCTFail("could not export/parse that document")
        }

        var paras = 0
        var breakBefore: [String: Int] = [:]
        var styleFlag = 0, both = 0, onlyStyle = 0
        var styleNamesWithFlag: [String: Int] = [:]
        var samples: [String] = []

        func walk(_ blocks: [[String: Any]]) {
            for b in blocks {
                if b["spans"] != nil {
                    paras += 1
                    let bb = (b["breakBefore"] as? String) ?? "<none>"
                    breakBefore[bb, default: 0] += 1
                    let flag = (b["pageBreakBefore"] as? Bool) == true
                    if flag {
                        styleFlag += 1
                        styleNamesWithFlag[(b["styleName"] as? String)
                            ?? (b["styleLocalName"] as? String) ?? "<unnamed>", default: 0] += 1
                        if bb == "page" || bb == "section" { both += 1 } else { onlyStyle += 1 }
                        if samples.count < 6 {
                            let t = (b["spans"] as? [[String: Any]])?
                                .compactMap { $0["text"] as? String }.joined() ?? ""
                            samples.append("[\(bb)] \(t.prefix(38))")
                        }
                    }
                }
                for key in ["blocks", "cells", "rows", "children"] {
                    if let nested = b[key] as? [[String: Any]] { walk(nested) }
                    if let rows = b[key] as? [[[String: Any]]] { for r in rows { walk(r) } }
                }
            }
        }
        walk(blocks)

        print("PROBE paragraphs                 : \(paras)")
        print("PROBE breakBefore values         : " + breakBefore.sorted { $0.value > $1.value }
            .map { "\($0.key)×\($0.value)" }.joined(separator: " "))
        print("PROBE pageBreakBefore == true    : \(styleFlag)   (also breakBefore page/section: \(both), style ONLY: \(onlyStyle))")
        print("PROBE styles carrying the flag   : " + styleNamesWithFlag.sorted { $0.value > $1.value }
            .prefix(8).map { "\($0.key)×\($0.value)" }.joined(separator: " "))
        for s in samples { print("PROBE   flagged sample: \(s)") }
    }
}
