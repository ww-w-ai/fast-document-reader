import XCTest
import AppKit
@testable import FastDocReader

/// `FontSubstitutionCache`'s own correctness contract — independent of
/// `FontSubstitutionResolverTests`'s glyph-identity proofs (those check WHAT gets drawn; these check
/// that memoising the CoreText calls BEHIND it changes nothing about the answer, only how many times
/// it is computed). See the cache's file doc in `FontSubstitutionResolver.swift` for the key design
/// this verifies, and `docs/font-substitution-cost-design.md` for why a per-read, not process-wide,
/// lifetime is the one this app can trust.
final class FontSubstitutionCacheTests: XCTestCase {
    /// Equivalent to NO cross-span memoisation at all: a brand new cache starts every span, so
    /// nothing can ever survive from one span to the next. This is the "unmemoised path" the file
    /// doc's bit-identical claim is checked against.
    private func resolveWithoutSharing(_ spans: [Span],
                                        blockWeight: FontSubstitutionResolver.BlockWeight = .regular) -> [Span] {
        spans.flatMap { FontSubstitutionResolver.resolve([$0], blockWeight: blockWeight, cache: FontSubstitutionCache()) }
    }

    private func resolveWithSharing(_ spans: [Span],
                                     blockWeight: FontSubstitutionResolver.BlockWeight = .regular,
                                     cache: FontSubstitutionCache = FontSubstitutionCache()) -> [Span] {
        FontSubstitutionResolver.resolve(spans, blockWeight: blockWeight, cache: cache)
    }

    // MARK: Bit-identical (synthetic — runs on every `swift test`, no real document required)

    /// Deliberately built so the SAME leading characters recur across DIFFERENT spans with DIFFERENT
    /// trailing text — the exact shape the design's "never on the span's specific text beyond which
    /// script(s) it contains" claim has to hold under for a leading-codepoint-keyed substitute cache
    /// to be safe — plus an exact whole-span repeat, and bold/italic/code spans so the font-identity
    /// half of the key (declared font's OWN traited `fontName`) is exercised too.
    func testMemoisedResultsAreBitIdenticalToUnmemoised() {
        let spans: [Span] = [
            Span(text: "가나다라마바사아자차카타파하 boilerplate 1"),
            Span(text: "가나다 다른 꼬리 텍스트가 이어지는 두 번째 span"),
            Span(text: "다른 문자로 시작하는 세 번째 한글 문단입니다"),
            Span(text: "가나다라 짧은 반복"),
            Span(text: "Bold 한글도 섞여있음", bold: true),
            Span(text: "Italic 한글도 섞여있음", italic: true),
            Span(text: "코드안의한글텍스트", code: true),
            Span(text: "한글과 English와 123 그리고 かな가 섞인 span"),
            Span(text: "가나다라마바사아자차카타파하 boilerplate 1"),   // exact repeat of the first span
            Span(text: "완전히 새로운 표현이 계속 등장하는 문단"),
        ]
        let unmemoised = resolveWithoutSharing(spans)
        let memoised = resolveWithSharing(spans)
        XCTAssertEqual(unmemoised, memoised,
                       "a shared cache must return byte-identical spans to no sharing at all")

        // Heading weight is a SEPARATE probe font from body text (`.semibold` vs `.regular`) — the
        // memo key includes `blockWeight`, and a bug there would silently return a regular-weight
        // substitute for a heading the second time a leading character recurs.
        let headingSpans: [Span] = [
            Span(text: "가나다라마바사아자차카타파하 제목 하나"),
            Span(text: "가나다라마바사아자차카타파하 제목 둘"),
        ]
        XCTAssertEqual(resolveWithoutSharing(headingSpans, blockWeight: .semibold),
                       resolveWithSharing(headingSpans, blockWeight: .semibold),
                       "heading (semibold) spans must also be byte-identical whether shared or not")
    }

