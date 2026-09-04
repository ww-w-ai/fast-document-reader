import XCTest
@testable import FastDocReader

/// U5's own proof: with schema-v4 retired, the tree door (`fastdoc_office_tree_json` ->
/// `RustEngine.decodeOfficeTree` -> `RenderTreeOfficeAdapter`) is the ONLY way this app reads an
/// office document, so there is no second door left to compare it against. What this test pins
/// instead is the KNOWN gap between that door and the Swift reference readers — U1's differential
/// harness's own measurement (`OfficeDifferentialHarnessTests`, `diff-38e.tsv`, run over
/// `testdocs/` on 2026-09-05) — so a later change that WIDENS the gap fails here, without
/// requiring the gap to be zero (`docs/02-planned/2026-09-04-diff-harness-and-rendertree-contract.md`
/// §2 decision 2: the harness compares at `OfficeReadResult` level).
///
/// Reuses `OfficeDiffNormalizer` and `OfficeDifferentialHarnessTests.readOracle`/`readEngine`
/// rather than a fourth comparison, so "identical" and "the known gap" mean what U1's own harness
/// already means them.
final class RenderTreeAdapterParityTests: XCTestCase {
    /// Path (relative to `testdocs/`) -> sorted diff field names `diff-38e.tsv` recorded for it,
    /// restricted to `OfficeDiffNormalizer.diffFields`'s own vocabulary — `diff-38e.tsv`'s `sheets`
    /// column is a SEPARATE comparison (`sheetsOracle`/`sheetsEngine`, paged sheet counts) that
    /// `diffFields` never reports, so it is not part of the pinned set this test checks.
    /// `testdocs/` is gitignored (`docx-test-corpus.md`), so most of this table finds nothing on a
    /// fresh checkout — the two synthesized fixtures below are what keeps this test real there.
    private static let knownDiffs: [String: [String]] = [
        "tables/giant-table.odt": [],
        "tables/2025_행정업무운영편람_최종.hwp": ["imageByteLengths"],
        "tables/OpenAPI활용가이드_특일정보_v1.4.docx":
            ["blockCount", "keepWithNextCount", "pageBreakCount", "text"],
        "tables/tago-tables.odt": [],
        "bulk/스케일업팁스_연구개발계획서_v6.hwp": [],
        "bulk/Zero100-2_call_full_250919.docx": ["keepWithNextCount"],
        "mini/s9-picture-crop.hwp": ["imageByteLengths"],
        "mini/s8-list-geometry.hwp": [],
        "mini/s7-page-restart.hwp": [],
        "mini/s6-cell-diagonal.hwp": [],
        "everything/사업타당성검토보고서_덕소5B구역.docx":
            ["blockCount", "keepWithNextCount", "pageBreakCount", "text"],
        "everything/GnBS_IM_20260401.docx": ["pageBreakCount", "text"],
        "everything/1790387_prep_final_report.hwpx": ["imageByteLengths"],
        "small/notes.odt": [],
        "small/인감_개인신고서_김태형.docx": [],
        "small/사업계획서_IR참가신청.hwpx": [],
        "small/내용증명_20260723.hwp": [],
        "media/카카오톡대화_피고진성호.docx": ["pageBreakCount", "text"],
        "media/test-image2.hwp": [],
        "media/pic2.hwpx": [],
    ]

    /// Always present, pinned to an exact match — no known gap touches either fixture.
    private static let synthesizedFixtures: [(name: String, ext: String, data: Data)] = [
        ("S1BOfficeFixtures.docx", "docx", S1BOfficeFixtures.docx),
        ("S1BOfficeFixtures.odt", "odt", S1BOfficeFixtures.odt),
    ]

    private static func testdocsRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("testdocs")
    }

    private func assertKnownGap(_ expected: [String], data: Data, ext: String, label: String,
                                totalBlocksVisited: inout Int) {
        guard let oracle = try? OfficeDifferentialHarnessTests.readOracle(data, ext: ext) else {
            XCTFail("\(label): the oracle reader must still answer this document")
            return
        }
        guard let engine = OfficeDifferentialHarnessTests.readEngine(data, ext: ext) else {
            XCTFail("\(label): the tree door must still answer this document")
            return
        }
        let normOracle = OfficeDiffNormalizer.normalize(oracle)
        let normEngine = OfficeDiffNormalizer.normalize(engine)
        let diffs = OfficeDiffNormalizer.diffFields(normOracle, normEngine).sorted()
        XCTAssertEqual(diffs, expected.sorted(),
                       "\(label): the tree door's gap against the oracle changed — widened or narrowed")
        totalBlocksVisited += normOracle.blockCount
    }

    /// Guards against a hollow pass (§4's mutation-hygiene discipline) by requiring at least the
    /// synthesized fixtures to have run and produced real blocks.
    func testTreeDoorMatchesTheKnownOracleGap() throws {
        var totalBlocksVisited = 0
        var checked = 0

        for fixture in Self.synthesizedFixtures {
            assertKnownGap([], data: fixture.data, ext: fixture.ext, label: fixture.name,
                           totalBlocksVisited: &totalBlocksVisited)
            checked += 1
        }

        let root = Self.testdocsRoot()
        let officeExtensions: Set<String> = ["docx", "docm", "dotx", "dotm", "odt", "hwp", "hwpx"]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                let ext = url.pathExtension.lowercased()
                guard officeExtensions.contains(ext),
                      let data = FileManager.default.contents(atPath: url.path) else { continue }
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                guard let expected = Self.knownDiffs[relative] else {
                    // Not in the pinned snapshot — U1's own corpus probe (`FMD_DIFF_CORPUS`) covers
                    // a document this repo added to `testdocs/` after `diff-38e.tsv` was recorded.
                    continue
                }
                assertKnownGap(expected, data: data, ext: ext, label: relative,
                               totalBlocksVisited: &totalBlocksVisited)
                checked += 1
            }
        }

        XCTAssertGreaterThanOrEqual(checked, Self.synthesizedFixtures.count,
                                    "at least the synthesized fixtures must run")
        XCTAssertGreaterThan(totalBlocksVisited, 0,
                             "hollow-normalizer guard: the checked fixtures together must produce real blocks")
    }
}
