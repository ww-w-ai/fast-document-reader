import XCTest
import AppKit
@testable import FastDocReader

/// S3: rhwp's structured JSON (`{"v":1,"blocks":[…]}`) → `[OfficeBlock]` / `OfficeReadResult`.
/// These feed SYNTHETIC JSON strings straight into the pure decode+map layer
/// (`HwpReader.mapJSON`), so no HWP file or FFI is needed — the mapping is a pure
/// `String -> OfficeReadResult` function separate from `exportDocumentJSON`.
final class HwpMappingTests: XCTestCase {

    // MARK: helpers

    private func envelope(_ blocksJSON: String) -> String {
        "{\"v\":1,\"blocks\":[\(blocksJSON)]}"
    }

    private func mapBlocks(_ blocksJSON: String) throws -> [OfficeBlock] {
        try HwpReader.mapJSON(envelope(blocksJSON)).blocks
    }

    // MARK: paragraph + mixed-style spans

    func testBodyParagraphWithMixedStyleSpans() throws {
        // bold+italic, an underlined coloured run, and a size-converted run.
        let json = """
        {"t":"para","heading":null,"align":"left","spans":[
          {"text":"A","bold":true,"italic":true,"underline":"none","strike":false,"super":false,"sub":false,"color":null,"size":1300,"font":"바탕","link":null,"bookmark":null},
          {"text":"B","bold":false,"italic":false,"underline":"double","strike":false,"super":false,"sub":false,"color":"FF0000","size":1000,"font":null,"link":null,"bookmark":null},
          {"text":"C","bold":false,"italic":false,"underline":"none","strike":true,"super":true,"sub":false,"color":null,"size":0,"font":null,"link":"https://x","bookmark":"anchor1"}
        ]}
        """
        let blocks = try mapBlocks(json)
        XCTAssertEqual(blocks.count, 1)
        guard case let .paragraph(spans, rtl, alignment, tabs, format) = blocks[0] else {
            return XCTFail("expected .paragraph, got \(blocks[0])")
        }
        XCTAssertFalse(rtl)
        XCTAssertEqual(alignment, .left)
        XCTAssertEqual(tabs, [])
        XCTAssertEqual(format, ParagraphFormat())        // no indent/spacing/lineHeight → all nil
        XCTAssertEqual(spans.count, 3)

        // span A: bold+italic, size 1300 HWPUNIT → 13pt, font carried
        XCTAssertEqual(spans[0].text, "A")
        XCTAssertTrue(spans[0].bold)
        XCTAssertTrue(spans[0].italic)
        XCTAssertFalse(spans[0].underline)
        XCTAssertEqual(spans[0].fontSize, 13)
        XCTAssertEqual(spans[0].fontName, "바탕")
        XCTAssertNil(spans[0].textColor)

        // span B: double underline, red, 10pt
        XCTAssertTrue(spans[1].underline)
        XCTAssertEqual(spans[1].underlineStyle, .double)
        XCTAssertEqual(spans[1].fontSize, 10)
        XCTAssertEqual(spans[1].textColor, NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))

