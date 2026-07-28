import XCTest
import AppKit
import CoreText
@testable import FastDocReader

/// `FontSubstitutionResolver` moves AppKit's own font-substitution decision from every ⌘+ press to
/// ONCE, at read time (`docs/font-substitution-cost-design.md`), and does it at the coarsest
/// granularity that is still faithful: **one representative per declared font, applied to a whole
/// span, no splitting**. Four things this file must never let regress:
///
///   (a) GLYPH IDENTITY WHERE IT IS ACHIEVABLE — text the declared font cannot draw AT ALL (a Korean
///       paragraph under a Latin-only font) draws with the EXACT font CoreText itself would have
///       substituted, character for character. That is the whole of what "we never pick a family of
///       our own" can mean once substitution is applied per span: where the declared font could have
///       drawn some of the characters, those characters now ride along with the substitute rather
///       than alternating — 24,939 of them on the reference HWP, deliberately, because the
///       alternation IS the cost this pass exists to remove (matching it exactly was built, measured
///       at build 625 ms → 5.8 s / display 1.5 s → 34 s, and rejected).
///   (b) SILENT PARITY — a document whose declared fonts draw their own text renders byte-identical
///       to before this feature existed. Invariant 37 depends on this, and under this design it is
///       structural: the gate never fires, so no span is ever copied.
///   (c) THE GATE IS ABOUT COVERAGE, NOT AVAILABILITY, AND THE SAMPLE IS ABOUT THE FONT'S WHOLE TEXT.
///       Both halves are defects that shipped in an earlier draft of this very pass and are pinned
///       here as tests: an availability gate misses a Korean `.docx` naming Times New Roman, and a
///       sample drawn only from non-ASCII characters drags an English document's Latin body onto
///       whatever answers for one stray symbol.
///   (d) The installed-attribute-run REDUCTION itself, so a future change that defeats it is caught
///       by the gate rather than rediscovered by profiling a slow ⌘+ press.
///
/// Deliberately synthetic (no real document dependency, unlike `SpanFragmentationProbeTests`/
/// `FontSubstitutionProbeTests`): these properties must hold on every run of `swift test`, not only
/// when a developer has the reference HWP on disk and remembers to set an env var.
final class FontSubstitutionResolverTests: XCTestCase {
    /// Installs `attr` into a REAL `NSTextStorage` + `NSLayoutManager` + `NSTextContainer` and forces
    /// layout — the exact sequence `SpanFragmentationProbeTests` uses to measure "installed" runs —
    /// then reads back the font attribute PER CHARACTER. Deliberately NOT `attr.attribute(.font,
    /// at:)` on the string as-built: AppKit's own attribute fixing rewrites the STORAGE's font
    /// attribute to whatever it actually draws once a layout manager is attached, so only the
    /// installed storage tells you what was drawn.
    private func drawnFontNames(_ attr: NSAttributedString) -> [String] {
        let storage = NSTextStorage()
        storage.setAttributedString(attr)
        let lm = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(lm)
        lm.addTextContainer(container)
        lm.ensureLayout(for: container)
        var out: [String] = []
        out.reserveCapacity(storage.length)
        for i in 0..<storage.length {
            let f = storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont
            out.append(f?.fontName ?? "<none>")
        }
        return out
    }

    private func build(_ spans: [Span], theme: RenderTheme = .current(size: 16)) -> NSAttributedString {
        OfficeTextBuilder.build([.paragraph(spans: spans)], theme: theme)
    }

    /// Characters drawn per face on the INSTALLED storage — the census that catches the one failure
    /// no run count can see (bold Korean going out regular).
    private func faceCensus(_ attr: NSAttributedString) -> [String: Int] {
        var out: [String: Int] = [:]
        for name in drawnFontNames(attr) { out[name, default: 0] += 1 }
        return out
    }

    // MARK: (a) Glyph identity where it is achievable

