import XCTest
import AppKit
@testable import FastDocReader

/// JUST THE TWO STAGES A DOUBLE-CLICK IS JUDGED BY — read+parse, and first paint.
///
/// `ReaderPerfProbeTests` measures the whole matrix and costs ~4.6 minutes a run, which is too slow
/// to bisect with. This is the same two stages by the same door (`MarkdownDocument.read` then
/// `makeWindowControllers`), so it can be dropped into an older worktree and compared.
///
/// `FMD_FIRSTPAINT_FILE=<abs path>`; optional `FMD_PERF_WIDTH`/`FMD_PERF_HEIGHT`.
final class FirstPaintProbeTests: XCTestCase {
    private func ms(_ t: Date) -> Double { Date().timeIntervalSince(t) * 1000 }

    func testFirstPaint() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_FIRSTPAINT_FILE"] else {
            throw XCTSkip("set FMD_FIRSTPAINT_FILE")
        }
        let w = CGFloat(Double(ProcessInfo.processInfo.environment["FMD_PERF_WIDTH"] ?? "1200") ?? 1200)
        let h = CGFloat(Double(ProcessInfo.processInfo.environment["FMD_PERF_HEIGHT"] ?? "900") ?? 900)
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let uti: String = {
            switch ext {
            case "odt": return "org.oasis-open.opendocument.text"
            case "hwp", "hwpx": return "com.hancom.hwp"
            case "md", "markdown": return "net.daringfireball.markdown"
            case "txt": return "public.plain-text"
            default: return "org.openxmlformats.wordprocessingml.document"
            }
        }()
        let data = try Data(contentsOf: url)

        // ONE document per process, deliberately. Rendering the same file three times in one
        // process reported 50.4 s, then 17.7 s, then 8.8 s — three 2.8 M character storages alive at
        // once, and the number that came out was memory pressure rather than render cost. Run the
        // whole test three times instead: 10.11 / 10.23 / 10.12.
        for round in 1...1 {
            let doc = MarkdownDocument()
            doc.fileURL = url
            var t = Date()
            try doc.read(from: data, ofType: uti)
            let readMs = ms(t)
            NSWindow.removeFrame(usingName: "FastMDReaderDoc")
            t = Date()
            doc.makeWindowControllers()
            let paintMs = ms(t)
            let wc = doc.windowControllers.first as? DocumentWindowController
            wc?.window?.setFrame(NSRect(x: 0, y: 0, width: w, height: h), display: false)
            let chars = wc?.textView.textStorage?.length ?? 0
            print(String(format: "FP round=%d read=%.1fms firstPaint=%.1fms chars=%d",
                         round, readMs, paintMs, chars))
            doc.windowControllers.forEach { doc.removeWindowController($0) }
        }
    }
}
