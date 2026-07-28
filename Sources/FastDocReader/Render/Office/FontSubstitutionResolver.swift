import AppKit
import CoreText

/// Resolves AppKit's own font-substitution decision ONCE, at READ time, instead of letting it
/// happen — silently, per character, 114,412 times on the reference HWP — inside `setAttributedString`
/// on EVERY ⌘+/⌘− press. Full measurement and rationale: `docs/font-substitution-cost-design.md`.
///
/// **Why read time, not a memo consulted on every press:** this app is a READER. A document's text,
/// its declared fonts and its authored sizes are fixed the moment the file is read and can never
/// change again — only ⌘R, which re-reads the file from disk and rebuilds everything anyway, can
/// change them. That single fact removes the entire cache-invalidation problem before it exists: a
/// process-wide memo keyed on `(family, traits, script)` would have to answer for key completeness,
/// entry lifetime across MULTIPLE open documents, thread safety, and unbounded growth — four hazards
/// that all evaporate once the resolved answer simply lives on the `Span` the text came from.
///
/// **ONE REPRESENTATIVE PER DECLARED FONT — the shape of this pass, and the whole of it.** For each
/// DISTINCT declared font in the document, CoreText is asked exactly one question: *does this font
/// draw the most common character this document actually uses under it, and if not, what does?* That
/// single answer is then applied to every span carrying that declared font, across its whole text,
/// with **no per-span coverage test and no splitting**. Measured against the previous per-span-split
/// shape on the reference HWP: spans 17,910 → 9,328, built font runs 19,088 → 9,239, installed font
/// runs 23,097 → 16,119, CoreText calls at read 2,209 → 5, and build + first-query + layout
/// 2,596 ms → 1,292 ms. Four cheaper-looking alternatives were costed and each is ruled out by a
/// measurement, recorded in `docs/font-substitution-cost-design.md` §6 so none is re-derived:
/// one descriptor for the WHOLE document loses bold; the dominant family as the reader's base font
/// needs a private system-UI font name CoreText refuses; gating on whether the declared family is
/// INSTALLED silently misses a Korean `.docx` whose runs name Times New Roman; and pre-splitting the
/// characters the representative still cannot draw moved the installed count by exactly zero.
///
/// **Why the CHOICE of substitute is still not ours:** the font recorded here is `CTFontCreateForString`'s
/// answer — the SAME cascade AppKit's own attribute fixing consults — never a hardcoded family. What
/// changes, deliberately, is the GRANULARITY: one question per declared font rather than one per span,
/// and one answer across a whole span rather than a cut at each character the declared font could have
/// drawn on its own. See `sampleCharacter` for why the character CoreText is asked about is chosen the
/// way it is, and `FontSubstitutionResolverTests`' file doc for what glyph identity does and does not
/// guarantee as a result.
enum FontSubstitutionResolver {
    /// Coverage/substitution does not depend on point size — "whatever covers 가 at 12pt covers it
    /// at 14pt" (design §1) — so this fixed size exists only to construct a real `NSFont` instance
    /// to query CoreText with; it is never seen on screen (`OfficeTextBuilder` always reconstructs
    /// the resolved name at the span's own authored/theme size).
    fileprivate static let probeSize: CGFloat = 12
    private static let defaultFamilyFont = NSFont.systemFont(ofSize: probeSize)
    private static let codeFamilyFont = NSFont.monospacedSystemFont(ofSize: probeSize, weight: .regular)

    /// The WEIGHT `OfficeTextBuilder` starts a block's spans from, BEFORE any span-level bold/italic
    /// — `RenderTheme.headingFont` is `.systemFont(weight: .semibold)`, `.bodyFont`/list items are
    /// plain `.systemFont`. It is threaded in by `OfficeBlock.applyingFontSubstitution` from the
    /// block type it already has in hand, because it genuinely changes which face CoreText
    /// substitutes (see `declaredFont`).
    enum BlockWeight: Hashable {
        case regular
        case semibold

        fileprivate var probeFont: NSFont {
            switch self {
            case .regular: return defaultFamilyFont
            case .semibold: return NSFont.systemFont(ofSize: probeSize, weight: .semibold)
            }
        }
    }

