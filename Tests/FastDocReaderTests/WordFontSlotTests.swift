import XCTest
@testable import FastDocReader

/// `WordFontBlockTable`, `WordThemeFonts` and `WordRFonts` hold no XML and touch no archive, so
/// every rule in them is assertable directly. The point of testing them here rather than only
/// through `DocxReader` is that the table's most surprising rows — the six that send right-to-left
/// scripts to the slot named `ascii` — are the ones a future reader is most likely to "fix", and a
/// document-level test would only say the output changed, not which row said so.
final class WordFontSlotTests: XCTestCase {
    private func slot(_ scalar: Unicode.Scalar, hint: Bool = false) -> WordFontSlot? {
        WordFontBlockTable.slot(for: scalar, hintsEastAsia: hint)?.slot
    }

    private func script(_ scalar: Unicode.Scalar) -> String?? {
        WordFontBlockTable.slot(for: scalar, hintsEastAsia: false).map { $0.script }
    }

    // MARK: the block table

    func testBasicLatinSelectsAsciiAndEastAsianBlocksSelectEastAsia() {
        XCTAssertEqual(slot("A"), .ascii)
        XCTAssertEqual(slot("z"), .ascii)
        XCTAssertEqual(slot("가"), .eastAsia)       // Hangul Syllables AC00–D7AF
        XCTAssertEqual(slot("ᄀ"), .eastAsia)       // Hangul Jamo 1100–11FF
        XCTAssertEqual(slot("ㄱ"), .eastAsia)       // Hangul Compatibility Jamo 3130–318F
        XCTAssertEqual(slot("漢"), .eastAsia)       // CJK Unified Ideographs
        XCTAssertEqual(slot("あ"), .eastAsia)       // Hiragana
        XCTAssertEqual(slot("ア"), .eastAsia)       // Katakana
        XCTAssertEqual(slot("Ａ"), .eastAsia)       // Halfwidth and Fullwidth Forms
    }

    /// The rows this project is most likely to be "corrected" on. MS-OI29500 §17.3.2.26 classifies
    /// Hebrew, Arabic, Syriac, Arabic Supplement, Thaana and both Arabic Presentation Forms blocks
    /// as **ascii** — six separate rows saying the same thing, which is why it is the table's rule
    /// and not a transcription slip. A reader that sent them to `cs` "because they are complex
    /// scripts" would not be doing what Word does.
    func testRightToLeftBlocksSelectAsciiWhichIsCounterIntuitiveAndCorrect() {
        XCTAssertEqual(slot("\u{05D0}"), .ascii)   // Hebrew alef
        XCTAssertEqual(slot("\u{0627}"), .ascii)   // Arabic alef
        XCTAssertEqual(slot("\u{0710}"), .ascii)   // Syriac
        XCTAssertEqual(slot("\u{0750}"), .ascii)   // Arabic Supplement
        XCTAssertEqual(slot("\u{0780}"), .ascii)   // Thaana
        XCTAssertEqual(slot("\u{FB1D}"), .ascii)   // Hebrew presentation forms, inside FB00–FB4F
        XCTAssertEqual(slot("\u{FB50}"), .ascii)   // Arabic Presentation Forms-A
        XCTAssertEqual(slot("\u{FE70}"), .ascii)   // Arabic Presentation Forms-B
    }

    /// No row classifies to `cs`, so no character can select it. The complex-script slot is reached
    /// only by the run-level `w:cs`/`w:rtl` toggle — asserted here over the whole BMP rather than by
    /// reading the table, because "I looked and there is no such row" is exactly the kind of claim
    /// that stops being true when someone adds one.
    func testNoCharacterAnywhereSelectsTheComplexScriptSlot() {
        for value in UInt32(0)...0xFFFF {
            for hint in [false, true] {
                XCTAssertNotEqual(WordFontBlockTable.slot(forValue: value, hintsEastAsia: hint), .cs,
                                  "U+\(String(value, radix: 16, uppercase: true)) hint=\(hint)")
            }
        }
        XCTAssertNotEqual(WordFontBlockTable.slot(forValue: 0x1F600, hintsEastAsia: false), .cs)
    }

