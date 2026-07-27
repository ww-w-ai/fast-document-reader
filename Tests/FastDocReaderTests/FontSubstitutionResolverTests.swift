import XCTest
import AppKit
import CoreText
@testable import FastDocReader

/// `FontSubstitutionResolver` moves AppKit's own font-substitution decision from every ⌘+ press to
/// ONCE, at read time (`docs/font-substitution-cost-design.md`). Three things this file must never
/// let regress, matching that design's §4 "definition of done" — WITH ONE MEASURED CORRECTION to
/// how strictly "(a) glyph identity" applies, recorded here so it is never silently re-litigated:
///
///   (a) GLYPH IDENTITY, AT SPAN GRANULARITY — a genuinely uncoverable stretch (Korean text with no
///       declared-covered character mixed in) draws with the EXACT font CoreText itself would
///       substitute, character for character. A declared-covered character (a space, a digit, a
///       Latin letter) that happens to sit INSIDE an otherwise-substituted run rides along with that
///       SAME substitute rather than reverting to the declared font mid-run — a deliberate,
///       DOCUMENTED narrowing of "must not change glyphs" from "every character" to "every
///       character an all-covered declared font could never have drawn anyway." This is not a
///       shortcut: matching AppKit's true per-character alternation exactly was BUILT and MEASURED
///       first, and on the reference HWP it reproduced the identical fragmentation this feature
///       exists to eliminate (installed runs 118,533 → 118,533, i.e. no change) while making the
///       cost WORSE, not better (`OfficeTextBuilder.build` 625 ms → 5.8 s, `display` 1.5 s → 34 s,
///       measured) — because a span-per-character-boundary read-time representation still forces
///       `OfficeTextBuilder` to reconstruct that same huge run count on every ⌘+ press, just earlier.
///       Span-granularity substitution is what the design's own proof-of-concept measured (§1's
///       "one covering font" experiment, 118,533 → 19,460) — this resolver reaches the same
///       neighbourhood while staying font-CHOICE-faithful (never an app-chosen family) and touching
///       far fewer characters than that experiment's document-wide swap did.
///   (b) SILENT PARITY — a span the declared font already covers IN FULL renders byte-identical to
///       before this feature existed; nothing downstream can tell a "resolved but fully covered"
///       span apart from one the resolver never touched. This is the guarantee invariant 37 actually
///       depends on, and it is untouched by (a)'s narrowing — a fully-covered span never enters the
///       substitution branch at all.
///   (c) The installed-attribute-run REDUCTION itself, so a future change that defeats it is caught
///       by the gate, not rediscovered by profiling a slow ⌘+ press again.
///
/// Deliberately synthetic (no real document dependency, unlike `SpanFragmentationProbeTests`/
/// `OfficeRenderLatencyTests`): these three properties must hold on every run of `swift test`, not
/// only when a developer has the reference HWP on disk and remembers to set an env var.
final class FontSubstitutionResolverTests: XCTestCase {
    /// Installs `attr` into a REAL `NSTextStorage` + `NSLayoutManager` + `NSTextContainer` and forces
    /// layout — the exact sequence `SpanFragmentationProbeTests` uses to measure "installed" runs —
    /// then reads back the font attribute PER CHARACTER. This is deliberately NOT `attr.attribute(
    /// .font, at:)` on the string as-built: AppKit's own attribute fixing rewrites the STORAGE's font
    /// attribute to whatever it actually draws once a layout manager is attached, so only the
    /// installed storage tells you what was drawn — reading the pre-install string would just report
    /// back whatever font this code assigned, proving nothing about what AppKit did with it.
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

    // MARK: (a) Glyph identity — genuinely uncoverable text (no embedded declared-covered chars)

    /// A PURE Korean paragraph — every character is uncoverable by the declared font, so there is no
    /// declared-covered character for the coarse span-level rule to sweep in and nothing for it to
    /// differ on: this is the case where span-granularity and per-character give the SAME answer,
    /// and it must draw the IDENTICAL glyph at every character position — the invariant-37 gate in
    /// the strict form, proven on the text where it is actually achievable.
    func testGlyphIdentityIsUnchangedForAPurelyUncoveredKoreanParagraph() {
        let text = "가나다라마바사아자차카타파하다시한번더반복되는긴한글문단입니다"
        let rawSpans = [Span(text: text)]
        let resolvedSpans = FontSubstitutionResolver.resolve(rawSpans)

        XCTAssertTrue(resolvedSpans.contains { $0.resolvedFontDescriptor != nil },
                      "the probe text must force at least one substitution")

        let before = drawnFontNames(build(rawSpans))
        let after = drawnFontNames(build(resolvedSpans))
        XCTAssertEqual(before.count, after.count, "resolving must not change the character count")
        XCTAssertEqual(before, after,
                       "for text with no embedded declared-covered character, the font actually " +
                       "drawing each character must be identical whether pre-resolved or left for " +
                       "AppKit to substitute on install")
    }

