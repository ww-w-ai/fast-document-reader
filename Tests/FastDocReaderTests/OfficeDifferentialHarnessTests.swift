import XCTest
import AppKit
import PDFKit
@testable import FastDocReader

/// Normalized, comparison-only projection of an `OfficeReadResult` — see
/// `docs/02-planned/2026-09-04-diff-harness-and-rendertree-contract.md` §4 for the rules this
/// follows: text is paragraph-joined (span boundaries are not a diff), numbers are rounded to
/// 0.01pt, images compare by count and byte length rather than decoded pixels, and an ordered set
/// like `sectionStartBlocks` compares by the TEXT of the block it points at rather than its index
/// (an index shift with identical content must not read as a diff).
struct DiffNormalizedOffice: Equatable {
    var blockCount: Int
    var text: String
    /// One `"<rows>x<cols>"` entry per table, in document order — `cols` is the widest row's span
    /// sum, the same authority `OfficeBlock.table`'s own doc comment names for a real column count.
    var tableShapes: [String]
    var imageCount: Int
    var imageByteLengths: [Int]
    var defaultBodyFontSize: CGFloat
    var pageContentWidth: CGFloat?
    var pageContentHeight: CGFloat?
    var pageMarginLeft: CGFloat?
    var pageMarginRight: CGFloat?
    var pageMarginTop: CGFloat?
    var pageMarginBottom: CGFloat?
    var headerCount: Int
    var footerCount: Int
    var footnoteCount: Int
    var masterPageCount: Int
    var sectionStartTextHashes: [Int]
    var keepWithNextCount: Int
    var pageBreakCount: Int
    var hidePageNumberCount: Int
}

/// Builds a `DiffNormalizedOffice` from a real `OfficeReadResult`, and diffs two of them. Shared by
/// the always-on fixture test and the corpus probe below, per the plan's "put the normalizer + differ
/// in a small internal type in the same file" instruction.
enum OfficeDiffNormalizer {
    static func normalize(_ result: OfficeReadResult) -> DiffNormalizedOffice {
        // Paragraph texts are compared as a SORTED multiset, not in document order: the engine
        // moves a text box that follows a pinned shape out of the body and into
        // `anchoredObjects` so it is drawn where the shape is (invariant 161 — the manual's chapter
        // dividers), while the oracle readers leave the same text in place. Same words, different
        // container; order-sensitive concatenation reported that as text LOSS. `collectText` below
        // is the one place both containers feed.
        var paragraphTexts: [String] = []
        var tableShapes: [String] = []
        var blockCount = 0

        func spanText(_ spans: [Span]) -> String { spans.map { $0.text }.joined() }
        func collectText(_ t: String) { if !t.isEmpty { paragraphTexts.append(t) } }

        func walk(_ blocks: [OfficeBlock]) {
            for block in blocks {
                blockCount += 1
                switch block {
                case .heading(_, let spans, _, _, _, _):
                    collectText(spanText(spans))
                case .paragraph(let spans, _, _, _, _):
                    collectText(spanText(spans))
                case .listItem(_, _, let spans, _, _, _, _, _, _):
                    collectText(spanText(spans))
                case .table(let rows, _, _, _):
                    let colCount = rows.map { row in row.reduce(0) { $0 + $1.colSpan } }.max() ?? 0
                    tableShapes.append("\(rows.count)x\(colCount)")
                    for row in rows {
                        for cell in row { walk(cell.blocks) }
                    }
                case .image, .unsupportedGraphic:
                    break
                case .formula(let latex):
                    collectText(latex)
                }
            }
        }
        walk(result.blocks)
        // Text the engine parked on an anchored object counts as text, not as blocks (the body
        // keeps a zero-height placeholder at the original index, so `blockCount` already matches).
        let bodyBlockCount = blockCount
        for anchored in result.anchoredObjects {
            if case .text(let blocks) = anchored.object.content { walk(blocks) }
        }
        blockCount = bodyBlockCount
        let text = paragraphTexts.sorted().joined(separator: "\n")

        // The block a `sectionStartBlocks` index points AT, by its own text — not the index
        // itself, per §4: a reader that numbered blocks slightly differently (a synthetic block
        // the other reader doesn't emit) must not turn into a false diff here.
        func leadingText(fromBlockAt index: Int) -> String {
            guard index >= 0, index < result.blocks.count else { return "" }
            switch result.blocks[index] {
            case .heading(_, let spans, _, _, _, _): return spanText(spans)
            case .paragraph(let spans, _, _, _, _): return spanText(spans)
            case .listItem(_, _, let spans, _, _, _, _, _, _): return spanText(spans)
            case .formula(let latex): return latex
            default: return ""
            }
        }
        let sectionHashes = result.sectionStartBlocks.map { leadingText(fromBlockAt: $0).hashValue }

        func round01(_ value: CGFloat?) -> CGFloat? {
            value.map { (($0 * 100).rounded()) / 100 }
        }

        return DiffNormalizedOffice(
            blockCount: blockCount,
            text: text,
            tableShapes: tableShapes,
            imageCount: result.images.count,
            imageByteLengths: result.images.values.map(\.count).sorted(),
            defaultBodyFontSize: (round01(result.defaultBodyFontSize) ?? result.defaultBodyFontSize),
            pageContentWidth: round01(result.pageContentWidth),
            pageContentHeight: round01(result.pageContentHeight),
            pageMarginLeft: round01(result.pageMarginLeft),
            pageMarginRight: round01(result.pageMarginRight),
            pageMarginTop: round01(result.pageMarginTop),
            pageMarginBottom: round01(result.pageMarginBottom),
            headerCount: result.headers.count,
            footerCount: result.footers.count,
            footnoteCount: result.footnotes.count,
            masterPageCount: result.masterPages.count,
            sectionStartTextHashes: sectionHashes,
            keepWithNextCount: result.keepWithNextBlocks.count,
            pageBreakCount: result.pageBreakBlocks.count,
            hidePageNumberCount: result.hidePageNumberBlocks.count)
    }

