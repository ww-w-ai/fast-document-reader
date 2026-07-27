import XCTest
@testable import FastDocReader

/// The generated Unicode script table, checked against three authorities that are not itself.
///
/// A table this size cannot be reviewed by reading it, and a bug in it is invisible on screen — a
/// mis-classified range does not crash or look broken, it just draws a few thousand characters in the
/// wrong document-declared face. So every property it needs is asserted against something that was
/// not involved in generating it: ICU's own `u_getIntPropertyValue` for the script boundaries, the
/// Swift standard library for `Grapheme_Extend` and the variation selectors, and an independent
/// re-implementation of the binary search for the ASCII fast path.
///
/// **ICU is a TEST oracle and must never become the implementation.** It is the fastest route to the
/// real property (1.03 ms/250k against the table's 2.07 ms) and it works — the symbol is exported
/// unversioned from the dyld shared cache because Apple builds with `U_DISABLE_RENAMING`, and the
/// property data is embedded in `libicucore` itself, so it keeps answering with `/usr/share/icu`
/// fully denied. But Apple has never documented the C API, withholds `uscript.h`, and ICU's numeric
/// `UScriptCode` values are not stable across releases; App Store acceptance of linking it is
/// unresolved. Reached here by `dlsym` precisely so that nothing about it can reach the app: no
/// linker flag, no manifest change, no header, nothing for a future build to inherit by accident.
/// It is also why this file never compares raw ICU integers — it asks ICU for the property value's
/// NAME, which is stable across versions, and compares that.
final class ScriptTableTests: XCTestCase {

    // MARK: - The table's own shape

    func testGeneratedClassNamesMatchTheEnumOrder() {
        // The generator stores each range's class as a `ScriptClass` raw value, so the two lists are
        // one contract. If a case is inserted here without regenerating, or CLASS_ORDER is reordered
        // there, every scalar in the table silently changes meaning and nothing else would notice.
        XCTAssertEqual(scriptClassNames, ScriptClass.allCases.map { String(describing: $0) })
        XCTAssertEqual(scriptClassNames.count, ScriptClass.allCases.count)
        for (index, klass) in ScriptClass.allCases.enumerated() {
            XCTAssertEqual(Int(klass.rawValue), index,
                           "ScriptClass.\(klass) must keep raw value \(index)")
        }
    }

    func testTableIsSortedGaplessAndTotal() {
        XCTAssertEqual(scriptRangeStarts.count, scriptRangeClasses.count)
        XCTAssertFalse(scriptRangeStarts.isEmpty)
        XCTAssertEqual(scriptRangeStarts.first, 0, "the table must start at U+0000 to be total")
        for index in 1..<scriptRangeStarts.count {
            XCTAssertLessThan(scriptRangeStarts[index - 1], scriptRangeStarts[index],
                              "starts must be strictly ascending for the binary search to be sound")
        }
        XCTAssertLessThanOrEqual(scriptRangeStarts.last!, 0x10FFFF)
        for raw in scriptRangeClasses {
            XCTAssertNotNil(ScriptClass(rawValue: raw), "table carries unknown class \(raw)")
        }
        // Two adjacent entries with the same class would be a wasted probe. The generator builds
        // this list by scanning its per-scalar class array for MAXIMAL runs, so the property is
        // structural rather than the work of a separate merge step (an explicit `coalesce` pass
        // was written, measured to be incapable of ever firing, and removed) — what this catches
        // is that run-scan itself regressing into emitting one entry per scalar.
        for index in 1..<scriptRangeClasses.count {
            XCTAssertNotEqual(scriptRangeClasses[index - 1], scriptRangeClasses[index],
                              "entries \(index - 1)/\(index) share a class and should be one range")
        }
    }

    func testAsciiFastPathAgreesWithAnIndependentBinarySearch() {
        // The fast path is a second copy of the answer for U+0000-U+007F, so it is a second place to
        // be wrong. Re-derive it here from the raw arrays rather than calling the same code twice.
        for value in UInt32(0)..<128 {
            let scalar = Unicode.Scalar(value)!
            XCTAssertEqual(UnicodeScript.of(scalar), Self.referenceLookup(value),
                           "ASCII fast path disagrees at U+\(String(value, radix: 16, uppercase: true))")
        }
    }

