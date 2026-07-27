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
/// that all evaporate once the resolved answer simply lives on the `Span` the text came from. It can
/// never go stale because its inputs (this document's own text and declared fonts) cannot change.
///
/// **Why the CHOICE of substitute must not change:** the font recorded here is not one of this app's
/// own choosing — it is `CTFontCreateForString`'s answer, the SAME cascade AppKit's own attribute
/// fixing already consults today, never a hardcoded family. What DOES change, deliberately, is the
/// GRANULARITY at which it is applied — see `resolveOne`'s own doc for why span-level (not
/// per-character) is required, measured, and the correct reading of design §2's "record it on the
/// span" — and `FontSubstitutionResolverTests`' file doc for exactly what glyph identity does and
/// does not guarantee as a result.
///
/// **A SECOND cost, found after that read-time relocation shipped: the SAME CoreText question was
/// still being asked once per SPAN — ~17,900 of them on the reference HWP — even though the answer
/// depends only on a HANDFUL of distinct (declared typeface, traits, character) combinations.**
/// Read+parse measured 644 ms → 1,266–1,293 ms (roughly doubled) purely from `coverage(of:in:)` and
/// `CTFontCreateForString` being invoked fresh for every span, most of them asking CoreText something
/// it had already answered minutes (well, microseconds) earlier for a different span built from the
/// same handful of Korean characters, particles, and boilerplate a real administrative document
/// repeats constantly. `FontSubstitutionCache` (below) fixes this the same way as the read-time
/// relocation itself: by giving the answer a lifetime that exactly matches the question's — one
/// document READ, never longer, never shared across documents, never consulted again after this
/// function returns. See that type's own doc for the key design and why it cannot collide.
enum FontSubstitutionResolver {
    /// Coverage/substitution does not depend on point size — "whatever covers 가 at 12pt covers it
    /// at 14pt" (design §1) — so this fixed size exists only to construct a real `NSFont` instance
    /// to query CoreText with; it is never seen on screen (`OfficeTextBuilder` always reconstructs
    /// the resolved name at the span's own authored/theme size). `fileprivate`, not `private`, so
    /// `FontSubstitutionCache` — a separate type in this same file — can reconstruct a cached
    /// substitute descriptor at the identical probe size it was resolved at.
    fileprivate static let probeSize: CGFloat = 12
    private static let defaultFamilyFont = NSFont.systemFont(ofSize: probeSize)
    private static let codeFamilyFont = NSFont.monospacedSystemFont(ofSize: probeSize, weight: .regular)

    /// The WEIGHT `OfficeTextBuilder` starts a block's spans from, BEFORE any span-level bold/italic
    /// — `RenderTheme.headingFont` is `.systemFont(weight: .semibold)`, `.bodyFont`/list items are
    /// plain `.systemFont`. This is NOT the "heading vs. body never matters" claim this file used to
    /// make (see the corrected doc on `declaredFont` below for why that was wrong) — it is the one
    /// piece of block context that DOES change which face CoreText substitutes, threaded in by
    /// `OfficeBlock.resolvingFontSubstitution()` from the block type it already has in hand.
    /// `Hashable` so it can sit in `FontSubstitutionCache`'s memo keys alongside the rest of what
    /// `declaredFont` varies on.
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

    /// Everything `declaredFont(for:blockWeight:)` actually varies on — a PURE function of these five
    /// values, so memoising by them is exact, not approximate: two spans with the same key are, by
    /// construction, asking `declaredFont` to build the identical probe font.
    fileprivate struct DeclaredFontKey: Hashable {
        let code: Bool
        let fontName: String?
        let blockWeight: BlockWeight
        let bold: Bool
        let italic: Bool
    }