    /// Thai, Devanagari and every other Indic block are absent from the table, so they take the
    /// spec's own catch-all. This is the row that does not exist, and it decides what happens to
    /// most of the world's scripts.
    func testScriptsAbsentFromTheTableFallToTheHAnsiCatchAll() {
        XCTAssertEqual(slot("\u{0E01}"), .hAnsi)   // Thai
        XCTAssertEqual(slot("\u{0915}"), .hAnsi)   // Devanagari
        XCTAssertEqual(slot("\u{0985}"), .hAnsi)   // Bengali
        XCTAssertEqual(slot("\u{10A0}"), .hAnsi)   // Georgian
        XCTAssertEqual(slot("\u{1200}"), .hAnsi)   // Ethiopic
    }

    /// Twenty-three of the table's rows do nothing at all unless `w:hint="eastAsia"` is present —
    /// and `w:hint` rides on 42.9% of the `w:rFonts` in this project's corpus. Asserted against the
    /// TABLE, not the classifier, because absorption sits in front of the classifier and decides
    /// separately whether a given character ever gets to ask (see the test below).
    func testHintConditionalRowsChangeAnswerOnlyWhenTheHintIsPresent() {
        for value: UInt32 in [0x03B1, 0x0410, 0x2018, 0x2192, 0x25A0, 0x2600, 0x02B0, 0xE000, 0x2E80, 0xFB00] {
            XCTAssertEqual(WordFontBlockTable.slot(forValue: value, hintsEastAsia: false), .hAnsi,
                           "unhinted U+\(String(value, radix: 16, uppercase: true))")
            XCTAssertEqual(WordFontBlockTable.slot(forValue: value, hintsEastAsia: true), .eastAsia,
                           "hinted U+\(String(value, radix: 16, uppercase: true))")
        }
    }

    /// A consequence of absorbing script-neutral characters, pinned so it is a known property rather
    /// than a surprise: the hint-conditional rows for the SYMBOL and PUNCTUATION blocks can never
    /// fire, because every character in them is Script=Common and absorbs into its neighbour before
    /// the table is consulted. What that costs is a curly quote or an arrow beside Latin text
    /// drawing in the Latin family where Word, given the hint, would use the East Asian one; beside
    /// Korean text — the context these documents are actually in — absorption reaches Word's own
    /// answer by riding along with the Hangul.
    ///
    /// The rows that DO survive absorption are the ones whose blocks hold real scripts, and the hint
    /// is fully live for them.
    func testTheHintStaysLiveForRealScriptsAndIsUnreachableForSymbolBlocks() {
        for scalar: Unicode.Scalar in ["\u{03B1}", "\u{0410}", "\u{E000}", "\u{2E80}", "\u{FB00}"] {
            XCTAssertEqual(slot(scalar), .hAnsi, "U+\(String(scalar.value, radix: 16, uppercase: true))")
            XCTAssertEqual(slot(scalar, hint: true), .eastAsia, "U+\(String(scalar.value, radix: 16, uppercase: true))")
        }
        for scalar: Unicode.Scalar in ["\u{2018}", "\u{2192}", "\u{25A0}", "\u{2600}", "\u{20A0}"] {
            XCTAssertNil(slot(scalar, hint: true), "U+\(String(scalar.value, radix: 16, uppercase: true)) absorbs first")
        }
    }

    /// Latin-1 Supplement is one published row with a scattered exception list. Both halves matter:
    /// the listed code points move under the hint, and the ones beside them do not.
    func testLatin1SupplementMovesOnlyTheCodePointsTheTableLists() {
        for value: UInt32 in [0xA1, 0xA4, 0xA7, 0xA8, 0xAA, 0xAD, 0xAF, 0xB0, 0xB4, 0xB6, 0xBA, 0xBC, 0xBF, 0xD7, 0xF7] {
            XCTAssertEqual(WordFontBlockTable.slot(forValue: value, hintsEastAsia: true), .eastAsia,
                           "U+\(String(value, radix: 16, uppercase: true)) should move under the hint")
            XCTAssertEqual(WordFontBlockTable.slot(forValue: value, hintsEastAsia: false), .hAnsi)
        }
        for value: UInt32 in [0xA0, 0xA2, 0xA3, 0xA5, 0xA6, 0xA9, 0xAB, 0xAE, 0xB5, 0xBB, 0xC0, 0xD6, 0xF8, 0xFF] {
            XCTAssertEqual(WordFontBlockTable.slot(forValue: value, hintsEastAsia: true), .hAnsi,
                           "U+\(String(value, radix: 16, uppercase: true)) is not in the exception list")
        }
    }

