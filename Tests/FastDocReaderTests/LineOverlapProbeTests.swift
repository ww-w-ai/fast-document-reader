import XCTest
import AppKit
@testable import FastDocReader

/// Lines drawn ON TOP OF each other.
///
/// The line dump (`FMD_LINE_DUMP`) carries `y` alone, so two lines of a table row and two lines
/// genuinely painted over one another look identical in it. This one carries `x` and reports the
/// pairs whose rectangles actually intersect, which is the only way to tell them apart.
final class LineOverlapProbeTests: XCTestCase {

    func testOverlappingLines() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FMD_OVERLAP_PROBE"] else {
            throw XCTSkip("set FMD_OVERLAP_PROBE=<document>; FMD_OVERLAP_FROM/FMD_OVERLAP_TO are sheet numbers")
        }
        // stdout is not reliable here — this repo has already been bitten by a probe's summary
        // vanishing between xctest and the swift-testing runner. Collect and write a file.
        var report: [String] = []
        func say(_ line: String) { report.append(line); print(line) }
        defer {
            if let out = env["FMD_OVERLAP_OUT"] {
                try? report.joined(separator: "\n").appending("\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        let url = URL(fileURLWithPath: path)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        let w = CGFloat(Double(env["FMD_OVERLAP_W"] ?? "") ?? 1098)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: w, height: 640), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
        guard let lm = wc.textView.layoutManager, let tc = wc.textView.textContainer,
              let st = wc.textView.textStorage else { say("PROBE ABORTED"); return }
        lm.ensureLayout(for: tc)
        let d = wc.pageBandDelegate
        let pitch = d.pageContentHeight + d.band
        let from = Int(env["FMD_OVERLAP_FROM"] ?? "") ?? 1
        let to = Int(env["FMD_OVERLAP_TO"] ?? "") ?? from
        let top = from <= 0 ? -.greatestFiniteMagnitude : d.leadingBand + CGFloat(from - 1) * pitch
        let bottom = from <= 0 ? .greatestFiniteMagnitude : d.leadingBand + CGFloat(to) * pitch
        say("PROBE sheets \(from)...\(to)  y \(String(format: "%.1f", top))..\(String(format: "%.1f", bottom))")

        struct L { var r: NSRect; var text: String; var table: Bool; var loc: Int }
        var lines: [L] = []
        let ns = st.string as NSString
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, used, _, gr, _ in
            guard used.minY >= top, used.minY < bottom else { return }
            let cr = lm.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
            guard cr.location + cr.length <= ns.length else { return }
            let t = ns.substring(with: cr)
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return }
            let ps = st.attribute(.paragraphStyle, at: cr.location, effectiveRange: nil) as? NSParagraphStyle
            lines.append(L(r: used, text: t, table: ps?.textBlocks.first is NSTextTableBlock, loc: cr.location))
        }
        say("PROBE lines with text: \(lines.count)")

        // CENSUS: FMD_OVERLAP_FROM=0 walks the whole document, bucketed by sheet so the pairwise
        // test stays inside a page instead of going quadratic over every line in the file.
        if from <= 0 {
            var bySheet: [Int: [L]] = [:]
            for l in lines {
                bySheet[Int((l.r.minY - d.leadingBand) / pitch), default: []].append(l)
            }
            var perSheet: [(sheet: Int, pairs: Int)] = []
            for (sheet, ls) in bySheet {
                var n = 0
                for i in ls.indices {
                    for j in (i + 1)..<ls.count {
                        let inter = ls[i].r.intersection(ls[j].r)
                        if inter.width > 1, inter.height > 1 { n += 1 }
                    }
                }
                if n > 0 { perSheet.append((sheet + 1, n)) }
            }
            perSheet.sort { $0.pairs > $1.pairs }
            say("PROBE sheets with overlapping lines: \(perSheet.count) of \(bySheet.count)")
            say("PROBE worst: " + perSheet.prefix(20).map { "\($0.sheet):\($0.pairs)" }.joined(separator: " "))
            let runs = perSheet.map(\.sheet).sorted()
            say("PROBE affected sheets: " + runs.prefix(60).map(String.init).joined(separator: ","))
            return
        }

        var pairs = 0
        for i in lines.indices {
            for j in (i + 1)..<lines.count {
                let a = lines[i], b = lines[j]
                let hit = a.r.intersects(b.r)
                guard hit else { continue }
                let inter = a.r.intersection(b.r)
                // A shared edge is not an overlap; ask for real area on BOTH axes.
                guard inter.width > 1, inter.height > 1 else { continue }
                pairs += 1
                if pairs <= 20 {
                    say(String(format: "PROBE  overlap %.0fx%.0f  A(%.0f,%.0f %.0fx%.0f tbl=%@) |%@|",
                                 inter.width, inter.height,
                                 a.r.minX, a.r.minY, a.r.width, a.r.height,
                                 a.table ? "y" : "n", String(a.text.prefix(24)) + " @\(a.loc)"))
                    say(String(format: "PROBE                B(%.0f,%.0f %.0fx%.0f tbl=%@) |%@|",
                                 b.r.minX, b.r.minY, b.r.width, b.r.height,
                                 b.table ? "y" : "n", String(b.text.prefix(24)) + " @\(b.loc)"))
                }
            }
        }
        say("PROBE overlapping pairs: \(pairs)")
    }
}
