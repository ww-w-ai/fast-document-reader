import XCTest
@testable import FastDocReader

/// Counts how finely a real document is cut into styled fragments, and how much of that cutting is
/// REDUNDANT — adjacent pieces whose formatting is byte-identical and could have been one piece.
///
/// Why this number and not a stopwatch: profiling a ⌘+ press on a 323-table HWP found that the two
/// dominant costs — installing the rebuilt string, and the one-time tax the first full-range attribute
/// query pays on fresh storage — both scale with the ATTRIBUTE-RUN COUNT, not with the character
/// count. That document carried 118,533 runs across 250,088 characters: one run every ~2 characters.
/// Building those runs is also ~93% of the build stage. So the run count is the single number three
/// separate costs follow, and it is deterministic — unlike this machine's wall clock, which was
/// measured swinging up to 11x under load.
///
///     FMD_SPAN_PROBE="/path/to/doc.hwp" \
///       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --filter testSpanFragmentation
///
/// Skipped by default: it needs a document this repo does not ship. It reports; it asserts nothing
/// about the numbers, because what counts as "too fragmented" is a judgement the reader makes with
/// the measurement in hand, not a threshold to bake in here.
final class SpanFragmentationProbeTests: XCTestCase {
    /// Two spans can be merged only if EVERY formatting field matches. Compared by blanking the TEXT
    /// and leaning on `Span`'s own synthesised `Equatable` — deliberately not a hand-written field
    /// list, which would silently start over-reporting merge opportunities the day someone adds a
    /// field to `Span` and forgets this probe exists.
    private func sameFormatting(_ a: Span, _ b: Span) -> Bool {
        var x = a; x.text = ""
        var y = b; y.text = ""
        return x == y
    }