    /// The published table is written in UTF-16 and classifies all three surrogate ranges as
    /// eastAsia, which makes every astral character eastAsia to a UTF-16 reader. This pass walks
    /// scalars and never sees a surrogate, so following the spec's letter is a decision, taken
    /// deliberately — see `WordFontBlockTable.slot(forValue:hintsEastAsia:)`.
    func testAstralCharactersTakeEastAsiaFollowingTheSpecsUTF16Letter() {
        XCTAssertEqual(slot("\u{20B9F}"), .eastAsia)   // CJK Ext-B — the case the rule is written for
        XCTAssertEqual(slot("\u{10400}"), .eastAsia)   // Deseret, nothing East Asian about it
        // Emoji reach the same row but never ask: they are Script=Common and absorb, which is what
        // keeps a ZWJ sequence or a skin-tone modifier whole with no special casing.
        XCTAssertEqual(WordFontBlockTable.slot(forValue: 0x1F600, hintsEastAsia: false), .eastAsia)
        XCTAssertNil(slot("\u{1F600}"))
        XCTAssertEqual(WordFontBlockTable.slot(forValue: 0xD800, hintsEastAsia: false), .eastAsia)
        XCTAssertEqual(WordFontBlockTable.slot(forValue: 0xDFFF, hintsEastAsia: false), .eastAsia)
    }

    // MARK: absorption

    /// Absorption is what stops a piece boundary landing inside a grapheme cluster. The two that
    /// would break WITHOUT it are worth naming: Word puts a Latin letter in `ascii` and the
    /// combining accent on it in `hAnsi`, and puts both halves of a ZWJ emoji pair in `eastAsia`
    /// while the joiner between them is `hAnsi`.
    func testClusterMachineryNeverStartsAPiece() {
        XCTAssertNil(slot("\u{0301}"), "combining acute")
        XCTAssertNil(slot("\u{200D}"), "zero width joiner")
        XCTAssertNil(slot("\u{FE0F}"), "variation selector-16")
        XCTAssertNil(slot("\u{0483}"), "Cyrillic titlo — a real script, still Grapheme_Extend")
        XCTAssertNil(slot("\u{094D}"), "Devanagari virama")
    }

    /// Script-neutral characters absorb too. This is the rule measurement chose over classifying
    /// them by the table — see `WordFontBlockTable.slot(for:hintsEastAsia:)` for the numbers and for
    /// what it costs.
    func testScriptNeutralCharactersAbsorbRatherThanStartingAPiece() {
        XCTAssertNil(slot(" "), "space")
        XCTAssertNil(slot("1"), "ASCII digit")
        XCTAssertNil(slot("("), "ASCII punctuation")
        XCTAssertNil(slot("\u{3001}"), "ideographic comma — the CJK case the choice turned on")
        XCTAssertNil(slot("\u{3000}"), "ideographic space")
    }

    // MARK: script keys into the theme's own list

    func testScriptKeysAreDerivedOnlyWhereOneCodeIsUnambiguous() {
        XCTAssertEqual(script("가"), .some("Hang"))
        XCTAssertEqual(script("A"), .some("Latn"))
        XCTAssertEqual(script("あ"), .some("Jpan"))
        XCTAssertEqual(script("ア"), .some("Jpan"))
        // The recorded gap: Hans, Hant and Jpan all use Han, and only the document's language tells
        // them apart. Guessing would mis-render two of the three.
        XCTAssertEqual(script("漢"), .some(nil))
    }

    // MARK: theme font scheme

    private func koreanOfficeTheme() -> WordThemeFonts {
        // The shape measured in five of five real themes: the East Asian and complex-script
        // defaults are EMPTY and the per-script list carries the real families.
        var fonts = WordThemeFonts()
        fonts.minor.latin = "맑은 고딕"
        fonts.minor.eastAsian = nil
        fonts.minor.complex = nil
        fonts.minor.byScript = ["Hang": "맑은 고딕", "Jpan": "ＭＳ 明朝", "Arab": "Arial", "Thai": "Angsana New"]
        fonts.major.latin = "맑은 고딕 Semilight"
        fonts.major.byScript = ["Hang": "맑은 고딕 Semilight"]
        return fonts
    }