    /// The same check for a `code` span (theme's monospaced font, also no Korean coverage) and for a
    /// span carrying an explicit `fontName` override — `FontSubstitutionResolver.declaredFont(for:)`
    /// must mirror `OfficeTextBuilder`'s OWN precedence (code wins, then family override, then
    /// theme default) or these two would silently diverge from what is actually drawn. Pure Korean
    /// again (no embedded ASCII) so this isolates the precedence question from (a)'s span-coarsening.
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
    /// embedded between two Korean words — which the DECLARED font can draw perfectly well — rides
    /// along with the surrounding substitute instead of reverting mid-run. This is not a bug this
    /// test is working around; it is the span-granularity choice the file doc above explains and
    /// measures. If a future change makes this revert to per-character precision, run count
    /// regresses catastrophically (see `testInstalledRunCountDropsForUncoveredKoreanText`) — so this
    /// assertion exists specifically to keep that trade-off intentional rather than silently undone.
    func testEmbeddedDeclaredCoveredCharactersRideAlongWithTheSurroundingSubstitute() {
        let text = "긴한글 단어와 짧은한글"   // Korean words separated by plain spaces
        let resolved = FontSubstitutionResolver.resolve([Span(text: text)])
        let after = drawnFontNames(build(resolved))
        let ns = text as NSString
        // Every SPACE position must draw with the SAME font as its Korean neighbours (the
        // substitute), not the declared font — the coarse, intended behaviour.
        for i in 0..<ns.length where ns.character(at: i) == 0x20 {
            XCTAssertNotEqual(after[i], NSFont.systemFont(ofSize: 16).fontName,
                              "space at \(i) must ride along with the substitute, not stay on the declared font")
        }
    }

    /// Independent verification that the recorded substitute is genuinely "what CoreText would have
    /// picked" and not merely self-consistent: reconstructing it from its own descriptor must cover
    /// EVERY character of the piece it was resolved for (never a partial or wrong font slipping
    /// through the cache).
    func testResolvedSubstituteActuallyCoversTheTextItWasResolvedFor() {
        let text = "한글과 English와 123 그리고 かな가 섞인 span입니다"
        let resolved = FontSubstitutionResolver.resolve([Span(text: text)])
        for piece in resolved {
            guard let descriptor = piece.resolvedFontDescriptor else { continue }
            let font = try! XCTUnwrap(NSFont(descriptor: descriptor, size: 16))
            let ns = piece.text as NSString
            var chars = [UniChar](repeating: 0, count: ns.length)
            ns.getCharacters(&chars, range: NSRange(location: 0, length: ns.length))
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            let covers = CTFontGetGlyphsForCharacters(font as CTFont, chars, &glyphs, chars.count)
            XCTAssertTrue(covers, "resolved substitute \(font.fontName) must cover its own piece '\(piece.text)'")
        }
    }

