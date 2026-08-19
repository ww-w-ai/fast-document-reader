import XCTest
@testable import FastDocReader

/// Measures whether real office documents (.docx/.docm/.dotx/.dotm/.odt/.hwp/.hwpx) are ever big
/// enough in TEXT for the progressive front-first first paint that markdown got at invariant 101
/// (300,000 UTF-16 units) to matter. A document can be huge in BYTES (embedded images) while its
/// actual text is tiny — this probe measures the text, not the file.
///
///     FMD_OFFICE_TEXT_SIZE_CORPUS="$HOME/Documents:$HOME/Downloads:$HOME/Desktop" \
///       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --filter testOfficeTextSize
///
/// Skipped by default: it needs real documents this repo does not ship.
///
/// Text size is the sum of every `Span.text` length reached by walking `OfficeReadResult.blocks`
/// (recursing into `.table` cells, which hold the SAME block vocabulary) — no `OfficeTextBuilder`
/// call, no layout pass. That is cheaper than the full typography build and answers the same
/// question (how much text would the reader lay out), since `OfficeTextBuilder` never DROPS a
/// span's characters, only styles them.
final class OfficeTextSizeProbeTests: XCTestCase {
    func testOfficeTextSize() throws {
        guard let dirList = ProcessInfo.processInfo.environment["FMD_OFFICE_TEXT_SIZE_CORPUS"] else {
            throw XCTSkip("set FMD_OFFICE_TEXT_SIZE_CORPUS (colon-separated directories)")
        }
        let roots = dirList.split(separator: ":").map { URL(fileURLWithPath: String($0)) }

        struct Row {
            let path: String
            let chars: Int
            let bytes: Int
            let paged: Bool
        }
        var rows: [Row] = []
        var found = 0, parseFailures = 0, enumerationErrors = 0

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [],
                errorHandler: { _, _ in enumerationErrors += 1; return true }
            ) else { continue }

            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let name = url.lastPathComponent
                    if name == "node_modules" || name == ".build" || name.hasPrefix(".") {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                let ext = url.pathExtension.lowercased()
                guard DocumentTypes.isHwp(ext) || ext == "docx" || ext == "docm" || ext == "dotx"
                        || ext == "dotm" || ext == "odt" else { continue }
                let base = url.lastPathComponent
                guard !base.hasPrefix("._"), !base.hasPrefix("~$") else { continue }
                found += 1

                do {
                    let data = try Data(contentsOf: url)
                    let result: OfficeReadResult
                    if DocumentTypes.isHwp(ext) {
                        result = try HwpReader.read(data)
                    } else {
                        result = try DocumentTypes.readOffice(try ZipArchive(data: data), extension: ext)
                    }
                    let chars = OfficeTextSizeProbeTests.textLength(of: result.blocks)
                    rows.append(Row(path: url.path, chars: chars, bytes: data.count,
                                     paged: result.pageContentWidth != nil))
                } catch {
                    parseFailures += 1
                    print("PARSEFAIL \(url.lastPathComponent) — \(error)")
                }
            }
        }

        // Write the full table to scratch — never paste this back, it's the whole corpus.
        let scratchDir = URL(fileURLWithPath: "/Users/taehyoungkim/.claude/jobs/b865c686/tmp/")
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        let scratchFile = scratchDir.appendingPathComponent("office-text-size-probe.tsv")
        var tsv = "chars\tbytes\tpaged\tpath\n"
        for r in rows.sorted(by: { $0.chars > $1.chars }) {
            tsv += "\(r.chars)\t\(r.bytes)\t\(r.paged)\t\(r.path)\n"
        }
        try? tsv.write(to: scratchFile, atomically: true, encoding: .utf8)

        let charCounts = rows.map { $0.chars }.sorted()
        func percentile(_ p: Double) -> Int {
            guard !charCounts.isEmpty else { return 0 }
            let idx = min(charCounts.count - 1, max(0, Int((Double(charCounts.count) * p).rounded(.down))))
            return charCounts[idx]
        }
        let charsMax = charCounts.last ?? 0
        let p99 = percentile(0.99)
        let p90 = percentile(0.90)
        let p50 = percentile(0.50)
        let over300k = rows.filter { $0.chars >= 300_000 }.count
        let over100k = rows.filter { $0.chars >= 100_000 }.count
        let pagedCount = rows.filter { $0.paged }.count
        let unpagedCount = rows.count - pagedCount
        let pagedPct = rows.isEmpty ? 0 : Double(pagedCount) / Double(rows.count) * 100
        let unpagedPct = rows.isEmpty ? 0 : Double(unpagedCount) / Double(rows.count) * 100

        print("""
        OFFICETEXTSIZEPROBE found=\(found) parsed=\(rows.count) parseFailures=\(parseFailures) \
        enumerationErrorsSkippedPast=\(enumerationErrors)
        OFFICETEXTSIZEPROBE method=blockSpanSum(no OfficeTextBuilder call)
        OFFICETEXTSIZEPROBE chars_max=\(charsMax) chars_p99=\(p99) chars_p90=\(p90) chars_p50=\(p50)
        OFFICETEXTSIZEPROBE over300k=\(over300k) over100k=\(over100k) totalDocs=\(rows.count)
        OFFICETEXTSIZEPROBE paged_count=\(pagedCount) paged_pct=\(String(format: "%.1f", pagedPct)) \
        unpaged_count=\(unpagedCount) unpaged_pct=\(String(format: "%.1f", unpagedPct))
        """)

        for r in rows.sorted(by: { $0.chars > $1.chars }).prefix(5) {
            print("OFFICETEXTSIZEPROBE top name=\(URL(fileURLWithPath: r.path).lastPathComponent) " +
                  "chars=\(r.chars) bytes=\(r.bytes) paged=\(r.paged)")
        }
        print("OFFICETEXTSIZEPROBE scratchFile=\(scratchFile.path)")

        XCTAssertGreaterThan(found, 0, "FMD_OFFICE_TEXT_SIZE_CORPUS matched no office documents")
    }

    /// Sums every `Span.text` length reached from a block list, recursing into table cells (which
    /// hold the SAME block vocabulary — see `Cell.blocks`'s doc). Deliberately does not add a
    /// synthetic count for `.image`/`.unsupportedGraphic`/`.formula` — those contribute no
    /// characters to the reader's actual text storage the way a span's text does; `.formula`'s
    /// LaTeX is rendered as a web block, not laid-out text, so counting its string length would
    /// overstate what this probe exists to measure.
    private static func textLength(of blocks: [OfficeBlock]) -> Int {
        var total = 0
        for block in blocks {
            switch block {
            case .heading(_, let spans, _, _, _, _),
                 .paragraph(let spans, _, _, _, _),
                 .listItem(_, _, let spans, _, _, _, _, _, _):
                for span in spans { total += span.text.utf16.count }
            case .table(let rows, _, _, _):
                for row in rows {
                    for cell in row {
                        total += textLength(of: cell.blocks)
                    }
                }
            case .image, .unsupportedGraphic, .formula:
                break
            }
        }
        return total
    }
}
