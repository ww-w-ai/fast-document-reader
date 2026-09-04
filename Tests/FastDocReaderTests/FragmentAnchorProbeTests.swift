import XCTest
import AppKit
@testable import FastDocReader

/// Every line fragment in a vertical window around one anchor, with the attributes that decide its
/// height — so a gap the reference renderer does not draw can be charged to the exact fragment and
/// the exact paragraph-style field that produced it, rather than to "the table" or "the blank".
///
///     FMD_FRAG_PROBE=<document> FMD_FRAG_ANCHOR="<text>" [FMD_FRAG_BEFORE=140 FMD_FRAG_AFTER=40] \
///     [FMD_FRAG_OUT=<file>] swift test --filter FragmentAnchorProbeTests
///
/// Same screen door as `EmptyParagraphProbeTests` (invariant 29). Heights are the screen arm's;
/// the print arm re-lays out, but a cell's own padding and a paragraph's own spacing are identical
/// in both.
final class FragmentAnchorProbeTests: XCTestCase {

    func testFragmentsAroundAnchor() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FMD_FRAG_PROBE"] else { throw XCTSkip("set FMD_FRAG_PROBE=<document>") }
        let anchor = env["FMD_FRAG_ANCHOR"] ?? ""
        let before = CGFloat(Double(env["FMD_FRAG_BEFORE"] ?? "") ?? 140)
        let after = CGFloat(Double(env["FMD_FRAG_AFTER"] ?? "") ?? 40)
        var report: [String] = []
        func say(_ s: String) { report.append(s); print(s) }
        defer {
            if let out = env["FMD_FRAG_OUT"] {
                try? report.joined(separator: "\n").appending("\n")
                    .write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        let url = URL(fileURLWithPath: path)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1098, height: 640), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
        if env["FMD_FRAG_PRINT"] != nil {
            // The PRINT arm: the same three steps `makePrintOperation` takes before handing the view
            // to AppKit, so a gap that exists only on paper can be seen in its fragments.
            wc.beginPrintLayout()
            wc.settlePagedTablesFully()
            wc.applyTrailingFooterBand()
            say("PROBE print arm: sheets \(wc.printSheets.count)")
        }
        guard let lm = wc.textView.layoutManager, let tc = wc.textView.textContainer,
              let st = wc.textView.textStorage else { say("PROBE ABORTED"); return }
        lm.ensureLayout(for: tc)
        let ns = st.string as NSString
        // `FMD_FRAG_NTH=2` takes the second occurrence — a manual's index quotes its own headings.
        let nth = Int(env["FMD_FRAG_NTH"] ?? "") ?? 1
        var hit = ns.range(of: anchor)
        // `FMD_FRAG_AT=<char>` anchors on a character index instead — the census names an EMPTY
        // fragment's location this way, since it has no text to anchor on.
        if let at = Int(env["FMD_FRAG_AT"] ?? ""), at < ns.length { hit = NSRange(location: at, length: 1) }
        for _ in 1..<max(1, nth) where hit.location != NSNotFound {
            let from = hit.location + hit.length
            hit = ns.range(of: anchor, range: NSRange(location: from, length: ns.length - from))
        }
        let anchorRect: NSRect
        if hit.location != NSNotFound {
            anchorRect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: hit.location), effectiveRange: nil)
            say(String(format: "PROBE anchor at char %d  y=%.2f", hit.location, anchorRect.minY))
        } else {
            say("PROBE anchor not found: \(anchor)"); anchorRect = .zero
        }
        let window = (anchorRect.minY - before)...(anchorRect.minY + after)
        for run in wc.columnRunRanges() {
            say("PROBE column run chars \(run.range.location)+\(run.range.length) count \(run.layout.count) spacing \(run.layout.spacing) widths \(run.layout.widths)")
        }
        say("PROBE sheets screen \(wc.pageBandDelegate.pageContentHeight) band \(wc.pageBandDelegate.band) leading \(wc.pageBandDelegate.leadingBand)")
        say("PROBE column placements \(wc.pageBandDelegate.columnPlacements.count)")

        func describe(_ ps: NSParagraphStyle?) -> String {
            guard let ps else { return "no-style" }
            var s = String(format: "before %.1f after %.1f min %.1f max %.1f mult %.2f spacing %.1f",
                           ps.paragraphSpacingBefore, ps.paragraphSpacing, ps.minimumLineHeight,
                           ps.maximumLineHeight, ps.lineHeightMultiple, ps.lineSpacing)
            if let tb = ps.textBlocks.last as? NSTextTableBlock {
                s += String(format: "  CELL%@ row %d  pad t%.1f b%.1f  margin t%.1f b%.1f",
                            ps.textBlocks.count > 1 ? "x\(ps.textBlocks.count)" : "", tb.startingRow,
                            tb.width(for: .padding, edge: .minY), tb.width(for: .padding, edge: .maxY),
                            tb.width(for: .margin, edge: .minY), tb.width(for: .margin, edge: .maxY))
                if tb.contentWidthValueType == .absoluteValueType || tb.contentWidth > 0 {
                    s += String(format: " minH? %.1f", tb.value(for: .minimumHeight))
                }
            } else if !ps.textBlocks.isEmpty {
                s += "  block(\(type(of: ps.textBlocks.last!)))"
            }
            return s
        }

        if env["FMD_FRAG_CENSUS"] != nil {
            // Every fragment in the document, charged to the (emptiness, cell, font, height, declared
            // minimum) that produced it — the whole-document weight of what the window shows once.
            var census: [String: (n: Int, pt: CGFloat)] = [:]
            var example: [String: String] = [:]
            lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, _, _, gr, _ in
                let cr = lm.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
                guard cr.location < ns.length else { return }
                let empty = ns.substring(with: cr).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let attrs = st.attributes(at: cr.location, effectiveRange: nil)
                let ps = attrs[.paragraphStyle] as? NSParagraphStyle
                let font = attrs[.font] as? NSFont
                let key = String(format: "%@ %@ %@ %-24@ h %5.1f min %5.1f max %5.1f",
                                 empty ? "EMPTY" : "text ", (ps?.textBlocks.last is NSTextTableBlock) ? ((ps?.textBlocks.count ?? 0) > 1 ? "nest" : "cell") : "body",
                                 ps == nil ? "NOSTYLE" : "styled ", (font?.fontName ?? "-") as NSString,
                                 rect.height, ps?.minimumLineHeight ?? -1, ps?.maximumLineHeight ?? -1)
                var e = census[key] ?? (0, 0); e.n += 1; e.pt += rect.height; census[key] = e
                if attrs[MDAttr.tableKeepsWhole] != nil {
                    var k = census["KEEPSWHOLE fragments (tables the source said not to split)"] ?? (0, 0)
                    k.n += 1; k.pt += rect.height; census["KEEPSWHOLE fragments (tables the source said not to split)"] = k
                }
                if example[key] == nil {
                    example[key] = empty ? "@\(cr.location)"
                        : String(ns.substring(with: cr).replacingOccurrences(of: "\n", with: "⏎").prefix(36))
                }
            }
            let sheet = max(1, wc.pageBandDelegate.pageContentHeight)
            say(String(format: "PROBE census sheet height %.1f", sheet))
            for (k, v) in census.sorted(by: { $0.value.pt > $1.value.pt }).prefix(60) {
                say(String(format: "PROBE %@  n %6d  %9.0fpt  %6.1f sheets  |%@|", k as NSString, v.n, v.pt, v.pt / sheet,
                           (example[k] ?? "") as NSString))
            }
            return
        }
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, used, _, gr, _ in
            guard window.contains(rect.minY) || window.contains(rect.maxY) else { return }
            let cr = lm.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
            guard cr.location < ns.length else { return }
            let raw = ns.substring(with: cr)
            let text = raw.replacingOccurrences(of: "\n", with: "⏎")
                .replacingOccurrences(of: "\u{FFFC}", with: "⦿")
            let attrs = st.attributes(at: cr.location, effectiveRange: nil)
            let font = attrs[.font] as? NSFont
            var marks: [String] = []
            if attrs[MDAttr.startsPage] != nil { marks.append("startsPage") }
            if attrs[MDAttr.anchoredObjects] != nil { marks.append("anchored") }
            if attrs[MDAttr.sectionIndex] != nil { marks.append("section") }
            if attrs[MDAttr.tableKeepsWhole] != nil { marks.append("keepsWhole") }
            if let p = wc.pageBandDelegate.columnPlacements[cr.location] {
                marks.append(String(format: "col->(%.0f,%.0f)", p.x, p.y))
            }
            say(String(format: "PROBE y %8.2f h %6.2f used %6.2f  chars %6d+%-4d  %@ %.1f  %@ %@ |%@|",
                       rect.minY, rect.height, used.height, cr.location, cr.length,
                       (font?.fontName ?? "-") as NSString, font?.pointSize ?? 0,
                       describe(attrs[.paragraphStyle] as? NSParagraphStyle) as NSString,
                       marks.joined(separator: ",") as NSString,
                       String(text.prefix(40)) as NSString))
        }
    }
}
