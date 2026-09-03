import XCTest
import AppKit
@testable import FastDocReader

/// Sheets that hold no text at all — and what opened them.
///
/// A page break the document declares on an EMPTY paragraph manufactures a sheet whose only
/// content is that blank line. The reference renderer produces no page there, because HWP records
/// a page only where something was laid out. This counts them and names the run of blocks each one
/// holds, so the fix can be judged by how many sheets it removes.
final class EmptySheetProbeTests: XCTestCase {

    func testSheetsWithNoText() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FMD_EMPTY_SHEET"] else { throw XCTSkip("set FMD_EMPTY_SHEET=<document>") }
        var report: [String] = []
        func say(_ s: String) { report.append(s); print(s) }
        defer {
            if let out = env["FMD_EMPTY_SHEET_OUT"] {
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
        let sheets = wc.printSheets
        var textBySheet = [Int: Int](), linesBySheet = [Int: Int]()
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, used, _, gr, _ in
            let page = Int((((used.minY - d.leadingBand) / max(1, d.pageContentHeight + d.band)) + 1e-6).rounded(.down))
            linesBySheet[page, default: 0] += 1
            let cr = lm.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
            guard cr.location < ns.length else { return }
            let t = ns.substring(with: cr).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { textBySheet[page, default: 0] += 1 }
        }
        let blank = linesBySheet.keys.filter { (textBySheet[$0] ?? 0) == 0 }.sorted()
        say("PROBE sheets \(sheets.count)   sheets with NO text at all: \(blank.count)")
        say("PROBE   they are: " + blank.prefix(80).map(String.init).joined(separator: ","))
        let hist = Dictionary(grouping: blank) { linesBySheet[$0] ?? 0 }
            .mapValues(\.count).sorted { $0.key < $1.key }
        say("PROBE   by line count: " + hist.map { "\($0.key)line×\($0.value)" }.joined(separator: " "))
    }
}
