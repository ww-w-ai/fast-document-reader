import XCTest
import AppKit
@testable import FastDocReader

/// What the engine actually hands the builder, block by block, around one anchor.
///
/// An empty line on screen can be two very different things: a paragraph the DOCUMENT declares
/// empty, or a paragraph this reader manufactured for something it took out of the flow. Only the
/// block stream says which, and the answer decides whether the fix belongs in the reader or in the
/// height it gives a blank.
final class BlockStreamProbeTests: XCTestCase {

    func testBlocksAroundAnAnchor() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FMD_BLOCKS"] else { throw XCTSkip("set FMD_BLOCKS=<document>") }
        let anchor = env["FMD_BLOCKS_ANCHOR"] ?? ""
        let span = Int(env["FMD_BLOCKS_SPAN"] ?? "") ?? 12
        var report: [String] = []
        func say(_ s: String) { report.append(s) }
        defer {
            if let out = env["FMD_BLOCKS_OUT"] {
                try? report.joined(separator: "\n").appending("\n")
                    .write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let handle = try XCTUnwrap(RustOfficeDocumentHandle(data: data, extension: (path as NSString).pathExtension))
        let blocks = try XCTUnwrap(handle.officeContent(bytes: data)).blocks

        func describe(_ b: OfficeBlock, _ i: Int) -> String {
            switch b {
            case .paragraph(let spans, _, _, _, let f):
                let text = spans.map(\.text).joined()
                return String(format: "%5d para  spans%2d  size %@  before %@ after %@ lineH %@  |%@|",
                              i, spans.count,
                              spans.first?.fontSize.map { String(format: "%.1f", $0) } ?? "-",
                              f.spacingBefore.map { String(format: "%.1f", $0) } ?? "-",
                              f.spacingAfter.map { String(format: "%.1f", $0) } ?? "-",
                              f.lineHeight.map { String(describing: $0) } ?? "-",
                              String(text.replacingOccurrences(of: "\n", with: "⏎").prefix(46)))
            case .table: return String(format: "%5d TABLE", i)
            case .image: return String(format: "%5d image", i)
            default: return String(format: "%5d %@", i, String(describing: b).prefix(40) as CVarArg)
            }
        }

        var hit = -1
        if !anchor.isEmpty {
            for (i, b) in blocks.enumerated() {
                if case .paragraph(let spans, _, _, _, _) = b,
                   spans.map(\.text).joined().contains(anchor) { hit = i; break }
            }
        }
        say("PROBE blocks \(blocks.count)  anchor \"\(anchor)\" at \(hit)")
        let lo = hit < 0 ? 0 : max(0, hit - span)
        let hi = hit < 0 ? min(blocks.count, span * 2) : min(blocks.count, hit + span)
        for i in lo..<hi { say("PROBE " + describe(blocks[i], i)) }

        // And the census the page count actually turns on: every block that produces a line with
        // nothing on it, named by the kind that produced it.
        var byKind: [String: Int] = [:]
        func count(_ bs: [OfficeBlock]) {
            for b in bs {
                switch b {
                case .paragraph(let spans, _, _, _, _):
                    if spans.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        byKind["paragraph", default: 0] += 1
                    }
                case .heading(_, let spans, _, _, _, _):
                    if spans.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        byKind["heading", default: 0] += 1
                    }
                case .listItem(_, _, let spans, _, _, _, _, _, _):
                    if spans.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        byKind["listItem", default: 0] += 1
                    }
                case .table(let rows, _, _, _):
                    for row in rows { for cell in row { count(cell.blocks) } }
                default: break
                }
            }
        }
        count(blocks)
        for (k, v) in byKind.sorted(by: { $0.value > $1.value }) { say("PROBE empty \(k): \(v)") }
    }
}