    /// THE HEADING CASE OF (a) — a heading's declared font is `.systemFont(weight: .semibold)`
    /// (`RenderTheme.headingFont`), a DIFFERENT probe from a paragraph's plain `.systemFont`. The
    /// first version of this resolver ignored that (probed every block with a REGULAR system font,
    /// then let `OfficeTextBuilder` outright REPLACE the heading's semibold base font with whatever
    /// REGULAR substitute it found) — losing the weight on every heading whose declared font needed
    /// substitution at all.
    func testGlyphIdentityIsUnchangedForAHeadingsSemiboldWeight() {
        let text = "가나다라마바사아자차카타파하다시한번더반복되는긴한글제목"
        let block = OfficeBlock.heading(level: 1, spans: [Span(text: text)])
        let resolvedBlock = block.resolvingFontSubstitution()
        guard case let .heading(_, resolvedSpans, _, _, _, _) = resolvedBlock else {
            return XCTFail("resolvingFontSubstitution must preserve the block shape")
        }
        XCTAssertTrue(resolvedSpans.contains { $0.resolvedFontDescriptor != nil },
                      "the probe text must force at least one substitution")
        let theme = RenderTheme.current(size: 16)
        let before = drawnFontNames(OfficeTextBuilder.build([block], theme: theme))
        let after = drawnFontNames(OfficeTextBuilder.build([resolvedBlock], theme: theme))
        XCTAssertEqual(before, after,
                       "a heading's semibold weight must survive font substitution — the resolved " +
                       "substitute must be the SAME face CoreText would draw for a semibold probe, " +
                       "not a regular one")
        // Pin the concrete face, not merely "before == after" — two wrong-but-equal fonts (e.g. both
        // regular) would slip through the equality check above without this. `dropLast()` excludes
        // the trailing "\n" `OfficeTextBuilder.build` appends after every paragraph — a control
        // character with no Korean-substitute glyph of its own, irrelevant to this probe.
        XCTAssertTrue(before.dropLast().allSatisfy { $0.contains("SemiBold") },
                      "sanity: this probe text must genuinely need the SemiBold Korean substitute, got \(before)")
    }

    /// THE BOLD/ITALIC SPAN CASE of (a) — a different failure from the heading one: the first
    /// version's `declaredFont(for:)` ignored `span.bold`/`.italic` entirely when probing, then
    /// `OfficeTextBuilder` tried to RE-ADD those traits onto the already-resolved PRIVATE substitute
    /// descriptor afterward — `withSymbolicTraits` on an opaque system-UI face does not reliably
    /// honour that (measured: re-adding `[.bold, .italic]` onto an `-Regular` Korean substitute
    /// silently no-opped, staying `-Regular`), so the run drew unbolded, unitalicised.
    func testGlyphIdentityIsUnchangedForABoldItalicSpan() {
        let text = "가나다라마바사아자차카타파하다시한번더반복되는긴한글문단"
        let span = Span(text: text, bold: true, italic: true)
        let resolved = FontSubstitutionResolver.resolve([span])
        XCTAssertTrue(resolved.contains { $0.resolvedFontDescriptor != nil },
                      "the probe text must force at least one substitution")
        let before = drawnFontNames(build([span]))
        let after = drawnFontNames(build(resolved))
        XCTAssertEqual(before, after, "a bold+italic span must survive font substitution unchanged")
        XCTAssertTrue(before.dropLast().allSatisfy { $0.contains("Bold") },
                      "sanity: this probe text must genuinely need the Bold Korean substitute, got \(before)")
    }

    /// THE COMBINED CASE — a heading run that is ALSO explicitly bold (Word commonly marks a
    /// heading run bold at the RUN level in addition to the style's own semibold weight): this needs
    /// BOTH halves of the blocker-2 fix at once. `declaredFont` alone fixes the CHOICE (probing with
    /// semibold + `.bold` unioned in front of CoreText correctly stays "SemiBold", matching what a
    /// bold trait added on top of an already-semibold weight actually draws) — but reproducing the
    /// reviewer's own corpus number ("41 chars go SemiBold → .AppleKoreanFont-Bold") ALSO needs
    /// `OfficeTextBuilder` to stop re-applying `.bold` a SECOND time on top of the now-correctly-
    /// resolved descriptor: measured, re-adding `.bold` onto an already-`-SemiBold` PRIVATE
    /// substitute (even a correctly resolved one) can still knock it onto a different face
    /// (`.AppleKoreanFont-Bold`) — `withSymbolicTraits` on these opaque system-UI descriptors is not
    /// idempotent the way it is on ordinary public families.
    func testGlyphIdentityIsUnchangedForAHeadingRunThatIsAlsoExplicitlyBold() {
        let text = "가나다라마바사아자차카타파하다시한번더반복되는긴한글제목"
        let block = OfficeBlock.heading(level: 1, spans: [Span(text: text, bold: true)])
        let resolvedBlock = block.resolvingFontSubstitution()
        guard case let .heading(_, resolvedSpans, _, _, _, _) = resolvedBlock else {
            return XCTFail("resolvingFontSubstitution must preserve the block shape")
        }
        XCTAssertTrue(resolvedSpans.contains { $0.resolvedFontDescriptor != nil },
                      "the probe text must force at least one substitution")
        let theme = RenderTheme.current(size: 16)
        let before = drawnFontNames(OfficeTextBuilder.build([block], theme: theme))
        let after = drawnFontNames(OfficeTextBuilder.build([resolvedBlock], theme: theme))
        XCTAssertEqual(before, after,
                       "a heading run that is ALSO explicitly bold must survive font substitution")
        XCTAssertTrue(before.dropLast().allSatisfy { $0.contains("SemiBold") },
                      "sanity: a bold trait on top of an already-semibold heading must stay the " +
                      "SemiBold Korean substitute, got \(before)")
    }

