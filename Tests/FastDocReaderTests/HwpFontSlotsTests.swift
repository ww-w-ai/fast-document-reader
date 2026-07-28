import XCTest
@testable import FastDocReader

/// The HWP slot classifier and its fallback chain, as pure functions.
///
/// These prove the CLASSIFIER. They deliberately do not prove that the reader reaches it — that is
/// invariant 29's distinction, and it is covered separately by `HwpMappingTests`' cases that go
/// through `HwpReader.mapJSON` and by `HwpParserRebuildParityTests`' dump through the real
/// `HwpReader.read`.
final class HwpFontSlotsTests: XCTestCase {

    private func slot(_ s: Unicode.Scalar) -> HwpFontSlot? { HwpSlotTable.slot(for: s) }
    private func slot(_ v: UInt32) -> HwpFontSlot? { HwpSlotTable.slot(for: Unicode.Scalar(v)!) }

    // MARK: the four named writing systems

    func testTheFourNamedWritingSystemsSelectTheirOwnSlots() {
        XCTAssertEqual(slot("한"), .hangul)
        XCTAssertEqual(slot("ㄱ"), .hangul)          // compatibility jamo
        XCTAssertEqual(slot("A"), .latin)
        XCTAssertEqual(slot("é"), .latin)            // Latin-1 supplement
        XCTAssertEqual(slot("ʃ"), .latin)            // IPA extensions — rhwp sends these to Hangul
        XCTAssertEqual(slot("漢"), .hanja)
        XCTAssertEqual(slot(0x3400), .hanja)         // CJK Ext-A
        XCTAssertEqual(slot(0x2A700), .hanja)        // CJK Ext-C — rhwp stops at Ext-B
        XCTAssertEqual(slot("あ"), .japanese)
        XCTAssertEqual(slot("ア"), .japanese)
        XCTAssertEqual(slot(0xFF71), .japanese)      // halfwidth katakana — rhwp sends this to Hangul
    }

    /// The whole reason this classifier exists rather than rhwp's: its catch-all is `_ => 0`, the
    /// KOREAN slot, so every one of these used to be drawn in the document's Hangul face. HWP's
    /// "기타/Other" slot is exactly what they belong in.
    func testEveryOtherRealScriptGoesToTheOtherSlotAndNotToHangul() {
        for (name, scalar) in [("Cyrillic", "Ж" as Unicode.Scalar), ("Greek", "Ω"),
                               ("Arabic", "ع"), ("Hebrew", "א"), ("Thai", "ก"),
                               ("Devanagari", "क"), ("Armenian", "Ա"), ("Georgian", "ა")] {
            XCTAssertEqual(slot(scalar), .other, "\(name) must select the Other slot, not Hangul")
        }
        XCTAssertEqual(slot(0x3105), .other, "Bopomofo — below rhwp's Hangul arm, so it fell to slot 0")
    }

    // MARK: absorption — the shared floor

    func testAbsorbingScalarsNeverStartAPiece() {
        XCTAssertNil(slot(" "))
        XCTAssertNil(slot("1"), "a digit is Common; breaking on it would split 제1항")
        XCTAssertNil(slot("("))
        XCTAssertNil(slot("\t"))
        XCTAssertNil(slot(0x0301), "combining acute — Grapheme_Extend")
        XCTAssertNil(slot(0x0483), "Cyrillic titlo — Grapheme_Extend carrying a REAL script")
        XCTAssertNil(slot(0x094D), "Devanagari virama")
        XCTAssertNil(slot(0x0E31), "Thai vowel above")
        XCTAssertNil(slot(0x200D), "ZWJ — Inherited, joins emoji sequences")
        XCTAssertNil(slot(0xFE0F), "VS16")
        XCTAssertNil(slot(0x1F1F0), "regional indicator — Common")
        XCTAssertNil(slot(0x0964), "Devanagari danda — Common despite the name")
    }

    /// `U+3000`–`U+303F` is rhwp's slot-5 territory and is deliberately NOT excepted here: its first
    /// code point is a SPACE, and a space taking a different typeface from the words around it is the
    /// failure both other classifiers in this codebase were corrected to avoid.
    func testCjkPunctuationIsAbsorbedRatherThanSentToTheSymbolSlot() {
        XCTAssertNil(slot(0x3000), "IDEOGRAPHIC SPACE must never start a piece")
        XCTAssertNil(slot("、"))
        XCTAssertNil(slot("。"))
        XCTAssertNil(slot("「"))
        XCTAssertNil(slot(0x2014), "em dash — general punctuation")
    }

