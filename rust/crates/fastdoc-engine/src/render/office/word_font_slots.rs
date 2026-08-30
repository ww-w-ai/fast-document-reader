//! swift: Render/Office/WordFontSlots.swift
//! swift-range: 1-15
//!
//! Word's own four-slot font vocabulary, its per-character slot table, and its theme font scheme —
//! the parts of `w:rFonts` resolution that are pure data and pure decision, with no XML and no
//! archive in sight, so every rule below is unit-testable on its own terms. `DocxReader` owns the
//! other half: reading these out of `word/styles.xml`/`word/theme/theme1.xml` and cascading them.
//!
//! ## Why Word needs its OWN table rather than the shared script classifier
//!
//! `UnicodeScript`/`ScriptClass` answer "which writing system is this scalar", which is what HWP's
//! seven slots and ODF's Table 22 are keyed on. Word is keyed on something else: MS-OI29500
//! §17.3.2.26 classifies by Unicode **block**, and the two disagree loudly. Hebrew, Arabic, Syriac,
//! Thaana and both Arabic Presentation Forms blocks are classified **ascii** — the slot whose own
//! name says "0–127" — across six separate rows, which no script-derived rule would ever produce.
//! Thai, Devanagari and every other Indic block are absent from the table entirely and therefore
//! fall to the catch-all **hAnsi**. Driving Word from script identities would mis-render all of
//! them, so the table is transcribed here instead, row by row, and can be checked against the spec.

// swift: Render/Office/WordFontSlots.swift:1-26
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WordFontSlot {
    Ascii,
    HAnsi,
    EastAsia,
    /// Reachable ONLY through a run-level `w:rPr/w:cs` or `w:rPr/w:rtl` toggle. Scan the whole
    /// block table: not one row classifies to `cs`. A reader that picks the complex-script slot
    /// "because this character is Arabic" is not doing what Word does — Word sends Arabic to
    /// `ascii` and reaches `cs` only when the run itself says the run is complex-script.
    Cs,
}

impl WordFontSlot {
    /// All cases, mirroring Swift's `CaseIterable` conformance.
    pub const ALL: [WordFontSlot; 4] =
        [WordFontSlot::Ascii, WordFontSlot::HAnsi, WordFontSlot::EastAsia, WordFontSlot::Cs];
}

// swift: Render/Office/WordFontSlots.swift:27-41
/// One slot's declaration at ONE level of the cascade: a literal family, or a reference into the
/// theme's font scheme.
///
/// These are ONE cell, not two independent optionals, and that is load-bearing. MS-OI29500
/// §17.3.2.26 note e: *"If an inherited style contains an rFonts element with the ascii attribute it
/// will override any previously specified ascii OR asciiTheme attribute in the style hierarchy"* —
/// so a level that sets `w:ascii` must ERASE an ancestor's `w:asciiTheme`, which modelling them as
/// two optionals and coalescing at the end could never do (the ancestor's theme reference would leak
/// past the descendant's literal). Within one element the theme reference wins, per the same note.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WordFontDecl {
    Literal(String),
    /// An `ST_Theme` value — `minorHAnsi`, `majorEastAsia`, … — resolved against `WordThemeFonts`.
    Theme(String),
}

// swift: Render/Office/WordFontSlots.swift:42-121
/// A `w:rFonts` element as declared at one level, or the result of cascading several.
///
/// `hint` rides along as a fifth cell because it is an attribute of the same element and 23 of the
/// spec table's rows do nothing at all without it — measured at 42.9% of the `w:rFonts` in this
/// project's docx corpus, so it is not an edge case but most of what those documents say.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WordRFonts {
    pub ascii: Option<WordFontDecl>,
    pub h_ansi: Option<WordFontDecl>,
    pub east_asia: Option<WordFontDecl>,
    pub cs: Option<WordFontDecl>,
    /// `w:hint`'s raw value. Only `"eastAsia"` does anything (the corpus also carries `"default"`,
    /// which is the same as saying nothing); kept as the raw string rather than a Bool so a level
    /// that says `w:hint="default"` can still OVERRIDE an ancestor's `w:hint="eastAsia"` — a Bool
    /// would collapse "said default" and "said nothing" into the same false and let the ancestor win.
    // swift: Render/Office/WordFontSlots.swift:52-81
    pub hint: Option<String>,
}