    /// The font `OfficeTextBuilder.spansAttributedString` would actually draw this span in, BEFORE
    /// any font-substitution touches it — same precedence that function uses (`code` wins over a
    /// family override wins over the block's base weight), and now also carrying the span's own
    /// bold/italic, UNIONED IN before CoreText is ever asked for a substitute.
    ///
    /// **Corrected from this file's first version**, which probed with a REGULAR system font no
    /// matter what: "heading level vs. body vs. list item never matters here... neither changes
    /// glyph coverage" was true about COVERAGE and false about SUBSTITUTE CHOICE — CoreText's own
    /// cascade picks a DIFFERENT face per weight (measured: a Korean character resolves to
    /// `.AppleSDGothicNeoI-Regular` under `.systemFont(12)`, `-SemiBold` under `.systemFont(12,
    /// weight: .semibold)`, `-Bold` under a font with the `.bold` symbolic trait added — three real,
    /// different fonts). Probing with the wrong weight/traits and then trying to re-add them AFTER
    /// substitution (`OfficeTextBuilder`'s old `fontAdding(traits, to: substitutedFont)`) does not
    /// recover this: `withSymbolicTraits` on an opaque, private substitute descriptor (what these
    /// system-UI cascades hand back) does not reliably stay in the same family — measured, adding
    /// `.bold` on top of an already-`-SemiBold` substitute produced `.AppleKoreanFont-Bold`, a
    /// different face entirely, and adding `[.bold, .italic]` on top of an `-Regular` substitute
    /// silently no-opped (stayed `-Regular`). Building the FULLY-TRAITED probe font first and asking
    /// CoreText ONCE is what "the SAME cascade AppKit's own attribute fixing already consults today"
    /// (design §2) actually requires.
    ///
    /// Memoised in `cache.declaredFontMemo` by `DeclaredFontKey` — a handful of distinct combinations
    /// recur across thousands of spans in a real document (most spans in one block share the exact
    /// same `code`/`fontName`/`bold`/`italic` and the block's own weight), so this constructs the
    /// probe font once per COMBINATION, never once per span.
    private static func declaredFont(for span: Span, blockWeight: BlockWeight, cache: FontSubstitutionCache) -> NSFont {
        let key = DeclaredFontKey(code: span.code, fontName: span.fontName, blockWeight: blockWeight,
                                   bold: span.bold, italic: span.italic)
        if let cached = cache.declaredFontMemo[key] { return cached }
        var font: NSFont
        if span.code {
            font = codeFamilyFont
        } else if let name = span.fontName, let named = NSFont(name: name, size: probeSize) {
            font = named
        } else {
            font = blockWeight.probeFont
        }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if span.bold { traits.insert(.bold) }
        if span.italic { traits.insert(.italic) }
        if !traits.isEmpty { font = fontAdding(traits, to: font) }
        cache.declaredFontMemo[key] = font
        return font
    }

    /// Adds symbolic traits while keeping the SAME family — duplicated from `OfficeTextBuilder`'s
    /// private helper of the same name/shape (that one is private to its own file) — used here only
    /// on PUBLIC, ordinary font families (the block's base weight and/or a `fontName` override)
    /// where trait-matching is reliable, never on an already-resolved private substitute descriptor
    /// (see `declaredFont`'s doc for why that direction silently fails).
    private static func fontAdding(_ traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }

    /// Resolves a whole block's spans — the read-time entry point every reader's `OfficeReadResult`
    /// flows through (`OfficeBlock.resolvingFontSubstitution()` below), so no caller re-implements
    /// this per reader. `blockWeight` defaults to `.regular` (every pre-existing call site, and
    /// every non-heading block) — only a heading passes `.semibold`.
    ///
    /// `cache` defaults to a FRESH, private `FontSubstitutionCache()` when the caller omits it — so
    /// every existing direct call (every test in `FontSubstitutionResolverTests`, which resolves one
    /// span or one block in isolation) keeps behaving exactly as before, with no cross-call sharing.
    /// The real production path (`OfficeReadResult.resolvingFontSubstitution()`) constructs exactly
    /// ONE cache and threads it through every block in the document — that single shared instance,
    /// not this default, is what eliminates the redundant CoreText calls. See `FontSubstitutionCache`.
    static func resolve(_ spans: [Span], blockWeight: BlockWeight = .regular,
                         cache: FontSubstitutionCache = FontSubstitutionCache()) -> [Span] {
        var out: [Span] = []
        out.reserveCapacity(spans.count)
        for span in spans { out.append(contentsOf: resolveOne(span, blockWeight: blockWeight, cache: cache)) }
        return out
    }

