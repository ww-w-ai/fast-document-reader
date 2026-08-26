import XCTest
import AppKit
@testable import FastDocReader

#if FMD_RUST_ENGINE

/// S5B2b-03/04: proves the cutover on a REAL document through the REAL reflow entry point —
/// `TableBlockBuilder.resizeTables(in:toWidth:)`, the exact function `DocumentWindowController`
/// calls on first layout and every resize. This is deliberately NOT
/// `RustEngineTableResizeParityTests` (S5B2a): that file compares two calls into the engine
/// against each other (a call the S5B2a-era `resizeTables` never made), which the intent audit
/// already named as the shape that hid a real defect once. Here `resizeTables` itself is the one
/// under test, unmodified from what production calls, and the REFERENCE value it is checked
/// against is `TableBlockBuilder.localCellTargetWidth` — the host's own formula, computed
/// independently of whichever branch `resizeTables` took to answer.
///
/// Reaches `fastdoc_table_resize_cell_widths` (`RustEngineTableResize.targetWidths`, called once
/// per table from `resizeTables`'s `#if FMD_RUST_ENGINE` branch) — named here because a "parity"
/// test that never crosses the FFI boundary is exactly what this roadmap already shipped once.
final class RustEngineTableResizeCutoverTests: XCTestCase {
    /// `docs/fixtures`-style skip, matching `RustEngineBridgeTests.fixture`: this machine's
    /// `testdocs/` corpus is gitignored, so a fresh checkout skips rather than fails.
    private static func fixture(_ testdocsRelativePath: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("testdocs").appendingPathComponent(testdocsRelativePath)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw XCTSkip("testdocs/\(testdocsRelativePath) is gitignored and absent in this checkout")
        }
        return data
    }

    /// Opens a real office document the same way the app does, and returns the attributed string
    /// `OfficeTextBuilder.build` produces for it at `columnWidth` — the pre-reflow shape
    /// `resizeTables` is always called on next, exactly as `DocumentWindowController` does on
    /// first layout.
    private func attributedString(for data: Data, extension ext: String, columnWidth: CGFloat) throws
        -> NSAttributedString {
        let doc = MarkdownDocument()
        // `MarkdownDocument.kind` (and so `read(from:ofType:)`'s office/text branch) is derived from
        // `fileURL?.pathExtension` — without a `fileURL` a real docx would be misread as markdown
        // text. This mirrors `GiantTableDeferralLatencyProbe`'s own `doc.fileURL = url` before `read`.
        doc.fileURL = URL(fileURLWithPath: "fixture.\(ext)")
        let uti = (ext == "odt") ? "org.oasis-open.opendocument.text"
            : (ext == "hwp" || ext == "hwpx") ? "com.hancom.hwp"
            : "org.openxmlformats.wordprocessingml.document"
        try doc.read(from: data, ofType: uti)
        let theme = RenderTheme.current(size: doc.officeDefaultBodyFontSize)
        return OfficeTextBuilder.build(
            doc.officeBlocks, theme: theme, columnWidth: columnWidth,
            documentDefaultFontSize: doc.officeDefaultBodyFontSize,
            pageContentWidth: doc.officePageContentWidth, tableWidth: columnWidth,
            comments: doc.officeComments)
    }

    /// Runs the production `resizeTables` on `storage` and, table by table, checks every touched
    /// cell's WRITTEN contentWidth against `localCellTargetWidth`'s answer for the identical
    /// span/padding/border — the host's own formula, independent of the FFI call `resizeTables`
    /// just made. Returns how many tables and cells were actually reached, so a caller can assert
    /// the corpus was not accidentally empty.
    @discardableResult
    private func resizeAndCompareAgainstTheHostsOwnFormula(
        _ storage: NSTextStorage, toWidth width: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) -> (tables: Int, cells: Int, written: Int) {
        let written = TableBlockBuilder.resizeTables(in: storage, toWidth: width)
        var edgesByTable: [ObjectIdentifier: [CGFloat]] = [:]
        var tablesSeen: Set<ObjectIdentifier> = []
        var cellsSeen = 0
        storage.enumerateAttribute(
            NSAttributedString.Key.paragraphStyle, in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            guard let ps = value as? NSParagraphStyle,
                  let block = ps.textBlocks.first as? NSTextTableBlock,
                  let table = block.table as? GridTextTable, !table.columnProportions.isEmpty
            else { return }
            let key = ObjectIdentifier(table)
            tablesSeen.insert(key)
            let edges = edgesByTable[key] ?? {
                let e = table.edges(forWidth: width); edgesByTable[key] = e; return e
            }()
            guard let reference = TableBlockBuilder.localCellTargetWidth(
                edges: edges, numberOfColumns: table.numberOfColumns,
                startingColumn: block.startingColumn, columnSpan: block.columnSpan,
                padLeft: block.width(for: .padding, edge: .minX),
                padRight: block.width(for: .padding, edge: .maxX),
                borderLeft: block.width(for: .border, edge: .minX),
                borderRight: block.width(for: .border, edge: .maxX))
            else { return }
            cellsSeen += 1
            XCTAssertEqual(block.contentWidth, reference, accuracy: 0.5,
                           "engine-resized contentWidth must match the host's own formula",
                           file: file, line: line)
        }
        return (tablesSeen.count, cellsSeen, written)
    }

    /// A real docx with merged cells, resized through the production `resizeTables` while the
    /// engine answers — every touched cell's written width must equal what
    /// `localCellTargetWidth` (the host's own formula, no FFI in it) computes for the same span.
    func testARealDocxsTableCellsMatchTheHostsOwnFormulaThroughTheProductionResizePath() throws {
        let data = try Self.fixture("tables/OpenAPI활용가이드_특일정보_v1.4.docx")
        let attr = try attributedString(for: data, extension: "docx", columnWidth: 500)
        let storage = NSTextStorage(attributedString: attr)
        // 700, not 500's neighbour: this document AUTHORS its table widths, so every width above
        // the authored cap resolves to the same answer `build` already wrote and NOTHING moves —
        // measured, 0 cells written at 700 against 861 at 300. A width that moves no cell cannot
        // tell a correct answer apart from no answer at all, which is how a refusal survived here.
        let result = resizeAndCompareAgainstTheHostsOwnFormula(storage, toWidth: 300)
        XCTAssertGreaterThan(result.tables, 0, "the corpus document must actually contain tables")
        XCTAssertGreaterThan(result.cells, 0)
        // Without this, a refusal is invisible: an engine that answers nothing leaves every cell
        // at the width `build` gave it, and on a document whose tables do not move between the two
        // widths that reads exactly like a correct answer. Dropping one width from the answer (so
        // the count no longer matches the cells asked about) passed the value comparison above.
        XCTAssertGreaterThan(result.written, 0,
                             "the engine's answer must actually reach cells, not be refused")
    }

    /// S5B2b-04: resizing the SAME storage at the SAME width a second time must move zero cells —
    /// invariant 48's own gate, applied to the engine-driven branch. A cutover that wrote
    /// unconditionally would re-snap every cell on every reflow and look like a rendering bug.
    func testResizingTwiceAtTheSameWidthMovesNoCellOnARealDocument() throws {
        let data = try Self.fixture("tables/OpenAPI활용가이드_특일정보_v1.4.docx")
        let attr = try attributedString(for: data, extension: "docx", columnWidth: 500)
        let storage = NSTextStorage(attributedString: attr)
        // 300 for the same reason the parity test uses it: at 640 this document's authored widths
        // win and the FIRST pass already writes nothing, which would make "the second wrote
        // nothing" true for free.
        let writtenOnTheFirstPass = TableBlockBuilder.resizeTables(in: storage, toWidth: 300)
        XCTAssertGreaterThan(writtenOnTheFirstPass, 0,
                             "the first pass must actually move cells for the second to prove anything")

        var before: [ObjectIdentifier: CGFloat] = [:]
        var reached = 0
        storage.enumerateAttribute(
            NSAttributedString.Key.paragraphStyle, in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            guard let ps = value as? NSParagraphStyle,
                  let block = ps.textBlocks.first as? NSTextTableBlock else { return }
            before[ObjectIdentifier(block)] = block.contentWidth
            reached += 1
        }
        XCTAssertGreaterThan(reached, 0, "the table must actually be reached before this check means anything")

        let writtenOnTheSecondPass = TableBlockBuilder.resizeTables(in: storage, toWidth: 300)
        // The WIDTHS cannot tell this apart: writing every cell the value it already holds moves
        // nothing. What a conditional write protects is the invalidation set (invariant 48), so
        // that is what this asserts.
        XCTAssertEqual(writtenOnTheSecondPass, 0,
                       "a reflow at an unchanged width must write no cell at all")
        var moved = 0
        storage.enumerateAttribute(
            NSAttributedString.Key.paragraphStyle, in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            guard let ps = value as? NSParagraphStyle,
                  let block = ps.textBlocks.first as? NSTextTableBlock else { return }
            if let was = before[ObjectIdentifier(block)], abs(was - block.contentWidth) > 0.5 { moved += 1 }
        }
        XCTAssertEqual(moved, 0, "the second resize at the same width must not re-snap a single cell")
    }
}
#endif