impl WordRFonts {
    // swift: Render/Office/WordFontSlots.swift:52-81
    pub fn hints_east_asia(&self) -> bool {
        self.hint.as_deref() == Some("eastAsia")
    }

    /// True when this level declared nothing at all — the `parseStyles` gate for "is this style
    /// worth recording", matching how `RunStyleProps`/`ParaStyleProps` are gated beside it.
    // swift: Render/Office/WordFontSlots.swift:60-81
    pub fn is_empty(&self) -> bool {
        *self == WordRFonts::default()
    }

    // swift: Render/Office/WordFontSlots.swift:64-82
    pub fn get(&self, slot: WordFontSlot) -> Option<&WordFontDecl> {
        match slot {
            WordFontSlot::Ascii => self.ascii.as_ref(),
            WordFontSlot::HAnsi => self.h_ansi.as_ref(),
            WordFontSlot::EastAsia => self.east_asia.as_ref(),
            WordFontSlot::Cs => self.cs.as_ref(),
        }
    }

    pub fn set(&mut self, slot: WordFontSlot, value: Option<WordFontDecl>) {
        match slot {
            WordFontSlot::Ascii => self.ascii = value,
            WordFontSlot::HAnsi => self.h_ansi = value,
            WordFontSlot::EastAsia => self.east_asia = value,
            WordFontSlot::Cs => self.cs = value,
        }
    }

    /// Word's legacy East-Asian exception, as a slot remap: *"If the eastAsia (or eastAsiaTheme)
    /// attribute's value is 'Times New Roman' and the ascii (or asciiTheme) and hAnsi (or hAnsiTheme)
    /// attributes are equal, then the ascii (or asciiTheme) font is used."*
    ///
    /// The family name in that rule is not this app choosing a typeface — it is the SENTINEL Word
    /// itself writes, and the same page says why: *"Word uses a default font of Times New Roman for
    /// all of these attributes"*, so `eastAsia="Times New Roman"` overwhelmingly means nobody ever
    /// set an East Asian font, not that someone asked for one. Recognising a value the document
    /// declares is the opposite of hardcoding a family: nothing here is drawn unless the document
    /// named it.
    ///
    /// Expressed as "the eastAsia slot borrows the ascii declaration" rather than "the whole run uses
    /// ascii", which the spec's wording also allows. The two are indistinguishable in effect — the
    /// rule only fires when ascii and hAnsi are already equal, so every slot a character can select
    /// then names the same family — and this form leaves `cs` alone, which matters because `cs` is
    /// reached by the run-level toggle that takes precedence over this rule anyway.
    // swift: Render/Office/WordFontSlots.swift:42-121
    pub fn effective_slot(&self, slot: WordFontSlot) -> WordFontSlot {
        let is_sentinel = matches!(&self.east_asia, Some(WordFontDecl::Literal(s)) if s == "Times New Roman");
        if slot != WordFontSlot::EastAsia || !is_sentinel || self.ascii != self.h_ansi {
            return slot;
        }
        WordFontSlot::Ascii
    }