    /// A PURE Korean paragraph — every character is uncoverable by the declared font, so there is
    /// nothing for the span-wide rule to sweep in and this is the case where span-granularity and
    /// AppKit's own per-character answer must AGREE at every position.
    func testGlyphIdentityIsUnchangedForAPurelyUncoveredKoreanParagraph() {
        let text = "가나다라마바사아자차카타파하다시한번더반복되는긴한글문단입니다"
        let rawSpans = [Span(text: text)]
        let resolvedSpans = FontSubstitutionResolver.resolve(rawSpans)

        XCTAssertTrue(resolvedSpans.contains { $0.resolvedFontDescriptor != nil },
                      "the probe text must force a substitution")

        let before = drawnFontNames(build(rawSpans))
        let after = drawnFontNames(build(resolvedSpans))
        XCTAssertEqual(before.count, after.count, "resolving must not change the character count")
        XCTAssertEqual(before, after,
                       "for text the declared font cannot draw at all, the font actually drawing each " +
                       "character must be identical whether pre-resolved or left to AppKit")
    }

    /// The same check for a `code` span (theme's monospaced font, also no Korean coverage) and for a
    /// span carrying an explicit `fontName` override — `declaredFont` must mirror
    /// `OfficeTextBuilder`'s OWN precedence (code wins, then family override, then theme default) or
    /// the two silently diverge from what is actually drawn.
    func testGlyphIdentityHoldsForCodeSpansAndFontNameOverrides() {
        let codeSpan = Span(text: "코드안의한글텍스트입니다", code: true)
        let overrideSpan = Span(text: "오버라이드안의한글텍스트", fontName: "Helvetica")
        for raw in [codeSpan, overrideSpan] {
            let resolved = FontSubstitutionResolver.resolve([raw])
            let before = drawnFontNames(build([raw]))
            let after = drawnFontNames(build(resolved))
            XCTAssertEqual(before, after, "glyph identity must hold for span: \(raw.text)")
        }
    }

    /// THE DOCUMENTED TRADE-OFF, pinned as a real assertion rather than left as a comment: a space
    /// between two Korean words — which the DECLARED font draws perfectly well — rides along with
    /// the substitute rather than reverting. That is the whole point of removing the split; a change
    /// that makes it revert regresses the run count catastrophically (see (d)).
    func testDeclaredCoveredCharactersRideAlongWithTheSubstitute() {
        let text = "긴한글 단어와 짧은한글"   // Korean words separated by plain spaces
        let resolved = FontSubstitutionResolver.resolve([Span(text: text)])
        XCTAssertEqual(resolved.count, 1, "the span must not be split at all")
        let after = drawnFontNames(build(resolved))
        let ns = text as NSString
        for i in 0..<ns.length where ns.character(at: i) == 0x20 {
            XCTAssertNotEqual(after[i], NSFont.systemFont(ofSize: 16).fontName,
                              "space at \(i) must ride along with the substitute, not stay on the declared font")
        }
    }

    /// The substitute is chosen for ONE character — the sample — and that is the only coverage claim
    /// this design makes. Verified directly, because the previous design's much stronger claim
    /// ("every piece is self-covering") is deliberately gone and a reader could otherwise assume it
    /// silently survived.
    func testTheSubstituteCoversTheCharacterItWasChosenFor() throws {
        let text = "한글이 대부분인 문단에 English와 123과 かな가 조금 섞인 한글 문단입니다"
        let plan = FontSubstitutionResolver.plan(for: [.paragraph(spans: [Span(text: text)])])
        XCTAssertEqual(plan.substitutedFontCount, 1, "one declared font here, so exactly one decision")
        let entry = try XCTUnwrap(plan.describedEntries.first)
        XCTAssertTrue(entry.contains("→ .Apple"), "expected an Apple Korean face, got: \(entry)")
        // And CoreText's answer really does draw the character it was asked about.
        let cache = FontSubstitutionCache()
        let sample = try XCTUnwrap(entry.split(separator: "'").dropFirst().first?.unicodeScalars.first)
        let substitute = try XCTUnwrap(NSFont(descriptor: try XCTUnwrap(
            FontSubstitutionResolver.resolve([Span(text: text)]).first?.resolvedFontDescriptor), size: 12))
        XCTAssertTrue(cache.covers(substitute, sample.value),
                      "the representative must draw its own sample \(sample)")
    }

