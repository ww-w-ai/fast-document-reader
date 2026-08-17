import XCTest
@testable import FastDocReader

/// What real Korean documents actually SAY about line breaking — the measurement that decides which
/// of HWP's five line-fitting declarations are worth honouring and which are dead bits.
///
///     FMD_HWP_BREAK_PROBE="/path/to/hwp/files:/another/dir" \
///       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --filter HwpLineBreakProbeTests
///
/// Skipped by default: it needs documents this repo does not ship. Five bits arrived together in one
/// export, and honouring one of them costs a paragraph attribute on every paragraph of every HWP
/// file — so "does any document set this, and how often" is a question to answer with a corpus
/// rather than from the format's shape. It reports; the only thing it asserts is that the decode
/// produced a value at all, which is what a rename on either side of the JSON would break silently.
final class HwpLineBreakProbeTests: XCTestCase {

    private func corpusFiles() throws -> [URL] {
        guard let dirs = ProcessInfo.processInfo.environment["FMD_HWP_BREAK_PROBE"], !dirs.isEmpty else {
            throw XCTSkip("set FMD_HWP_BREAK_PROBE to colon-separated directories of HWP files")
        }
        let fm = FileManager.default
        var files: [URL] = []
        var skipped = 0
        for dir in dirs.split(separator: ":").map(String.init) {
            // Invariant 35: without an explicit error handler the walk stops at the first unreadable
            // directory and silently under-reports its own input.
            let e = fm.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil,
                                  options: [.skipsHiddenFiles],
                                  errorHandler: { _, _ in skipped += 1; return true })
            while let u = e?.nextObject() as? URL {
                if ["hwp", "hwpx"].contains(u.pathExtension.lowercased()) { files.append(u) }
            }
        }
        if skipped > 0 { print("BREAKPROBE dirsSkipped=\(skipped)") }
        var seen = Set<String>()
        return files.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
    }

    /// Every paragraph of every reachable document, counted by what it declared.
    func testWhatDocumentsDeclareAboutLineFitting() throws {
        let files = try corpusFiles()
        var parsed = 0, unreadable = 0, paragraphs = 0
        var hangulWord = 0, hangulChar = 0, hangulUnstated = 0
        var latinWord = 0, latinHyphen = 0, latinChar = 0, latinUnstated = 0
        var autoSpaceLatin = 0, autoSpaceNumber = 0, fontLineHeight = 0
        // A document counts once for each setting it uses ANYWHERE — a bit set by one paragraph in
        // one file is a different proposition from one set by every paragraph of every file.
        var docsHangulChar = 0, docsLatinNonWord = 0, docsAutoSpace = 0, docsFontLineHeight = 0

        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let result = try? HwpReader.read(data) else { unreadable += 1; continue }
            parsed += 1
            var docHangulChar = false, docLatinNonWord = false, docAutoSpace = false, docFontLH = false
            for block in result.blocks {
                // Only paragraphs the reader built from a real HWP paragraph. The reader also emits
                // an EMPTY `.paragraph` as the standing-in block for an object it could not render
                // (`HwpReader` has five such sites), and those carry a default format that no
                // document ever spoke — counting them as "the document said nothing" would put a
                // floor under every number here that no measurement could ever clear.
                guard let (f, spans) = Self.formatAndSpans(of: block), !spans.isEmpty else { continue }
                paragraphs += 1
                switch f.eastAsianLineBreak {
                case .word: hangulWord += 1
                case .character: hangulChar += 1; docHangulChar = true
                case .hyphen: hangulChar += 1          // not a Hangul value; counted so none is lost
                case nil: hangulUnstated += 1
                }
                switch f.latinLineBreak {
                case .word: latinWord += 1
                case .hyphen: latinHyphen += 1; docLatinNonWord = true
                case .character: latinChar += 1; docLatinNonWord = true
                case nil: latinUnstated += 1
                }
                if f.autoSpaceEastAsianLatin == true { autoSpaceLatin += 1; docAutoSpace = true }
                if f.autoSpaceEastAsianNumber == true { autoSpaceNumber += 1; docAutoSpace = true }
                if f.lineHeightFromFontMetrics == true { fontLineHeight += 1; docFontLH = true }
            }
            if docHangulChar { docsHangulChar += 1 }
            if docLatinNonWord { docsLatinNonWord += 1 }
            if docAutoSpace { docsAutoSpace += 1 }
            if docFontLH { docsFontLineHeight += 1 }
        }

        print("""
        BREAKPROBE files=\(files.count) parsed=\(parsed) unreadable=\(unreadable) paragraphs=\(paragraphs)
        BREAKPROBE hangul  word=\(hangulWord) char=\(hangulChar) unstated=\(hangulUnstated) docsWithChar=\(docsHangulChar)
        BREAKPROBE latin   word=\(latinWord) hyphen=\(latinHyphen) char=\(latinChar) unstated=\(latinUnstated) docsWithNonWord=\(docsLatinNonWord)
        BREAKPROBE autoSpace latin=\(autoSpaceLatin) number=\(autoSpaceNumber) docs=\(docsAutoSpace)
        BREAKPROBE fontLineHeight paragraphs=\(fontLineHeight) docs=\(docsFontLineHeight)
        """)

        XCTAssertGreaterThan(parsed, 0, "no document could be read — the probe measured nothing")
        // The decode itself, not the numbers: a JSON key renamed on either side decodes to nil, and
        // every paragraph would silently read as "unstated" while every count above stayed plausible.
        XCTAssertEqual(hangulUnstated, 0,
                       "every HWP paragraph carries a Hangul break unit — nil means the decode broke")
    }

    private static func formatAndSpans(of block: OfficeBlock) -> (ParagraphFormat, [Span])? {
        switch block {
        case .paragraph(let spans, _, _, _, let f): return (f, spans)
        case .heading(_, let spans, _, _, _, let f): return (f, spans)
        default: return nil
        }
    }
}