    /// The family this slot names in THIS document, or `nil` when neither the slot nor the theme it
    /// points at says anything.
    ///
    /// `nil` is not a failure: it is the ordinary case and means exactly what it has always meant —
    /// draw this text in the reader's own body font. That is the fallback chain's end, and there is
    /// deliberately no hardcoded family beyond it (`docs/per-script-font-design.md` §2.3).
    ///
    /// `script` is the ISO-15924 code of the CHARACTERS this slot was selected for, used only to
    /// pick an `a:font script=` entry out of the theme. See `WordThemeFonts.family` for why the
    /// character's own script rather than the document's language decides that.
    // swift: Render/Office/WordFontSlots.swift:104-122
    pub fn family(&self, slot: WordFontSlot, script: Option<&str>, theme: &WordThemeFonts) -> Option<String> {
        match self.get(self.effective_slot(slot)) {
            Some(WordFontDecl::Literal(name)) => Some(name.clone()),
            Some(WordFontDecl::Theme(r#ref)) => theme.family(r#ref, script),
            None => None,
        }
    }
}

// swift: Render/Office/WordFontSlots.swift:123-225
/// `word/theme/theme1.xml`'s `a:fontScheme` — a major (heading) and a minor (body) scheme, each
/// naming a default per broad category plus a per-script override list.
///
/// The override list is the whole reason this type exists. Measured across the five real themes in
/// this project's corpus, `a:ea typeface=""` and `a:cs typeface=""` in **five of five**, while 29 to
/// 94 `a:font script="…"` entries carry the actual families (`script="Hang"` → 맑은 고딕). A reader
/// that parses only `a:latin`/`a:ea`/`a:cs` resolves `minorEastAsia` to the empty string on every
/// one of them and gains nothing at all on a real Korean document — which is exactly the document
/// this work exists for.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WordThemeFonts {
    pub major: WordThemeScheme,
    pub minor: WordThemeScheme,
}

// swift: Render/Office/WordFontSlots.swift:133-145
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WordThemeScheme {
    /// `a:latin` — the fallback for the ascii/hAnsi theme references.
    pub latin: Option<String>,
    /// `a:ea` — the fallback for the eastAsia theme reference. Empty in every real theme measured.
    pub east_asian: Option<String>,
    /// `a:cs` — the fallback for the bidi/complex-script theme reference. Likewise empty.
    pub complex: Option<String>,
    /// `a:font script="…" typeface="…"`, keyed by ISO-15924 script code (`Hang`, `Jpan`, `Hans`,
    /// `Hant`, `Arab`, `Hebr`, `Thai`, …). ISO-15924 codes are SCRIPT identities, not languages
    /// or regions, which is what makes this the right hook for a reader that must never name a
    /// human language: the key is a property of the characters, computable anywhere.
    pub by_script: std::collections::HashMap<String, String>,
}

impl WordThemeFonts {
    // swift: Render/Office/WordFontSlots.swift:146-151
    pub fn is_empty(&self) -> bool {
        *self == WordThemeFonts::default()
    }

    /// Resolves an `ST_Theme` reference to a family.
    ///
    /// **A deliberate divergence from Word's stated algorithm, recorded here rather than discovered
    /// later.** The spec route runs through `w:themeFontLang` in `word/settings.xml`: `minorEastAsia`
    /// picks the `a:font` entry for the LANGUAGE in `@w:eastAsia` (`ko-KR` in every corpus file that
    /// declares one). Following it needs a language → ISO-15924 mapping the spec does not supply, and
    /// that table would be per-language data compiled into a reader shipping worldwide. We resolve by
    /// the CHARACTER's own script instead, which needs no language data whatsoever and reaches the
    /// same answer whenever the document's language and its characters agree — which for the East
    /// Asian slot is the case this feature is about.
    ///
    /// Where the two part company is a character whose script cannot be narrowed to one ISO-15924
    /// code. See `WordThemeFonts.scriptCode` for which those are and what they cost.
    /// **The role's own default falls through to `a:latin` when it is empty**, and that fall-through
    /// is load-bearing rather than defensive: `a:ea typeface=""` and `a:cs typeface=""` in five of
    /// five real themes measured here, so a role that stopped at its own default resolved to nothing
    /// on every real document the moment the character's script missed `byScript`. Measured through
    /// the real dispatch before this fell through: a run carrying `w:asciiTheme="minorEastAsia"` —
    /// 2,422 of them in one corpus file — gave its Latin text no family while the Korean beside it
    /// got 맑은 고딕, so one authored sentence rendered in two faces where Word renders it in one.
    /// Word reaches 맑은 고딕 there through `w:themeFontLang`, i.e. through the document's LANGUAGE;
    /// `a:latin` reaches the same family on both corpus themes without naming a language anywhere,
    /// which is the constraint this reader ships under.
    // swift: Render/Office/WordFontSlots.swift:152-185
    pub fn family(&self, r#ref: &str, script: Option<&str>) -> Option<String> {
        let (scheme, role) = Self::target(r#ref)?;
        let table = if scheme == Which::Major { &self.major } else { &self.minor };
        if let Some(script) = script {
            if let Some(named) = table.by_script.get(script) {
                return Some(named.clone());
            }
        }
        match role {
            Role::Latin => table.latin.clone(),
            Role::EastAsian => table.east_asian.clone().or_else(|| table.latin.clone()),
            Role::Complex => table.complex.clone().or_else(|| table.latin.clone()),
        }
    }

    /// `ST_Theme`'s eight values (ECMA-376) split into which scheme and which default within it.
    /// `majorAscii`/`majorHAnsi` name the same `a:latin` default — the two Latin ranges Word tracks
    /// separately in `w:rFonts` share one theme entry.
    // swift: Render/Office/WordFontSlots.swift:188-203
    fn target(r#ref: &str) -> Option<(Which, Role)> {
        match r#ref {
            "majorAscii" | "majorHAnsi" => Some((Which::Major, Role::Latin)),
            "majorEastAsia" => Some((Which::Major, Role::EastAsian)),
            "majorBidi" => Some((Which::Major, Role::Complex)),
            "minorAscii" | "minorHAnsi" => Some((Which::Minor, Role::Latin)),
            "minorEastAsia" => Some((Which::Minor, Role::EastAsian)),
            "minorBidi" => Some((Which::Minor, Role::Complex)),
            _ => None,
        }
    }

