import XCTest
@testable import FastDocReader

/// `ScriptRunSplitter` cuts a run where the family the DOCUMENT resolved for it changes, so each
/// stretch of text can be drawn in the face its own writing system was assigned.
///
/// Three properties have to hold on every input this file feeds it, so every case asserts all three
/// through `check(_:_:)` rather than only the one it was written for: no piece is empty,
/// concatenating the pieces reproduces the input EXACTLY, and the pieces are in source order. The
/// round-trip is the one that matters most — a splitter that drops or duplicates a scalar changes
/// the document's text, and unlike a wrong font that is not a presentation bug.
///
/// The trap cases below are the thirteen from the investigation behind
/// `docs/per-script-font-design.md` §4, kept verbatim so the finding never has to be re-derived. Each
/// was proven there to produce identical output from a scalar walk and from a grapheme-cluster
/// reference; what they defend here is that absorption alone keeps a cluster whole, without this
/// pass ever segmenting graphemes or touching UTF-16 offsets.
final class ScriptRunSplitterTests: XCTestCase {

    // MARK: - The classifiers these tests split with

    /// The identity classifier: one slot per `ScriptClass`, family named after it. It is what makes
    /// a piece's family readable in an assertion, and it is the harshest classifier available —
    /// every distinct script resolves to a distinct family, so nothing is hidden by two slots
    /// happening to agree.
    private func splitByScript(_ text: String) -> [ScriptRunSplitter.Piece] {
        ScriptRunSplitter.split(text,
                                classify: { UnicodeScript.of($0).isAbsorbing ? nil : UnicodeScript.of($0) },
                                family: { String(describing: $0) })
    }

    /// `[script:"text"]` per piece, the shape the investigation recorded its results in.
    private func describe(_ pieces: [ScriptRunSplitter.Piece]) -> String {
        pieces.map { "[\($0.family ?? "nil"):\($0.text.debugDescription)]" }.joined(separator: " ")
    }

    /// Asserts the three universal properties, then returns the pieces for a case-specific check.
    @discardableResult
    private func check(_ text: String,
                       _ pieces: [ScriptRunSplitter.Piece],
                       file: StaticString = #filePath,
                       line: UInt = #line) -> [ScriptRunSplitter.Piece] {
        for piece in pieces {
            XCTAssertFalse(piece.text.isEmpty, "a piece is empty", file: file, line: line)
        }
        XCTAssertEqual(pieces.map { String($0.text) }.joined(), text,
                       "pieces do not reproduce the input", file: file, line: line)
        return pieces
    }

    // MARK: - The thirteen trap cases

