import XCTest
import AppKit
import CFastdocEngine
@testable import FastDocReader

/// The like-for-like half of the markdown engine comparison.
///
/// The engine's markdown numbers so far were taken inside `cargo test`, where the font world is a
/// single synthetic face and nothing is ever substituted — a FLOOR, not a comparison (roadmap M1
/// says so explicitly). This probe closes that gap by driving `fastdoc_read_text_tree` from the
/// HOST, with the real CoreText-backed provider installed, against the same file the host renderer
/// gets. Both arms therefore pay for the same fonts, the same substitutions and the same machine.
///
/// It is a probe, not a gate: it prints and asserts only that both arms produced something. A wall
/// clock cannot be a pass/fail on this machine (this repo's suite is documented flaky under load),
/// and the decision it feeds — whether to build the tree consumer S6 left undone — is a judgement,
/// not a threshold.
final class MarkdownEngineParityProbeTests: XCTestCase {
    func testTheEngineAndTheHostRenderTheSameMarkdownFile() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_MD_PARITY_FILE"] else {
            throw XCTSkip("set FMD_MD_PARITY_FILE to an absolute path naming a real markdown file")
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let source = try XCTUnwrap(String(data: data, encoding: .utf8), "the file must be UTF-8")

        // The engine measures and substitutes through the host, exactly as the office path does.
        RustEngineFonts.install()

        func measure(_ label: String, _ body: () -> Int) -> (label: String, ms: Double, size: Int) {
            var best = Double.greatestFiniteMagnitude
            var size = 0
            for _ in 0..<3 {                       // minimum of three: the machine is shared
                let start = DispatchTime.now().uptimeNanoseconds
                size = body()
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                best = min(best, ms)
            }
            return (label, best, size)
        }

        let host = measure("host  (Swift MarkdownRenderer)") {
            let theme = RenderTheme.current(size: FontSizeStore.defaultSize)
            return MarkdownRenderer.render(source, theme: theme).length
        }

        let ext = url.pathExtension
        let engine = measure("engine (fastdoc_read_text_tree)") {
            var produced = 0
            data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                ext.withCString { cext in
                    guard let json = fastdoc_read_text_tree(base, data.count, cext) else { return }
                    produced = strlen(json)
                    fastdoc_string_free(json)
                }
            }
            return produced
        }

        // The engine arm above stops at a JSON tree; the host arm ends at a laid-out attributed
        // string. Reporting those two against each other would be the same mistake as quoting one
        // document's print delta — so the transport the host would STILL owe is measured here. This
        // is a FLOOR for it: a real consumer decodes into typed values and builds typography on top,
        // where this only scans the bytes once.
        var envelopeBytes = Data()
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            ext.withCString { cext in
                guard let json = fastdoc_read_text_tree(base, data.count, cext) else { return }
                envelopeBytes = Data(bytes: json, count: strlen(json))
                fastdoc_string_free(json)
            }
        }
        let decode = measure("  + host decode floor (JSON scan)") {
            (try? JSONSerialization.jsonObject(with: envelopeBytes)) != nil ? envelopeBytes.count : 0
        }

        print("MD-PARITY \(url.lastPathComponent) — \(source.count) characters, real font world")
        for arm in [host, engine, decode] {
            print(String(format: "  %@  %8.1f ms   result %d", arm.label, arm.ms, arm.size))
        }

        // The only mechanical claim: each arm actually produced a document. Without this a build
        // that returned nothing would look like the fastest arm.
        XCTAssertGreaterThan(host.size, 0, "the host renderer produced an empty document")
        XCTAssertGreaterThan(engine.size, 0,
                             "the engine returned no envelope — the door itself is unreachable")
        XCTAssertGreaterThan(decode.size, 0, "the envelope did not parse as JSON")
    }
}
