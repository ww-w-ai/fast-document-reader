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

    func testHowOftenADeclaredFontIsMissingFromThisMachine() throws {
        let files = try corpusFiles()
        var parsed = 0, unreadable = 0
        // Per NAME: how many char-shape slots asked for it, and in how many documents.
        var slotsByName: [String: Int] = [:]
        var docsByName: [String: Int] = [:]
        var resolvable: [String: Bool] = [:]
        var slots = 0, slotsUnresolvable = 0, docsWithAnyUnresolvable = 0

        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let json = HwpReader.exportDocumentJSON(data),
                  let export = try? HwpReader.fontSlotExport(json) else { unreadable += 1; continue }
            parsed += 1
            var namesHere = Set<String>()
            var docHasUnresolvable = false
            for row in export.charShapes {
                for name in row {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    slots += 1
                    slotsByName[trimmed, default: 0] += 1
                    namesHere.insert(trimmed)
                    // rhwp hands over a CSS-style list for some faces ("A, B"); the first name is
                    // the one the document asked for and the rest are rhwp's own web fallbacks, so
                    // asking about the whole string would report every one of them as missing.
                    let primary = trimmed.split(separator: ",").first.map(String.init)?
                        .trimmingCharacters(in: .whitespaces) ?? trimmed
                    let ok = resolvable[primary] ?? {
                        let v = NSFont(name: primary, size: 12) != nil
                        resolvable[primary] = v
                        return v
                    }()
                    if !ok { slotsUnresolvable += 1; docHasUnresolvable = true }
                }
            }
            for n in namesHere { docsByName[n, default: 0] += 1 }
            if docHasUnresolvable { docsWithAnyUnresolvable += 1 }
        }

        let missing = resolvable.filter { !$0.value }.keys.sorted {
            (slotsByName[$0] ?? 0) > (slotsByName[$1] ?? 0)
        }
        print("""
        FONTPROBE files=\(files.count) parsed=\(parsed) unreadable=\(unreadable)
        FONTPROBE slots=\(slots) unresolvable=\(slotsUnresolvable) distinctNames=\(resolvable.count) distinctMissing=\(missing.count) docsWithAnyMissing=\(docsWithAnyUnresolvable)
        """)
        for name in missing.prefix(25) {
            print("FONTPROBE missing \(name) slots=\(slotsByName[name] ?? 0) docs=\(docsByName[name] ?? 0)")
        }

        XCTAssertGreaterThan(parsed, 0, "no document could be read — the probe measured nothing")
        XCTAssertGreaterThan(slots, 0, "no char shape carried a font name — the export path is broken")
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
