import XCTest
import AppKit
@testable import FastDocReader

/// Cells whose SHORT label wrapped — the row-stretch signature.
///
/// A one- or two-word label that needs one line in the source and two here doubles its row, and a
/// table of such rows doubles a page. The cause is measurement, not the table: the face this
/// machine resolves for the declared one is wider, so the label misses the cell's own content width
/// by a point or two and the typesetter breaks it (invariant 146).
final class CellLabelWrapProbeTests: XCTestCase {

    func testShortLabelsThatWrapped() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FMD_CELL_WRAP"] else { throw XCTSkip("set FMD_CELL_WRAP=<document>") }
        var report: [String] = []
        func say(_ s: String) { report.append(s); print(s) }
        defer {
            if let out = env["FMD_CELL_WRAP_OUT"] {
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
        let d = wc.pageBandDelegate
        let pitch = max(1, d.pageContentHeight + d.band)

        // Fragment runs, keyed by the PARAGRAPH they belong to: a paragraph that produced more than
        // one fragment wrapped.
        struct Run { var lines = 0; var text = ""; var width: CGFloat = 0; var content: CGFloat = 0
                     var font = ""; var size: CGFloat = 0; var head: CGFloat = 0; var sheet = 0 }
        var runs: [Int: Run] = [:]
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { _, used, _, gr, _ in
            let cr = lm.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
            guard cr.location < ns.length else { return }
            let ps = st.attribute(.paragraphStyle, at: cr.location, effectiveRange: nil) as? NSParagraphStyle
            guard let cell = ps?.textBlocks.first as? NSTextTableBlock else { return }
            let para = ns.paragraphRange(for: NSRange(location: cr.location, length: 0)).location
            var run = runs[para] ?? Run()
            run.lines += 1
            run.text += ns.substring(with: cr).trimmingCharacters(in: .whitespacesAndNewlines)
            run.width = max(run.width, used.width)
            run.content = cell.contentWidth
            run.head = ps?.headIndent ?? 0
            run.sheet = Int((((used.minY - d.leadingBand) / pitch) + 1e-6).rounded(.down))
            if let f = st.attribute(.font, at: cr.location, effectiveRange: nil) as? NSFont {
                run.font = f.fontName; run.size = f.pointSize
            }
            runs[para] = run
        }
        let wrapped = runs.values.filter { $0.lines > 1 && $0.text.count <= 8 }
        say("PROBE cell paragraphs: \(runs.count)   short labels that wrapped: \(wrapped.count)")
        for r in wrapped.sorted(by: { $0.sheet < $1.sheet }).prefix(30) {
            say(String(format: "PROBE  sheet %3d  lines %d  |%@|  drawn %.1f  content %.1f  head %.1f  %@@%.1f",
                       r.sheet, r.lines, r.text as NSString, r.width, r.content, r.head,
                       r.font as NSString, r.size))
        }
    }
}