    /// The finding this whole unit turns on: reading only `a:latin`/`a:ea`/`a:cs` resolves
    /// `minorEastAsia` to nothing on a real Korean theme, because `a:ea` is empty and the family
    /// lives in the `a:font script="Hang"` entry.
    func testEastAsiaThemeReferenceResolvesThroughTheScriptListNotTheEmptyDefault() {
        let theme = koreanOfficeTheme()
        XCTAssertEqual(theme.family(forThemeRef: "minorEastAsia", script: "Hang"), "맑은 고딕")
        XCTAssertNil(theme.family(forThemeRef: "minorEastAsia", script: nil),
                     "with no script key there is only the empty a:ea to fall back to")
    }

    func testAsciiAndHAnsiThemeReferencesShareTheLatinDefaultAndMajorPicksTheMajorScheme() {
        let theme = koreanOfficeTheme()
        XCTAssertEqual(theme.family(forThemeRef: "minorAscii", script: nil), "맑은 고딕")
        XCTAssertEqual(theme.family(forThemeRef: "minorHAnsi", script: nil), "맑은 고딕")
        XCTAssertEqual(theme.family(forThemeRef: "majorHAnsi", script: nil), "맑은 고딕 Semilight")
        XCTAssertEqual(theme.family(forThemeRef: "majorEastAsia", script: "Hang"), "맑은 고딕 Semilight")
    }

    func testAnUnknownOrAbsentThemeReferenceResolvesToNothingRatherThanAFabricatedFamily() {
        XCTAssertNil(koreanOfficeTheme().family(forThemeRef: "notAThemeSlot", script: "Hang"))
        XCTAssertNil(WordThemeFonts().family(forThemeRef: "minorHAnsi", script: "Latn"))
    }

    // MARK: per-slot declarations

    /// MS-OI29500 note e, at the level of one element: a theme reference and a literal on the same
    /// `w:rFonts` are not two answers to average — the theme reference wins outright.
    func testASlotHoldsOneCellSoALiteralAndAThemeReferenceCannotBothSurvive() {
        var decl = WordRFonts()
        decl.eastAsia = .theme("minorEastAsia")
        XCTAssertEqual(decl.family(for: .eastAsia, script: "Hang", theme: koreanOfficeTheme()), "맑은 고딕")
        decl.eastAsia = .literal("바탕")
        XCTAssertEqual(decl.family(for: .eastAsia, script: "Hang", theme: koreanOfficeTheme()), "바탕")
    }

    /// Word's legacy exception. `eastAsia="Times New Roman"` is the value Word writes when nobody
    /// ever set an East Asian font, so when the two Latin slots agree it is read as "not set".
    func testTheLegacyTimesNewRomanExceptionBorrowsTheAsciiDeclaration() {
        var decl = WordRFonts()
        decl.ascii = .literal("Georgia")
        decl.hAnsi = .literal("Georgia")
        decl.eastAsia = .literal("Times New Roman")
        XCTAssertEqual(decl.effectiveSlot(.eastAsia), .ascii)
        XCTAssertEqual(decl.family(for: .eastAsia, script: "Hang", theme: WordThemeFonts()), "Georgia")
    }

    func testTheLegacyExceptionDoesNotFireWhenTheTwoLatinSlotsDisagree() {
        var decl = WordRFonts()
        decl.ascii = .literal("Georgia")
        decl.hAnsi = .literal("Calibri")
        decl.eastAsia = .literal("Times New Roman")
        XCTAssertEqual(decl.effectiveSlot(.eastAsia), .eastAsia)
        XCTAssertEqual(decl.family(for: .eastAsia, script: "Hang", theme: WordThemeFonts()), "Times New Roman")
    }

    func testTheLegacyExceptionDoesNotFireForAnyOtherEastAsianFamily() {
        var decl = WordRFonts()
        decl.ascii = .literal("Georgia")
        decl.hAnsi = .literal("Georgia")
        decl.eastAsia = .literal("바탕")
        XCTAssertEqual(decl.effectiveSlot(.eastAsia), .eastAsia)
        XCTAssertEqual(decl.family(for: .eastAsia, script: "Hang", theme: WordThemeFonts()), "바탕")
    }

    func testASlotNobodyDeclaredResolvesToNothingAndNeverToAHardcodedFamily() {
        XCTAssertNil(WordRFonts().family(for: .ascii, script: "Latn", theme: koreanOfficeTheme()))
        XCTAssertTrue(WordRFonts().isEmpty)
    }
}