    /// **The variation-selector blocker (found in review, 2026-07-28).** `substituteFont` hands
    /// CoreText the WHOLE REMAINDER of a span, not the isolated base character — so a memo keyed on
    /// the base scalar alone under-describes the actual question whenever a variation selector sits
    /// directly after it. U+2699 (gear) is a Unicode "dual presentation" symbol: probed live,
    /// `.systemFont(ofSize: 12)` resolves U+2699 ALONE to `Menlo-Regular` but U+2699 immediately
    /// followed by VS16 (U+FE0F, "emoji presentation") to `.AppleColorEmojiUI` — genuinely different
    /// real CoreText answers for the same base scalar. Order matters: the emoji-presentation span is
    /// resolved FIRST, through the SAME shared cache, so a base-scalar-only key (the bug) poisons the
    /// LATER, unrelated bare span with the wrong colour-emoji substitute — exactly the real-corpus
    /// failure the blocker report measured (a document's own "⚙️" resolved before its own bare "⚙",
    /// the second then silently reading as colour emoji instead of the declared font's own text-style
    /// substitute).
    func testSharedCacheDoesNotConflateAVariationSelectedCharacterWithItsBareForm() {
        let emojiSpan = Span(text: "gear \u{2699}\u{FE0F} first")   // emoji presentation, resolved FIRST
        let bareSpan = Span(text: "gear \u{2699} second")            // bare — must resolve INDEPENDENTLY

        let sharedCache = FontSubstitutionCache()
        let sharedEmoji = FontSubstitutionResolver.resolve([emojiSpan], cache: sharedCache)
        let sharedBare = FontSubstitutionResolver.resolve([bareSpan], cache: sharedCache)

        // The ground truth: each span resolved with its OWN fresh cache, i.e. no cross-span memo at
        // all — equivalent to what a correct shared-cache key must also produce for BOTH spans.
        let unsharedEmoji = FontSubstitutionResolver.resolve([emojiSpan], cache: FontSubstitutionCache())
        let unsharedBare = FontSubstitutionResolver.resolve([bareSpan], cache: FontSubstitutionCache())

        XCTAssertEqual(sharedEmoji, unsharedEmoji,
                       "the emoji-presentation span's own resolution must not depend on cache sharing")
        XCTAssertEqual(sharedBare, unsharedBare,
                       "a LATER bare span sharing the cache must resolve exactly as it would with no " +
                       "sharing at all — not inherit an earlier span's variation-selected answer")

        // Pin the concrete, genuinely different faces — "equal to the unshared baseline" alone would
        // pass even if BOTH sides were (consistently) wrong, so confirm the two really do diverge.
        func resolvedFontName(_ resolved: [Span]) -> String? {
            resolved.first { $0.resolvedFontDescriptor != nil }?.resolvedFontDescriptor
                .flatMap { NSFont(descriptor: $0, size: 12)?.fontName }
        }
        let emojiFace = try! XCTUnwrap(resolvedFontName(sharedEmoji))
        let bareFace = try! XCTUnwrap(resolvedFontName(sharedBare))
        XCTAssertNotEqual(emojiFace, bareFace,
                          "sanity: the emoji-presentation gear (\(emojiFace)) and the bare gear " +
                          "(\(bareFace)) must be genuinely different substitute faces for this test " +
                          "to mean anything")
    }

    /// This test does not ship a runnable mutation (`FontSubstitutionCache` is deliberately `final` —
    /// no subclass hook exists to poison it without weakening the production type, and a hand-rolled
    /// second implementation "for testing" would itself need proving correct). Instead, invariant
    /// 30's mutation step was performed BY HAND during implementation and is recorded here rather
    /// than left as an unverified claim: `coverage(of:in:)`'s cache-hit branch was temporarily
    /// changed to return the wrong stored answer (skipping straight to `covered[cp.start] = false`
    /// regardless of the memoised value), `swift test --filter FontSubstitutionCacheTests` was run,
    /// and `testMemoisedResultsAreBitIdenticalToUnmemoised` FAILED as expected (the shared-cache path
    /// diverged from the fresh-cache path on every span whose second+ occurrence of a cached
    /// character hit the corrupted branch) — then the change was reverted and the suite re-confirmed
    /// green. That failure is the proof this test is not merely vacuously true.

    // MARK: Deterministic CoreText call count (real document — the knob this fix is judged by)

    /// On a real document, sharing ONE cache across the whole read must cut CoreText calls
    /// dramatically below one-per-span, without changing a single resolved `Span`. Skips unless
    /// `FMD_OFFICE_LATENCY_FILE` names a real office document (mirrors `OfficeRenderLatencyTests`).
    func testSharedCacheDramaticallyReducesCoreTextCallsOnARealDocument() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_OFFICE_LATENCY_FILE"] else {
            throw XCTSkip("set FMD_OFFICE_LATENCY_FILE to measure a real office document")
        }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        guard ext == "hwp" || ext == "hwpx" else {
            throw XCTSkip("this probe reads HWP directly; point FMD_OFFICE_LATENCY_FILE at a .hwp/.hwpx")
        }
        let data = try Data(contentsOf: url)
        let raw = try HwpReader.read(data)

        // "Before": every TOP-LEVEL block resolved with its own fresh cache — zero cross-block
        // sharing, which is at least as generous to "before" as the true unmemoised code (whose
        // per-span local dictionary never shared across spans at all, only within one span's own
        // run-splitting loop). If anything this undercounts the old cost.
        var beforeCalls = 0
        var beforeBlocks: [OfficeBlock] = []
        for block in raw.blocks {
            let cache = FontSubstitutionCache()
            beforeBlocks.append(block.resolvingFontSubstitution(cache: cache))
            beforeCalls += cache.coreTextCallCount
        }

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

        // "After": the real production path — ONE cache for the whole document.
        let sharedCache = FontSubstitutionCache()
        let afterBlocks = raw.blocks.map { $0.resolvingFontSubstitution(cache: sharedCache) }
        let afterCalls = sharedCache.coreTextCallCount

        print("  spans: \(spanCount)")
        print("  CoreText calls — no sharing (fresh cache per top-level block): \(beforeCalls)")
        print("  CoreText calls — one shared cache (real document-read shape): \(afterCalls)")

        XCTAssertLessThan(afterCalls, beforeCalls,
                          "a document-scoped shared cache must issue fewer CoreText calls than one fresh per block")
        // Not an arbitrary threshold: fewer CoreText calls than spans means real CROSS-span reuse is
        // happening, not merely the intra-span dedup the old per-span code already had for free.
        XCTAssertLessThan(afterCalls, spanCount,
                          "sharing must cut CoreText calls below one-per-span — that is the whole point of a document-scoped memo")

        // And the result must be identical to the unshared run — cost changed, behaviour did not.
        XCTAssertEqual(beforeBlocks, afterBlocks,
                       "resolved blocks must be byte-identical whether the cache was shared across the document or not")
    }
}