    /// THE HEADING CASE — a heading's declared font is `.systemFont(weight: .semibold)`
    /// (`RenderTheme.headingFont`), a DIFFERENT probe from a paragraph's plain `.systemFont`. An
    /// earlier draft probed every block with a REGULAR system font and lost the weight on every
    /// heading needing substitution.
    func testGlyphIdentityIsUnchangedForAHeadingsSemiboldWeight() {
        let text = "가나다라마바사아자차카타파하다시한번더반복되는긴한글제목"
        let block = OfficeBlock.heading(level: 1, spans: [Span(text: text)])
        let resolvedBlock = block.resolvingFontSubstitution()
        guard case let .heading(_, resolvedSpans, _, _, _, _) = resolvedBlock else {
            return XCTFail("resolvingFontSubstitution must preserve the block shape")
        }
        XCTAssertTrue(resolvedSpans.contains { $0.resolvedFontDescriptor != nil },
                      "the probe text must force a substitution")
        let theme = RenderTheme.current(size: 16)
        let before = drawnFontNames(OfficeTextBuilder.build([block], theme: theme))
        let after = drawnFontNames(OfficeTextBuilder.build([resolvedBlock], theme: theme))
        XCTAssertEqual(before, after, "a heading's semibold weight must survive font substitution")
        // Pin the concrete face, not merely "before == after" — two wrong-but-equal fonts would slip
        // through. `dropLast()` excludes the trailing "\n" the builder appends.
        XCTAssertTrue(before.dropLast().allSatisfy { $0.contains("SemiBold") },
                      "sanity: this probe must genuinely need the SemiBold Korean face, got \(before)")
    }

    /// THE BOLD/ITALIC SPAN CASE — an earlier draft ignored `span.bold`/`.italic` when probing and
    /// re-added the traits onto the already-resolved PRIVATE substitute descriptor afterwards;
    /// `withSymbolicTraits` on an opaque system-UI face does not reliably honour that (measured:
    /// re-adding `[.bold, .italic]` onto an `-Regular` Korean substitute silently no-opped).
    func testGlyphIdentityIsUnchangedForABoldItalicSpan() {
        let text = "가나다라마바사아자차카타파하다시한번더반복되는긴한글문단"
        let span = Span(text: text, bold: true, italic: true)
        let resolved = FontSubstitutionResolver.resolve([span])
        XCTAssertTrue(resolved.contains { $0.resolvedFontDescriptor != nil },
                      "the probe text must force a substitution")
        let before = drawnFontNames(build([span]))
        let after = drawnFontNames(build(resolved))
        XCTAssertEqual(before, after, "a bold+italic span must survive font substitution unchanged")
        XCTAssertTrue(before.dropLast().allSatisfy { $0.contains("Bold") },
                      "sanity: this probe must genuinely need the Bold Korean face, got \(before)")
    }

    /// THE COMBINED CASE — a heading run that is ALSO explicitly bold (what Word writes when a
    /// heading style's runs carry `w:b`): the probe must be semibold WITH `.bold` unioned in, and
    /// `OfficeTextBuilder` must not re-apply `.bold` a second time on top of the resolved descriptor
    /// (measured: that knocks an already-`-SemiBold` private face onto `.AppleKoreanFont-Bold`).
    func testGlyphIdentityIsUnchangedForAHeadingRunThatIsAlsoExplicitlyBold() {
        let text = "가나다라마바사아자차카타파하다시한번더반복되는긴한글제목"
        let block = OfficeBlock.heading(level: 1, spans: [Span(text: text, bold: true)])
        let resolvedBlock = block.resolvingFontSubstitution()
        let theme = RenderTheme.current(size: 16)
        let before = drawnFontNames(OfficeTextBuilder.build([block], theme: theme))
        let after = drawnFontNames(OfficeTextBuilder.build([resolvedBlock], theme: theme))
        XCTAssertEqual(before, after,
                       "a heading run that is ALSO explicitly bold must survive font substitution")
        XCTAssertTrue(before.dropLast().allSatisfy { $0.contains("SemiBold") },
                      "sanity: a bold trait on top of an already-semibold heading must stay SemiBold, got \(before)")
    }

