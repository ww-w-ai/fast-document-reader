import XCTest
import AppKit
@testable import FastDocReader

/// Empty body paragraphs, and what each of them is FOR.
///
/// The reference renderer draws 521 of them on the 편람; this reader draws 1,483. An empty paragraph
/// costs a full line box, so 962 of them is roughly 28 sheets — and they are invisible in every
/// aggregate because the page simply "runs long". This counts them apart by the marker they carry,
/// which is what says whether the line is the document's own blank line or a placeholder this
/// reader left behind when it took an object out of the flow.
final class EmptyParagraphProbeTests: XCTestCase {

    func testEmptyParagraphs() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FMD_EMPTY_PARA_PROBE"] else {
            throw XCTSkip("set FMD_EMPTY_PARA_PROBE=<document>")
        }
        var report: [String] = []
        func say(_ s: String) { report.append(s); print(s) }
        defer {
            if let out = env["FMD_EMPTY_PARA_OUT"] {
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
        guard let lm = wc.textView.layoutManager, let tc = wc.textView.textContainer,
              let st = wc.textView.textStorage else { say("PROBE ABORTED"); return }
        lm.ensureLayout(for: tc)
        let ns = st.string as NSString

        var kinds: [String: (n: Int, pt: CGFloat)] = [:]
        func charge(_ k: String, _ h: CGFloat) {
            var e = kinds[k] ?? (0, 0); e.n += 1; e.pt += h; kinds[k] = e
        }
        var totalEmpty = 0
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, used, _, gr, _ in
            let cr = lm.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
            guard cr.location < ns.length else { return }
            let text = ns.substring(with: cr).trimmingCharacters(in: .whitespacesAndNewlines)
            let inCellNow = (st.attribute(.paragraphStyle, at: cr.location, effectiveRange: nil)
                             as? NSParagraphStyle)?.textBlocks.first is NSTextTableBlock
            guard text.isEmpty else {
                charge((inCellNow ? "cell" : "body") + " / a line with text on it", rect.height)
                return
            }
            totalEmpty += 1
            let ps = st.attribute(.paragraphStyle, at: cr.location, effectiveRange: nil) as? NSParagraphStyle
            let inCell = ps?.textBlocks.first is NSTextTableBlock
            var key = inCell ? "cell" : "body"
            if st.attribute(MDAttr.anchoredObjects, at: cr.location, effectiveRange: nil) != nil {
                key += " / anchored-object placeholder"
            } else if st.attribute(MDAttr.startsPage, at: cr.location, effectiveRange: nil) != nil {
                key += " / page break"
            } else if st.attribute(MDAttr.sectionIndex, at: cr.location, effectiveRange: nil) != nil {
                key += " / section start"
            } else {
                key += " / the document's own blank line"
            }
            charge(key, rect.height)
        }
        say("PROBE empty line fragments: \(totalEmpty)")
        for (k, v) in kinds.sorted(by: { $0.value.pt > $1.value.pt }) {
            say(String(format: "PROBE   %-46@ %5d  %8.0fpt = %5.1f sheets",
                       k as NSString, v.n, v.pt, v.pt / max(1, wc.pageBandDelegate.pageContentHeight)))
        }
    }
}
