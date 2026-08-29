import XCTest
import Markdown
@testable import FastDocReader

/// What the HOST's markdown parse actually costs, isolated from everything around it.
///
/// The whole-reader probe reports `read_parse ms=1.3` for a 1.2 MB novel, which is not a parse at
/// all: `MarkdownDocument.read` for a text document decodes bytes and stops, and
/// `MarkdownRenderer` parses on the first render — whole, deliberately ("a link definition at the
/// end of the file binds text at the start"), with only the WALK sliced for progressive paint.
/// Comparing that 1.3 against the engine's producer would be comparing a file read against a parse.
///
/// Set `FMD_MD_PARSE_PROBE` to a markdown file. Run with `-c release`: a debug build measured the
/// engine's own producer at 1,102 ms and release at 63.7, so a debug number here would be a
/// different kind of wrong in the other direction.
final class MarkdownParseCostProbeTests: XCTestCase {
    func testWhatSwiftMarkdownCostsToParseARealDocument() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_MD_PARSE_PROBE"] else {
            throw XCTSkip("set FMD_MD_PARSE_PROBE to an absolute path naming a markdown file")
        }
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        func ms(_ body: () -> Void) -> Double {
            let t = Date(); body(); return Date().timeIntervalSince(t) * 1000
        }

        // Parse alone, three times, reported as the minimum — the same shape `perf-baseline.sh`
        // uses, because a first run pays for pages the later ones find warm.
        var parseSamples: [Double] = []
        for _ in 0..<3 {
            var parsed: Document?
            parseSamples.append(ms { parsed = Document(parsing: text) })
            XCTAssertNotNil(parsed)
        }
        // Then the whole host render — parse plus the attributed-string build the engine's tree
        // does NOT do, so the two numbers bracket what a fair comparison would cost.
        let theme = RenderTheme(baseFontSize: 13)
        var built: NSAttributedString?
        let renderMs = ms { built = MarkdownRenderer.render(text, theme: theme) }

        print("MDPARSE file=\((path as NSString).lastPathComponent) "
              + "bytes=\(text.utf8.count) chars=\(text.count) "
              + String(format: "parseMinMs=%.1f renderMs=%.1f builtChars=%d",
                       parseSamples.min() ?? -1, renderMs, built?.length ?? -1))
    }
}
