import XCTest
import AppKit
@testable import FastDocReader

/// The width a columned run is BUILT at, against the width its columns are PLACED at.
///
/// Those are two different numbers today: the build asks `columnWidthPerBlock` for a share of the
/// TEXT CONTAINER, and the settle asks `ColumnGeometry` for a share of the document's own page
/// BODY (`PageBandLayoutDelegate.columnBodyWidth`). When they disagree, a line breaks at one width
/// and is drawn inside a column of another — which is a real overlap, not a near miss.
final class ColumnWidthProbeTests: XCTestCase {

    func testColumnWidths() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FMD_COLWIDTH_PROBE"] else {
            throw XCTSkip("set FMD_COLWIDTH_PROBE=<document>")
        }
        var report: [String] = []
        func say(_ s: String) { report.append(s); print(s) }
        defer {
            if let out = env["FMD_COLWIDTH_OUT"] {
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
        let w = CGFloat(Double(env["FMD_COLWIDTH_W"] ?? "") ?? 1098)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: w, height: 640), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)

        let container = wc.textView.textContainer?.size.width ?? 0
        let pad = wc.textView.textContainer?.lineFragmentPadding ?? 0
        say(String(format: "PROBE window %.1f  container %.1f  pad %.1f  columnBodyWidth %.1f",
                   w, container, pad, wc.pageBandDelegate.columnBodyWidth))

        for (i, run) in wc.columnRunRanges().enumerated() {
            let placed = ColumnGeometry.columns(inWidth: wc.pageBandDelegate.columnBodyWidth,
                                                layout: run.layout)
            let built = ColumnGeometry.columns(inWidth: container, layout: run.layout)
            say("PROBE run \(i) chars \(run.range.location)..\(run.range.location + run.range.length)"
                + "  count \(run.layout.count) spacing \(run.layout.spacing)"
                + " widths \(run.layout.widths) gaps \(run.layout.gaps)"
                + " proportional \(run.layout.proportional)")
            say("PROBE   placed " + placed.map { String(format: "x%.1f w%.1f", $0.x, $0.width) }
                .joined(separator: " | "))
            say("PROBE   built  " + built.map { String(format: "x%.1f w%.1f", $0.x, $0.width) }
                .joined(separator: " | "))
            if let p = placed.first, let b = built.first {
                say(String(format: "PROBE   first-column delta %.1f (built - placed)", b.width - p.width))
            }
        }
    }
}