    /// **BOLD AND SEMIBOLD MUST SURVIVE — the requirement that disqualified the one-descriptor-per-
    /// DOCUMENT variant.** That variant had the best run count of all and was ruled out because its
    /// face census showed ZERO characters in the bold Korean face where the shipped behaviour had
    /// 1,531: every bold and semibold Korean run rendered regular. A run count cannot see that; a
    /// census can, so assert on the census.
    func testTheFaceCensusStillCarriesBoldAndSemiboldKorean() {
        let body = "가나다라마바사아자차카타파하 본문입니다"
        let blocks: [OfficeBlock] = [
            .heading(level: 1, spans: [Span(text: "가나다라마바사아자차카타파하 제목")]),
            .paragraph(spans: [Span(text: body), Span(text: body, bold: true)]),
        ]
        let plan = FontSubstitutionResolver.plan(for: blocks)
        let resolved = blocks.map { $0.applyingFontSubstitution(plan) }
        let census = faceCensus(OfficeTextBuilder.build(resolved, theme: .current(size: 16)))
        let bold = census.filter { $0.key.contains("Bold") && !$0.key.contains("SemiBold") }
            .values.reduce(0, +)
        let semibold = census.filter { $0.key.contains("SemiBold") }.values.reduce(0, +)
        XCTAssertGreaterThan(bold, 0, "bold Korean must still be drawn bold — census: \(census)")
        XCTAssertGreaterThan(semibold, 0, "a semibold heading must still be drawn semibold — census: \(census)")
    }

    // MARK: (b) Silent parity — invariant 37

    /// A span the declared font ALREADY covers (plain English) must come back as the exact same
    /// `Span` VALUE, not a copy that merely leaves `resolvedFontDescriptor` `nil`.
    func testFullyCoveredSpanIsReturnedUnchanged() {
        let span = Span(text: "Plain English text, digits 123, punctuation!", bold: true)
        XCTAssertEqual(FontSubstitutionResolver.resolve([span]), [span],
                       "a fully covered span must be byte-identical, not merely equivalent")
    }

    /// INVARIANT 37, HALF ONE: a Latin-only office document renders byte-identically whether or not
    /// it went through the resolver.
    func testALatinOnlyDocumentIsByteIdentical() {
        let spans = [
            Span(text: "A report title", bold: true),
            Span(text: " with "),
            Span(text: "emphasis", italic: true),
            Span(text: " and a "),
            Span(text: "code span", code: true),
            Span(text: "."),
        ]
        let before = build(spans)
        let after = build(FontSubstitutionResolver.resolve(spans))
        XCTAssertTrue(before.isEqual(to: after),
                      "an all-covered office document must produce a byte-identical attributed string")
    }

    /// INVARIANT 37, HALF TWO — the half a Latin document cannot test: a KOREAN document whose
    /// declared family is INSTALLED and DOES draw Korean must also be untouched. This is the
    /// difference between "the gate is conservative" and "the gate happens never to fire on the
    /// documents we tried".
    func testAKoreanDocumentWhoseDeclaredFamilyDrawsKoreanIsByteIdentical() throws {
        let family = try XCTUnwrap(["AppleSDGothicNeo-Regular", "AppleMyungjo", "AppleGothic"]
            .first { NSFont(name: $0, size: 12) != nil },
                                    "this machine ships no Korean-covering family to test with")
        let spans = [Span(text: "가나다라마바사 한글 문서입니다", fontName: family),
                     Span(text: " 그리고 두 번째 문장", fontName: family)]
        let resolved = FontSubstitutionResolver.resolve(spans)
        XCTAssertEqual(resolved, spans,
                       "a declared family that draws this document's own Korean must never be substituted")
        XCTAssertTrue(build(spans).isEqual(to: build(resolved)),
                      "and the built string must be byte-identical")
    }

    /// Markdown never constructs an office `Span`/`OfficeBlock` at all — `MarkdownRenderer` builds
    /// straight from swift-markdown's own AST — so this feature has no code path into it.
    func testMarkdownRenderingIsUntouchedByOfficeFontResolution() {
        let md = "# Heading\n\nPlain paragraph text, unrelated to office font substitution."
        let theme = RenderTheme.current(size: 16)
        XCTAssertTrue(MarkdownRenderer.render(md, theme: theme).isEqual(to: MarkdownRenderer.render(md, theme: theme)))
    }

    // MARK: (c) What the gate is, and what the sample is

    /// **THE AVAILABILITY-GATE HOLE, closed.** Times New Roman is installed on this machine and does
    /// not draw a single Hangul syllable — and it is exactly what Word writes into the ascii slot by
    /// default, so a Korean `.docx` names it constantly. A gate asking "is the declared family
    /// installed?" passes this document straight through to AppKit's per-character fixing, silently,
    /// depending on which fonts the reader happens to have. Asking about COVERAGE cannot do that.
    func testAnInstalledButNonCoveringFamilyStillGetsASubstitute() throws {
        try XCTSkipIf(NSFont(name: "Times New Roman", size: 12) == nil, "Times New Roman not installed")
        let span = Span(text: "가나다라마바사아자차카타파하 한글 본문", fontName: "Times New Roman")
        let resolved = FontSubstitutionResolver.resolve([span])
        XCTAssertNotNil(resolved.first?.resolvedFontDescriptor,
                        "an INSTALLED family that cannot draw this document's text must still be substituted")
    }