    /// Everything `declaredFont` varies on — a PURE function of these five values. This is also the
    /// unit "one representative per DECLARED FONT" counts in: two spans sharing a key are asking
    /// CoreText the identical question, so they get the identical answer by construction rather
    /// than by coincidence. Bold and italic are part of the key deliberately: CoreText's cascade
    /// picks a DIFFERENT face per weight (a Korean character resolves to `.AppleSDGothicNeoI-Regular`
    /// under `.systemFont(12)` and `-Bold` under the same font with `.bold` added), so folding
    /// weights together is exactly how a bold Korean heading ends up drawn regular.
    struct DeclaredFontKey: Hashable {
        let code: Bool
        let fontName: String?
        let blockWeight: BlockWeight
        let bold: Bool
        let italic: Bool

        init(span: Span, blockWeight: BlockWeight) {
            self.code = span.code
            self.fontName = span.fontName
            self.blockWeight = blockWeight
            self.bold = span.bold
            self.italic = span.italic
        }
    }

    /// The font `OfficeTextBuilder.spansAttributedString` would actually draw a span in, BEFORE any
    /// font substitution touches it — same precedence that function uses (`code` wins over a family
    /// override wins over the block's base weight), with the span's own bold/italic UNIONED IN
    /// before CoreText is ever asked for a substitute.
    ///
    /// Probing with the wrong weight and re-adding traits AFTERWARDS does not recover this:
    /// `withSymbolicTraits` on the opaque, private substitute descriptor these system-UI cascades
    /// hand back does not reliably stay in the same family — measured, adding `.bold` on top of an
    /// already-`-SemiBold` substitute produced `.AppleKoreanFont-Bold`, a different face entirely,
    /// and adding `[.bold, .italic]` on top of an `-Regular` substitute silently no-opped. Building
    /// the FULLY-TRAITED probe font first and asking CoreText ONCE is what "the SAME cascade AppKit's
    /// own attribute fixing already consults" (design §2) actually requires.
    private static func declaredFont(for key: DeclaredFontKey, cache: FontSubstitutionCache) -> NSFont {
        if let cached = cache.declaredFontMemo[key] { return cached }
        var font: NSFont
        if key.code {
            font = codeFamilyFont
        } else if let name = key.fontName, let named = NSFont(name: name, size: probeSize) {
            font = named
        } else {
            font = key.blockWeight.probeFont
        }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if key.bold { traits.insert(.bold) }
        if key.italic { traits.insert(.italic) }
        if !traits.isEmpty { font = fontAdding(traits, to: font) }
        cache.declaredFontMemo[key] = font
        return font
    }

    /// Adds symbolic traits while keeping the SAME family — used here only on PUBLIC, ordinary font
    /// families (the block's base weight and/or a `fontName` override) where trait-matching is
    /// reliable, never on an already-resolved private substitute descriptor (see `declaredFont`).
    private static func fontAdding(_ traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }

    // MARK: - Phase 1, the survey