    /// Every field name that differs between `a` and `b` — the vocabulary the TSV `diff_fields`
    /// column and the class taxonomy below are both built from.
    static func diffFields(_ a: DiffNormalizedOffice, _ b: DiffNormalizedOffice) -> [String] {
        var diffs: [String] = []
        if a.text != b.text { diffs.append("text") }
        if a.blockCount != b.blockCount { diffs.append("blockCount") }
        if a.tableShapes != b.tableShapes { diffs.append("tableShapes") }
        if a.imageCount != b.imageCount { diffs.append("imageCount") }
        if a.imageByteLengths != b.imageByteLengths { diffs.append("imageByteLengths") }
        if a.defaultBodyFontSize != b.defaultBodyFontSize { diffs.append("defaultBodyFontSize") }
        if a.pageContentWidth != b.pageContentWidth { diffs.append("pageContentWidth") }
        if a.pageContentHeight != b.pageContentHeight { diffs.append("pageContentHeight") }
        if a.pageMarginLeft != b.pageMarginLeft { diffs.append("pageMarginLeft") }
        if a.pageMarginRight != b.pageMarginRight { diffs.append("pageMarginRight") }
        if a.pageMarginTop != b.pageMarginTop { diffs.append("pageMarginTop") }
        if a.pageMarginBottom != b.pageMarginBottom { diffs.append("pageMarginBottom") }
        if a.headerCount != b.headerCount { diffs.append("headerCount") }
        if a.footerCount != b.footerCount { diffs.append("footerCount") }
        if a.footnoteCount != b.footnoteCount { diffs.append("footnoteCount") }
        if a.masterPageCount != b.masterPageCount { diffs.append("masterPageCount") }
        if a.sectionStartTextHashes != b.sectionStartTextHashes { diffs.append("sectionStartTextHashes") }
        if a.keepWithNextCount != b.keepWithNextCount { diffs.append("keepWithNextCount") }
        if a.pageBreakCount != b.pageBreakCount { diffs.append("pageBreakCount") }
        if a.hidePageNumberCount != b.hidePageNumberCount { diffs.append("hidePageNumberCount") }
        return diffs
    }

