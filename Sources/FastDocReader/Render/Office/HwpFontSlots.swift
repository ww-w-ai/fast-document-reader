import Foundation

/// HWP's seven font slots, in the file format's own fixed order.
///
/// A `CharShape` carries `font_ids: [u16; 7]` and the document's font table carries seven parallel
/// groups, so every char shape names seven families — one per writing system — and HWP picks between
/// them per CHARACTER. The raw values are that order and are a contract with the `charShapes` table
/// rhwp exports (`HwpEnvelope.charShapes`, one row of seven strings per char shape): reordering these
/// cases silently re-labels every family in every document.
enum HwpFontSlot: Int, CaseIterable {
    case hangul = 0
    case latin
    case hanja
    case japanese
    /// 기타 — HWP's own name for "a script that is none of the four above". This is the slot rhwp's
    /// own classifier can never return, which is the defect this file exists to not repeat.
    case other
    /// 기호 — symbols. Reachable only through `HwpSlotTable.slot(for:)`'s measured exception; see
    /// `symbolSelectingScalar` for why it is as narrow as it is.
    case symbol
    /// 사용자 — a user-defined slot. Never selected by classification; see `HwpSlotTable`'s note.
    case user
}

/// The seven families ONE char shape declared, each already resolved through HWP's fallback chain.
///
/// Construction resolves every slot once, so the per-scalar path is an array index and the splitter's
/// own memo never has to re-derive anything. `isUniform` is the fast path that makes invariant 37 hold
/// by construction for the 46.4% of documents whose slots all agree: when every slot resolves to the
/// same family no character can select anything different from any other, so the scalar walk is
/// skipped rather than run to rediscover that.
struct HwpSlotFonts: Equatable {
    /// `resolved[slot]` — the family that slot draws in, or `nil` when the document named none
    /// anywhere. **Never a hardcoded family:** `nil` means "the theme's own body font", which is
    /// exactly what this reader rendered before per-slot fonts existed.
    private let resolved: [String?]

    /// True when all seven resolved families are equal — including the case where all seven are
    /// `nil`, i.e. a document that declared no font at all.
    let isUniform: Bool

    /// The chain, per `docs/per-script-font-design.md` §2.3: **slot → 0 → 1 → first non-empty →
    /// `nil`.** An empty string in the row is a real answer from rhwp ("the document's font table had
    /// no entry for this slot"), not an error, so it is treated as absent rather than as a family
    /// named "".
    ///
    /// The `first non-empty` arm is the one worth stating out loud, because it COULD differ from what
    /// this reader drew before: rhwp's own `font` field is `slot 0, else slot 1`, and stops there, so
    /// a row naming nothing in slots 0 and 1 but something in slot 2 would newly draw in that family.
    /// Measured rather than assumed, and measured against the `font` string rhwp ACTUALLY EXPORTED
    /// rather than a re-derivation of its rule — the distinction matters because `lookup_font_name`
    /// applies rhwp's own `lang_index`-sensitive substitution before we ever see a name, so a row can
    /// be self-consistent and still not match the span's string. Over 920 documents /
    /// 114,696 rows / **565,909 spans: 0 disagreements, and 0 rows with slots 0 and 1 both empty**
    /// (`HwpSlotClassifierProbeTests.testFallbackChainAgreesWithTheParsersOwnFontField` — the figures
    /// this comment first carried, 1,557 / 218,745 / 1,085,915, were the pre-dedupe double count and
    /// no invocation of that test can produce them; see `symbolSelectingScalar` for why). The arm is
    /// therefore unreached on real files and is here as an honest total function, not as a behaviour
    /// change — which is also why the neutral path below can use this chain rather than having to
    /// carry rhwp's answer separately to stay byte-identical.
    /// What this char shape does BEYOND its seven families — carried alongside the fonts because
    /// both are read by the same row number and threaded to the same place, and a second parallel
    /// array threaded through the same eight call sites would be one more thing to keep in step.
    /// `nil` for a parser predating the decoration export.
    var decor: HwpCharDecor?

    init(row: [String], decor: HwpCharDecor? = nil) {
        self.decor = decor
        let names: [String?] = (0..<7).map { i in
            guard i < row.count else { return nil }
            let n = row[i]
            return n.isEmpty ? nil : n
        }
        let firstNonEmpty = names.first(where: { $0 != nil }) ?? nil
        let chain = names.map { $0 ?? names[0] ?? names[1] ?? firstNonEmpty }
        resolved = chain
        isUniform = chain.allSatisfy { $0 == chain[0] }
    }

