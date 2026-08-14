import XCTest
import AppKit
@testable import FastDocReader

/// **Invariant 29 for this pass: a unit test on the resolver cannot tell you the resolver is
/// REACHED.** `FontSubstitutionResolverTests` calls `FontSubstitutionResolver` and
/// `OfficeBlock.resolvingFontSubstitution` directly, which proves the algorithm and says nothing
/// about the application — the same blindness that let `.odt` ship registered, parsed, covered by 24
/// passing tests, and completely unopenable. This file drives a real `.docx` through
/// `DocumentTypes.readOffice`, the ONE dispatch `MarkdownDocument` and `--extract` both use, and
/// asserts the substitution arrived on the spans that came back.
///
/// It matters more here than it looks: this change moved the resolution from a per-block map to a
/// SURVEY-then-APPLY pair, and a dispatch that called only the apply half would produce a document
/// with an empty plan — every span untouched, no error, no failing unit test, and the whole feature
/// silently dead. That is precisely the failure mode invariant 29 exists for.
final class FontSubstitutionDispatchTests: XCTestCase {
    // MARK: A real (stored-only) ZIP, built in memory — same shape as `DocxReaderTests`'s builder

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
            body += le32(0x0403_4b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            body += le32(UInt32(content.count)) + le32(UInt32(content.count))
            body += le16(UInt16(nameBytes.count)) + le16(0) + nameBytes + Array(content)
            prepared.append(Prepared(nameBytes: nameBytes, content: content, localOffset: localOffset))
        }
        var central = [UInt8]()
        for p in prepared {
            central += le32(0x0201_4b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
            central += le32(0) + le32(UInt32(p.content.count)) + le32(UInt32(p.content.count))
            central += le16(UInt16(p.nameBytes.count)) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            central += le32(UInt32(p.localOffset)) + p.nameBytes
        }
        let centralOffset = body.count
        var archive = body + central
        archive += le32(0x0605_4b50) + le16(0) + le16(0)
        archive += le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        archive += le32(UInt32(central.count)) + le32(UInt32(centralOffset)) + le16(0)
        return Data(archive)
    }

    private func docx(_ body: String) -> Data {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document><w:body>\(body)</w:body></w:document>"
        return buildZip([(name: "word/document.xml", content: Data(xml.utf8))])
    }

    private func everySpan(in blocks: [OfficeBlock]) -> [Span] {
        blocks.flatMap { block -> [Span] in
            switch block {
            case let .heading(_, spans, _, _, _, _), let .paragraph(spans, _, _, _, _):
                return spans
            case let .listItem(_, _, spans, _, _, _, _, _, _):
                return spans
            case let .table(rows, _, _, _):
                return rows.flatMap { $0.flatMap { everySpan(in: $0.blocks) } }
            case .image, .unsupportedGraphic, .formula:
                return []
            }
        }
    }

    /// A Korean paragraph whose runs name **Times New Roman** — what Word writes into the ascii slot
    /// by default, installed on this machine, and unable to draw a single Hangul syllable. Through
    /// the real dispatch it must come back carrying a substitute.
    func testAKoreanDocxIsSubstitutedThroughTheRealReadOfficeDispatch() throws {
        try XCTSkipIf(NSFont(name: "Times New Roman", size: 12) == nil, "Times New Roman not installed")
        let body = """
        <w:p><w:r><w:rPr><w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" \
        w:eastAsia="Times New Roman"/></w:rPr><w:t>가나다라마바사아자차카타파하 한글 본문입니다</w:t></w:r></w:p>
        """
        let result = try DocumentTypes.readOffice(try ZipArchive(data: docx(body)), extension: "docx")
        let spans = everySpan(in: result.blocks)
        XCTAssertFalse(spans.isEmpty, "the fixture must produce spans at all")
        XCTAssertTrue(spans.contains { $0.resolvedFontDescriptor != nil },
                      "the read-time substitution must be REACHED by the real dispatch, not merely " +
                      "exist — spans came back as \(spans.map { ($0.text, $0.resolvedFontDescriptor != nil) })")
    }

    /// The other side of the same dispatch, and invariant 37 through it: an ordinary English document
    /// declaring an installed family that draws its own text comes back completely untouched.
    func testAnEnglishDocxIsUntouchedThroughTheRealReadOfficeDispatch() throws {
        try XCTSkipIf(NSFont(name: "Times New Roman", size: 12) == nil, "Times New Roman not installed")
        let body = """
        <w:p><w:r><w:rPr><w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman"/></w:rPr>\
        <w:t>The auditor reviewed the quarterly statements carefully.</w:t></w:r></w:p>
        """
        let result = try DocumentTypes.readOffice(try ZipArchive(data: docx(body)), extension: "docx")
        let spans = everySpan(in: result.blocks)
        XCTAssertFalse(spans.isEmpty)
        XCTAssertTrue(spans.allSatisfy { $0.resolvedFontDescriptor == nil },
                      "a document whose declared family draws its own text must be untouched")
    }

    /// **The survey is document-wide THROUGH THE DISPATCH, not per block.** Two paragraphs share one
    /// declared font; the first holds a single Latin word, the second a page of Korean. If the
    /// dispatch ever planned per block, the first paragraph would be judged on its own Latin, pass
    /// the gate and come back unsubstituted while the second did not — so this asserts on the FIRST
    /// paragraph, the one that can only be right if the whole document was surveyed first.
    func testTheSurveySpansTheWholeDocumentThroughTheRealDispatch() throws {
        try XCTSkipIf(NSFont(name: "Times New Roman", size: 12) == nil, "Times New Roman not installed")
        let font = "<w:rPr><w:rFonts w:ascii=\"Times New Roman\" w:hAnsi=\"Times New Roman\" w:eastAsia=\"Times New Roman\"/></w:rPr>"
        let korean = String(repeating: "한글 본문이 길게 이어집니다. ", count: 20)
        let body = """
        <w:p><w:r>\(font)<w:t>Intro</w:t></w:r></w:p>
        <w:p><w:r>\(font)<w:t>\(korean)</w:t></w:r></w:p>
        """
        let result = try DocumentTypes.readOffice(try ZipArchive(data: docx(body)), extension: "docx")
        let spans = everySpan(in: result.blocks)
        let intro = try XCTUnwrap(spans.first { $0.text.contains("Intro") })
        XCTAssertNotNil(intro.resolvedFontDescriptor,
                        "the Latin-only first paragraph shares its declared font with the Korean body, " +
                        "so a document-wide survey must give it the same answer")
    }
}
