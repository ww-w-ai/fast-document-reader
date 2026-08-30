//! swift: Render/Office/FontSubstitutionResolver.swift
//! swift-range: 1-3

use std::collections::{HashMap, HashSet};
use swiftshim::SwiftString;

// swift: FontSubstitutionResolver
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
pub struct FontSubstitutionResolver;

impl FontSubstitutionResolver {
    /// Coverage/substitution does not depend on point size — "whatever covers 가 at 12pt covers it
    /// at 14pt" (design §1) — so this fixed size exists only to construct a real `NSFont` instance
    /// to query CoreText with; it is never seen on screen (`OfficeTextBuilder` always reconstructs
    /// the resolved name at the span's own authored/theme size).
    // swift: FontSubstitutionResolver.BlockWeight
    pub const PROBE_SIZE: f64 = 12.0;

    // swift: FontSubstitutionResolver.BlockWeight
    fn default_family_font() -> swiftshim::NSFont {
        swiftshim::NSFont::systemFont(Self::PROBE_SIZE)
    }
    fn code_family_font() -> swiftshim::NSFont {
        swiftshim::NSFont::monospacedSystemFont(Self::PROBE_SIZE, swiftshim::NSFontWeight::regular)
    }

    /// Adds symbolic traits while keeping the SAME family — used here only on PUBLIC, ordinary font
    /// families (the block's base weight and/or a `fontName` override) where trait-matching is
    /// reliable, never on an already-resolved private substitute descriptor (see `declaredFont`).
    // swift: FontSubstitutionResolver.fontAdding
    fn font_adding(traits: swiftshim::NSFontDescriptorSymbolicTraits, font: swiftshim::NSFont) -> swiftshim::NSFont {
        let d = font
            .fontDescriptor()
            .withSymbolicTraits(font.fontDescriptor().symbolicTraits().union(traits));
        swiftshim::NSFont::with_descriptor(&d, font.pointSize()).unwrap_or(font)
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
    // swift: FontSubstitutionResolver.isSampleEligible
    fn is_sample_eligible(scalar: char) -> bool {
        let value = scalar as u32;
        if (0xE000..=0xF8FF).contains(&value)
            || (0xF0000..=0xFFFFD).contains(&value)
            || (0x100000..=0x10FFFD).contains(&value)
        {
            return false;
        }
        !crate::render::office::script::unicode_script::UnicodeScript::of(scalar).is_absorbing()
    }

    /// CoreText's way of saying it has nothing: the font that draws every codepoint as a box. It is
    /// the ABSENCE of a substitute, not a substitute, so accepting it would paint a whole span's
    /// worth of otherwise-drawable text as boxes. Belt to the PUA exclusion's braces — that removes
    /// the one case measured to reach here, this refuses the answer itself, so an unsupported script
    /// nobody has anticipated cannot do the same thing from a direction nobody listed.
    const NO_SUBSTITUTE_FONT_NAME: &'static str = "LastResort";

    /// The most common eligible character, ties broken by the LOWER codepoint. The tie-break is not
    /// cosmetic: a `Dictionary`'s iteration order is per-process hash-randomised, so "whichever
    /// maximum I met first" would let the same document resolve to a different face on a different
    /// launch — the exact fault invariant 50 records having shipped once already, from a different
    /// direction.
    // swift: FontSubstitutionResolver.sampleCharacter
    fn sample_character(histogram: &HashMap<u32, i64>) -> Option<u32> {
        let mut best: Option<(u32, i64)> = None;
        for (&scalar, &count) in histogram {
            if let Some(b) = best {
                if count < b.1 || (count == b.1 && scalar > b.0) {
                    continue;
                }
            }
            best = Some((scalar, count));
        }
        best.map(|b| b.0)
    }

    /// The whole decision for one document: census every span, then ask CoreText once per declared
    /// font. Nothing is written to any span here — the plan is a value the apply pass reads.
    // swift: FontSubstitutionResolver.plan
    pub fn plan(
        blocks: &[crate::render::office::office_block::OfficeBlock],
        cache: &FontSubstitutionCache,
        declared_faces: &HashMap<String, crate::render::office::declared_font_kind::DeclaredFace>,
    ) -> FontSubstitutionPlan {
        let mut histograms: HashMap<DeclaredFontKey, HashMap<u32, i64>> = HashMap::new();
        Self::census(blocks, BlockWeight::Regular, &mut histograms);
        Self::decide(&histograms, cache, declared_faces)
    }

    /// One question per declared font, and the only place CoreText is consulted.
    // swift: FontSubstitutionResolver.decide
    fn decide(
        histograms: &HashMap<DeclaredFontKey, HashMap<u32, i64>>,
        cache: &FontSubstitutionCache,
        declared_faces: &HashMap<String, crate::render::office::declared_font_kind::DeclaredFace>,
    ) -> FontSubstitutionPlan {
        let mut substitutes: HashMap<DeclaredFontKey, Substitute> = HashMap::new();
        for (key, histogram) in histograms {
            let Some(sample) = Self::sample_character(histogram) else { continue };
            let (declared, is_stand_in) = Self::declared_font(key, cache, declared_faces);
            // THE GATE. Not "is the declared family installed?" — Times New Roman, Arial, Helvetica
            // and Georgia are all installed here and none of them draws Hangul, so an availability
            // test passes a Korean `.docx` (Word writes Times New Roman into the ascii slot by
            // default) straight through to AppKit's per-character fixing. Ask whether the declared
            // font draws THIS DOCUMENT's own characters instead, and that cliff cannot exist.
            // A STAND-IN has to be recorded even when it covers, and this is the one thing about the
            // shape of this pass that the chain changed. `OfficeTextBuilder` reaches a span's family
            // by calling `NSFont(name: span.fontName())` itself (`:425`) — which returns nil for exactly
            // the unresolvable families the chain exists for — so `resolvedFontDescriptor` is the ONLY
            // channel a stand-in can travel down. Leaving it unset because the stand-in happened to
            // draw the sample would decide the right face and then throw it away.
            if cache.covers(&declared, sample) {
                if is_stand_in {
                    substitutes.insert(key.clone(), Substitute { sample, descriptor: declared.fontDescriptor() });
                }
                continue;
            }
            let substitute = cache.substitute_font(&declared, sample);
            if substitute.fontName() == Self::NO_SUBSTITUTE_FONT_NAME {
                continue;
            }
            substitutes.insert(key.clone(), Substitute { sample, descriptor: substitute.fontDescriptor() });
        }
        FontSubstitutionPlan { substitutes }
    }

    /// Recursive read-only walk — a table's cells hold the same block vocabulary as the top of a
    /// document, and a heading's spans start from a different weight, which is the one piece of
    /// block context the key needs.
    // swift: FontSubstitutionResolver.census
    fn census(
        blocks: &[crate::render::office::office_block::OfficeBlock],
        block_weight: BlockWeight,
        histograms: &mut HashMap<DeclaredFontKey, HashMap<u32, i64>>,
    ) {
        use crate::render::office::office_block::OfficeBlock;
        for block in blocks {
            match block {
                OfficeBlock::Heading { spans, .. } => {
                    Self::tally(spans, BlockWeight::Semibold, histograms);
                }
                OfficeBlock::Paragraph { spans, .. } | OfficeBlock::ListItem { spans, .. } => {
                    Self::tally(spans, block_weight, histograms);
                }
                OfficeBlock::Table { rows, .. } => {
                    for row in rows {
                        for cell in row {
                            Self::census(&cell.blocks, block_weight, histograms);
                        }
                    }
                }
                OfficeBlock::Image { .. } | OfficeBlock::UnsupportedGraphic { .. } | OfficeBlock::Formula { .. } => continue,
            }
        }
    }

    // swift: FontSubstitutionResolver.tally
    fn tally(
        spans: &[crate::render::office::office_block::Span],
        block_weight: BlockWeight,
        histograms: &mut HashMap<DeclaredFontKey, HashMap<u32, i64>>,
    ) {
        for span in spans {
            if span.text.is_empty() {
                continue;
            }
            let key = DeclaredFontKey::new(span, block_weight);
            for scalar in span.text.chars() {
                if Self::is_sample_eligible(scalar) {
                    *histograms.entry(key.clone()).or_default().entry(scalar as u32).or_insert(0) += 1;
                }
            }
        }
    }

    // MARK: - Phase 2, applying it

    /// A span whose declared font needs no substitute comes back as the EXACT SAME `Span` value —
    /// not a copy that merely leaves `resolvedFontDescriptor` `nil` — which is the byte-identical
    /// guard invariant 37 depends on: nothing downstream can tell it apart from a span this pass
    /// never touched, because there is no difference to tell.
    // swift: FontSubstitutionResolver.resolve
    pub fn resolve(
        spans: &[crate::render::office::office_block::Span],
        block_weight: BlockWeight,
        plan: &FontSubstitutionPlan,
    ) -> Vec<crate::render::office::office_block::Span> {
        if plan.is_empty() {
            return spans.to_vec();
        }
        spans
            .iter()
            .map(|span| {
                if span.text.is_empty() {
                    return span.clone();
                }
                let key = DeclaredFontKey::new(span, block_weight);
                let Some(substitute) = plan.substitutes.get(&key) else { return span.clone() };
                let mut out = span.clone();
                out.resolved_font_descriptor = Some(substitute.descriptor.clone());
                out
            })
            .collect()
    }

    /// Survey and apply in one call, over just these spans — the shape a caller resolving one block
    /// in isolation (every direct unit test) wants. The production path plans over the WHOLE
    /// document first, which is the point: a font's representative is chosen from everything the
    /// document draws in it, not from one paragraph's worth.
    // swift: FontSubstitutionResolver.resolve
    pub fn resolve_with_cache(
        spans: &[crate::render::office::office_block::Span],
        block_weight: BlockWeight,
        cache: &FontSubstitutionCache,
    ) -> Vec<crate::render::office::office_block::Span> {
        let mut histograms: HashMap<DeclaredFontKey, HashMap<u32, i64>> = HashMap::new();
        Self::tally(spans, block_weight, &mut histograms);
        let plan = Self::decide(&histograms, cache, &HashMap::new());
        Self::resolve(spans, block_weight, &plan)
    }

    /// The same rule for a string that was never built from `Span`s — markdown and plain text, whose
    /// fonts come from the theme rather than from any document declaration.
    ///
    /// **What these two paths were missing, and it is the whole per-script layer.** An office reader
    /// names the document's OWN face PER SCRIPT (invariant 53 — HWP carries seven slots, docx four,
    /// ODF three, and 53.6% of real HWPs genuinely declare different fonts across them). The theme
    /// declares one font for everything, it has no Hangul, and AppKit then fixes the string per
    /// CHARACTER: Hangul lands on `AppleSDGothicNeo` while every space, digit and newline between the
    /// words stays on the system font, so a run is cut at nearly every word. Measured on a generated
    /// Korean markdown document: **246,900 font runs across 370k characters, one every 1.5**, against
    /// 8,215 on a Korean HWP of comparable size that came through the office path.
    ///
    /// So this gives those paths the same per-script slots the formats have, decided the same way
    /// invariant 52 decides an office document's: **once per (declared font, script)** — never per
    /// character and never per run — on the most common character that font actually draws in that
    /// script, and only where the declared font does NOT already draw it. A theme font that draws
    /// Latin keeps the Latin, which is the point of slots rather than one blanket substitution: it is
    /// what lets English in a Korean document stay in the face the theme chose for it.
    ///
    /// Runs are then split by `ScriptRunSplitter`, which is load-bearing for the same reason it is in
    /// the office path: **a character with no script of its own joins the run in progress instead of
    /// starting one.** Without that the spaces alone are 42% of the runs on a mixed Korean/English
    /// document (measured), which is the very fragmentation this exists to remove.
    ///
    /// Returns how many ranges were restamped — the deterministic number a test asserts on.
    // swift: FontSubstitutionResolver.applySubstitutions
    pub fn apply_substitutions(string: &mut swiftshim::NSMutableAttributedString, cache: &FontSubstitutionCache) -> i64 {
        if string.length() <= 0 {
            return 0;
        }
        let whole = swiftshim::NSRange { location: 0, length: string.length() };
        let text = SwiftString::new(string.string());

        // swift: FontSubstitutionResolver.SlotKey
        #[derive(Hash, PartialEq, Eq, Clone)]
        struct SlotKey {
            font: String,
            script: crate::render::office::script::unicode_script::ScriptClass,
        }
        // swift: FontSubstitutionResolver.fontKey
        // Keyed on the font as a VALUE (face + size), not as an object: a theme hands out
        // equal-but-distinct instances, and keying on identity would ask the same question once per
        // run instead of once per face.
        fn font_key(font: &swiftshim::NSFont) -> String {
            format!("{}|{}", font.fontName(), font.pointSize())
        }
        // swift: `value as? NSFont` — pulling an `NSFont` back out of the attribute-value union.
        // No such downcast exists on `swiftshim::AttrValue` (an enum, not `Any`), so it is matched
        // out locally rather than widening the shim for this one call site.
        fn value_as_font(value: Option<&swiftshim::AttrValue>) -> Option<swiftshim::NSFont> {
            match value {
                Some(swiftshim::AttrValue::Font(f)) => Some(f.clone()),
                _ => None,
            }
        }

        let mut histograms: HashMap<SlotKey, HashMap<u32, i64>> = HashMap::new();
        let mut declared_fonts: HashMap<String, swiftshim::NSFont> = HashMap::new();
        string.asAttributedString().enumerateAttribute(&swiftshim::NSAttributedStringKey::Font, whole, |value, range, _stop| {
            let Some(font) = value_as_font(value) else { return };
            let key = font_key(&font);
            declared_fonts.insert(key.clone(), font);
            for scalar in text.substring(range).chars() {
                if Self::is_sample_eligible(scalar) {
                    let slot = SlotKey {
                        font: key.clone(),
                        script: crate::render::office::script::unicode_script::UnicodeScript::of(scalar),
                    };
                    *histograms.entry(slot).or_default().entry(scalar as u32).or_insert(0) += 1;
                }
            }
        });

        let mut substitutes: HashMap<SlotKey, swiftshim::NSFont> = HashMap::new();
        let mut by_family: HashMap<String, swiftshim::NSFont> = HashMap::new();
        for (key, histogram) in &histograms {
            let (Some(sample), Some(declared)) =
                (Self::sample_character(histogram), declared_fonts.get(&key.font))
            else {
                continue;
            };
            if cache.covers(declared, sample) {
                continue;
            }
            let substitute = cache.substitute_font(declared, sample);
            if substitute.fontName() == Self::NO_SUBSTITUTE_FONT_NAME {
                continue;
            }
            // SIZED to the font it replaces, and grouped by face AND size. This path hands the
            // resolved `NSFont` straight to the storage — unlike `OfficeTextBuilder`, which rebuilds
            // the resolved NAME at the span's own authored size and so cannot be wrong about this —
            // and two things upstream answer by face name alone: `substituteFont`'s memo is keyed on
            // the declared face without its size, and this map used to be too. A theme's H1, H2 and
            // table header are one face (`.systemFont(weight: .semibold)`) at three sizes, so both
            // collapsed them onto whichever size happened to be resolved first.
            let sized = swiftshim::NSFont::with_descriptor(&substitute.fontDescriptor(), declared.pointSize())
                .unwrap_or(substitute);
            by_family.insert(font_key(&sized), sized.clone());
            substitutes.insert(key.clone(), sized);
        }
        if substitutes.is_empty() {
            return 0;
        }

        // Collected first, applied after: mutating the attributes being enumerated is undefined.
        let mut edits: Vec<(swiftshim::NSRange, swiftshim::NSFont)> = Vec::new();
        string.asAttributedString().enumerateAttribute(&swiftshim::NSAttributedStringKey::Font, whole, |value, range, _stop| {
            let Some(font) = value_as_font(value) else { return };
            let key = font_key(&font);
            if !substitutes.keys().any(|k| k.font == key) {
                return;
            }
            let piece = text.substring(range);
            let mut offset = range.location;
            for part in crate::render::office::script::script_run_splitter::ScriptRunSplitter::split(
                &piece,
                |scalar| {
                    let script = crate::render::office::script::unicode_script::UnicodeScript::of(scalar);
                    if script.is_absorbing() { None } else { Some(script) }
                },
                // The DECLARED family for a script this font
                // already draws — never `nil`. `nil` means "the
                // document said nothing", which tells the splitter
                // not to break at all; here "no substitute" is the
                // opposite, a positive statement that the theme font
                // draws this script, and it must break so the Latin
                // keeps the face the theme chose for it.
                |script| {
                    Some(
                        substitutes
                            .get(&SlotKey { font: key.clone(), script })
                            .map(font_key)
                            .unwrap_or_else(|| font_key(&font)),
                    )
                },
            ) {
                let length = part.text.encode_utf16().count();
                if let Some(family) = part.family {
                    if let Some(substitute) = by_family.get(&family) {
                        edits.push((swiftshim::NSRange { location: offset, length }, substitute.clone()));
                    }
                }
                offset += length;
            }
        });
        for (range, font) in &edits {
            string.addAttribute(
                swiftshim::NSAttributedStringKey::Font,
                swiftshim::AttrValue::Font(font.clone()),
                *range,
            );
        }
        edits.len() as i64
    }
}

// swift: FontSubstitutionResolver.BlockWeight
/// The WEIGHT `OfficeTextBuilder` starts a block's spans from, BEFORE any span-level bold/italic
/// — `RenderTheme.headingFont` is `.systemFont(weight: .semibold)`, `.bodyFont`/list items are
/// plain `.systemFont`. It is threaded in by `OfficeBlock.applyingFontSubstitution` from the
/// block type it already has in hand, because it genuinely changes which face CoreText
/// substitutes (see `declaredFont`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BlockWeight {
    Regular,
    Semibold,
}