    /// Whether a character may be the one CoreText is asked about: everything EXCEPT the absorbing
    /// classes — Script=Common, Script=Inherited and `Grapheme_Extend` (`ScriptClass.isAbsorbing`,
    /// the shared floor `ScriptRunSplitter` already stands on). Both halves of that sentence are
    /// load-bearing and each was proven by a document this rule got wrong first.
    ///
    /// **Why the absorbing classes are excluded.** A space, a digit, a curly quote, a FIGURE SPACE
    /// or a combining mark says nothing about which writing system a font is drawing — and space is
    /// the single most common character in nearly every document, so counting it would make EVERY
    /// census answer "space", which every font draws, and the gate would never fire on anything.
    ///
    /// **Why ASCII letters are INCLUDED, which is the part that is easy to get wrong.** Restricting
    /// the census to non-ASCII asks a subtly different question — "what is the most common FOREIGN
    /// character?" — and a font whose text is ordinary Latin with a handful of exotic ones then gets
    /// judged on the exotic ones. Measured on a real 400k-character report: `Times New Roman` there
    /// draws 5,177 characters of ordinary Latin plus a few `U+2164` ROMAN NUMERAL FIVE section
    /// numbers, this Mac's Times New Roman has no glyph for `U+2164`, and a non-ASCII-only census
    /// therefore sampled `Ⅴ`, failed the gate, and moved all 5,177 characters onto Lucida Grande —
    /// serif body text silently redrawn sans-serif. Counting the Latin letters too makes the sample
    /// `e`, Times New Roman draws `e`, and the gate correctly does not fire; the few Roman numerals
    /// fall back to AppKit's own per-character substitution exactly as they always have.
    ///
    /// That is also what protects the case the PREVIOUS per-span design needed a `lastBad` bound
    /// for: an English contract carrying one soft hyphen (`U+00AD`, absorbing) or one Wingdings PUA
    /// bullet is sampled on its own Latin letters, the gate never fires, and no unrelated word can
    /// be dragged onto a symbol font's fallback. Same defect, prevented by a different and simpler
    /// mechanism — the gate does not fire at all rather than firing and then being trimmed back.
    ///
    /// **Private Use is the one further exclusion, and it is also measured, not theorised.** A PUA
    /// codepoint has no agreed meaning — its glyph is defined only by the font that declared it, so
    /// "what else draws `U+F0854`" has no correct answer, only an accidental one. On the same 400k
    /// report, `HY신명조` is used mostly for a repeated supplementary-PUA ornament, so it sampled
    /// that ornament, no installed font claimed it, and CoreText answered `LastResort` — the font
    /// whose entire job is to draw a box meaning "nothing here draws this". 450 characters of
    /// perfectly drawable Korean went out as boxes. Skipping PUA lets that font be sampled on its
    /// Hangul instead, which is what it is actually being used for.
    private static func isSampleEligible(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if (0xE000...0xF8FF).contains(value) || (0xF0000...0xFFFFD).contains(value)
            || (0x100000...0x10FFFD).contains(value) { return false }
        return !UnicodeScript.of(scalar).isAbsorbing
    }

    /// CoreText's way of saying it has nothing: the font that draws every codepoint as a box. It is
    /// the ABSENCE of a substitute, not a substitute, so accepting it would paint a whole span's
    /// worth of otherwise-drawable text as boxes. Belt to the PUA exclusion's braces — that removes
    /// the one case measured to reach here, this refuses the answer itself, so an unsupported script
    /// nobody has anticipated cannot do the same thing from a direction nobody listed.
    private static let noSubstituteFontName = "LastResort"

    /// The most common eligible character, ties broken by the LOWER codepoint. The tie-break is not
    /// cosmetic: a `Dictionary`'s iteration order is per-process hash-randomised, so "whichever
    /// maximum I met first" would let the same document resolve to a different face on a different
    /// launch — the exact fault invariant 50 records having shipped once already, from a different
    /// direction.
    private static func sampleCharacter(_ histogram: [UInt32: Int]) -> UInt32? {
        var best: (scalar: UInt32, count: Int)?
        for (scalar, count) in histogram {
            if let b = best, count < b.count || (count == b.count && scalar > b.scalar) { continue }
            best = (scalar, count)
        }
        return best?.scalar
    }

    /// The whole decision for one document: census every span, then ask CoreText once per declared
    /// font. Nothing is written to any span here — the plan is a value the apply pass reads.
    static func plan(for blocks: [OfficeBlock],
                     cache: FontSubstitutionCache = FontSubstitutionCache()) -> FontSubstitutionPlan {
        var histograms: [DeclaredFontKey: [UInt32: Int]] = [:]
        census(blocks, blockWeight: .regular, into: &histograms)
        return decide(histograms, cache: cache)
    }

    /// One question per declared font, and the only place CoreText is consulted.
    private static func decide(_ histograms: [DeclaredFontKey: [UInt32: Int]],
                               cache: FontSubstitutionCache) -> FontSubstitutionPlan {
        var substitutes: [DeclaredFontKey: FontSubstitutionPlan.Substitute] = [:]
        for (key, histogram) in histograms {
            guard let sample = sampleCharacter(histogram) else { continue }
            let declared = declaredFont(for: key, cache: cache)
            // THE GATE. Not "is the declared family installed?" — Times New Roman, Arial, Helvetica
            // and Georgia are all installed here and none of them draws Hangul, so an availability
            // test passes a Korean `.docx` (Word writes Times New Roman into the ascii slot by
            // default) straight through to AppKit's per-character fixing. Ask whether the declared
            // font draws THIS DOCUMENT's own characters instead, and that cliff cannot exist.
            guard !cache.covers(declared, sample) else { continue }
            let substitute = cache.substituteFont(declared: declared, scalar: sample)
            guard substitute.fontName != noSubstituteFontName else { continue }
            substitutes[key] = .init(sample: sample, descriptor: substitute.fontDescriptor)
        }
        return FontSubstitutionPlan(substitutes: substitutes)
    }