    /// ONE span → one or more spans. A span the declared font already covers in full comes back as
    /// the EXACT SAME `Span` value (not a copy that merely leaves `resolvedFontDescriptor` `nil`) —
    /// the byte-identical guard invariant 37 depends on: nothing downstream can tell a resolved-but-
    /// covered span apart from one this pass never touched, because there is no difference to tell.
    ///
    /// **Span-granularity, not per-character** — this is the coarseness design §2 asks for
    /// ("record that resolved family ON THE SPAN"), and it is load-bearing, not a style choice:
    /// measured directly, matching AppKit's OWN per-character alternation exactly (declared font for
    /// an interleaved space/digit, substitute only for the Korean characters either side of it) drove
    /// the reference HWP's BUILT run count from 17,389 to 118,508 — i.e. it reproduced, at read
    /// time, the identical fragmentation this feature exists to eliminate, and cost accordingly
    /// (`OfficeTextBuilder.build` 625 ms → 5.8 s, `display` 1.5 s → 34 s, measured). Once a span
    /// needs ANY substitution, this resolves ONE substitute for the first uncovered position and
    /// extends it across every character IT covers — including a space, a digit, a Latin letter the
    /// DECLARED font would also have drawn — because a real CJK-capable substitute face covers
    /// ASCII/whitespace too, so those characters were never going to look different. Only a truly
    /// unrelated leading prefix (declared-covered text BEFORE the first uncovered character) stays
    /// on the declared font untouched, and only a substitute that genuinely fails partway (a script
    /// change the first substitute doesn't cover either) starts a new run — "maximal same-substitute
    /// runs," never per character.
    ///
    /// The substitution loop is bounded at the LAST uncovered position, not the end of the span —
    /// symmetric to the leading-prefix trim above. Once every remaining character is one the
    /// declared font covers on its own, there is nothing left needing a substitute; extending
    /// through it anyway is exactly the failure a real English contract paragraph exposed: one
    /// uncovered symbol (a soft hyphen, `w:softHyphen`'s `U+00AD`, or a Wingdings/Symbol PUA bullet)
    /// picked Helvetica Neue as CoreText's answer for THAT character, and because Helvetica Neue
    /// trivially covers ordinary Latin too, the greedy "extend across everything the substitute
    /// covers" rule rode it all the way to the end of the span — seven unrelated words silently
    /// changing typeface. Bounding at the last genuinely uncovered index keeps the CJK-interleaving
    /// case this design exists for completely intact (a paragraph of Korean has uncovered
    /// characters right up near its own end, so the bound rarely bites there) while giving back a
    /// real declared-covered TAIL its own untouched piece, the same as the leading prefix already
    /// gets.
    ///
    /// Both `coverage(of:in:)` and the substitute lookup are delegated to `cache` — this function no
    /// longer calls `CTFontGetGlyphsForCharacters`/`CTFontCreateForString` directly, and no longer
    /// keeps its own per-span dedup dictionary (the old local `cache: [String: …]`): `cache`'s own
    /// memo subsumes it, PLUS extends the same reuse across every other span in the document.
    private static func resolveOne(_ span: Span, blockWeight: BlockWeight, cache: FontSubstitutionCache) -> [Span] {
        guard !span.text.isEmpty else { return [span] }
        let ns = span.text as NSString
        let length = ns.length
        var chars = [UniChar](repeating: 0, count: length)
        ns.getCharacters(&chars, range: NSRange(location: 0, length: length))

        let declared = declaredFont(for: span, blockWeight: blockWeight, cache: cache)
        let declaredCoverage = cache.coverage(of: declared, in: chars)
        guard let firstBad = declaredCoverage.firstIndex(of: false) else { return [span] }
        let lastBad = declaredCoverage.lastIndex(of: false) ?? firstBad

        var pieces: [Span] = []
        if firstBad > 0 {
            // A genuinely declared-covered PREFIX (rare — most uncovered spans start uncovered)
            // stays on the declared font, unchanged: there is no reason to move text the declared
            // font already draws correctly onto a substitute it never needed.
            var prefix = span
            prefix.text = ns.substring(with: NSRange(location: 0, length: firstBad))
            pieces.append(prefix)
        }

        // The substitute for a given starting position is looked up through `cache` — keyed on
        // (declared font, the codepoint AT that position), so a repeated substitute WITHIN this span
        // (Korean/English/Korean/…) or across ANY OTHER span sharing this document's cache is
        // resolved and measured only ONCE for the whole read. See `FontSubstitutionCache.
        // substituteFont` for why the leading codepoint alone is a safe, collision-free key.
        func substitute(from start: Int) -> (descriptor: NSFontDescriptor, coverage: [Bool]) {
            let font = cache.substituteFont(declared: declared, source: ns, chars: chars, at: start, length: length)
            return (descriptor: font.fontDescriptor, coverage: cache.coverage(of: font, in: chars))
        }

        var pos = firstBad
        while pos <= lastBad {
            let (descriptor, subCoverage) = substitute(from: pos)
            // Extend across every character THIS substitute covers — deliberately NOT stopping at a
            // character the declared font would also have covered (see the doc above): a run break
            // only where this substitute itself runs out, OR where nothing further needs a
            // substitute at all (bounded at `lastBad`, see this method's doc).
            var end = pos
            while end <= lastBad, subCoverage[end] { end += 1 }
            if end == pos {
                // Must always progress; guard, never trust blindly — but progressing by a bare code
                // unit is exactly the mid-pair cut blockers 1/3 report: if THIS substitute doesn't
                // cover `pos` either (a genuinely mixed-script span, the next loop iteration tries a
                // different substitute), and `pos` is a surrogate PAIR's high half, a 1-code-unit
                // step would carve off the high surrogate alone and leave its low partner to start
                // the NEXT piece — a lone surrogate, which becomes U+FFFD the instant it is held in
                // a Swift `String`. Step by the character's real UTF-16 width instead.
                let isPairStart = pos + 1 <= lastBad && UTF16.isLeadSurrogate(chars[pos])
                    && UTF16.isTrailSurrogate(chars[pos + 1])
                end = pos + (isPairStart ? 2 : 1)
            }
            var piece = span
            piece.text = ns.substring(with: NSRange(location: pos, length: end - pos))
            piece.resolvedFontDescriptor = descriptor
            pieces.append(piece)
            pos = end
        }
        if pos < length {
            // A genuinely declared-covered TAIL (symmetric to the leading prefix above): nothing
            // from here to the end of the span needs a substitute, so it stays on the declared font.
            var suffix = span
            suffix.text = ns.substring(with: NSRange(location: pos, length: length - pos))
            pieces.append(suffix)
        }
        return pieces
    }
}