impl BlockWeight {
    fn probe_font(&self) -> swiftshim::NSFont {
        match self {
            BlockWeight::Regular => FontSubstitutionResolver::default_family_font(),
            BlockWeight::Semibold => swiftshim::NSFont::systemFontWeight(
                FontSubstitutionResolver::PROBE_SIZE,
                swiftshim::NSFontWeight::semibold,
            ),
        }
    }
}

// swift: FontSubstitutionResolver.DeclaredFontKey
/// Everything `declaredFont` varies on — a PURE function of these five values. This is also the
/// unit "one representative per DECLARED FONT" counts in: two spans sharing a key are asking
/// CoreText the identical question, so they get the identical answer by construction rather
/// than by coincidence. Bold and italic are part of the key deliberately: CoreText's cascade
/// picks a DIFFERENT face per weight (a Korean character resolves to `.AppleSDGothicNeoI-Regular`
/// under `.systemFont(12)` and `-Bold` under the same font with `.bold` added), so folding
/// weights together is exactly how a bold Korean heading ends up drawn regular.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DeclaredFontKey {
    pub code: bool,
    pub font_name: Option<String>,
    pub block_weight: BlockWeight,
    pub bold: bool,
    pub italic: bool,
}

impl DeclaredFontKey {
    pub fn new(span: &crate::render::office::office_block::Span, block_weight: BlockWeight) -> Self {
        DeclaredFontKey {
            code: span.code,
            font_name: span.font_name.as_ref().map(|s| s.to_string()),
            block_weight,
            bold: span.bold,
            italic: span.italic,
        }
    }
}

