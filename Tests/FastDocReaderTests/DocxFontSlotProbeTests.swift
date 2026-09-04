import XCTest
@testable import FastDocReader

/// The instrument behind the per-script font work's before/after numbers, kept as a test for the
/// same reason `CorpusProbeTests` is: a figure quoted in a design document has to be re-derivable by
/// running something, not by trusting a note. It prints; it asserts only the invariants that must
/// hold whatever the corpus is (no span loses its text, no empty span is emitted), because the
/// counts themselves are properties of whichever documents are on the machine and pinning them
/// would make the probe fail for a reason that is not a defect.
///
/// Two inputs. The four `.docx` under `docs/fixtures/office/` are committed here (well, committed to
/// the owner's machine — `docs/` is gitignored, see CLAUDE.md) and are what the fixture numbers in
/// the sprint report were measured on. `FMD_DOCX_FONT_PROBE=<path>` points it at a real document the
/// repository cannot ship, which is how the Korean corpus figures were taken: the whole point of
/// unit 2 is what a document whose theme declares `a:ea typeface=""` renders as, and no synthetic
/// fixture can stand in for the measurement of that.
///
/// Everything runs through `DocumentTypes.readOffice`, never `DocxReader.read` directly — invariant
/// 29: a number measured off the parser says nothing about the number the application produces, and
/// `readOffice` is also where `resolvingFontSubstitution()` runs, so what this counts is what the
/// builder will actually be handed.
final class DocxFontSlotProbeTests: XCTestCase {
    func testFixtureCorpusSpanAndFamilyHistogram() throws {
        let dir = repoRoot().appendingPathComponent("docs/fixtures/office")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".docx") }.sorted()
        try XCTSkipIf(files.isEmpty, "docs/fixtures/office holds no .docx (docs/ is gitignored)")

        for name in files {
            let url = dir.appendingPathComponent(name)
            let archive = try ZipArchive(data: try Data(contentsOf: url))
            let result = try DocumentTypes.readOffice(archive, extension: "docx")
            report(name: name, spans: Self.allSpans(result.blocks))
        }
    }

    func testRealDocumentSpanAndFamilyHistogram() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_DOCX_FONT_PROBE"] else {
            throw XCTSkip("set FMD_DOCX_FONT_PROBE=<path to a .docx> to measure a real document")
        }
        let archive = try ZipArchive(data: try Data(contentsOf: URL(fileURLWithPath: path)))
        let result = try DocumentTypes.readOffice(archive, extension: "docx")
        report(name: (path as NSString).lastPathComponent, spans: Self.allSpans(result.blocks))
    }

    /// Prints one document's span count and its declared-family histogram, and asserts the two
    /// things that must be true of ANY corpus: splitting a run must not invent an empty piece, and
    /// must not lose a character. The second is checked here as "no span is empty" plus the
    /// exact-concatenation assertions `ScriptRunSplitterTests` makes on the splitter itself — this
    /// probe cannot re-derive the original run text, since by the time it sees the blocks the runs
    /// are already spans.
    private func report(name: String, spans: [Span]) {
        var histogram: [String: Int] = [:]
        for span in spans { histogram[span.fontName ?? "(none)", default: 0] += 1 }
        let ordered = histogram.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let chars = spans.reduce(0) { $0 + $1.text.count }
        print("[docx-font-probe] \(name): spans=\(spans.count) chars=\(chars) families=\(histogram.count)")
        for (family, count) in ordered { print("[docx-font-probe]     \(count)\t\(family)") }
        for span in spans { XCTAssertFalse(span.text.isEmpty, "\(name): an empty span was emitted") }
    }

    /// Every `Span` in the document in reading order, table cells included — a table's cells hold
    /// their own `[OfficeBlock]`, so a walk that stopped at the top level would under-count exactly
    /// the documents (forms, reports) this feature matters most for.
    static func allSpans(_ blocks: [OfficeBlock]) -> [Span] {
        var out: [Span] = []
        for block in blocks {
            switch block {
            case let .heading(_, spans, _, _, _, _),
                 let .paragraph(spans, _, _, _, _),
                 let .listItem(_, _, spans, _, _, _, _, _, _):
                // An empty paragraph's one run is its MARK (invariant 170), not a split piece —
                // the splitter never sees it, so it is not what the emptiness assertion is about.
                if spans.count == 1, spans[0].text.isEmpty { continue }
                out += spans
            case let .table(rows, _, _, _):
                for row in rows { for cell in row { out += allSpans(cell.blocks) } }
            case .image, .unsupportedGraphic, .formula:
                continue
            }
        }
        return out
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