    /// §4's `class` column, one bucket per diff cause — `text` and `blockCount` outrank a table
    /// shape, which outranks page geometry, which outranks an image-only diff, matching the order
    /// a reader would notice the defects in (wrong words on the page beats a wrong page number).
    /// `fallback` is the one case §4 calls out explicitly: an image diff where one side reports
    /// zero images and the other doesn't is the engine's own known-fallback shape (invariant 115's
    /// 11 documents), not an ordinary content disagreement.
    static func classify(diffFields: [String], oracleImages: Int, engineImages: Int) -> String {
        guard !diffFields.isEmpty else { return "same" }
        let textFields: Set<String> = ["text", "blockCount"]
        let tableFields: Set<String> = ["tableShapes"]
        let imageFields: Set<String> = ["imageCount", "imageByteLengths"]
        if diffFields.allSatisfy({ imageFields.contains($0) }), (oracleImages == 0) != (engineImages == 0) {
            return "fallback"
        }
        if diffFields.contains(where: { textFields.contains($0) }) { return "text" }
        if diffFields.contains(where: { tableFields.contains($0) }) { return "table" }
        if diffFields.contains(where: { imageFields.contains($0) }) { return "images" }
        return "geometry"
    }
}

/// The differential harness: every real docx/dotx/docm/dotm/odt/hwp/hwpx under
/// `FMD_DIFF_CORPUS` (colon-separated directories), read by BOTH the Swift oracle readers
/// (`DocxReader`/`OdtReader`/`HwpReader` — kept alive as the reference, invariant 112) and the
/// Rust engine (`RustEngine.readOffice`, the production path), normalized, diffed, and then
/// rendered through the SAME paged path (`DocumentWindowController.printPageCount`, the number
/// `⌘P`/`--pdf` actually print) to compare sheet counts.
///
///     FMD_DIFF_CORPUS="$HOME/…/demo:$HOME/…/testdocs" FMD_DIFF_OUT=/tmp/diff.tsv \
///       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --filter OfficeDifferentialHarnessTests
///
/// Skipped by default: needs documents this repo does not ship beyond `demo/`/`testdocs/`. Modeled
/// on `CorpusRenderProbeTests`' walk (print-before-build so a trap still names the offender) and its
/// `FMD_*_OUT` file-report rule (stdout is interleaved and unreliable for a long run's evidence).
///
/// PRIVACY: never prints or writes document TEXT — only paths, counts, and field names.
final class OfficeDifferentialHarnessTests: XCTestCase {
    private struct Row {
        let path: String
        let ext: String
        let oracleOk: Bool
        let engineOk: Bool
        let diffFields: [String]
        let sheetsOracle: Int?
        let sheetsEngine: Int?
        let cls: String
    }

    // MARK: - Reading both implementations

    /// The Swift reference readers — never routed through `DocumentTypes.readOffice`, which under
    /// some builds dispatches to the engine itself and would turn this into the engine compared
    /// against itself (the same guard `RustEngineBridgeTests.swiftReference` documents).
    /// Not `private`: `RenderTreeAdapterParityTests` reuses this door (and `readEngine` below)
    /// rather than opening a third comparison, per this file's own module doc.
    static func readOracle(_ data: Data, ext: String) throws -> OfficeReadResult {
        if DocumentTypes.isHwp(ext) {
            return try HwpReader.read(data)
        }
        let archive = try ZipArchive(data: data)
        return ext == "odt" ? try OdtReader.read(archive) : try DocxReader.read(archive)
    }