    /// Recursive read-only walk — a table's cells hold the same block vocabulary as the top of a
    /// document, and a heading's spans start from a different weight, which is the one piece of
    /// block context the key needs.
    private static func census(_ blocks: [OfficeBlock], blockWeight: BlockWeight,
                               into histograms: inout [DeclaredFontKey: [UInt32: Int]]) {
        for block in blocks {
            switch block {
            case let .heading(_, spans, _, _, _, _):
                tally(spans, blockWeight: .semibold, into: &histograms)
            case let .paragraph(spans, _, _, _, _), let .listItem(_, _, spans, _, _, _, _, _):
                tally(spans, blockWeight: blockWeight, into: &histograms)
            case let .table(rows, _, _, _):
                for row in rows {
                    for cell in row { census(cell.blocks, blockWeight: blockWeight, into: &histograms) }
                }
            case .image, .unsupportedGraphic, .formula:
                continue
            }
        }
    }

    private static func tally(_ spans: [Span], blockWeight: BlockWeight,
                              into histograms: inout [DeclaredFontKey: [UInt32: Int]]) {
        for span in spans where !span.text.isEmpty {
            let key = DeclaredFontKey(span: span, blockWeight: blockWeight)
            for scalar in span.text.unicodeScalars where isSampleEligible(scalar) {
                histograms[key, default: [:]][scalar.value, default: 0] += 1
            }
        }
    }

    // MARK: - Phase 2, applying it

    /// A span whose declared font needs no substitute comes back as the EXACT SAME `Span` value —
    /// not a copy that merely leaves `resolvedFontDescriptor` `nil` — which is the byte-identical
    /// guard invariant 37 depends on: nothing downstream can tell it apart from a span this pass
    /// never touched, because there is no difference to tell.
    static func resolve(_ spans: [Span], blockWeight: BlockWeight = .regular,
                        plan: FontSubstitutionPlan) -> [Span] {
        guard !plan.isEmpty else { return spans }
        return spans.map { span in
            guard !span.text.isEmpty,
                  let substitute = plan.substitutes[DeclaredFontKey(span: span, blockWeight: blockWeight)]
            else { return span }
            var out = span
            out.resolvedFontDescriptor = substitute.descriptor
            return out
        }
    }

    /// Survey and apply in one call, over just these spans — the shape a caller resolving one block
    /// in isolation (every direct unit test) wants. The production path plans over the WHOLE
    /// document first, which is the point: a font's representative is chosen from everything the
    /// document draws in it, not from one paragraph's worth.
    static func resolve(_ spans: [Span], blockWeight: BlockWeight = .regular,
                        cache: FontSubstitutionCache = FontSubstitutionCache()) -> [Span] {
        var histograms: [DeclaredFontKey: [UInt32: Int]] = [:]
        tally(spans, blockWeight: blockWeight, into: &histograms)
        return resolve(spans, blockWeight: blockWeight, plan: decide(histograms, cache: cache))
    }
}

/// One document's whole substitution decision: for each distinct declared font, the ONE descriptor
/// every span carrying that font is drawn with. A separate value rather than state inside the cache
/// so that applying without surveying is not expressible — an apply pass silently running against
/// an empty plan would look exactly like a document that needed no substitutes.
struct FontSubstitutionPlan {
    /// The sample is carried alongside the descriptor because the run count alone cannot say WHY a
    /// document moved — which declared font was replaced, and on the evidence of which character.
    /// A reviewer reading "5,177 characters left Times New Roman" needs to see the character that
    /// decided it, and a probe that can only report totals cannot show them.
    struct Substitute {
        let sample: UInt32
        let descriptor: NSFontDescriptor
    }

