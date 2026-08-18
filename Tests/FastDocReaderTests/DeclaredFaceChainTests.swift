import AppKit
import XCTest
@testable import FastDocReader

/// What stands in for a declared family this machine cannot resolve. The rule the whole chain exists
/// to serve is invariant 57's — the document is the truth and the app contributes nothing — so the
/// order is by how DIRECTLY the document said it, and the app's own inference is asked LAST.
final class DeclaredFaceChainTests: XCTestCase {

    // MARK: - PANOSE: a kind the document STATED

    /// PANOSE byte 0 = family kind (2 = Latin Text), byte 1 = serif style (2-10 serif, 11-13 sans).
    private func panose(kind: UInt8, serifStyle: UInt8) -> [UInt8] {
        [kind, serifStyle, 0, 0, 0, 0, 0, 0, 0, 0]
    }

    /// The serif-style byte is deliberately NOT read, and this is the test that keeps it that way.
    /// On an HWPX file that byte is rhwp's own `synthesize_serif_type` guess rather than anything the
    /// XML states — rhwp's export test shows the same manuscript reporting 11 from its HWP5 form and 0
    /// from its HWPX one — and nothing in the export says which path a value took. Reading it would
    /// rank another tool's inference above our own measured rules while calling it the document's word.
    func testTheSerifStyleByteIsNotTrustedBecauseOnOnePathItIsAGuess() {
        XCTAssertNil(DeclaredFace(typeInfo: panose(kind: 2, serifStyle: 2)).declaredKind,
                     "a Latin Text face states no KIND we can trust; the name rules answer instead")
        XCTAssertNil(DeclaredFace(typeInfo: panose(kind: 2, serifStyle: 11)).declaredKind)
    }

    /// Byte 0 IS the document's on both paths, and it is the one that settles the residue the name
    /// rules leave alone.
    func testTheFamilyKindByteIsRead() {
        XCTAssertEqual(DeclaredFace(typeInfo: panose(kind: 5, serifStyle: 0)).declaredKind, .symbol)
        XCTAssertEqual(DeclaredFace(typeInfo: panose(kind: 3, serifStyle: 0)).declaredKind, .unclassified)
    }

    /// A hand-written or decorative face is a kind in its own right, and the honest answer for it is
    /// the same one a display NAME gets: no text face substitutes for it. Reached here from the
    /// document's own statement rather than from the spelling of its name.
    func testAHandwrittenOrDecorativeDeclarationIsNotForcedIntoSerifOrSans() {
        for kind: UInt8 in [3, 4] {
            XCTAssertEqual(DeclaredFace(typeInfo: panose(kind: kind, serifStyle: 2)).declaredKind,
                           .unclassified)
        }
        XCTAssertNil(DeclaredFace(typeInfo: panose(kind: 5, serifStyle: 0)).declaredKind?.systemFamily,
                     "a symbol face must be offered nothing")
    }

    /// "The document said nothing" and "the document said any" are different facts, and collapsing
    /// them is how a measurement of how often documents fill this in becomes meaningless.
    func testSayingNothingIsNotTheSameAsSayingAny() {
        XCTAssertNil(DeclaredFace(typeInfo: nil).declaredKind, "absent")
        XCTAssertNil(DeclaredFace(typeInfo: panose(kind: 0, serifStyle: 0)).declaredKind, "PANOSE any")
        XCTAssertNil(DeclaredFace(typeInfo: panose(kind: 2, serifStyle: 1)).declaredKind, "no fit")
        XCTAssertNotEqual(DeclaredFace(typeInfo: nil), DeclaredFace(typeInfo: panose(kind: 0, serifStyle: 0)))
    }

    func testATruncatedTypeInfoBlockIsNotGuessedAt() {
        XCTAssertNil(DeclaredFace(typeInfo: [2]).declaredKind)
        XCTAssertNil(DeclaredFace(typeInfo: []).declaredKind)
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

    /// A kind the document DECLARED beats the one its name implies — shown with the byte we DO trust.
    /// A face the document calls decorative gets no text substitute even though its name says sans.
    func testADeclaredKindBeatsWhatTheNameImplies() {
        let faces = ["HY중고딕": DeclaredFace(typeInfo: panose(kind: 4, serifStyle: 0))]
        let resolved = resolvedFont(paragraph(font: "HY중고딕"), faces: faces)
        // The span still ends up with a face — the ordinary cascade runs as it always did. What must
        // NOT happen is our map choosing it. The two are told apart by the leading dot: CoreText's
        // cascade hands back a PRIVATE face (".AppleSDGothicNeoI-Regular"), while anything this map
        // proposes is a public family ("AppleSDGothicNeo-Regular"). So the assertion is not "nothing
        // happened" but "the map kept out of it", which is the actual claim.
        XCTAssertNotNil(resolved)
        XCTAssertTrue(resolved!.hasPrefix("."),
                      "the name says sans and the document says decorative — the document wins, so the "
                      + "map must propose nothing and leave the cascade to answer. Got \(resolved!)")
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