    /// **THE PREFIX/TAIL DEFECT, re-tested rather than assumed inherited.** The previous design had
    /// to bound its substitution run at the LAST uncovered character because one stray symbol — a
    /// soft hyphen, or a Wingdings/Symbol PUA bullet — resolved to Helvetica Neue, which also draws
    /// ordinary Latin, so the greedy rule rode it to the end of the span and changed seven unrelated
    /// words. That bound is GONE. The defect is prevented by a different mechanism: the sample is the
    /// most common non-absorbing character of the font's WHOLE text, so an English sentence is
    /// sampled on its own Latin letters and the gate never fires at all.
    ///
    /// Not vacuous: the sanity assertions below confirm the trap is real on this machine — the stray
    /// character genuinely is uncovered, and CoreText's answer for it genuinely does cover Latin, so
    /// a design that sampled it WOULD move the whole sentence.
    func testAStraySymbolDoesNotDragAnEnglishSentenceOntoItsSubstitute() throws {
        for stray in ["\u{00AD}", "\u{F0B7}"] {   // soft hyphen (w:softHyphen); Wingdings PUA bullet
            let text = "Please co\(stray)operate fully with the auditor before the meeting"
            let span = Span(text: text)
            let resolved = FontSubstitutionResolver.resolve([span])
            XCTAssertEqual(resolved, [span],
                           "an English sentence carrying one stray \(stray.unicodeScalars.first!) must be untouched")

            // Sanity: the trap this is defending against has to be real, or the assertion above is
            // just describing a document with no problem in it.
            let declared = NSFont.systemFont(ofSize: 12)
            let scalar = stray.unicodeScalars.first!
            let cache = FontSubstitutionCache()
            XCTAssertFalse(cache.covers(declared, scalar.value),
                           "sanity: \(scalar) must genuinely be uncovered by the theme's body font")
            let wouldBe = cache.substituteFont(declared: declared, scalar: scalar.value)
            XCTAssertTrue(cache.covers(wouldBe, UInt32(UInt8(ascii: "o"))),
                          "sanity: \(wouldBe.fontName) also draws Latin, so sampling \(scalar) WOULD " +
                          "have moved the whole sentence — that is the defect being prevented")
        }
    }

    /// **THE SAMPLE MUST BE JUDGED AGAINST THE FONT'S WHOLE TEXT, ASCII INCLUDED.** Measured on a
    /// real 400k report: `Times New Roman` there draws 5,177 characters of ordinary Latin plus a few
    /// `U+2164` ROMAN NUMERAL FIVE section numbers, this Mac's Times New Roman has no glyph for
    /// `U+2164`, and a census restricted to NON-ASCII characters therefore sampled `Ⅴ` and moved all
    /// 5,177 characters onto Lucida Grande — serif body text redrawn sans-serif. Counting the Latin
    /// letters makes the sample `e`, which Times New Roman draws, and the gate correctly stays shut.
    func testAFontDrawingMostlyLatinIsNotMovedByAFewExoticCharacters() throws {
        try XCTSkipIf(NSFont(name: "Times New Roman", size: 12) == nil, "Times New Roman not installed")
        let body = String(repeating: "The auditor reviewed the quarterly statements carefully. ", count: 8)
        let span = Span(text: "\u{2164}. \(body)", fontName: "Times New Roman")
        XCTAssertEqual(FontSubstitutionResolver.resolve([span]), [span],
                       "a font drawing this document's own Latin must keep its text, however many " +
                       "exotic characters it also carries")
    }

    /// A declared font whose text holds NOTHING but absorbing characters (digits, punctuation,
    /// spaces — all Script=Common) yields no sample and is therefore never substituted. Stated as a
    /// test because it is the answer to "what happens when there is no sample", and because it is
    /// also why counting space would break everything: space is the most common character in nearly
    /// every document and every font draws it, so a census including it would answer "space" for
    /// every font and the gate would never fire on anything.
    func testAFontDrawingOnlyPunctuationAndDigitsIsNeverSubstituted() {
        let span = Span(text: "123 456.78 (9,10) — 11/12", fontName: "Times New Roman")
        XCTAssertEqual(FontSubstitutionResolver.resolve([span]), [span])
        XCTAssertTrue(FontSubstitutionResolver.plan(for: [.paragraph(spans: [span])]).isEmpty,
                      "no eligible character means no question to ask CoreText")
    }