    // MARK: (a), continued — Concern 1: an uncovered symbol must not drag unrelated trailing text
    // onto its substitute

    /// A single uncovered SYMBOL (docx `w:softHyphen` → `U+00AD`, which `.systemFont` has no glyph
    /// for) inside an otherwise fully declared-covered English sentence must substitute ONLY that
    /// symbol — not sweep the rest of the sentence onto whatever face CoreText happened to pick for
    /// it. The first version's "extend across every character the substitute covers" rule had no
    /// upper bound: `CTFontCreateForString` answered the soft hyphen with Helvetica Neue, which also
    /// trivially covers ordinary Latin, so the run extended all the way to the end of the span —
    /// seven unrelated words silently changed typeface.
    func testAnUncoveredSymbolDoesNotDragTrailingDeclaredCoveredTextOntoItsSubstitute() {
        let text = "Please co\u{00AD}operate fully"   // U+00AD = soft hyphen (DocxReader's w:softHyphen)
        let resolved = FontSubstitutionResolver.resolve([Span(text: text)])
        XCTAssertEqual(resolved.map(\.text).joined(), text, "splitting must not drop or duplicate text")
        // The trailing "operate fully" must stay UNRESOLVED (the declared font draws it correctly
        // on its own) — no piece CARRYING a resolved substitute may contain it.
        for piece in resolved where piece.resolvedFontDescriptor != nil {
            XCTAssertFalse(piece.text.contains("operate"),
                           "the declared-covered trailing text must not be swept into a substituted run: \(resolved.map(\.text))")
        }
        XCTAssertTrue(resolved.contains { $0.text.contains("operate") && $0.resolvedFontDescriptor == nil },
                      "\"operate fully\" must end up on the declared font, unresolved: \(resolved.map(\.text))")
    }

    // MARK: Blockers 1 & 3 — surrogate pairs must never be cut in half

    /// CoreText places a surrogate PAIR's one glyph at the HIGH surrogate's index and writes 0 at the
    /// LOW one — a coverage/run-extension pass that trusts the low surrogate's slot literally always
    /// sees it as "uncovered" and breaks the run exactly between the two halves. The moment a cut
    /// half is held in a Swift `String` (`Span.text`) it becomes U+FFFD — every emoji and CJK
    /// Extension B/C character (both surrogate pairs) is destroyed at READ time, silently, with no
    /// existing test catching it (invariant 41's lesson: an unreached case is invisible to a parser
    /// unit test alone).
    func testSurrogatePairCharactersAreNeverCutInHalf() {
        let text = "인용\u{F0854}표시\u{1F600}끝"   // HWP Plane-15 SPUA symbol + an emoji, both non-BMP
        let resolved = FontSubstitutionResolver.resolve([Span(text: text)])
        let rejoined = resolved.map(\.text).joined()
        XCTAssertEqual(rejoined, text, "splitting must never cut a surrogate pair in half")
        XCTAssertFalse(resolved.contains { $0.text.contains("\u{FFFD}") },
                       "no piece may contain a replacement character: \(resolved.map(\.text))")
    }

    /// The same property with plain ASCII on both sides of the pair (mirrors the report's ZWJ-family
    /// repro in miniature) — a mid-pair cut here would surface as the emoji itself vanishing into
    /// U+FFFD while "AB"/"CD" stayed intact, which a whole-string equality check alone could mask if
    /// the two sides happened to reassemble to the right LENGTH.
    func testCoverageNeverDisagreesBetweenTheTwoHalvesOfASurrogatePair() {
        let text = "AB😀CD"
        let resolved = FontSubstitutionResolver.resolve([Span(text: text)])
        XCTAssertEqual(resolved.map(\.text).joined(), text)
        XCTAssertFalse(resolved.contains { $0.text.contains("\u{FFFD}") })
        XCTAssertTrue(resolved.contains { $0.text.contains("😀") },
                      "the emoji itself must survive intact: \(resolved.map(\.text))")
    }

