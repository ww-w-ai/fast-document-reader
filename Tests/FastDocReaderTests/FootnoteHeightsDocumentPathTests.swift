import XCTest
@testable import FastDocReader

/// The map the RENDER actually uses, on a real document that really cites footnotes.
///
/// `FootnoteHeightsEngineParityTests` proves the crossing and the seam. This proves the level
/// above: that `applyPageBand`'s own input comes from the engine's reply rather than being
/// computed alongside it and thrown away (invariant 103). Values cannot separate those two — the
/// engine and the host measure the SAME document and agree, which is the point of the parity —
/// so the test hands `engineReply` an answer the host could never produce and requires the map to
/// carry it, the shape `MasterPagePainter.draw`'s `templateSelection` established.
///
/// HWP is the only format that reaches here: `HwpReader.swift:501` is the one writer of
/// `OfficeReadResult.footnotes` — `DocxReader` parses `word/footnotes.xml` but appends the bodies
/// as ordinary blocks (`DocxReader.swift:427`), so a docx never populates this vocabulary.
final class FootnoteHeightsDocumentPathTests: XCTestCase {
    private static let fixture = "Vendor/rhwp-src/samples/footnote-01.hwp"

    private func openFixture() throws -> MarkdownDocument {
        let url = URL(fileURLWithPath: Self.fixture)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("needs \(Self.fixture) — an HWP that CITES footnotes")
        }
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: Data(contentsOf: url), ofType: "hwp")
        XCTAssertFalse(doc.officeFootnotes.isEmpty, "wrong fixture: this document cites no footnote")
        return doc
    }

    func testTheRenderUsesTheEnginesAnswerRatherThanMeasuringAlongsideIt() throws {
        let doc = try openFixture()
        // A height no measurement of this document could return, for every number it declares.
        let impossible = Dictionary(uniqueKeysWithValues: doc.officeFootnotes.map { ($0.number, CGFloat(4242)) })
        let used = doc.footnoteHeights(theme: .current(size: 11), bandColumn: 400,
                                       engineReply: .some(impossible))
        XCTAssertEqual(Set(used.keys), Set(impossible.keys))
        XCTAssertEqual(used.values.filter { $0 == 4242 }.count, impossible.count,
                       "the render measured its own heights instead of using the reply it asked for")
    }

    func testTheRealEngineAndTheRealHostAgreeOnEveryNoteOfARealDocument() throws {
        let doc = try openFixture()
        // EXACTLY what `applyPageBand` builds: a paged document's theme is pinned to its own
        // default body size (invariant 57), and the band column is the document's page content
        // width. A theme built at any other size measures a different document.
        let theme = RenderTheme.current(size: doc.officeDefaultBodyFontSize)
        let column = try XCTUnwrap(doc.officePageContentWidth)
        print("PARITY defaultBodySize=\(doc.officeDefaultBodyFontSize) column=\(column)")
        let host = doc.footnoteHeights(theme: theme, bandColumn: column, engineReply: .some(nil))
        let engine = doc.footnoteHeights(theme: theme, bandColumn: column)
        print("PARITY host=\(host.sorted { $0.key < $1.key }.map(\.value))")
        print("PARITY engine=\(engine.sorted { $0.key < $1.key }.map(\.value))")
        XCTAssertFalse(host.isEmpty)
        XCTAssertEqual(Set(engine.keys), Set(host.keys), "the two parses disagree on WHICH notes exist")
        for (number, hostHeight) in host {
            XCTAssertEqual(try XCTUnwrap(engine[number]), hostHeight, accuracy: 0.5,
                           "note \(number) measures differently in the engine than in the host")
        }
        XCTAssertTrue(host.values.contains { $0 > 0 },
                      "every note measured zero — this proves nothing about the arithmetic")
    }
}
