import XCTest
import AppKit
@testable import FastDocReader

/// The per-script slots the THEME never had (invariant 93).
///
/// An office document names its own face per script — HWP carries seven slots, docx four, ODF three,
/// and 53.6% of real HWPs genuinely declare different fonts across them (invariant 53). Markdown and
/// plain text have no document to declare anything, so the theme put one font on everything and
/// AppKit fixed the result per CHARACTER: Hangul moved to a Korean face while every space between
/// the words stayed behind on the system font, cutting a run at nearly every word.
///
/// These assert the three halves of the rule that replaced that, on strings built by hand so the
/// question is about the rule and not about any renderer's own output.
final class ThemeScriptSlotTests: XCTestCase {
    private let systemFont = NSFont.systemFont(ofSize: 13)

    private func fontRuns(_ string: NSAttributedString) -> [(NSRange, NSFont?)] {
        var out: [(NSRange, NSFont?)] = []
        string.enumerateAttribute(.font, in: NSRange(location: 0, length: string.length), options: []) {
            value, range, _ in out.append((range, value as? NSFont))
        }
        return out
    }

    /// The whole point, stated as the thing that was wrong: the spaces BETWEEN Korean words must not
    /// each become their own run. A character with no script of its own joins the run in progress.
    func testSpacesBetweenKoreanWordsDoNotCutTheRun() {
        let string = NSMutableAttributedString(string: "행정 업무 운영 편람",
                                               attributes: [.font: systemFont])
        let edits = FontSubstitutionResolver.applySubstitutions(to: string)

        XCTAssertGreaterThan(edits, 0, "the system font draws no Hangul, so this must substitute")
        XCTAssertEqual(fontRuns(string).count, 1,
                       "Hangul words and the spaces between them are ONE run — a run per word is the "
                       + "defect invariant 93 measured at 246,900 runs on a 370k-character document")
    }

    /// The reason this is SLOTS and not one blanket substitution: a theme font that draws Latin keeps
    /// the Latin. English inside a Korean document stays in the face the theme chose for it, which is
    /// exactly why the office formats carry a slot per script rather than one font.
    func testLatinKeepsTheThemeFontWhileHangulMoves() {
        let string = NSMutableAttributedString(string: "행정 policy 업무", attributes: [.font: systemFont])
        FontSubstitutionResolver.applySubstitutions(to: string)

        let runs = fontRuns(string)
        // Read by CONTENT rather than by position, and never indexed blind: when this rule breaks the
        // string collapses to one run, and an index would abort the whole test process before the
        // other three cases ran — which is how a mutation check loses the evidence it was run for.
        let latin = runs.first { (string.string as NSString).substring(with: $0.0).contains("policy") }
        let hangul = runs.first { (string.string as NSString).substring(with: $0.0).contains("행정") }
        XCTAssertEqual(runs.count, 3, "one Hangul run, one Latin run, one Hangul run")
        XCTAssertEqual(latin?.1?.fontName, systemFont.fontName,
                       "the theme font draws Latin, so the Latin slot must not be substituted")
        XCTAssertNotEqual(hangul?.1?.fontName, systemFont.fontName,
                          "the Hangul slot must be, on the same string")
    }

    /// A document the theme's font already draws must come out byte-identical — the gate asks whether
    /// the declared font draws THIS text, not whether some other script exists in the world. Measured
    /// on `moby-dick.md`: 6,397 font runs before and after.
    func testALatinOnlyStringIsUntouched() {
        let string = NSMutableAttributedString(string: "Call me Ishmael. Some years ago—never mind how long",
                                               attributes: [.font: systemFont])
        let before = string.copy() as! NSAttributedString
        let edits = FontSubstitutionResolver.applySubstitutions(to: string)

        XCTAssertEqual(edits, 0, "nothing here needs a substitute")
        XCTAssertEqual(string, before, "and nothing may be rewritten")
    }

    /// Two scripts the theme font cannot draw resolve independently — the case a single sample per
    /// FONT could never serve, because only one of them can be the most common character.
    func testTwoUncoveredScriptsEachGetTheirOwnSlot() {
        let string = NSMutableAttributedString(string: "행정 業務 행정", attributes: [.font: systemFont])
        FontSubstitutionResolver.applySubstitutions(to: string)

        for (range, font) in fontRuns(string) {
            XCTAssertNotNil(font, "every run keeps a font")
            let piece = (string.string as NSString).substring(with: range)
            XCTAssertNotEqual(font?.fontName, systemFont.fontName,
                              "\"\(piece)\" is drawn by no system-font glyph and must have moved")
        }
    }
}