        // span C: strike + superscript + link + bookmark; size 0 → unspecified (nil)
        XCTAssertTrue(spans[2].strikethrough)
        XCTAssertTrue(spans[2].superscript)
        XCTAssertNil(spans[2].fontSize)
        XCTAssertEqual(spans[2].link, "https://x")
        XCTAssertEqual(spans[2].bookmarks, ["anchor1"])
    }

    // MARK: heading

    func testHeading() throws {
        let json = """
        {"t":"para","heading":1,"align":"center","spans":[
          {"text":"Title","bold":false,"italic":false,"underline":"none","strike":false,"super":false,"sub":false,"color":null,"size":2000,"font":null,"link":null,"bookmark":null}
        ]}
        """
        let blocks = try mapBlocks(json)
        guard case let .heading(level, spans, rtl, alignment, _, _) = blocks[0] else {
            return XCTFail("expected .heading, got \(blocks[0])")
        }
        XCTAssertEqual(level, 1)
        XCTAssertFalse(rtl)
        XCTAssertEqual(alignment, .center)
        XCTAssertEqual(spans.first?.text, "Title")
        XCTAssertEqual(spans.first?.fontSize, 20)
    }

    // MARK: list items (ordered + bullet)

    func testOrderedAndBulletListItems() throws {
        let json = """
        {"t":"para","heading":null,"align":"left","list":{"level":0,"ordered":true,"marker":"1."},"spans":[
          {"text":"one","bold":false,"italic":false,"underline":"none","strike":false,"super":false,"sub":false,"color":null,"size":0,"font":null,"link":null,"bookmark":null}
        ]},
        {"t":"para","heading":null,"align":"left","list":{"level":1,"ordered":false,"marker":null},"spans":[
          {"text":"bullet","bold":false,"italic":false,"underline":"none","strike":false,"super":false,"sub":false,"color":null,"size":0,"font":null,"link":null,"bookmark":null}
        ]}
        """
        let blocks = try mapBlocks(json)
        XCTAssertEqual(blocks.count, 2)
        guard case let .listItem(level0, ordered0, spans0, marker0, _, _, _, _) = blocks[0] else {
            return XCTFail("expected .listItem, got \(blocks[0])")
        }
        XCTAssertEqual(level0, 0)
        XCTAssertTrue(ordered0)
        XCTAssertEqual(marker0, "1.")
        XCTAssertEqual(spans0.first?.text, "one")

        guard case let .listItem(level1, ordered1, _, marker1, _, _, _, _) = blocks[1] else {
            return XCTFail("expected .listItem, got \(blocks[1])")
        }
        XCTAssertEqual(level1, 1)
        XCTAssertFalse(ordered1)
        XCTAssertNil(marker1)                            // null marker → builder self-counts
    }

    // MARK: alignment variants

    func testAlignmentVariants() throws {
        func alignmentOf(_ align: String) throws -> NSTextAlignment? {
            let json = """
            {"t":"para","heading":null,"align":"\(align)","spans":[]}
            """
            guard case let .paragraph(_, _, alignment, _, _) = try mapBlocks(json)[0] else {
                XCTFail("expected paragraph"); return nil
            }
            return alignment
        }
        XCTAssertEqual(try alignmentOf("left"), .left)
        XCTAssertEqual(try alignmentOf("center"), .center)
        XCTAssertEqual(try alignmentOf("right"), .right)
        XCTAssertEqual(try alignmentOf("justify"), .justified)
        XCTAssertEqual(try alignmentOf("both"), .justified)
        XCTAssertEqual(try alignmentOf("distribute"), .justified)  // matches DocxReader
    }

    // MARK: underline mapping

    func testUnderlineMapping() throws {
        func styleOf(_ u: String) throws -> (Bool, UnderlineStyle) {
            let json = """
            {"t":"para","heading":null,"align":"left","spans":[
              {"text":"x","bold":false,"italic":false,"underline":"\(u)","strike":false,"super":false,"sub":false,"color":null,"size":0,"font":null,"link":null,"bookmark":null}
            ]}
            """
            guard case let .paragraph(spans, _, _, _, _) = try mapBlocks(json)[0] else {
                XCTFail("expected paragraph"); return (false, .single)
            }
            return (spans[0].underline, spans[0].underlineStyle)
        }
        XCTAssertEqual(try styleOf("none").0, false)
        XCTAssertEqual(try styleOf("single").1, .single)
        XCTAssertEqual(try styleOf("double").1, .double)
        XCTAssertEqual(try styleOf("dotted").1, .dotted)
        XCTAssertEqual(try styleOf("dashed").1, .dashed)
        XCTAssertEqual(try styleOf("wavy").1, .wavy)
        XCTAssertTrue(try styleOf("single").0)
    }

    // MARK: unit conversion into ParagraphFormat

    func testUnitConversionIndentAndSpacing() throws {
        let json = """
        {"t":"para","heading":null,"align":"left",
         "indentStart":1000,"indentEnd":500,"indentFirst":700,
         "spaceBefore":300,"spaceAfter":0,
         "lineHeight":{"type":"percent","value":160},
         "spans":[]}
        """
        guard case let .paragraph(_, _, _, _, format) = try mapBlocks(json)[0] else {
            return XCTFail("expected paragraph")
        }
        // Paragraph metrics are stored 2× in HWP5 → ÷200 (HWPUNIT→pt then ÷2), matching rhwp.
        XCTAssertEqual(format.indentStart, 5)            // 1000 → 5pt
        XCTAssertEqual(format.indentEnd, 2.5)
        XCTAssertEqual(format.firstLineIndent, 3.5)      // positive indentFirst → first-line
        XCTAssertNil(format.hangingIndent)
        XCTAssertEqual(format.spacingBefore, 1.5)
        XCTAssertNil(format.spacingAfter)                // 0 → unspecified (theme wins)
        // percent line spacing (HWP's neutral 160% default) → nil → the app's house rhythm,
        // so HWP body matches markdown/docx body (invariant 37 unification).
        XCTAssertNil(format.lineHeight)
    }

    func testNegativeFirstIndentBecomesHanging() throws {
        let json = """
        {"t":"para","heading":null,"align":"left","indentFirst":-400,"spans":[]}
        """
        guard case let .paragraph(_, _, _, _, format) = try mapBlocks(json)[0] else {
            return XCTFail("expected paragraph")
        }
        XCTAssertNil(format.firstLineIndent)
        XCTAssertEqual(format.hangingIndent, 2)          // -400 → 2pt hanging (2×-stored → ÷200)
    }

    func testLineHeightModes() throws {
        func lh(_ type: String, _ value: Int) throws -> LineHeight? {
            let json = """
            {"t":"para","heading":null,"align":"left","lineHeight":{"type":"\(type)","value":\(value)},"spans":[]}
            """
            guard case let .paragraph(_, _, _, _, format) = try mapBlocks(json)[0] else {
                XCTFail("expected paragraph"); return nil
            }
            return format.lineHeight
        }
        // percent (any value) → nil: HWP line-spacing % is the format's neutral default, normalized
        // to the app's house rhythm so HWP reads consistently with markdown/docx (invariant 37).
        XCTAssertNil(try lh("percent", 200))
        // fixed/at-least are author-chosen ABSOLUTE heights, stored 2× in HWP5 → ÷200.
        XCTAssertEqual(try lh("at_least", 1500), .atLeast(7.5))
        XCTAssertEqual(try lh("fixed", 1600), .exact(8))
    }

    // MARK: default / empty paragraph → byte-identical default format

    func testDefaultParagraphHasDefaultFormat() throws {
        // Every optional format field absent → ParagraphFormat() (all nil), byte-identical to
        // a block with no format at all (invariant 37).
        let json = """
        {"t":"para","heading":null,"align":"left","spans":[]}
        """
        guard case let .paragraph(spans, rtl, _, tabs, format) = try mapBlocks(json)[0] else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(spans, [])
        XCTAssertFalse(rtl)
        XCTAssertEqual(tabs, [])
        XCTAssertEqual(format, ParagraphFormat())
    }

    // MARK: table (cells recurse through the same mapping) — S3 minimal

    func testSimpleTwoByTwoTable() throws {
        let cell = """
        {"colSpan":1,"rowSpan":1,"vAlign":"center","borderFillId":0,"blocks":[
          {"t":"para","heading":null,"align":"left","spans":[
            {"text":"cell","bold":false,"italic":false,"underline":"none","strike":false,"super":false,"sub":false,"color":null,"size":0,"font":null,"link":null,"bookmark":null}
          ]}
        ]}
        """
        let json = """
        {"t":"table","cols":2,"colWidths":[3000,3000],"borderFillId":1,
         "rows":[[\(cell),\(cell)],[\(cell),\(cell)]]}
        """
        let blocks = try mapBlocks(json)
        guard case let .table(rows, headerRows, columnWidths, _) = blocks[0] else {
            return XCTFail("expected .table, got \(blocks[0])")
        }
        XCTAssertEqual(headerRows, 0)                    // never invented
        XCTAssertEqual(columnWidths, [30, 30])           // 3000 HWPUNIT → 30pt (absolute, not %)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].count, 2)
        let c = rows[0][0]
        XCTAssertEqual(c.rowSpan, 1)
        XCTAssertEqual(c.colSpan, 1)
        XCTAssertEqual(c.verticalAlignment, .center)     // "center" carried; "top" would be nil (default)
        // cell content recursed through the SAME block mapping → a real .paragraph
        guard case let .paragraph(cspans, _, _, _, _) = c.blocks.first else {
            return XCTFail("expected cell paragraph, got \(String(describing: c.blocks.first))")
        }
        XCTAssertEqual(cspans.first?.text, "cell")
    }

    func testTableCellTopVAlignIsUnspecified() throws {
        let cell = """
        {"colSpan":1,"rowSpan":1,"vAlign":"top","borderFillId":0,"blocks":[
          {"t":"para","heading":null,"align":"left","spans":[]}
        ]}
        """
        let json = """
        {"t":"table","cols":1,"colWidths":[2000],"borderFillId":1,"rows":[[\(cell)]]}
        """
        guard case let .table(rows, _, _, _) = try mapBlocks(json)[0] else {
            return XCTFail("expected table")
        }
        XCTAssertNil(rows[0][0].verticalAlignment)       // Word's default top → nil (byte-identical)
    }

    // MARK: image + unsupported (size reserved, nothing dropped)

    func testImageReservesSize() throws {
        let json = """
        {"t":"image","binDataId":7,"w":9600,"h":4800,"mime":"image/png"}
        """
        guard case let .image(id, size) = try mapBlocks(json)[0] else {
            return XCTFail("expected .image, got \(try mapBlocks(json)[0])")
        }
        XCTAssertEqual(id, "hwpimg:7")
        XCTAssertEqual(size, CGSize(width: 96, height: 48))   // HWPUNIT → pt
    }

    func testUnsupportedGraphic() throws {
        let json = """
        {"t":"unsupported","label":"Chart","w":5000,"h":3000}
        """
        guard case let .unsupportedGraphic(label, size) = try mapBlocks(json)[0] else {
            return XCTFail("expected .unsupportedGraphic")
        }
        XCTAssertEqual(label, "Chart")
        XCTAssertEqual(size, CGSize(width: 50, height: 30))
    }

    // MARK: envelope-level

    func testReadResultCarriesNoComments() throws {
        let result = try HwpReader.mapJSON(envelope(#"{"t":"para","heading":null,"align":"left","spans":[]}"#))
        XCTAssertEqual(result.comments, [])
    }

    /// `mapJSON` is the PURE String->OfficeReadResult step: it must NOT fetch image bytes (that needs
    /// the live rhwp handle, only available in `read`). So even an envelope that RESERVES an image
    /// block yields an empty `images` map — the bytes are pre-decoded only by `HwpReader.read`.
    func testMapJSONReservesImageButDecodesNoBytes() throws {
        let result = try HwpReader.mapJSON(envelope(#"{"t":"image","binDataId":7,"w":12000,"h":9000}"#))
        guard case .image(let id, _) = result.blocks[0] else { return XCTFail("expected .image") }
        XCTAssertEqual(id, "hwpimg:7")
        XCTAssertTrue(result.images.isEmpty, "mapJSON must not decode image bytes — that is read()'s job")
    }

    /// The default construction (both zip readers, all tests) means "nothing pre-decoded".
    func testOfficeReadResultImagesDefaultsEmpty() {
        XCTAssertEqual(OfficeReadResult(blocks: []).images, [:])
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try HwpReader.mapJSON("{ not json"))
        XCTAssertThrowsError(try HwpReader.mapJSON(#"{"v":1,"blocks":[{"t":"mystery"}]}"#))
    }

    // MARK: default body font size (rhwp envelope `defaultFontSizePt`)

    /// The envelope's `defaultFontSizePt` (the document's own Normal-style size) surfaces on the
    /// result so `MarkdownDocument` can scale HWP text to the document, exactly as docx/odt do — a
    /// declared 10pt document must NOT be scaled as if it were 11.
    func testEnvelopeDefaultFontSizeSurfaces() throws {
        let result = try HwpReader.mapJSON(#"{"v":1,"defaultFontSizePt":10,"blocks":[]}"#)
        XCTAssertEqual(result.defaultBodyFontSize, 10)
    }

    /// A fractional default (e.g. 10.5pt) is carried without rounding.
    func testEnvelopeFractionalDefaultFontSize() throws {
        let result = try HwpReader.mapJSON(#"{"v":1,"defaultFontSizePt":10.5,"blocks":[]}"#)
        XCTAssertEqual(result.defaultBodyFontSize, 10.5)
    }

    /// rhwp emitted `null` (or omitted the field, or a non-positive value) → the document declared no
    /// determinable default → fall back to `11` (the theme default the builder tolerates), never a
    /// wrong guess. Covers all three "unspecified" shapes.
    func testDefaultFontSizeFallsBackTo11WhenUnspecified() throws {
        XCTAssertEqual(try HwpReader.mapJSON(#"{"v":1,"defaultFontSizePt":null,"blocks":[]}"#).defaultBodyFontSize, 11)
        XCTAssertEqual(try HwpReader.mapJSON(#"{"v":1,"blocks":[]}"#).defaultBodyFontSize, 11)
        XCTAssertEqual(try HwpReader.mapJSON(#"{"v":1,"defaultFontSizePt":0,"blocks":[]}"#).defaultBodyFontSize, 11)
    }

    // MARK: equation block (rhwp now emits real LaTeX)

    /// An `equation` block with real LaTeX maps to `.formula` carrying that latex — the SAME case a
    /// Word `m:oMathPara` becomes, so `OfficeTextBuilder` renders it through the app's formula engine
    /// for free (no HWP-specific web-block path).
    func testEquationWithLatexMapsToFormula() throws {
        let json = """
        {"t":"equation","latex":"\\\\frac{a}{b}","script":"a over b","w":9600,"h":4800}
        """
        let blocks = try mapBlocks(json)
        XCTAssertEqual(blocks.count, 1)
        guard case let .formula(latex) = blocks[0] else {
            return XCTFail("expected .formula, got \(blocks[0])")
        }
        XCTAssertEqual(latex, "\\frac{a}{b}")
    }

    /// An `equation` whose latex is empty/whitespace falls back to `.unsupportedGraphic(label:"equation")`
    /// — honest, never an empty formula (mirrors DocxReader.formulaBlock's never-nothing ladder). The
    /// advisory `w`/`h` reserve the placeholder's area (HWPUNIT ÷ 100 → points).
    func testEquationWithEmptyLatexFallsBackToUnsupported() throws {
        let json = """
        {"t":"equation","latex":"   ","script":null,"w":5000,"h":3000}
        """
        let blocks = try mapBlocks(json)
        guard case let .unsupportedGraphic(label, size) = blocks[0] else {
            return XCTFail("expected .unsupportedGraphic, got \(blocks[0])")
        }
        XCTAssertEqual(label, "equation")
        XCTAssertEqual(size, CGSize(width: 50, height: 30))
    }

    /// script/w/h are all optional — a bare `{"t":"equation","latex":…}` still maps, and a missing
    /// w/h on the empty-latex fallback reserves a zero area rather than throwing.
    func testEquationOptionalFieldsAbsent() throws {
        guard case let .formula(latex) = try mapBlocks(#"{"t":"equation","latex":"x^2"}"#)[0] else {
            return XCTFail("expected .formula")
        }
        XCTAssertEqual(latex, "x^2")
        guard case let .unsupportedGraphic(_, size) = try mapBlocks(#"{"t":"equation","latex":""}"#)[0] else {
            return XCTFail("expected .unsupportedGraphic")
        }
        XCTAssertEqual(size, .zero)                       // no w/h → zero-reserved placeholder
    }

    // MARK: S3 regression — populated link + bookmark on a span still map (unaffected by equations)

    /// rhwp now POPULATES `span.link`/`span.bookmark` (were always null). Prove the S3 mapping path is
    /// untouched: a non-null link maps to `Span.link` and a non-null bookmark to `Span.bookmarks`.
    /// Footnotes need no new mapping either — they arrive as ordinary superscript marker spans plus
    /// appended note paragraphs, both already handled by the para/span path.
    func testSpanLinkAndBookmarkStillMap() throws {
        let json = """
        {"t":"para","heading":null,"align":"left","spans":[
          {"text":"see","bold":false,"italic":false,"underline":"none","strike":false,"super":false,"sub":false,"color":null,"size":0,"font":null,"link":"https://ww-w.ai","bookmark":"chapter2"}
        ]}
        """
        guard case let .paragraph(spans, _, _, _, _) = try mapBlocks(json)[0] else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(spans[0].link, "https://ww-w.ai")
        XCTAssertEqual(spans[0].bookmarks, ["chapter2"])
    }

    // MARK: gated real parse — an equation-bearing .hwp yields at least one .formula block

    /// Runs the FULL read path (FFI + mapping) on a real equation-bearing HWP file. Gated on
    /// `FMD_HWP_SAMPLE` (e.g. the rhwp fork's `samples/eq-01.hwp`), so the suite stays green without a
    /// sample AND without depending on the linked rhwp binary already emitting `t:"equation"` — set the
    /// env only when validating against a freshly-built rhwp that does.
    func testRealEquationHwpProducesFormulaBlock() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_HWP_SAMPLE"], !path.isEmpty else {
            throw XCTSkip("set FMD_HWP_SAMPLE to an equation-bearing .hwp to run this")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let result = try HwpReader.read(data)
        // Equations can live inside table cells (eq-01.hwp puts all of them there), so search
        // recursively — a top-level-only check misses cell-nested formulas the mapping DID produce.
        func containsFormula(_ blocks: [OfficeBlock]) -> Bool {
            for b in blocks {
                if case .formula = b { return true }
                if case .table(let rows, _, _, _) = b,
                   rows.contains(where: { $0.contains { containsFormula($0.blocks) } }) {
                    return true
                }
            }
            return false
        }
        XCTAssertTrue(containsFormula(result.blocks),
                      "expected at least one .formula block (top-level or in a table cell) from \(path)")
    }
}