    func testSpotCheckedScalarsLandInTheirScript() {
        // One representative per class, plus the three characters a name-based oracle gets wrong.
        let expected: [(UInt32, ScriptClass, String)] = [
            (0x0041, .latin, "LATIN CAPITAL LETTER A"),
            (0xAC00, .hangul, "HANGUL SYLLABLE GA"),
            (0x4E00, .han, "CJK UNIFIED IDEOGRAPH-4E00"),
            (0x20B9F, .han, "an astral CJK ideograph"),
            (0x3042, .kana, "HIRAGANA LETTER A"),
            (0x30AB, .kana, "KATAKANA LETTER KA"),
            (0x3105, .eastAsianOther, "BOPOMOFO LETTER B"),
            (0x0627, .complex, "ARABIC LETTER ALEF"),
            (0x05D0, .complex, "HEBREW LETTER ALEF"),
            (0x0E01, .complex, "THAI CHARACTER KO KAI"),
            (0x0905, .complex, "DEVANAGARI LETTER A"),
            (0x0410, .other, "CYRILLIC CAPITAL LETTER A"),
            (0x0391, .other, "GREEK CAPITAL LETTER ALPHA"),
            (0xE000, .other, "a private-use scalar — unassigned, and NOT neutral"),
            (0x0020, .common, "SPACE"),
            (0x0031, .common, "DIGIT ONE"),
            (0x1F600, .common, "an emoji"),
            (0x200D, .inherited, "ZERO WIDTH JOINER — Inherited, not Common; absorbed either way"),
            (0x1F1F0, .common, "REGIONAL INDICATOR SYMBOL LETTER K"),
            (0x1F3FD, .common, "EMOJI MODIFIER FITZPATRICK TYPE-4"),
            (0x309B, .common, "KATAKANA-HIRAGANA VOICED SOUND MARK — Common despite the name"),
            (0x0964, .common, "DEVANAGARI DANDA — Common despite the name"),
            (0x0301, .extend, "COMBINING ACUTE ACCENT"),
            (0x0483, .extend, "COMBINING CYRILLIC TITLO — a real script, still absorbed"),
            (0x064B, .extend, "ARABIC FATHATAN"),
            (0x094D, .extend, "DEVANAGARI SIGN VIRAMA"),
            (0x0E34, .extend, "THAI CHARACTER SARA I"),
            (0x05B8, .extend, "HEBREW POINT QAMATS"),
            (0xFE0F, .extend, "VARIATION SELECTOR-16"),
        ]
        for (value, klass, what) in expected {
            let scalar = Unicode.Scalar(value)!
            XCTAssertEqual(UnicodeScript.of(scalar), klass,
                           "U+\(String(value, radix: 16, uppercase: true)) (\(what))")
        }
    }

    // MARK: - Cross-checks against authorities outside the generator

