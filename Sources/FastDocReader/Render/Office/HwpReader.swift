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

        // The picture provider is what lets a FILL image be decoded during the mapping walk; it is
        // the same FFI `collectImages` uses, handed in rather than reached for, so `mapJSON` stays a
        // pure function of its two arguments and every hand-built-envelope test is unaffected.
        var result = try mapJSON(json) { binDataId in
            guard let id = UInt16(exactly: binDataId), let b64 = imageBase64(handle, binDataId: id) else { return nil }
            return Data(base64Encoded: b64)
        }
        // Embedded pictures are fetched here (they need the live handle); drawings were already
        // rendered inside `mapJSON` and must survive that — hence a merge rather than an assignment.
        result.images.merge(collectImages(handle: handle, blocks: result.blocks)) { _, new in new }
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

    /// The id prefix for a DRAWING this reader rendered itself (`HwpShapeRenderer`) — distinct from
    /// `hwpImagePrefix` because these bytes are made here, not fetched from the file, so
    /// `collectImages` must not try to look them up by `binDataId`.
    static let hwpShapePrefix = "hwpshape:"

    /// Where a drawing's rendered PDF goes while the block walk is still running. A reference type
    /// so the `map` closures that build blocks can add to it without threading `inout` through five
    /// signatures; `mapJSON` hands its contents to the result, which is what makes the shape bytes
    /// reachable by `reconcileMedia` under the id the block carries.
    final class MediaContext {
        var images: [String: Data] = [:]
        /// Objects pinned to the PAPER, collected during the block walk with the index of the block
        /// they were anchored at — see `OfficeAnchoredObject`. A reference type for the same reason
        /// `images` is: the `map` closures that build blocks add to it without threading `inout`.
        var anchored: [OfficeAnchoredObject] = []
        /// The document's own paper, when it declared one — the reference an anchored object is
        /// placed against.
        var paper: PaperGeometry?
        /// Where the drawing whose text box is being read sits on the paper. A text box's paragraphs
        /// arrive as the SIBLING blocks right after their own drawing (the exporter's contract, see
        /// `docs/BUILD-RHWP.md` item 7), and they state their geometry in that drawing's frame rather
        /// than the paper's — so the frame this records is the origin those coordinates are measured
        /// from. Nil until the walk has passed an anchored object, which is exactly when a box
        /// coordinate cannot be resolved and is therefore ignored.
        var lastAnchoredFrame: CGRect?
        /// The index of the top-level block being mapped, so an anchored object knows where in the
        /// document it belongs. Set by `mapJSON`'s own loop; nested content (a table cell) keeps the
        /// top-level block's index, which is the page-bearing one.
        var blockIndex = 0
        /// Bytes for an embedded picture by `binDataId`, when the caller has a live parse handle.
        /// `nil` in `mapJSON`-only use (every unit test): a picture FILL then stays unpainted rather
        /// than the mapper inventing a colour for it.
        let picture: ((Int) -> Data?)?
        private var next = 0
        init(picture: ((Int) -> Data?)? = nil) { self.picture = picture }
        /// The decoded image for a fill's `binDataId`, or nil when there is no provider or no bytes.
        func fillImage(_ binDataId: Int?) -> NSImage? {
            guard let binDataId, binDataId > 0, let data = picture?(binDataId) else { return nil }
            return NSImage(data: data)
        }
        func add(_ data: Data) -> String {
            next += 1
            let id = "\(hwpShapePrefix)\(next)"
            images[id] = data
            return id
        }
    }

    /// The longest a STYLE-INFERRED heading's text may be. A heading is a label; a paragraph of prose
    /// carrying a heading-ish style name is not one, however the document styled it. Only applies to
    /// inference — an explicitly outlined paragraph is honoured at any length.
    static let headingTextLimit = 80

    /// HWP's own default line spacing, and the value a NON-PAGED HWP still treats as "nothing
    /// stated" — see `paragraphFormat`'s percent arm for why that treatment survives there and
    /// nowhere else. The match is near-exact (±0.5) on purpose: 158% is a choice, not a rounding
    /// of 160. Measured across 637 real files, 225,654 of 525,054 percent paragraphs (43%) sit
    /// here, so this constant decides the most common Korean page there is.
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
    static func mapJSON(_ json: String, pictureProvider: ((Int) -> Data?)? = nil) throws -> OfficeReadResult {
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
        // The document's own border/background table, resolved ONCE for the whole document the same
        // way `slotFonts` is — a cell carries only an id. `[]` (a parser predating this export)
        // leaves every table exactly as this reader drew it before: the theme grid.
        let borderFills = envelope.borderFills ?? []
        // Drawings are rendered DURING the block walk (see `HwpShapeRenderer`); the bytes they produce
        // join the result's own media map, keyed by the id their block carries.
        let shapes = MediaContext(picture: pictureProvider)
        // `paged` is not a second flag — it is the SAME predicate `OfficeTextBuilder.build` resolves
        // as `pageBasis != nil` (a page content width the document actually stated), read here from
        // the same field so the reader and the builder cannot drift on what "paged" means.
        // The paper an anchored object is placed on. Only present when the document declared a page
        // at all; without it nothing can be pinned to a sheet and every object stays in the flow.
        if let w = envelope.pageContentWidth, w > 0, let h = envelope.pageContentHeight, h > 0 {
            shapes.paper = PaperGeometry(contentWidth: CGFloat(w), contentHeight: CGFloat(h),
                                         marginLeft: CGFloat(envelope.pageMarginLeft ?? 0),
                                         marginTop: CGFloat(envelope.pageMarginTop ?? 0),
                                         marginRight: CGFloat(envelope.pageMarginRight ?? 0),
                                         marginBottom: CGFloat(envelope.pageMarginBottom ?? 0))
        }
        var result = OfficeReadResult(blocks: envelope.blocks.enumerated().map { index, block in
            shapes.blockIndex = index
            return mapBlock(block, pageWidth: pageWidth, defaultBodySize: defaultBodySize,
                            slotFonts: slotFonts, borderFills: borderFills, shapes: shapes,
                            paged: pageWidth != nil)
        }, comments: [])
        result.anchoredObjects = shapes.anchored
        // The author's OWN page breaks. `section` counts too: a Korean document starts a new page at
        // a section break, and this reader flattens every section into one column (invariant 57), so
        // without it the sections simply run together. `multiColumn`/`column` are NOT page breaks —
        // they move to the next COLUMN, which a single-column reader has nowhere to honour, and
        // treating them as pages would invent breaks the document never asked for.
        result.pageBreakBlocks = envelope.blocks.enumerated().compactMap { index, block in
            guard case .para(let p) = block else { return nil }
            // The author's own break, and the STYLE's — two separate signals in HWP, the same
            // instruction to a reader.
            return (p.breakBefore == "page" || p.breakBefore == "section" || p.pageBreakBefore == true)
                ? index : nil
        }
        result.sections = (envelope.sections ?? []).map { section in
            OfficeSectionDeclaration(
                paper: section.page.map {
                    PaperGeometry(contentWidth: $0.contentWidth, contentHeight: $0.contentHeight,
                                  marginLeft: $0.marginLeft, marginTop: $0.marginTop,
                                  marginRight: $0.marginRight, marginBottom: $0.marginBottom)
                },
                hidesHeader: section.hideHeader ?? false,
                hidesFooter: section.hideFooter ?? false,
                hidesMasterPage: section.hideMasterPage ?? false,
                pageNumberStart: section.pageNumberStart.flatMap { $0 > 0 ? $0 : nil },
                lineGridPitch: section.lineGridHwpUnit.flatMap { $0 > 0 ? points($0) : nil },
                isVertical: section.verticalText ?? false)
        }
        result.keepWithNextBlocks = envelope.blocks.enumerated().compactMap { index, block in
            guard case .para(let p) = block, p.keepWithNext == true else { return nil }
            return index
        }
        // The drawings this read rendered — merged, not assigned, so a later `read()` that also
        // fetches embedded pictures keeps both (invariant: one media map, one id space).
        result.images = shapes.images
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
        // The vertical twin, plus all four margins — HWP wired NONE of these before this change
        // (only the body width was read), so this is new ground for the format, not an extension of
        // an existing HWP layout path. Each is adopted independently and ONLY when present and
        // positive, exactly like the `pageContentWidth` line above: a document a parser predating
        // these fields produced leaves every one of them nil, unchanged (invariant 37's "unspecified
        // → theme/fallback" contract, restated for geometry rather than typography).
        if let h = envelope.pageContentHeight, h > 0 { result.pageContentHeight = CGFloat(h) }
        if let l = envelope.pageMarginLeft, l > 0 { result.pageMarginLeft = CGFloat(l) }
        if let r = envelope.pageMarginRight, r > 0 { result.pageMarginRight = CGFloat(r) }
        if let t = envelope.pageMarginTop, t > 0 { result.pageMarginTop = CGFloat(t) }
        if let b = envelope.pageMarginBottom, b > 0 { result.pageMarginBottom = CGFloat(b) }
        // header-footer-design.md step 2/3 — read ONLY, nothing renders these yet. `nil` (a parser
        // built before this field existed) behaves exactly like `[]`: no running header/footer
        // captured, same as every other reader that finds none.
        // Running heads from the BODY section only — a header declared by some other section
        // describes that section's pages, not this reading column's. A parser predating
        // `bodySection`/`section` leaves both nil and every entry is kept, exactly as before.
        let bodySection = envelope.bodySection
        let sectionStarts = envelope.sectionStarts ?? []
        result.sectionStartBlocks = sectionStarts
        func inBodySection(_ entry: HwpHeaderFooterEntry) -> Bool {
            guard let bodySection, let section = entry.section else { return true }
            return section == bodySection
        }
        // Every section's entries are kept when the parser said where sections start — the painter
        // picks per page, the same way it picks a master page. Without `sectionStarts` a page cannot
        // be placed in a section at all, and then the body section's are the only honest answer
        // (invariant 77: applying another section's put a page number on 400 pages that never had one).
        let keepEveryHeadSection = !sectionStarts.isEmpty
        result.headers = (envelope.headers ?? []).filter { keepEveryHeadSection || inBodySection($0) }.map {
            mapHeaderFooterEntry($0, pageWidth: pageWidth, defaultBodySize: defaultBodySize,
                                 slotFonts: slotFonts, borderFills: borderFills, shapes: shapes,
                                 paged: pageWidth != nil)
        }
        result.footers = (envelope.footers ?? []).filter { keepEveryHeadSection || inBodySection($0) }.map {
            mapHeaderFooterEntry($0, pageWidth: pageWidth, defaultBodySize: defaultBodySize,
                                 slotFonts: slotFonts, borderFills: borderFills, shapes: shapes,
                                 paged: pageWidth != nil)
        }
        // EVERY section's template is kept, and the painter picks per page (`sectionStartBlocks`).
        // Keeping only the body section's — the rule a running head needs (invariant 77) — put that
        // section's chapter title on the cover, on the table of contents and on every other
        // chapter's pages, which is the same defect one level up. Without `sectionStarts` no page
        // can be placed in a section at all, and then the body section's is the honest single answer.
        result.masterPages = (envelope.masterPages ?? [])
            .filter { !sectionStarts.isEmpty || bodySection == nil || $0.section == bodySection }
            .compactMap {
                mapMasterPage($0, pageWidth: pageWidth, defaultBodySize: defaultBodySize,
                              slotFonts: slotFonts, borderFills: borderFills, shapes: shapes,
                              paged: pageWidth != nil)
            }
        return result
    }

    /// Where an anchored object sits on the SHEET, in points from the paper's top-left — rhwp's own
    /// placement rule (`renderer/layout/shape_layout.rs`'s `calc_shape_bottom_y`), restated for the
    /// two references this reader can honour.
    ///
    /// `paper` measures against the whole sheet, `page` against the body area inside the margins.
    /// `para`/`column` need the anchoring paragraph's own position — the floating layer invariant 75
    /// measured and rejected — so they never reach here.
    static func anchoredFrame(size: CGSize, vertRelTo: String, horzRelTo: String,
                              vertAlign: String, horzAlign: String,
                              offset: CGPoint, page: PaperGeometry) -> CGRect? {
        guard vertRelTo == "paper" || vertRelTo == "page",
              horzRelTo == "paper" || horzRelTo == "page" else { return nil }
        func place(_ refOrigin: CGFloat, _ refExtent: CGFloat, _ own: CGFloat,
                   _ align: String, _ offset: CGFloat) -> CGFloat {
            switch align {
            case "center": return refOrigin + (refExtent - own) / 2 + offset
            case "bottom", "outside": return refOrigin + refExtent - own - offset
            default: return refOrigin + offset          // top / inside
            }
        }
        let vRef: (CGFloat, CGFloat) = vertRelTo == "paper"
            ? (0, page.paperHeight) : (page.marginTop, page.contentHeight)
        let hRef: (CGFloat, CGFloat) = horzRelTo == "paper"
            ? (0, page.paperWidth) : (page.marginLeft, page.contentWidth)
        return CGRect(x: place(hRef.0, hRef.1, size.width, horzAlign, offset.x),
                      y: place(vRef.0, vRef.1, size.height, vertAlign, offset.y),
                      width: size.width, height: size.height)
    }

    /// Where a PARAGRAPH-anchored object sits — the half of the placement that does not need layout,
    /// plus the rule for the half that does.
    ///
    /// Horizontally there is nothing to wait for: `para`/`column` both measure against the text
    /// COLUMN, which this reader lays out at one fixed width, so it is the same body area
    /// `anchoredFrame` uses for a page-relative object. Vertically the reference is the anchoring
    /// paragraph's own line, so the returned frame's `y` is a placeholder and the `ParagraphAnchor`
    /// beside it says how to measure the real one once layout can answer where that line is.
    ///
    /// Returns nil for a vertical reference that is NOT the paragraph — those are already placed in
    /// full by `anchoredFrame`, and one function must not answer for both.
    static func paragraphAnchoredPlacement(
        size: CGSize, vertRelTo: String, horzRelTo: String, vertAlign: String, horzAlign: String,
        offset: CGPoint, page: PaperGeometry
    ) -> (frame: CGRect, anchor: ParagraphAnchor)? {
        guard vertRelTo == "para" else { return nil }
        let hRef: (CGFloat, CGFloat)
        switch horzRelTo {
        case "paper": hRef = (0, page.paperWidth)
        default: hRef = (page.marginLeft, page.contentWidth)   // page / column / para
        }
        let x: CGFloat
        switch horzAlign {
        case "center": x = hRef.0 + (hRef.1 - size.width) / 2 + offset.x
        case "right", "outside": x = hRef.0 + hRef.1 - size.width - offset.x
        default: x = hRef.0 + offset.x                          // left / inside
        }
        let align: ParagraphAnchor.Align
        switch vertAlign {
        case "center": align = .center
        case "bottom", "outside": align = .bottom
        default: align = .top                                   // top / inside
        }
        return (CGRect(x: x, y: 0, width: size.width, height: size.height),
                ParagraphAnchor(align: align, offset: offset.y))
    }

    /// The paper an anchored object is placed on lives in the format-neutral vocabulary
    /// (`PaperGeometry` in `OfficeBlock.swift`) — a section's own sheet is a fact docx and odt state
    /// too, so the type that carries it must not belong to one reader.
    typealias PaperGeometry = FastDocReader.PaperGeometry

    /// One 바탕쪽 → the format-neutral `OfficeMasterPage`, or nil when nothing in it can be drawn.
    ///
    /// Every object is resolved HERE, at read time, into bytes or blocks — the same choice
    /// `HwpShapeRenderer` already forced for inline drawings (invariant 75): the picture provider and
    /// the live parse handle exist during the read and are gone by the time anything paints.
    private static func mapMasterPage(
        _ page: HwpMasterPage, pageWidth: CGFloat?, defaultBodySize: CGFloat,
        slotFonts: [HwpSlotFonts], borderFills: [HwpBorderFill], shapes: MediaContext, paged: Bool
    ) -> OfficeMasterPage? {
        var objects: [OfficeMasterObject] = []
        // rhwp's own order, not the storage order: measured on the 편람, the full-page background
        // picture is stored FIRST and the running title SECOND, so drawing them as stored painted
        // the artwork over the title. Sorted by the SAME key the renderer sorts paper-relative nodes
        // by — text-wrap band, then z-order, then stable position — with a stable sort so an object
        // that declares neither keeps its place.
        let ordered = page.objects.enumerated()
            .sorted { a, b in
                let ka = (a.element.plane ?? 2, a.element.z ?? 0, a.offset)
                let kb = (b.element.plane ?? 2, b.element.z ?? 0, b.offset)
                return ka < kb
            }
            .map(\.element)
        for object in ordered {
            let frame = CGRect(x: points(object.x), y: points(object.y),
                               width: points(object.w), height: points(object.h))
            // A picture first, because an object that HAS one is that picture: the paths beside it
            // are the frame the document drew round it, and rhwp already exports the two separately.
            if let binDataId = object.binDataId, let image = shapes.fillImage(binDataId) {
                objects.append(OfficeMasterObject(frame: frame, content: .image(image)))
                continue
            }
            // A drawing is rendered to the SAME vector PDF an inline shape becomes, so the tab down
            // the page edge is drawn by the code that already draws the arrows in the body.
            let paths = (object.paths ?? []).compactMap(shapePath)
            if !paths.isEmpty, frame.width > 0.5, frame.height > 0.5,
               let pdf = HwpShapeRenderer.pdf(paths: paths, size: frame.size) {
                objects.append(OfficeMasterObject(frame: frame, content: .drawing(pdf)))
            }
            let blocks = (object.blocks ?? []).map {
                mapBlock($0, pageWidth: pageWidth, defaultBodySize: defaultBodySize,
                         slotFonts: slotFonts, borderFills: borderFills, shapes: shapes, paged: paged)
            }
            // A DEGENERATE box is dropped rather than given a width this reader invents. Measured on
            // the 편람, one master text box states a width of zero (a rotated tab label on the cover
            // section) — laying text into a box the document sized at nothing means choosing the
            // width ourselves, which is invariant 57's mistake. The body section's own four objects
            // all state real boxes.
            if !blocks.isEmpty, frame.width > 0.5, frame.height > 0.5 {
                objects.append(OfficeMasterObject(frame: frame, content: .text(blocks)))
            }
        }
        guard !objects.isEmpty else { return nil }
        return OfficeMasterPage(section: page.section,
                                appliesTo: mapHeaderFooterApplyTo(page.applyTo), objects: objects)
    }

    /// One rhwp header/footer entry (`{"applyTo":"both"|"even"|"odd","blocks":[…]}`) → the SAME
    /// format-neutral `OfficeHeaderFooter` docx/odt produce — its `blocks` are the identical `HwpBlock`
    /// shape the body uses, mapped through the SAME `mapBlock` (zero new block-parsing code, mirroring
    /// header-footer-design.md §2c's "parseBody already generalizes" for docx/odt).
    private static func mapHeaderFooterEntry(
        _ entry: HwpHeaderFooterEntry, pageWidth: CGFloat?, defaultBodySize: CGFloat,
        slotFonts: [HwpSlotFonts], borderFills: [HwpBorderFill], shapes: MediaContext, paged: Bool
    ) -> OfficeHeaderFooter {
        OfficeHeaderFooter(
            appliesTo: mapHeaderFooterApplyTo(entry.applyTo),
            blocks: entry.blocks.map {
                mapBlock($0, pageWidth: pageWidth, defaultBodySize: defaultBodySize, slotFonts: slotFonts,
                         borderFills: borderFills, shapes: shapes, paged: paged)
            },
            section: entry.section)
    }

    /// rhwp's `apply_to` (`"both"`/`"even"`/`"odd"`) → `HeaderFooterApplicability` — see that enum's
    /// own doc for why this is NOT a case-for-case correspondence with docx's three types. `"even"`
    /// is the one honest match. `"both"` (no even override declared anywhere in the section — this
    /// entry covers every page) and `"odd"` (an even override EXISTS elsewhere, so this entry is
    /// explicitly the non-even pages) both fold into `.defaultPages`: this reader has no consumer
    /// yet that would need the two told apart, and docx's own `.defaultPages` already means "every
    /// page not covered by a more specific entry" — the same shape. An unrecognized value (a rhwp
    /// version ahead of this mapper) degrades to `.defaultPages` too, rather than being dropped.
    private static func mapHeaderFooterApplyTo(_ raw: String) -> HeaderFooterApplicability {
        raw == "even" ? .evenPages : .defaultPages
    }

    /// What rhwp's per-script font export looks like once THIS file's own decoder has read it.
    ///
    /// The per-slot font work (`docs/per-script-font-design.md`) lands in two steps so the risky
    /// half — replacing the prebuilt parser binary — can be verified before anything depends on it. Step
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
            case .image, .shape, .unsupported, .equation:
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

    /// A gradient fill drawn as the gradient it is — every stop, at the angle the document stated.
    ///
    /// The stops and the angle were decoded and then thrown away: both consumers read `colors[0]` and
    /// painted a flat wash, so a two-colour panel rendered as its first colour and the angle was dead
    /// data. There is no gradient in the table/cell vocabulary — a fill is a colour or an image — so
    /// this renders one into the IMAGE slot the picture fill already uses, which the painters draw
    /// stretched into the rect (`GridTextTableBlock`, `TableBlockBuilder`). A single stop is a plain
    /// fill and stays on the colour path; a picture fill wins, because that is a real picture.
    ///
    /// HWP measures the angle in degrees CLOCKWISE from straight down (0 = top-to-bottom), which is
    /// the direction Hancom's own gradient dialog states.
    private static func gradientImage(_ gradient: HwpGradient?) -> NSImage? {
        guard let gradient else { return nil }
        let stops = gradient.colors.compactMap { color($0) }
        guard stops.count >= 2 else { return nil }
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        let ns = NSGradient(colors: stops)
        // NSGradient measures counter-clockwise from the positive x axis; HWP measures clockwise
        // from straight down. 0° must come out pointing down the page, which in this flipped-free
        // image space is -90°.
        ns?.draw(in: NSRect(origin: .zero, size: size),
                 angle: -90 - CGFloat(gradient.angle ?? 0))
        return image
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
        // Only "page" is exported today; anything else is a future rhwp speaking a word this build
        // does not know, and a page number drawn as its cached value beats one drawn as a guess.
        if s.pageNumberField == "page" { span.pageNumberField = .page }

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
            // Same reason, and the same shape: the field is ONE substitution site. Left on every
            // piece, a page number that happened to split would be replaced once per piece and draw
            // "33" on page 3. (Digits are one script, so this is a guard, not a path taken today.)
            if index > 0 { out.pageNumberField = nil }
            return out
        }
    }

    /// rhwp's own `max_fs` for one paragraph: the largest size any of its runs DECLARES, in points.
    /// `nil` when no run declares one (an empty paragraph, or a run that inherits its size), and the
    /// caller then falls back to the document default.
    ///
    /// Per-PARAGRAPH rather than per-LINE, which is the one honest gap against HWP: HWP re-picks
    /// `max_fs` for every wrapped line, and an `NSParagraphStyle` carries a single line rule for the
    /// whole paragraph, so a paragraph mixing one 20pt word into 10pt prose spaces all of its lines
    /// for the 20pt one. Taking the MAXIMUM (rather than, say, the first or the most common run) is
    /// what keeps that degradation on the safe side of invariant 1's territory — a floor that is too
    /// generous adds space, while one that is too small lets the tall line set its own natural
    /// height and silently under-spaces exactly the line that needed the room.
    private static func maxRunSize(_ spans: [HwpSpan]) -> CGFloat? {
        // Same conversion `mapSpan` applies to `Span.fontSize` (base_size in HWPUNIT, ÷100 = points),
        // so the basis a line is spaced by is the size that line is actually drawn at.
        spans.compactMap { $0.size.flatMap { $0 > 0 ? CGFloat($0) / 100 : nil } }.max()
    }

    /// A paragraph that lives INSIDE a drawing's text box, moved to where that box is.
    ///
    /// These words are not body text. A Korean document builds its cover and its foreword out of a
    /// picture frame with a box of text sitting inside it, and a reader that flows them down the full
    /// body column puts a 300pt block of type across a 396pt column — beside the frame it belongs in
    /// rather than within it. The box states where it is (`boxX`/`boxW`, HWPUNIT) in ITS OWN
    /// DRAWING's frame, so the paper position is that drawing's origin plus the box, and the indent
    /// is what is left once the body column's own left edge is taken off.
    ///
    /// Only the HORIZONTAL half is honoured. The vertical one would have to lift the paragraph out of
    /// the flow entirely, which is the floating-object layout invariant 31 measured and did not ship,
    /// and doing it would also take the words out of `--extract` (invariant 40). Left in the flow the
    /// text still reads and still extracts; it is only lower on the page than the document draws it.
    ///
    /// The narrowing is CLAMPED. Trusting a box width blindly is what the first attempt did with
    /// coordinates that were not coordinates at all (`boxW` was 0 because a group child's own
    /// `common` is empty), and 1,510 paragraphs took an indent that left them almost no width — the
    /// 편람 went 520 pages to 436. A box that does not leave a readable column is not honoured.
    private static func boxedFormat(_ format: ParagraphFormat, para p: HwpPara,
                                    shapes: MediaContext) -> ParagraphFormat {
        guard let paper = shapes.paper, let owner = shapes.lastAnchoredFrame,
              let bx = p.boxX, let bw = p.boxW, bw > 0 else { return format }
        let column = (left: paper.marginLeft, width: paper.contentWidth)
        guard column.width > 0 else { return format }
        let boxLeft = owner.minX + points(bx)
        let boxWidth = points(bw)
        let start = max(0, boxLeft - column.left)
        let end = max(0, column.width - start - boxWidth)
        // Below this the "box" is telling us something we cannot draw — a coordinate we misread, or a
        // box that genuinely sits outside the body column. Flowing at full width is wrong but legible;
        // a 40pt column is neither.
        guard column.width - start - end >= column.width * 0.25 else { return format }
        var f = format
        f.indentStart = start
        f.indentEnd = end
        return f
    }

    private static func paragraphFormat(_ p: HwpPara, defaultBodySize: CGFloat,
                                        paged: Bool) -> ParagraphFormat {
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
            // HWP percent line spacing, resolved the way HWP ITSELF resolves it — which is not what
            // the estimate this code used to carry said. rhwp is a full HWP renderer and states the
            // rule in three independent places (`renderer/mod.rs` `corrected_line_height`,
            // `composer/line_breaking.rs` `compute_line_spacing_hwp`, `height_measurer.rs`):
            //
            //     line pitch = max_fs × percent / 100
            //
            // where `max_fs` is the largest FONT SIZE in the line, and `LineSeg.line_height` IS that
            // font size (rhwp's own empirical note: 10pt → 1000, 12pt → 1200, 25pt → 2500 HWPUNIT).
            // So 160% is exactly 1.6× em. The superseded comment estimated "~1.81× em" and concluded
            // 160% must therefore be discarded as looser than the house rhythm — but that 1.81 was a
            // property of `.multiple(1.6)`, i.e. `NSParagraphStyle.lineHeightMultiple` scaling the
            // FONT's natural height (≈1.13 em on a Korean face), never a property of HWP. The
            // measurement was of the wrong subject, and this reader now uses `.atLeast(points)`,
            // which is em-relative and font-independent, so the hazard it named cannot arise.
            //
            // PAGED → every percentage is honoured, 160 included. Discarding the most common rule in
            // Korean typesetting (225,654 of 525,054 percent paragraphs across 637 real files) is
            // exactly the "document stated something, app overrode it" the paged model exists to
            // stop: HWP asks for 1.6× em and the house rhythm draws 1.45×, so the most common Korean
            // page came out ~9% tighter than its author set it and every line break downstream moved.
            //
            // NON-PAGED → unchanged, deliberately. There the old window-filling model still runs
            // (office text re-typeset at the READER's size), and with it the old justification that
            // HWP body should read like markdown/docx body in the same window. Measured: 637 of 637
            // real files declare a page width, so this arm is reached only by a document that
            // declares none — for which byte-identical is the contract.
            //
            // The BASIS is the paragraph's own `max_fs`, not the document default, because HWP's
            // percentage is of the text's OWN size. Measured across the corpus, only 76,601 of
            // 392,216 percent paragraphs (19.5%) have a run size within 5% of the document default —
            // so the default is the wrong basis four times in five, and 47 of 637 files report a
            // default that is not a plausible body size at all (1pt, 24pt, 40pt). Using it would
            // have made the small-text majority WORSE than the house rhythm it replaced: a
            // 0.8×-default paragraph wants 1.28× the default and would have been given 1.6×, a 25%
            // over-space against the 13% the house rhythm already cost.
            //
            // A FLOOR (`atLeast`) rather than `.exact` so a tall CJK glyph or a substituted face is
            // never clipped. The cost is honest and one-directional: below ~120% the floor sits under
            // the font's natural height and the line renders looser than HWP would draw it (63,931
            // paragraphs ask for 100%). Looser never clips; `.exact` would.
            case "percent":
                if let percent = percentLineHeight(lh.value) {
                    if paged {
                        f.lineHeight = .atLeast((maxRunSize(p.spans) ?? defaultBodySize) * percent / 100)
                    } else if abs(percent - neutralPercentLineHeight) > 0.5 {
                        f.lineHeight = .atLeast(defaultBodySize * percent / 100)
                    }
                }
            // Author-chosen ABSOLUTE line heights are honoured in both models; HWP5 stores these
            // 2× → ÷200 (see `nonZeroPoints`).
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
                                 slotFonts: [HwpSlotFonts], borderFills: [HwpBorderFill],
                                 shapes: MediaContext, paged: Bool) -> OfficeBlock {
        switch b {
        case .para(let p):
            let spans = p.spans.flatMap { mapSpan($0, slotFonts: slotFonts) }
            let align = alignment(p.align)
            let base = paragraphFormat(p, defaultBodySize: defaultBodySize, paged: paged)
            // NOT indented to `boxX`/`boxW`, deliberately. A text box that is a GROUP's child states
            // its offset in the GROUP's coordinates, not the paper's, and rhwp resolves that through
            // its own render tree (`shape_layout.rs`'s group origin walk). Treating the raw offset as
            // a paper coordinate was tried and measured: 1,510 paragraphs took an indent that left
            // them almost no width, and the manual went 520 pages to 436. The geometry is exported
            // and carried; honouring it needs the group-origin math, not a guess.
            // The paragraph's OWN tab stops. HWP keeps them in a shared tab-definition table the
            // paragraph points at, so a signature block's right-aligned column or a leader dot run
            // used to fall back to this reader's default tab width — the same information docx and
            // odt have carried since they were built.
            let tabStops: [TabStop] = (p.tabStops ?? []).compactMap { stop in
                let position = points(stop.posHwpUnit)
                guard position > 0 else { return nil }
                let alignment: TabAlignment
                switch stop.kind {
                case "right": alignment = .right
                case "center": alignment = .center
                case "decimal": alignment = .decimal
                default: alignment = .left
                }
                return TabStop(position: position, alignment: alignment)
            }
            let format = boxedFormat(base, para: p, shapes: shapes)
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
                                 rtl: false, alignment: align, tabStops: tabStops, format: format,
                                 numbering: ListNumbering(
                                    glyphs: ListNumbering.Glyphs(rawValue: list.numberFormat ?? "") ?? .decimal,
                                    startNumber: list.startNumber))
            }
            return .paragraph(spans: spans, rtl: false, alignment: align, tabStops: tabStops, format: format)
        case .table(let t):
            let rows = t.rows.map { row in
                row.map { mapCell($0, pageWidth: pageWidth, defaultBodySize: defaultBodySize,
                                  slotFonts: slotFonts, borderFills: borderFills, shapes: shapes,
                                  paged: paged) }
            }
            // colWidths as ABSOLUTE INTEGER-derived points, never percentages (invariant 39/42).
            let columnWidths = t.colWidths.map { points($0) }
            // The table's own width as HWP laid it out (points), so a picture in a cell scales against
            // the TABLE rather than the page — identical treatment to docx (`TableFormat.sourceWidth`),
            // no HWP-specific layout path. Zero/absent widths → nil → the page basis, as before.
            var format = TableFormat()
            let sourceWidth = columnWidths.reduce(0, +)
            if sourceWidth > 0 { format.sourceWidth = sourceWidth }
            // A table's own border-fill is its BACKGROUND, not a box around the grid: rhwp's renderer
            // hands the table's fill to `render_cell_background` and to nothing else
            // (`layout/table_cell_content.rs:529`), and every rule on screen comes from the CELL
            // fills. So the id becomes shading here and never a border — see invariant 74 for the
            // measurement that corrected the opposite assumption.
            let tableFill = borderFill(forId: t.borderFillId, in: borderFills)
            format.defaultShading = tableFill.flatMap { color($0.bg) }
            // A PICTURE fill on the table is one image behind the whole grid — the rounded box a
            // Korean document draws around an annotation. Painted once by `GridTextTable`, never
            // repeated per cell, which is what turns one frame into a wall of frames.
            format.backgroundImage = shapes.fillImage(tableFill?.bgImage)
                ?? gradientImage(tableFill?.bgGradient)
            // A single-stop gradient is a plain fill, and one that could not be drawn still reads
            // closer to the document as its first colour than as blank paper.
            if format.defaultShading == nil, format.backgroundImage == nil,
               let stops = tableFill?.bgGradient?.colors, !stops.isEmpty {
                format.defaultShading = color(stops[0])
            }
            // The AUTHOR's own repeating header rows. Inventing "row one is a header" was the
            // alternative and it bolds ordinary text; taking the document's mark costs nothing and
            // is the only way a table that crosses a page keeps its column labels on page two.
            return .table(rows: rows, headerRows: max(0, t.headerRows ?? 0),
                          columnWidths: columnWidths, format: format)
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
            // PINNED TO THE PAPER — a cover's artwork, the frame a foreword is printed inside. It is
            // drawn on the sheet its anchoring block falls on, exactly like an anchored drawing.
            //
            // This was measured and REJECTED once, and what changed is not the reasoning but a
            // missing fact: with the picture out of the flow, a page that holds nothing else stopped
            // existing at all, and the manual's two-page cover collapsed (451 → 436). Pages existed
            // only where text reached. They no longer do — the document's own page breaks are read
            // now (`pageBreakBlocks`), so a page the author declared exists whether or not anything
            // flows onto it, and the artwork has a sheet to be drawn on. Keeping the picture inline
            // is what was corrupting everything after it: a 688pt frame in a 555pt body takes two
            // pages by itself and pushes the text meant to sit INSIDE it onto the next one.
            if im.asChar != true, let paper = shapes.paper, let bytes = shapes.picture?(im.binDataId),
               let image = NSImage(data: bytes),
               let frame = anchoredFrame(size: size, vertRelTo: im.vertRelTo ?? "para",
                                         horzRelTo: im.horzRelTo ?? "para",
                                         vertAlign: im.vertAlign ?? "top",
                                         horzAlign: im.horzAlign ?? "left",
                                         offset: CGPoint(x: points(im.offsetX ?? 0),
                                                         y: points(im.offsetY ?? 0)),
                                         page: paper) {
                shapes.lastAnchoredFrame = frame
                shapes.anchored.append(OfficeAnchoredObject(
                    blockIndex: shapes.blockIndex,
                    object: OfficeMasterObject(frame: frame, content: .image(image))))
                return .paragraph(spans: [])
            }
            return .image(id: "\(hwpImagePrefix)\(im.binDataId)", size: size,
                          alignment: imageAlignment(im.align))
        case .shape(let sh):
            // An ANCHORED drawing is placed by the document's own rule — the offsets ALONE are not
            // enough, and that is exactly what the float layer invariant 75 rejected got wrong: it
            // guessed the reference edge and laid a 431pt rule over a table's own column label.
            // `vert_align`/`horz_align` say which edge the offset is measured from (invariant 81),
            // so with those exported, a paper-, page- or paragraph-anchored drawing lands where the
            // document put it. A PICTURE is still never floated — see the `.image` case above for
            // the 451→436 measurement that decided it.
            let paths = sh.paths.compactMap { shapePath($0) }
            var size = CGSize(width: points(sh.w), height: points(sh.h))
            if size.width < 1 || size.height < 1, let extent = pathsExtent(paths) { size = extent }
            // PINNED TO THE PAPER — a cover's decoration, a rule down a margin. Placed by the
            // document's own rule (`anchoredFrame`) and drawn on the sheet the anchoring block falls
            // on, rather than pushed into the text where inlining one cost 29 pages (invariant 75).
            if sh.asChar != true, let paper = shapes.paper,
               let frame = anchoredFrame(size: size, vertRelTo: sh.vertRelTo ?? "para",
                                         horzRelTo: sh.horzRelTo ?? "para",
                                         vertAlign: sh.vertAlign ?? "top",
                                         horzAlign: sh.horzAlign ?? "left",
                                         offset: CGPoint(x: points(sh.offsetX ?? 0),
                                                         y: points(sh.offsetY ?? 0)),
                                         page: paper),
               let pdf = HwpShapeRenderer.pdf(paths: paths, size: size) {
                shapes.lastAnchoredFrame = frame
                shapes.anchored.append(OfficeAnchoredObject(
                    blockIndex: shapes.blockIndex,
                    object: OfficeMasterObject(frame: frame, content: .drawing(pdf))))
                return .paragraph(spans: [])
            }
            // PINNED TO ITS PARAGRAPH — a seal over a signature line, an arrow onto the table beside
            // it. Only the horizontal half can be settled here; the vertical one is finished by the
            // draw pass, which is the only place that knows where the anchoring line ended up.
            if sh.asChar != true, let paper = shapes.paper,
               let placement = paragraphAnchoredPlacement(
                    size: size, vertRelTo: sh.vertRelTo ?? "para", horzRelTo: sh.horzRelTo ?? "para",
                    vertAlign: sh.vertAlign ?? "top", horzAlign: sh.horzAlign ?? "left",
                    offset: CGPoint(x: points(sh.offsetX ?? 0), y: points(sh.offsetY ?? 0)),
                    page: paper),
               let pdf = HwpShapeRenderer.pdf(paths: paths, size: size) {
                shapes.lastAnchoredFrame = placement.frame
                shapes.anchored.append(OfficeAnchoredObject(
                    blockIndex: shapes.blockIndex,
                    object: OfficeMasterObject(frame: placement.frame, content: .drawing(pdf)),
                    paragraphAnchor: placement.anchor))
                return .paragraph(spans: [])
            }
            guard sh.asChar == true, let pdf = HwpShapeRenderer.pdf(paths: paths, size: size) else {
                return .paragraph(spans: [])
            }
            return .image(id: shapes.add(pdf), size: size, alignment: imageAlignment(sh.align))
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
                                slotFonts: [HwpSlotFonts], borderFills: [HwpBorderFill],
                                shapes: MediaContext, paged: Bool) -> Cell {
        let blocks = c.blocks.map {
            mapBlock($0, pageWidth: pageWidth, defaultBodySize: defaultBodySize, slotFonts: slotFonts,
                     borderFills: borderFills, shapes: shapes, paged: paged)
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
        // The cell's own four-edge inner margin, ALREADY resolved by rhwp's
        // `Cell::effective_padding` (the `aim` flag, the table-wide fallback and the preserved-pad
        // hygiene limit, all measured against Hancom's own PDFs) — so the rule lives in ONE place and
        // this reader does not invent a second one. Before this existed HWP declared no padding at
        // all and every cell fell to `TableBlockBuilder.defaultCellPadding` (7pt on all four edges):
        // measured on a real 490-page 편람, that invented number alone made the document 66 pages
        // longer than the official viewer's 429. Invariant 57(a)'s failure, in a fourth place.
        //
        // A parser predating this field decodes as nil and behaves exactly as before.
        let edges: EdgePadding?
        if c.padLeft != nil || c.padRight != nil || c.padTop != nil || c.padBottom != nil {
            edges = EdgePadding(top: c.padTop.map { CGFloat($0) },
                                left: c.padLeft.map { CGFloat($0) },
                                bottom: c.padBottom.map { CGFloat($0) },
                                right: c.padRight.map { CGFloat($0) })
        } else {
            edges = nil
        }
        // The cell's own four edges and background, resolved from the id it carries. Before this the
        // id arrived and resolved to nothing, so EVERY HWP table was ruled with the reader's theme
        // grid — including the layout tables a Korean document uses to place things, whose borders it
        // had deliberately turned off (measured: 423 of the 편람's 821 definitions are all-off).
        let fill = borderFill(forId: c.borderFillId, in: borderFills)
        var shading = fill.flatMap { color($0.bg) }
        let fillImage = shapes.fillImage(fill?.bgImage) ?? gradientImage(fill?.bgGradient)
        if shading == nil, fillImage == nil,
           let stops = fill?.bgGradient?.colors, !stops.isEmpty { shading = color(stops[0]) }
        return Cell(blocks: blocks, rowSpan: c.rowSpan, colSpan: c.colSpan,
                    backgroundColor: shading,
                    backgroundImage: fillImage,
                    edgeBorders: edgeBorders(forFillId: c.borderFillId, in: borderFills),
                    verticalAlignment: vAlign, edgePadding: edges)
    }

    /// One exported path → the renderer's own vocabulary, converting HWPUNIT to points as it goes.
    /// A command whose operator or arity this reader does not recognise is DROPPED rather than
    /// guessed at — a mis-read control point draws a line across the page, which is worse than a
    /// missing segment.
    private static func shapePath(_ p: HwpShapePath) -> HwpShapeRenderer.Path? {
        var commands: [HwpShapeRenderer.Path.Command] = []
        for token in p.d {
            let numbers = token.compactMap { $0.value }.map { CGFloat($0) / 100 }
            switch (token.first?.name ?? "", numbers.count) {
            case ("M", 2): commands.append(.move(CGPoint(x: numbers[0], y: numbers[1])))
            case ("L", 2): commands.append(.line(CGPoint(x: numbers[0], y: numbers[1])))
            case ("C", 6):
                commands.append(.curve(CGPoint(x: numbers[0], y: numbers[1]),
                                       CGPoint(x: numbers[2], y: numbers[3]),
                                       CGPoint(x: numbers[4], y: numbers[5])))
            case ("Z", _): commands.append(.close)
            default: continue
            }
        }
        guard !commands.isEmpty else { return nil }
        var stroke: BorderSide?
        if let s = p.stroke {
            stroke = BorderSide(width: CGFloat(s.widthPt ?? 0.5), color: color(s.color) ?? .black,
                                style: lineStyle(s.type ?? "solid"))
        }
        return HwpShapeRenderer.Path(commands: commands, stroke: stroke, fill: color(p.fill),
                                     arrowStart: p.arrowStart ?? false, arrowEnd: p.arrowEnd ?? false)
    }

    /// The box the paths themselves occupy — the fallback size for an object whose own record states
    /// none, so a drawing with real geometry is never collapsed to nothing.
    private static func pathsExtent(_ paths: [HwpShapeRenderer.Path]) -> CGSize? {
        var maxX: CGFloat = 0, maxY: CGFloat = 0, any = false
        for path in paths {
            for command in path.commands {
                let points: [CGPoint]
                switch command {
                case .move(let p), .line(let p): points = [p]
                case .curve(let a, let b, let c): points = [a, b, c]
                case .close: points = []
                }
                for p in points { maxX = max(maxX, p.x); maxY = max(maxY, p.y); any = true }
            }
        }
        guard any, maxX > 0.5, maxY > 0.5 else { return nil }
        return CGSize(width: maxX, height: maxY)
    }

    /// The border-fill row an id names, or nil when the document named none. HWP's reference is
    /// 1-BASED and `0` means "nothing specified" — the same convention rhwp's own renderer applies
    /// (`border_fill_id - 1`), restated here rather than assumed, because an off-by-one silently
    /// paints every cell with its neighbour's rules.
    private static func borderFill(forId id: Int?, in fills: [HwpBorderFill]) -> HwpBorderFill? {
        guard let id, id > 0, id - 1 < fills.count else { return nil }
        return fills[id - 1]
    }

    /// A border-fill id → the four edges it declares. `nil` when no fill resolves (id absent, `0`,
    /// out of range, or a parser predating the export) → unchanged behaviour: the theme grid.
    ///
    /// Every resolved edge is a DECLARATION, never silence — HWP's fill states all four, so an edge
    /// this document turned off becomes `.suppressed` rather than nil. That distinction is the whole
    /// fix: nil would fall back through the cascade to the very border the document erased
    /// (invariant 47).
    private static func edgeBorders(forFillId id: Int?, in fills: [HwpBorderFill]) -> EdgeBorders? {
        guard let fill = borderFill(forId: id, in: fills) else { return nil }
        return EdgeBorders(top: borderDecl(fill.top), left: borderDecl(fill.left),
                           bottom: borderDecl(fill.bottom), right: borderDecl(fill.right))
    }

    /// One exported edge → the reader's three-state declaration. `"none"` (the document switched the
    /// edge off) → `.suppressed`; anything else is a real rule at the width and colour the document
    /// gave. A width that failed to arrive falls back to the same 1pt the theme uses, so a malformed
    /// edge is still drawn rather than silently vanishing.
    private static func borderDecl(_ edge: HwpBorderEdge) -> BorderDecl {
        if edge.type == "none" { return .suppressed }
        let width = (edge.widthPt).flatMap { $0 > 0 ? CGFloat($0) : nil } ?? 1
        return .drawn(BorderSide(width: width, color: color(edge.color), style: lineStyle(edge.type)))
    }

    /// HWP's 18-value line type (spec table 27, exported by name) → the four this reader paints.
    /// The dash family collapses to one dash and the multi-line family to `double`; `wave` and the
    /// four 3-D bevels have no honest match and stay `solid`, which is what they are made of.
    private static func lineStyle(_ type: String) -> BorderLineStyle {
        switch type {
        case "dash", "dashDot", "dashDotDot", "longDash": return .dashed
        case "dot", "circle": return .dotted
        case "double", "thinThickDouble", "thickThinDouble", "thinThickThinTriple", "doubleWave":
            return .double
        default: return .solid
        }
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
    /// The first section's page BODY height in points (rhwp: `PageAreas::from_page_def().body_area`
    /// height ÷100, landscape/binding/gutter honoured) — the vertical twin of `pageContentWidth`, same
    /// absent/null → nil semantics.
    let pageContentHeight: Double?
    /// The first section's page margins in points (rhwp: paper size minus the resolved body area, on
    /// each of the four edges) — nil/absent for a parser built before this existed, same as
    /// `pageContentWidth`/`pageContentHeight`.
    let pageMarginLeft: Double?
    let pageMarginRight: Double?
    let pageMarginTop: Double?
    let pageMarginBottom: Double?
    /// One row per char shape, indexed by a span's `csId`; each row the SEVEN font families the
    /// document declared for that char shape, in HWP's own fixed slot order — 0 Hangul, 1 Latin,
    /// 2 Hanja, 3 Japanese, 4 Other, 5 Symbol, 6 User (`CharShape.font_ids`). An EMPTY string means
    /// the document's font table had no entry for that slot, which is a real answer ("nothing
    /// declared here") and not an error.
    ///
    /// Absent against a parser built before this existed — hence optional, and hence the reason a
    /// test has to assert it is PRESENT for a real file rather than trusting the Rust source.
    let charShapes: [[String]]?
    /// The document's own border/background definitions, indexed by `borderFillId - 1` (HWP's
    /// reference is 1-based; `0` means "nothing specified" and points at no row at all). Absent
    /// against a parser built before this export existed, which is exactly the state in which every
    /// HWP table was drawn with the reader's OWN grid: the ids arrived, nothing could resolve them.
    /// Measured on `2025_행정업무운영편람_최종.hwp`: 423 of 821 definitions turn all four edges OFF,
    /// so a document that deliberately erased its grid (layout tables) was ruled anyway.
    let borderFills: [HwpBorderFill]?
    let blocks: [HwpBlock]
    /// Running headers/footers (header-footer-design.md §3) — rhwp's `model/header_footer.rs`
    /// `Header`/`Footer`, each with its own `apply_to` and full paragraph body, exported by
    /// `document_json.rs`'s `append_control_blocks` (a Rust-side change tracked separately from
    /// this Swift mapper — see that design doc's step 6). `nil` for a parser built before this
    /// export existed, which the mapper treats exactly like `[]`: no running header/footer at all,
    /// unchanged from before this field existed (invariant 37's contract, restated for HWP).
    let headers: [HwpHeaderFooterEntry]?
    let footers: [HwpHeaderFooterEntry]?
    /// The section this document is typeset on (the one holding the most paragraphs, the same choice
    /// `pageContentWidth` comes from). Running heads are kept ONLY from this section: measured on a
    /// real manual, exactly one of 14 sections declares any — a five-paragraph landscape insert —
    /// and applying it document-wide printed a page number at the top of every even page and the
    /// bottom of every odd one, for 400 pages, while rhwp itself draws neither (invariant 77).
    let bodySection: Int?
    /// The document's 바탕쪽 templates, each with the section that declares it and its objects at
    /// PAPER coordinates (HWPUNIT from the sheet's top-left). `nil` for a parser predating the
    /// export — treated exactly like `[]`, i.e. no master page, which is how this reader behaved
    /// before the feature existed.
    let masterPages: [HwpMasterPage]?
    /// Where each section begins in the flat `blocks` array. `nil` for a parser predating it, and
    /// then no page can be told which section it is on — the reader keeps only the body section's
    /// template, which is what it did before per-page selection existed.
    let sectionStarts: [Int]?
    let sections: [HwpSection]?
}

/// One 바탕쪽 as rhwp exports it. `section` is filtered against the envelope's `bodySection` for the
/// same reason a running head is (invariant 77).
private struct HwpMasterPage: Decodable {
    var section: Int
    var applyTo: String
    var objects: [HwpMasterObject]
}

/// One positioned object of a master page. `kind` says which of the three payloads is the real one:
/// `image` carries `binDataId`, `shape` carries `paths`, `text` carries `blocks` — AND, in real
/// files, its own `paths` too (a Korean number box is a rounded rectangle with a number in it), so
/// the two are not alternatives to each other.
private struct HwpMasterObject: Decodable {
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var kind: String
    /// The two halves of rhwp's OWN paper-plane sort key (`Layout::paper_node_sort_key`): the
    /// text-wrap band (1 behind text, 2 ordinary, 3 in front) and the z-order within it. A parser
    /// predating them decodes as nil, and the objects then keep their stored order — which is what
    /// this reader did until the 편람 showed why that is not the same thing.
    var plane: Int?
    var z: Int?
    var binDataId: Int?
    var paths: [HwpShapePath]?
    var blocks: [HwpBlock]?
}

/// One running header or footer entry, decoded straight off rhwp's own export shape
/// (`{"applyTo":"both"|"even"|"odd","blocks":[…]}`) — `blocks` are the SAME `HwpBlock` the document
/// body decodes, so mapping one is exactly `mapBlock`, called nowhere differently than the body's own
/// blocks are.
private struct HwpHeaderFooterEntry: Decodable {
    var applyTo: String
    /// Which section declared it. A running head belongs to its own section — see the envelope's
    /// `bodySection` for why a reader that lays the whole document on one page must filter by it.
    var section: Int?
    var blocks: [HwpBlock]
}

/// A body block, discriminated by its `"t"` tag. Decoding re-reads the SAME object through the
/// tag-specific struct rather than duplicating each field into a flat model.
private enum HwpBlock: Decodable {
    case para(HwpPara)
    case table(HwpTable)
    case image(HwpImage)
    case shape(HwpShape)
    case unsupported(HwpUnsupported)
    case equation(HwpEquation)

    private enum Keys: String, CodingKey { case t }

    init(from decoder: Decoder) throws {
        let tag = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .t)
        switch tag {
        case "para": self = .para(try HwpPara(from: decoder))
        case "table": self = .table(try HwpTable(from: decoder))
        case "image": self = .image(try HwpImage(from: decoder))
        case "shape": self = .shape(try HwpShape(from: decoder))
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
    /// The paragraph's own tab stops, from HWP's shared tab-definition table.
    var tabStops: [HwpTabStop]?
    /// When the paragraph lives inside a drawing's TEXT BOX rather than in the body, the box's own
    /// position and size in HWPUNIT (accumulated through group nesting). Absent for a body paragraph.
    var boxX: Int?
    var boxY: Int?
    var boxW: Int?
    var boxH: Int?
    /// Keep this paragraph with the next one / do not split it / do not strand its first or last
    /// line / the STYLE says start a page here (which is a different signal from the author's own
    /// `breakBefore`). All four are what stop a heading being paginated away from its body.
    var keepWithNext: Bool?
    var keepLines: Bool?
    var widowOrphan: Bool?
    var pageBreakBefore: Bool?
    /// `"page"`/`"section"`/`"multiColumn"`/`"column"`, absent when the paragraph starts nothing.
    var breakBefore: String?
}

private struct HwpLineHeight: Decodable {
    var type: String
    var value: Int
}

/// What a SECTION declared about itself — which page furniture it hides, where it restarts page
/// numbering, whether it is written on a grid or vertically. Absent for a parser predating the
/// export, and then every section reads as declaring nothing, which is how this reader always
/// behaved.
private struct HwpSection: Decodable {
    var page: HwpSectionPage?
    var hideHeader: Bool?
    var hideFooter: Bool?
    var hideMasterPage: Bool?
    var pageNumberStart: Int?
    var lineGridHwpUnit: Int?
    var charGridHwpUnit: Int?
    var verticalText: Bool?
}

/// The paper a SECTION declared, in points. HWP defines a page per section; the envelope's own
/// `pageContentWidth`/`Height` carry only the section with the most paragraphs (invariant 73).
private struct HwpSectionPage: Decodable {
    var contentWidth: CGFloat
    var contentHeight: CGFloat
    var marginLeft: CGFloat
    var marginRight: CGFloat
    var marginTop: CGFloat
    var marginBottom: CGFloat
}

private struct HwpTabStop: Decodable {
    var posHwpUnit: Int
    var kind: String?
}

private struct HwpList: Decodable {
    var level: Int
    var ordered: Bool
    /// The document's OWN marker — its number format string (`^1.`, 가./나./다.) or its bullet
    /// character (▶). Absent means the document declared none and the reader's default stands.
    var marker: String?
    /// The level's start number when the author set one other than 1.
    var startNumber: Int?
    /// Which glyphs the number is written in (HWP's own table 43), named — see `ListNumbering.Glyphs`.
    var numberFormat: String?
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
    /// `"page"` when this run stands in for HWP's live page-number control, absent otherwise.
    ///
    /// HWP writes a page number as a `Control::AutoNumber(Page)` — a control, not characters — so
    /// before rhwp exported it a Korean footer reading `- 3 -` arrived as `-   -` with the number
    /// missing entirely. The number rhwp computed rides along as this run's text (what a reader with
    /// no pagination would show), and this marker lets `PageBandPainter` replace it with the page
    /// actually being drawn, exactly as it does for Word's `PAGE` field.
    var pageNumberField: String?

    private enum CodingKeys: String, CodingKey {
        case text, bold, italic, underline, strike, color, size, font, link, bookmark, csId
        case pageNumberField
        case superscript = "super"
        case subscripted = "sub"
    }
}

/// One row of the document's border/background table (rhwp `borderFills`). Every HWP cell names one
/// of these, and it declares ALL FOUR of that cell's edges — so an HWP cell is never in
/// `BorderDecl`'s "never mentioned" state once its id resolves: an edge is either drawn or
/// explicitly `none`. That is why this maps to a fully-populated `EdgeBorders` rather than leaving
/// unmentioned edges to the table cascade the way docx's partial `w:tcBorders` does.
private struct HwpBorderFill: Decodable {
    var left: HwpBorderEdge
    var right: HwpBorderEdge
    var top: HwpBorderEdge
    var bottom: HwpBorderEdge
    /// Solid background fill as `"RRGGBB"`, already filtered by rhwp's own renderer rule — a
    /// pattern, gradient, image or transparent fill arrives absent, and the reader paints nothing
    /// rather than guessing an average colour.
    var bg: String?
    /// A PICTURE fill's `binDataId`. This is how a Korean document draws a rounded annotation box:
    /// the TABLE's fill is an image and every cell declares no rules at all, so a reader that knows
    /// only `bg` renders the box as blank paper (measured on the 편람's 전자문서 box).
    var bgImage: Int?
    /// A GRADIENT fill's stops and angle. Painted as a linear gradient; a single stop degrades to a
    /// plain fill, which is what it is.
    var bgGradient: HwpGradient?
}

private struct HwpGradient: Decodable {
    var colors: [String]
    var angle: Int?
}

/// One edge of an `HwpBorderFill`. `type == "none"` is the document SUPPRESSING that edge (and then
/// carries no width/colour); any other type is a real rule. The reader keeps only "is it drawn, and
/// at what width/colour" — `BorderSide` has no dash vocabulary — but the type is decoded as sent so
/// a later dash model has the fact rather than having to rebuild the parser for it.
private struct HwpBorderEdge: Decodable {
    var type: String
    var widthPt: Double?
    var color: String?
}

private struct HwpTable: Decodable {
    var cols: Int?
    var colWidths: [Int]
    var borderFillId: Int?
    var rows: [[HwpCell]]
    /// How many rows at the TOP the document repeats when the table crosses a page — the author's
    /// own mark, not a guess that row one is a header. Absent for a parser predating the export.
    var headerRows: Int?
}

private struct HwpCell: Decodable {
    var colSpan: Int
    var rowSpan: Int
    var vAlign: String?
    var borderFillId: Int?
    /// The cell's resolved inner margin in POINTS, per edge (rhwp `Cell::effective_padding` ÷100).
    /// Absent against a parser built before this existed — which is exactly the state that made every
    /// HWP table fall to the reader's own invented default, so a rebuild that loses these fields
    /// silently inflates every table again rather than failing.
    var padLeft: Double?
    var padRight: Double?
    var padTop: Double?
    var padBottom: Double?
    var blocks: [HwpBlock]
}

/// A drawing object, flattened to paths by rhwp (`{"t":"shape",…}`). See `HwpShapeRenderer` for why
/// this is drawn at read time instead of becoming a new kind of block.
private struct HwpShape: Decodable {
    var w: Int
    var h: Int
    var align: String?
    /// TRUE when the document places the object AS A CHARACTER — in the text flow, where drawing it
    /// inline moves nothing. FALSE = anchored by coordinates, over or beside the text.
    var asChar: Bool?
    /// What an anchored object's position is measured against (`paper`/`page`/`para`) and the two
    /// offsets in HWPUNIT. Only `para` is placeable by this reader: its anchor is a paragraph this
    /// layout knows the position of, while `paper`/`page` presuppose the document's own pagination.
    var vertRelTo: String?
    var horzRelTo: String?
    var offsetX: Int?
    var offsetY: Int?
    /// WHICH EDGE of that reference the offset is measured from — the other half of rhwp's own
    /// placement (`shape_layout.rs`'s `calc_shape_bottom_y`). Without it an offset is not a position.
    var vertAlign: String?
    var horzAlign: String?
    var paths: [HwpShapePath]
}

private struct HwpShapePath: Decodable {
    /// Path commands as rhwp writes them: `["M",x,y]`, `["L",x,y]`, `["C",…6 numbers]`, `["Z"]`,
    /// in HWPUNIT relative to the object's own box. Decoded as a heterogeneous array because that
    /// is the shape SVG itself uses, and a per-command object would triple the JSON for 79 shapes.
    var d: [[HwpPathToken]]
    var stroke: HwpShapeStroke?
    var fill: String?
    var arrowStart: Bool?
    var arrowEnd: Bool?
}

/// One element of a path command — the leading operator string or one of its numbers.
private enum HwpPathToken: Decodable {
    case op(String)
    case number(Double)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .op(s); return }
        self = .number(try c.decode(Double.self))
    }

    var value: Double? { if case .number(let v) = self { return v } else { return nil } }
    var name: String? { if case .op(let s) = self { return s } else { return nil } }
}

private struct HwpShapeStroke: Decodable {
    var color: String?
    var widthPt: Double?
    var type: String?
}

private struct HwpImage: Decodable {
    var binDataId: Int
    var w: Int
    var h: Int
    var mime: String?
    /// The object's OWN horizontal alignment, which in HWP lives on the picture rather than on a
    /// containing paragraph (`left`/`center`/`right`/`inside`/`outside`).
    var align: String?
    /// The anchor, exactly as a drawing carries it — a picture is anchored as often as a drawing is
    /// (a cover's artwork, a seal over a signature line). Absent for a parser predating the export,
    /// and then every picture reads as in-flow, which is how this reader always treated them.
    var asChar: Bool?
    var vertRelTo: String?
    var horzRelTo: String?
    var vertAlign: String?
    var horzAlign: String?
    var offsetX: Int?
    var offsetY: Int?
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