    func family(_ slot: HwpFontSlot) -> String? { resolved[slot.rawValue] }

    /// The family a run with no classifying character at all falls back to — the Hangul slot's own
    /// resolution, which reproduces rhwp's `font` field exactly (slot 0, else slot 1) for every row
    /// where either is declared.
    var neutralFamily: String? { resolved[HwpFontSlot.hangul.rawValue] }
}

/// Which of HWP's seven slots a scalar selects — the whole per-character half of the HWP feature.
///
/// ## rhwp's own `detect_lang_category` is NOT the model
///
/// The fork ships a classifier for this (`renderer/style_resolver.rs:402`) and it must not be reused
/// or ported. It has no `=> 4` arm at all — HWP's "기타/Other" slot is unreachable from it — and its
/// catch-all is `_ => 0`, the KOREAN slot, so Cyrillic, Greek, Arabic, Hebrew, Thai and Devanagari
/// all resolve to the family the document chose for Hangul. It also mis-slots fullwidth Latin,
/// halfwidth katakana, CJK Ext-C..G and Bopomofo. Reading it was useful; copying it would have
/// shipped its bug. Nothing is ported, so no licence notice is due.
///
/// The correction is a different DEFAULT, not a bigger table: everything with a real script identity
/// that is not one of the four named systems goes to `other`, which is what that slot is defined to
/// be. That is also why this file holds no ranges of its own — the script identity comes from the
/// shared generated UCD table (`UnicodeScript`), the same one Word's and ODF's classifiers read.
enum HwpSlotTable {
    /// The slot this scalar selects, or `nil` for a scalar that must never START a piece.
    ///
    /// Absorption is the shared floor (`ScriptClass.isAbsorbing`): Common, Inherited and
    /// Grapheme_Extend join the run in progress. HWP has no published per-character table of its own
    /// to weigh against that floor — unlike Word, whose MS-OI29500 §17.3.2.26 block table is explicit
    /// that ASCII digits select `ascii` — so there is nothing here to trade the floor against, and the
    /// digits in `제1항` ride along with the Hangul rather than splitting the run at every numeral.
    static func slot(for scalar: Unicode.Scalar) -> HwpFontSlot? {
        let klass = UnicodeScript.of(scalar)
        if klass.isAbsorbing {
            return symbolSelectingScalar(scalar) ? .symbol : nil
        }
        switch klass {
        case .hangul: return .hangul
        case .latin: return .latin
        case .han: return .hanja
        case .kana: return .japanese
        // Cyrillic, Greek, Arabic, Hebrew, Thai, Devanagari, Armenian, and every unassigned or
        // private-use scalar. `eastAsianOther` and `complex` are refinements of `other` that nothing
        // shipping distinguishes (see `ScriptClass`), and HWP has exactly one slot for all of them.
        case .eastAsianOther, .complex, .other: return .other
        case .common, .inherited, .extend: return nil   // unreachable — isAbsorbing covered these
        }
    }

