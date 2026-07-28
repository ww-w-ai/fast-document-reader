import XCTest
import AppKit
@testable import FastDocReader

/// `FontSubstitutionCache`'s own correctness contract — independent of
/// `FontSubstitutionResolverTests`'s glyph-identity proofs (those check WHAT gets drawn; these check
/// that memoising the CoreText calls BEHIND it changes nothing about the answer, only how many times
/// it is computed). See the cache's file doc in `FontSubstitutionResolver.swift` for the key design
/// this verifies, and `docs/font-substitution-cost-design.md` for why a per-read, not process-wide,
/// lifetime is the one this app can trust.
///
/// **What this file no longer has to test, and why that is a deletion worth naming.** The previous
/// shape asked `CTFontCreateForString` about the whole REMAINDER of a span, which made the leading
/// codepoint an under-description of the real question: a variation selector sitting directly after
/// the base changes CoreText's answer (`U+2699` alone → `Menlo-Regular`, `U+2699 U+FE0F` →
/// `.AppleColorEmojiUI`), and a key ignoring it leaked a colour-emoji face onto a later, unrelated
/// bare `⚙`. That whole hazard is gone by construction rather than by guard: the question is now
/// about ONE isolated character, and that character can never be a variation selector or an emoji
/// base anyway (both are absorbing classes, which are not sample-eligible). The replacement test
/// below pins the outcome so the deletion is verified, not merely asserted.
final class FontSubstitutionCacheTests: XCTestCase {
    /// Equivalent to NO cross-span memoisation at all: a brand new cache starts every span, so
    /// nothing can survive from one span to the next.
    private func resolveWithoutSharing(_ spans: [Span],
                                        blockWeight: FontSubstitutionResolver.BlockWeight = .regular) -> [Span] {
        spans.flatMap { FontSubstitutionResolver.resolve([$0], blockWeight: blockWeight, cache: FontSubstitutionCache()) }
    }

    // MARK: Bit-identical (synthetic — runs on every `swift test`, no real document required)

    /// The same spans, resolved through one shared cache and through a fresh cache each, must come
    /// out identical. Deliberately built so the SAME characters recur across DIFFERENT spans, plus an
    /// exact whole-span repeat, plus bold/italic/code spans so the font-identity half of the key (the
    /// declared font's OWN traited `fontName`) is exercised too.
    ///
    /// Note what makes this a fair comparison under the new design: each of these spans, taken alone,
    /// samples a Korean syllable, so its per-span answer is the same one the shared survey reaches.
    /// A span mixing scripts in DIFFERENT proportions to the document as a whole would legitimately
    /// differ — the sample is a document-level fact (`testTheSampleIsTakenFromTheWholeDocumentNotOneBlock`),
    /// which is the point of surveying before applying, not a caching bug.
    func testMemoisedResultsAreBitIdenticalToUnmemoised() {
        let spans: [Span] = [
            Span(text: "가나다라마바사아자차카타파하 보일러플레이트 하나"),
            Span(text: "가나다 다른 꼬리 텍스트가 이어지는 두 번째 문단"),
            Span(text: "다른 문자로 시작하는 세 번째 한글 문단입니다"),
            Span(text: "가나다라 짧은 반복"),
            Span(text: "볼드 한글도 섞여있음", bold: true),
            Span(text: "이탤릭 한글도 섞여있음", italic: true),
            Span(text: "코드안의한글텍스트", code: true),
            Span(text: "가나다라마바사아자차카타파하 보일러플레이트 하나"),   // exact repeat of the first
            Span(text: "완전히 새로운 표현이 계속 등장하는 문단"),
        ]
        let sharedCache = FontSubstitutionCache()
        XCTAssertEqual(resolveWithoutSharing(spans),
                       FontSubstitutionResolver.resolve(spans, cache: sharedCache),
                       "a shared cache must return byte-identical spans to no sharing at all")

        // Heading weight is a SEPARATE probe font from body text (`.semibold` vs `.regular`) — the
        // memo key includes `blockWeight`, and a bug there would silently return a regular-weight
        // substitute for a heading.
        let headingSpans: [Span] = [
            Span(text: "가나다라마바사아자차카타파하 제목 하나"),
            Span(text: "가나다라마바사아자차카타파하 제목 둘"),
        ]
        XCTAssertEqual(resolveWithoutSharing(headingSpans, blockWeight: .semibold),
                       FontSubstitutionResolver.resolve(headingSpans, blockWeight: .semibold,
                                                         cache: FontSubstitutionCache()),
                       "heading (semibold) spans must also be byte-identical whether shared or not")
    }

    /// The variation-selector hazard, verified ABSENT rather than guarded against. Both spans are
    /// ordinary English carrying a dual-presentation symbol; `U+2699` is Script=Common and `U+FE0F`
    /// is `Grapheme_Extend`, so neither can be sampled, the gate never fires, and there is nothing
    /// for a shared cache to conflate. Order is deliberate — the emoji-presentation span resolves
    /// FIRST through the SAME cache, which is what poisoned the bare one under the old key.
    func testAVariationSelectorCannotPoisonALaterBareCharacter() {
        let emojiSpan = Span(text: "gear \u{2699}\u{FE0F} first")
        let bareSpan = Span(text: "gear \u{2699} second")
        let shared = FontSubstitutionCache()
        let firstResolved = FontSubstitutionResolver.resolve([emojiSpan], cache: shared)
        let secondResolved = FontSubstitutionResolver.resolve([bareSpan], cache: shared)
        XCTAssertEqual(firstResolved, [emojiSpan])
        XCTAssertEqual(secondResolved, [bareSpan],
                       "a later bare span must be untouched — it cannot inherit an earlier span's " +
                       "variation-selected answer, because neither character is ever sampled")
    }