/// A memo scoped to EXACTLY ONE document read — created fresh by `OfficeReadResult.
/// resolvingFontSubstitution()` for that call and never referenced again once it returns. See the
/// file doc's "SECOND cost" section for the measurement that motivated this: `coverage(of:in:)` and
/// `CTFontCreateForString` were each being asked, once per span (~17,900 of them on the reference
/// HWP), a question whose answer depends only on a HANDFUL of distinct (declared typeface, traits,
/// character) combinations — the same character/particle/boilerplate vocabulary repeating across a
/// real document's thousands of spans and hundreds of near-identical table rows.
///
/// **Why THIS lifetime, and not a process-wide cache (again):** `docs/font-substitution-cost-design.md`
/// §2 already rejected a process-wide `(family, traits, script)` memo when it decided read time was
/// the right lifetime for the RESOLVED SPANS themselves — key completeness, entry lifetime across
/// MULTIPLE open documents, thread safety, unbounded growth. Every one of those hazards would return
/// unchanged if this cache lived any longer than one call: this app is a reader, a document's text
/// and declared fonts cannot change after it is read, so a memo scoped to exactly that read cannot go
/// stale, needs no invalidation, cannot leak between documents (a fresh instance every read, per
/// document, discarded the moment `resolvingFontSubstitution()` returns — nothing outlives the call
/// that created it), and raises no thread-safety question (one read, one cache, no concurrent access).
/// It is strictly narrower than the design doc's already-rejected shape, not a reopening of it.
///
/// **The key, stated explicitly, and why it cannot collide:**
///   `Key = (font identity, Unicode codepoint)`
/// - **Font identity** is `NSFont.fontName` — the PostScript name — read off the font AFTER traits
///   are unioned in (`declaredFont` above always applies bold/italic before returning; `substituteFont`
///   below keys on THAT already-traited `declared` font, never a bare family). Two distinct requested
///   typefaces can never share an entry because AppKit/CoreText guarantee distinct PostScript names
///   per distinct face — and, the specific failure this design deliberately avoids, a key that
///   IGNORED traits would conflate a bold run with a regular one: it cannot here, because `.SFNS-
///   Regular` and `.SFNS-Bold` are different `fontName`s by construction, not by any assumption this
///   cache makes. (A bug of exactly this shape — traits dropped between probing and drawing — was
///   already caught and fixed once in this file; see `declaredFont`'s "Corrected from this file's
///   first version" doc above. This cache reads `fontName` off the SAME fully-traited font that fix
///   produces, so it inherits the fix rather than re-risking the bug.)
/// - **Codepoint**, not a hand-rolled "script" bucket — a full 21-bit Unicode scalar, decoded from a
///   genuine UTF-16 surrogate pair when one is present, NEVER a lone UTF-16 half (`scalar(at:in:)`
///   below is the one place that decision is made, and both `coverage` and `substituteFont` route
///   through it so they can never disagree about where one atom ends and the next begins — the exact
///   bug class blockers 1/3 already found and fixed in the unmemoised code, see `resolveOne`'s doc).
///   Keying on the literal character rather than an inferred script classification is the safer of
///   the two choices this file could have made: a cache hit is only ever returned for a (font,
///   codepoint) pair CoreText has ALREADY been asked about, verbatim, earlier in this same read — so
///   returning the memoised answer is not an approximation extrapolated from "probably the same
///   script," it is the literal answer CoreText itself already gave for that exact question. No
///   Unicode-script table of this file's own invention has to be trusted for correctness; only
///   CoreText's own determinism (the same premise `declaredFont`'s "substitute choice" fix already
///   depends on) does. `FontSubstitutionCacheTests.testMemoisedResultsAreBitIdenticalToUnmemoised`
///   proves this empirically rather than leaving it as an argued claim.
///
/// - **CORRECTED — "verbatim" was true of `coverage` and false of `substituteFont`.** `substituteFont`
///   hands CoreText the WHOLE REMAINDER of the span from `start` onward (`CFRange(start, length -
///   start)`), not the isolated base codepoint — so the base scalar alone under-describes the actual
///   question whenever the very next character changes the cascade's answer. A Unicode variation
///   selector does exactly that: probed live, `CTFontCreateForString` resolves U+2699 alone to
///   `Menlo-Regular` but U+2699 immediately followed by VS16 (U+FE0F, "emoji presentation") to
///   `.AppleColorEmojiUI` — the SAME base scalar, two different remainders, two different real
///   answers. Keying on the base scalar alone let a span containing "⚙️" (gear + VS16) memoise the
///   emoji-font answer for U+2699, and a LATER, unrelated span's plain "⚙" (no selector) then receive
///   that memoised color-emoji font it was never asked about — measured on a real corpus document
///   (`docs/font-substitution-cost-design.md`'s reference set), order-dependent on which presentation
///   happened to resolve first. The key now also carries `followingVariationSelector` — the VS1–16 or
///   Ideographic Variation Selector (`FontSubstitutionCache.followingVariationSelector`, below)
///   sitting DIRECTLY after the base character, `0` when none — restoring "verbatim" as an actual
///   guarantee rather than a claim invalidated by exactly the part of the question the key omitted.
final class FontSubstitutionCache {
    fileprivate struct Key: Hashable {
        let fontKey: String
        let scalar: UInt32
        /// `0` for every `coverage(of:in:)` key — coverage is a context-free cmap lookup for one
        /// codepoint under one font (see this cache's file doc), so it never varies on this field and
        /// every call site there omits it. `substituteFont` is the one caller that passes a real
        /// value, exactly because it is the one question this key was proven NOT context-free for.
        var followingVariationSelector: UInt32 = 0
        init(fontKey: String, scalar: UInt32, followingVariationSelector: UInt32 = 0) {
            self.fontKey = fontKey
            self.scalar = scalar
            self.followingVariationSelector = followingVariationSelector
        }
    }