impl FontSubstitutionResolver {
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
    // swift: FontSubstitutionResolver.declaredFont
    fn declared_font(
        key: &DeclaredFontKey,
        cache: &FontSubstitutionCache,
        declared_faces: &HashMap<String, crate::render::office::declared_font_kind::DeclaredFace>,
    ) -> (swiftshim::NSFont, bool) {
        if let Some(cached) = cache.declared_font_memo_get(key) {
            return (cached.clone(), cache.stand_in_keys_contains(key));
        }
        let mut font: swiftshim::NSFont;
        let mut is_stand_in = false;
        if key.code {
            font = Self::code_family_font();
        } else if let Some(name) = &key.font_name {
            if let Some(named) = swiftshim::NSFont::named(name, Self::PROBE_SIZE) {
                font = named;
            } else if let Some(substitute) = Self::stand_in(name, declared_faces) {
                font = substitute;
                is_stand_in = true;
            } else {
                font = key.block_weight.probe_font();
            }
        } else {
            font = key.block_weight.probe_font();
        }
        let mut traits = swiftshim::NSFontDescriptorSymbolicTraits::empty();
        if key.bold {
            traits.insert(swiftshim::NSFontDescriptorSymbolicTraits::bold);
        }
        if key.italic {
            traits.insert(swiftshim::NSFontDescriptorSymbolicTraits::italic);
        }
        if !traits.isEmpty() {
            font = Self::font_adding(traits, font);
        }
        cache.declared_font_memo_set(key.clone(), font.clone());
        if is_stand_in {
            cache.stand_in_keys_insert(key.clone());
        }
        (font, is_stand_in)
    }

