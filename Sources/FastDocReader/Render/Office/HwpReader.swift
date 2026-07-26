import Foundation
import AppKit
import CRhwpNative

// Bridge to the rhwp (Rust, MIT — github.com/edwardkim/rhwp, forked: FFI drift fix +
// structured-export FFI added) HWP/HWPX parser, statically linked via the RhwpNative
// xcframework. See docs/BUILD-RHWP.md to rebuild the binary.
//
// S2 scope = the raw parse bridge only (Data -> rhwp's structured document JSON).
// The JSON -> OfficeBlock/OfficeReadResult mapping lands in S3+ so the existing
// OfficeTextBuilder renders HWP the same way it renders Word/ODT.
enum HwpReader {
    /// Parse HWP/HWPX bytes with rhwp and return its structured document JSON
    /// (`{"v":1,"blocks":[...]}`). Returns nil if rhwp cannot parse the bytes.
    ///
    /// Handle lifecycle: rhwp_open (one parse) -> rhwp_document_json -> rhwp_close,
    /// and every returned C string is freed via rhwp_string_free (see the FFI contract
    /// in bindings/Native/src/lib.rs of the fork).
    static func exportDocumentJSON(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let handle: UnsafeMutableRawPointer? = data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return rhwp_open(base, data.count)
        }
        guard let handle else { return nil }        // parse failure -> null handle
        defer { rhwp_close(handle) }