    fileprivate var declaredFontMemo: [FontSubstitutionResolver.DeclaredFontKey: NSFont] = [:]
    private var coverageMemo: [Key: Bool] = [:]
    private var substituteMemo: [Key: NSFont] = [:]

    /// Every real `CTFontGetGlyphsForCharacters` call this cache issues — counted once per BATCH
    /// (a whole span's worth of never-before-seen codepoints tested together), never once per
    /// character.
    private(set) var coverageCoreTextCalls = 0
    /// Every real `CTFontCreateForString` call — once per (declared font, leading codepoint) MISS.
    private(set) var substituteCoreTextCalls = 0
    /// The deterministic knob this fix is judged by, mirroring invariant 49's `layoutStepCount`
    /// idiom: count CoreText round-trips, not wall clock (which this machine has already been shown,
    /// in `docs/font-substitution-cost-design.md` §4, to swing wildly).
    var coreTextCallCount: Int { coverageCoreTextCalls + substituteCoreTextCalls }

    /// The Unicode scalar the UTF-16 code unit AT `index` begins — a decoded surrogate pair if
    /// `index` is a lead surrogate immediately followed by its trail, the raw code unit otherwise
    /// (including a lone/malformed surrogate: not a real character, and not coverable by any font
    /// either way, exactly as the unmemoised `coverage(of:in:)` already treated it). The single place
    /// this pairing decision is made — `codepoints(in:)` and `substituteFont` both route through it,
    /// so they can never disagree about where one atom ends and the next begins.
    private static func scalar(at index: Int, in chars: [UniChar]) -> UInt32 {
        if index + 1 < chars.count, UTF16.isLeadSurrogate(chars[index]), UTF16.isTrailSurrogate(chars[index + 1]) {
            return 0x10000 + (UInt32(chars[index]) - 0xD800) * 0x400 + (UInt32(chars[index + 1]) - 0xDC00)
        }
        return UInt32(chars[index])
    }