    func testTrapCasesStayWholeAndRoundTrip() {
        let cases: [(name: String, text: String, expected: String)] = [
            ("combining mark",
             "e\u{0301}cole",
             #"[latin:"école"]"#),
            ("Cyrillic Grapheme_Extend on a LATIN base",
             "a\u{0483}b",
             #"[latin:"a҃b"]"#),
            ("Korean with ASCII punctuation and digits",
             "한국어, 2025년 (test).",
             #"[hangul:"한국어, 2025년 ("] [latin:"test)."]"#),
            ("VS16 emoji",
             "gear \u{2699}\u{FE0F} done",
             #"[latin:"gear ⚙️ done"]"#),
            ("regional indicator pair",
             "flag \u{1F1F0}\u{1F1F7} end",
             #"[latin:"flag 🇰🇷 end"]"#),
            ("ZWJ family",
             "x\u{1F468}\u{200D}\u{1F469}y",
             #"[latin:"x👨‍👩y"]"#),
            ("astral surrogate pair",
             "字\u{20B9F}字",
             #"[han:"字𠮟字"]"#),
            ("skin-tone modifier",
             "a\u{1F44D}\u{1F3FD}b",
             #"[latin:"a👍🏽b"]"#),
            ("Devanagari danda",
             "\u{0915}\u{0930}\u{094D}\u{092E}\u{0964}",
             #"[complex:"कर्म।"]"#),
            ("Arabic mixed with Latin",
             "abc \u{0627}\u{0644}\u{0639} 123 xyz",
             #"[latin:"abc "] [complex:"الع 123 "] [latin:"xyz"]"#),
            ("kana voiced mark, which is Common",
             "\u{30AB}\u{309B}",
             #"[kana:"カ゛"]"#),
            ("Thai vowel above",
             "\u{0E01}\u{0E34}",
             #"[complex:"กิ"]"#),
            ("Hebrew points",
             "\u{05D0}\u{05B8}\u{05DC}",
             #"[complex:"אָל"]"#),
        ]
        for (name, text, expected) in cases {
            let pieces = check(text, splitByScript(text))
            XCTAssertEqual(describe(pieces), expected, name)
        }
    }

    func testAnAbsorbedScalarNeverStartsAPiece() {
        // The specific regression the `extend` class exists for: U+0483 is Grapheme_Extend AND
        // Script=Cyrillic, so Common+Inherited absorption alone would cut "a҃b" into three pieces
        // and put the boundary inside a grapheme cluster.
        let pieces = check("a\u{0483}b", splitByScript("a\u{0483}b"))
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(String(pieces[0].text), "a\u{0483}b")
        // And every piece must still begin on a grapheme-cluster boundary in the original string.
        let text = "한국어\u{0301}abc"
        let split = check(text, splitByScript(text))
        let clusterStarts = Set(text.indices)
        for piece in split.dropFirst() {
            XCTAssertTrue(clusterStarts.contains(piece.text.startIndex),
                          "piece \(piece.text.debugDescription) starts inside a cluster")
        }
    }

    // MARK: - The invariant-37 shape: break on the FAMILY, not on the slot

    func testTwoSlotsNamingTheSameFamilyProduceOnePiece() {
        // This is the structural half of invariant 37. `제1항` alternates between two slots at every
        // character — Hangul, digit, Hangul — and a splitter keyed on the SLOT would emit three
        // pieces. Keyed on the resolved family, a document that points both slots at one face gets
        // back exactly what it started with.
        let text = "제1항 rev.2026년"
        let pieces = check(text, ScriptRunSplitter.split(
            text,
            classify: { scalar -> ScriptClass? in UnicodeScript.of(scalar) },   // nothing absorbs
            family: { _ in "Batang" }))
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(String(pieces[0].text), text)
        XCTAssertEqual(pieces[0].family, "Batang")

        // The same input under a classifier whose slots DO name different families splits, so the
        // single piece above is the family rule at work and not the splitter failing to see slots.
        let split = check(text, ScriptRunSplitter.split(
            text,
            classify: { scalar -> ScriptClass? in UnicodeScript.of(scalar) },
            family: { $0 == .hangul ? "Batang" : "Times" }))
        XCTAssertGreaterThan(split.count, 1)
    }

    func testADocumentThatDeclaredNothingIsOnePieceWithNoFamily() {
        // The other half of invariant 37: every slot resolving to `nil` is one piece carrying `nil`,
        // which is exactly the span the reader had before this pass existed.
        let text = "한국어 mixed with English 漢字 and ٱلْعَرَبِيَّة"
        let pieces = check(text, ScriptRunSplitter.split(
            text,
            classify: { UnicodeScript.of($0).isAbsorbing ? nil : UnicodeScript.of($0) },
            family: { _ in nil }))
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(String(pieces[0].text), text)
        XCTAssertNil(pieces[0].family)
    }

    func testASingleFamilyInputIsOnePieceHoldingTheWholeInput() {
        let text = "The quick brown fox."
        let pieces = check(text, splitByScript(text))
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(String(pieces[0].text), text)
        XCTAssertEqual(pieces[0].family, "latin")
    }

    // MARK: - Degenerate inputs

    func testEmptyInputProducesNoPieces() {
        XCTAssertEqual(splitByScript(""), [])
    }

    func testAnEntirelyAbsorbedRunIsOnePieceWithNoFamily() {
        // A run of nothing but punctuation and spaces has no writing system to take a family from.
        // It must still come back whole — dropping it would delete text from the document.
        let text = " ,  — ()… "
        let pieces = check(text, splitByScript(text))
        XCTAssertEqual(pieces.count, 1)
        XCTAssertNil(pieces[0].family)
        XCTAssertEqual(String(pieces[0].text), text)
    }

    func testLeadingAbsorbedScalarsJoinTheFirstRealPiece() {
        // Punctuation before the first classifying scalar has nowhere of its own to go; it belongs
        // to the piece that follows, not to a family-less piece of its own.
        let text = "  (한국어) abc"
        let pieces = check(text, splitByScript(text))
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].family, "hangul")
        XCTAssertEqual(String(pieces[0].text), "  (한국어) ")
        XCTAssertEqual(pieces[1].family, "latin")
    }

    // MARK: - The `family` callback's contract

    func testFamilyIsResolvedOncePerConsecutiveSlotRatherThanPerScalar() {
        // The memo is why a reader can pass `{ slot in slotFonts[slot] }` without paying a
        // dictionary lookup on every scalar of the document. Counting the calls is the only way to
        // see it — the OUTPUT is identical either way, which is what makes this worth asserting.
        var resolutions: [ScriptClass] = []
        let text = "한국어 abc 한국어 abc"
        let pieces = check(text, ScriptRunSplitter.split(
            text,
            classify: { UnicodeScript.of($0).isAbsorbing ? nil : UnicodeScript.of($0) },
            family: { slot in resolutions.append(slot); return String(describing: slot) }))
        XCTAssertEqual(describe(pieces), #"[hangul:"한국어 "] [latin:"abc "] [hangul:"한국어 "] [latin:"abc"]"#)
        XCTAssertEqual(resolutions, [.hangul, .latin, .hangul, .latin],
                       "family() should be called once per slot CHANGE, not once per scalar")
    }

    // MARK: - The deterministic knob

    func testRunCountOnALargeMixedScriptString() throws {
        // Piece count, not wall clock, is this feature's knob — invariant 49's `layoutStepCount`
        // idiom, and this machine's clock swings up to 3x under load. The corpus is the one the
        // investigation measured on: a Korean administrative line mixing Hangul, Latin, digits,
        // ASCII punctuation, Han, kana, enclosed numerals and symbols, repeated past 250k UTF-16
        // units. If a later change to absorption or to the table moves this number, that is a
        // behaviour change to explain, not noise to re-baseline.
        let unit = "제1조(목적) 이 규정은 행정업무의 운영에 필요한 사항을 정함을 목적으로 한다. "
                 + "Section 3.2 (a) — see ISO 9001:2015, p. 47. 漢字混用 かな ①②③ ★ 100% ✓\n"
        var corpus = ""
        corpus.reserveCapacity(300_000)
        while corpus.utf16.count < 250_000 { corpus += unit }
        XCTAssertEqual(corpus.utf16.count, 250_030, "the corpus itself must not drift")

        let pieces = check(corpus, splitByScript(corpus))
        XCTAssertEqual(pieces.count, 9_092)

        // Same corpus, same classifier, one family for every slot: the whole thing collapses to one
        // piece. That is the property the readers rely on for a document whose slots agree, at a
        // scale where an off-by-one in the merge would be obvious.
        let collapsed = check(corpus, ScriptRunSplitter.split(
            corpus,
            classify: { UnicodeScript.of($0).isAbsorbing ? nil : UnicodeScript.of($0) },
            family: { _ in "one" }))
        XCTAssertEqual(collapsed.count, 1)
    }
}
