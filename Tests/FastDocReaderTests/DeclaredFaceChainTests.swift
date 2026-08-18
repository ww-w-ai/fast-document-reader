import AppKit
import XCTest
@testable import FastDocReader

/// What stands in for a declared family this machine cannot resolve. The rule the whole chain exists
/// to serve is invariant 57's — the document is the truth and the app contributes nothing — so the
/// order is by how DIRECTLY the document said it, and the app's own inference is asked LAST.
final class DeclaredFaceChainTests: XCTestCase {

    // MARK: - The declared-kind block, and why it is not read

    /// Ten bytes as a font table would carry them. Named `panose` because that is what it is on the
    /// HWP5 path; on the HWPX path byte 0 is an `FCAT_*` enum instead, which is the whole problem.
    private func panose(kind: UInt8, serifStyle: UInt8) -> [UInt8] {
        [kind, serifStyle, 0, 0, 0, 0, 0, 0, 0, 0]
    }

    /// Ten bytes on a font-table entry, and this reader reads none of them. The reason is a finding,
    /// not an omission: **byte 0 carries a different vocabulary depending on which format the file was
    /// saved in, and nothing in the export says which.** HWP5 copies the file's own PANOSE bytes
    /// (`parser/doc_info.rs:281`) where 3 = Hand Written and 5 = Symbol; HWPX writes an OWPML `FCAT_*`
    /// enum into the same byte (`parser/hwpx/header.rs:474`) where 3 = FCAT_SSERIF (sans!) and
    /// 5 = FCAT_DECORATIVE. Picking either reading is wrong for every file saved the other way.
    ///
    /// This test is what stops that from being quietly re-added: every value that means something
    /// different under the two readings must produce NO claim.
    func testTheDeclaredKindBlockIsNotReadWhileItsMeaningDependsOnTheFileFormat() {
        for byte0: UInt8 in 0...7 {
            XCTAssertNil(DeclaredFace(typeInfo: panose(kind: byte0, serifStyle: 2)).declaredKind,
                         "byte 0 = \(byte0) means one thing in a HWP5 file and another in a HWPX one; "
                         + "until the exporter says which, this reader must make no claim from it")
        }
        XCTAssertNil(DeclaredFace(typeInfo: nil).declaredKind)
    }

    /// The value is still CARRIED, so a later sprint can consume it once the exporter normalises the
    /// two vocabularies. Dropping it from the type would make that sprint re-do the export.
    func testTheBlockIsStillCarriedEvenThoughItIsNotRead() {
        let face = DeclaredFace(typeInfo: panose(kind: 1, serifStyle: 11))
        XCTAssertEqual(face.typeInfo?.count, 10, "the bytes are kept for a sprint that can read them")
        XCTAssertNotEqual(DeclaredFace(typeInfo: nil), face,
                          "and 'said nothing' stays distinguishable from 'said something'")
    }

    // MARK: - The order, end to end through the real resolver

    /// A paragraph whose declared family does not exist, so the chain has to answer.
    private func paragraph(font: String, text: String = "가나다라마바사") -> OfficeBlock {
        var span = Span(text: text)
        span.fontName = font
        return .paragraph(spans: [span])
    }

    private func resolvedFont(_ block: OfficeBlock, faces: [String: DeclaredFace]) -> String? {
        let plan = FontSubstitutionResolver.plan(for: [block], declaredFaces: faces)
        let resolved = block.applyingFontSubstitution(plan)
        guard case let .paragraph(spans, _, _, _, _) = resolved else { return nil }
        return spans.first?.resolvedFontDescriptor?.postscriptName
    }

    /// The whole point, in one assertion: a serif document stops being drawn in a sans face. Before
    /// this chain the declared name was discarded the moment `NSFont(name:)` returned nil and the
    /// reader's own UI font stood in, which is why the reference 편람's PDF embedded
    /// `.AppleSDGothicNeo` for a document that declares 명조.
    func testASerifDeclarationNoLongerResolvesToTheReadersSansUIFont() {
        let resolved = resolvedFont(paragraph(font: "HY신명조"), faces: [:])
        XCTAssertNotNil(resolved)
        XCTAssertTrue(resolved!.localizedCaseInsensitiveContains("Myungjo"),
                      "expected a serif face, got \(resolved!)")
    }

    func testASansDeclarationStillResolvesToASansFace() {
        let resolved = resolvedFont(paragraph(font: "HY중고딕"), faces: [:])
        XCTAssertNotNil(resolved)
        XCTAssertTrue(resolved!.localizedCaseInsensitiveContains("Gothic"),
                      "expected a sans face, got \(resolved!)")
    }