    /// Every `.image(id:)` id a block tree references, recursing into table cells the way
    /// `OfficeDiffNormalizer.walk` already does for text.
    private static func imageIds(in blocks: [OfficeBlock]) -> Set<String> {
        var ids: Set<String> = []
        func walk(_ blocks: [OfficeBlock]) {
            for block in blocks {
                switch block {
                case .image(let id, _, _):
                    ids.insert(id)
                case .table(let rows, _, _, _):
                    for row in rows { for cell in row { walk(cell.blocks) } }
                default:
                    break
                }
            }
        }
        walk(blocks)
        return ids
    }

    /// The engine's `OfficeReadResult`, through the SAME door the app fills a document's pictures
    /// from — never `RustEngine.readOffice` alone, which is a one-shot read whose `images` map is
    /// empty for HWP by design (`RustOfficeDocumentHandle.picture`'s own P2c doc comment: a picture
    /// is fetched from the still-open parse handle when something is about to draw it, not
    /// pre-decoded at read time). `RustEngine.readOffice(data:extension:)` never opens that handle,
    /// so comparing its bare result against the oracle's (which — `OfficeReadResult.images`'s own
    /// doc comment — pre-decodes every HWP picture at read time) reads every HWP with pictures as a
    /// content diff that is not one; the reader on screen never shows an empty document.
    ///
    /// docx/odt are untouched by this: `RustOfficeDocumentHandle.picture` returns `nil` for them by
    /// design (their pictures come from the ZIP archive the host holds, not the engine's parse), and
    /// the oracle's own `images` map is empty for them too (`OfficeReadResult.images`'s doc comment),
    /// so there is nothing to fill in.
    static func readEngine(_ data: Data, ext: String) -> OfficeReadResult? {
        guard let handle = RustOfficeDocumentHandle(data: data, extension: ext) else { return nil }
        guard var result = handle.officeContent(bytes: data) else { return nil }
        guard DocumentTypes.isHwp(ext) else { return result }

        var ids = Self.imageIds(in: result.blocks)
        for header in result.headers { ids.formUnion(Self.imageIds(in: header.blocks)) }
        for footer in result.footers { ids.formUnion(Self.imageIds(in: footer.blocks)) }
        for footnote in result.footnotes { ids.formUnion(Self.imageIds(in: footnote.blocks)) }
        for id in ids where result.images[id] == nil {
            if let bytes = handle.picture(id: id) { result.images[id] = bytes }
        }
        return result
    }

    // MARK: - Sheet count, through the real paged path