    func testEveryGraphemeExtendScalarIsAbsorbedAndOnlyThose() {
        // The standard library carries `Grapheme_Extend` itself, from the platform's own Unicode
        // data, so this is an independent check that the overlay landed — in BOTH directions,
        // because an overlay that fired too widely would quietly stop real scripts from starting a
        // run at all.
        var missing: [UInt32] = []
        var spurious: [UInt32] = []
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let isExtend = UnicodeScript.of(scalar) == .extend
            let stdlibSaysExtend = scalar.properties.isGraphemeExtend
            if stdlibSaysExtend && !isExtend { missing.append(value) }
            if isExtend && !stdlibSaysExtend { spurious.append(value) }
        }
        XCTAssertEqual(spurious, [], "scalars the table absorbs that are not Grapheme_Extend")
        // The one place the two authorities differ, measured rather than assumed: 39 scalars inside
        // Apple's corporate private-use zone that the platform treats as combining marks and the UCD
        // does not assign at all (see `testAppleCorporateZoneFollowsTheUCDNotThePlatform`). Pinned as
        // an exact set so that a divergence appearing anywhere ELSE — a real overlay bug, or a future
        // OS moving further from the standard — still fails this test.
        XCTAssertEqual(missing, Self.appleCorporateExtendScalars,
                       "Grapheme_Extend divergence outside the known corporate-zone set")
    }

    func testEveryVariationSelectorIsAbsorbing() {
        // A variation selector changes which glyph CoreText picks for the character BEFORE it
        // (`FontSubstitutionCache.followingVariationSelector` already depends on this), so letting
        // one start a piece would separate it from the character it modifies. They are absorbing
        // TWICE OVER — every one of them is Script=Inherited in the UCD (`Scripts.txt`: FE00..FE0F
        // and E0100..E01EF) *and* Grapheme_Extend — so this cannot fail while `.inherited` absorbs,
        // whatever the overlay does. That redundancy is the point: it pins the OUTCOME the rest of
        // the pipeline depends on rather than the particular rule that currently delivers it.
        var notAbsorbed: [UInt32] = []
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value), scalar.properties.isVariationSelector else { continue }
            if !UnicodeScript.of(scalar).isAbsorbing { notAbsorbed.append(value) }
        }
        XCTAssertEqual(notAbsorbed, [], "variation selectors that could start a piece")
    }

    func testTableAgreesWithICUOverEveryScalar() throws {
        let icu = try XCTUnwrap(ICUScriptOracle(), """
            libicucore did not export u_getIntPropertyValue/u_getPropertyValueName in this process. \
            That is a real finding, not a reason to pass: the cross-check has no oracle and the \
            generated table is unverified against anything outside its own generator.
            """)

        // Compared by NAME, never by ICU's numeric UScriptCode — those are not stable across ICU
        // releases and Apple bumps ICU with the OS. Only the classes the generator DERIVES are
        // checked exactly; `complex` and `eastAsianOther` are curated refinements of `other`, so
        // what is asserted for them is the part that matters — that no real script leaks INTO a
        // derived class, and that the curated ones never claim a script the derived ones own.
        var disagreements: [UInt32] = []
        var kinds: Set<String> = []
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }  // surrogates are not scalars
            let ours = UnicodeScript.of(scalar)
            if ours == .extend { continue }  // the overlay hides the script; checked above instead
            let theirs = icu.scriptName(of: value)
            let expected: ScriptClass?
            switch theirs {
            case "Latin": expected = .latin
            case "Hangul": expected = .hangul
            case "Han": expected = .han
            case "Hiragana", "Katakana": expected = .kana
            case "Common": expected = .common
            case "Inherited": expected = .inherited
            case "Unknown": expected = .other
            default: expected = nil    // a real script we do not name individually
            }
            let agrees = expected.map { $0 == ours }
                ?? ![.latin, .hangul, .han, .kana, .common, .inherited].contains(ours)
            if !agrees {
                disagreements.append(value)
                kinds.insert("ICU=\(theirs) ours=\(ours)")
            }
        }
        XCTAssertEqual(disagreements, Array(Self.appleCorporateZone), """
            table (UCD \(UnicodeScript.unicodeVersion)) disagrees with ICU (Unicode \
            \(icu.unicodeVersion)) somewhere other than the corporate private-use zone. If those \
            two versions differ, regenerate the table before reading this as a generation bug.
            """)
        XCTAssertEqual(kinds, ["ICU=Common ours=other"],
                       "the corporate zone should differ in exactly one way")
    }

    func testAppleCorporateZoneFollowsTheUCDNotThePlatform() {
        // A measured, deliberate divergence, recorded here so it is a known gap rather than a silent
        // one. Apple's Unicode data assigns properties inside U+F7F0–U+F8FF — the corporate private
        // use zone AppKit itself draws on (`NSUpArrowFunctionKey` is U+F700) — that the standard does
        // not: all 272 of those scalars come back Script=Common from ICU, and 39 of them come back
        // Grapheme_Extend from the standard library. The UCD assigns none of it.
        //
        // The table follows the UCD, so those scalars are `other`: a real, if unknown, identity that
        // can begin a piece. That is the conservative reading — the alternative, absorbing them,
        // would mean a reader silently deciding that a character it knows nothing about wants the
        // neighbouring run's typeface, on the authority of one platform's private extension. A format
        // whose own specification says otherwise says so in its own classifier (ODF names the private
        // use areas among its 22 unmapped gap ranges and leaves them to the consumer), which is
        // exactly why the splitter takes `classify` as an argument.
        for value in Self.appleCorporateZone {
            let scalar = Unicode.Scalar(value)!
            XCTAssertEqual(UnicodeScript.of(scalar), .other, "U+\(Self.hex(value))")
            XCTAssertFalse(UnicodeScript.of(scalar).isAbsorbing, "U+\(Self.hex(value))")
        }
    }

    // MARK: - Helpers

    /// Apple's corporate private-use zone, as far as its Unicode data actually diverges from the
    /// standard — measured, not guessed at from the zone's nominal bounds.
    private static let appleCorporateZone: ClosedRange<UInt32> = 0xF7F0...0xF8FF

    /// The 39 corporate-zone scalars the platform reports as `Grapheme_Extend` and the UCD does not
    /// assign at all. Apple uses them as transcoding hints for round-tripping legacy encodings.
    private static let appleCorporateExtendScalars: [UInt32] =
        Array(0xF870...0xF87F) + Array(0xF884...0xF899) + [0xF89F]

    private static func hex(_ value: UInt32) -> String {
        String(value, radix: 16, uppercase: true)
    }

    /// The binary search, written again from the raw arrays, so the ASCII fast-path check is not
    /// comparing `UnicodeScript.of` with itself.
    private static func referenceLookup(_ value: UInt32) -> ScriptClass {
        var found = 0
        for (index, start) in scriptRangeStarts.enumerated() where start <= value { found = index }
        return ScriptClass(rawValue: scriptRangeClasses[found])!
    }
}