    /// The variation selector sitting DIRECTLY after the character that starts at `index` and is
    /// `width` UTF-16 code units wide — VS1–VS16 (U+FE00–U+FE0F; VS15 "text presentation" and VS16
    /// "emoji presentation" are the ones a real document actually uses) or an Ideographic Variation
    /// Selector from the supplementary plane (U+E0100–U+E01EF, itself a surrogate pair) — `0` when no
    /// such character immediately follows. `substituteFont` below folds this into its cache key
    /// because it, unlike `coverage`, hands CoreText a REMAINDER rather than an isolated codepoint,
    /// and a variation selector right after the base is exactly the part of that remainder proven (by
    /// live probe, see `FontSubstitutionCache`'s file doc) to change CoreText's answer.
    private static func followingVariationSelector(afterWidth width: Int, from index: Int, in chars: [UniChar]) -> UInt32 {
        let next = index + width
        guard next < chars.count else { return 0 }
        if next + 1 < chars.count, UTF16.isLeadSurrogate(chars[next]), UTF16.isTrailSurrogate(chars[next + 1]) {
            let candidate = 0x10000 + (UInt32(chars[next]) - 0xD800) * 0x400 + (UInt32(chars[next + 1]) - 0xDC00)
            return (0xE0100...0xE01EF).contains(candidate) ? candidate : 0
        }
        let candidate = UInt32(chars[next])
        return (0xFE00...0xFE0F).contains(candidate) ? candidate : 0
    }