    /// The ISO-15924 code to look up in `byScript` for text of this class, or `nil` when this
    /// project's shared script table cannot narrow it to exactly one code.
    ///
    /// **Recorded gap: `.han` returns nil.** A Han character could belong to a `Hans`, `Hant` or
    /// `Jpan` entry and only the document's language distinguishes them — the very data this route
    /// exists to avoid. Guessing one would mis-render the other two, so a Hanja inside a Korean
    /// paragraph falls through to `a:ea` (empty in every real theme) and therefore to `nil`, the
    /// reader's own body font. That is what it already rendered as before this feature, so the gap
    /// costs nothing that was previously working; what it costs is that the Hangul beside it now
    /// improves and the Hanja does not, which shows up as a run boundary between them.
    ///
    /// `.kana` → `Jpan` and not `Hira`/`Kana`: the theme's own list is keyed by writing SYSTEM, and
    /// `Jpan` is the code every measured theme actually carries for kana text.
    // swift: Render/Office/WordFontSlots.swift:204-226
    pub fn script_code(klass: crate::render::office::script::unicode_script::ScriptClass) -> Option<&'static str> {
        use crate::render::office::script::unicode_script::ScriptClass;
        match klass {
            ScriptClass::Latin => Some("Latn"),
            ScriptClass::Hangul => Some("Hang"),
            ScriptClass::Kana => Some("Jpan"),
            ScriptClass::Han
            | ScriptClass::EastAsianOther
            | ScriptClass::Complex
            | ScriptClass::Other
            | ScriptClass::Common
            | ScriptClass::Inherited
            | ScriptClass::Extend => None,
        }
    }
}

// swift: Render/Office/WordFontSlots.swift:186-202
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Which {
    Major,
    Minor,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Role {
    Latin,
    EastAsian,
    Complex,
}

// swift: Render/Office/WordFontSlots.swift:227-239
/// What `ScriptRunSplitter` is asked to break on for a Word document: the slot a character selects
/// AND the script key that slot's theme reference would be resolved through.
///
/// Both halves have to be in the key, because the splitter memoises `family` for as long as
/// consecutive scalars keep choosing the same value. The slot alone is not enough: 한 and 漢 both
/// select `eastAsia`, but one resolves through the theme's `Hang` entry and the other cannot be
/// narrowed to any entry at all, so a slot-only key would silently hand the second one the first
/// one's family.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WordSlotKey {
    pub slot: WordFontSlot,
    pub script: Option<String>,
}