    /// The measured exception to absorption, and the ONLY route to the Symbol slot.
    ///
    /// ## The tension, and the numbers that settled it
    ///
    /// HWP reserves slot 5 for symbols, but nearly every character that would use it is
    /// Script=Common (■ □ ○ ─ ▪ ● ◆ and the arrows), which the shared absorption floor makes ride the
    /// neighbouring run. Two true things pulled opposite ways: absorbing keeps run counts flat, which
    /// is what the floor is for; and a face that covers Hangul is not necessarily the face the
    /// document chose for its symbols — the fork keeps its own regression test for exactly that.
    ///
    /// So it was measured rather than preferred, over **920 distinct real HWP/HWPX documents,
    /// 0 unreadable, 114,696 char-shape rows, 11,310,464 characters, 565,909 spans**
    /// (`HwpSlotClassifierProbeTests.testSymbolAndUserSlotCost`, re-runnable). Cost is extra pieces;
    /// benefit is characters that actually change typeface, counted PER SCALAR against the
    /// no-exception split — a piece count alone cannot tell you that, since a split can hand both
    /// halves the same family.
    ///
    /// (920 documents, and if an older note anywhere says 1,557 for this same corpus it is the
    /// pre-dedupe figure: the natural invocation names the rhwp sample directory AND `$HOME/Documents`,
    /// and the first lives inside the second, so every sample was walked twice. The probe now dedupes
    /// by resolved path. Ratios were unchanged by the fix — 27.4% → 27.1%, +0.3% → +0.4% — which is
    /// what a uniform double-count predicts. Note this is a DIFFERENT number from the 1,557-file
    /// corpus in `docs/per-script-font-design.md` §6, which was a genuinely wider walk; the collision
    /// of the two is exactly why the one above needed correcting rather than explaining away.)
    ///
    /// | rule | pieces | cost | chars re-faced |
    /// |---|---|---|---|
    /// | absorb every symbol (no exception) | 584,016 | — | — |
    /// | **NARROW list — shipped** | 586,099 | **+2,083 (+0.4%)** | **17,210** |
    /// | rhwp's own slot-5 range list | 589,903 | +5,887 (+1.0%) | 65,991 |
    ///
    /// And the benefit is not hypothetical: **31,131 of 114,696 rows (27.1%), across 425 of the
    /// 920 documents, name a Symbol family that differs from their own Hangul family.** More than a
    /// quarter of real char shapes genuinely ask for a different face for their symbols, so absorbing
    /// every symbol draws a documented request in the wrong typeface. At +0.4% pieces that is bought
    /// cheaply — 8.3 characters re-faced per extra piece.
    ///
    /// ## Why this list is narrow, and what it deliberately leaves out
    ///
    /// Excepted: geometric shapes, box drawing, block elements, arrows, dingbats and miscellaneous
    /// symbols — characters drawn as marks in their own right, which a Korean document uses as
    /// bullets and rules.
    ///
    /// **Not excepted, deliberately: `U+3000`–`U+303F`, which rhwp's own slot-5 list claims.** Its
    /// first code point is `U+3000` IDEOGRAPHIC SPACE, and a SPACE taking a different typeface from
    /// the words on either side of it is the precise failure both of this codebase's other two
    /// classifiers were corrected to avoid — ODF's, where "a single space between two Korean words
    /// would end one run and begin another", and Word's, where classifying Common by the block table
    /// grew one Korean report's spans 64% and left every ideographic comma falling back to the
    /// reader's own body font while its neighbours drew in the document's face. The rest of that
    /// block is CJK punctuation sitting inside running prose. Punctuation belongs to the text around
    /// it; a bullet does not. That single block is most of the difference between the two rows above.
    ///
    /// ASCII is not excepted at any code point: `*` and `-` are Latin-slot characters in every
    /// document that uses them as text, and `UnicodeScript`'s ASCII fast path means this function is
    /// not even consulted for them on the common path.
    ///
    /// ## Slot 6 (User) is never selected — measured, not omitted
    ///
    /// rhwp reaches its User slot for exactly one code point, `U+318D` (ㆍ araea), which its own
    /// source marks as a Korea-specific hack. The first measurement contradicted the guess that it
    /// never occurs: **`U+318D` appears 3,153 times** in the corpus. So it was costed like the
    /// symbols rather than dismissed:
    ///
    /// | | pieces | cost over NARROW | chars re-faced |
    /// |---|---|---|---|
    /// | NARROW + `U+318D` → User | 588,665 | **+2,566** | +1,435 |
    ///
    /// That is **1.79 extra pieces per character re-faced, against 0.12 for the narrow symbol rule —
    /// fifteen times worse** — because araea appears as a separator INSIDE Hangul prose (`가ㆍ나`),
    /// so nearly every occurrence cuts a run in three. It is Script=Hangul in the UCD and it is doing
    /// a separator's job, which makes routing it elsewhere the same mistake as routing the ideographic
    /// space: it is punctuation, and punctuation belongs to the text around it. Rejected on those
    /// numbers, and rejected again on kind — reaching slot 6 requires hardcoding one code point,
    /// which is the hand-maintained list this design forbids. (For completeness: 52,575 rows (45.8%)
    /// DO declare a User family differing from their Hangul one. A slot being declared is not
    /// evidence that any character selects it.)
    private static func symbolSelectingScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2190...0x21FF,   // arrows
             0x2500...0x257F,   // box drawing
             0x2580...0x259F,   // block elements
             0x25A0...0x25FF,   // geometric shapes  ■ □ ○ ● ◆ ▪
             0x2600...0x26FF,   // miscellaneous symbols
             0x2700...0x27BF:   // dingbats
            return true
        default:
            return false
        }
    }
}
