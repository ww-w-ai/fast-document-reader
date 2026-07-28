import XCTest
@testable import FastDocReader

/// The measurements that decided the two open questions in `HwpSlotTable` — whether the Symbol slot
/// is worth an exception to absorption, and whether the User slot is reachable at all — asked of a
/// real corpus rather than argued from the format's shape.
///
///     FMD_HWP_SLOT_SURVEY="/path/to/hwp/files:/another/dir" \
///       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --filter HwpSlotClassifierProbeTests
///
/// Skipped by default: it needs documents this repo does not ship. It reports; it asserts almost
/// nothing about the numbers, because "is a fifth of the corpus enough to justify +2.3% pieces" is a
/// judgement made with the measurement in hand, not a threshold to bake in here. What it DOES assert
/// is the two structural properties a wrong classifier would break — no piece is empty, and
/// concatenating the pieces reproduces the source text exactly — on every span of every real
/// document it can reach, which is a far larger sample than any hand-built case.
final class HwpSlotClassifierProbeTests: XCTestCase {

    // MARK: the two candidate exception lists, measured against each other

    /// The narrow list `HwpSlotTable` actually ships: marks drawn in their own right.
    private static func narrowSymbol(_ v: UInt32) -> Bool {
        switch v {
        case 0x2190...0x21FF, 0x2500...0x257F, 0x2580...0x259F,
             0x25A0...0x25FF, 0x2600...0x26FF, 0x2700...0x27BF: return true
        default: return false
        }
    }

    /// rhwp's OWN slot-5 range list (`style_resolver.rs:402`), measured as the alternative. It adds
    /// enclosed alphanumerics, mathematical operators, miscellaneous technical, and — the expensive
    /// one — `U+3000`–`U+303F`, the CJK punctuation that sits inside running Korean prose.
    private static func rhwpSymbol(_ v: UInt32) -> Bool {
        switch v {
        case 0x2190...0x21FF, 0x2200...0x22FF, 0x2300...0x23FF, 0x2460...0x24FF,
             0x2500...0x257F, 0x2580...0x259F, 0x25A0...0x25FF, 0x2600...0x26FF,
             0x2700...0x27BF, 0x3000...0x303F: return true
        default: return false
        }
    }

    /// Absorption with NO symbol exception — the shared floor on its own, the baseline both
    /// candidates are costed against.
    private static func baselineSlot(_ s: Unicode.Scalar) -> HwpFontSlot? {
        let klass = UnicodeScript.of(s)
        if klass.isAbsorbing { return nil }
        switch klass {
        case .hangul: return .hangul
        case .latin: return .latin
        case .han: return .hanja
        case .kana: return .japanese
        case .eastAsianOther, .complex, .other: return .other
        case .common, .inherited, .extend: return nil
        }
    }

    private static func slot(_ s: Unicode.Scalar, symbol: (UInt32) -> Bool) -> HwpFontSlot? {
        if let base = baselineSlot(s) { return base }
        return symbol(s.value) ? .symbol : nil
    }

    /// The slot-6 candidate: rhwp's own User-slot special case, `U+318D` (ㆍ araea), which the UCD
    /// calls Script=Hangul and this classifier therefore sends to the Hangul slot. Measured as an
    /// exception on top of the shipped narrow-symbol rule.
    private static func slotWithAraea(_ s: Unicode.Scalar) -> HwpFontSlot? {
        if s.value == 0x318D { return .user }
        return slot(s, symbol: narrowSymbol)
    }

    /// The family each SCALAR ends up drawn in, one entry per scalar, so two classifiers can be
    /// compared character by character rather than only by piece count. Piece counts are the cost
    /// side; this is the benefit side — how many characters actually change typeface.
    private static func perScalarFamilies(_ pieces: [ScriptRunSplitter.Piece]) -> [String?] {
        var out: [String?] = []
        for p in pieces { out.append(contentsOf: p.text.unicodeScalars.map { _ in p.family }) }
        return out
    }

    // MARK: corpus walk

