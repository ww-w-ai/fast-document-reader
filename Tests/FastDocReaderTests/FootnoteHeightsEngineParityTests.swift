import XCTest
@testable import FastDocReader

/// S5D-2 — `RustOfficeDocumentHandle.footnoteHeights` (the FFI crossing) and
/// `PageBandGeometry.resolveNoteHeights` (`s5d2.md`'s own seam: the choice `MarkdownDocument`
/// makes between the engine's reply and the host's own loop, pulled out as a pure function so a
/// unit test can watch the branch judgment itself, not just the arithmetic either side of it).
///
/// **A real non-empty round-trip is not reachable on this machine.** Neither the Swift `DocxReader`
/// nor its Rust port lift a docx's footnotes into `OfficeReadResult.footnotes` yet — both still
/// flat-append note bodies into `.blocks`, invariant 99's pre-lift shape (`docx_reader/part_a.rs`,
/// `DocxReader.swift`, confirmed by reading both — this is not this sprint's gap to close, S5D-2
/// only measures whatever `.footnotes` already holds). The lift exists for HWP
/// (`HwpReader.swift:501`), and no HWP fixture on this machine cites one (checked:
/// `Vendor/rhwp-src/saved/*.hwp`, all `footnotes.count == 0`). So the arithmetic's real-content
/// correctness — `built_height` called per note, and refusing the WHOLE batch on the first one it
/// cannot measure — is proven at the Rust layer instead
/// (`page_band_measure_port_absence.rs::the_first_unmeasurable_note_refuses_the_whole_batch…`,
/// which uses a real `Span` with real text). What THIS file proves is everything downstream of that
/// arithmetic: the crossing's own mechanics for the one case reachable here (a real docx, zero
/// lifted footnotes) and the Swift-side seam's branch judgments, all as pure-function unit tests.
///
///   1. the crossing itself — a real handle answers a real, empty round-trip (not `nil`).
///   2. rejection direction — the seam falls back to the host when the engine cannot answer at all.
///   3. the parsing-branch judgment — a host number the engine's reply does not name rejects the
///      WHOLE map, never just that entry.
///   4. invariant 103 — when engine values are ones `built_height` could never itself produce
///      (negative), `resolveNoteHeights` still hands them back verbatim: what is USED is the
///      engine's answer, not a value the seam recomputed.
///   5. key integrity — a reply keyed out of order still lands on its own number, never by
///      position.
final class FootnoteHeightsEngineParityTests: XCTestCase {

    private func fixture(_ repoRootRelativePath: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(repoRootRelativePath)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw XCTSkip("\(repoRootRelativePath) is gitignored and absent in this checkout")
        }
        return data
    }

    // MARK: - 1. The crossing itself — a real handle, a real (empty) round-trip

    /// `docs/fixtures/office/notes.docx` is a real docx with real footnote XML — proving the
    /// buffer-sizing/decode mechanics work on a genuine document, even though its two notes never
    /// reach `.footnotes` (see the class doc). `count: 0` sizes the reply buffer to the FFI's own
    /// stated floor (`max(count, 1)`), and the answer must be an EMPTY map, not `nil` — a document
    /// with nothing to measure needs no port at all, so this must succeed with no measurer
    /// installed either.
    func testARealHandleAnswersARealEmptyRoundTripWithNoMeasurerNeeded() throws {
        let data = try fixture("docs/fixtures/office/notes.docx")
        RustEngineFonts.install()
        let handle = try XCTUnwrap(RustOfficeDocumentHandle(data: data, extension: "docx"))
        let before = handle.answeredQueries
        let heights = try XCTUnwrap(handle.footnoteHeights(
            count: 0, columnWidth: 400, pageContentWidth: nil, documentDefaultFontSize: 11),
            "an empty batch must answer, never refuse")
        XCTAssertEqual(heights, [:])
        XCTAssertEqual(handle.answeredQueries, before + 1, "the crossing must have happened")
    }

    // MARK: - 2. Rejection direction — the seam falls back when the engine cannot answer at all

    /// `PageBandGeometry.resolveNoteHeights`'s own half of the same direction — `MarkdownDocument`'s
    /// fallback trigger IS `engine == nil`, exercised here without any FFI at all.
    func testResolveNoteHeightsFallsBackWhenTheEngineAnswerIsNil() {
        XCTAssertNil(PageBandGeometry.resolveNoteHeights(hostNumbers: [1, 2], engine: nil))
    }

    // MARK: - 3. The parsing-branch judgment — one missing number rejects the WHOLE map

    func testAHostNumberMissingFromTheEngineReplyRejectsTheWholeMapNotJustThatEntry() {
        // The engine named 1 but not 2 — even though 1's height is right there.
        let resolved = PageBandGeometry.resolveNoteHeights(hostNumbers: [1, 2], engine: [1: 40])
        XCTAssertNil(resolved, "a map missing ANY number this render will draw must be rejected whole")
    }

    func testEveryHostNumberPresentResolvesEvenWithExtraEngineOnlyNumbers() {
        // The engine also named 9, which this render never asked to draw — ignored, not an error.
        let resolved = PageBandGeometry.resolveNoteHeights(hostNumbers: [1, 2], engine: [1: 40, 2: 60, 9: 999])
        XCTAssertEqual(resolved, [1: 40, 2: 60])
    }

    // MARK: - 4. Invariant 103 — the value used is the engine's, not a recomputed one

    /// `built_height` can never answer a NEGATIVE number (it is a laid-out `NSLayoutManager` rect
    /// height, always `>= 0`) — so `-777`/`-888` are values no host recomputation could ever
    /// produce. `resolveNoteHeights` hands them back unchanged, proving the seam forwards the
    /// engine's own answer rather than substituting a value derived some other way.
    func testTheResolvedMapCarriesTheEnginesOwnValuesEvenWhenTheyAreImpossibleForTheHostToProduce() {
        let resolved = PageBandGeometry.resolveNoteHeights(hostNumbers: [2, 3], engine: [2: -777, 3: -888])
        XCTAssertEqual(resolved, [2: -777, 3: -888],
                       "the seam must pass the engine's own reply through untouched, never a "
                       + "value only the host's own arithmetic could have produced")
    }

    // MARK: - 5. Key integrity — a reply keyed out of order still lands on its own number

    func testANonSequentialHostOrderStillResolvesEachNumberToItsOwnEngineHeight() {
        // `hostNumbers` deliberately DESCENDING and non-contiguous — a bridge or seam that zipped
        // by POSITION rather than looking each number up would put 22 at host-position 0 (number 5)
        // instead of at number 3.
        let resolved = PageBandGeometry.resolveNoteHeights(hostNumbers: [5, 3], engine: [3: 22, 5: 11])
        XCTAssertEqual(resolved?[5], 11)
        XCTAssertEqual(resolved?[3], 22)
    }
}