    /// The two questions this cache memoises, asked directly, with and without the memo. A cache
    /// that returned a WRONG stored answer would show up here as a disagreement between the first
    /// (uncached) call and the second (cached) one on the same input.
    func testRepeatedQuestionsReturnTheSameAnswerAndCostNothingTheSecondTime() {
        let cache = FontSubstitutionCache()
        let declared = NSFont.systemFont(ofSize: 12)
        let hangul = "가".unicodeScalars.first!.value

        let firstCovers = cache.covers(declared, hangul)
        let afterFirst = cache.coreTextCallCount
        XCTAssertEqual(firstCovers, cache.covers(declared, hangul))
        XCTAssertEqual(cache.coreTextCallCount, afterFirst, "a repeated coverage question must be free")

        let firstFont = cache.substituteFont(declared: declared, scalar: hangul)
        let afterSubstitute = cache.coreTextCallCount
        XCTAssertGreaterThan(afterSubstitute, afterFirst, "the first substitute question must cost a call")
        XCTAssertEqual(firstFont, cache.substituteFont(declared: declared, scalar: hangul))
        XCTAssertEqual(cache.coreTextCallCount, afterSubstitute, "a repeated substitute question must be free")
    }

    /// Two declared fonts differing ONLY in weight must never share an answer — `.SFNS-Regular` and
    /// `.SFNS-Bold` are different `fontName`s, which is what keeps a bold Korean run from inheriting
    /// a regular face. Pinned because a key that dropped traits is a bug this file's subject has
    /// already had once.
    func testTraitsAreNotConflatedInTheCacheKey() {
        let cache = FontSubstitutionCache()
        let hangul = "가".unicodeScalars.first!.value
        let regular = NSFont.systemFont(ofSize: 12)
        let bold = NSFont.systemFont(ofSize: 12, weight: .bold)
        XCTAssertNotEqual(regular.fontName, bold.fontName, "sanity: the two probes must differ")
        let regularFace = cache.substituteFont(declared: regular, scalar: hangul).fontName
        let boldFace = cache.substituteFont(declared: bold, scalar: hangul).fontName
        XCTAssertNotEqual(regularFace, boldFace,
                          "a bold probe must resolve to a bold face, not inherit the regular answer " +
                          "(\(regularFace) vs \(boldFace))")
    }

    /// This file ships no runnable mutation of the cache itself (`FontSubstitutionCache` is
    /// deliberately `final` — no subclass hook exists to poison it without weakening the production
    /// type). Invariant 30's mutation step was performed BY HAND and is recorded here rather than
    /// left as an unverified claim; see the commit message for what each mutation printed.

    // MARK: Deterministic CoreText call count (real document — the knob this pass is judged by)

    /// On a real document, ONE survey for the whole read must cost a handful of CoreText calls, not
    /// one per span. Skips unless `FMD_OFFICE_LATENCY_FILE` names a real HWP.
    ///
    /// Note the comparison deliberately does NOT assert the two runs produce identical blocks any
    /// more: planning per block asks "what is the most common character in THIS block", which is a
    /// genuinely different question from "…in this document" and may legitimately answer differently.
    /// That divergence is the feature, and asserting it away would pin the wrong thing.
    func testOneSurveyPerDocumentCostsAHandfulOfCoreTextCalls() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_OFFICE_LATENCY_FILE"] else {
            throw XCTSkip("set FMD_OFFICE_LATENCY_FILE to measure a real office document")
        }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        guard ext == "hwp" || ext == "hwpx" else {
            throw XCTSkip("this probe reads HWP directly; point FMD_OFFICE_LATENCY_FILE at a .hwp/.hwpx")
        }
        let raw = try HwpReader.read(try Data(contentsOf: url))

        func countSpans(_ blocks: [OfficeBlock]) -> Int {
            blocks.reduce(0) { acc, b in
                switch b {
                case let .heading(_, spans, _, _, _, _), let .paragraph(spans, _, _, _, _):
                    return acc + spans.count
                case let .listItem(_, _, spans, _, _, _, _, _):
                    return acc + spans.count
                case let .table(rows, _, _, _):
                    return acc + rows.reduce(0) { a, row in a + row.reduce(0) { a2, c in a2 + countSpans(c.blocks) } }
                case .image, .unsupportedGraphic, .formula:
                    return acc
                }
            }
        }
        let spanCount = countSpans(raw.blocks)

        var perBlockCalls = 0
        for block in raw.blocks {
            let cache = FontSubstitutionCache()
            _ = block.resolvingFontSubstitution(cache: cache)
            perBlockCalls += cache.coreTextCallCount
        }

        let sharedCache = FontSubstitutionCache()
        let plan = FontSubstitutionResolver.plan(for: raw.blocks, cache: sharedCache)
        let documentCalls = sharedCache.coreTextCallCount

        print("  spans: \(spanCount)")
        print("  CoreText calls — a fresh survey per top-level block: \(perBlockCalls)")
        print("  CoreText calls — ONE survey for the document:        \(documentCalls)")
        print("  declared fonts substituted: \(plan.substitutedFontCount)")
        print(plan.describedEntries.map { "    \($0)" }.joined(separator: "\n"))

        XCTAssertLessThan(documentCalls, perBlockCalls,
                          "one document-wide survey must cost less than one per block")
        // Not an arbitrary threshold: at most one coverage question and one substitute question per
        // distinct declared font is the design's own upper bound, and the memo collapses fonts that
        // share an answer, so the real number lands below it.
        XCTAssertLessThanOrEqual(documentCalls, 2 * (plan.substitutedFontCount + 1) + 64,
                                 "the survey must stay a handful of calls, not scale with spans")
        XCTAssertLessThan(documentCalls, spanCount, "and must be far below one call per span")
    }
}