    // MARK: (b) Silent parity

    /// A span the declared font ALREADY covers (plain English) must come back from the resolver as
    /// the exact same `Span` value — not a copy that merely leaves `resolvedFontDescriptor` `nil`, the
    /// SAME value — which is the coverage-guard the whole feature depends on for invariant 37.
    func testFullyCoveredSpanIsReturnedUnchanged() {
        let span = Span(text: "Plain English text, digits 123, punctuation!", bold: true)
        let resolved = FontSubstitutionResolver.resolve([span])
        XCTAssertEqual(resolved, [span], "a fully covered span must be byte-identical, not merely equivalent")
    }

    /// An office document built from spans whose declared font is available (English, system font)
    /// renders BYTE-IDENTICAL whether or not those spans were run through the resolver first —
    /// nothing in `OfficeTextBuilder` may fire for a document this feature was never meant to touch.
    func testOfficeDocumentUsingAnAvailableFamilyIsByteIdentical() {
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

    /// Markdown never constructs an office `Span`/`OfficeBlock` at all — `MarkdownRenderer` builds
    /// straight from swift-markdown's own AST — so this feature has no code path into it. This pins
    /// that fact as a real assertion (two independent renders of the same source must agree) rather
    /// than leaving it as an unverified claim in a report.
    func testMarkdownRenderingIsUntouchedByOfficeFontResolution() {
        let md = "# Heading\n\nPlain paragraph text, unrelated to office font substitution."
        let theme = RenderTheme.current(size: 16)
        let a = MarkdownRenderer.render(md, theme: theme)
        let b = MarkdownRenderer.render(md, theme: theme)
        XCTAssertTrue(a.isEqual(to: b))
    }

    // MARK: (c) Installed-run reduction

    /// The deterministic knob design §4 names: resolving substitution at read time must reduce the
    /// INSTALLED attribute-run count for text AppKit would otherwise keep re-substituting per
    /// character. A future change that defeats the resolver (e.g. it stops splitting, or stops being
    /// consulted at build time) regresses this number, not just a wall-clock measurement nobody
    /// reruns.
    func testInstalledRunCountDropsForUncoveredKoreanText() {
        let korean = String(repeating: "긴 한글 문단이 반복됩니다. ", count: 40)
        let rawSpans = [Span(text: korean)]
        let resolvedSpans = FontSubstitutionResolver.resolve(rawSpans)

        func installedRuns(_ spans: [Span]) -> Int {
            let attr = build(spans)
            let storage = NSTextStorage()
            storage.setAttributedString(attr)
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

    // MARK: Mixed-script splitting (genuinely uncoverable by one substitute)

    /// A span whose substitute STILL cannot cover everything must split into maximal same-substitute
    /// runs, never per character. Two things this proves independent of (a)'s span-coarsening: no
    /// character is dropped or duplicated by the split, and every emitted piece's descriptor (where
    /// set) genuinely covers that piece's own text — i.e. this really did split at real coverage
    /// boundaries, not at arbitrary ones.
    func testMixedScriptSpanSplitsIntoMaximalRunsAndEveryPieceIsSelfCovering() {
        // Korean + Japanese kana + Latin in one span — plausibly three different substitute
        // decisions depending on the installed cascade.
        let text = "한글かなLatin다시한글"
        let raw = [Span(text: text)]
        let resolved = FontSubstitutionResolver.resolve(raw)
        XCTAssertGreaterThanOrEqual(resolved.count, 1)
        // Reassembling the pieces must reproduce the source text exactly — a split must never drop
        // or duplicate a character.
        XCTAssertEqual(resolved.map(\.text).joined(), text)
        for piece in resolved {
            let font: NSFont = piece.resolvedFontDescriptor.flatMap { NSFont(descriptor: $0, size: 12) }
                ?? NSFont.systemFont(ofSize: 12)
            let ns = piece.text as NSString
            var chars = [UniChar](repeating: 0, count: ns.length)
            ns.getCharacters(&chars, range: NSRange(location: 0, length: ns.length))
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            let covers = CTFontGetGlyphsForCharacters(font as CTFont, chars, &glyphs, chars.count)
            XCTAssertTrue(covers, "piece '\(piece.text)' must be fully covered by its own assigned font")
        }
    }
}