    /// A substitute the DOCUMENT nominated outranks one this reader inferred from the name — even
    /// when the name's own morpheme points elsewhere. This is the case invariant 95 measured as
    /// firing zero times on a machine without Hancom Office, and it is built for the machine that has
    /// them; asserting it with a face that DOES exist here is how the ordering gets tested at all.
    func testTheDocumentsOwnNominationBeatsWhatTheNameImplies() {
        let faces = ["HY중고딕": DeclaredFace(nominatedSubstitute: "AppleMyungjo")]
        let resolved = resolvedFont(paragraph(font: "HY중고딕"), faces: faces)
        XCTAssertEqual(resolved, "AppleMyungjo",
                       "the name says sans; the document nominated a serif face and the document wins")
    }

    /// A declared-kind block must NOT change the outcome while it is unreadable. The name says sans,
    /// the block says FCAT_BRUSHSCRIPT under one reading and Hand Written under the other — and the
    /// answer has to be the same as if the block were absent, because this reader makes no claim from
    /// it. Without this, a future change that starts reading the byte would pass silently.
    func testAnUnreadableDeclaredKindBlockChangesNothing() {
        let withBlock = resolvedFont(paragraph(font: "HY중고딕"),
                                     faces: ["HY중고딕": DeclaredFace(typeInfo: panose(kind: 4, serifStyle: 0))])
        let without = resolvedFont(paragraph(font: "HY중고딕"), faces: [:])
        XCTAssertEqual(withBlock, without,
                       "the block is carried, not consulted — it must not move the outcome")
        XCTAssertNotNil(without)
        XCTAssertTrue(without!.localizedCaseInsensitiveContains("Gothic"),
                      "and the NAME still decides: 고딕 is sans. Got \(without!)")
    }

    /// A nomination this machine cannot resolve must not stop the chain — it falls through to the
    /// next link rather than stranding the text.
    func testAnUnresolvableNominationFallsThroughRatherThanStranding() {
        let faces = ["HY신명조": DeclaredFace(nominatedSubstitute: "A Face Nobody Has Installed")]
        let resolved = resolvedFont(paragraph(font: "HY신명조"), faces: faces)
        XCTAssertNotNil(resolved)
        XCTAssertTrue(resolved!.localizedCaseInsensitiveContains("Myungjo"),
                      "expected the morpheme rule to answer after the nomination failed, got \(resolved!)")
    }

    /// The safety property the whole design rests on: the chain PROPOSES, and coverage still decides.
    /// `Palatino Linotype` is a Latin serif with a real macOS equivalent, but Palatino cannot draw
    /// Hangul — so a Korean span declaring it must NOT end up in Palatino.
    func testAProposedFaceThatCannotDrawTheTextDoesNotGetIt() {
        let resolved = resolvedFont(paragraph(font: "Palatino Linotype", text: "가나다라"), faces: [:])
        if let resolved {
            XCTAssertFalse(resolved.localizedCaseInsensitiveContains("Palatino"),
                           "Palatino cannot draw Hangul; the coverage test must have overruled it")
        }
    }

    /// And the same face IS taken when the text is one it can draw.
    ///
    /// This asserts the half of the pass the chain had to change. Palatino DRAWS Latin, so the old
    /// shape would have stopped at "the declared font covers its sample, nothing to plan" and left the
    /// span carrying `Palatino Linotype` — a name `OfficeTextBuilder` then resolves to nil, putting the
    /// text back in the reader's own font. A stand-in has to be recorded precisely BECAUSE it worked.
    func testTheLatinEquivalentIsTakenForLatinText() {
        let resolved = resolvedFont(paragraph(font: "Palatino Linotype", text: "Latin text here"),
                                    faces: [:])
        XCTAssertNotNil(resolved, "the stand-in must reach the span, not just the decision")
        XCTAssertTrue(resolved!.localizedCaseInsensitiveContains("Palatino"),
                      "expected Palatino, got \(resolved!)")
    }

    /// The other half of that: a span whose declared family DOES resolve is still left completely
    /// untouched. Invariant 37 depends on an unsubstituted span coming back byte-identical, and the
    /// chain must not have widened what counts as substituted.
    func testASpanWhoseFamilyResolvesIsStillLeftAlone() {
        let block = paragraph(font: "Helvetica", text: "Latin text here")
        let plan = FontSubstitutionResolver.plan(for: [block])
        XCTAssertTrue(plan.isEmpty, "nothing should be planned for a family this machine has")
        XCTAssertEqual(block.applyingFontSubstitution(plan), block, "and the block is unchanged")
    }
}

