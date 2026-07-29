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

    // MARK: page content width (paper − margins, pt) — rhwp emits it already in pt

    func testPageContentWidthDecodedFromEnvelope() throws {
        // rhwp exports the first section's body width (PageAreas.body_area ÷100) as pt.
        let r = try HwpReader.mapJSON("{\"v\":1,\"pageContentWidth\":476.25,\"blocks\":[]}")
        XCTAssertEqual(r.pageContentWidth, 476.25)
    }

    func testPageContentWidthAbsentIsNil() throws {
        // A document/envelope that declares none → nil → reader keeps the window-filling column.
        XCTAssertNil(try HwpReader.mapJSON(envelope("")).pageContentWidth)
    }

    func testPageContentWidthNonPositiveIsNil() throws {
        // Guard: rhwp should never emit ≤0 (it returns None), but if it did, the mapper drops it.
        XCTAssertNil(try HwpReader.mapJSON("{\"v\":1,\"pageContentWidth\":0,\"blocks\":[]}").pageContentWidth)
        XCTAssertNil(try HwpReader.mapJSON("{\"v\":1,\"pageContentWidth\":-5,\"blocks\":[]}").pageContentWidth)
    }

    // MARK: page content height + all four margins — HWP wired NONE of these before this change

    func testPageGeometryDecodedFromEnvelope() throws {
        // rhwp exports the first section's body height and all four margins already in pt.
        let r = try HwpReader.mapJSON("""
        {"v":1,"pageContentWidth":432.48,"pageContentHeight":762.3,\
        "pageMarginLeft":56.7,"pageMarginRight":56.7,"pageMarginTop":42.5,"pageMarginBottom":42.5,\
        "blocks":[]}
        """)
        XCTAssertEqual(r.pageContentWidth, 432.48)
        XCTAssertEqual(r.pageContentHeight, 762.3)
        XCTAssertEqual(r.pageMarginLeft, 56.7)
        XCTAssertEqual(r.pageMarginRight, 56.7)
        XCTAssertEqual(r.pageMarginTop, 42.5)
        XCTAssertEqual(r.pageMarginBottom, 42.5)
    }

    func testPageGeometryAbsentIsNilForEveryNewField() throws {
        // A parser predating these fields (or a document with no section) → every one of them nil,
        // exactly like `pageContentWidth` already behaves — none of the five are wired together.
        let r = try HwpReader.mapJSON(envelope(""))
        XCTAssertNil(r.pageContentHeight)
        XCTAssertNil(r.pageMarginLeft)
        XCTAssertNil(r.pageMarginRight)
        XCTAssertNil(r.pageMarginTop)
        XCTAssertNil(r.pageMarginBottom)
    }

    func testPageGeometryNonPositiveIsNil() throws {
        // Each field is clamped independently, exactly like the `pageContentWidth` line it mirrors.
        let r = try HwpReader.mapJSON("""
        {"v":1,"pageContentHeight":0,"pageMarginLeft":-5,"pageMarginRight":0,\
        "pageMarginTop":-1,"pageMarginBottom":0,"blocks":[]}
        """)
        XCTAssertNil(r.pageContentHeight)
        XCTAssertNil(r.pageMarginLeft)
        XCTAssertNil(r.pageMarginRight)
        XCTAssertNil(r.pageMarginTop)
        XCTAssertNil(r.pageMarginBottom)
    }

    func testPageGeometryFieldsAreIndependentOfEachOther() throws {
        // A document that reports width and height but not margins (or vice versa) keeps exactly the
        // fields it has — one field failing must not null out its neighbours.
        let r = try HwpReader.mapJSON("{\"v\":1,\"pageContentWidth\":432.48,\"pageContentHeight\":762.3,\"blocks\":[]}")
        XCTAssertEqual(r.pageContentWidth, 432.48)
        XCTAssertEqual(r.pageContentHeight, 762.3)
        XCTAssertNil(r.pageMarginLeft)
        XCTAssertNil(r.pageMarginRight)
        XCTAssertNil(r.pageMarginTop)
        XCTAssertNil(r.pageMarginBottom)
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
        // NON-PAGED (this envelope declares no `pageContentWidth`): the old window-filling model,
        // where 160% is treated as "nothing stated" and normalizes to the app's house rhythm so HWP
        // body reads consistently with markdown/docx (invariant 37). Any other percentage is an
        // author's choice and is honoured as a floor. A PAGED document honours 160 too and measures
        // it against the paragraph's own run size — see `testPagedHonoursTheFormatDefaultPercent`.
        XCTAssertNil(try lh("percent", 160))
        XCTAssertEqual(try lh("percent", 200), .atLeast(22))   // 200% of the 11pt default
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
        guard case let .image(id, size, _) = try mapBlocks(json)[0] else {
            return XCTFail("expected .image, got \(try mapBlocks(json)[0])")
        }
        XCTAssertEqual(id, "hwpimg:7")
        XCTAssertEqual(size, CGSize(width: 96, height: 48))   // HWPUNIT → pt
    }

    func testUnsupportedGraphic() throws {
        let json = """
        {"t":"unsupported","label":"Chart","w":5000,"h":3000}
        """
        guard case let .unsupportedGraphic(label, size, _) = try mapBlocks(json)[0] else {
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
        guard case .image(let id, _, _) = result.blocks[0] else { return XCTFail("expected .image") }
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
        guard case let .unsupportedGraphic(label, size, _) = blocks[0] else {
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
        guard case let .unsupportedGraphic(_, size, _) = try mapBlocks(#"{"t":"equation","latex":""}"#)[0] else {
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

    // MARK: per-script font slots — the data the rebuilt parser now carries (step 1 of the feature)

    /// The rebuild's ONLY observable effect, asserted against a real document through the real FFI.
    ///
    /// Everything about this is deliberately end-to-end: the bytes go through `exportDocumentJSON`
    /// (the linked rhwp binary), and the JSON comes back through the SAME decoder `mapJSON` uses.
    /// A hand-written JSON literal would pass against a stale binary, which is precisely the failure
    /// this test exists to catch — SwiftPM keys a `binaryTarget` off the xcframework's PATH, not its
    /// bytes (invariant 45), so a vendored `.a` that never relinked looks completely healthy, and a
    /// field named in snake_case decodes to `nil` with no error at all. Both faults are silent; only
    /// asserting on real values from a real parse makes either of them loud.
    ///
    /// Three claims, matching what step 2 will rely on:
    /// 1. `charShapes` arrives, and every row carries all seven slots.
    /// 2. Real text spans carry `csId`.
    /// 3. Every `csId` indexes a row that exists — rhwp omits the key rather than emitting an id it
    ///    has no row for, so this is structural, and the assertion is here to keep it that way.
    func testCharShapeFontSlotsArriveFromARealDocument() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_HWP_SAMPLE"], !path.isEmpty else {
            throw XCTSkip("set FMD_HWP_SAMPLE to a real .hwp/.hwpx to run this")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let json = HwpReader.exportDocumentJSON(data) else {
            return XCTFail("rhwp could not parse \(path)")
        }
        let export = try HwpReader.fontSlotExport(json)

        XCTAssertFalse(export.charShapes.isEmpty,
                       "no charShapes table — the linked rhwp binary predates it, or the field name drifted")
        for (i, row) in export.charShapes.enumerated() {
            XCTAssertEqual(row.count, 7, "charShapes[\(i)] must carry all seven slots, got \(row)")
        }

        let ids = export.spanCharShapeIds.compactMap { $0 }
        XCTAssertFalse(ids.isEmpty, "text spans must carry csId")
        for id in ids {
            XCTAssertTrue(export.charShapes.indices.contains(id),
                          "csId \(id) is outside the \(export.charShapes.count)-row charShapes table")
        }

        // Observation, not an assertion: what the seven names ACTUALLY are. `lookup_font_name`
        // applies rhwp's own web-oriented substitution before we ever see a name, and it is
        // lang_index-sensitive, so slots 2-6 fire rules this build has never exercised. Step 2 has
        // to be designed against what they really return, not against what the slot order implies.
        let distinctRows = Set(export.charShapes.map { $0.joined(separator: "\u{1}") })
        print("""
              FONTSLOTS \(URL(fileURLWithPath: path).lastPathComponent): \
              \(export.charShapes.count) rows (\(distinctRows.count) distinct), \
              \(export.spanCharShapeIds.count) spans (\(export.spanCharShapeIds.filter { $0 == nil }.count) without a csId)
              """)
        for row in export.charShapes.prefix(4) { print("  slots: \(row)") }
    }

    /// A span that carries no char shape of its own — a bookmark anchor, a footnote reference
    /// marker — must decode to `csId == nil` rather than to a bogus row number, and the mapper must
    /// go on treating it exactly as before. Synthetic here on purpose: this is a claim about the
    /// DECODER's handling of an absent key, which no real file can vary.
    func testSpanWithoutACharShapeDecodesToNoSlotRow() throws {
        let json = """
        {"v":1,"charShapes":[["A","B","C","D","E","F","G"]],"blocks":[
          {"t":"para","spans":[
            {"text":"x","size":1000,"font":"A","csId":0},
            {"text":"","size":0,"font":"","bookmark":"anchor"}
          ]}
        ]}
        """
        let export = try HwpReader.fontSlotExport(json)
        XCTAssertEqual(export.charShapes, [["A", "B", "C", "D", "E", "F", "G"]])
        XCTAssertEqual(export.spanCharShapeIds, [0, nil])
        // …and nothing about the mapped result changed: the anchor is still a bookmark span.
        let blocks = try HwpReader.mapJSON(json).blocks
        guard case let .paragraph(spans, _, _, _, _) = blocks[0] else {
            return XCTFail("expected .paragraph, got \(blocks[0])")
        }
        XCTAssertEqual(spans.map(\.text), ["x", ""])
        XCTAssertEqual(spans[1].bookmarks, ["anchor"])
    }

    /// An envelope from a parser that predates the field decodes to an EMPTY table, not a failure —
    /// the whole point of shipping the rebuild additively is that the reader keeps working either
    /// way, so "old binary" must be a legible state rather than a crash.
    func testEnvelopeWithoutCharShapesDecodesToAnEmptyTable() throws {
        let json = "{\"v\":1,\"blocks\":[{\"t\":\"para\",\"spans\":[{\"text\":\"x\",\"size\":0,\"font\":\"\"}]}]}"
        let export = try HwpReader.fontSlotExport(json)
        XCTAssertEqual(export.charShapes, [])
        XCTAssertEqual(export.spanCharShapeIds, [nil])
    }

    /// `fontSlotExport` reaches spans nested in TABLE CELLS. A Korean report is mostly tables — a
    /// walker that stopped at the top level would report "every csId is in range" having checked
    /// almost none of them, which is invariant 30's unreachable-assertion failure exactly.
    func testFontSlotExportReachesSpansInsideTableCells() throws {
        let json = """
        {"v":1,"charShapes":[["A","A","A","A","A","A","A"],["B","B","B","B","B","B","B"]],"blocks":[
          {"t":"table","cols":1,"colWidths":[100],"rows":[[
            {"colSpan":1,"rowSpan":1,"blocks":[
              {"t":"para","spans":[{"text":"in a cell","size":1000,"font":"B","csId":1}]}
            ]}
          ]]}
        ]}
        """
        let export = try HwpReader.fontSlotExport(json)
        XCTAssertEqual(export.spanCharShapeIds, [1])
    }
}

// MARK: - Style-derived headings, picture alignment, relative picture width (S10)

extension HwpMappingTests {
    private func envelope2(_ blocksJSON: String, pageWidth: Double? = nil) -> String {
        let pw = pageWidth.map { ",\"pageContentWidth\":\($0)" } ?? ""
        return "{\"v\":1\(pw),\"blocks\":[\(blocksJSON)]}"
    }

    /// HWP marks only OUTLINE-numbered paragraphs with its heading flag, and measuring 14 real files
    /// found 13 with none — Korean reports title their sections with a named style instead. Matching
    /// the built-in styles is the same fix invariant 33 records for Word, in the form HWP offers it:
    /// the ENGLISH name is the locale-stable identity, the Korean name its display form.
    func testBuiltInOutlineStyleBecomesAHeading() {
        XCTAssertEqual(HwpReader.headingLevel(styleName: "Outline 2", localName: "개요 2"), 2)
        XCTAssertEqual(HwpReader.headingLevel(styleName: nil, localName: "개요 3"), 3)
        XCTAssertEqual(HwpReader.headingLevel(styleName: "Title", localName: "제목"), 1)
        XCTAssertNil(HwpReader.headingLevel(styleName: "Normal", localName: "바탕글"),
                     "body text must never become a heading")
        XCTAssertNil(HwpReader.headingLevel(styleName: "Body", localName: "본문"))
    }

    /// Custom names, taken from the corpus: "각 장 제목"/"각 절 제목" are real headings and their
    /// depth is in the word used. "표의 제목" is a TABLE CAPTION — it appeared 112 times in one
    /// document, so accepting it would bury the outline under captions; "목차,발간사 제목" styles the
    /// contents ENTRIES themselves. Both are excluded BY MEASUREMENT, not by taste.
    func testCustomKoreanTitleStylesAreAcceptedButCaptionsAndContentsAreNot() {
        XCTAssertEqual(HwpReader.headingLevel(styleName: nil, localName: "각 장 제목"), 1)
        XCTAssertEqual(HwpReader.headingLevel(styleName: nil, localName: "각 절 제목"), 2)
        XCTAssertNil(HwpReader.headingLevel(styleName: nil, localName: "표의 제목"))
        XCTAssertNil(HwpReader.headingLevel(styleName: nil, localName: "그림 제목"))
        XCTAssertNil(HwpReader.headingLevel(styleName: nil, localName: "목차,발간사 제목"))
        XCTAssertNil(HwpReader.headingLevel(styleName: nil, localName: "본문(ㅇ)"))
    }

    /// A style-INFERRED heading must also look like one. A real document applies a "…제목" style to
    /// running prose, which turned 80-character sentences into headings; an EXPLICIT outline
    /// paragraph is trusted at any length, because there the document itself said so.
    func testInferredHeadingIsRejectedWhenItsTextIsProse() throws {
        let long = String(repeating: "가", count: HwpReader.headingTextLimit + 1)
        let inferred = try HwpReader.mapJSON(envelope2("""
        {"t":"para","styleLocalName":"각 장 제목","spans":[{"text":"\(long)"}]}
        """)).blocks
        guard case .paragraph = inferred[0] else {
            return XCTFail("a prose-length paragraph must stay a paragraph, got \(inferred[0])")
        }
        let short = try HwpReader.mapJSON(envelope2("""
        {"t":"para","styleLocalName":"각 장 제목","spans":[{"text":"서 론"}]}
        """)).blocks
        guard case .heading(let level, _, _, _, _, _) = short[0] else {
            return XCTFail("a short titled paragraph must become a heading, got \(short[0])")
        }
        XCTAssertEqual(level, 1)
        // Explicit outline wins regardless of length.
        let explicit = try HwpReader.mapJSON(envelope2("""
        {"t":"para","heading":2,"spans":[{"text":"\(long)"}]}
        """)).blocks
        guard case .heading = explicit[0] else {
            return XCTFail("an explicitly outlined paragraph must stay a heading at any length")
        }
    }

    /// HWP stores a picture's own horizontal alignment. `inside`/`outside` are mirror-margin values
    /// with no meaning in one continuous column, so they resolve to nil (the reader's default)
    /// instead of being flattened to left, which would assert something the document never said.
    func testPictureAlignmentIsCarriedAndMirrorMarginsAreLeftUnstated() throws {
        let blocks = try HwpReader.mapJSON(envelope2("""
        {"t":"image","binDataId":3,"w":10000,"h":5000,"align":"center"},
        {"t":"image","binDataId":4,"w":10000,"h":5000,"align":"outside"}
        """)).blocks
        guard case .image(_, _, let centred) = blocks[0], case .image(_, _, let mirrored) = blocks[1] else {
            return XCTFail("expected two image blocks, got \(blocks)")
        }
        XCTAssertEqual(centred, .center)
        XCTAssertNil(mirrored)
    }

    /// A width HWP stored RELATIVE to the page is a share in ten-thousandths, not HWPUNIT — reading
    /// it as absolute yields a picture hundreds of points wide. Resolved against the page body width
    /// the same parse already carries; the absolute case (by far the common one) is untouched.
    func testRelativePictureWidthResolvesAgainstThePageAndAbsoluteIsUnchanged() throws {
        let blocks = try HwpReader.mapJSON(envelope2("""
        {"t":"image","binDataId":1,"w":5000,"h":2500,"widthCriterion":"page"},
        {"t":"image","binDataId":2,"w":24000,"h":12000,"widthCriterion":"absolute"}
        """, pageWidth: 400)).blocks
        guard case .image(_, let relative, _) = blocks[0], case .image(_, let absolute, _) = blocks[1] else {
            return XCTFail("expected two image blocks, got \(blocks)")
        }
        XCTAssertEqual(relative.width, 200, accuracy: 0.01, "5000/10000 of a 400pt page = 200pt")
        XCTAssertEqual(relative.height, 100, accuracy: 0.51, "the authored aspect is kept")
        XCTAssertEqual(absolute.width, 240, accuracy: 0.01, "24000 HWPUNIT ÷ 100 = 240pt, unchanged")
    }

    /// With no page width known, a relative width cannot be resolved — the reader must not invent
    /// one, so it falls back to the declared conversion exactly as before this existed.
    func testRelativePictureWidthWithoutAPageWidthFallsBackToTheDeclaredSize() throws {
        let blocks = try HwpReader.mapJSON(envelope2("""
        {"t":"image","binDataId":1,"w":5000,"h":2500,"widthCriterion":"page"}
        """)).blocks
        guard case .image(_, let size, _) = blocks[0] else { return XCTFail("expected an image") }
        XCTAssertEqual(size.width, 50, accuracy: 0.01)
    }
}

extension HwpMappingTests {
    /// NON-PAGED ONLY — this envelope declares no `pageContentWidth`. There the old window-filling
    /// model still runs: HWP's own default spacing (160%) means "nothing stated" → the reader's
    /// house rhythm, so HWP body reads like markdown/docx body in the same window. Every OTHER
    /// percentage is the author's choice and is honoured, as a FLOOR so a tall CJK glyph is never
    /// clipped. Measured: 637 of 637 real files DO declare a page width, so this arm is reached only
    /// by a document that declares none — for which byte-identical is the contract.
    func testPercentLineHeightHonoursAuthorChoicesButNotTheFormatDefault() throws {
        func lineHeight(_ percent: Int) throws -> LineHeight? {
            let json = """
            {"v":1,"defaultFontSizePt":10,"blocks":[{"t":"para","spans":[{"text":"x"}],
            "lineHeight":{"type":"percent","value":\(percent)}}]}
            """
            guard case let .paragraph(_, _, _, _, format) = try HwpReader.mapJSON(json).blocks[0] else {
                XCTFail("expected a paragraph"); return nil
            }
            return format.lineHeight
        }
        XCTAssertNil(try lineHeight(160), "the format's own default must stay neutral")
        guard case .atLeast(let doubled)? = try lineHeight(200) else {
            return XCTFail("200% must be honoured as a floor")
        }
        XCTAssertEqual(doubled, 20, accuracy: 0.01, "200% of a 10pt body = 20pt")
        guard case .atLeast(let tight)? = try lineHeight(110) else {
            return XCTFail("110% must be honoured")
        }
        XCTAssertEqual(tight, 11, accuracy: 0.01)
        XCTAssertNotNil(try lineHeight(158), "158% is a choice, not a rounding of the default")
    }

    // MARK: - PAGED: HWP's own percent rule, reproduced

    /// One paragraph, built through the real `mapJSON`, with the page width that makes it PAGED.
    /// `runSize` is the size the paragraph's single run declares, in points (`nil` = declares none).
    private func pagedLineHeight(percent: Int, defaultPt: Double = 10,
                                 runSize: Double?) throws -> LineHeight? {
        let size = runSize.map { ",\"size\":\(Int($0 * 100))" } ?? ""
        let json = """
        {"v":1,"defaultFontSizePt":\(defaultPt),"pageContentWidth":420,
         "blocks":[{"t":"para","spans":[{"text":"본문"\(size)}],
         "lineHeight":{"type":"percent","value":\(percent)}}]}
        """
        guard case let .paragraph(_, _, _, _, format) = try HwpReader.mapJSON(json).blocks[0] else {
            XCTFail("expected a paragraph"); return nil
        }
        return format.lineHeight
    }

    /// The change this sprint is about: a PAGED document's 160% is the author's line rule, not
    /// silence. It used to be discarded, which drew the most common Korean page (225,654 of 525,054
    /// percent paragraphs across 637 real files) at the app's 1.45× house rhythm instead of the
    /// 1.6× em HWP asks for.
    func testPagedHonoursTheFormatDefaultPercent() throws {
        guard case .atLeast(let pt)? = try pagedLineHeight(percent: 160, runSize: 10) else {
            return XCTFail("a paged 160% must be honoured, not discarded")
        }
        // rhwp's own rule, stated in three places in its renderer: pitch = max_fs × percent / 100.
        // 10pt text at 160% = 16pt — exactly 1.6× em, NOT the 1.81× the superseded comment estimated
        // (that figure was a property of `.multiple`, which this reader does not use).
        XCTAssertEqual(pt, 16, accuracy: 0.01)
    }

    /// The SAME document without a page width keeps the old model exactly — so the page width, and
    /// nothing else, is what switches the rule. This is the byte-identical half of the contract.
    func testNonPagedStillDiscardsTheFormatDefaultPercent() throws {
        let json = """
        {"v":1,"defaultFontSizePt":10,"blocks":[{"t":"para","spans":[{"text":"본문","size":1000}],
         "lineHeight":{"type":"percent","value":160}}]}
        """
        guard case let .paragraph(_, _, _, _, format) = try HwpReader.mapJSON(json).blocks[0] else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertNil(format.lineHeight, "with no page width the old window-filling model stands")
    }

    /// HWP measures its percentage against the TEXT'S OWN size (rhwp's `max_fs`), not against the
    /// document default. Measured across 637 files: only 76,601 of 392,216 percent paragraphs (19.5%)
    /// have a run size within 5% of the document default, and 47 files report a default that is not
    /// a plausible body size at all (1pt, 24pt, 40pt) — so the default is the wrong basis four times
    /// in five. A 20pt heading-ish paragraph in a 10pt document wants 32pt of line, not 16pt.
    func testPagedPercentIsMeasuredAgainstTheParagraphsOwnRunSize() throws {
        guard case .atLeast(let big)? = try pagedLineHeight(percent: 160, defaultPt: 10, runSize: 20)
        else { return XCTFail("expected a floor") }
        XCTAssertEqual(big, 32, accuracy: 0.01, "160% of the paragraph's OWN 20pt, not of the 10pt default")

        // ...and the other direction: text SMALLER than the default must not be over-spaced.
        guard case .atLeast(let small)? = try pagedLineHeight(percent: 160, defaultPt: 10, runSize: 8)
        else { return XCTFail("expected a floor") }
        XCTAssertEqual(small, 12.8, accuracy: 0.01, "160% of 8pt, not the 16pt the default would give")
    }

    /// The paragraph's own size is an ANSWER, not always present — an empty paragraph, or a run that
    /// inherits its size, declares none. Then, and only then, the document default is the basis.
    func testPagedPercentFallsBackToTheDocumentDefaultWhenNoRunStatesASize() throws {
        guard case .atLeast(let pt)? = try pagedLineHeight(percent: 160, defaultPt: 10, runSize: nil)
        else { return XCTFail("expected a floor") }
        XCTAssertEqual(pt, 16, accuracy: 0.01, "no run size → the document's own default is the basis")
    }

    /// A paragraph MIXING sizes takes the largest, so the tall line is never the one that gets too
    /// little room — the one-directional degradation `maxRunSize`'s doc names (HWP re-picks `max_fs`
    /// per wrapped LINE; an `NSParagraphStyle` carries one rule for the whole paragraph).
    func testPagedPercentTakesTheLargestRunInAMixedParagraph() throws {
        let json = """
        {"v":1,"defaultFontSizePt":10,"pageContentWidth":420,
         "blocks":[{"t":"para","spans":[{"text":"작은","size":900},{"text":"큰","size":1800}],
         "lineHeight":{"type":"percent","value":150}}]}
        """
        guard case let .paragraph(_, _, _, _, format) = try HwpReader.mapJSON(json).blocks[0],
              case .atLeast(let pt)? = format.lineHeight else {
            return XCTFail("expected a paragraph with a floor")
        }
        XCTAssertEqual(pt, 27, accuracy: 0.01, "150% of the 18pt run, not of the 9pt one")
    }

    /// The rule reaches a paragraph inside a TABLE CELL too — `mapCell` recurses through the same
    /// `mapBlock`, and a Korean report puts most of its text in tables.
    func testPagedPercentReachesTableCellParagraphs() throws {
        let json = """
        {"v":1,"defaultFontSizePt":10,"pageContentWidth":420,
         "blocks":[{"t":"table","colWidths":[10000],"rows":[[{"colSpan":1,"rowSpan":1,
         "blocks":[{"t":"para","spans":[{"text":"칸","size":1000}],
         "lineHeight":{"type":"percent","value":160}}]}]]}]}
        """
        guard case let .table(rows, _, _, _) = try HwpReader.mapJSON(json).blocks[0],
              case let .paragraph(_, _, _, _, format) = rows[0][0].blocks[0] else {
            return XCTFail("expected a table cell paragraph")
        }
        guard case .atLeast(let pt)? = format.lineHeight else {
            return XCTFail("a cell paragraph's 160% must be honoured too")
        }
        XCTAssertEqual(pt, 16, accuracy: 0.01)
    }

    /// The same field is written as a percentage by some HWP versions and as percent×100 by others.
    /// Both are accepted; a value in neither band is refused rather than rendered as a 160× line.
    func testPercentLineHeightAcceptsBothEncodingsAndRefusesNonsense() {
        XCTAssertEqual(HwpReader.percentLineHeight(160), 160)
        XCTAssertEqual(HwpReader.percentLineHeight(16_000), 160)
        XCTAssertNil(HwpReader.percentLineHeight(3))
        XCTAssertNil(HwpReader.percentLineHeight(2_000_000))
    }

    // MARK: - per-slot fonts, THROUGH the real mapper (invariant 29)

    /// `HwpFontSlotsTests` proves the classifier; these prove the READER REACHES it. Every case here
    /// goes through `HwpReader.mapJSON`, the same function `HwpReader.read` calls, so a classifier
    /// that is perfect and unwired fails here — which is exactly the shape of the `.odt` defect
    /// invariant 29 records (a parser with 24 passing tests that could not be reached at all).
    private func spans(_ json: String) throws -> [Span] {
        guard case let .paragraph(spans, _, _, _, _) = try HwpReader.mapJSON(json).blocks[0] else {
            throw XCTSkip("expected a paragraph")
        }
        return spans
    }

    /// A row whose seven slots name one family produces the ORIGINAL span, unchanged — the fast path
    /// invariant 37 rests on, and the shape 46.4% of real documents are in.
    func testAUniformRowProducesOneUnchangedSpan() throws {
        let json = """
        {"v":1,"charShapes":[["A","A","A","A","A","A","A"]],"blocks":[
          {"t":"para","spans":[{"text":"이상무 KDI 전문위원","size":1000,"font":"A","csId":0}]}]}
        """
        let out = try spans(json)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "이상무 KDI 전문위원")
        XCTAssertEqual(out[0].fontName, "A")
    }

    /// The case the whole feature exists for: the document asks for one face for Korean and another
    /// for Latin, and the Latin stops being drawn in the Korean face.
    func testAVaryingRowDrawsEachScriptInItsOwnDeclaredFamily() throws {
        let json = """
        {"v":1,"charShapes":[["휴먼명조","Palatino Linotype","HY신명조","HY신명조","HY신명조","HY신명조","HY견명조"]],
         "blocks":[{"t":"para","spans":[{"text":"이상무 KDI 전문위원","size":1000,"font":"휴먼명조","csId":0}]}]}
        """
        let out = try spans(json)
        XCTAssertEqual(out.map(\.text), ["이상무 ", "KDI ", "전문위원"])
        XCTAssertEqual(out.map(\.fontName), ["휴먼명조", "Palatino Linotype", "휴먼명조"])
        XCTAssertEqual(out.map(\.text).joined(), "이상무 KDI 전문위원", "no text may be lost in the split")
    }

    /// Every property other than the family is copied onto each piece — a split must not drop the
    /// bold/colour/size the run carried.
    func testASplitCarriesEveryOtherPropertyOntoBothPieces() throws {
        let json = """
        {"v":1,"charShapes":[["KO","LA","","","","",""]],"blocks":[
          {"t":"para","spans":[{"text":"가나ABC","size":1200,"font":"KO","csId":0,
            "bold":true,"italic":true,"underline":"double","strike":true,"color":"FF0000"}]}]}
        """
        let out = try spans(json)
        XCTAssertEqual(out.count, 2)
        for piece in out {
            XCTAssertTrue(piece.bold); XCTAssertTrue(piece.italic)
            XCTAssertTrue(piece.underline); XCTAssertEqual(piece.underlineStyle, .double)
            XCTAssertTrue(piece.strikethrough)
            XCTAssertEqual(piece.fontSize, 12)
            XCTAssertNotNil(piece.textColor)
        }
    }

    /// A span with no char shape of its own (a bookmark anchor, a footnote marker) and a span whose
    /// `csId` is out of range must both degrade to EXACTLY what this reader drew before — rhwp's own
    /// `font` — rather than to a guess or to nothing.
    func testASpanWithNoOrOutOfRangeCharShapeKeepsTheParsersOwnFont() throws {
        let noId = """
        {"v":1,"charShapes":[["KO","LA","","","","",""]],"blocks":[
          {"t":"para","spans":[{"text":"가나ABC","size":1000,"font":"기존폰트"}]}]}
        """
        XCTAssertEqual(try spans(noId).map(\.fontName), ["기존폰트"])
        XCTAssertEqual(try spans(noId).count, 1, "no csId means no classification, so no split")

        let outOfRange = """
        {"v":1,"charShapes":[["KO","LA","","","","",""]],"blocks":[
          {"t":"para","spans":[{"text":"가나ABC","size":1000,"font":"기존폰트","csId":97}]}]}
        """
        XCTAssertEqual(try spans(outOfRange).map(\.fontName), ["기존폰트"])

        let noTable = """
        {"v":1,"blocks":[{"t":"para","spans":[{"text":"가나ABC","size":1000,"font":"기존폰트","csId":0}]}]}
        """
        XCTAssertEqual(try spans(noTable).map(\.fontName), ["기존폰트"],
                       "a parser predating charShapes must render exactly as before")
    }

    /// An empty-text span is a bookmark anchor, and the splitter yields NO pieces for empty input —
    /// so without its own guard this pass would delete the anchor and every internal link to it.
    ///
    /// The anchor is given a `csId` on a NON-uniform row DELIBERATELY. rhwp omits `csId` for
    /// synthetic spans today, so an anchor written the way rhwp writes it exits at the `csId` check
    /// and never reaches the empty-text guard at all — which the first version of this test did, and
    /// mutation testing caught it: deleting the guard left this test green, proving only that some
    /// EARLIER branch worked (invariant 30, "a green assertion whose subject is unreachable proves
    /// nothing"). Both shapes are asserted now, so the guard is covered on its own terms and stays
    /// correct if rhwp ever starts stamping a char shape on its anchors.
    func testAnEmptyBookmarkAnchorSurvivesTheSplitPass() throws {
        let asRhwpWritesItToday = """
        {"v":1,"charShapes":[["KO","LA","","","","",""]],"blocks":[
          {"t":"para","spans":[{"text":"","bookmark":"target1"},
                               {"text":"가나ABC","size":1000,"font":"KO","csId":0}]}]}
        """
        let out = try spans(asRhwpWritesItToday)
        XCTAssertEqual(out.first?.bookmarks, ["target1"])
        XCTAssertEqual(out.first?.text, "")

        // The same anchor carrying a char shape, which is what makes the empty-text guard reachable.
        let anchorWithACharShape = """
        {"v":1,"charShapes":[["KO","LA","","","","",""]],"blocks":[
          {"t":"para","spans":[{"text":"","bookmark":"target2","csId":0},
                               {"text":"가나ABC","size":1000,"font":"KO","csId":0}]}]}
        """
        let out2 = try spans(anchorWithACharShape)
        XCTAssertEqual(out2.first?.text, "", "the empty anchor span must not be dropped")
        XCTAssertEqual(out2.first?.bookmarks, ["target2"],
                       "an anchor with a csId must survive the splitter, which yields no pieces for empty text")
    }

    /// A bookmark is a POINT in the document. Copying it onto every piece of a split run would
    /// publish the same name several times and give an internal link more than one place to land.
    func testASplitRunKeepsItsBookmarkOnTheFirstPieceOnly() throws {
        let json = """
        {"v":1,"charShapes":[["KO","LA","","","","",""]],"blocks":[
          {"t":"para","spans":[{"text":"가나ABC","size":1000,"font":"KO","csId":0,"bookmark":"anchor"}]}]}
        """
        let out = try spans(json)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].bookmarks, ["anchor"])
        XCTAssertEqual(out[1].bookmarks, [], "the anchor must not be duplicated onto the second piece")
    }

    /// A run of nothing but absorbing characters classifies nothing, so the splitter hands back one
    /// piece with no family. Emitting that verbatim would strand a theme-font span between two runs
    /// of a real family — the boundary absorption exists to protect.
    func testARunOfOnlyNeutralCharactersKeepsTheDocumentsOwnFamily() throws {
        let json = """
        {"v":1,"charShapes":[["KO","LA","","","","",""]],"blocks":[
          {"t":"para","spans":[{"text":"  (3) ","size":1000,"font":"KO","csId":0}]}]}
        """
        let out = try spans(json)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].fontName, "KO", "must not fall back to the theme body font")
    }

    /// A Korean report is mostly tables, so a pass that stopped at the top level would leave most of
    /// the document unimproved while every top-level assertion passed.
    func testPerSlotFontsReachSpansInsideTableCells() throws {
        let json = """
        {"v":1,"charShapes":[["휴먼명조","Palatino Linotype","","","","",""]],
         "blocks":[{"t":"table","colWidths":[100],"rows":[[{"colSpan":1,"rowSpan":1,"blocks":[
           {"t":"para","spans":[{"text":"이상무 KDI","size":1000,"font":"휴먼명조","csId":0}]}]}]]}]}
        """
        guard case let .table(rows, _, _, _) = try HwpReader.mapJSON(json).blocks[0],
              case let .paragraph(cellSpans, _, _, _, _) = rows[0][0].blocks[0] else {
            return XCTFail("expected a table with a paragraph in its cell")
        }
        XCTAssertEqual(cellSpans.map(\.fontName), ["휴먼명조", "Palatino Linotype"])
    }

    /// Slot 4 is the correction to rhwp's own classifier, whose catch-all is the KOREAN slot — so
    /// this is the assertion that would fail if anyone ever "simplified" by porting it.
    func testNonCjkScriptsTakeTheOtherSlotThroughTheRealMapper() throws {
        let json = """
        {"v":1,"charShapes":[["KO","LA","HANJA","JP","OTHER","SYM","U"]],"blocks":[
          {"t":"para","spans":[{"text":"가나 ABC Привет 漢字","size":1000,"font":"KO","csId":0}]}]}
        """
        let out = try spans(json)
        XCTAssertEqual(out.map(\.text), ["가나 ", "ABC ", "Привет ", "漢字"])
        XCTAssertEqual(out.map(\.fontName), ["KO", "LA", "OTHER", "HANJA"])
    }

    // MARK: Headers/footers — rhwp's top-level `headers`/`footers` arrays (header-footer-design.md §3)

    /// `blocks` inside a header/footer entry are the SAME `HwpBlock` shape the body decodes, mapped
    /// through the identical `mapBlock` — zero new block-parsing code, mirroring what
    /// header-footer-design.md §2c already established for docx/odt.
    func testHeadersAndFootersDecodedFromEnvelopeArrays() throws {
        let json = """
        {"v":1,"blocks":[],
         "headers":[{"applyTo":"both","blocks":[{"t":"para","spans":[{"text":"Running header"}]}]}],
         "footers":[{"applyTo":"odd","blocks":[{"t":"para","spans":[{"text":"Odd footer"}]}]},
                    {"applyTo":"even","blocks":[{"t":"para","spans":[{"text":"Even footer"}]}]}]}
        """
        let result = try HwpReader.mapJSON(json)
        XCTAssertEqual(result.headers, [
            OfficeHeaderFooter(appliesTo: .defaultPages, blocks: [.paragraph(spans: [Span(text: "Running header")])]),
        ])
        XCTAssertEqual(result.footers, [
            OfficeHeaderFooter(appliesTo: .defaultPages, blocks: [.paragraph(spans: [Span(text: "Odd footer")])]),
            OfficeHeaderFooter(appliesTo: .evenPages, blocks: [.paragraph(spans: [Span(text: "Even footer")])]),
        ])
    }

    /// A parser built before `headers`/`footers` existed (or a document with genuinely none) decodes
    /// to `nil`, which the mapper treats exactly like `[]` — invariant 37's contract, restated here.
    func testHeadersAndFootersAbsentFromEnvelopeDecodeToEmptyArrays() throws {
        let result = try HwpReader.mapJSON(envelope(""))
        XCTAssertEqual(result.headers, [])
        XCTAssertEqual(result.footers, [])
    }

    /// rhwp's `"both"` (no even override declared anywhere in the section) and `"odd"` (an even
    /// override EXISTS elsewhere, so this entry is explicitly the non-even pages) both fold into
    /// `.defaultPages` — see `HeaderFooterApplicability`'s own doc for why HWP's split is not
    /// docx's three-way one. `"even"` is the one honest match.
    func testApplyToBothAndOddBothMapToDefaultPagesWhileEvenMapsToEvenPages() throws {
        let json = """
        {"v":1,"blocks":[],
         "headers":[{"applyTo":"both","blocks":[]},{"applyTo":"odd","blocks":[]},{"applyTo":"even","blocks":[]}]}
        """
        let result = try HwpReader.mapJSON(json)
        XCTAssertEqual(result.headers.map(\.appliesTo), [.defaultPages, .defaultPages, .evenPages])
    }

    /// An unrecognized `applyTo` (a future rhwp version this mapper doesn't yet know) degrades to
    /// `.defaultPages` rather than being silently dropped — the entry's CONTENT still survives.
    func testUnrecognizedApplyToDegradesToDefaultPagesRatherThanBeingDropped() throws {
        let json = """
        {"v":1,"blocks":[],"headers":[{"applyTo":"mystery","blocks":[{"t":"para","spans":[{"text":"x"}]}]}]}
        """
        let result = try HwpReader.mapJSON(json)
        XCTAssertEqual(result.headers.count, 1)
        XCTAssertEqual(result.headers[0].appliesTo, .defaultPages)
        XCTAssertEqual(result.headers[0].blocks, [.paragraph(spans: [Span(text: "x")])])
    }

    /// Proves the SAME mapper is reused, not a simplified stand-in: a bold/coloured span inside a
    /// header block resolves exactly like one in the body would.
    func testHeaderSpanFormattingResolvesThroughTheSameMapperAsTheBody() throws {
        let json = """
        {"v":1,"blocks":[],
         "headers":[{"applyTo":"both","blocks":[{"t":"para","spans":[{"text":"Bold","bold":true,"color":"FF0000"}]}]}]}
        """
        let result = try HwpReader.mapJSON(json)
        guard case .paragraph(let spans, _, _, _, _) = try XCTUnwrap(result.headers.first?.blocks.first) else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertEqual(spans, [Span(text: "Bold", bold: true, textColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))])
    }
}