    /// What stands in for a declared family this machine cannot resolve — the ONE thing that changes
    /// about the declared font, and the reason a 명조 document stopped coming out in a sans face.
    ///
    /// **What this does NOT do is choose a substitute.** Everything downstream is untouched: whatever
    /// comes back here still goes through the same `covers()` test and, failing that, the same
    /// `substituteFont()` cascade the app has always run. CoreText still overrules a candidate that
    /// cannot draw the document's characters, exactly as it overrules the app's own base font today.
    /// What changes is only the quality of the starting point — a face of the kind the document asked
    /// for, instead of the font this reader would have used if the document had said nothing.
    ///
    /// The order is by how DIRECTLY the document said it:
    ///
    ///   1. a face the document NOMINATED as its own substitute
    ///   2. a KIND the document DECLARED, in its font table's type-info block (PANOSE)
    ///   3. a kind the declared NAME states, read from its morphemes (`DeclaredFontKind`)
    ///
    /// and if none of those produces a resolvable face, the caller falls back to what it does now.
    /// Only step 3 is this reader inferring anything, and it is the last one asked.
    ///
    /// Costs nothing per span: `declaredFont` is memoised per `DeclaredFontKey`, so this runs once per
    /// DISTINCT declared font in the document and never again — not per span, not per ⌘+/⌘− press.
    // swift: FontSubstitutionResolver.standIn
    fn stand_in(
        name: &str,
        declared_faces: &HashMap<String, crate::render::office::declared_font_kind::DeclaredFace>,
    ) -> Option<swiftshim::NSFont> {
        let face = declared_faces.get(name);
        if let Some(nominated) = face.and_then(|f| f.nominated_substitute.as_ref()) {
            if let Some(font) = swiftshim::NSFont::named(nominated, Self::PROBE_SIZE) {
                return Some(font);
            }
        }
        // A kind the document DECLARED is an ANSWER, including when the answer is "nothing suits this".
        // A document calling its face decorative or symbolic has spoken; falling through to our own
        // name rules there would let this reader overrule it with an inference, which is the one thing
        // the order exists to prevent. Only silence from the document reaches the rules below.
        if let Some(declared) = face.and_then(|f| f.declared_kind()) {
            let family = declared.system_family()?;
            return swiftshim::NSFont::named(family, Self::PROBE_SIZE);
        }
        if let Some(family) = crate::render::office::declared_font_kind::DeclaredFontKind::fallback_family(name) {
            return swiftshim::NSFont::named(family, Self::PROBE_SIZE);
        }
        None
    }
}