        guard let cstr = rhwp_document_json(handle) else { return nil }
        defer { rhwp_string_free(cstr) }
        return String(cString: cstr)
    }

    /// Base64 of an embedded image's bytes, by 1-based bin_data_id. Empty string when
    /// the id resolves to nothing. Requires a live handle from the same parse — S4 will
    /// use this from within a single open/close around the whole read.
    static func imageBase64(_ handle: UnsafeMutableRawPointer, binDataId: UInt16) -> String? {
        guard let cstr = rhwp_image_base64(handle, binDataId) else { return nil }
        defer { rhwp_string_free(cstr) }
        let s = String(cString: cstr)
        return s.isEmpty ? nil : s
    }

    // MARK: - S3: structured JSON -> OfficeBlock / OfficeReadResult

    enum MapError: Swift.Error, Equatable, LocalizedError {
        /// rhwp's `exportDocumentJSON` returned nil — the bytes are not a parseable HWP/HWPX
        /// document (or empty). Named so a caller can tell a parse failure from a decode failure.
        case parseFailed
        /// The JSON rhwp produced (or a synthetic string) could not be decoded into the expected
        /// `{"v":1,"blocks":[…]}` shape — malformed JSON, or a block whose `"t"` isn't one this
        /// mapper handles.
        case malformedJSON

        var errorDescription: String? {
            switch self {
            case .parseFailed:
                return "This file could not be parsed as an HWP/HWPX document — it may be corrupt or an unsupported format."
            case .malformedJSON:
                return "The HWP document's internal structure could not be read."
            }
        }
    }

    /// The public office entry: HWP/HWPX bytes → the SAME `OfficeReadResult` `DocxReader`/`OdtReader`
    /// return, so `OfficeTextBuilder` renders HWP identically. Two steps kept separate on purpose —
    /// `exportDocumentJSON` (the FFI, untestable without a file) then `mapJSON` (a pure
    /// `String -> OfficeReadResult`, unit-tested with synthetic JSON, no FFI needed).
    static func read(_ data: Data) throws -> OfficeReadResult {
        guard !data.isEmpty else { throw MapError.parseFailed }
        // ONE open/close spans BOTH the JSON export AND the image fetch: rhwp's image FFI needs the
        // SAME live parse handle the JSON came from, and there is no archive to fall back on later
        // (HWP is CFB binary, not a zip), so an image not decoded inside this handle's lifetime is
        // gone. `exportDocumentJSON` stays a self-closing pure JSON getter for tests; this path
        // re-opens because it also needs the handle alive for `imageBase64`.
        let handle: UnsafeMutableRawPointer? = data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return rhwp_open(base, data.count)
        }
        guard let handle else { throw MapError.parseFailed }   // parse failure -> null handle
        defer { rhwp_close(handle) }

        guard let cstr = rhwp_document_json(handle) else { throw MapError.parseFailed }
        let json = String(cString: cstr)
        rhwp_string_free(cstr)

        var result = try mapJSON(json)                          // KEEP mapJSON pure (String -> result)
        result.images = collectImages(handle: handle, blocks: result.blocks)
        return result
    }

    /// Walk the mapped blocks (recursively, INCLUDING table cells) for every `.image(id:)` whose id
    /// is an embedded HWP image (`"hwpimg:<binDataId>"`), fetch its bytes via the live `handle`, and
    /// return them keyed by the SAME id string the block carries — the key `reconcileMedia` looks up.
    /// A linked (external-URL) image has no `hwpimg:` id and no embedded bytes, so it is skipped here
    /// and resolved by the URL path instead, exactly like a linked docx/odt image.
    private static func collectImages(handle: UnsafeMutableRawPointer, blocks: [OfficeBlock]) -> [String: Data] {
        var out: [String: Data] = [:]
        func walk(_ block: OfficeBlock) {
            switch block {
            case .image(let id, _):
                guard out[id] == nil, id.hasPrefix(hwpImagePrefix),
                      let binDataId = UInt16(id.dropFirst(hwpImagePrefix.count)),
                      let b64 = imageBase64(handle, binDataId: binDataId),
                      let data = Data(base64Encoded: b64) else { return }
                out[id] = data
            case .table(let rows, _, _, _):
                for row in rows { for cell in row { for b in cell.blocks { walk(b) } } }
            default:
                break
            }
        }
        blocks.forEach(walk)
        return out
    }

    /// The id prefix `mapBlock` stamps on an embedded HWP image — kept in ONE place so the writer
    /// (`mapBlock`) and the reader (`collectImages`, and `reconcileMedia`'s map lookup) can never
    /// drift on the string.
    static let hwpImagePrefix = "hwpimg:"

    /// PURE mapping: rhwp's structured JSON string → `OfficeReadResult`. Separated from the FFI so
    /// the whole JSON→OfficeBlock vocabulary is testable with hand-built envelopes. HWP comments are
    /// a later/never sprint, so `comments` is always `[]`.
    static func mapJSON(_ json: String) throws -> OfficeReadResult {
        guard let data = json.data(using: .utf8) else { throw MapError.malformedJSON }
        let envelope: HwpEnvelope
        do {
            envelope = try JSONDecoder().decode(HwpEnvelope.self, from: data)
        } catch {
            throw MapError.malformedJSON
        }
        var result = OfficeReadResult(blocks: envelope.blocks.map(mapBlock), comments: [])
        // The document's own default body size (Normal/"바탕글" style char-shape base size, in pt),
        // rhwp's analog of docx `w:docDefaults/…/w:sz`. `null`/≤0 → leave the `11` default so an HWP
        // that declares none scales exactly like a docx/odt that declares none (invariant 37).
        if let pt = envelope.defaultFontSizePt, pt > 0 { result.defaultBodyFontSize = CGFloat(pt) }
        return result
    }

    // MARK: unit conversion (HWPUNIT = 1/7200 inch; points = HWPUNIT ÷ 100)

    /// A raw HWPUNIT PARAGRAPH-METRIC length (spacing / indent / margin) → points. HWP5 stores these
    /// at 2× the effective value (rhwp halves them — `style_resolver.rs` `variant_div = 2.0`), so the
    /// scale is ÷200 (HWPUNIT→pt = ÷100, then ÷2). `nil`/`0` → `nil` so unspecified leaves the theme
    /// token in place, byte-identical to a block with no format (invariant 37).
    /// NOTE: font size and image/column extents are NOT 2×-stored — those use `points()` (÷100).
    private static func nonZeroPoints(_ hwpunit: Int?) -> CGFloat? {
        guard let v = hwpunit, v != 0 else { return nil }
        return CGFloat(v) / 200
    }

    /// A raw HWPUNIT EXTENT (font size, image/column width/height) → points. These are stored at true
    /// HWPUNIT (NOT 2×), so ÷100 (confirmed against rhwp `hwpunit_to_px` + `base_size`/`common.width`).
    private static func points(_ hwpunit: Int) -> CGFloat { CGFloat(hwpunit) / 100 }

    /// "RRGGBB" (6 hex digits, optional leading '#') → sRGB colour; anything else → nil (theme
    /// decides — invariant 37). Mirrors `DocxReader.colorFromHex`.
    private static func color(_ hex: String?) -> NSColor? {
        guard var digits = hex else { return nil }
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// HWP paragraph `align` → the block's `NSTextAlignment?`, resolved exactly the way
    /// `DocxReader.alignmentFromJc` does: `"both"`/`"justify"`/`"distribute"` → `.justified`
    /// (`NSTextAlignment` has no distributed case, so distribute collapses to justify — same choice
    /// DocxReader makes for `w:jc="distribute"`); an unrecognized/absent value → `nil` so `rtl`/the
    /// theme default decides, never a hardcoded `.left`.
    private static func alignment(_ align: String?) -> NSTextAlignment? {
        switch align {
        case "left": return .left
        case "center": return .center
        case "right": return .right
        case "justify", "both", "distribute": return .justified
        default: return nil
        }
    }

    /// HWP span `underline` string → (`underline` on/off, `underlineStyle`). `"none"`/absent → off;
    /// each named style maps to the matching `UnderlineStyle` case (all five HWP names have an exact
    /// AppKit equivalent, so no nearest-case approximation is needed).
    private static func underline(_ u: String?) -> (Bool, UnderlineStyle) {
        switch u {
        case "single": return (true, .single)
        case "double": return (true, .double)
        case "dotted": return (true, .dotted)
        case "dashed": return (true, .dashed)
        case "wavy": return (true, .wavy)
        default: return (false, .single)   // "none" / null / unknown
        }
    }

    private static func mapSpan(_ s: HwpSpan) -> Span {
        let (ul, ulStyle) = underline(s.underline)
        var span = Span(text: s.text)
        span.bold = s.bold ?? false
        span.italic = s.italic ?? false
        span.underline = ul
        span.underlineStyle = ulStyle
        span.strikethrough = s.strike ?? false
        span.superscript = s.superscript ?? false
        span.subscripted = s.subscripted ?? false
        span.textColor = color(s.color)
        // size is a base_size in HWPUNIT; ÷100 = points. 0/absent → unspecified (theme decides).
        if let sz = s.size, sz > 0 { span.fontSize = CGFloat(sz) / 100 }
        if let font = s.font, !font.isEmpty { span.fontName = font }
        span.link = s.link
        if let bm = s.bookmark, !bm.isEmpty { span.bookmarks = [bm] }
        return span
    }

    private static func paragraphFormat(_ p: HwpPara) -> ParagraphFormat {
        var f = ParagraphFormat()
        f.spacingBefore = nonZeroPoints(p.spaceBefore)
        f.spacingAfter = nonZeroPoints(p.spaceAfter)
        f.indentStart = nonZeroPoints(p.indentStart)
        f.indentEnd = nonZeroPoints(p.indentEnd)
        // firstLine indent is mutually exclusive with hanging (mirrors docx `w:firstLine`/`w:hanging`
        // and ODF's signed `fo:text-indent`): a positive value is a first-line indent, a negative
        // one is a hanging indent expressed as its magnitude.
        if let fi = p.indentFirst, fi != 0 {
            // first-line/hanging indent is also a 2×-stored paragraph metric → ÷200 (see nonZeroPoints).
            if fi > 0 { f.firstLineIndent = CGFloat(fi) / 200 }
            else { f.hangingIndent = CGFloat(-fi) / 200 }
        }
        if let lh = p.lineHeight, lh.value > 0 {
            switch lh.type {
            // HWP percent line spacing is the format's NEUTRAL default (near-universal 160%, its
            // docDefault-equivalent). Treat it as UNSPECIFIED (invariant 37) → leave lineHeight nil →
            // the app's house rhythm (1.45× em fixed), so HWP body reads IDENTICALLY to markdown/docx
            // body in the SAME app. `.multiple(1.6)` would render ~1.81× em — looser than md/docx AND
            // font-dependent/uneven on CJK (exactly why MarkdownRenderer refuses lineHeightMultiple).
            // Author-chosen ABSOLUTE line heights (fixed/at-least) ARE honoured; HWP5 stores them 2× → ÷200.
            case "percent": break
            case "at_least": f.lineHeight = .atLeast(CGFloat(lh.value) / 200)
            case "fixed": f.lineHeight = .exact(CGFloat(lh.value) / 200)
            default: break
            }
        }
        return f
    }

    private static func mapBlock(_ b: HwpBlock) -> OfficeBlock {
        switch b {
        case .para(let p):
            let spans = p.spans.map(mapSpan)
            let align = alignment(p.align)
            let format = paragraphFormat(p)
            if let heading = p.heading {
                return .heading(level: heading, spans: spans, rtl: false, alignment: align, tabStops: [], format: format)
            }
            if let list = p.list {
                return .listItem(level: list.level, ordered: list.ordered, spans: spans, marker: list.marker,
                                 rtl: false, alignment: align, tabStops: [], format: format)
            }
            return .paragraph(spans: spans, rtl: false, alignment: align, tabStops: [], format: format)
        case .table(let t):
            let rows = t.rows.map { row in row.map(mapCell) }
            // colWidths as ABSOLUTE INTEGER-derived points, never percentages (invariant 39/42).
            let columnWidths = t.colWidths.map { points($0) }
            // headerRows = 0: HWP's JSON carries no header signal, and inventing "row one" bolds
            // ordinary text (OfficeBlock.table's own contract). Full geometry/merge fidelity is S4.
            return .table(rows: rows, headerRows: 0, columnWidths: columnWidths, format: TableFormat())
        case .image(let im):
            // `read` resolves binDataId → pixels via `imageBase64` at read time (pre-decoded into
            // OfficeReadResult.images); the block only RESERVES the layout area here (invariant
            // 1/2/11). id is the stable key `collectImages`/`reconcileMedia` look the bytes up by.
            return .image(id: "\(hwpImagePrefix)\(im.binDataId)", size: CGSize(width: points(im.w), height: points(im.h)))
        case .unsupported(let u):
            return .unsupportedGraphic(label: u.label, size: CGSize(width: points(u.w), height: points(u.h)))
        case .equation(let e):
            // rhwp now hands us real LaTeX; route it to the SAME `.formula` case a Word `m:oMathPara`
            // becomes, so `OfficeTextBuilder` renders it through the app's formula engine with no
            // HWP-specific path (invariant: office `.formula` rides the markdown `$$…$$` web-block
            // pipeline). `w`/`h` are advisory only — the formula engine sizes from the rendered LaTeX.
            let latex = e.latex.trimmingCharacters(in: .whitespacesAndNewlines)
            if !latex.isEmpty { return .formula(latex: latex) }
            // Empty/whitespace latex → an honest placeholder, NEVER an empty formula (mirrors
            // DocxReader.formulaBlock's never-nothing ladder). rhwp already degrades a parse failure
            // to `unsupported`; this guards the residual "equation block with nothing translatable".
            return .unsupportedGraphic(label: "equation",
                                       size: CGSize(width: points(e.w ?? 0), height: points(e.h ?? 0)))
        }
    }

    private static func mapCell(_ c: HwpCell) -> Cell {
        let blocks = c.blocks.map(mapBlock)
        // "top" is Word/HWP's own default → nil, so a cell that only ever says "top" renders
        // byte-identical to one that says nothing (Cell.verticalAlignment's contract); only an
        // explicit center/bottom is carried.
        let vAlign: CellVAlign?
        switch c.vAlign {
        case "center": vAlign = .center
        case "bottom": vAlign = .bottom
        default: vAlign = nil               // "top" / null / unknown → unspecified default
        }
        return Cell(blocks: blocks, rowSpan: c.rowSpan, colSpan: c.colSpan, verticalAlignment: vAlign)
    }
}

