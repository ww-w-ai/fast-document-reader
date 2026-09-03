import XCTest
import AppKit
@testable import FastDocReader

/// One sheet's lines with the attributes that DECIDE their geometry — the font, the paragraph's own
/// line-height rule, and, for a cell, the width the grid gave it.
///
/// The line dump carries `y`, height and text, which is enough to see that a row is too tall and
/// never enough to say why. `FMD_LINE_ATTR=<document>`, `FMD_LINE_ATTR_SHEET=<n>`,
/// `FMD_LINE_ATTR_OUT=<file>`; `FMD_LINE_ATTR_W` defaults to the reader's 1098.
final class LineAttributeProbeTests: XCTestCase {

    func testLineAttributes() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FMD_LINE_ATTR"], let sheet = Int(env["FMD_LINE_ATTR_SHEET"] ?? "") else {
            throw XCTSkip("set FMD_LINE_ATTR=<document> and FMD_LINE_ATTR_SHEET=<n>")
        }
        var report: [String] = []
        func say(_ s: String) { report.append(s); print(s) }
        defer {
            if let out = env["FMD_LINE_ATTR_OUT"] {
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
        let w = CGFloat(Double(env["FMD_LINE_ATTR_W"] ?? "") ?? 1098)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: w, height: 640), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
        guard let lm = wc.textView.layoutManager, let tc = wc.textView.textContainer,
              let st = wc.textView.textStorage else { say("PROBE ABORTED"); return }
        lm.ensureLayout(for: tc)
        let d = wc.pageBandDelegate
        let pitch = d.pageContentHeight + d.band
        let top = d.leadingBand + CGFloat(sheet - 1) * pitch
        let bottom = top + pitch
        say(String(format: "PROBE sheet %d  y %.1f..%.1f  body %.1f", sheet, top, bottom, d.pageContentHeight))
        let ns = st.string as NSString
        var seen: Set<ObjectIdentifier> = []
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, used, _, gr, _ in
            guard used.minY >= top, used.minY < bottom else { return }
            let cr = lm.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
            guard cr.location < ns.length else { return }
            let text = ns.substring(with: cr).replacingOccurrences(of: "\n", with: "⏎")
                .trimmingCharacters(in: .whitespaces)
            let font = st.attribute(.font, at: cr.location, effectiveRange: nil) as? NSFont
            let ps = st.attribute(.paragraphStyle, at: cr.location, effectiveRange: nil) as? NSParagraphStyle
            let cell = ps?.textBlocks.first as? NSTextTableBlock
            if let grid = cell?.table as? GridTextTable, !seen.contains(ObjectIdentifier(grid)) {
                seen.insert(ObjectIdentifier(grid))
                say("PROBE  TABLE proportions "
                    + grid.columnProportions.map { String(format: "%.3f", $0) }.joined(separator: ",")
                    + String(format: "  maxWidth %.1f  outerMargin %.1f/%.1f",
                             grid.maxWidth ?? -1, grid.outerMarginLeft, grid.outerMarginRight))
            }
            say(String(format: "PROBE  y%9.1f h%5.1f x%6.1f w%6.1f  font %5.1f  minLH %5.1f maxLH %5.1f"
                       + "  head %5.1f tail %6.1f  cell %@  |%@| @%d",
                       used.minY, used.height, used.minX, used.width,
                       font?.pointSize ?? -1, ps?.minimumLineHeight ?? -1, ps?.maximumLineHeight ?? -1,
                       ps?.headIndent ?? 0, ps?.tailIndent ?? 0,
                       cell.map { String(format: "r%d c%d span%d content %.1f",
                                         $0.startingRow, $0.startingColumn, $0.columnSpan,
                                         $0.contentWidth) } ?? "-",
                       String(text.prefix(30)), cr.location)
                + (wc.pageBandDelegate.columnPlacements[cr.location].map {
                       String(format: "  COLPLACED x%.1f y%.1f", $0.x, $0.y) } ?? "  -"))
            if let f = font {
                let m = f.matrix   // six CGFloats: a b c d tx ty
                say(String(format: "PROBE      face %@  matrix a%.3f d%.3f  kern %@",
                           f.fontName, m[0] / max(f.pointSize, 0.001), m[3] / max(f.pointSize, 0.001),
                           (st.attribute(.kern, at: cr.location, effectiveRange: nil) as? NSNumber)
                               .map { String(format: "%.2f", $0.doubleValue) } ?? "-"))
            }
        }
    }
}