    /// The whole buffer decoded into (scalar, start-index, width) atoms, width 2 exactly where
    /// `scalar(at:in:)` consumed a real pair (its only values above 0xFFFF), 1 otherwise — mirrors
    /// the unmemoised `coverage(of:in:)`'s own pairing loop exactly, just restated in terms this
    /// cache's per-codepoint memo can key on.
    private static func codepoints(in chars: [UniChar]) -> [(scalar: UInt32, start: Int, width: Int)] {
        var out: [(UInt32, Int, Int)] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let s = scalar(at: i, in: chars)
            let width = s > 0xFFFF ? 2 : 1
            out.append((s, i, width))
            i += width
        }
        return out
    }

    /// `CTFontGetGlyphsForCharacters(font, chars)`, memoised per (font, CODEPOINT) for the lifetime
    /// of this cache. Only the codepoints THIS call has never seen under THIS font are actually sent
    /// to CoreText — batched together in ONE call, preserving the exact surrogate-pair grouping the
    /// unmemoised version required — so a span built entirely from characters already resolved
    /// elsewhere in this document costs ZERO CoreText calls, and a span with N novel characters costs
    /// exactly one call covering all N, never N separate calls.
    ///
    /// **Why per-character reuse is exact, not an approximation**: `CTFontGetGlyphsForCharacters` is
    /// a cmap lookup — glyph existence for ONE character under ONE font — with no dependency on
    /// neighbouring characters; the only context-sensitivity in the unmemoised function was surrogate
    /// pairing, which `scalar(at:in:)` preserves atom-for-atom. Testing a SUBSET of a span's
    /// characters in one call and testing the full span in another therefore must agree at every
    /// shared position — this cache never returns an answer CoreText did not itself already give for
    /// that literal (font, codepoint) pair earlier in this same read.
    func coverage(of font: NSFont, in chars: [UniChar]) -> [Bool] {
        guard !chars.isEmpty else { return [] }
        let fontKey = font.fontName
        let cps = Self.codepoints(in: chars)
        var covered = [Bool](repeating: false, count: chars.count)
        var missing: [Int] = []   // indices into `cps`
        for (i, cp) in cps.enumerated() {
            if let hit = coverageMemo[Key(fontKey: fontKey, scalar: cp.scalar)] {
                covered[cp.start] = hit
                if cp.width == 2 { covered[cp.start + 1] = hit }
            } else {
                missing.append(i)
            }
        }
        guard !missing.isEmpty else { return covered }

        var buffer: [UniChar] = []
        buffer.reserveCapacity(missing.count * 2)
        var offsets: [Int] = []
        offsets.reserveCapacity(missing.count)
        for i in missing {
            let cp = cps[i]
            offsets.append(buffer.count)
            buffer.append(chars[cp.start])
            if cp.width == 2 { buffer.append(chars[cp.start + 1]) }
        }
        var glyphs = [CGGlyph](repeating: 0, count: buffer.count)
        _ = CTFontGetGlyphsForCharacters(font as CTFont, buffer, &glyphs, buffer.count)
        coverageCoreTextCalls += 1
        for (n, i) in missing.enumerated() {
            let cp = cps[i]
            let isCovered = glyphs[offsets[n]] != 0
            coverageMemo[Key(fontKey: fontKey, scalar: cp.scalar)] = isCovered
            covered[cp.start] = isCovered
            if cp.width == 2 { covered[cp.start + 1] = isCovered }
        }
        return covered
    }

    /// `CTFontCreateForString(declared, source, CFRange(start, length-start))`, memoised per
    /// (declared font, the codepoint AT `start`, a variation selector immediately after it if any) —
    /// the question CoreText is actually being asked: "if a run needed a substitute starting HERE,
    /// what covers it?" On a cache HIT this issues ZERO CoreText calls, returning the exact same
    /// `NSFont` instance a previous span already resolved for this literal (font, leading character,
    /// following selector) triple — not a reconstruction from a saved descriptor (which would add a
    /// `NSFont(descriptor:size:)` round-trip this doesn't need), the SAME live object CoreText itself
    /// produced. See the type's own doc for why the leading character ALONE is not a safe key (a
    /// variation selector right after it changes CoreText's real answer) and why adding that one
    /// extra character back in is enough to make it safe again.
    func substituteFont(declared: NSFont, source: NSString, chars: [UniChar], at start: Int, length: Int) -> NSFont {
        let baseWidth = (start + 1 < chars.count && UTF16.isLeadSurrogate(chars[start])
                          && UTF16.isTrailSurrogate(chars[start + 1])) ? 2 : 1
        let vs = Self.followingVariationSelector(afterWidth: baseWidth, from: start, in: chars)
        let key = Key(fontKey: declared.fontName, scalar: Self.scalar(at: start, in: chars),
                      followingVariationSelector: vs)
        if let hit = substituteMemo[key] { return hit }
        let remainder = CFRange(location: start, length: length - start)
        let ctFont = CTFontCreateForString(declared as CTFont, source as CFString, remainder)
        substituteCoreTextCalls += 1
        let font = ctFont as NSFont
        substituteMemo[key] = font
        return font
    }
}