// swift: FontSubstitutionPlan
/// One document's whole substitution decision: for each distinct declared font, the ONE descriptor
/// every span carrying that font is drawn with. A separate value rather than state inside the cache
/// so that applying without surveying is not expressible — an apply pass silently running against
/// an empty plan would look exactly like a document that needed no substitutes.
pub struct FontSubstitutionPlan {
    substitutes: HashMap<DeclaredFontKey, Substitute>,
}

/// The sample is carried alongside the descriptor because the run count alone cannot say WHY a
/// document moved — which declared font was replaced, and on the evidence of which character.
/// A reviewer reading "5,177 characters left Times New Roman" needs to see the character that
/// decided it, and a probe that can only report totals cannot show them.
// swift: FontSubstitutionPlan.Substitute
#[derive(Clone)]
pub struct Substitute {
    pub sample: u32,
    pub descriptor: swiftshim::NSFontDescriptor,
}

impl FontSubstitutionPlan {
    /// Empty means "every declared font in this document draws its own text" — the byte-identical
    /// case, and the one the apply pass short-circuits.
    // swift-range: Render/Office/FontSubstitutionResolver.swift:445-480
    pub fn is_empty(&self) -> bool {
        self.substitutes.is_empty()
    }
    /// How many distinct declared fonts got a substitute. The deterministic number a test asserts
    /// on, in preference to a wall clock this machine has been measured swinging up to 11×.
    pub fn substituted_font_count(&self) -> usize {
        self.substitutes.len()
    }

