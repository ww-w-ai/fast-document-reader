/// Which writing system a scalar belongs to, at the granularity the three office formats' own
/// font-slot vocabularies need — Word's 4 slots, ODF's 3, HWP's 7 — expressed as ISO-15924 script
/// identities so no human language is ever named.
///
/// The raw values are a CONTRACT with `Scripts/gen-script-ranges.py`'s `CLASS_ORDER`: the generated
/// table stores a range's class as this enum's raw value, so reordering the cases here silently
/// re-labels every scalar in the document. `ScriptTableTests.testGeneratedClassNamesMatchTheEnumOrder`
/// compares the two lists and fails if they ever drift.
///
/// **`complex` and `eastAsianOther` are refinements of `other`, not independent facts.** Unicode
/// defines no property for either — "complex script" is ODF's and Word's shaping/bidi vocabulary,
/// not the UCD's — so their membership is curated in the generator by hand. Nothing shipping today
/// distinguishes them from `other` (HWP sends all three to its own Other slot; Word never picks its
/// complex slot by character at all, and ODF has its own normative table), which is exactly why a
/// script missing from either curated set cannot mis-render anything. Should a classifier ever need
/// the distinction, derive the membership from a real property rather than extending a hand list.
enum ScriptClass: UInt8, CaseIterable {
    case latin = 0
    case hangul
    case han
    case kana
    case eastAsianOther
    case complex
    /// Every other real script identity, PLUS the scalars the UCD leaves unassigned (Script=Unknown,
    /// which includes the private use areas). Unassigned is deliberately not absorbing: it is not
    /// Common, and a format whose own specification says to treat some of it as neutral — ODF does,
    /// for its Table 22 gaps — says so in its own classifier.
    case other

    /// Script=Common (`Zyyy`): space, ASCII punctuation, digits, most symbols, emoji, the regional
    /// indicators, ZWJ and the skin-tone modifiers.
    case common
    /// Script=Inherited (`Zinh`): a mark that takes its script from whatever it is attached to.
    case inherited
    /// `Grapheme_Extend`, overlaid ON TOP of the script value. This is the class that stops a run
    /// breaking in the middle of a grapheme cluster, and it is not reducible to Common+Inherited:
    /// 1,443 combining scalars carry a REAL script (U+0483 Cyrillic titlo, U+0591–05BD Hebrew
    /// points, U+0610–061A Arabic, U+094D Devanagari virama, U+0E31/U+0E34 Thai vowels), so a
    /// classifier absorbing only the two neutral scripts would cut those clusters in half.
    case extend

    /// Whether this class must never START a run — it joins whichever run is already in progress.
    ///
    /// A splitter never consults this directly: `ScriptRunSplitter` learns that a scalar is
    /// absorbing from its injected classifier returning `nil`, because the three formats disagree
    /// about what is neutral (Word's own block table slots ASCII digits to its Latin slot; ODF
    /// declares 22 unmapped gap ranges its consumers are free to treat as weak). This is the shared
    /// floor beneath those three answers: whatever else a format decides, a mark that extends a
    /// cluster cannot be allowed to start a new one.
    var isAbsorbing: Bool {
        switch self {
        case .common, .inherited, .extend: return true
        case .latin, .hangul, .han, .kana, .eastAsianOther, .complex, .other: return false
        }
    }
}

/// The Unicode Script property, read out of a table generated from the UCD and shipped with the app.
///
/// Swift's standard library exposes no `script`, no `scriptExtensions` and no `block` — verified
/// against this toolchain rather than remembered, by dumping the module and enumerating all 58
/// members of `Unicode.Scalar.Properties`. Every runtime route to the real property was measured and
/// rejected: ICU's `u_getIntPropertyValue` is the fastest (1.03 ms/250k) but is an undocumented C API
/// on Apple platforms with an unresolved App Store position, so it stays a TEST-time oracle only;
/// `NLTagger(.script)` returns language-flavoured composite codes (漢字 → `Jpan`, 한국어 → `Kore`),
/// collapses mixed text to one tag, and costs 175–279 ms/250k; and the scalar's own `name` string
/// disagrees with the real Script value on 0.8% of scalars — concentrated in exactly the characters
/// this pass has to get right (U+309B, U+0964 danda, U+064B are all Common or Inherited but named
/// after a script) — while costing 10× a table lookup because every call allocates a `String`.
///
/// Cost of what remains: 4.09 ms per 250,030 scalars, halved to **2.07 ms by the 128-entry ASCII
/// direct table** below, because real documents are ASCII-heavy even when their prose is not. That is
/// 0.4% of the reference HWP's 644 ms read, paid once per document read and never per ⌘+ press.
enum UnicodeScript {
    /// The UCD release the shipped table was generated from. Worth stating out loud because the
    /// platform's own font cascade is built against some UCD too: if the two ever diverge far enough
    /// to matter, this is the number to compare.
    static let unicodeVersion = scriptTableUnicodeVersion

    /// The generated `[UInt8]` widened to the enum once, at first use, rather than per lookup — and
    /// checked while widening, so a table carrying a raw value no case claims fails loudly here
    /// instead of being silently coerced into something plausible at every call site.
    private static let rangeClasses: [ScriptClass] = scriptRangeClasses.map {
        guard let klass = ScriptClass(rawValue: $0) else {
            preconditionFailure("ScriptRanges.swift carries class \($0), which no ScriptClass case "
                                + "claims — regenerate it with Scripts/gen-script-ranges.py")
        }
        return klass
    }

    /// The measured optimisation, and the only one taken: a direct-indexed table for U+0000–U+007F.
    private static let asciiClasses: [ScriptClass] = (0..<128).map { search(UInt32($0)) }

    /// This scalar's class. `@inline(__always)` because the caller is a per-scalar loop over a whole
    /// document and the ASCII branch is most of the work.
    @inline(__always)
    static func of(_ scalar: Unicode.Scalar) -> ScriptClass {
        let value = scalar.value
        return value < 0x80 ? asciiClasses[Int(value)] : search(value)
    }

    /// "Last entry whose start is <= value" over a sorted, gapless table — 11 probes for the 1,790
    /// entries, in a ~9 KB working set that stays in cache. Gapless is what makes this total: there
    /// is no "not found" answer to handle, because entry 0 starts at U+0000 and every scalar up to
    /// U+10FFFF falls inside some entry.
    private static func search(_ value: UInt32) -> ScriptClass {
        var low = 0
        var high = scriptRangeStarts.count - 1
        while low < high {
            let mid = (low + high + 1) >> 1
            if scriptRangeStarts[mid] <= value { low = mid } else { high = mid - 1 }
        }
        return rangeClasses[low]
    }
}