// MARK: - Codable model mirroring rhwp's `{"v":1,"blocks":[…]}` schema

private struct HwpEnvelope: Decodable {
    let v: Int
    /// The document's default body font size in points (rhwp: default style char-shape base_size
    /// ÷100), or absent/null when rhwp could not determine it → the mapper keeps the `11` fallback.
    let defaultFontSizePt: Double?
    let blocks: [HwpBlock]
}

/// A body block, discriminated by its `"t"` tag. Decoding re-reads the SAME object through the
/// tag-specific struct rather than duplicating each field into a flat model.
private enum HwpBlock: Decodable {
    case para(HwpPara)
    case table(HwpTable)
    case image(HwpImage)
    case unsupported(HwpUnsupported)
    case equation(HwpEquation)

    private enum Keys: String, CodingKey { case t }

    init(from decoder: Decoder) throws {
        let tag = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .t)
        switch tag {
        case "para": self = .para(try HwpPara(from: decoder))
        case "table": self = .table(try HwpTable(from: decoder))
        case "image": self = .image(try HwpImage(from: decoder))
        case "unsupported": self = .unsupported(try HwpUnsupported(from: decoder))
        case "equation": self = .equation(try HwpEquation(from: decoder))
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown block type \"\(tag)\""))
        }
    }
}