    /// One human-readable line per substituted declared font, sorted so two runs of the same
    /// document print identically.
    pub fn described_entries(&self) -> Vec<String> {
        let mut out: Vec<String> = self
            .substitutes
            .iter()
            .map(|(key, value)| {
                let sample = char::from_u32(value.sample)
                    .map(|c| format!("U+{:X} '{}'", value.sample, c))
                    .unwrap_or_else(|| format!("U+{:X}", value.sample));
                let traits: Vec<&str> = [
                    key.bold.then_some("bold"),
                    key.italic.then_some("italic"),
                    key.code.then_some("code"),
                    (key.block_weight == BlockWeight::Semibold).then_some("heading"),
                ]
                .into_iter()
                .flatten()
                .collect();
                let traits_str = traits.join("+");
                format!(
                    "{}{} — sample {} → {}",
                    key.font_name.as_deref().unwrap_or("<theme>"),
                    if traits_str.is_empty() { String::new() } else { format!(" [{}]", traits_str) },
                    sample,
                    // BLOCKED ON SHIM: `NSFontDescriptor.postscript_name()` has no member in
                    // swiftshim's `color_font.rs` (only `.symbolicTraits()`/`addingAttributes`/
                    // `withSymbolicTraits` exist there) — this debug-only description string
                    // stands in "?" until the shim grows it, reported to b-shim.
                    "?"
                )
            })
            .collect();
        out.sort();
        out
    }
}

// swift: FontSubstitutionCache
/// A memo scoped to EXACTLY ONE document read — created fresh by `OfficeReadResult.
/// resolvingFontSubstitution()` and never referenced again once it returns. Under the
/// one-representative-per-declared-font design its job is small and exact: the survey asks CoreText
/// at most twice per distinct declared font (does it cover the sample; if not, what does), and this
/// memo collapses the fonts that share an answer — five CoreText round-trips for the whole reference
/// HWP, against 2,209 under the previous per-span shape.
///
/// **The key, and why it cannot collide:** `(font identity, Unicode codepoint)`, where font identity
/// is `NSFont.fontName()` — the PostScript name — read off the font AFTER traits are unioned in, so
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
pub struct FontSubstitutionCache {
    // swift-range: Render/Office/FontSubstitutionResolver.swift:504-508
    // (Key struct folded into the coverage/substitute memo maps below.)
    declared_font_memo: std::cell::RefCell<HashMap<DeclaredFontKey, swiftshim::NSFont>>,
    /// Which memoised entries came from the fallback CHAIN rather than from the declared name itself.
    /// Kept beside the memo rather than folded into it so a cache hit answers both questions without
    /// re-walking anything.
    // swift-range: Render/Office/FontSubstitutionResolver.swift:509-515
    stand_in_keys: std::cell::RefCell<HashSet<DeclaredFontKey>>,
    coverage_memo: std::cell::RefCell<HashMap<(String, u32), bool>>,
    substitute_memo: std::cell::RefCell<HashMap<(String, u32), swiftshim::NSFont>>,

    /// Every real `CTFontGetGlyphsForCharacters` call this cache issues.
    // swift-range: Render/Office/FontSubstitutionResolver.swift:516-517
    coverage_core_text_calls: std::cell::Cell<i64>,
    /// Every real `CTFontCreateForString` call.
    // swift-range: Render/Office/FontSubstitutionResolver.swift:518-523
    substitute_core_text_calls: std::cell::Cell<i64>,
}