// swift: Render/Office/WordFontSlots.swift:240-422
/// MS-OI29500 §17.3.2.26's per-character table — "which of the four fonts does Word use for this
/// character", transcribed row by row so it can be diffed against the published table.
pub struct WordFontBlockTable;

impl WordFontBlockTable {
    /// The slot this scalar selects, or `nil` for a scalar that must never START a piece.
    ///
    /// ## Absorption is the shared floor, and it was measured against the alternative
    ///
    /// Every `ScriptClass.isAbsorbing` class — Common, Inherited, Grapheme_Extend — absorbs, which
    /// is the same floor the other two readers stand on. The competing rule was tried first and
    /// rejected on numbers, so it is worth stating what it was: classify Common by the table too,
    /// on the entirely correct observation that Word is EXPLICIT that ASCII space, digits and
    /// punctuation are Basic Latin and select the `ascii` slot — they are not neutral to Word the
    /// way ODF's Table 22 gaps are neutral to ODF.
    ///
    /// That version is more faithful per character and worse everywhere it was measured. Its cost
    /// falls on CJK punctuation: `U+3000`–`U+303F` and the fullwidth forms are Script=Common, so
    /// they carry no ISO-15924 identity to look the theme's `a:font script=` list up by, while the
    /// Hangul beside them does — and since a real Office theme leaves `a:ea` empty, every ideographic
    /// comma in a Korean paragraph both broke the run AND fell back to the reader's own body font
    /// while its neighbours drew in 맑은 고딕. Measured on one 39,660-character Korean report:
    /// 6,032 spans classifying Common against 4,054 absorbing it, from a baseline of 3,681 — a 64%
    /// growth cut to 10%, with the visible inconsistency removed rather than traded away.
    ///
    /// What absorbing Common costs in exchange is real and bounded: where a document points `ascii`
    /// and `eastAsia` at DIFFERENT faces, the digits in `제1항` ride along with the Hangul instead
    /// of taking the Latin face Word would give them. No document in this project's corpus does
    /// that — every one resolves both slots to the same family — and the trade is the one this
    /// codebase already made deliberately one layer down, where `Span.resolvedFontDescriptor`'s own
    /// doc records that "a space between two Korean words rides along with that substitute rather
    /// than reverting".
    ///
    /// Absorption alone is not sufficient, and the gap is `DocxReader.buildSpans`': a run that is
    /// NOTHING but neutral characters has no neighbour to absorb into, and must still be given the
    /// table's answer rather than no family at all.
    ///
    /// The floor is not negotiable whatever the rest is, because Word's own table would otherwise
    /// cut a grapheme cluster in half, twice over. A Latin letter is Basic Latin (`ascii`) while the
    /// combining acute accent on it is in Combining Diacritical Marks (`hAnsi` unless hinted), so a
    /// document with different ascii and hAnsi families would split base from mark. A ZWJ emoji
    /// sequence is worse: both emoji are astral and therefore `eastAsia`, while the joiner between
    /// them is General Punctuation and therefore `hAnsi`, splitting one cluster into three. Neither
    /// needs a hand-written scalar list to fix — U+200D is Script=Inherited and every combining mark
    /// and variation selector is Grapheme_Extend, both already in the shared table.
    // swift: Render/Office/WordFontSlots.swift:243-289
    pub fn slot(scalar: char, hints_east_asia: bool) -> Option<WordSlotKey> {
        let klass = crate::render::office::script::unicode_script::UnicodeScript::of(scalar);
        if klass.is_absorbing() {
            return None;
        }
        Some(WordSlotKey {
            slot: Self::slot_for_value(scalar as u32, hints_east_asia),
            script: WordThemeFonts::script_code(klass).map(|s| s.to_string()),
        })
    }