    /// `nil` when the document declares no page height at all — an unpaged document has no sheet
    /// count to compare (§4/§5: this harness does not invent a paged concept for a format that
    /// declares none). Otherwise builds a throwaway `MarkdownDocument` straight from the ORACLE
    /// reader's own `OfficeReadResult` (`setOfficeContent`, the seam `OfficeDocumentTests` already
    /// uses to drive synthetic content independent of any particular reader) and reads back
    /// `DocumentWindowController.printPageCount` — the exact number `⌘P`/`--pdf` print, not a
    /// second formula (see that property's own doc comment).
    ///
    /// This is the ORACLE side only. It passes no `engineHandle`, exactly like the oracle readers
    /// themselves: `DocxReader`/`OdtReader`/`HwpReader` never open a Rust parse handle, so a
    /// document whose layout leans on one (footnote heights, band sides, table placement, `sheets`
    /// itself — every `officeEngineHandle?`-gated query in `MarkdownDocument`/
    /// `DocumentWindowController`) falls back to the host's own arithmetic here exactly as it would
    /// for a real oracle-only read. That is a real difference from the app's own count and is
    /// exactly why the ENGINE side below cannot reuse this function.
    private static func oracleSheetCount(for result: OfficeReadResult) -> Int? {
        guard result.pageContentHeight != nil else { return nil }
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-diff-sheet-\(UUID().uuidString).docx")
        doc.setOfficeContent(
            blocks: result.blocks, comments: result.comments, archive: nil,
            images: result.images, defaultBodyFontSize: result.defaultBodyFontSize,
            pageContentWidth: result.pageContentWidth,
            pageMarginLeft: result.pageMarginLeft, pageMarginRight: result.pageMarginRight,
            pageContentHeight: result.pageContentHeight,
            pageMarginTop: result.pageMarginTop, pageMarginBottom: result.pageMarginBottom,
            pageHeaderDistance: result.pageHeaderDistance, pageFooterDistance: result.pageFooterDistance,
            headers: result.headers, footers: result.footers,
            footnotes: result.footnotes, masterPages: result.masterPages,
            sectionStartBlocks: result.sectionStartBlocks,
            pageBreakBlocks: result.pageBreakBlocks,
            keepWithNextBlocks: result.keepWithNextBlocks,
            hidePageNumberBlocks: result.hidePageNumberBlocks,
            pageNumberRestartBlocks: result.pageNumberRestartBlocks,
            sections: result.sections, anchoredObjects: result.anchoredObjects,
            lineGridPitch: result.lineGridPitch)
        doc.makeWindowControllers()
        guard let wc = doc.windowControllers.first as? DocumentWindowController else { return nil }
        // The same settle sequence `PrintPaginationTests.settle` uses for a synthetic paged
        // document: lay the window out, then the whole text, then reserve the trailing footer band
        // `printPageCount` measures against.
        wc.textView.postsFrameChangedNotifications = false
        wc.textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = false
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.updateTextInset()
        if let container = wc.textView.textContainer {
            wc.textView.layoutManager?.ensureLayout(for: container)
        }
        wc.applyTrailingFooterBand()
        return Self.printedSheetCount(wc)
    }