impl Default for FontSubstitutionCache {
    fn default() -> Self {
        FontSubstitutionCache {
            declared_font_memo: std::cell::RefCell::new(HashMap::new()),
            stand_in_keys: std::cell::RefCell::new(HashSet::new()),
            coverage_memo: std::cell::RefCell::new(HashMap::new()),
            substitute_memo: std::cell::RefCell::new(HashMap::new()),
            coverage_core_text_calls: std::cell::Cell::new(0),
            substitute_core_text_calls: std::cell::Cell::new(0),
        }
    }
}

impl FontSubstitutionCache {
    fn declared_font_memo_get(&self, key: &DeclaredFontKey) -> Option<swiftshim::NSFont> {
        self.declared_font_memo.borrow().get(key).cloned()
    }
    fn declared_font_memo_set(&self, key: DeclaredFontKey, font: swiftshim::NSFont) {
        self.declared_font_memo.borrow_mut().insert(key, font);
    }
    fn stand_in_keys_contains(&self, key: &DeclaredFontKey) -> bool {
        self.stand_in_keys.borrow().contains(key)
    }
    fn stand_in_keys_insert(&self, key: DeclaredFontKey) {
        self.stand_in_keys.borrow_mut().insert(key);
    }

    /// The deterministic knob this pass is judged by, mirroring invariant 49's `layoutStepCount`
    /// idiom: count CoreText round-trips, not wall clock.
    // swift: FontSubstitutionCache.covers
    pub fn core_text_call_count(&self) -> i64 {
        self.coverage_core_text_calls.get() + self.substitute_core_text_calls.get()
    }

    /// Does `font` have a glyph for this one character? A cmap lookup, memoised per (font, scalar).
    /// Tested on `glyphs[0]` rather than the function's own return value because a non-BMP scalar is
    /// two UTF-16 units and CoreText reports the trailing half as unmapped even when the pair
    /// resolved — the same reading the pre-memo code used.
    // swift: FontSubstitutionCache.covers
    pub fn covers(&self, font: &swiftshim::NSFont, scalar: u32) -> bool {
        let key = (font.fontName(), scalar);
        if let Some(hit) = self.coverage_memo.borrow().get(&key) {
            return *hit;
        }
        // A cmap lookup asks the font system whether this face can draw this character. The engine
        // cannot answer it — that is the whole reason `font_provider` is a port — so it asks, using
        // the face id the descriptor was issued.
        let covered: bool = match font.fontDescriptor().baseFace() {
            Some(face) => swiftshim::font_provider::provider().covers(face, scalar),
            // A font with no issued face is one this process never resolved, so there is nothing to
            // ask about. Reporting "covered" keeps the declared face rather than substituting on a
            // question that was never answered — the Swift's own posture when the lookup cannot run.
            None => true,
        };
        self.coverage_core_text_calls.set(self.coverage_core_text_calls.get() + 1);
        self.coverage_memo.borrow_mut().insert(key, covered);
        covered
    }

    /// What CoreText itself would substitute for this one character when `declared` cannot draw it —
    /// `CTFontCreateForString` over a string holding exactly that character, memoised per
    /// (declared font, scalar). On a hit this issues zero CoreText calls and returns the SAME live
    /// object CoreText produced, not a reconstruction from a saved descriptor.
    // swift: FontSubstitutionCache.substituteFont
    pub fn substitute_font(&self, declared: &swiftshim::NSFont, scalar: u32) -> swiftshim::NSFont {
        let key = (declared.fontName(), scalar);
        if let Some(hit) = self.substitute_memo.borrow().get(&key) {
            return hit.clone();
        }
        let Some(_unicode) = char::from_u32(scalar) else { return declared.clone() };
        // Asks the font system what IT would substitute — not a list held here. The substitution
        // cascade is the platform's, and reproducing this build means asking it.
        let Some(declared_face) = declared.fontDescriptor().baseFace() else { return declared.clone() };
        let font: swiftshim::NSFont = match swiftshim::font_provider::provider()
            .substitute(declared_face, scalar)
        {
            // The system offered nothing, so the declared face stands — substituting to some other
            // face here would be this engine inventing a cascade rather than reproducing one.
            None => declared.clone(),
            Some(face) => swiftshim::NSFont::fromFace(face, declared.pointSize()),
        };
        self.substitute_core_text_calls.set(self.substitute_core_text_calls.get() + 1);
        self.substitute_memo.borrow_mut().insert(key, font.clone());
        font
    }
}

