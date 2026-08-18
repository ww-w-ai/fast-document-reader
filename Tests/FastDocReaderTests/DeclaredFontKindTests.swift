import AppKit
import XCTest
@testable import FastDocReader

/// The rules that decide what KIND of face a declared family asks for. Every case below is a real
/// name from the 265 distinct families a 2,267-document corpus declares and this machine cannot
/// resolve (`docs/06-research/2026-08-18-font-dump-full.md`) — not an invented example, because the
/// two subtleties this classifier exists for were both found by running it against that list and
/// reading what came out wrong.
final class DeclaredFontKindTests: XCTestCase {

    // MARK: - The roots, on real names

    func testAKoreanSerifRootIsReadThroughItsVendorPrefixAndWeightSuffix() {
        // The point of matching the ROOT as a substring: none of these is written down anywhere.
        for name in ["명조", "HY신명조", "HY견명조", "휴먼명조", "한양신명조", "함초롬바탕",
                     "바탕", "바탕체", "KoPub바탕체 Light", "Haansoft Batang"] {
            XCTAssertEqual(DeclaredFontKind.classify(name).kind, .serif, "\(name) declares a serif root")
        }
    }

    func testAKoreanSansRootIsReadTheSameWay() {
        for name in ["맑은 고딕", "HY고딕", "HY중고딕", "한양중고딕", "굴림", "굴림체", "돋움",
                     "돋움체", "함초롬돋움", "KoPub돋움체 Bold", "HCR Dotum"] {
            XCTAssertEqual(DeclaredFontKind.classify(name).kind, .sans, "\(name) declares a sans root")
        }
    }

    /// Found by running the classifier against the real list: a Korean face spelled only in Latin
    /// letters was landing in `.latin` beside genuinely Western names. That is a WRONG fact rather
    /// than a missing one — `.latin` would then offer it a Latin equivalent that cannot draw Hangul.
    func testALatinSpelledKoreanVendorFaceIsNotCalledWestern() {
        for name in ["HYHeadLine-Medium", "HYhaeseo", "HCI Poppy"] {
            let (kind, morpheme) = DeclaredFontKind.classify(name)
            XCTAssertEqual(kind, .unclassified, "\(name) is a Korean vendor face, not a Western one")
            XCTAssertTrue(morpheme.hasPrefix("vendor:"), "the reason should name the vendor rule")
        }
    }

    func testAGenuinelyWesternNameIsLatin() {
        XCTAssertEqual(DeclaredFontKind.classify("Palatino Linotype").kind, .latin)
        XCTAssertEqual(DeclaredFontKind.classify("Book Antiqua").kind, .latin)
    }

    // MARK: - The residue stays unclassified ON PURPOSE

    /// A display or handwriting name says what a face is FOR, not whether it has serifs. Guessing
    /// would be this app contributing judgment the document never gave (invariant 57), so these must
    /// come back `.unclassified` and get today's cascade — 102 of the 265 names, but only 2.4% of the
    /// slots, which is why leaving them alone costs almost nothing.
    func testDisplayAndHandwritingNamesAreLeftAlone() {
        for name in ["HY헤드라인M", "가는각진제목체", "한겨레결체", "강낭콩", "필기", "08서울한강체"] {
            XCTAssertEqual(DeclaredFontKind.classify(name).kind, .unclassified,
                           "\(name) states no kind; the app must not invent one")
            XCTAssertNil(DeclaredFontKind.fallbackFamily(for: name),
                         "an unclassified name must fall through to the existing cascade")
        }
    }

    // MARK: - Order

    func testMonospaceWinsOverTheSansRootItAlsoCarries() {
        // "고정폭 고딕" is a monospace face whose name also contains the sans root. Whichever table is
        // asked first decides, so the order is a behaviour and not an implementation detail.
        XCTAssertEqual(DeclaredFontKind.classify("고정폭 고딕").kind, .mono)
    }

    func testASymbolFaceIsOfferedNothing() {
        // Substituting a text face for a symbol font draws the WRONG CHARACTERS, not the right ones
        // in the wrong style, so there is nothing honest to offer.
        XCTAssertEqual(DeclaredFontKind.classify("Wingdings").kind, .symbol)
        XCTAssertNil(DeclaredFontKind.fallbackFamily(for: "Wingdings"))
    }

    // MARK: - What the chain is allowed to propose

    func testTheProposedTargetsExistOnThisMachineAndDrawWhatTheyAreOfferedFor() {
        // Not a tautology: this is the check that the three names in `systemFamily` are the ones a
        // fresh macOS actually ships. If Apple renames one, this fails here rather than silently
        // sending every Korean document back to the cascade.
        // The spellings differ per family and NSFont(name:) is strict about it — "AppleSDGothicNeo"
        // without spaces returns nil, which is how this test first failed.
        for (name, expectHangul) in [("AppleMyungjo", true), ("Apple SD Gothic Neo", true),
                                     ("AppleGothic", true), ("Menlo", false), ("Palatino", false)] {
            guard let font = NSFont(name: name, size: 12) else {
                return XCTFail("\(name) does not resolve on this machine")
            }
            XCTAssertEqual(draws(font, "가"), expectHangul, "\(name) and Hangul")
            XCTAssertTrue(draws(font, "A"), "\(name) must at least draw Latin")
        }
        // And the map must only ever propose names of that exact form.
        for kind in [DeclaredFontKind.serif, .sans, .mono] {
            let family = kind.systemFamily
            XCTAssertNotNil(family)
            XCTAssertNotNil(NSFont(name: family!, size: 12),
                            "\(family!) is proposed by the map but NSFont(name:) cannot resolve it — "
                            + "the chain would silently do nothing")
        }
    }

    /// A Latin equivalence is an IDENTITY, not a style guess: Palatino Linotype IS Palatino. The
    /// reason it is safe to offer for a name we classified `.latin` is that the caller still runs a
    /// coverage test — and this asserts the half that makes that true, namely that Palatino cannot
    /// draw Hangul and therefore loses on a Korean span rather than stranding it.
    func testTheLatinEquivalentIsOfferedButCannotStrandKoreanText() {
        XCTAssertEqual(DeclaredFontKind.fallbackFamily(for: "Palatino Linotype"), "Palatino")
        guard let palatino = NSFont(name: "Palatino", size: 12) else {
            return XCTFail("Palatino does not resolve on this machine")
        }
        XCTAssertFalse(draws(palatino, "가"),
                       "if this ever passes, the coverage test is the only thing keeping Korean text "
                       + "out of a Latin face, and the argument in the design changes")
    }

    func testAResolvableNameIsStillClassifiedButNeedsNoFallbackInPractice() {
        // Times New Roman and Arial resolve natively here, so they never reach the chain. The
        // classifier still has an opinion about them; what matters is that no equivalence is offered,
        // because offering one would replace a face the machine HAS.
        XCTAssertNil(DeclaredFontKind.equivalentFamily(for: "Times New Roman"))
        XCTAssertNil(DeclaredFontKind.equivalentFamily(for: "Arial"))
        XCTAssertNotNil(NSFont(name: "Times New Roman", size: 12))
        XCTAssertNotNil(NSFont(name: "Arial", size: 12))
    }

    private func draws(_ font: NSFont, _ s: String) -> Bool {
        var units = Array(s.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        _ = CTFontGetGlyphsForCharacters(font as CTFont, &units, &glyphs, units.count)
        return glyphs[0] != 0
    }
}