    /// The table lookup itself, split out so tests can drive it by code point.
    ///
    /// **Astral characters take `eastAsia`, deliberately.** The published table is written in UTF-16
    /// terms and classifies all three surrogate ranges (`D800–DB7F`, `DB80–DBFF`, `DC00–DFFF`) as
    /// `eastAsia`, which means every character above the BMP — emoji, CJK Ext-B and up, Deseret —
    /// is `eastAsia` to a UTF-16 reader. This pass walks Unicode SCALARS, so it never sees a
    /// surrogate and would otherwise drop astral characters into the unlisted catch-all `hAnsi`.
    /// The spec is silent on what Word does with an astral scalar and this was not tested against
    /// Word, so the choice here is the spec's letter, taken on purpose rather than by accident.
    // swift: Render/Office/WordFontSlots.swift:290-304
    pub fn slot_for_value(value: u32, hints_east_asia: bool) -> WordFontSlot {
        if value > 0xFFFF {
            return WordFontSlot::EastAsia;
        }
        let Some(row) = Self::row_containing(value) else { return WordFontSlot::HAnsi };
        if hints_east_asia { row.hinted } else { row.plain }
    }

    // swift: Render/Office/WordFontSlots.swift:311-321
    fn row_containing(value: u32) -> Option<Row> {
        let rows = Self::rows();
        let mut low: i64 = 0;
        let mut high: i64 = rows.len() as i64 - 1;
        while low <= high {
            let mid = ((low + high) / 2) as usize;
            let row = rows[mid];
            if value < row.start {
                high = mid as i64 - 1;
            } else if value > row.end {
                low = mid as i64 + 1;
            } else {
                return Some(row);
            }
        }
        None
    }