    private func corpusFiles() throws -> [URL] {
        guard let dirs = ProcessInfo.processInfo.environment["FMD_HWP_SLOT_SURVEY"], !dirs.isEmpty else {
            throw XCTSkip("set FMD_HWP_SLOT_SURVEY to colon-separated directories of HWP files")
        }
        let fm = FileManager.default
        var files: [URL] = []
        var skipped = 0
        for dir in dirs.split(separator: ":").map(String.init) {
            // Invariant 35: without an explicit error handler the walk stops dead at the first
            // unreadable directory and under-reports its own input with no indication at all.
            let e = fm.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil,
                                  options: [.skipsHiddenFiles],
                                  errorHandler: { _, _ in skipped += 1; return true })
            while let u = e?.nextObject() as? URL {
                if ["hwp", "hwpx"].contains(u.pathExtension.lowercased()) { files.append(u) }
            }
        }
        if skipped > 0 { print("SLOTPROBE dirsSkipped=\(skipped)") }
        // DEDUPE BY RESOLVED PATH. The natural argument for this probe lists the rhwp sample
        // directory explicitly AND `$HOME/Documents`, and the former lives inside the latter — so
        // every sample was walked twice and every count in the first run of this file was inflated
        // by that overlap. Two directories where one contains the other is the ordinary way to
        // invoke this, so the probe has to survive it rather than the caller having to notice.
        var seen = Set<String>()
        return files.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
    }

    /// The whole decision, in one pass over the corpus.
    ///
    /// For every span of every document it resolves the char shape's seven families, then splits the
    /// span's text three ways — no exception, the narrow list, rhwp's list — and counts the pieces
    /// each produces. The cost of an exception is the DIFFERENCE in piece counts; its benefit is how
    /// often the Symbol family is one the neighbouring run would not have used.
    func testSymbolAndUserSlotCost() throws {
        let files = try corpusFiles()
        var parsed = 0, unreadable = 0
        var rows = 0, rowsSymbolDiffersFromHangul = 0, docsWithSymbolDifference = 0
        var chars = 0, araea = 0
        var piecesBaseline = 0, piecesNarrow = 0, piecesRhwp = 0, piecesAraea = 0
        // Characters each exception would draw in a DIFFERENT family than absorption gives them —
        // the benefit side, as opposed to the piece count, which is the cost side. Counted per
        // SCALAR against the baseline split, so it is what actually changes on screen.
        var charsRedrawnNarrow = 0, charsRedrawnRhwp = 0, charsRedrawnAraea = 0
        var narrowSymbolChars = 0, rhwpSymbolChars = 0
        var rowsUserDiffersFromHangul = 0, docsWithUserDifference = 0

        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let json = HwpReader.exportDocumentJSON(data),
                  let export = try? HwpReader.fontSlotExport(json) else { unreadable += 1; continue }
            parsed += 1
            rows += export.charShapes.count
            var docHasDifference = false, docHasUserDifference = false
            let fonts = export.charShapes.map { HwpSlotFonts(row: $0) }
            for f in fonts where f.family(.symbol) != f.family(.hangul) {
                rowsSymbolDiffersFromHangul += 1
                docHasDifference = true
            }
            for f in fonts where f.family(.user) != f.family(.hangul) {
                rowsUserDiffersFromHangul += 1
                docHasUserDifference = true
            }
            if docHasDifference { docsWithSymbolDifference += 1 }
            if docHasUserDifference { docsWithUserDifference += 1 }

            for sample in export.spans {
                guard !sample.text.isEmpty else { continue }
                chars += sample.text.unicodeScalars.count
                for s in sample.text.unicodeScalars {
                    if s.value == 0x318D { araea += 1 }
                    if Self.narrowSymbol(s.value) { narrowSymbolChars += 1 }
                    if Self.rhwpSymbol(s.value) { rhwpSymbolChars += 1 }
                }
                guard let id = sample.csId, fonts.indices.contains(id) else { continue }
                let f = fonts[id]
                // A uniform row can never split, whichever exception is in force, so it contributes
                // one piece to all three counts and is skipped rather than walked three times.
                guard !f.isUniform else {
                    piecesBaseline += 1; piecesNarrow += 1; piecesRhwp += 1; piecesAraea += 1
                    continue
                }
                let base = ScriptRunSplitter.split(sample.text, classify: Self.baselineSlot,
                                                   family: f.family)
                let narrow = ScriptRunSplitter.split(sample.text,
                                                     classify: { Self.slot($0, symbol: Self.narrowSymbol) },
                                                     family: f.family)
                let rhwp = ScriptRunSplitter.split(sample.text,
                                                   classify: { Self.slot($0, symbol: Self.rhwpSymbol) },
                                                   family: f.family)
                let araeaSplit = ScriptRunSplitter.split(sample.text, classify: Self.slotWithAraea,
                                                         family: f.family)
                piecesBaseline += base.count
                piecesNarrow += narrow.count
                piecesRhwp += rhwp.count
                piecesAraea += araeaSplit.count
                // Structural properties, asserted on real text at corpus scale (design §8.3).
                for pieces in [base, narrow, rhwp, araeaSplit] {
                    XCTAssertEqual(pieces.map { String($0.text) }.joined(), sample.text,
                                   "pieces must concatenate to the source — \(url.lastPathComponent)")
                    XCTAssertFalse(pieces.contains { $0.text.isEmpty },
                                   "no piece may be empty — \(url.lastPathComponent)")
                }
                // Per-scalar family comparison: how many characters actually change typeface, which
                // a piece count cannot tell you (an exception can split a run and hand both halves
                // the same family).
                let baseFamilies = Self.perScalarFamilies(base)
                for (variant, counter) in [(narrow, 0), (rhwp, 1), (araeaSplit, 2)] {
                    let f2 = Self.perScalarFamilies(variant)
                    let changed = zip(baseFamilies, f2).filter { $0 != $1 }.count
                    switch counter {
                    case 0: charsRedrawnNarrow += changed
                    case 1: charsRedrawnRhwp += changed
                    default: charsRedrawnAraea += changed
                    }
                }
            }
        }

        func pct(_ n: Int, _ d: Int) -> String {
            d > 0 ? String(format: "%.1f%%", Double(n) / Double(d) * 100) : "-"
        }
        print("""
        SYMBOL/USER SLOT DECISION — \(parsed) documents parsed, \(unreadable) unreadable
          char-shape rows                         \(rows)
          rows whose Symbol family != Hangul      \(rowsSymbolDiffersFromHangul) (\(pct(rowsSymbolDiffersFromHangul, rows)))
          documents with >=1 such row             \(docsWithSymbolDifference) of \(parsed)
          rows whose User family != Hangul        \(rowsUserDiffersFromHangul) (\(pct(rowsUserDiffersFromHangul, rows)))
          documents with >=1 such row             \(docsWithUserDifference) of \(parsed)
          characters walked                       \(chars)
          chars matching the NARROW symbol list   \(narrowSymbolChars) (\(pct(narrowSymbolChars, chars)))
          chars matching RHWP's symbol list       \(rhwpSymbolChars) (\(pct(rhwpSymbolChars, chars)))
          U+318D (araea, rhwp's only User char)   \(araea)
        PIECES over the same spans        (cost)            (benefit: chars re-faced)
          absorbing symbols (no exception)        \(piecesBaseline)
          NARROW exception                        \(piecesNarrow)  (+\(piecesNarrow - piecesBaseline), \(pct(piecesNarrow - piecesBaseline, piecesBaseline)))   \(charsRedrawnNarrow)
          RHWP's full list                        \(piecesRhwp)  (+\(piecesRhwp - piecesBaseline), \(pct(piecesRhwp - piecesBaseline, piecesBaseline)))   \(charsRedrawnRhwp)
          NARROW + U+318D -> User slot            \(piecesAraea)  (+\(piecesAraea - piecesNarrow) over NARROW)   \(charsRedrawnAraea)
        """)
        XCTAssertGreaterThan(parsed, 0, "corpus produced no parseable documents")
    }

    /// Does this reader's fallback chain (slot → 0 → 1 → first non-empty) ever disagree with rhwp's
    /// own `font` field (slot 0, else slot 1)?
    ///
    /// It can, in exactly one shape: a row naming nothing in slots 0 and 1 but something further
    /// along. That row used to draw in the theme's own body font and would now draw in the family the
    /// document declared — an improvement, but a CHANGE, and one that lands on the uniform fast path
    /// where invariant 37 promises byte-identity. So it is counted rather than assumed away, and the
    /// count is what justifies keeping rhwp's own answer on the uniform path.
    /// Which real documents this feature actually CHANGES, and by how much — the list proof 2 of
    /// `docs/per-script-font-design.md` §8 is picked from, and the answer to "is a corpus-wide
    /// percentage hiding the fact that no single file visibly improves".
    ///
    /// Computable in ONE binary because the before-state is known exactly: rhwp's own `font` field is
    /// what every span used to carry. So a span CHANGED if the pieces it now produces differ from one
    /// piece carrying that font — either because it split, or because its single family moved.
    func testWhichDocumentsChange() throws {
        let files = try corpusFiles()
        struct Change { let name: String; let spansSplit: Int; let spansRefaced: Int; let example: String }
        var changed: [Change] = []
        var unchangedDocs = 0
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let json = HwpReader.exportDocumentJSON(data),
                  let export = try? HwpReader.fontSlotExport(json) else { continue }
            let fonts = export.charShapes.map { HwpSlotFonts(row: $0) }
            var split = 0, refaced = 0
            var example = ""
            for sample in export.spans {
                guard !sample.text.isEmpty, let id = sample.csId, fonts.indices.contains(id),
                      !fonts[id].isUniform else { continue }
                let was = (sample.font?.isEmpty == false) ? sample.font : nil
                let pieces = ScriptRunSplitter.split(sample.text, classify: HwpSlotTable.slot(for:),
                                                     family: fonts[id].family)
                if pieces.count > 1 {
                    split += 1
                    if example.isEmpty, pieces.count >= 2,
                       pieces.contains(where: { $0.family != was }) {
                        example = pieces.map { "\(String($0.text).prefix(24).debugDescription)->\($0.family ?? "nil")" }
                            .prefix(4).joined(separator: " | ") + "   (was all \(was ?? "nil"))"
                    }
                }
                refaced += pieces.filter { $0.family != was }
                    .reduce(0) { $0 + $1.text.unicodeScalars.count }
            }
            if split > 0 || refaced > 0 {
                changed.append(Change(name: url.lastPathComponent, spansSplit: split,
                                      spansRefaced: refaced, example: example))
            } else {
                unchangedDocs += 1
            }
        }
        changed.sort { $0.spansRefaced > $1.spansRefaced }
        print("""
        DOCUMENTS THIS FEATURE CHANGES — \(changed.count) changed, \(unchangedDocs) unchanged
        top 12 by characters re-faced:
        """)
        for c in changed.prefix(12) {
            print("  \(c.name)\n     spansSplit=\(c.spansSplit) charsRefaced=\(c.spansRefaced)\n     \(c.example)")
        }
    }

    /// Compared against the `font` field rhwp ACTUALLY EXPORTED for each span, not against a
    /// re-derivation of rhwp's rule from the same row. The distinction is the whole point: rhwp's
    /// `lookup_font_name` applies its own web-oriented substitution before we see a name, and that
    /// substitution is `lang_index`-sensitive (`resolve_legacy_latin_font` early-returns unless the
    /// index is 1). Re-deriving "slot 0 else slot 1" from the row therefore proves the ROW is
    /// self-consistent and says nothing about whether it matches the string the span carries — which
    /// is the string this reader has been drawing all along, and the one byte-identity is owed to.
    func testFallbackChainAgreesWithTheParsersOwnFontField() throws {
        let files = try corpusFiles()
        var parsed = 0, rows = 0, bothSlotsEmpty = 0
        var spansCompared = 0, spansDisagreeing = 0
        var examples: [String] = []
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let json = HwpReader.exportDocumentJSON(data),
                  let export = try? HwpReader.fontSlotExport(json) else { continue }
            parsed += 1
            let fonts = export.charShapes.map { HwpSlotFonts(row: $0) }
            for row in export.charShapes {
                rows += 1
                let slot0 = row.count > 0 && !row[0].isEmpty
                let slot1 = row.count > 1 && !row[1].isEmpty
                if !slot0 && !slot1 { bothSlotsEmpty += 1 }
            }
            for sample in export.spans {
                guard let id = sample.csId, fonts.indices.contains(id) else { continue }
                spansCompared += 1
                let exported = (sample.font?.isEmpty == false) ? sample.font : nil
                if fonts[id].neutralFamily != exported {
                    spansDisagreeing += 1
                    if examples.count < 8 {
                        examples.append("\(url.lastPathComponent): row=\(export.charShapes[id]) "
                                        + "chain=\(fonts[id].neutralFamily ?? "nil") exported=\(exported ?? "nil")")
                    }
                }
            }
        }
        print("""
        FALLBACK CHAIN vs the `font` rhwp ACTUALLY EXPORTED — \(parsed) documents
          char-shape rows                    \(rows)
          rows with slots 0 AND 1 both empty \(bothSlotsEmpty)
          spans compared                     \(spansCompared)
          spans where the chain DISAGREES    \(spansDisagreeing)
        """)
        for e in examples { print("  \(e)") }
    }
}