    fileprivate let substitutes: [FontSubstitutionResolver.DeclaredFontKey: Substitute]
    /// Empty means "every declared font in this document draws its own text" — the byte-identical
    /// case, and the one the apply pass short-circuits.
    var isEmpty: Bool { substitutes.isEmpty }
    /// How many distinct declared fonts got a substitute. The deterministic number a test asserts
    /// on, in preference to a wall clock this machine has been measured swinging up to 11×.
    var substitutedFontCount: Int { substitutes.count }

    /// One human-readable line per substituted declared font, sorted so two runs of the same
    /// document print identically.
    var describedEntries: [String] {
        substitutes.map { key, value in
            let sample = Unicode.Scalar(value.sample).map { "U+\(String(value.sample, radix: 16, uppercase: true)) '\(Character($0))'" }
                ?? "U+\(String(value.sample, radix: 16, uppercase: true))"
            let traits = [key.bold ? "bold" : nil, key.italic ? "italic" : nil,
                          key.code ? "code" : nil, key.blockWeight == .semibold ? "heading" : nil]
                .compactMap { $0 }.joined(separator: "+")
            return "\(key.fontName ?? "<theme>")\(traits.isEmpty ? "" : " [\(traits)]") "
                + "— sample \(sample) → \(value.descriptor.postscriptName ?? "?")"
        }.sorted()
    }
}

/// A memo scoped to EXACTLY ONE document read — created fresh by `OfficeReadResult.
/// resolvingFontSubstitution()` and never referenced again once it returns. Under the
/// one-representative-per-declared-font design its job is small and exact: the survey asks CoreText
/// at most twice per distinct declared font (does it cover the sample; if not, what does), and this
/// memo collapses the fonts that share an answer — five CoreText round-trips for the whole reference
/// HWP, against 2,209 under the previous per-span shape.
///
/// **The key, and why it cannot collide:** `(font identity, Unicode codepoint)`, where font identity
/// is `NSFont.fontName` — the PostScript name — read off the font AFTER traits are unioned in, so
/// `.SFNS-Regular` and `.SFNS-Bold` are different keys by construction rather than by any assumption
/// this cache makes. The codepoint is a full scalar, never a UTF-16 half. Both questions are asked
/// about that ONE character in isolation, so the key IS the question, verbatim — this cache can only
/// return an answer CoreText itself already gave for that literal pair earlier in this same read.
///
/// (The previous shape handed `CTFontCreateForString` the whole REMAINDER of a span, which made the
/// leading codepoint an under-description of the real question — a variation selector immediately
/// after the base changes CoreText's answer, and a key ignoring it leaked a colour-emoji font onto a
/// later, unrelated plain `⚙`. Asking about one isolated, sample-eligible character removes that
/// class of error rather than guarding against it: a variation selector is `Grapheme_Extend`, an
/// emoji base is Script=Common, and neither can ever be a sample.)
final class FontSubstitutionCache {
    fileprivate struct Key: Hashable {
        let fontKey: String
        let scalar: UInt32
    }

    fileprivate var declaredFontMemo: [FontSubstitutionResolver.DeclaredFontKey: NSFont] = [:]
    private var coverageMemo: [Key: Bool] = [:]
    private var substituteMemo: [Key: NSFont] = [:]

    /// Every real `CTFontGetGlyphsForCharacters` call this cache issues.
    private(set) var coverageCoreTextCalls = 0
    /// Every real `CTFontCreateForString` call.
    private(set) var substituteCoreTextCalls = 0
    /// The deterministic knob this pass is judged by, mirroring invariant 49's `layoutStepCount`
    /// idiom: count CoreText round-trips, not wall clock.
    var coreTextCallCount: Int { coverageCoreTextCalls + substituteCoreTextCalls }

