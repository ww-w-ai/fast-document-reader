import XCTest
import AppKit
@testable import FastDocReader

/// Whether the fonts real Korean documents NAME are fonts this machine has — the measurement that
/// decides whether HWP's own substitution fields (`Font.alt_name`, `subst_font`, `is_embedded`) are
/// worth exporting and honouring, or whether they would serve almost nobody.
///
///     FMD_HWP_FONT_AVAILABILITY="/path/to/hwp/files:/another/dir" \
///       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --filter HwpDeclaredFontProbeTests
///
/// Skipped by default: it needs documents this repo does not ship. A document's declared font
/// decides every glyph's WIDTH, so a name this machine cannot resolve means every line in that
/// paragraph is measured against a different face than the document was written with — and a line
/// width is a line count, which is a page count. What the probe cannot answer, and deliberately
/// does not try to, is whether the document's OWN named substitute would resolve any better; that
/// needs an export this parser does not yet send, and this measurement is what decides whether to
/// add it.
final class HwpDeclaredFontProbeTests: XCTestCase {

    private func corpusFiles() throws -> [URL] {
        guard let dirs = ProcessInfo.processInfo.environment["FMD_HWP_FONT_AVAILABILITY"], !dirs.isEmpty else {
            throw XCTSkip("set FMD_HWP_FONT_AVAILABILITY to colon-separated directories of HWP files")
        }
        let fm = FileManager.default
        var files: [URL] = []
        var skipped = 0
        for dir in dirs.split(separator: ":").map(String.init) {
            let e = fm.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil,
                                  options: [.skipsHiddenFiles],
                                  errorHandler: { _, _ in skipped += 1; return true })
            while let u = e?.nextObject() as? URL {
                if ["hwp", "hwpx"].contains(u.pathExtension.lowercased()) { files.append(u) }
            }
        }
        if skipped > 0 { print("FONTPROBE dirsSkipped=\(skipped)") }
        var seen = Set<String>()
        return files.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
    }

    /// Shared corpus walk for every test in this file: which PRIMARY font name is missing from this
    /// machine, how many char-shape slots ask for it, and in how many documents. Counted against the
    /// PRIMARY name throughout — rhwp hands over a CSS-style list for some faces ("A, B"), the first
    /// name is the one the document asked for and the rest are rhwp's own web fallbacks, and
    /// `NSFont(name:)` is only ever asked about that first name — so weight/breadth have to be kept
    /// under the SAME key resolvability was decided under, or a name inside one of those lists would
    /// have its slots/docs silently undercounted against the full untouched string instead.
    private struct FontUsage {
        var filesCount = 0
        var parsed = 0
        var unreadable = 0
        var slots = 0
        var slotsUnresolvable = 0
        var docsWithAnyUnresolvable = 0
        /// Count of distinct primary names asked about at all (resolvable or not).
        var distinctNames = 0
        /// unresolved primary name -> (slots, docs).
        var missing: [String: (slots: Int, docs: Int)] = [:]
    }

    private func measureFontUsage(_ files: [URL]) -> FontUsage {
        var u = FontUsage()
        u.filesCount = files.count
        var slotsByPrimary: [String: Int] = [:]
        var docsByPrimary: [String: Int] = [:]
        var resolvable: [String: Bool] = [:]

        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let json = HwpReader.exportDocumentJSON(data),
                  let export = try? HwpReader.fontSlotExport(json) else { u.unreadable += 1; continue }
            u.parsed += 1
            var primariesHere = Set<String>()
            var docHasUnresolvable = false
            for row in export.charShapes {
                for name in row {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    let primary = trimmed.split(separator: ",").first.map(String.init)?
                        .trimmingCharacters(in: .whitespaces) ?? trimmed
                    guard !primary.isEmpty else { continue }
                    u.slots += 1
                    slotsByPrimary[primary, default: 0] += 1
                    primariesHere.insert(primary)
                    let ok = resolvable[primary] ?? {
                        let v = NSFont(name: primary, size: 12) != nil
                        resolvable[primary] = v
                        return v
                    }()
                    if !ok { u.slotsUnresolvable += 1; docHasUnresolvable = true }
                }
            }
            for p in primariesHere { docsByPrimary[p, default: 0] += 1 }
            if docHasUnresolvable { u.docsWithAnyUnresolvable += 1 }
        }

        u.distinctNames = resolvable.count
        for (name, ok) in resolvable where !ok {
            u.missing[name] = (slotsByPrimary[name] ?? 0, docsByPrimary[name] ?? 0)
        }
        return u
    }

    func testHowOftenADeclaredFontIsMissingFromThisMachine() throws {
        let files = try corpusFiles()
        let u = measureFontUsage(files)
        let missingSorted = u.missing.keys.sorted { (u.missing[$0]?.slots ?? 0) > (u.missing[$1]?.slots ?? 0) }

        print("""
        FONTPROBE files=\(u.filesCount) parsed=\(u.parsed) unreadable=\(u.unreadable)
        FONTPROBE slots=\(u.slots) unresolvable=\(u.slotsUnresolvable) distinctNames=\(u.distinctNames) distinctMissing=\(missingSorted.count) docsWithAnyMissing=\(u.docsWithAnyUnresolvable)
        """)
        for name in missingSorted.prefix(25) {
            let row = u.missing[name] ?? (0, 0)
            print("FONTPROBE missing \(name) slots=\(row.slots) docs=\(row.docs)")
        }

        XCTAssertGreaterThan(u.parsed, 0, "no document could be read — the probe measured nothing")
        XCTAssertGreaterThan(u.slots, 0, "no char shape carried a font name — the export path is broken")
    }

    /// The complete list invariant 95 could not show: EVERY unresolved primary name, not just the
    /// top 25, each with a typographic CLASS decided by a morpheme. A Korean font name wraps a vendor
    /// prefix (HY/한컴/함초롬/한양/Yoon/MD…) and a weight suffix (Bold/Light/굵은/견/태/세/중…) around a
    /// root that actually says serif or sans — matching that root as a SUBSTRING catches every
    /// prefixed/suffixed variant for free, which is why `classifyFontName`'s table stays short. A name
    /// with no Hangul and no matching root is a genuinely Western font (`latin`) — a different problem
    /// from the Korean-face mapping this classification exists to size; a name that IS Korean but
    /// matches no root (`unclassified`) is the residue a human has to rule on.
    func testFullUnresolvedFontDumpWithMorphology() throws {
        let files = try corpusFiles()
        let u = measureFontUsage(files)
        let missingSorted = u.missing.keys.sorted { (u.missing[$0]?.slots ?? 0) > (u.missing[$1]?.slots ?? 0) }

        var byNameClass: [String: Int] = [:], bySlotsClass: [String: Int] = [:], byDocsClass: [String: Int] = [:]
        print("FONTPROBE dumpFiles=\(u.filesCount) parsed=\(u.parsed) unreadable=\(u.unreadable) totalUnresolvableSlots=\(u.slotsUnresolvable) distinctMissing=\(missingSorted.count)")
        for name in missingSorted {
            let row = u.missing[name] ?? (0, 0)
            let (cls, morpheme) = Self.classifyFontName(name)
            byNameClass[cls, default: 0] += 1
            bySlotsClass[cls, default: 0] += row.slots
            byDocsClass[cls, default: 0] += row.docs
            print("FONTPROBE dump \(name) slots=\(row.slots) docs=\(row.docs) class=\(cls) morpheme=\(morpheme)")
        }

        let classes = ["serif", "sans", "mono", "symbol", "latin", "unclassified"]
        func summaryLine(_ tag: String, _ counts: [String: Int], _ total: Int) -> String {
            classes.map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: " ").isEmpty ? "" :
                "FONTPROBE \(tag) " + classes.map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: " ") + " total=\(total)"
        }
        print(summaryLine("classByName", byNameClass, missingSorted.count))
        print(summaryLine("classBySlots", bySlotsClass, u.slotsUnresolvable))
        print(summaryLine("classByDocs", byDocsClass, u.docsWithAnyUnresolvable))

        let unclassifiedNames = byNameClass["unclassified"] ?? 0
        let unclassifiedSlots = bySlotsClass["unclassified"] ?? 0
        let classifiableNames = missingSorted.count - unclassifiedNames
        let classifiableSlots = u.slotsUnresolvable - unclassifiedSlots
        let fracByName = missingSorted.isEmpty ? 0 : Double(classifiableNames) / Double(missingSorted.count) * 100
        let fracBySlots = u.slotsUnresolvable == 0 ? 0 : Double(classifiableSlots) / Double(u.slotsUnresolvable) * 100
        print(String(format: "FONTPROBE classifiableFraction byName=%.1f%% (%d/%d) bySlots=%.1f%% (%d/%d)",
                     fracByName, classifiableNames, missingSorted.count,
                     fracBySlots, classifiableSlots, u.slotsUnresolvable))

        XCTAssertGreaterThan(u.parsed, 0, "no document could be read — the probe measured nothing")
        XCTAssertGreaterThan(missingSorted.count, 0, "no unresolved name found — the resolvability check is broken")
    }

    // MARK: - Morphology
    //
    // A Korean font family name wraps a vendor prefix (HY/한컴/함초롬/한양/Yoon/MD…) and a weight
    // suffix (Bold/Light/굵은/견/태/세/중/B/L/M/EB…) around a root that decides serif vs sans. Matching
    // the root as a SUBSTRING catches every prefixed/suffixed combination without spelling each one
    // out — "HY중고딕", "한양중고딕", "맑은 고딕", "함초롬돋움" all carry a sans root. This table was
    // built by reading the actual distinct-missing list (docs/06-research/2026-08-18-font-dump-full.md),
    // not assumed ahead of it — grow it there first if a name turns up that should not be `unclassified`.

    private static let monoMorphemes = ["고정폭", "타자기", "Mono", "Console", "Consolas", "Courier", "Typewriter"]
    private static let symbolMorphemes = ["Wingding", "Webding", "Marlett", "Symbol", "Dingbat", "기호"]
    /// Korean sans root, plus its own English romanisation — "Haansoft Batang"/"HCR Dotum" name a
    /// Korean face using only Latin letters, so the romanised form has to be checked too, not just Hangul.
    private static let sansMorphemes = ["고딕", "돋움", "굴림", "Gothic", "Dotum", "Gulim", "Sans"]
    /// "Myungjo" and "Gungsuh" are second romanisations of 명조/궁서 this table missed on the first
    /// pass — caught by running the classifier against the real 265 and finding them stuck in `latin`
    /// (a Latin-spelled Korean name is not the same fact as a Western one; see below).
    private static let serifMorphemes = ["명조", "바탕", "궁서", "옛체", "Myeongjo", "Myungjo", "Batang",
                                          "Gungseo", "Gungsuh", "Serif", "Ming"]
    /// A name using ONLY Latin letters is not the same fact as a Western font — "HYHeadLine-Medium",
    /// "HYhaeseo" and "HCI Poppy" name Korean vendor faces (한양시스템/한컴 계열) whose specific root
    /// (헤드라인/해서/…) is not in the table above, so without this check they fell to `latin` next to
    /// genuinely Western names like Palatino Linotype — a wrong fact, not just a missing one. Anchored
    /// at the START of the string (not a bare `contains`) because "HY"/"HCI" are short enough to appear
    /// inside an unrelated word by accident. Built by reading every `latin`-bucket name this table
    /// produced, not assumed ahead of it — see docs/06-research/2026-08-18-font-dump-full.md.
    private static let koreanVendorPrefixes = ["HY", "HCI"]

    private static func containsHangul(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0xAC00...0xD7A3).contains($0.value) ||   // syllables
            (0x1100...0x11FF).contains($0.value) ||   // jamo
            (0x3130...0x318F).contains($0.value)      // compat jamo
        }
    }

    /// `class` and the substring (or signal) that decided it. `latin` = no Hangul, no known root, and
    /// no Korean vendor prefix: a genuinely Western/foreign font name. `unclassified` = Korean by
    /// script OR by vendor prefix, but no root matched: the residue for a human ruling.
    private static func classifyFontName(_ raw: String) -> (cls: String, morpheme: String) {
        for m in monoMorphemes where raw.localizedCaseInsensitiveContains(m) { return ("mono", m) }
        for m in symbolMorphemes where raw.localizedCaseInsensitiveContains(m) { return ("symbol", m) }
        for m in sansMorphemes where raw.localizedCaseInsensitiveContains(m) { return ("sans", m) }
        for m in serifMorphemes where raw.localizedCaseInsensitiveContains(m) { return ("serif", m) }
        if containsHangul(raw) { return ("unclassified", "none") }
        for p in koreanVendorPrefixes where raw.hasPrefix(p) { return ("unclassified", "vendor:\(p)") }
        return ("latin", "no-hangul")
    }

    /// The follow-up question the first measurement raises: when the declared font is missing, does
    /// the DOCUMENT's own nominated substitute resolve any better than the reader's fallback would?
    /// If it does not, HWP's `alt_name`/`substFont` are dead weight for this reader and saying so
    /// with a number is the point — see invariant 95.
    func testWhetherTheDocumentsOwnSubstituteResolves() throws {
        let files = try corpusFiles()
        var parsed = 0, unreadable = 0, faces = 0
        var missingPrimary = 0, hasAlt = 0, altResolves = 0
        var embedded = 0, embeddedWithBytes = 0, hft = 0
        var docsWithEmbedded = 0, docsWhereAltHelps = 0, docsWithFontTable = 0
        var altHelpers: [String: Int] = [:]
        var resolvable: [String: Bool] = [:]
        func resolves(_ name: String) -> Bool {
            let primary = name.split(separator: ",").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? name
            guard !primary.isEmpty else { return false }
            if let v = resolvable[primary] { return v }
            let v = NSFont(name: primary, size: 12) != nil
            resolvable[primary] = v
            return v
        }

        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let json = HwpReader.exportDocumentJSON(data),
                  let export = try? HwpReader.fontSlotExport(json) else { unreadable += 1; continue }
            parsed += 1
            if !export.fontFaces.isEmpty { docsWithFontTable += 1 }
            var docEmbedded = false, docAltHelps = false
            for slot in export.fontFaces {
                for face in slot {
                    faces += 1
                    if face.type == 2 { hft += 1 }
                    if face.embedded == true {
                        embedded += 1
                        docEmbedded = true
                        if face.binDataId != nil { embeddedWithBytes += 1 }
                    }
                    guard !resolves(face.name) else { continue }
                    missingPrimary += 1
                    guard let alt = face.altName, !alt.isEmpty else { continue }
                    hasAlt += 1
                    if resolves(alt) {
                        altResolves += 1
                        docAltHelps = true
                        altHelpers[alt, default: 0] += 1
                    }
                }
            }
            if docEmbedded { docsWithEmbedded += 1 }
            if docAltHelps { docsWhereAltHelps += 1 }
        }

        print("""
        SUBSTPROBE files=\(files.count) parsed=\(parsed) unreadable=\(unreadable) docsWithFontTable=\(docsWithFontTable)
        SUBSTPROBE faces=\(faces) missingPrimary=\(missingPrimary) hasAlt=\(hasAlt) altResolves=\(altResolves) docsWhereAltHelps=\(docsWhereAltHelps)
        SUBSTPROBE embedded=\(embedded) withBytes=\(embeddedWithBytes) docsWithEmbedded=\(docsWithEmbedded) hftFaces=\(hft)
        """)
        for (name, n) in altHelpers.sorted(by: { $0.value > $1.value }).prefix(10) {
            print("SUBSTPROBE altResolvesTo \(name) times=\(n)")
        }

        XCTAssertGreaterThan(parsed, 0, "no document could be read — the probe measured nothing")
        // The export itself: a rename on either side decodes to an empty table and every number
        // above would read as a confident zero.
        XCTAssertGreaterThan(docsWithFontTable, 0, "no document carried a font table — the export broke")
    }
}