    // MARK: the two measured decisions

    func testTheNarrowSymbolListSelectsTheSymbolSlot() {
        XCTAssertEqual(slot("■"), .symbol)
        XCTAssertEqual(slot("□"), .symbol)
        XCTAssertEqual(slot("○"), .symbol)
        XCTAssertEqual(slot("◆"), .symbol)
        XCTAssertEqual(slot(0x2500), .symbol, "box drawing")
        XCTAssertEqual(slot(0x2580), .symbol, "block elements")
        XCTAssertEqual(slot("→"), .symbol)
        XCTAssertEqual(slot(0x2714), .symbol, "dingbat")
    }

    /// Measured, not assumed: `U+318D` occurs 3,153 times in the corpus, and routing it to the User
    /// slot costs 1.79 extra pieces per character re-faced against the symbol rule's 0.12. It is
    /// Script=Hangul and it does a separator's job inside Hangul prose, so it stays with its text.
    func testAraeaStaysInTheHangulSlotSoTheUserSlotIsUnreachable() {
        XCTAssertEqual(slot(0x318D), .hangul)
        for v in UInt32(0)...0x2FFF {
            if let s = Unicode.Scalar(v) { XCTAssertNotEqual(slot(s), .user) }
        }
        for v in UInt32(0x3000)...0x33FF {
            if let s = Unicode.Scalar(v) { XCTAssertNotEqual(slot(s), .user) }
        }
    }

    // MARK: the fallback chain

    func testFallbackChainPrefersTheSlotThenHangulThenLatinThenAnything() {
        let row = HwpSlotFonts(row: ["KO", "LA", "", "", "", "", ""])
        XCTAssertEqual(row.family(.hangul), "KO")
        XCTAssertEqual(row.family(.latin), "LA")
        XCTAssertEqual(row.family(.hanja), "KO", "empty slot falls back to Hangul first")
        XCTAssertEqual(row.family(.other), "KO")

        let noHangul = HwpSlotFonts(row: ["", "LA", "", "", "", "", ""])
        XCTAssertEqual(noHangul.family(.hangul), "LA", "slot 0 empty → slot 1")
        XCTAssertEqual(noHangul.family(.hanja), "LA")

        let onlyHanja = HwpSlotFonts(row: ["", "", "HANJA", "", "", "", ""])
        XCTAssertEqual(onlyHanja.family(.hangul), "HANJA", "slots 0 and 1 empty → first non-empty")
        XCTAssertEqual(onlyHanja.neutralFamily, "HANJA")
    }

    /// Never a hardcoded family: a row naming nothing resolves to `nil`, which downstream means the
    /// theme's own body font — exactly what this reader drew before per-slot fonts existed.
    func testARowNamingNothingResolvesToNilAndIsUniform() {
        let empty = HwpSlotFonts(row: ["", "", "", "", "", "", ""])
        XCTAssertNil(empty.family(.hangul))
        XCTAssertNil(empty.family(.symbol))
        XCTAssertNil(empty.neutralFamily)
        XCTAssertTrue(empty.isUniform)
        XCTAssertTrue(HwpSlotFonts(row: []).isUniform, "a short/absent row must not trap")
        XCTAssertNil(HwpSlotFonts(row: []).family(.user))
    }

    func testIsUniformIsAboutResolvedFamiliesNotDeclaredOnes() {
        XCTAssertTrue(HwpSlotFonts(row: ["A", "A", "A", "A", "A", "A", "A"]).isUniform)
        // Declared in one slot only, but every other slot FALLS BACK to it, so no character can
        // select anything different — this is the byte-identical fast path.
        XCTAssertTrue(HwpSlotFonts(row: ["A", "", "", "", "", "", ""]).isUniform)
        XCTAssertFalse(HwpSlotFonts(row: ["A", "B", "", "", "", "", ""]).isUniform)
    }

