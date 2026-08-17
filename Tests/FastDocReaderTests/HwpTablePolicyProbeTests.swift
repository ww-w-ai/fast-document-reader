import XCTest
import AppKit
@testable import FastDocReader

/// What real documents say about their own tables at a page boundary — whether the heading is meant
/// to be reprinted overleaf, and whether the table may be cut at all.
///
///     FMD_HWP_TABLE_POLICY="/path/to/hwp/files:/another/dir" \
///       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --filter HwpTablePolicyProbeTests
///
/// Skipped by default: it needs documents this repo does not ship. Invariant 92 made breaking a
/// table the reader's default after measuring 11 pages of blank paper on one manual, and it made
/// that choice with no way to hear the document's own answer. These two flags are that answer, and
/// this probe is how their worth is judged before any pagination code is touched.
final class HwpTablePolicyProbeTests: XCTestCase {

    private func corpusFiles() throws -> [URL] {
        guard let dirs = ProcessInfo.processInfo.environment["FMD_HWP_TABLE_POLICY"], !dirs.isEmpty else {
            throw XCTSkip("set FMD_HWP_TABLE_POLICY to colon-separated directories of HWP files")
        }
        let fm = FileManager.default
        var files: [URL] = []
        var skipped = 0
        for dir in dirs.split(separator: ":").map(String.init) {
            let e = fm.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil,
                                  options: [.skipsHiddenFiles],
                                  errorHandler: { _, _ in skipped += 1; return true })
            while let u = e?.nextObject() as? URL {
                if ["hwp", "hwpx"].contains(u.pathExtension.lowercased()) { files.append(u) }
            }
        }
        if skipped > 0 { print("TABLEPOLICY dirsSkipped=\(skipped)") }
        var seen = Set<String>()
        return files.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
    }

    func testWhatDocumentsSayAboutTheirTablesAtAPageBoundary() throws {
        let files = try corpusFiles()
        var parsed = 0, unreadable = 0, tables = 0
        var withHeading = 0, repeats = 0, repeatsWithHeading = 0, headingWithoutRepeat = 0
        var never = 0, atRow = 0, anywhere = 0, unstated = 0
        // A table long enough that the question can even arise. Rows are a poor proxy for height,
        // but a table of three rows never reaches a page boundary whatever its policy says.
        var longTables = 0, longNever = 0, longRepeats = 0
        var docsWithNever = 0, docsWithRepeat = 0

        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let result = try? HwpReader.read(data) else { unreadable += 1; continue }
            parsed += 1
            var docNever = false, docRepeat = false
            for block in Self.everyTable(in: result.blocks) {
                guard case .table(let rows, let headerRows, _, let format) = block else { continue }
                tables += 1
                let long = rows.count >= 20
                if long { longTables += 1 }
                if headerRows > 0 { withHeading += 1 }
                if format.repeatHeaderRows == true {
                    repeats += 1
                    docRepeat = true
                    if long { longRepeats += 1 }
                    if headerRows > 0 { repeatsWithHeading += 1 }
                } else if headerRows > 0 {
                    headingWithoutRepeat += 1
                }
                switch format.pageBreakPolicy {
                case .never:
                    never += 1; docNever = true
                    if long { longNever += 1 }
                case .atRowBoundary: atRow += 1
                case .anywhere: anywhere += 1
                case nil: unstated += 1
                }
            }
            if docNever { docsWithNever += 1 }
            if docRepeat { docsWithRepeat += 1 }
        }

        print("""
        TABLEPOLICY files=\(files.count) parsed=\(parsed) unreadable=\(unreadable) tables=\(tables) longTables(>=20rows)=\(longTables)
        TABLEPOLICY heading=\(withHeading) repeats=\(repeats) repeatsWithHeading=\(repeatsWithHeading) headingWithoutRepeat=\(headingWithoutRepeat) docsWithRepeat=\(docsWithRepeat) longRepeats=\(longRepeats)
        TABLEPOLICY split never=\(never) atRow=\(atRow) anywhere=\(anywhere) unstated=\(unstated) docsWithNever=\(docsWithNever) longNever=\(longNever)
        """)

        XCTAssertGreaterThan(parsed, 0, "no document could be read — the probe measured nothing")
        XCTAssertGreaterThan(tables, 0, "no table was found — the walk or the export is broken")
        // The decode itself: a renamed key leaves every table "unstated" while the counts still add up.
        XCTAssertLessThan(unstated, tables, "every table read as unstated — the pageBreak decode broke")
    }

    /// Tables nest — a cell holds blocks, and those can be tables again.
    private static func everyTable(in blocks: [OfficeBlock]) -> [OfficeBlock] {
        var out: [OfficeBlock] = []
        for block in blocks {
            guard case .table(let rows, _, _, _) = block else { continue }
            out.append(block)
            for row in rows { for cell in row { out.append(contentsOf: everyTable(in: cell.blocks)) } }
        }
        return out
    }
}