    /// Does `font` have a glyph for this one character? A cmap lookup, memoised per (font, scalar).
    /// Tested on `glyphs[0]` rather than the function's own return value because a non-BMP scalar is
    /// two UTF-16 units and CoreText reports the trailing half as unmapped even when the pair
    /// resolved — the same reading the pre-memo code used.
    func covers(_ font: NSFont, _ scalar: UInt32) -> Bool {
        let key = Key(fontKey: font.fontName, scalar: scalar)
        if let hit = coverageMemo[key] { return hit }
        guard let unicode = Unicode.Scalar(scalar) else { return false }
        var units = Array(String(unicode).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        _ = CTFontGetGlyphsForCharacters(font as CTFont, &units, &glyphs, units.count)
        coverageCoreTextCalls += 1
        let covered = glyphs[0] != 0
        coverageMemo[key] = covered
        return covered
    }

    /// What CoreText itself would substitute for this one character when `declared` cannot draw it —
    /// `CTFontCreateForString` over a string holding exactly that character, memoised per
    /// (declared font, scalar). On a hit this issues zero CoreText calls and returns the SAME live
    /// object CoreText produced, not a reconstruction from a saved descriptor.
    func substituteFont(declared: NSFont, scalar: UInt32) -> NSFont {
        let key = Key(fontKey: declared.fontName, scalar: scalar)
        if let hit = substituteMemo[key] { return hit }
        guard let unicode = Unicode.Scalar(scalar) else { return declared }
        let text = String(unicode) as CFString
        let font = CTFontCreateForString(declared as CTFont, text,
                                         CFRange(location: 0, length: CFStringGetLength(text))) as NSFont
        substituteCoreTextCalls += 1
        substituteMemo[key] = font
        return font
    }
}

extension OfficeBlock {
    /// This block with its spans drawn through `plan` — recurses into a table's cells, since a
    /// cell's content is the SAME format-neutral block vocabulary as the top of a document.
    /// `.image`/`.unsupportedGraphic`/`.formula` carry no spans and pass through unchanged.
    func applyingFontSubstitution(_ plan: FontSubstitutionPlan) -> OfficeBlock {
        switch self {
        case let .heading(level, spans, rtl, alignment, tabStops, format):
            // `RenderTheme.headingFont` is `.systemFont(weight: .semibold)` regardless of level
            // (level only changes SIZE, never weight) — see `FontSubstitutionResolver.BlockWeight`.
            return .heading(level: level,
                             spans: FontSubstitutionResolver.resolve(spans, blockWeight: .semibold, plan: plan),
                             rtl: rtl, alignment: alignment, tabStops: tabStops, format: format)
        case let .paragraph(spans, rtl, alignment, tabStops, format):
            return .paragraph(spans: FontSubstitutionResolver.resolve(spans, plan: plan), rtl: rtl,
                               alignment: alignment, tabStops: tabStops, format: format)
        case let .listItem(level, ordered, spans, marker, rtl, alignment, tabStops, format):
            return .listItem(level: level, ordered: ordered,
                              spans: FontSubstitutionResolver.resolve(spans, plan: plan),
                              marker: marker, rtl: rtl, alignment: alignment, tabStops: tabStops, format: format)
        case let .table(rows, headerRows, columnWidths, format):
            let resolvedRows = rows.map { row in
                row.map { cell -> Cell in
                    var c = cell
                    c.blocks = c.blocks.map { $0.applyingFontSubstitution(plan) }
                    return c
                }
            }
            return .table(rows: resolvedRows, headerRows: headerRows, columnWidths: columnWidths, format: format)
        case .image, .unsupportedGraphic, .formula:
            return self
        }
    }

    /// Survey and apply over just this block — the shape a direct unit test wants; the production
    /// path surveys the whole document (see `OfficeReadResult.resolvingFontSubstitution`).
    func resolvingFontSubstitution(cache: FontSubstitutionCache = FontSubstitutionCache()) -> OfficeBlock {
        applyingFontSubstitution(FontSubstitutionResolver.plan(for: [self], cache: cache))
    }
}

extension OfficeReadResult {
    /// The single point every reader's result flows through — called from `DocumentTypes.readOffice`
    /// (docx/odt/docm/dotx/dotm, ONE call site for all of them) and from `HwpReader.read` (HWP's own
    /// single dispatch, invariant 44) — so no caller of either can forget it, and neither reader
    /// re-implements the resolution itself.
    ///
    /// Two passes over the blocks, in this order and never merged: the survey has to have seen the
    /// WHOLE document before the first span is written, because "the most common character under
    /// this declared font" is a fact about the document, not about whichever paragraph happened to
    /// be reached first.
    func resolvingFontSubstitution(cache: FontSubstitutionCache = FontSubstitutionCache()) -> OfficeReadResult {
        let plan = FontSubstitutionResolver.plan(for: blocks, cache: cache)
        var copy = self
        copy.blocks = blocks.map { $0.applyingFontSubstitution(plan) }
        return copy
    }
}