extension OfficeBlock {
    /// This block with its spans resolved through `FontSubstitutionResolver` — recurses into a
    /// table's cells, since a cell's content is the SAME format-neutral block vocabulary as the top
    /// of a document (see `Cell.blocks`'s doc). `.image`/`.unsupportedGraphic`/`.formula` carry no
    /// spans and pass through unchanged.
    ///
    /// `cache` defaults to a fresh, private `FontSubstitutionCache()` so a direct call (every
    /// existing test) behaves exactly as before. The real path — `OfficeReadResult.
    /// resolvingFontSubstitution()` — passes ONE cache down through every top-level block AND every
    /// table cell recursed into here, which is what makes the memo span the WHOLE document rather
    /// than just one block: a cell's spans see every declared-font/substitute answer already resolved
    /// anywhere else in the same document, not just within its own cell.
    func resolvingFontSubstitution(cache: FontSubstitutionCache = FontSubstitutionCache()) -> OfficeBlock {
        switch self {
        case let .heading(level, spans, rtl, alignment, tabStops, format):
            // `RenderTheme.headingFont` is `.systemFont(weight: .semibold)` regardless of level
            // (level only changes SIZE, never weight) — see `FontSubstitutionResolver.BlockWeight`.
            return .heading(level: level,
                             spans: FontSubstitutionResolver.resolve(spans, blockWeight: .semibold, cache: cache),
                             rtl: rtl, alignment: alignment, tabStops: tabStops, format: format)
        case let .paragraph(spans, rtl, alignment, tabStops, format):
            return .paragraph(spans: FontSubstitutionResolver.resolve(spans, cache: cache), rtl: rtl,
                               alignment: alignment, tabStops: tabStops, format: format)
        case let .listItem(level, ordered, spans, marker, rtl, alignment, tabStops, format):
            return .listItem(level: level, ordered: ordered,
                              spans: FontSubstitutionResolver.resolve(spans, cache: cache),
                              marker: marker, rtl: rtl, alignment: alignment, tabStops: tabStops, format: format)
        case let .table(rows, headerRows, columnWidths, format):
            let resolvedRows = rows.map { row in
                row.map { cell -> Cell in
                    var c = cell
                    c.blocks = c.blocks.map { $0.resolvingFontSubstitution(cache: cache) }
                    return c
                }
            }
            return .table(rows: resolvedRows, headerRows: headerRows, columnWidths: columnWidths, format: format)
        case .image, .unsupportedGraphic, .formula:
            return self
        }
    }
}

extension OfficeReadResult {
    /// The single point every reader's result flows through — called from `DocumentTypes.readOffice`
    /// (docx/odt/docm/dotx/dotm, ONE call site for all of them) and from `HwpReader.read` (HWP's own
    /// single dispatch, invariant 44) — so no caller of either can forget it, and neither reader
    /// re-implements the resolution logic itself.
    ///
    /// Constructs exactly ONE `FontSubstitutionCache` per call (the default parameter is evaluated
    /// once, here, not once per block) and threads that SAME instance through every block — this is
    /// the one line that actually gives the memo document-read scope rather than merely per-block
    /// scope: every existing call site (`DocumentTypes.swift`, `HwpReader.swift`) omits the argument
    /// and gets this for free, with no change to either call site.
    func resolvingFontSubstitution(cache: FontSubstitutionCache = FontSubstitutionCache()) -> OfficeReadResult {
        var copy = self
        copy.blocks = blocks.map { $0.resolvingFontSubstitution(cache: cache) }
        return copy
    }
}
