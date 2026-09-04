import XCTest
@testable import FastDocReader

/// P1 — a document the app opens is PARSED once.
///
/// Reading a document and opening a handle to it were two calls that each performed the same
/// `read_office`, and the app made both on every open: `read(from:)` asked the engine for the
/// content, then `setOfficeContent` opened a handle for the engine's queries. Measured on
/// `2025_행정업무운영편람_최종.hwp` (release): 565 ms of the second read, thrown away — 47% of the
/// 1,212 ms the whole pre-cutover build spent on that document's `--extract`.
///
/// Nothing caught it, and nothing could have: the two parses read the same bytes with the same
/// parser, so they always agreed. This is invariant 103's shape one layer down — asking twice and
/// asking once are indistinguishable by their answers, so the CALL has to be counted, not the
/// answer compared. `RustEngine.documentReads` is that count.
///
/// Judged by a count rather than by a clock, deliberately: this suite is a documented false-failure
/// under load, and a parse count is the same number on a busy machine (invariant 113).
final class OfficeSingleReadTests: XCTestCase {
    /// The second half of this gate. `reads == 1` is also what a build produces when it takes the
    /// export path and opens NO handle at all — a different regression (every engine query silently
    /// falls back to the host's own arithmetic) that would read as a pass here. Asserting the
    /// handle exists is what tells the two apart.
    private func assertParsedOnce(
        _ doc: MarkdownDocument, reads: Int, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(reads, 1, "the document was parsed \(reads) times, not once", file: file, line: line)
        XCTAssertNotNil(
            doc.officeEngineHandle,
            "one parse, but no handle — every engine query on this document falls back to the host",
            file: file, line: line)
        XCTAssertFalse(
            doc.officeBlocks.isEmpty,
            "vacuous: this document produced no blocks, so nothing here measured a real read",
            file: file, line: line)
    }

    func testOpeningAZipBackedDocumentParsesItExactlyOnce() throws {
        // The extension comes off `fileURL`, not off the UTI — a document with no URL takes the
        // plain-text path and never reaches an office reader at all.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("p1-single-read-\(UUID().uuidString).docx")
        try fixtureDocx().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let doc = MarkdownDocument()
        doc.fileURL = url
        let (_, reads) = try RustEngine.countingDocumentReads {
            try doc.read(from: data, ofType: "org.openxmlformats.wordprocessingml.document")
        }
        assertParsedOnce(doc, reads: reads)
    }

    func testOpeningAHwpParsesItExactlyOnce() throws {
        let url = URL(fileURLWithPath: "Vendor/rhwp-src/samples/footnote-01.hwp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("needs \(url.path) — a committed HWP sample")
        }
        let data = try Data(contentsOf: url)
        let doc = MarkdownDocument()
        doc.fileURL = url
        let (_, reads) = try RustEngine.countingDocumentReads {
            try doc.read(from: data, ofType: "hwp")
        }
        assertParsedOnce(doc, reads: reads)
    }

    /// ⌘R had the same pair of parses as a first open, and for the same reason — invariant 29's
    /// rule that a reload must behave the same as a first open cuts both ways, including cost.
    func testReloadingADocumentParsesItExactlyOnce() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("p1-single-read-\(UUID().uuidString).docx")
        try fixtureDocx().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url),
                     ofType: "org.openxmlformats.wordprocessingml.document")
        let (_, reads) = RustEngine.countingDocumentReads { doc.reloadDocument(nil) }
        assertParsedOnce(doc, reads: reads)
    }

    // MARK: - fixture

    private func fixtureDocx() -> Data {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p><w:r><w:t>Alpha bravo charlie</w:t></w:r></w:p>
        </w:body></w:document>
        """
        return buildZip([("word/document.xml", Data(document.utf8))])
    }

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private func buildZip(_ entries: [(name: String, content: Data)]) -> Data {
        struct Prepared { let nameBytes: [UInt8]; let content: Data; let localOffset: Int }
        var body = [UInt8]()
        var prepared: [Prepared] = []
        for (name, content) in entries {
            let nameBytes = Array(name.utf8)
            let localOffset = body.count
            body += le32(0x0403_4b50)
            body += le16(20)
            body += le16(0)
            body += le16(0)
            body += le16(0) + le16(0)
            body += le32(0)
            body += le32(UInt32(content.count))
            body += le32(UInt32(content.count))
            body += le16(UInt16(nameBytes.count))
            body += le16(0)
            body += nameBytes
            body += Array(content)
            prepared.append(Prepared(nameBytes: nameBytes, content: content, localOffset: localOffset))
        }
        var centralDirectory = [UInt8]()
        for p in prepared {
            centralDirectory += le32(0x0201_4b50)
            centralDirectory += le16(20) + le16(20)
            centralDirectory += le16(0)
            centralDirectory += le16(0)
            centralDirectory += le16(0) + le16(0)
            centralDirectory += le32(0)
            centralDirectory += le32(UInt32(p.content.count))
            centralDirectory += le32(UInt32(p.content.count))
            centralDirectory += le16(UInt16(p.nameBytes.count))
            centralDirectory += le16(0)
            centralDirectory += le16(0)
            centralDirectory += le16(0)
            centralDirectory += le16(0)
            centralDirectory += le32(0)
            centralDirectory += le32(UInt32(p.localOffset))
            centralDirectory += p.nameBytes
        }
        let centralDirectoryOffset = body.count
        var archive = body + centralDirectory
        archive += le32(0x0605_4b50)
        archive += le16(0) + le16(0)
        archive += le16(UInt16(entries.count))
        archive += le16(UInt16(entries.count))
        archive += le32(UInt32(centralDirectory.count))
        archive += le32(UInt32(centralDirectoryOffset))
        archive += le16(0)
        return Data(archive)
    }
}
