import XCTest
import AppKit
@testable import FastDocReader

/// What the SCREEN actually lays out for a real document — the path a reader looks at.
///
/// This app makes the same document three different ways: the screen's text view, `--pdf`'s print
/// path, and `--extract`'s serializer. They share a reader but not a route, so a number from one of
/// them is not a claim about the others; judging fidelity from the PDF alone was how a screen defect
/// and a print defect were argued about as if they were one thing.
///
/// `FMD_SCREEN_PROBE=<file>`. Skipped by default, following the `FMD_HEADER_FOOTER_PROBE` family.
final class ScreenPathRealFileProbeTests: XCTestCase {
    func testWhatTheScreenLaysOut() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_SCREEN_PROBE"] else {
            throw XCTSkip("set FMD_SCREEN_PROBE=<document> to measure the screen path")
        }
        let url = URL(fileURLWithPath: path)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 820, height: 640), display: false)

        // The same settle the print path uses, so the two are compared at the same moment.
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)

        let storage = wc.textView.textStorage?.length ?? 0
        let lm = wc.textView.layoutManager
        let container = wc.textView.textContainer
        var laidOut = 0
        if let lm, let container {
            lm.ensureLayout(for: container)
            laidOut = lm.glyphRange(for: container).length
        }
        let height = wc.textView.frame.height
        print("PROBE storage chars      : \(storage)")
        print("PROBE glyphs laid out    : \(laidOut)")
        print("PROBE text view height   : \(Int(height)) pt")
        let d = wc.pageBandDelegate
        let pitch = d.pageContentHeight + d.band
        if pitch > 0 {
            print("PROBE page pitch         : \(String(format: "%.2f", pitch)) pt")
            print("PROBE sheets by height   : \(Int((height / pitch).rounded(.up)))")
        }
        // GEOMETRY — what a sheet actually offers the flow, so this reader's page can be compared
        // against another renderer's page rather than against its own sheet count.
        print("PROBE page content h     : \(String(format: "%.2f", d.pageContentHeight)) pt")
        print("PROBE page band          : \(String(format: "%.2f", d.band)) pt")
        if let container { print("PROBE container width    : \(String(format: "%.2f", container.size.width)) pt") }

        // LINE FRAGMENTS — the histogram that says whether height comes from many lines or tall ones.
        if let lm, let container {
            var heights: [Double] = []
            var idx = 0
            let total = lm.numberOfGlyphs
            // Chars per line is what says whether a column holds as much text as the document's own
            // renderer puts in it — a count of fragments alone cannot tell "more lines" from
            // "lines that break early", and an EMPTY fragment is neither.
            var nonEmpty = 0, charsOnLines = 0, usedWidthSum = 0.0
            var widestSeen = 0.0
            let str = wc.textView.textStorage?.string ?? ""
            let ns = str as NSString
            while idx < total {
                var eff = NSRange(location: 0, length: 0)
                let r = lm.lineFragmentRect(forGlyphAt: idx, effectiveRange: &eff)
                heights.append(Double(r.height))
                let used = lm.lineFragmentUsedRect(forGlyphAt: idx, effectiveRange: nil)
                let chars = lm.characterRange(forGlyphRange: eff, actualGlyphRange: nil)
                var visible = 0
                if chars.location + chars.length <= ns.length {
                    let t = ns.substring(with: chars)
                    visible = t.filter { !$0.isNewline && !$0.isWhitespace }.count
                }
                if visible > 0 {
                    nonEmpty += 1
                    charsOnLines += visible
                    usedWidthSum += Double(used.width)
                    widestSeen = max(widestSeen, Double(used.width))
                }
                idx = eff.length > 0 ? eff.location + eff.length : idx + 1
            }
            // PER SHEET — a page that carries one line and then stops is invisible in any total.
            // The sheet a fragment belongs to is decided by the same pitch the band rule uses.
            var perSheet: [Int: Int] = [:]
            var idx2 = 0
            while idx2 < total {
                var eff = NSRange(location: 0, length: 0)
                let r = lm.lineFragmentRect(forGlyphAt: idx2, effectiveRange: &eff)
                let chars = lm.characterRange(forGlyphRange: eff, actualGlyphRange: nil)
                var visible = 0
                if chars.location + chars.length <= ns.length {
                    visible = ns.substring(with: chars).filter { !$0.isNewline && !$0.isWhitespace }.count
                }
                if visible > 0, pitch > 0 {
                    perSheet[Int(r.midY / pitch), default: 0] += visible
                }
                idx2 = eff.length > 0 ? eff.location + eff.length : idx2 + 1
            }
            let sheetCount = Int((height / pitch).rounded(.up))
            let counts = (0..<max(sheetCount, 1)).map { perSheet[$0] ?? 0 }
            let nearEmpty = counts.enumerated().filter { $0.element < 80 }
            print("PROBE sheets                  : \(counts.count)  chars/sheet mean \(counts.reduce(0,+) / max(counts.count,1))")
            print("PROBE near-empty sheets (<80c): \(nearEmpty.count)")
            print("PROBE first 20 near-empty     : " + nearEmpty.prefix(20).map { "\($0.offset + 1)(\($0.element))" }.joined(separator: " "))
            print("PROBE sheets 15-25 char counts: " + (15...25).map { "\($0):\(counts.indices.contains($0 - 1) ? counts[$0 - 1] : -1)" }.joined(separator: " "))

            // WHAT KIND of line each height belongs to. A mean line cost says the document is
            // taller than another renderer's without saying WHERE, and prose and table cells are
            // measured by different rules — `NSParagraphStyle.textBlocks` is what tells them apart.
            var inTable: [Int: Int] = [:], outsideTable: [Int: Int] = [:]
            var tableHeight = 0.0, proseHeight = 0.0
            var sampleByBucket: [Int: String] = [:]
            var idx3 = 0
            while idx3 < total {
                var eff = NSRange(location: 0, length: 0)
                let r = lm.lineFragmentRect(forGlyphAt: idx3, effectiveRange: &eff)
                let cr = lm.characterRange(forGlyphRange: eff, actualGlyphRange: nil)
                var cell = false
                if cr.length > 0, cr.location < ns.length,
                   let ps = wc.textView.textStorage?.attribute(.paragraphStyle, at: cr.location,
                                                               effectiveRange: nil) as? NSParagraphStyle {
                    cell = !ps.textBlocks.isEmpty
                }
                let bucket = Int((Double(r.height) / 2).rounded()) * 2
                if cell { inTable[bucket, default: 0] += 1; tableHeight += Double(r.height) }
                else { outsideTable[bucket, default: 0] += 1; proseHeight += Double(r.height) }
                if cell, sampleByBucket[bucket] == nil, cr.length > 2,
                   cr.location + cr.length <= ns.length {
                    sampleByBucket[bucket] = String(ns.substring(with: cr).prefix(28))
                }
                idx3 = eff.length > 0 ? eff.location + eff.length : idx3 + 1
            }
            let nCell = inTable.values.reduce(0, +), nProse = outsideTable.values.reduce(0, +)
            print("PROBE in a table cell    : \(nCell) fragments, \(String(format: "%.0f", tableHeight)) pt"
                + (nCell > 0 ? "  mean \(String(format: "%.2f", tableHeight / Double(nCell)))" : ""))
            print("PROBE outside a table    : \(nProse) fragments, \(String(format: "%.0f", proseHeight)) pt"
                + (nProse > 0 ? "  mean \(String(format: "%.2f", proseHeight / Double(nProse)))" : ""))
            print("PROBE cell heights       : " + inTable.sorted { $0.value > $1.value }.prefix(8)
                .map { "\($0.key)pt×\($0.value)" }.joined(separator: " "))
            print("PROBE prose heights      : " + outsideTable.sorted { $0.value > $1.value }.prefix(8)
                .map { "\($0.key)pt×\($0.value)" }.joined(separator: " "))
            for (b, t) in sampleByBucket.sorted(by: { $0.key < $1.key }).prefix(4) {
                print("PROBE   cell \(b)pt sample : \(t.replacingOccurrences(of: "\n", with: "⏎"))")
            }

            print("PROBE non-empty fragments: \(nonEmpty)  chars on them \(charsOnLines)")
            if nonEmpty > 0 {
                print("PROBE chars per line     : \(String(format: "%.1f", Double(charsOnLines) / Double(nonEmpty)))")
                print("PROBE used width mean    : \(String(format: "%.1f", usedWidthSum / Double(nonEmpty))) pt  max \(String(format: "%.1f", widestSeen)) pt")
            }
            let sum = heights.reduce(0, +)
            print("PROBE line fragments     : \(heights.count)")
            print("PROBE fragment height sum: \(String(format: "%.0f", sum)) pt")
            var buckets: [Int: Int] = [:]
            for h in heights { buckets[Int((h / 2).rounded()) * 2, default: 0] += 1 }
            let top = buckets.sorted { $0.value > $1.value }.prefix(10)
            print("PROBE fragment histogram : " + top.map { "\($0.key)pt×\($0.value)" }.joined(separator: " "))
            _ = container
        }

        // PER-SHEET TEXT, to a file when asked. A page count says the document is longer than
        // another renderer's; only the text of each sheet says WHERE it got longer, and this is the
        // screen's own answer rather than the print path's (they are different routes).
        if let dump = ProcessInfo.processInfo.environment["FMD_SHEET_TEXT_OUT"],
           let lm, let container, pitch > 0 {
            let ns = (wc.textView.textStorage?.string ?? "") as NSString
            var perSheet: [Int: String] = [:]
            var idx = 0
            while idx < lm.numberOfGlyphs {
                var eff = NSRange(location: 0, length: 0)
                let r = lm.lineFragmentRect(forGlyphAt: idx, effectiveRange: &eff)
                let cr = lm.characterRange(forGlyphRange: eff, actualGlyphRange: nil)
                if cr.location + cr.length <= ns.length {
                    perSheet[Int(r.midY / pitch), default: ""] += ns.substring(with: cr)
                }
                idx = eff.length > 0 ? eff.location + eff.length : idx + 1
            }
            let sheetCount = Int((height / pitch).rounded(.up))
            let text = (0..<max(sheetCount, 1)).map { perSheet[$0] ?? "" }.joined(separator: "\u{0C}")
            try? text.write(toFile: dump, atomically: true, encoding: .utf8)
            print("PROBE sheet text written : \(dump)  (\(sheetCount) sheets)")
            _ = container
        }

        // The tail is what says whether the document ENDS where the document ends.
        let text = wc.textView.textStorage?.string ?? ""
        print("PROBE storage tail       : \(String(text.suffix(80)).replacingOccurrences(of: "\n", with: "⏎"))")
    }
}
