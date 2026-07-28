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
        // `.resolvingFontSubstitution()` is applied HERE, at HWP's own single dispatch point
        // (invariant 44 — HWP bypasses `DocumentTypes.readOffice` entirely, so it needs its own
        // call rather than `readOffice`'s), NOT inside `mapJSON`: `mapJSON` stays a pure JSON->
        // result mapper so every hand-built-envelope test that calls it directly is unaffected by
        // this pass. See `FontSubstitutionResolver`'s file doc for why read time is the right home.
        return result.resolvingFontSubstitution()
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
            case .image(let id, _, _):
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

    /// The longest a STYLE-INFERRED heading's text may be. A heading is a label; a paragraph of prose
    /// carrying a heading-ish style name is not one, however the document styled it. Only applies to
    /// inference — an explicitly outlined paragraph is honoured at any length.
    static let headingTextLimit = 80

    /// HWP's own default line spacing. A paragraph that says exactly this is saying nothing — it is
    /// the value nearly every document carries — so it maps to the reader's house rhythm and HWP body
    /// text reads like markdown/docx body in the same window. Any OTHER percentage is an author's
    /// deliberate choice and is honoured — measured on one real document: 1,188 paragraphs sit at
    /// 160% while 772 others carry 110/120/130/140/180%, every one of which this reader used to
    /// discard. The match is near-exact (±0.5) on purpose: 158% is a choice, not a rounding of 160.
    static let neutralPercentLineHeight: CGFloat = 160

    /// A percent line height as a plain percentage, whatever encoding the file used. HWP writes this
    /// field as a percentage in some versions and as percent×100 in others, so the value is accepted
    /// only from the two plausible bands and rejected outside them — a spacing this reader cannot
    /// identify must fall back to the house rhythm, never render a document at 160× line height.
    static func percentLineHeight(_ raw: Int) -> CGFloat? {
        let v = CGFloat(raw)
        if (50...500).contains(v) { return v }              // 160  → 160%
        if (5_000...50_000).contains(v) { return v / 100 }  // 16000 → 160%
        return nil
    }

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
        // The page body width is resolved FIRST: a picture whose width is stored as a share of the
        // page (HWP's `widthCriterion`) can only become points once that width is known.
        let pageWidth = (envelope.pageContentWidth).flatMap { $0 > 0 ? CGFloat($0) : nil }
        // The document's own default body size is resolved BEFORE mapping: a percent line height is
        // relative to the text's size, so the mapper needs it to turn "200%" into points.
        let defaultBodySize = (envelope.defaultFontSizePt).flatMap { $0 > 0 ? CGFloat($0) : nil } ?? 11
        // The seven families per char shape, each row resolved through HWP's fallback chain ONCE for
        // the whole document — tens to low hundreds of rows, against the ~1.1 M spans that index into
        // them. A parser predating the `charShapes` export yields `[]`, and every span then keeps
        // rhwp's own `font`, which is exactly what this reader drew before per-slot fonts existed.
        let slotFonts = (envelope.charShapes ?? []).map { HwpSlotFonts(row: $0) }
        var result = OfficeReadResult(blocks: envelope.blocks.map {
            mapBlock($0, pageWidth: pageWidth, defaultBodySize: defaultBodySize, slotFonts: slotFonts)
        }, comments: [])
        // The document's own default body size (Normal/"바탕글" style char-shape base size, in pt),
        // rhwp's analog of docx `w:docDefaults/…/w:sz`. `null`/≤0 → leave the `11` default so an HWP
        // that declares none scales exactly like a docx/odt that declares none (invariant 37).
        if let pt = envelope.defaultFontSizePt, pt > 0 { result.defaultBodyFontSize = CGFloat(pt) }
        // The document's own page body width (paper − margins, in pt) — the denominator of the office
        // GRAPHIC scale (see `OfficeReadResult.pageContentWidth`), so an HWP image keeps the share of
        // the reading column it held of rhwp's page. The column itself always fills the window, and
        // tables are untouched. Absent/≤0 → leave nil = authored sizes verbatim. Identical handling to
        // docx/odt: one field, one consumer, no HWP-specific layout path.
        if let w = envelope.pageContentWidth, w > 0 { result.pageContentWidth = CGFloat(w) }
        return result
    }

    /// What rhwp's per-script font export looks like once THIS file's own decoder has read it.
    ///
    /// The per-slot font work (`docs/per-script-font-design.md`) lands in two steps so the risky
    /// half — replacing a 59 MB parser binary — can be verified before anything depends on it. Step
    /// one adds `csId`/`charShapes` to the JSON and changes nothing else, so the rendered document
    /// must be bit-identical; step two reads this table and splits a run where the resolved family
    /// changes. This accessor exists for step one's proof and has no caller on the render path: it
    /// is the only way to show that the new data survives the FFI, the rebuild and the decoder,
    /// because every OTHER symptom of a failed rebuild is silence (invariant 45's stale link, and a
    /// `JSONDecoder` with no key strategy turning a misnamed field into `nil` without an error).
    ///
    /// It decodes through the SAME `HwpEnvelope`/`HwpSpan` the mapper uses, deliberately — a test
    /// that re-declared its own structs would prove the JSON and say nothing about whether this
    /// reader receives it, which is invariant 29's lesson in miniature.
    struct FontSlotExport: Equatable {
        /// `charShapes`, or `[]` when the envelope carried none (a parser predating this field).
        var charShapes: [[String]]
        /// Every span's `csId` in document order, table cells included, `nil` where the span
        /// carries none. Kept in order rather than as a set so a caller can also see how many spans
        /// have no char shape at all.
        var spanCharShapeIds: [Int?]

        /// One entry per span, in the same order, carrying what a MEASUREMENT of the per-slot
        /// classifier needs and the id list alone cannot give: the text a slot decision is made
        /// over, and the single family rhwp itself resolved for that span.
        ///
        /// This exists so the two questions the design leaves open — how much a Symbol-slot
        /// exception costs in extra pieces, and whether this reader's fallback chain ever disagrees
        /// with rhwp's own `font` field — can be asked of a real corpus rather than argued. It is
        /// read only by probes; the render path takes the mapped `Span`s, not this.
        var spans: [SpanSample] = []

        struct SpanSample: Equatable {
            var text: String
            var csId: Int?
            /// rhwp's own single-family answer for this span — slot 0, falling back to slot 1 only
            /// when slot 0 resolves empty. The value this reader drew before per-slot fonts existed.
            var font: String?
        }
    }

    static func fontSlotExport(_ json: String) throws -> FontSlotExport {
        guard let data = json.data(using: .utf8) else { throw MapError.malformedJSON }
        let envelope: HwpEnvelope
        do {
            envelope = try JSONDecoder().decode(HwpEnvelope.self, from: data)
        } catch {
            throw MapError.malformedJSON
        }
        var ids: [Int?] = []
        var samples: [FontSlotExport.SpanSample] = []
        func walk(_ block: HwpBlock) {
            switch block {
            case .para(let p):
                ids.append(contentsOf: p.spans.map(\.csId))
                samples.append(contentsOf: p.spans.map {
                    FontSlotExport.SpanSample(text: $0.text, csId: $0.csId, font: $0.font)
                })
            case .table(let t):
                for row in t.rows { for cell in row { cell.blocks.forEach(walk) } }
            case .image, .unsupported, .equation:
                break
            }
        }
        envelope.blocks.forEach(walk)
        return FontSlotExport(charShapes: envelope.charShapes ?? [], spanCharShapeIds: ids,
                              spans: samples)
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

    /// One rhwp span → the `Span`s it needs, which is USUALLY exactly one.
    ///
    /// It is a list rather than a single span because HWP picks a font per CHARACTER, not per run: a
    /// char shape names seven families (`HwpFontSlot`) and the character's own writing system selects
    /// between them, so one run reading `휴먼명조 and Palatino` can genuinely ask for two typefaces.
    /// `ScriptRunSplitter` cuts it into the fewest pieces that each want one family, breaking where
    /// the resolved FAMILY changes and never where the slot index changes — which is what keeps
    /// `제1항` / `2026년` / `(3)` whole in every document that points its slots at one face.
    ///
    /// Before this existed the run took rhwp's `font` field, which is slot 0 falling back to slot 1
    /// and stops there — so a document asking for 휴먼명조 for Korean and Palatino Linotype for Latin
    /// had its Latin drawn in 휴먼명조. Measured over 1,557 real files, 53.6% of documents and 47.1%
    /// of char-shape rows declare families that are not all identical, so this is the common case and
    /// not an exotic one.
    private static func mapSpan(_ s: HwpSpan, slotFonts: [HwpSlotFonts]) -> [Span] {
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
        span.link = s.link
        if let bm = s.bookmark, !bm.isEmpty { span.bookmarks = [bm] }

        /// rhwp's own single-family answer, kept for every span this pass cannot improve on: a
        /// synthetic span with no char shape, a `csId` outside the table, or a parser predating the
        /// `charShapes` export. Each of those degrades to EXACTLY what this reader drew before.
        let declared = (s.font?.isEmpty == false) ? s.font : nil

        // An empty-text span is a bookmark anchor or a footnote marker, not something to classify —
        // and the splitter yields no pieces for empty input, which would DELETE it. Bookmarks must
        // survive (invariant 38: they are never merged away), so this returns before the walk.
        guard !s.text.isEmpty else {
            span.fontName = declared
            return [span]
        }
        guard let id = s.csId, slotFonts.indices.contains(id) else {
            span.fontName = declared
            return [span]
        }
        let fonts = slotFonts[id]
        // The case invariant 37 rests on, and the one 46.4% of real documents are in: when all seven
        // slots resolve to one family — or to none at all — no character can select anything
        // different from any other, so the scalar walk is skipped rather than run to rediscover
        // that. Before/after is then identical by CONSTRUCTION, and this path costs nothing it did
        // not cost before slots existed. `neutralFamily` is rhwp's own answer here: proven equal to
        // the exported `font` on all 1,085,915 spans of the corpus, 0 disagreements.
        guard !fonts.isUniform else {
            span.fontName = fonts.neutralFamily
            return [span]
        }
        let pieces = ScriptRunSplitter.split(s.text, classify: HwpSlotTable.slot(for:),
                                             family: fonts.family)
        // A run of nothing but absorbing characters — a tab, a stretch of spaces, `(3)` — classifies
        // nothing, and the splitter rightly hands back one piece carrying no family. Emitting that
        // verbatim would strand a theme-font span between two runs of a real family, which is
        // absorption failing at exactly the boundary it exists to protect. Unlike the docx and ODT
        // readers this needs no re-scan to recognise: on a NON-uniform row every slot resolves to a
        // non-nil family by construction (some slot is named, so the chain's fallback is non-nil for
        // all seven), so a `nil` family on this path can ONLY mean nothing classified.
        if pieces.count == 1, pieces[0].family == nil {
            span.fontName = fonts.neutralFamily
            return [span]
        }
        return pieces.enumerated().map { index, piece in
            var out = span
            out.text = String(piece.text)
            out.fontName = piece.family
            // The anchor is a POINT in the document, not a property of the text, so it rides the
            // first piece alone — copying it onto every piece would publish the same bookmark name
            // several times and give an internal link more than one place to land.
            if index > 0 { out.bookmarks = [] }
            return out
        }
    }

    private static func paragraphFormat(_ p: HwpPara, defaultBodySize: CGFloat) -> ParagraphFormat {
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
            // A percent line height that IS the format's own default (160%) is treated as "the
            // document said nothing" → the app's house rhythm, so HWP body reads like markdown/docx
            // body in the same window. Anything ELSE is an author's deliberate choice and is
            // honoured: 200% really does mean double-spaced, and forcing it back to the house rhythm
            // was overriding the document. Expressed as a FLOOR (`atLeast`) rather than a fixed
            // height so a tall CJK glyph is never clipped, and against the document's own default
            // body size, which `OfficeTextBuilder` then scales by the reading size exactly as it does
            // every other absolute metric (invariant 37).
            case "percent":
                if let percent = percentLineHeight(lh.value),
                   abs(percent - neutralPercentLineHeight) > 0.5 {
                    f.lineHeight = .atLeast(defaultBodySize * percent / 100)
                }
            case "at_least": f.lineHeight = .atLeast(CGFloat(lh.value) / 200)
            case "fixed": f.lineHeight = .exact(CGFloat(lh.value) / 200)
            default: break
            }
        }
        return f
    }

    /// A heading level from the paragraph's STYLE, for the documents HWP's outline flag misses.
    ///
    /// Measured before writing this: of 14 real HWP files, 13 produced zero headings, because
    /// `head_type == Outline` only marks paragraphs using HWP's outline NUMBERING — while ordinary
    /// Korean reports title their sections with the built-in styles instead. This is invariant 33
    /// repeating: a true premise ("outline paragraphs are headings") protected a false conclusion
    /// ("only outline paragraphs are headings").
    ///
    /// Matched on the ENGLISH name first because it is the locale-stable identity (the same style
    /// shows as 개요 1 in a Korean install and Outline 1 in an English one — invariant 33's "the ID
    /// is not localised even though the NAME is", in the form HWP offers it). The Korean name is a
    /// fallback for documents whose English names were never filled in. Deliberately narrow: only
    /// the built-in outline/title styles, never a guess from font size or boldness, so a body
    /// paragraph in a custom style is never promoted into the table of contents.
    static func headingLevel(styleName: String?, localName: String?) -> Int? {
        func level(from name: String) -> Int? {
            let n = name.trimmingCharacters(in: .whitespaces).lowercased()
            // "Outline 1"…"Outline 7" / "개요 1"…"개요 7" — the level is the trailing digit.
            for prefix in ["outline", "개요", "heading", "제목 수준"] where n.hasPrefix(prefix) {
                let rest = n.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                if let digit = Int(rest), (1...7).contains(digit) { return digit }
                if rest.isEmpty { return 1 }
            }
            // A document title is the shallowest heading there is.
            if n == "title" || n == "제목" { return 1 }
            return nil
        }
        /// Korean documents overwhelmingly name their own styles rather than using the built-ins —
        /// measured on real files: "각 장 제목" / "각 절 제목" (chapter/section title),
        /// "목차,발간사 제목". Those ARE headings and were being dropped. But the same corpus also
        /// carries "표의 제목" (a TABLE's caption, 112 occurrences in one document) and "그림"
        /// (figure) — promoting those would bury a real outline under captions, which is worse than
        /// no outline at all. So: a name must SAY title/chapter/section, and must not be about a
        /// table, figure, footnote or running head. Depth comes from the word used (장 chapter → 1,
        /// 절 section → 2, 항 clause → 3), defaulting to 1.
        func customLevel(from name: String) -> Int? {
            let n = name.trimmingCharacters(in: .whitespaces)
            // `목차` earns its place in this list by measurement, not theory: one real document styles
            // its table-of-contents ENTRIES with "목차,발간사 제목", so accepting it turned 40-odd
            // contents lines and body sentences into headings — an outline made of the outline.
            let excluded = ["표", "그림", "캡션", "각주", "미주", "머리말", "꼬리말", "쪽번호", "번호", "목차"]
            guard n.contains("제목") else { return nil }
            for word in excluded where n.contains(word) { return nil }
            if n.contains("장") { return 1 }
            if n.contains("절") { return 2 }
            if n.contains("항") { return 3 }
            return 1
        }
        if let styleName, let l = level(from: styleName) { return l }
        if let localName, let l = level(from: localName) { return l }
        if let localName, let l = customLevel(from: localName) { return l }
        if let styleName, let l = customLevel(from: styleName) { return l }
        return nil
    }

    /// Resolves a picture whose width HWP stored RELATIVE to something (a share in ten-thousandths
    /// of the paper/page/column/paragraph) into points. Returns nil for the absolute case — by far
    /// the common one — and for a document with no known page width, so the caller keeps the declared
    /// HWPUNIT conversion and nothing changes for the documents this does not apply to.
    ///
    /// The height follows the width's own ratio rather than its own criterion: HWP stores the two
    /// independently, but a picture whose height is resolved against the PAGE HEIGHT (which this
    /// reader has no measure of, being a continuous column rather than pages) would distort. Keeping
    /// the authored aspect is the honest degradation.
    static func relativeGraphicSize(w: Int, h: Int, criterion: String?, pageWidth: CGFloat?) -> CGSize? {
        guard let criterion, criterion != "absolute", let pageWidth, pageWidth > 0, w > 0 else { return nil }
        let share = CGFloat(w) / 10_000
        guard share > 0, share <= 10 else { return nil }   // a nonsense share is not applied
        let width = pageWidth * share
        let aspect = w > 0 ? CGFloat(h) / CGFloat(w) : 0
        return CGSize(width: width, height: (width * aspect).rounded())
    }

    /// The alignment HWP stored on the picture itself. `inside`/`outside` are page-relative (mirror
    /// margins) and have no meaning in a single continuous reading column, so they are reported as
    /// nil — the reader's default — rather than being flattened to left, which would state something
    /// the document did not.
    static func imageAlignment(_ raw: String?) -> NSTextAlignment? {
        switch raw {
        case "left": return .left
        case "center": return .center
        case "right": return .right
        default: return nil
        }
    }

    private static func mapBlock(_ b: HwpBlock, pageWidth: CGFloat?, defaultBodySize: CGFloat,
                                 slotFonts: [HwpSlotFonts]) -> OfficeBlock {
        switch b {
        case .para(let p):
            let spans = p.spans.flatMap { mapSpan($0, slotFonts: slotFonts) }
            let align = alignment(p.align)
            let format = paragraphFormat(p, defaultBodySize: defaultBodySize)
            // An EXPLICIT outline paragraph is a heading because the document said so — no second
            // guessing. A STYLE-derived one is an inference, so it also has to look like a heading:
            // non-empty, and short enough to be a label rather than a sentence. Measured need — one
            // document applies its "…제목" style to running body text, which produced 80-character
            // "headings" in the table of contents. `headingTextLimit` is generous on purpose (Korean
            // section titles run long); it only rejects prose.
            if let explicit = p.heading {
                return .heading(level: explicit, spans: spans, rtl: false, alignment: align, tabStops: [], format: format)
            }
            if let inferred = headingLevel(styleName: p.styleName, localName: p.styleLocalName) {
                let text = spans.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, text.count <= headingTextLimit {
                    return .heading(level: inferred, spans: spans, rtl: false, alignment: align,
                                    tabStops: [], format: format)
                }
            }
            if let list = p.list {
                return .listItem(level: list.level, ordered: list.ordered, spans: spans, marker: list.marker,
                                 rtl: false, alignment: align, tabStops: [], format: format)
            }
            return .paragraph(spans: spans, rtl: false, alignment: align, tabStops: [], format: format)
        case .table(let t):
            let rows = t.rows.map { row in
                row.map { mapCell($0, pageWidth: pageWidth, defaultBodySize: defaultBodySize,
                                  slotFonts: slotFonts) }
            }
            // colWidths as ABSOLUTE INTEGER-derived points, never percentages (invariant 39/42).
            let columnWidths = t.colWidths.map { points($0) }
            // The table's own width as HWP laid it out (points), so a picture in a cell scales against
            // the TABLE rather than the page — identical treatment to docx (`TableFormat.sourceWidth`),
            // no HWP-specific layout path. Zero/absent widths → nil → the page basis, as before.
            var format = TableFormat()
            let sourceWidth = columnWidths.reduce(0, +)
            if sourceWidth > 0 { format.sourceWidth = sourceWidth }
            // headerRows = 0: HWP's JSON carries no header signal, and inventing "row one" bolds
            // ordinary text (OfficeBlock.table's own contract). Full geometry/merge fidelity is S4.
            return .table(rows: rows, headerRows: 0, columnWidths: columnWidths, format: format)
        case .image(let im):
            // `read` resolves binDataId → pixels via `imageBase64` at read time (pre-decoded into
            // OfficeReadResult.images); the block only RESERVES the layout area here (invariant
            // 1/2/11). id is the stable key `collectImages`/`reconcileMedia` look the bytes up by.
            // `w`/`h` are absolute HWPUNIT ONLY when the document says so. A relative criterion
            // (paper/page/column/para) stores a share in ten-thousandths instead, which converted as
            // if it were HWPUNIT yields a picture hundreds of points wide — so a non-absolute width is
            // resolved against the page body width the same read already carries. `page`/`paper` both
            // resolve against it here (we have no separate paper measure at this layer), and
            // `column`/`para` against the same width, since this reader lays out a single column.
            let declared = CGSize(width: points(im.w), height: points(im.h))
            let size = relativeGraphicSize(w: im.w, h: im.h, criterion: im.widthCriterion,
                                           pageWidth: pageWidth) ?? declared
            return .image(id: "\(hwpImagePrefix)\(im.binDataId)", size: size,
                          alignment: imageAlignment(im.align))
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

    private static func mapCell(_ c: HwpCell, pageWidth: CGFloat?, defaultBodySize: CGFloat,
                                slotFonts: [HwpSlotFonts]) -> Cell {
        let blocks = c.blocks.map {
            mapBlock($0, pageWidth: pageWidth, defaultBodySize: defaultBodySize, slotFonts: slotFonts)
        }
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
    /// The first section's page BODY width in points (rhwp: `PageAreas::from_page_def().body_area`
    /// width ÷100 — paper width − margins, landscape/binding/gutter honoured), or absent/null when
    /// no section/zero width → the mapper leaves `pageContentWidth` nil (reader falls back to
    /// window-filling). rhwp already emits points, so no further conversion.
    let pageContentWidth: Double?
    /// One row per char shape, indexed by a span's `csId`; each row the SEVEN font families the
    /// document declared for that char shape, in HWP's own fixed slot order — 0 Hangul, 1 Latin,
    /// 2 Hanja, 3 Japanese, 4 Other, 5 Symbol, 6 User (`CharShape.font_ids`). An EMPTY string means
    /// the document's font table had no entry for that slot, which is a real answer ("nothing
    /// declared here") and not an error.
    ///
    /// Absent against a parser built before this existed — hence optional, and hence the reason a
    /// test has to assert it is PRESENT for a real file rather than trusting the Rust source.
    let charShapes: [[String]]?
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
    /// The paragraph STYLE's stable English name ("Outline 1", "Title"), and its Korean display name
    /// ("개요 1", "제목"). Both absent for a document whose styles carry neither.
    ///
    /// Why both: HWP's own `head_type` marks only paragraphs that use OUTLINE numbering, and measuring
    /// 14 real HWP files found 13 of them produce ZERO headings that way — practically every Korean
    /// report titles its sections with a named STYLE instead. That is invariant 33's lesson repeating
    /// itself (Word headings were missed for the same reason, in 103 of 188 documents): one signal is
    /// not the format, it is one of the ways the format expresses the same thing.
    var styleName: String?
    var styleLocalName: String?
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
    /// Which row of the envelope's `charShapes` table this run's char shape is — i.e. the seven
    /// per-script font families the DOCUMENT declared for it. Absent for a synthetic span (a
    /// bookmark anchor, a footnote reference marker) which has no char shape of its own, and for a
    /// run whose char-shape id fell outside the document's own table; rhwp omits the key in both
    /// cases, so a present value is in range by construction and needs no bounds check here.
    ///
    /// NOTHING on the render path reads this yet — `font` above is still the single family a span
    /// draws in. It is decoded now because the rebuild that added it has to be provable on its own:
    /// a stale binary (invariant 45) or a snake_case rename would leave this `nil` with no error at
    /// all, and that must fail loudly in a test rather than quietly in a month's rendering work.
    var csId: Int?

    private enum CodingKeys: String, CodingKey {
        case text, bold, italic, underline, strike, color, size, font, link, bookmark, csId
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
    /// The object's OWN horizontal alignment, which in HWP lives on the picture rather than on a
    /// containing paragraph (`left`/`center`/`right`/`inside`/`outside`).
    var align: String?
    /// What `w` is measured against: `absolute` (HWPUNIT, the overwhelmingly common case) or
    /// `paper`/`page`/`column`/`para`, where `w` is instead a share in ten-thousandths. Honouring
    /// this is what "follow the option the document stored" means for HWP — the format has five
    /// ways to state a width and forcing them all through the absolute one is a guess.
    var widthCriterion: String?
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