    /// The ENGINE side, through the REAL production door — `MarkdownDocument.read(from:ofType:)` on
    /// the file's own bytes, nothing injected (not `setOfficeContent`, not a hand-built
    /// `OfficeReadResult`): that seam is what opens the live `RustOfficeDocumentHandle` and threads
    /// it into `officeEngineHandle`, which layout leans on for footnote heights, band sides, table
    /// placement and the `sheets` grid itself — every one of which silently fell back to host
    /// arithmetic when this harness built its `MarkdownDocument` from a pre-parsed `OfficeReadResult`
    /// instead (1869 sheets reported for a manual `--pdf` prints as 391). The settle sequence below
    /// is `HeadlessPDF.run`'s own — same seed width, same `waitForRenderToSettle`, same paged/.fit
    /// column correction, same two calls before `printPageCount` — reusing its `static func`s
    /// directly rather than a second copy, so a drift in the app's own settle logic cannot silently
    /// stop being reflected here.
    private static func engineSheetCount(path: String, data: Data) -> Int? {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: path)
        guard (try? doc.read(from: data, ofType: "public.data")) != nil else { return nil }
        guard doc.officePageContentHeight != nil else { return nil }
        doc.makeWindowControllers()
        guard let wc = doc.windowControllers.first as? DocumentWindowController else { return nil }
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 820, height: 640), display: false)
        _ = HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
        if let window = wc.window,
           let corrected = HeadlessPDF.printColumnCorrection(
               windowWidth: window.frame.width, viewWidth: wc.textView.frame.width,
               target: HeadlessPDF.paperImageableWidth(), isPaged: wc.pagedDocumentWidth != nil) {
            window.setFrame(NSRect(x: 0, y: 0, width: corrected, height: 640), display: false)
            _ = HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
        }
        guard let container = wc.textView.textContainer else { return nil }
        wc.textView.layoutManager?.ensureLayout(for: container)
        wc.applyTrailingFooterBand()
        return Self.printedSheetCount(wc)
    }

    /// The count `makePrintOperation` prints, taken the way it takes it: the print layout is begun,
    /// the paged tables are settled fully, the trailing band is reserved, and THEN the sheets are
    /// read. `printPageCount` before those two calls is the SCREEN's count — on the reference manual
    /// it reads 403 where `--pdf` writes 391, because a table crossing a page boundary is only
    /// resolved by `settlePagedTablesFully` (invariants 61/64/72). Same for both sides.
    private static func printedSheetCount(_ wc: DocumentWindowController) -> Int {
        wc.beginPrintLayout()
        wc.settlePagedTablesFully()
        wc.applyTrailingFooterBand()
        return wc.printSheets.count
    }

    // MARK: - Always-on: the normalizer + differ actually work, on a deterministic fixture

    /// Never skipped. Proves the normalizer/differ pair this file defines agrees on a document
    /// every checkout has (`S1BOfficeFixtures.docx`, the same deterministic fixture
    /// `RustEngineBridgeTests` bridges), AND that the normalizer is not hollow — it must actually
    /// have visited more than zero blocks, or an empty diff would trivially "pass" against an empty
    /// normalization of nothing (the mutation-hygiene guard §4 in effect, invariant-family 5/106).
    func testNormalizerAndDifferAgreeOnDeterministicFixture() throws {
        let data = S1BOfficeFixtures.docx
        let archive = try ZipArchive(data: data)
        let oracle = try DocxReader.read(archive)
        let engine = try XCTUnwrap(RustEngine.readOffice(data, extension: "docx"),
                                   "the engine must read the S1B docx fixture")

        let normOracle = OfficeDiffNormalizer.normalize(oracle)
        let normEngine = OfficeDiffNormalizer.normalize(engine)

        XCTAssertGreaterThan(normOracle.blockCount, 0,
                             "hollow-normalizer guard: the fixture must produce real blocks")
        XCTAssertGreaterThan(normOracle.text.count, 0,
                             "hollow-normalizer guard: the fixture must produce real text")

        let diffs = OfficeDiffNormalizer.diffFields(normOracle, normEngine)
        XCTAssertEqual(diffs, [],
                       "oracle vs engine normalized diff must be empty on the deterministic S1B fixture")
    }

    // MARK: - Pin: the harness's engine sheet count IS the app's

    /// Never trust `engineSheetCount` on its say-so — prove it against a REAL `--pdf` run of the
    /// same file, counted from the PDF's own page objects (`PDFKit`, not a third formula). Skipped
    /// by default: needs a real document beyond `demo/`/`testdocs/`.
    ///
    ///     FMD_DIFF_PIN_DOC=<document> swift test --filter testEngineSheetCountPinnedToHeadlessPDF
    func testEngineSheetCountPinnedToHeadlessPDF() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_DIFF_PIN_DOC"] else {
            throw XCTSkip("set FMD_DIFF_PIN_DOC=<document> to pin the harness's engine sheet count to a real --pdf run")
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()

        let harnessCount = try XCTUnwrap(Self.engineSheetCount(path: url.path, data: data),
                                         "the harness must report a sheet count for a paged document")

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmd-diff-pin-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: outURL) }
        let exitCode = HeadlessPDF.run([url.path, "-o", outURL.path, "-f"])
        XCTAssertEqual(exitCode, 0, "--pdf must succeed on \(path)")
        let pdf = try XCTUnwrap(PDFDocument(url: outURL), "the written file must be a readable PDF")
        let appCount = pdf.pageCount

        print("pin[\(ext)] \(path): harness=\(harnessCount) app(--pdf)=\(appCount)")
        XCTAssertLessThanOrEqual(abs(harnessCount - appCount), 2,
            "the harness's engine sheet count (\(harnessCount)) must be within 2 of the app's own --pdf count (\(appCount))")
    }

    // MARK: - The corpus probe

    func testDifferentialCorpus() throws {
        guard let dirList = ProcessInfo.processInfo.environment["FMD_DIFF_CORPUS"] else {
            throw XCTSkip("set FMD_DIFF_CORPUS (colon-separated directories) to run the office differential harness")
        }
        let roots = dirList.split(separator: ":").map { URL(fileURLWithPath: String($0)) }

        var rows: [Row] = []
        var classCounts: [String: Int] = [:]

        for root in roots {
            // Explicit error handler for the reason `CorpusRenderProbeTests` records: without one
            // the enumerator stops SILENTLY at the first unreadable subdirectory.
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [],
                errorHandler: { _, _ in true }
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
                guard DocumentTypes.isHwp(ext) || ["docx", "docm", "dotx", "dotm", "odt"].contains(ext)
                else { continue }
                let base = url.lastPathComponent
                // AppleDouble sidecars and Word's own lock stubs carry a document extension and no
                // document (`CorpusRenderProbeTests`' own note).
                guard !base.hasPrefix("._"), !base.hasPrefix("~$") else { continue }

                // Printed BEFORE any read: PRIVACY-safe (path only) and the last line printed names
                // the offender if something downstream traps.
                print("diff[\(rows.count + 1)] \(url.path)")

                guard let data = try? Data(contentsOf: url) else {
                    rows.append(Row(path: url.path, ext: ext, oracleOk: false, engineOk: false,
                                    diffFields: ["unreadable"], sheetsOracle: nil, sheetsEngine: nil,
                                    cls: "error"))
                    classCounts["error", default: 0] += 1
                    continue
                }

                let oracleResult = try? Self.readOracle(data, ext: ext)
                let engineResult = Self.readEngine(data, ext: ext)

                guard let oracle = oracleResult, let engine = engineResult else {
                    rows.append(Row(path: url.path, ext: ext, oracleOk: oracleResult != nil,
                                    engineOk: engineResult != nil, diffFields: ["read"],
                                    sheetsOracle: nil, sheetsEngine: nil, cls: "error"))
                    classCounts["error", default: 0] += 1
                    continue
                }

                let normOracle = OfficeDiffNormalizer.normalize(oracle)
                let normEngine = OfficeDiffNormalizer.normalize(engine)
                let fieldDiffs = OfficeDiffNormalizer.diffFields(normOracle, normEngine)

                let sheetsOracle = Self.oracleSheetCount(for: oracle)
                let sheetsEngine = Self.engineSheetCount(path: url.path, data: data)
                var allDiffs = fieldDiffs
                let sheetsDiffer = sheetsOracle != sheetsEngine
                if sheetsDiffer { allDiffs.append("sheets") }

                let cls: String
                if allDiffs.isEmpty {
                    cls = "same"
                } else if fieldDiffs.isEmpty, sheetsDiffer {
                    cls = "sheets"
                } else {
                    cls = OfficeDiffNormalizer.classify(diffFields: fieldDiffs,
                                                        oracleImages: normOracle.imageCount,
                                                        engineImages: normEngine.imageCount)
                }

                classCounts[cls, default: 0] += 1
                rows.append(Row(path: url.path, ext: ext, oracleOk: true, engineOk: true,
                                diffFields: allDiffs, sheetsOracle: sheetsOracle,
                                sheetsEngine: sheetsEngine, cls: cls))
            }
        }

        let classSummary = "class_summary " + classCounts.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("differential harness: \(rows.count) documents")
        print(classSummary)

        if let out = ProcessInfo.processInfo.environment["FMD_DIFF_OUT"] {
            var lines = ["path\text\toracle_ok\tengine_ok\tdiff_fields\tsheets_oracle\tsheets_engine\tclass"]
            for row in rows {
                lines.append([
                    row.path, row.ext, row.oracleOk ? "1" : "0", row.engineOk ? "1" : "0",
                    row.diffFields.joined(separator: ";"),
                    row.sheetsOracle.map(String.init) ?? "",
                    row.sheetsEngine.map(String.init) ?? "",
                    row.cls,
                ].joined(separator: "\t"))
            }
            lines.append(classSummary)
            let report = lines.joined(separator: "\n") + "\n"
            try report.write(toFile: out, atomically: true, encoding: .utf8)
        }

        XCTAssertGreaterThan(rows.count, 0, "FMD_DIFF_CORPUS matched no office documents")
    }
}