    func testSpanFragmentation() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_SPAN_PROBE"] else {
            throw XCTSkip("set FMD_SPAN_PROBE to a real office document")
        }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let result: OfficeReadResult = DocumentTypes.isHwp(ext)
            ? try HwpReader.read(try Data(contentsOf: url))
            : try DocumentTypes.readOffice(try ZipArchive(data: Data(contentsOf: url)), extension: ext)

        var spans = 0, mergeable = 0, chars = 0, emptySpans = 0
        var paragraphs = 0, cells = 0
        var longestRun = 0

        func tally(_ ss: [Span]) {
            paragraphs += 1
            var prev: Span?
            for s in ss {
                spans += 1
                chars += s.text.count
                if s.text.isEmpty { emptySpans += 1 }
                longestRun = max(longestRun, s.text.count)
                if let p = prev, sameFormatting(p, s) { mergeable += 1 }
                prev = s
            }
        }

        func walk(_ blocks: [OfficeBlock]) {
            for b in blocks {
                switch b {
                case let .paragraph(spans, _, _, _, _): tally(spans)
                case let .heading(_, spans, _, _, _, _): tally(spans)
                case let .listItem(_, _, spans, _, _, _, _, _): tally(spans)
                case let .table(rows, _, _, _):
                    for row in rows {
                        for cell in row {
                            cells += 1
                            walk(cell.blocks)
                        }
                    }
                default: break
                }
            }
        }
        walk(result.blocks)

        let pct = spans > 0 ? Double(mergeable) / Double(spans) * 100 : 0
        print("""
        span fragmentation — \(url.lastPathComponent)
          top-level blocks     \(result.blocks.count)
          table cells          \(cells)
          text paragraphs      \(paragraphs)
          SPANS                \(spans)
          characters           \(chars)
          chars per span       \(spans > 0 ? String(format: "%.1f", Double(chars) / Double(spans)) : "-")
          longest single span  \(longestRun) chars
          empty spans          \(emptySpans)
          MERGEABLE with the previous span (identical formatting)
                               \(mergeable)  (\(String(format: "%.1f", pct))%)
          spans if merged      \(spans - mergeable)
        """)
        XCTAssertGreaterThan(spans, 0, "document produced no spans")

        // The SOURCE fragment count above is only half the question. What the two dominant ⌘+ costs
        // actually follow is the attribute-run count of the BUILT string — and on this document that
        // was measured at 118,533 against 9,328 source spans, a 12x multiplication the source cannot
        // explain. So build it here and attribute the runs to the specific keys that cut them: a run
        // boundary falls wherever ANY attribute changes, so the fragmenting key is the one whose own
        // run count approaches the total.
        let theme = RenderTheme.current(size: 16)
        let attr = OfficeTextBuilder.build(result.blocks, theme: theme,
                                           columnWidth: 600,
                                           pageContentWidth: result.pageContentWidth,
                                           tableWidth: 600)
        let whole = NSRange(location: 0, length: attr.length)
        var totalRuns = 0
        var keys = Set<NSAttributedString.Key>()
        attr.enumerateAttributes(in: whole, options: []) { dict, _, _ in
            totalRuns += 1
            keys.formUnion(dict.keys)
        }
        var perKey: [(String, Int)] = []
        for key in keys {
            var n = 0
            attr.enumerateAttribute(key, in: whole, options: []) { value, _, _ in
                if value != nil { n += 1 }
            }
            perKey.append((key.rawValue, n))
        }
        perKey.sort { $0.1 > $1.1 }
        print("""
        built-string attribute runs — \(url.lastPathComponent)
          length               \(attr.length)
          TOTAL runs           \(totalRuns)
          runs per source span \(spans > 0 ? String(format: "%.1f", Double(totalRuns) / Double(spans)) : "-")
          chars per run        \(totalRuns > 0 ? String(format: "%.1f", Double(attr.length) / Double(totalRuns)) : "-")
          per-attribute run counts (a key near TOTAL is the one doing the cutting):
        \(perKey.map { "    \(String(format: "%7d", $0.1))  \($0.0)" }.joined(separator: "\n"))
        """)

        // A separate profiling pass counted 118,533 runs on the INSTALLED storage for this same
        // document — 7x what the built string above carries. Same characters, same attributes, so
        // either installation itself refragments the run list or that figure was measuring something
        // else. Which of those is true decides whether there is a defect here at all, so count it
        // rather than argue: install exactly as `display` does, then again after the reflow passes
        // its async tail runs.
        func runs(_ s: NSAttributedString) -> Int {
            var n = 0
            s.enumerateAttributes(in: NSRange(location: 0, length: s.length), options: []) { _, _, _ in n += 1 }
            return n
        }
        let storage = NSTextStorage()
        storage.setAttributedString(attr)
        let afterInstall = runs(storage)
        // Per-key again, on the INSTALLED storage. Whichever key's own run count multiplied is the
        // one the storage refuses to coalesce — that names the fix, where the total alone cannot.
        var installedPerKey: [(String, Int)] = []
        for key in keys {
            var n = 0
            storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length),
                                       options: []) { value, _, _ in if value != nil { n += 1 } }
            installedPerKey.append((key.rawValue, n))
        }
        installedPerKey.sort { $0.1 > $1.1 }
        let before = Dictionary(uniqueKeysWithValues: perKey)
        print("""
        per-attribute runs, BUILT -> INSTALLED — \(url.lastPathComponent)
        \(installedPerKey.map { k in
            "    \(String(format: "%7d", before[k.0] ?? 0)) -> \(String(format: "%7d", k.1))  \(k.0)"
        }.joined(separator: "\n"))
        """)
        let lm = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(lm)
        lm.addTextContainer(container)
        let afterAttach = runs(storage)
        lm.ensureLayout(for: container)
        let afterLayout = runs(storage)
        TableBlockBuilder.resizeTables(in: storage, toWidth: 520)
        let afterResize = runs(storage)
        // The hypothesis the numbers above point at: the storage's own attribute fixing substitutes a
        // covering font wherever the assigned one lacks a glyph, and Korean text in a Latin-first
        // font makes that happen every couple of characters. If that is the mechanism, assigning a
        // font that already covers the text should stop the multiplication outright. Same glyphs on
        // screen either way — the substitute is what is being drawn today.
        let covering = NSFont(name: "AppleSDGothicNeo-Regular", size: 12)
        var coveringRuns = -1
        if let covering {
            let swapped = NSMutableAttributedString(attributedString: attr)
            swapped.enumerateAttribute(.font, in: NSRange(location: 0, length: swapped.length),
                                       options: []) { value, range, _ in
                guard let f = value as? NSFont else { return }
                if let sized = NSFont(descriptor: covering.fontDescriptor, size: f.pointSize) {
                    swapped.addAttribute(.font, value: sized, range: range)
                }
            }
            let s2 = NSTextStorage()
            s2.setAttributedString(swapped)
            coveringRuns = runs(s2)
        }
        print("""
        font-coverage experiment — \(url.lastPathComponent)
          installed runs, fonts as built        \(afterInstall)
          installed runs, one covering font     \(coveringRuns)  \(coveringRuns < 0 ? "(font unavailable)" : "")
        """)

        print("""
        run count through the install pipeline — \(url.lastPathComponent)
          built string             \(totalRuns)
          after setAttributedString\(String(format: "%8d", afterInstall))
          after layout manager     \(String(format: "%8d", afterAttach))
          after full layout        \(String(format: "%8d", afterLayout))
          after resizeTables       \(String(format: "%8d", afterResize))
        """)
    }
}