    /// The real row from the survey this whole feature exists for.
    func testTheSurveysRealRowResolvesPerScript() {
        let row = HwpSlotFonts(row: ["휴먼명조", "Palatino Linotype", "HY신명조", "HY신명조",
                                     "HY신명조", "HY신명조", "HY견명조"])
        XCTAssertFalse(row.isUniform)
        XCTAssertEqual(row.family(.hangul), "휴먼명조")
        XCTAssertEqual(row.family(.latin), "Palatino Linotype")
        XCTAssertEqual(row.family(.hanja), "HY신명조")
    }

    // MARK: the splitter, driven by THIS classifier

    private func split(_ text: String, _ row: [String]) -> [(String, String?)] {
        let fonts = HwpSlotFonts(row: row)
        return ScriptRunSplitter.split(text, classify: HwpSlotTable.slot(for:), family: fonts.family)
            .map { (String($0.text), $0.family) }
    }

    func testMixedKoreanAndLatinSplitsWhereTheFamilyChanges() {
        let row = ["휴먼명조", "Palatino Linotype", "", "", "", "", ""]
        XCTAssertEqual(split("이상무 KDI 전문위원", row).map(\.0),
                       ["이상무 ", "KDI ", "전문위원"])
        XCTAssertEqual(split("이상무 KDI 전문위원", row).map(\.1),
                       ["휴먼명조", "Palatino Linotype", "휴먼명조"])
    }

    /// The load-bearing rule: break on the resolved FAMILY, never on the slot index. Both slots name
    /// one face here, so the run stays whole even though it alternates writing systems.
    func testAlternatingScriptsStayWholeWhenBothSlotsNameOneFace() {
        XCTAssertEqual(split("제1항 2026년 (3)", ["A", "A", "A", "A", "A", "A", "A"]).count, 1)
        XCTAssertEqual(split("이상무 KDI 전문위원", ["A", "", "", "", "", "", ""]).count, 1)
    }

    func testDigitsAndPunctuationRideTheNeighbourRatherThanSplitting() {
        let row = ["KO", "LA", "", "", "", "", ""]
        XCTAssertEqual(split("제1항", row).map(\.0), ["제1항"], "digits are absorbed")
        XCTAssertEqual(split("가나 (다라)", row).map(\.0), ["가나 (다라)"])
    }

    func testSymbolBulletTakesTheSymbolFamily() {
        let row = ["KO", "LA", "", "", "", "SYM", ""]
        XCTAssertEqual(split("■ 항목", row).map(\.1), ["SYM", "KO"])
    }

    /// Design §8.3, on every case this file has: no piece is empty and the pieces reproduce the
    /// source exactly. The corpus probe asserts the same two properties over 11.3 M characters.
    func testPiecesAreNonEmptyAndConcatenateToTheSource() {
        let rows = [["KO", "LA", "HANJA", "JP", "OTH", "SYM", "U"], ["A", "B", "", "", "", "", ""]]
        let texts = ["이상무 KDI 전문위원", "제1항 2026년", "漢字とかなとHangul한글",
                     "Привет мир", "■ 항목 → 결과", "e\u{0301}gale", "👨‍👩‍👧 family",
                     "🇰🇷 flag", "\u{20B9F} astral", "   ", "", "ㆍ가ㆍ나ㆍ"]
        for row in rows {
            for text in texts {
                let pieces = split(text, row)
                XCTAssertEqual(pieces.map(\.0).joined(), text, "round-trip failed for \(text.debugDescription)")
                XCTAssertFalse(pieces.contains { $0.0.isEmpty }, "empty piece for \(text.debugDescription)")
            }
        }
    }

    /// Clusters must never be cut, which is what the `extend` class in the shared table buys.
    func testGraphemeClustersAreNeverSplit() {
        let row = ["KO", "LA", "", "", "", "", ""]
        XCTAssertEqual(split("e\u{0301}", row).count, 1, "base + combining acute is one piece")
        XCTAssertEqual(split("👨‍👩‍👧", row).count, 1, "a ZWJ family is one piece")
        XCTAssertEqual(split("🇰🇷", row).count, 1, "a regional-indicator pair is one piece")
        XCTAssertEqual(split("A\u{0483}", row).count, 1, "a Cyrillic titlo on a Latin base")
    }
}