/// S5B2b-05: the reflow latency on the heaviest real table document, measured again after the
/// cutover. Permanently-skipped probe (same convention as `GiantTableDeferralLatencyProbe`),
/// deliberately NOT gated by `FMD_RUST_ENGINE` — the SAME test, run once per build configuration,
/// IS the comparison: BEFORE is a build WITHOUT the flag (`TableBlockBuilder.resizeTables`'s local
/// formula, zero FFI crossings); AFTER is a build WITH it (ONE
/// `fastdoc_table_resize_cell_widths_batch` call for the whole document). The printed line names
/// which branch ran so the two numbers are never mixed up when read back from a log.
final class RustEngineTableResizeLatencyProbe: XCTestCase {
    private func ms(_ s: Date) -> Double { Date().timeIntervalSince(s) * 1000 }

    func testResizeTablesLatencyWithTheEngineAnswering() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_GIANT_TABLE_LATENCY"] else {
            throw XCTSkip("set FMD_GIANT_TABLE_LATENCY to a real many-table document to measure this")
        }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let uti = (ext == "odt") ? "org.oasis-open.opendocument.text"
            : (ext == "hwp" || ext == "hwpx") ? "com.hancom.hwp"
            : "org.openxmlformats.wordprocessingml.document"
        let doc = MarkdownDocument()
        doc.fileURL = url  // `kind`/`read(from:ofType:)`'s office branch needs this, see `attributedString(for:extension:columnWidth:)`'s own note
        try doc.read(from: Data(contentsOf: url), ofType: uti)
        XCTAssertFalse(doc.officeBlocks.isEmpty, "the measurement document must actually parse as office content")
        let theme = RenderTheme.current(size: doc.officeDefaultBodyFontSize)
        let width: CGFloat = 800
        // Built at a DIFFERENT placeholder width (400, not 800) — `tableWidth` defaults to
        // `columnWidth` (`OfficeTextBuilder.build`'s own `requestedWidth = tableWidth ?? columnWidth`),
        // so building directly at `width` would give `resizeTables` nothing to move, and the first
        // call below would measure an early return instead of real work.
        let attr = OfficeTextBuilder.build(
            doc.officeBlocks, theme: theme, columnWidth: 400,
            documentDefaultFontSize: doc.officeDefaultBodyFontSize,
            pageContentWidth: doc.officePageContentWidth,
            comments: doc.officeComments)
        let storage = NSTextStorage(attributedString: attr)

        // First call actually moves cells (placeholder width -> `width`); the second, at the same
        // width, is the "nothing moves" steady-state cost invariant 48 measures.
        let t1 = Date()
        TableBlockBuilder.resizeTables(in: storage, toWidth: width)
        let firstCallMs = ms(t1)
        let t2 = Date()
        TableBlockBuilder.resizeTables(in: storage, toWidth: width)
        let secondCallMs = ms(t2)
        #if FMD_RUST_ENGINE
        let branch = "FMD_RUST_ENGINE=1 (engine, ONE FFI call for the whole document)"
        #else
        let branch = "FMD_RUST_ENGINE off (host local formula, no FFI)"
        #endif
        print(String(format: "  [%@] resizeTables width-changed %8.2f ms · width-unchanged %8.2f ms",
                     branch, firstCallMs, secondCallMs))
    }
}