private struct HwpPara: Decodable {
    var heading: Int?
    var spans: [HwpSpan]
    var align: String?
    var indentStart: Int?
    var indentEnd: Int?
    var indentFirst: Int?
    var spaceBefore: Int?
    var spaceAfter: Int?
    var lineHeight: HwpLineHeight?
    var list: HwpList?
}

private struct HwpLineHeight: Decodable {
    var type: String
    var value: Int
}

private struct HwpList: Decodable {
    var level: Int
    var ordered: Bool
    var marker: String?
}

private struct HwpSpan: Decodable {
    var text: String
    var bold: Bool?
    var italic: Bool?
    var underline: String?
    var strike: Bool?
    var superscript: Bool?      // JSON key "super" (a Swift keyword) — remapped below
    var subscripted: Bool?      // JSON key "sub"
    var color: String?
    var size: Int?
    var font: String?
    var link: String?
    var bookmark: String?

    private enum CodingKeys: String, CodingKey {
        case text, bold, italic, underline, strike, color, size, font, link, bookmark
        case superscript = "super"
        case subscripted = "sub"
    }
}

private struct HwpTable: Decodable {
    var cols: Int?
    var colWidths: [Int]
    var borderFillId: Int?
    var rows: [[HwpCell]]
}

private struct HwpCell: Decodable {
    var colSpan: Int
    var rowSpan: Int
    var vAlign: String?
    var borderFillId: Int?
    var blocks: [HwpBlock]
}

private struct HwpImage: Decodable {
    var binDataId: Int
    var w: Int
    var h: Int
    var mime: String?
}

private struct HwpUnsupported: Decodable {
    var label: String
    var w: Int
    var h: Int
}

/// A display equation rhwp translated to LaTeX (`{"t":"equation","latex":…,"script":…,"w":…,"h":…}`).
/// `latex` is the TeX string the app's formula engine renders; `script` is the raw HWP equation script
/// (kept for provenance/fallback, not currently rendered); `w`/`h` are advisory HWPUNIT dimensions used
/// only to reserve a placeholder area when `latex` is empty. All but `latex` are optional — a minimal
/// producer may emit `{"t":"equation","latex":…}` alone.
private struct HwpEquation: Decodable {
    var latex: String
    var script: String?
    var w: Int?
    var h: Int?
}