    // swift: Render/Office/WordFontSlots.swift:322-345
    /// The table, sorted and non-overlapping. Anything not covered is the spec's own catch-all:
    /// *"For all ranges not listed in the table, the hAnsi (or hAnsiTheme) font shall be used."*
    ///
    /// Rows whose answer is `hAnsi` both hinted and unhinted are therefore OMITTED, since listing
    /// them would only restate the catch-all. Those are Latin Extended-A (`0100–017F`), Latin
    /// Extended-B (`0180–024F`), IPA Extensions (`0250–02AF`), Latin Extended Additional
    /// (`1E00–1EFF`), and the parts of Latin-1 Supplement not enumerated below — named here so a
    /// reader diffing this against the published table can see they were read and dismissed, not
    /// missed. Each of those rows carries only ONE exception, and it is the one we do not implement:
    ///
    /// **Recorded gap, not an oversight.** Four rows branch on *"the language of the run is Chinese
    /// Traditional or Chinese Simplified"* and two of those additionally on the eastAsia font's
    /// character set being `Chinese5` or `GB2312` (which lives in `word/fontTable.xml`, a part this
    /// reader never opens). Implementing them verbatim would put a human language in this file,
    /// which this project forbids outright. The unconditional arm is taken instead. What that costs
    /// is precisely bounded: accented Latin letters inside a Chinese-language run draw from the
    /// hAnsi family rather than the East Asian one. Nothing else in the table is affected, and no
    /// non-Chinese document can reach these branches at all.
    ///
    /// A row that is only conditional in the published table (`"if hint is eastAsia → eastAsia"`,
    /// with no unconditional classification given) resolves unhinted to the catch-all `hAnsi` —
    /// there is no other answer available, since rule 3 covers every range the table does not
    /// classify outright.
    // swift: Render/Office/WordFontSlots.swift:346-422
    fn rows() -> &'static [Row] {
        use WordFontSlot::*;
        &[
            Row { start: 0x0000, end: 0x007F, plain: Ascii, hinted: Ascii }, // Basic Latin
            // Latin-1 Supplement 00A0–00FF is hAnsi except for these scattered code points, which the
            // table lists individually as taking eastAsia when hinted: A1, A4, A7–A8, AA, AD, AF,
            // B0–B4, B6–BA, BC–BF, D7, F7. (AF and B0–B4 are contiguous and merged.)
            Row { start: 0x00A1, end: 0x00A1, plain: HAnsi, hinted: EastAsia },
            Row { start: 0x00A4, end: 0x00A4, plain: HAnsi, hinted: EastAsia },
            Row { start: 0x00A7, end: 0x00A8, plain: HAnsi, hinted: EastAsia },
            Row { start: 0x00AA, end: 0x00AA, plain: HAnsi, hinted: EastAsia },
            Row { start: 0x00AD, end: 0x00AD, plain: HAnsi, hinted: EastAsia },
            Row { start: 0x00AF, end: 0x00B4, plain: HAnsi, hinted: EastAsia },
            Row { start: 0x00B6, end: 0x00BA, plain: HAnsi, hinted: EastAsia },
            Row { start: 0x00BC, end: 0x00BF, plain: HAnsi, hinted: EastAsia },
            Row { start: 0x00D7, end: 0x00D7, plain: HAnsi, hinted: EastAsia },
            Row { start: 0x00F7, end: 0x00F7, plain: HAnsi, hinted: EastAsia },
            Row { start: 0x02B0, end: 0x02FF, plain: HAnsi, hinted: EastAsia }, // Spacing Modifier Letters
            Row { start: 0x0300, end: 0x036F, plain: HAnsi, hinted: EastAsia }, // Combining Diacritical Marks
            Row { start: 0x0370, end: 0x03CF, plain: HAnsi, hinted: EastAsia }, // Greek
            Row { start: 0x0400, end: 0x04FF, plain: HAnsi, hinted: EastAsia }, // Cyrillic
            // The six counter-intuitive rows: right-to-left and Syriac blocks classified to the slot
            // named after code points 0–127. Repeated across six separate rows in the published table,
            // so this is its rule and not a transcription slip.
            Row { start: 0x0590, end: 0x05FF, plain: Ascii, hinted: Ascii }, // Hebrew
            Row { start: 0x0600, end: 0x06FF, plain: Ascii, hinted: Ascii }, // Arabic
            Row { start: 0x0700, end: 0x074F, plain: Ascii, hinted: Ascii }, // Syriac
            Row { start: 0x0750, end: 0x077F, plain: Ascii, hinted: Ascii }, // Arabic Supplement
            Row { start: 0x0780, end: 0x07BF, plain: Ascii, hinted: Ascii }, // Thaana
            Row { start: 0x1100, end: 0x11FF, plain: EastAsia, hinted: EastAsia }, // Hangul Jamo
            Row { start: 0x2000, end: 0x206F, plain: HAnsi, hinted: EastAsia }, // General Punctuation
            Row { start: 0x2070, end: 0x209F, plain: HAnsi, hinted: EastAsia }, // Superscripts and Subscripts
            Row { start: 0x20A0, end: 0x20CF, plain: HAnsi, hinted: EastAsia }, // Currency Symbols
            Row { start: 0x20D0, end: 0x20FF, plain: HAnsi, hinted: EastAsia }, // Combining Marks for Symbols
            Row { start: 0x2100, end: 0x214F, plain: HAnsi, hinted: EastAsia }, // Letter-like Symbols
            Row { start: 0x2150, end: 0x218F, plain: HAnsi, hinted: EastAsia }, // Number Forms
            Row { start: 0x2190, end: 0x21FF, plain: HAnsi, hinted: EastAsia }, // Arrows
            Row { start: 0x2200, end: 0x22FF, plain: HAnsi, hinted: EastAsia }, // Mathematical Operators
            Row { start: 0x2300, end: 0x23FF, plain: HAnsi, hinted: EastAsia }, // Miscellaneous Technical
            Row { start: 0x2400, end: 0x243F, plain: HAnsi, hinted: EastAsia }, // Control Pictures
            Row { start: 0x2440, end: 0x245F, plain: HAnsi, hinted: EastAsia }, // OCR
            Row { start: 0x2460, end: 0x24FF, plain: HAnsi, hinted: EastAsia }, // Enclosed Alphanumerics
            Row { start: 0x2500, end: 0x257F, plain: HAnsi, hinted: EastAsia }, // Box Drawing
            Row { start: 0x2580, end: 0x259F, plain: HAnsi, hinted: EastAsia }, // Block Elements
            Row { start: 0x25A0, end: 0x25FF, plain: HAnsi, hinted: EastAsia }, // Geometric Shapes
            Row { start: 0x2600, end: 0x26FF, plain: HAnsi, hinted: EastAsia }, // Miscellaneous Symbols
            Row { start: 0x2700, end: 0x27BF, plain: HAnsi, hinted: EastAsia }, // Dingbats
            Row { start: 0x2E80, end: 0x2EFF, plain: HAnsi, hinted: EastAsia }, // CJK Radicals Supplement
            Row { start: 0x2F00, end: 0x2FDF, plain: EastAsia, hinted: EastAsia }, // Kangxi Radicals
            Row { start: 0x2FF0, end: 0x2FFF, plain: EastAsia, hinted: EastAsia }, // Ideographic Description
            Row { start: 0x3000, end: 0x303F, plain: EastAsia, hinted: EastAsia }, // CJK Symbols and Punctuation
            Row { start: 0x3040, end: 0x309F, plain: EastAsia, hinted: EastAsia }, // Hiragana
            Row { start: 0x30A0, end: 0x30FF, plain: EastAsia, hinted: EastAsia }, // Katakana
            Row { start: 0x3100, end: 0x312F, plain: EastAsia, hinted: EastAsia }, // Bopomofo
            Row { start: 0x3130, end: 0x318F, plain: EastAsia, hinted: EastAsia }, // Hangul Compatibility Jamo
            Row { start: 0x3190, end: 0x319F, plain: EastAsia, hinted: EastAsia }, // Kanbun
            Row { start: 0x3200, end: 0x32FF, plain: EastAsia, hinted: EastAsia }, // Enclosed CJK Letters/Months
            Row { start: 0x3300, end: 0x33FF, plain: EastAsia, hinted: EastAsia }, // CJK Compatibility
            Row { start: 0x3400, end: 0x4DBF, plain: EastAsia, hinted: EastAsia }, // CJK Unified Ideographs Ext A
            Row { start: 0x4E00, end: 0x9FAF, plain: EastAsia, hinted: EastAsia }, // CJK Unified Ideographs
            Row { start: 0xA000, end: 0xA48F, plain: EastAsia, hinted: EastAsia }, // Yi Syllables
            Row { start: 0xA490, end: 0xA4CF, plain: EastAsia, hinted: EastAsia }, // Yi Radicals
            Row { start: 0xAC00, end: 0xD7AF, plain: EastAsia, hinted: EastAsia }, // Hangul Syllables
            // Surrogates. Unreachable from a scalar walk — kept because they are what the astral rule
            // above is derived from, and removing them would leave that rule looking invented.
            Row { start: 0xD800, end: 0xDFFF, plain: EastAsia, hinted: EastAsia },
            Row { start: 0xE000, end: 0xF8FF, plain: HAnsi, hinted: EastAsia }, // Private Use Area
            Row { start: 0xF900, end: 0xFAFF, plain: EastAsia, hinted: EastAsia }, // CJK Compatibility Ideographs
            // Alphabetic Presentation Forms is one published row split in two: its Latin ligatures take
            // eastAsia when hinted, its Hebrew presentation forms take ascii unconditionally.
            Row { start: 0xFB00, end: 0xFB1C, plain: HAnsi, hinted: EastAsia },
            Row { start: 0xFB1D, end: 0xFB4F, plain: Ascii, hinted: Ascii },
            Row { start: 0xFB50, end: 0xFDFF, plain: Ascii, hinted: Ascii }, // Arabic Presentation Forms-A
            Row { start: 0xFE30, end: 0xFE4F, plain: EastAsia, hinted: EastAsia }, // CJK Compatibility Forms
            Row { start: 0xFE50, end: 0xFE6F, plain: EastAsia, hinted: EastAsia }, // Small Form Variants
            Row { start: 0xFE70, end: 0xFEFE, plain: Ascii, hinted: Ascii }, // Arabic Presentation Forms-B
            Row { start: 0xFF00, end: 0xFFEF, plain: EastAsia, hinted: EastAsia }, // Halfwidth and Fullwidth Forms
        ]
    }
}

// swift: Render/Office/WordFontSlots.swift:305-310
#[derive(Clone, Copy)]
struct Row {
    start: u32,
    end: u32,
    plain: WordFontSlot,
    hinted: WordFontSlot,
}
