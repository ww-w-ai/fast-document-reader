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
        let content = try XCTUnwrap(handle.officeContent(bytes: data))
        let blocks = content.blocks

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
            case .image(let id, let size, _): return String(format: "%5d image %@ %.0fx%.0f", i, id as NSString, size.width, size.height)
            default: return String(format: "%5d %@", i, String(describing: b).prefix(40) as CVarArg)
            }
        }

        var hit = -1
        // `FMD_BLOCKS_NTH=2` takes the second paragraph holding the anchor — a manual's contents
        // quote its own headings, so the first hit is usually the index, not the page.
        var remaining = Int(env["FMD_BLOCKS_NTH"] ?? "") ?? 1
        if !anchor.isEmpty {
            for (i, b) in blocks.enumerated() {
                if case .paragraph(let spans, _, _, _, _) = b,
                   spans.map(\.text).joined().contains(anchor) {
                    remaining -= 1
                    if remaining == 0 { hit = i; break }
                }
            }
        }
        say("PROBE blocks \(blocks.count)  anchor \"\(anchor)\" at \(hit)")
        say(String(format: "PROBE page content %@x%@  margins L %@ R %@ T %@ B %@  default body %.1f",
                   content.pageContentWidth.map { String(format: "%.2f", $0) } ?? "-",
                   content.pageContentHeight.map { String(format: "%.2f", $0) } ?? "-",
                   content.pageMarginLeft.map { String(format: "%.2f", $0) } ?? "-",
                   content.pageMarginRight.map { String(format: "%.2f", $0) } ?? "-",
                   content.pageMarginTop.map { String(format: "%.2f", $0) } ?? "-",
                   content.pageMarginBottom.map { String(format: "%.2f", $0) } ?? "-",
                   content.defaultBodyFontSize))
        for (i, section) in content.sections.enumerated() {
            let paper = section.paper.map { String(format: "content %.1fx%.1f margins L%.1f T%.1f R%.1f B%.1f paper %.1fx%.1f",
                                                     $0.contentWidth, $0.contentHeight, $0.marginLeft, $0.marginTop,
                                                     $0.marginRight, $0.marginBottom, $0.paperWidth, $0.paperHeight) } ?? "no paper"
            say("PROBE section \(i) start block \(i < content.sectionStartBlocks.count ? content.sectionStartBlocks[i] : -1)  \(paper)")
        }
        let lo = hit < 0 ? 0 : max(0, hit - span)
        let hi = hit < 0 ? min(blocks.count, span * 2) : min(blocks.count, hit + span)
        let breaks = Set(content.pageBreakBlocks), sections = Set(content.sectionStartBlocks)
        for i in lo..<hi {
            var marks: [String] = []
            if breaks.contains(i) { marks.append("PAGEBREAK") }
            if sections.contains(i) { marks.append("SECTION") }
            say("PROBE " + describe(blocks[i], i) + (marks.isEmpty ? "" : "  <" + marks.joined(separator: ",") + ">"))
        }
        // The objects pinned to a page through a block in the window — what a zero-height anchor
        // paragraph actually stands for.
        for (n, a) in content.anchoredObjects.enumerated() where a.blockIndex >= lo && a.blockIndex < hi {
            let kind: String
            switch a.object.content {
            case .image: kind = "image"
            case .drawing: kind = "drawing"
            case .vector(let g): kind = "vector paths \(g.paths.count)"
            case .text(let b): kind = "text blocks \(b.count)"
            }
            say(String(format: "PROBE anchored #%d at block %d frame (%.1f,%.1f %.1fx%.1f) %@ paraAnchor %@", n, a.blockIndex,
                       a.object.frame.minX, a.object.frame.minY, a.object.frame.width, a.object.frame.height,
                       kind as NSString, a.paragraphAnchor == nil ? "-" : "yes"))
        }

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