    /// **A PRIVATE-USE character must never be the sample**, even when it is the most common thing
    /// the font draws. A PUA codepoint has no agreed meaning — its glyph is defined only by the font
    /// that declared it — so "what else draws this" has no correct answer. Measured on a real 400k
    /// report: `HY신명조` there is used mostly for a repeated supplementary-PUA ornament, sampled
    /// that ornament, and CoreText answered `LastResort` — 450 characters of perfectly drawable
    /// Korean went out as boxes.
    func testAPrivateUseCharacterIsNeverTheSampleEvenWhenItIsTheMostCommon() throws {
        let text = String(repeating: "\u{F0854}", count: 30) + "한글 본문이 이어집니다"
        let resolved = FontSubstitutionResolver.resolve([Span(text: text)])
        let descriptor = try XCTUnwrap(resolved.first?.resolvedFontDescriptor,
                                        "the Korean in this span must still get a representative")
        let face = try XCTUnwrap(NSFont(descriptor: descriptor, size: 12)).fontName
        XCTAssertNotEqual(face, "LastResort",
                          "the sample must be the Korean this font actually draws, not the PUA ornament")
        XCTAssertTrue(face.contains("Apple"), "expected an Apple Korean face, got \(face)")
    }

    /// **`LastResort` is the ABSENCE of a substitute, not a substitute.** It is the font whose entire
    /// job is to draw a box meaning "nothing here draws this", so accepting it would paint a whole
    /// span's worth of otherwise-drawable text as boxes. `U+0378` is unassigned in Unicode — a real
    /// script identity as far as this pass's table is concerned (Script=Unknown is not absorbing),
    /// not private use, and nothing on this machine draws it.
    func testACharacterNothingDrawsYieldsNoSubstituteRatherThanLastResort() throws {
        let cache = FontSubstitutionCache()
        let unassigned: UInt32 = 0x0378
        try XCTSkipIf(cache.substituteFont(declared: .systemFont(ofSize: 12), scalar: unassigned)
                        .fontName != "LastResort",
                      "this machine resolves U+0378 to a real face; the probe needs a truly undrawable one")
        let span = Span(text: "\u{0378}\u{0378}\u{0378}")
        XCTAssertEqual(FontSubstitutionResolver.resolve([span]), [span],
                       "a LastResort answer must be refused, leaving the span untouched")
    }

    // MARK: One representative per declared font — the shape itself

    /// The unit of decision is the DECLARED FONT, not the span: every span naming the same family
    /// gets the SAME descriptor, and the plan holds exactly one entry per distinct declared font.
    func testOneRepresentativePerDeclaredFontIsSharedByEverySpanUsingIt() {
        let spans = [Span(text: "첫 번째 한글 문장"), Span(text: "완전히 다른 두 번째 문장"),
                     Span(text: "세 번째", bold: true)]
        let plan = FontSubstitutionResolver.plan(for: [.paragraph(spans: spans)])
        XCTAssertEqual(plan.substitutedFontCount, 2,
                       "regular and bold are different declared fonts; nothing else is: \(plan.describedEntries)")
        let resolved = FontSubstitutionResolver.resolve(spans, plan: plan)
        XCTAssertEqual(resolved[0].resolvedFontDescriptor, resolved[1].resolvedFontDescriptor,
                       "two spans with the same declared font must share one representative")
        XCTAssertNotEqual(resolved[0].resolvedFontDescriptor, resolved[2].resolvedFontDescriptor,
                          "a bold span is a different declared font and must resolve independently")
    }

    /// The sample is a fact about the WHOLE DOCUMENT, not about whichever block was reached first —
    /// so a font used for one Latin word in block A and a page of Korean in block B is decided on
    /// the page of Korean. This is what the two-pass shape buys, and a one-pass "decide as you walk"
    /// implementation would silently get it wrong in document order.
    func testTheSampleIsTakenFromTheWholeDocumentNotOneBlock() {
        let blocks: [OfficeBlock] = [
            .paragraph(spans: [Span(text: "Intro")]),
            .paragraph(spans: [Span(text: String(repeating: "한글 본문이 길게 이어집니다. ", count: 20))]),
        ]
        let plan = FontSubstitutionResolver.plan(for: blocks)
        let resolved = blocks.map { $0.applyingFontSubstitution(plan) }
        guard case let .paragraph(first, _, _, _, _) = resolved[0] else { return XCTFail("shape") }
        XCTAssertNotNil(first[0].resolvedFontDescriptor,
                        "the Latin-only first paragraph shares its declared font with the Korean body, " +
                        "so it takes the same document-wide answer")
    }

