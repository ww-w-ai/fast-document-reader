import XCTest
import AppKit
@testable import FastDocReader

/// What the Finder's preview actually costs, stage by stage, on a real document.
///
/// The reader and the preview want opposite things from the same pipeline: a reader pays for the
/// whole document up front so its scrollbar is honest from the first frame (invariant 49), while a
/// preview is glanced at and dismissed — so anything paid beyond the first screen is paid for
/// nothing. This probe is how that trade is measured rather than argued about.
///
/// Needs a real document this repo does not ship:
///   FMD_QL_LATENCY_FILE=/path/to/big.md swift test --filter QuickLookPreviewLatencyTests
@MainActor
final class QuickLookPreviewLatencyTests: XCTestCase {

    func testWhereThePreviewSpendsItsTime() async throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_QL_LATENCY_FILE"] else {
            throw XCTSkip("set FMD_QL_LATENCY_FILE to a real document")
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)

        func ms(_ body: () throws -> Void) rethrows -> Double {
            let t = Date(); try body(); return Date().timeIntervalSince(t) * 1000
        }

        // The WHOLE document, the way the reader builds it — split so the parser's share is visible.
        var fullChars = 0
        let doc0 = MarkdownDocument()
        doc0.fileURL = url
        let parseMs = try ms { try doc0.read(from: data, ofType: "public.data") }
        let buildMs = ms {
            doc0.makeWindowControllers()
            fullChars = (doc0.windowControllers.first as? DocumentWindowController)?.textView.string.count ?? 0
        }
        let fullMs = parseMs + buildMs

        // What the Finder's preview actually does, through the real controller.
        var previewChars = 0
        let controller = QuickLookPreviewController()
        _ = controller.view
        let t = Date()
        try await controller.preparePreviewOfFile(at: url)
        let previewMs = Date().timeIntervalSince(t) * 1000
        previewChars = firstTextView(in: controller.view)?.string.count ?? 0

        // The curve the limit is chosen from: how much of the cost is the document and how much is
        // the fixed price of building a window controller at all.
        var curve: [String] = []
        let isText = DocumentTypes.kind(forExtension: url.pathExtension.lowercased()) != .office
        let text = isText ? TextEncodingDetector.decode(data).text : ""
        for limit in isText ? [1_000, 10_000, 20_000, 40_000, 80_000] : [] {
            let head = QuickLookPreviewController.previewSource(text, limit: limit)
            let bytes = Data(head.utf8)
            let took = try ms {
                let d = MarkdownDocument()
                d.fileURL = url
                try d.read(from: bytes, ofType: "public.data")
                d.makeWindowControllers()
            }
            curve.append("      \(limit) chars → \(String(format: "%.0f", took)) ms")
        }

        print("""
        [ql-latency] \(url.lastPathComponent)  \(data.count) bytes
            whole document (reader) : \(String(format: "%.0f", fullMs)) ms, \(fullChars) chars
                  of which parse    : \(String(format: "%.0f", parseMs)) ms
                  of which build    : \(String(format: "%.0f", buildMs)) ms
            preview (this extension): \(String(format: "%.0f", previewMs)) ms, \(previewChars) chars
            cost by limit:
        \(curve.joined(separator: "\n"))
        """)
        XCTAssertGreaterThan(previewChars, 0)
    }

    private func firstTextView(in view: NSView) -> NSTextView? {
        if let t = view as? NSTextView { return t }
        for sub in view.subviews { if let f = firstTextView(in: sub) { return f } }
        return nil
    }
}
