import XCTest
import AppKit
@testable import FastDocReader

/// The instrument the "one representative per declared font" change is judged by — the same four
/// deterministic counts `docs/font-substitution-cost-design.md` §1 and the option survey behind it
/// used, on any real document, so a before/after comparison is a re-run of one command rather than a
/// rebuilt throwaway.
///
///     FMD_SUBST_PROBE="/path/a.hwp:/path/b.docx" \
///       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --filter testSubstitutionCost
///
/// Reports, never asserts a threshold (the same discipline as `SpanFragmentationProbeTests`): what
/// counts as an acceptable run count is a judgement made with the numbers in hand. What it DOES
/// assert is that it measured something at all.
///
/// The four numbers, and why each is here:
///   - **spans** after resolution — the read-time pass's own fragmentation, the half that costs
///     `OfficeTextBuilder.build` on every ⌘+ press.
///   - **built font runs** — what the builder hands to the storage.
///   - **installed font runs** — what survives `NSTextStorage`'s own attribute fixing; the knob the
///     first full-range attribute query and layout both follow.
///   - **CoreText calls at read** — `FontSubstitutionCache.coreTextCallCount`, counted rather than
///     timed because this machine's wall clock has been measured swinging up to 11×.
///
/// Plus a **face census** — characters per drawn face on the INSTALLED storage — because the run
/// count alone cannot see the one failure that disqualified the whole-document-descriptor variant:
/// bold and semibold Korean going out regular. A census showing zero characters in a bold Korean
/// face is a defect no count would report.
final class FontSubstitutionProbeTests: XCTestCase {
    /// Raw, UNRESOLVED blocks — the reader's own output before `resolvingFontSubstitution` runs, so
    /// this probe can drive the resolution itself with a cache it can read the call count off.
    private func rawRead(_ url: URL) throws -> OfficeReadResult {
        let ext = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url)
        if DocumentTypes.isHwp(ext) {
            guard let json = HwpReader.exportDocumentJSON(data) else {
                throw NSError(domain: "probe", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "rhwp export failed"])
            }
            return try HwpReader.mapJSON(json)
        }
        // Deliberately the READER, not `DocumentTypes.readOffice` — that dispatch applies the
        // resolution on the way out, which is the very pass being measured here.
        return try DocxOrOdt(url: url, data: data).read()
    }

    private struct DocxOrOdt {
        let url: URL
        let data: Data
        func read() throws -> OfficeReadResult {
            let archive = try ZipArchive(data: data)
            switch url.pathExtension.lowercased() {
            case "odt": return try OdtReader.read(archive)
            default: return try DocxReader.read(archive)
            }
        }
    }

    private func spanCount(_ blocks: [OfficeBlock]) -> Int {
        var n = 0
        func walk(_ bs: [OfficeBlock]) {
            for b in bs {
                switch b {
                case let .paragraph(spans, _, _, _, _): n += spans.count
                case let .heading(_, spans, _, _, _, _): n += spans.count
                case let .listItem(_, _, spans, _, _, _, _, _): n += spans.count
                case let .table(rows, _, _, _):
                    for row in rows { for cell in row { walk(cell.blocks) } }
                default: break
                }
            }
        }
        walk(blocks)
        return n
    }

    private func fontRuns(_ s: NSAttributedString) -> Int {
        var n = 0
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length),
                             options: []) { v, _, _ in if v != nil { n += 1 } }
        return n
    }

    private func totalRuns(_ s: NSAttributedString) -> Int {
        var n = 0
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length), options: []) { _, _, _ in n += 1 }
        return n
    }

    private func census(_ s: NSAttributedString) -> [(String, Int)] {
        var chars: [String: Int] = [:]
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length),
                             options: []) { v, r, _ in
            guard let f = v as? NSFont else { return }
            chars[f.fontName, default: 0] += r.length
        }
        return chars.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }

    func testSubstitutionCost() throws {
        guard let paths = ProcessInfo.processInfo.environment["FMD_SUBST_PROBE"] else {
            throw XCTSkip("set FMD_SUBST_PROBE to colon-separated real office documents")
        }
        for path in paths.split(separator: ":").map(String.init) where !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            let raw = try rawRead(url)
            let cache = FontSubstitutionCache()
            let clock = ContinuousClock()
            var resolved = raw
            let readTime = clock.measure { resolved = raw.resolvingFontSubstitution(cache: cache) }

            let theme = RenderTheme.current(size: 16)
            var built = NSAttributedString()
            let buildTime = clock.measure {
                built = OfficeTextBuilder.build(resolved.blocks, theme: theme, columnWidth: 600,
                                                pageContentWidth: resolved.pageContentWidth,
                                                tableWidth: 600)
            }
            let storage = NSTextStorage()
            let installTime = clock.measure { storage.setAttributedString(built) }
            // The stage `docs/font-substitution-cost-design.md` §1 mis-attributed to
            // `setAttributedString`: the FIRST full-range attribute query on fresh storage.
            var queried = 0
            let queryTime = clock.measure {
                storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length),
                                            options: []) { _, _, _ in queried += 1 }
            }
            let lm = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 600,
                                                         height: CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(lm)
            lm.addTextContainer(container)
            let layoutTime = clock.measure { lm.ensureLayout(for: container) }

            func ms(_ d: Duration) -> String {
                String(format: "%.0f", Double(d.components.attoseconds) / 1e15
                       + Double(d.components.seconds) * 1000)
            }
            print("""
            === plan — \(url.lastPathComponent)
            \(FontSubstitutionResolver.plan(for: raw.blocks).describedEntries.joined(separator: "\n"))
            """)
            print("""
            === substitution cost — \(url.lastPathComponent)
              characters            \(built.length)
              spans  raw -> resolved\(String(format: "%8d", spanCount(raw.blocks))) -> \(spanCount(resolved.blocks))
              font runs  built      \(fontRuns(built))
              font runs  installed  \(fontRuns(storage))
              all runs   built      \(totalRuns(built))
              all runs   installed  \(queried)
              CoreText calls (read) \(cache.coreTextCallCount)
              stages (ms)  read \(ms(readTime))  build \(ms(buildTime))  install \(ms(installTime))  firstQuery \(ms(queryTime))  layout \(ms(layoutTime))
              face census (chars per drawn face, top 12):
            \(census(storage).prefix(12).map { "    \(String(format: "%8d", $0.1))  \($0.0)" }.joined(separator: "\n"))
            """)
            XCTAssertGreaterThan(built.length, 0, "\(url.lastPathComponent) produced no text")
        }
    }

    /// The same four counts, one line per document, over a whole CORPUS — because every number in
    /// the option survey this change came from was taken on ONE reference HWP plus one docx, and
    /// invariant 34's lesson is that one document's accidents can argue a feature into or out of
    /// existence. Deliberately writes a machine-diffable line per document, so the before/after of a
    /// change is a `diff` of two runs rather than an aggregate that can hide a regression on any
    /// individual file.
    ///
    ///     FMD_SUBST_CORPUS="$HOME/Documents:$HOME/Downloads" [FMD_SUBST_CORPUS_LIMIT=120] \
    ///       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    ///       swift test --filter testSubstitutionCostAcrossACorpusSample
    ///
    /// Uses ONLY `resolvingFontSubstitution(cache:)` and `OfficeTextBuilder.build` on purpose: both
    /// exist on either side of this change, so the identical test file can be run against an older
    /// checkout to produce the baseline half of the diff.
    func testSubstitutionCostAcrossACorpusSample() throws {
        guard let dirList = ProcessInfo.processInfo.environment["FMD_SUBST_CORPUS"] else {
            throw XCTSkip("set FMD_SUBST_CORPUS (colon-separated directories) to sample a corpus")
        }
        let limit = Int(ProcessInfo.processInfo.environment["FMD_SUBST_CORPUS_LIMIT"] ?? "") ?? 120
        var urls: [URL] = []
        for root in dirList.split(separator: ":").map({ URL(fileURLWithPath: String($0)) }) {
            // An explicit error handler, for the reason `CorpusProbeTests` records: without one the
            // enumerator stops SILENTLY at the first unreadable subdirectory.
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [], errorHandler: { _, _ in true })
            else { continue }
            for case let url as URL in e {
                let ext = url.pathExtension.lowercased()
                if ["docx", "odt", "hwp", "hwpx"].contains(ext) { urls.append(url) }
            }
        }
        // Deterministic sample: sorted by path, then every k-th file, so two runs of this probe on
        // two checkouts see the SAME documents in the same order.
        urls.sort { $0.path < $1.path }
        let stride = max(1, urls.count / limit)
        let sample = Swift.stride(from: 0, to: urls.count, by: stride).map { urls[$0] }

        // **Write to a FILE, not just stdout.** `swift test` buffers a test's stdout to process exit
        // and then TRUNCATES it: a first run of this probe printed 47 of 121 documents and passed,
        // with nothing anywhere saying the other 74 had been dropped — the exact silent truncation
        // this project's working style forbids, and it would have quietly halved the corpus this
        // change is judged on. `FMD_SUBST_CORPUS_OUT` names a file that gets every line.
        var lines: [String] = ["corpus sample: \(sample.count) of \(urls.count) documents "
                                + "(every \(stride)th, sorted by path)"]
        func emit(_ line: String) { print(line); lines.append(line) }
        defer {
            if let out = ProcessInfo.processInfo.environment["FMD_SUBST_CORPUS_OUT"] {
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        emit(lines[0])

        let theme = RenderTheme.current(size: 16)
        for url in sample {
            guard let raw = try? rawRead(url) else {
                emit("SKIP\t\(url.lastPathComponent)\tread threw")
                continue
            }
            let cache = FontSubstitutionCache()
            let resolved = raw.resolvingFontSubstitution(cache: cache)
            let built = OfficeTextBuilder.build(resolved.blocks, theme: theme, columnWidth: 600,
                                                pageContentWidth: resolved.pageContentWidth,
                                                tableWidth: 600)
            let storage = NSTextStorage()
            storage.setAttributedString(built)
            emit("DOC\tchars=\(built.length)\tspans=\(spanCount(resolved.blocks))"
                  + "\tbuiltFontRuns=\(fontRuns(built))\tinstalledFontRuns=\(fontRuns(storage))"
                  + "\tct=\(cache.coreTextCallCount)\t\(url.lastPathComponent)")
        }
        XCTAssertGreaterThan(sample.count, 0, "FMD_SUBST_CORPUS matched no office documents")
    }
}