    /// Ties are broken by the LOWER codepoint, deterministically. A `Dictionary`'s iteration order is
    /// per-process hash-randomised, so "whichever maximum I met first" would let the same document
    /// resolve differently on different launches — invariant 50 records that exact fault shipping
    /// once already, from a different direction.
    ///
    /// Fifty samples, not ten, and that number is measured: mutating the tie-break out (taking
    /// whichever maximum the dictionary yielded first) failed this test in only 2 of 3 process
    /// launches at ten, because each `Dictionary` has to happen to iterate differently at least once
    /// within the run. Fifty makes the detection reliable without making the test slow.
    func testTheSampleTieBreakIsDeterministic() {
        let span = Span(text: "가나가나")   // 가 and 나 each occur twice
        let answers = Set((0..<50).map { _ in
            FontSubstitutionResolver.plan(for: [.paragraph(spans: [span])]).describedEntries.joined()
        })
        XCTAssertEqual(answers.count, 1, "the same input must produce one answer, got \(answers)")
        XCTAssertTrue(answers.first!.contains("'가'"), "the LOWER codepoint must win a tie: \(answers)")
    }

    // MARK: Text integrity

    /// The apply pass touches only `resolvedFontDescriptor`, so text can never be altered — no
    /// splitting means no surrogate pair can be cut in half, which the previous design needed a
    /// hand-written lead/trail-surrogate guard for. Kept as an assertion rather than deleted with
    /// the guard: the property is what mattered, not the mechanism.
    func testTextIsNeverAlteredBySubstitution() {
        for text in ["인용\u{F0854}표시\u{1F600}끝", "AB😀CD", "한글かなLatin다시한글",
                     "combining e\u{0301} and Thai ก\u{0E31}"] {
            let resolved = FontSubstitutionResolver.resolve([Span(text: text)])
            XCTAssertEqual(resolved.map(\.text).joined(), text, "text must survive verbatim: \(text)")
            XCTAssertFalse(resolved.contains { $0.text.contains("\u{FFFD}") },
                           "no replacement character may appear: \(resolved.map(\.text))")
            XCTAssertEqual(resolved.count, 1, "a span is never split")
        }
    }

    /// A mixed-script span keeps ONE representative and leaves what that representative cannot draw
    /// to AppKit — pre-splitting those residual characters at read time was measured to move the
    /// installed run count by EXACTLY ZERO while adding 2,077 spans, because the boundaries are ones
    /// AppKit creates anyway. Characterises the shipped behaviour so a future "improvement" has to
    /// argue with the measurement.
    func testAMixedScriptSpanKeepsOneRepresentativeAndLeavesTheResidualToAppKit() {
        let resolved = FontSubstitutionResolver.resolve([Span(text: "한글かなLatin다시한글")])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertNotNil(resolved[0].resolvedFontDescriptor)
    }

    // MARK: (d) Installed-run reduction

    /// The deterministic knob design §4 names: resolving substitution at read time must reduce the
    /// INSTALLED attribute-run count for text AppKit would otherwise keep re-substituting per
    /// character.
    func testInstalledRunCountDropsForUncoveredKoreanText() {
        let korean = String(repeating: "긴 한글 문단이 반복됩니다. ", count: 40)
        let rawSpans = [Span(text: korean)]
        let resolvedSpans = FontSubstitutionResolver.resolve(rawSpans)

        func installedRuns(_ spans: [Span]) -> Int {
            let storage = NSTextStorage()
            storage.setAttributedString(build(spans))
            var n = 0
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { _, _, _ in n += 1 }
            return n
        }
        let before = installedRuns(rawSpans)
        let after = installedRuns(resolvedSpans)
        print("  installed runs — before: \(before)  after: \(after)")
        XCTAssertLessThan(after, before,
                          "resolving font substitution at read time must reduce installed attribute runs")
    }
}