extension DeclaredFaceChainTests {
    /// The cost gate, and it is a COUNT rather than a stopwatch — invariant 49's idiom, and the only
    /// instrument fine enough for a change this small on a machine whose suite is documented as flaky
    /// above load ~50.
    ///
    /// Two otherwise-good features in this same area are permanently rejected purely because they were
    /// measured too slow (invariant 32: 45 ms → 301 ms; invariant 55: 69,460 ms), so a chain that
    /// quietly multiplied CoreText round-trips would be the failure this repo has already paid for
    /// twice. The bound the design claims is `target faces × sample characters`, not
    /// `candidates × declared fonts`, because both `declaredFontMemo` and the coverage memo already
    /// exist — this asserts the claim rather than restating it.
    func testTheChainDoesNotMultiplyCoreTextRoundTrips() {
        // Twenty DISTINCT unresolvable families, all of one kind, over the same text: the chain walks
        // once per declared font, and every one of them asks about the SAME stand-in and the SAME
        // sample character, so the memo should collapse all twenty into a handful of real calls.
        let blocks = (0..<20).map { paragraph(font: "HY신명조 \($0)") }
        let cache = FontSubstitutionCache()
        _ = FontSubstitutionResolver.plan(for: blocks, cache: cache)
        // Not a vacuous bound: the chain must actually have asked CoreText something, or this test
        // would pass just as happily on a build where nothing runs at all.
        XCTAssertGreaterThan(cache.coreTextCallCount, 0, "the pass must really have consulted CoreText")
        XCTAssertLessThanOrEqual(cache.coreTextCallCount, 8,
                                 "20 declared fonts sharing one stand-in and one sample character must "
                                 + "not cost 20 round-trips — that would mean a memo is being missed")
    }

    /// And the memo really is per DECLARED FONT, not per span: a hundred paragraphs naming the SAME
    /// family must cost exactly what one paragraph costs.
    func testAHundredParagraphsOfOneFamilyCostWhatOneCosts() {
        func calls(_ n: Int) -> Int {
            let cache = FontSubstitutionCache()
            _ = FontSubstitutionResolver.plan(for: (0..<n).map { _ in paragraph(font: "HY신명조") },
                                              cache: cache)
            return cache.coreTextCallCount
        }
        XCTAssertGreaterThan(calls(1), 0, "and this one must not be measuring nothing either")
        XCTAssertEqual(calls(100), calls(1),
                       "the survey is per declared font; making it per span is the regression the "
                       + "current design was built to remove")
    }
}

/// The half the synthetic tests above cannot prove: that a REAL document's font table actually reaches
/// the resolver in production. Every other test in this file hands `plan(for:declaredFaces:)` a table
/// it built itself, which verifies the chain's logic and nothing about the wiring — if
/// `HwpReader` never filled `OfficeReadResult.declaredFaces`, all of them would still pass and the
/// document's own nominations would silently never be consulted.
///
///     FMD_HWP_SAMPLE=<a .hwp with a font table> \
///     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///     swift test --filter DeclaredFacesReachTheResolverTests
final class DeclaredFacesReachTheResolverTests: XCTestCase {

    func testARealDocumentsFontTableReachesTheReadResult() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_HWP_SAMPLE"] else {
            throw XCTSkip("set FMD_HWP_SAMPLE to a .hwp/.hwpx path to run this")
        }
        let result = try HwpReader.read(Data(contentsOf: URL(fileURLWithPath: path)))

        XCTAssertFalse(result.declaredFaces.isEmpty,
                       "the document's font table did not reach OfficeReadResult — the chain's "
                       + "document-stated links would never fire in production, and no synthetic test "
                       + "in this file would notice")

        // Every entry must be keyed by the name a span would actually carry, or the lookup misses.
        for (name, _) in result.declaredFaces {
            XCTAssertFalse(name.isEmpty, "an empty key can never match a span's fontName")
        }

        let named = result.declaredFaces.count
        let nominating = result.declaredFaces.values.filter { $0.nominatedSubstitute != nil }.count
        let embedding = result.declaredFaces.values.filter { $0.isEmbedded }.count
        let stating = result.declaredFaces.values.filter { $0.typeInfo != nil }.count
        print("DECLAREDFACES faces=\(named) nominating=\(nominating) embedding=\(embedding) "
              + "carryingTypeInfo=\(stating)")
    }
}
