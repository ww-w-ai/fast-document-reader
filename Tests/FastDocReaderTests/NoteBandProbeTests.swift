import XCTest
import AppKit
@testable import FastDocReader

/// What every footnote band actually RESERVES, against the notes that sit in it.
///
/// The band is a fixpoint (invariant 98): a reservation shortens the page, which moves the markers,
/// which re-decides the reservation. A band that settles far larger than its own notes is invisible
/// in every aggregate — the page is simply "not full" — and shows up only as pages the document
/// did not need.
final class NoteBandProbeTests: XCTestCase {

    func testNoteBands() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FMD_NOTEBAND_PROBE"] else {
            throw XCTSkip("set FMD_NOTEBAND_PROBE=<document>")
        }
        var report: [String] = []
        func say(_ s: String) { report.append(s); print(s) }
        defer {
            if let out = env["FMD_NOTEBAND_OUT"] {
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
        let w = CGFloat(Double(env["FMD_NOTEBAND_W"] ?? "") ?? 1098)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: w, height: 640), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)

        say(String(format: "PROBE lineGridPitch %@   defaultBodyFontSize %.2f   pageContentWidth %@",
                   doc.officeLineGridPitch.map { String(format: "%.3f", $0) } ?? "nil",
                   doc.officeDefaultBodyFontSize,
                   doc.officePageContentWidth.map { String(format: "%.2f", $0) } ?? "nil"))
        let d = wc.pageBandDelegate
        let bands = d.noteBands.sorted { $0.key < $1.key }
        say(String(format: "PROBE footnotes %d  pages with a band %d  body %.1f",
                   wc.footnotes.count, bands.count, d.pageContentHeight))
        let total = bands.reduce(0) { $0 + $1.value }
        say(String(format: "PROBE reserved total %.1f pt = %.1f pages", total, total / max(1, d.pageContentHeight)))
        for (page, height) in bands.prefix(25) {
            let notes = wc.footnotePages[page] ?? []
            let own = notes.compactMap { wc.footnoteHeights[$0] }.reduce(0, +)
            say(String(format: "PROBE  page %4d  band %7.1f  notes %d totalling %6.1f  waste %7.1f",
                       page, height, notes.count, own, height - own))
        }
        let waste = bands.reduce(CGFloat(0)) { acc, e in
            let own = (wc.footnotePages[e.key] ?? []).compactMap { wc.footnoteHeights[$0] }.reduce(0, +)
            return acc + max(0, e.value - own)
        }
        say(String(format: "PROBE waste total %.1f pt = %.1f pages", waste, waste / max(1, d.pageContentHeight)))
    }
}