impl crate::render::office::office_block::OfficeBlock {
    /// This block with its spans drawn through `plan` — recurses into a table's cells, since a
    /// cell's content is the SAME format-neutral block vocabulary as the top of a document.
    /// `.image`/`.unsupportedGraphic`/`.formula` carry no spans and pass through unchanged.
    // swift: OfficeBlock.applyingFontSubstitution
    pub fn applying_font_substitution(&self, plan: &FontSubstitutionPlan) -> Self {
        use crate::render::office::office_block::OfficeBlock;
        match self {
            // `RenderTheme.headingFont` is `.systemFont(weight: .semibold)` regardless of level
            // (level only changes SIZE, never weight) — see `FontSubstitutionResolver.BlockWeight`.
            OfficeBlock::Heading { level, spans, rtl, alignment, tab_stops, format, .. } => OfficeBlock::Heading {
                level: *level,
                spans: FontSubstitutionResolver::resolve(spans, BlockWeight::Semibold, plan),
                rtl: *rtl,
                alignment: alignment.clone(),
                tab_stops: tab_stops.clone(),
                format: format.clone(),
                format_ref: None,
            },
            OfficeBlock::Paragraph { spans, rtl, alignment, tab_stops, format, .. } => OfficeBlock::Paragraph {
                spans: FontSubstitutionResolver::resolve(spans, BlockWeight::Regular, plan),
                rtl: *rtl,
                alignment: alignment.clone(),
                tab_stops: tab_stops.clone(),
                format: format.clone(),
                format_ref: None,
            },
            OfficeBlock::ListItem { level, ordered, spans, marker, rtl, alignment, tab_stops, format, numbering, .. } => {
                OfficeBlock::ListItem {
                    level: *level,
                    ordered: *ordered,
                    spans: FontSubstitutionResolver::resolve(spans, BlockWeight::Regular, plan),
                    marker: marker.clone(),
                    rtl: *rtl,
                    alignment: alignment.clone(),
                    tab_stops: tab_stops.clone(),
                    format: format.clone(),
                    format_ref: None,
                    numbering: numbering.clone(),
                }
            }
            OfficeBlock::Table { rows, header_rows, column_widths, format } => {
                let resolved_rows: Vec<_> = rows
                    .iter()
                    .map(|row| {
                        row.iter()
                            .map(|cell| {
                                let mut c = cell.clone();
                                c.blocks = c.blocks.iter().map(|b| b.applying_font_substitution(plan)).collect();
                                c
                            })
                            .collect()
                    })
                    .collect();
                OfficeBlock::Table {
                    rows: resolved_rows,
                    header_rows: *header_rows,
                    column_widths: column_widths.clone(),
                    format: format.clone(),
                }
            }
            OfficeBlock::Image { .. } | OfficeBlock::UnsupportedGraphic { .. } | OfficeBlock::Formula { .. } => self.clone(),
        }
    }

    /// Survey and apply over just this block — the shape a direct unit test wants; the production
    /// path surveys the whole document (see `OfficeReadResult.resolvingFontSubstitution`).
    // swift: OfficeBlock.resolvingFontSubstitution
    pub fn resolving_font_substitution(&self, cache: &FontSubstitutionCache) -> Self {
        let plan = FontSubstitutionResolver::plan(std::slice::from_ref(self), cache, &HashMap::new());
        self.applying_font_substitution(&plan)
    }
}

/// swift: `Dictionary` keyed by `String` — `OfficeReadResult.declared_faces` is keyed by
/// `swiftshim::SwiftString` (convention §3's `NSString`/`String` stand-in), but `declared_font`'s
/// lookups below compare against `DeclaredFontKey.font_name: Option<String>`, so the map is
/// re-keyed by plain `String` at the one boundary that needs it rather than threading `SwiftString`
/// through every lookup in this file.
fn restring_declared_faces(
    faces: &HashMap<SwiftString, crate::render::office::declared_font_kind::DeclaredFace>,
) -> HashMap<String, crate::render::office::declared_font_kind::DeclaredFace> {
    faces.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

// swift: OfficeReadResult.resolvingFontSubstitution
impl crate::render::office::office_block::OfficeReadResult {
    /// The single point every reader's result flows through — called from `DocumentTypes.readOffice`
    /// (docx/odt/docm/dotx/dotm, ONE call site for all of them) and from `HwpReader.read` (HWP's own
    /// single dispatch, invariant 44) — so no caller of either can forget it, and neither reader
    /// re-implements the resolution itself.
    ///
    /// Two passes over the blocks, in this order and never merged: the survey has to have seen the
    /// WHOLE document before the first span is written, because "the most common character under
    /// this declared font" is a fact about the document, not about whichever paragraph happened to
    /// be reached first.
    // swift: OfficeReadResult.resolvingFontSubstitution
    pub fn resolving_font_substitution(&self, cache: &FontSubstitutionCache) -> Self {
        let declared_faces = restring_declared_faces(&self.declared_faces);
        let plan = FontSubstitutionResolver::plan(&self.blocks, cache, &declared_faces);
        let mut copy = self.clone();
        copy.blocks = self.blocks.iter().map(|b| b.applying_font_substitution(&plan)).collect();
        copy
    }
}
