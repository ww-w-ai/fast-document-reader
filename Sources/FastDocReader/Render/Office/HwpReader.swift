import Foundation
import AppKit
import CRhwpNative

// ────────────────────────────────────────────────────────────────────────────────────────────
// THE APP DOES NOT RUN THIS FILE. Reading HWP/HWPX is the RUST ENGINE's job — `MarkdownDocument`
// opens one through `RustOfficeDocumentHandle`, and `--extract`/`--pdf`/Quick Look go the same
// way. Nothing in `Sources/` calls `HwpReader.read` (grep it); every caller is a test or a probe.
//
// So EDITING THIS FILE CHANGES NOTHING A READER SEES. It is the port's reference half: the
// Swift original the Rust twin is checked against, and the oracle the probes measure with.
// A behaviour change belongs in BOTH — `rust/crates/fastdoc-engine/src/render/office/hwp_reader/` first, because that is the one
// that runs, and here second so the two keep saying the same thing.
//
// Measured the hard way: a width-scale (장평) fix was written here, built, and measured to have
// changed the screen by exactly zero — because the screen had never been reading this file.
// ────────────────────────────────────────────────────────────────────────────────────────────

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
        // port-exclude: the engine deliberately does not have this shape. P2c replaced the
        // read-time bulk fetch with a retained parse and an on-demand one (`picture_for_id`),
        // which stops fetching 50.8 MB of the 편람's 53.9 MB of picture bytes nothing draws.
        // Embedded pictures are fetched here (they need the live handle); drawings were already
        // rendered inside `mapJSON` and must survive that — hence a merge rather than an assignment.
        //
        // FOUR walks, not one. A running header's, a footer's and a footnote's blocks are NOT inside
        // `result.blocks` — they are lifted into their own top-level arrays so a band can be drawn
        // once per page rather than once per paragraph — so a walk over `result.blocks` alone never
        // fetches a picture that lives only in one of those. Measured on 648 real HWP documents:
        // 48 of them carry a `hwpimg:` id in a band that this fetch never asked the handle for, and
        // the reader then draws that band with the picture missing. The engine's own port had the
        // identical gap (`hwp_reader/mapping.rs`), found first and fixed in the same commit.
        for blocks in [result.blocks] + result.headers.map(\.blocks) + result.footers.map(\.blocks)
            + result.footnotes.map(\.blocks) {
            result.images.merge(collectImages(handle: handle, blocks: blocks)) { _, new in new }
        }
        // port-exclude-end
        // `.resolvingFontSubstitution()` is applied HERE, at HWP's own single dispatch point
        // (invariant 44 — HWP bypasses `DocumentTypes.readOffice` entirely, so it needs its own
        // call rather than `readOffice`'s), NOT inside `mapJSON`: `mapJSON` stays a pure JSON->
        // result mapper so every hand-built-envelope test that calls it directly is unaffected by
        // this pass. See `FontSubstitutionResolver`'s file doc for why read time is the right home.
        return result.resolvingFontSubstitution()
    }

    // port-exclude: the walk the line above replaced. The engine keeps the parse open instead
    // of decoding every picture while it is still alive, so there is no counterpart to port.
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
                guard out[id] == nil, id.hasPrefix(hwpImagePrefix) else { return }
                // The id may carry the crop this occurrence applies (`hwpimg:5!crop=x,y,w,h`), so
                // the same original shown twice at different crops keeps two entries.
                let body = id.dropFirst(hwpImagePrefix.count)
                let parts = body.components(separatedBy: hwpCropSeparator)
                guard let binDataId = UInt16(parts[0]),
                      let b64 = imageBase64(handle, binDataId: binDataId),
                      let data = Data(base64Encoded: b64) else { return }
                if parts.count > 1, let box = cropBox(parts[1]),
                   let cropped = croppedImageData(data, fraction: box) {
                    out[id] = cropped
                } else {
                    out[id] = data
                }
            case .table(let rows, _, _, _):
                for row in rows { for cell in row { for b in cell.blocks { walk(b) } } }
            default:
                break
            }
        }
        blocks.forEach(walk)
        return out
    }
    // port-exclude-end

    /// The id prefix `mapBlock` stamps on an embedded HWP image — kept in ONE place so the writer
    /// (`mapBlock`) and the reader (`collectImages`, and `reconcileMedia`'s map lookup) can never
    /// drift on the string.
    static let hwpImagePrefix = "hwpimg:"
    /// Separates a picture's binData id from the crop applied to it. A cropped picture gets its own
    /// key so the SAME original shown twice, cropped differently, cannot collide — which is the
    /// whole reason the crop lives in the id rather than beside it.
    static let hwpCropSeparator = "!crop="

    /// The id suffix for a picture that actually crops, empty for one that does not.
    ///
    /// A crop rectangle covering the whole original is NOT a crop — most documents write one
    /// (the 편람 declares 101 and cuts nothing with 28 of them). Reading those as crops would
    /// re-encode every picture in the corpus for no visible change.
    private static func cropSuffix(_ im: HwpImage) -> String {
        guard let box = realCrop(im) else { return "" }
        return "\(hwpCropSeparator)\(box.minX),\(box.minY),\(box.width),\(box.height)"
    }

    /// The crop as FRACTIONS of the original (0…1), or nil when the picture is not cropped. Kept as
    /// fractions because the reader never learns the original's pixel dimensions until the bytes are
    /// decoded, and HWPUNIT-to-pixel needs both.
    static func realCrop(left: Int, top: Int, right: Int, bottom: Int,
                         originalWidth: Int, originalHeight: Int) -> CGRect? {
        guard originalWidth > 0, originalHeight > 0,
              right > left, bottom > top,
              left > 0 || top > 0 || right < originalWidth || bottom < originalHeight
        else { return nil }
        let w = CGFloat(originalWidth), h = CGFloat(originalHeight)
        return CGRect(x: CGFloat(left) / w, y: CGFloat(top) / h,
                      width: CGFloat(right - left) / w, height: CGFloat(bottom - top) / h)
    }

    /// `x,y,w,h` as fractions, back from an image id. Malformed = no crop, so a future id shape
    /// cannot make this reader cut a picture by accident.
    private static func cropBox(_ text: String) -> CGRect? {
        let n = text.components(separatedBy: ",").compactMap(Double.init)
        guard n.count == 4, n[2] > 0, n[3] > 0 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    /// The picture's bytes, cut down to the fraction of itself the document shows.
    ///
    /// Re-encoded as PNG rather than clipped at draw time because everything downstream — the
    /// reserved size (invariant 1), the media cache, `--extract`, the Quick Look preview — takes a
    /// picture as BYTES. Cutting here means every one of them sees the same picture the reader
    /// draws, with no second crop model to keep in step.
    static func croppedImageData(_ data: Data, fraction: CGRect) -> Data? {
        guard let source = NSBitmapImageRep(data: data) else { return nil }
        let w = CGFloat(source.pixelsWide), h = CGFloat(source.pixelsHigh)
        let rect = NSRect(x: (fraction.minX * w).rounded(.down), y: (fraction.minY * h).rounded(.down),
                          width: max(1, (fraction.width * w).rounded()),
                          height: max(1, (fraction.height * h).rounded()))
        guard w > 0, h > 0, rect.maxX <= w, rect.maxY <= h,
              let cgImage = source.cgImage,
              let cut = cgImage.cropping(to: rect) else { return nil }
        return NSBitmapImageRep(cgImage: cut).representation(using: .png, properties: [:])
    }

    private static func realCrop(_ im: HwpImage) -> CGRect? {
        guard let c = im.crop, let ow = im.originalWidth, let oh = im.originalHeight else { return nil }
        return realCrop(left: c.left, top: c.top, right: c.right, bottom: c.bottom,
                        originalWidth: ow, originalHeight: oh)
    }

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
        let decorRows = envelope.charShapeDecor ?? []
        let slotFonts = (envelope.charShapes ?? []).enumerated().map { index, row in
            HwpSlotFonts(row: row, decor: index < decorRows.count ? decorRows[index] : nil)
        }
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
        // What the DOCUMENT's own font table says about each family it names, handed to the format-
        // neutral substitution pass. It is read only when a declared family cannot be resolved on
        // this machine — 99.5% of font slots across 1,589 real documents (invariant 95) — so on a
        // machine that has the fonts this costs a dictionary nobody looks at.
        //
        // The table is per SECTION in the export (`[[HwpFontFace]]`, one row per font-table slot per
        // section) but a family NAME is the key the resolver has, so the rows are flattened. A later
        // section re-declaring the same name keeps the FIRST entry rather than overwriting it: the
        // rows agree in every real document seen, and taking the first makes which section a span
        // came from irrelevant to what it is drawn in.
        result.declaredFaces = (envelope.fontFaces ?? []).flatMap { $0 }
            .reduce(into: [String: DeclaredFace]()) { table, face in
                guard !face.name.isEmpty, table[face.name] == nil else { return }
                table[face.name] = DeclaredFace(
                    nominatedSubstitute: face.altName?.isEmpty == false ? face.altName : nil,
                    isEmbedded: face.embedded ?? false,
                    typeInfo: face.panose.map { $0.map { UInt8(clamping: $0) } })
            }
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
        // The author's own PageHide('쪽 감추기') — a span-level marker rather than a paragraph
        // field, because HWP lets it start mid-paragraph. Only `hidePageNum == true` matters here
        // (see `OfficeReadResult.hidePageNumberBlocks`); `false` and absent are the same "this
        // paragraph said nothing" case, so both are excluded the same way.
        result.hidePageNumberBlocks = envelope.blocks.enumerated().compactMap { index, block in
            guard case .para(let p) = block else { return nil }
            return p.spans.contains(where: { $0.pageHide?.hidePageNum == true }) ? index : nil
        }
        // The author's own NewNumber('쪽 번호 새로 시작') — same span-level shape as PageHide, and
        // read the same way. Only `numberType == "page"` is taken: a picture or table counter
        // restart has no consumer here, because this reader never numbers a caption itself.
        result.pageNumberRestartBlocks = envelope.blocks.enumerated().compactMap { index, block in
            guard case .para(let p) = block else { return nil }
            for span in p.spans {
                if let restart = span.newNumber, restart.numberType == "page", let n = restart.number {
                    return OfficePageNumberRestart(block: index, number: n)
                }
            }
            return nil
        }
        result.sections = (envelope.sections ?? []).map { section in
            OfficeSectionDeclaration(
                footnoteSeparator: section.footnoteShape.map { shape in
                    // Every length is the document's own HWPUNIT, through the SAME `points`
                    // conversion every other authored length in this reader goes through — a
                    // separator measured differently from the margins around it would drift.
                    OfficeFootnoteSeparator(
                        lineType: shape.separatorLineType ?? 0,
                        lineWidthPt: shape.separatorLineWidth.flatMap {
                            $0 > 0 ? diagonalWidthPt($0) : nil } ?? 0,
                        color: shape.separatorColor.flatMap { color($0) },
                        lengthPt: shape.separatorLengthHwpUnit.map { points($0) },
                        marginTopPt: points(shape.separatorMarginTopHwpUnit ?? 0),
                        marginBottomPt: points(shape.separatorMarginBottomHwpUnit ?? 0),
                        noteSpacingPt: points(shape.noteSpacingHwpUnit ?? 0))
                },
                pageBorder: section.pageBorder.map {
                    OfficePageBorder(
                        borders: edgeBorders(forFillId: $0.borderFillId, in: borderFills),
                        background: borderFill(forId: $0.borderFillId, in: borderFills)
                            .flatMap { fill in color(fill.bg) },
                        spacing: NSEdgeInsets(top: points($0.spacingTopHwpUnit ?? 0),
                                              left: points($0.spacingLeftHwpUnit ?? 0),
                                              bottom: points($0.spacingBottomHwpUnit ?? 0),
                                              right: points($0.spacingRightHwpUnit ?? 0)),
                        measuredFromPaper: $0.basis != "body")
                },
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
        // The 원고지 line grid the document is written on. HWP states it per SECTION and this reader
        // lays a document out in ONE container, so there is exactly one grid to honour — and the only
        // honest answer is the one every section agrees on. A document where sections disagree, or
        // where some are on a grid and others are not, cannot be expressed at one pitch, and saying
        // nothing is what tells a caller "we could not" apart from "the document never said"
        // (invariant 83's own rule). Until now HWP set this NOWHERE: the pitch reached the section
        // vocabulary and stopped, while the builder that consumes it (`OfficeTextBuilder`, a FLOOR on
        // line height) was fed by docx alone.
        let declaredGrids = result.sections.map(\.lineGridPitch)
        if let first = declaredGrids.first, first != nil, declaredGrids.allSatisfy({ $0 == first }) {
            result.lineGridPitch = first
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
        // Invariant 58's open half — "ODT and HWP state neither distance yet". HWP does state both,
        // and the machinery to use them already exists on both sides: `DocxReader` writes these two
        // fields and `PageBandPainter.headerTop`/`.footerTop` read them to place the running head
        // INSIDE the band. The band's own height is unaffected — `PageBandGeometry.measure`, which
        // feeds the page pitch and therefore the page COUNT, never reads either distance, and the
        // painter clamps both into the gap it already reserved.
        //
        // Read from the section the envelope's own `pageMargin*` came from: `body_section_index` and
        // `page_geometry_pt` select by the identical key (most paragraphs, earliest on a tie), so a
        // distance taken here cannot describe a different sheet than the margins beside it.
        let geometrySection = envelope.bodySection
            .flatMap { index in (envelope.sections ?? []).indices.contains(index) ? envelope.sections?[index] : nil }
            ?? envelope.sections?.first
        if let page = geometrySection?.page {
            // A distance at or past the body's own start would put the running head inside the body
            // text, which no document means — the same rejection `DocxReader` makes for `w:header`.
            if let h = page.marginHeader, h > 0, h < page.marginTop { result.pageHeaderDistance = h }
            if let f = page.marginFooter, f > 0, f < page.marginBottom { result.pageFooterDistance = f }
        }
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
        result.footnotes = (envelope.footnotes ?? []).map {
            mapFootnote($0, pageWidth: pageWidth, defaultBodySize: defaultBodySize,
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
    // port-exclude: An alias, not a declaration: `PaperGeometry` itself lives in `OfficeBlock.swift`
    // port-exclude: and the engine's counterpart is claimed there. A port of an alias would be a
    // port-exclude: second name for the same type.
    typealias PaperGeometry = FastDocReader.PaperGeometry
    // port-exclude-end

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

    /// Every section's footnotes are kept, unfiltered — unlike a running head, which belongs to one
    /// section (invariant 77). A footnote is drawn on the page that CITES it, and that page is found
    /// from its marker rather than from any section rule, so filtering by section here could only
    /// throw away a note whose marker is still in the text.
    private static func mapFootnote(
        _ entry: HwpFootnoteEntry, pageWidth: CGFloat?, defaultBodySize: CGFloat,
        slotFonts: [HwpSlotFonts], borderFills: [HwpBorderFill], shapes: MediaContext, paged: Bool
    ) -> OfficeFootnote {
        OfficeFootnote(
            number: entry.number,
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
        switch raw {
        case "even": return .evenPages
        case "odd": return .oddPages
        default: return .defaultPages
        }
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

        /// The document's own font table, one list per language slot — what it NAMED, before
        /// rhwp's substitution table rewrote it, and what it nominates instead when that name is
        /// not installed. `[]` for a parser predating the export.
        var fontFaces: [[HwpFontFace]] = []

        /// One row per char shape, same row number as `charShapes` — the decoration table.
        /// `[]` for a parser predating the export.
        var charShapeDecor: [HwpCharDecor] = []

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
                              spans: samples, fontFaces: envelope.fontFaces ?? [],
                              charShapeDecor: envelope.charShapeDecor ?? [])
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

    /// A raw HWPUNIT EXTENT that is `nil`/absent when unspecified (unlike `points`, whose callers
    /// already hold a non-optional `Int`) — `nonZeroPoints` cannot be reused here: `outer_margin_*`
    /// is a plain EXTENT (÷100, confirmed against `hwpunit_to_px` — the rust source's own `outer_margin:
    /// i16 = 283 // ~1mm` is exactly `283 / 100 = 2.83pt = 1mm`), NOT a 2×-stored paragraph metric.
    private static func extentPoints(_ hwpunit: Int?) -> CGFloat? {
        guard let v = hwpunit, v != 0 else { return nil }
        return points(v)
    }

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

    /// The SAME gradient `gradientImage` above rasterizes into a fixed-size preview bitmap, carried
    /// instead as the document's own DECLARATION (stops + angle) — mirrors
    /// `fastdoc-engine`'s `mapping.rs::gradient_declaration`. `nil` on the same "single stop is a
    /// plain fill" rule `gradientImage` already applies, so the two never disagree about whether a
    /// fill counts as a gradient at all — only about what they carry it AS.
    private static func gradientDeclaration(_ gradient: HwpGradient?) -> OfficeGradient? {
        guard let gradient else { return nil }
        let stops = gradient.colors.compactMap { color($0) }
        guard stops.count >= 2 else { return nil }
        return OfficeGradient(stops: stops, angleDegrees: gradient.angle.map { CGFloat($0) })
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
    /// HWP's own column declaration in this reader's vocabulary. Every length arrives in points
    /// already (rhwp divides by 100), EXCEPT the per-column widths when the document states shares
    /// — `proportional` says which, and `ColumnGeometry` is what resolves them against a real page.
    private static func columnLayout(_ cd: HwpColumnDef) -> OfficeColumnLayout {
        // The rule's thickness reuses HWP's sixteen-step line-width table, the same one a cell
        // diagonal and a footnote separator are measured with — one table, three consumers.
        let rule = (cd.separatorType ?? 0) != 0
            ? diagonalWidthPt(cd.separatorWidth ?? 0)
            : 0
        return OfficeColumnLayout(
            count: max(1, cd.columnCount),
            spacing: CGFloat(cd.columnSpacingPt ?? 0),
            widths: (cd.columnWidths ?? []).map { CGFloat($0) },
            gaps: (cd.columnGaps ?? []).map { CGFloat($0) },
            proportional: cd.proportionalWidths ?? false,
            separatorType: cd.separatorType ?? 0,
            separatorWidthPt: rule,
            separatorColor: rule > 0 ? color(cd.separatorColor) : nil)
    }

    private static func mapSpan(_ s: HwpSpan, slotFonts: [HwpSlotFonts]) -> [Span] {
        let (ul, ulStyle) = underline(s.underline)
        var span = Span(text: s.text)
        span.bold = s.bold ?? false
        span.italic = s.italic ?? false
        span.underline = ul
        span.underlineStyle = ulStyle
        span.strikethrough = s.strike ?? false
        span.superscript = s.superscript ?? false
        // ONLY a footnote's marker is carried. An endnote's marker is left bare: its note is still
        // in the block flow where it belongs, so nothing has to find it.
        // SUPERSCRIPT is what makes it a marker. A note's own BODY carries the same `noteRef` on
        // its leading number run — that run is the note introducing itself (`1) `, already spelled
        // out by the exporter), not a citation of it. Treating both as markers printed the
        // decoration twice (`1) )`) and made the extraction emit a reference where the note's text
        // should be (`[^1]: [^1] …`).
        if s.noteRefKind == "footnote", s.superscript == true, let ref = s.noteRef {
            span.footnoteRef = Int(ref)
            // The marker's glyphs are ASSEMBLED here rather than carried as three more fields on
            // `Span`: what is printed around a number is a per-format convention (HWP states it on
            // the note's own control; a docx puts it in the numbering definition), while `Span` is
            // the format-neutral vocabulary. Measured on the 637-sample corpus: 791 of 811 shape
            // declarations print a closing `)` and NONE prints anything before the number, so a
            // reader that draws the bare digit is wrong on 97% of the documents that have notes.
            span.text = (s.noteBeforeChar ?? "") + span.text + (s.noteAfterChar ?? "")
        }
        if let cd = s.columnDef { span.columnLayout = columnLayout(cd) }
        if let f = s.form {
            let control = OfficeFormControl(kind: .init(exported: f.formType),
                                            caption: f.caption ?? "",
                                            text: f.text ?? "",
                                            value: f.value ?? 0,
                                            enabled: f.enabled ?? true)
            span.formControl = control
            // The control's own glyphs ARE its text. A form control arrives on a zero-width anchor
            // span (like a bookmark or a note marker), so without this the run has nothing to draw
            // and the document renders blank — which is exactly what a corpus form sample did.
            if span.text.isEmpty { span.text = control.displayText }
        }
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
        applyDecor(fonts.decor, to: &span)
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

    /// The char shape's decorations that this reader draws — and only those. The rest of the
    /// sixteen are decoded and left alone; `HwpCharDecorProbeTests` measured all of them over 1,589
    /// real documents and invariant 97 carries the table that decided which is which.
    ///
    /// The per-script values are applied ONLY when the document's seven slots agree. A span carries
    /// one letter spacing and one width scale, so honouring a shape whose Hangul and Latin ask for
    /// different values would mean applying one script's answer to the other — measured, the slots
    /// agree on 95.9% of the char shapes that state a spacing at all and 93.3% of those that state a
    /// width scale; the rest keep the font's own.
    private static func applyDecor(_ d: HwpCharDecor?, to span: inout Span) {
        guard let d else { return }
        if let v = uniformValue(d.spacings), v != 0 { span.letterSpacingPercent = CGFloat(v) }
        // 장평. `100` is the identity and means the same thing as saying nothing, so it is dropped
        // here rather than travelling as a scale of 1 that every downstream site has to test for.
        if let v = uniformValue(d.ratios), v != 100, v > 0 { span.widthScalePercent = CGFloat(v) }
        if let v = uniformValue(d.charOffsets), v != 0 { span.baselineOffsetPercent = CGFloat(v) }
        if let c = d.underlineColor { span.underlineColor = color(c) }
        if let c = d.strikeColor { span.strikethroughColor = color(c) }
        // 음영 is a background painted behind the glyphs — the same thing `highlightColor` already
        // carries for docx's highlighter, so it reuses that rather than growing a second attribute
        // that would paint the same pixels.
        if let c = d.shadeColor, span.highlightColor == nil { span.highlightColor = color(c) }
    }

    /// The one value all seven language slots agree on, or `nil` when they do not — see
    /// `applyDecor`. An empty or short array is also `nil`: a partial answer is not an answer.
    static func uniformValue(_ slots: [Int]?) -> Int? {
        guard let slots, slots.count == 7, let first = slots.first,
              slots.allSatisfy({ $0 == first }) else { return nil }
        return first
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
                        f.lineHeight = .atLeast(
                            (maxRunSize(p.spans) ?? p.baseSizePt ?? defaultBodySize) * percent / 100)
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
        // Zero is a REAL value in both codes (break between words), so the export sends it rather
        // than omitting it the way it omits every other default — see `document_json.rs`. An absent
        // key therefore means a parser predating that export, and the reader leaves its own line
        // breaking alone rather than reading silence as a setting.
        f.eastAsianLineBreak = p.koreanBreakUnit.flatMap(hangulBreak)
        f.latinLineBreak = p.englishBreakUnit.flatMap(latinBreak)
        f.autoSpaceEastAsianLatin = p.autoSpaceKrEn
        f.autoSpaceEastAsianNumber = p.autoSpaceKrNum
        f.lineHeightFromFontMetrics = p.fontLineHeight
        return f
    }

    /// HWP's two line-break codes, in this reader's vocabulary. The export omits a zero, so a
    /// paragraph that never states one decodes to `nil` and the reader's own default stands — which
    /// is why "unstated" and "stated as 0" are deliberately NOT collapsed here.
    static func hangulBreak(_ code: Int) -> LineBreakGranularity? {
        switch code {
        case 0: return .word
        case 1: return .character
        default: return nil
        }
    }

    /// HWP's three page-break answers for a table, in this reader's vocabulary. An unknown string
    /// is not guessed at — a parser that grows a fourth answer should read as "said nothing" rather
    /// than as whichever case happened to be the default here.
    static func tablePageBreakPolicy(_ raw: String) -> TablePageBreakPolicy? {
        switch raw {
        case "none": return .never
        case "row": return .atRowBoundary
        case "cell": return .anywhere
        default: return nil
        }
    }

    static func latinBreak(_ code: Int) -> LineBreakGranularity? {
        switch code {
        case 0: return .word
        case 1: return .hyphen
        case 2: return .character
        default: return nil
        }
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
                return TabStop(position: position, alignment: alignment,
                               leader: tabLeader(stop.fillType))
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
                var format = format
                // The document's own gap between a marker and its text. `ordered` picks which of the
                // two the level actually has — a numbered head and a bullet are the same fact in two
                // records, and a level is one or the other.
                if let raw = list.ordered ? list.numberingHeadTextDistance : list.bulletTextDistance,
                   raw > 0 {
                    format.listTextDistance = points(raw)
                }
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
            let tableRealImage = shapes.fillImage(tableFill?.bgImage)
            format.backgroundImage = tableRealImage ?? gradientImage(tableFill?.bgGradient)
            // The DECLARATION half of the same fact — see `Cell.backgroundGradient`'s own doc.
            // `nil` whenever a real picture won above, mirroring the same `real_image.is_none()`
            // priority `mapping.rs` resolves at read time, so the two are never both "the answer".
            format.backgroundGradient = tableRealImage == nil ? gradientDeclaration(tableFill?.bgGradient) : nil
            // A single-stop gradient is a plain fill, and one that could not be drawn still reads
            // closer to the document as its first colour than as blank paper.
            if format.defaultShading == nil, format.backgroundImage == nil,
               let stops = tableFill?.bgGradient?.colors, !stops.isEmpty {
                format.defaultShading = color(stops[0])
            }
            // The AUTHOR's own repeating header rows. Inventing "row one is a header" was the
            // alternative and it bolds ordinary text; taking the document's mark costs nothing and
            // is the only way a table that crosses a page keeps its column labels on page two.
            format.repeatHeaderRows = t.repeatHeader
            format.pageBreakPolicy = t.pageBreak.flatMap(tablePageBreakPolicy)
            // The table OBJECT's own outer margin — the gap to what surrounds it, not a cell's
            // padding. Left `nil` (the whole `EdgePadding`, not just its fields) when the source
            // declared none of the four, so a table with no outer margin at all costs nothing.
            let outerMargin = EdgePadding(top: extentPoints(t.outerMarginTop),
                                          left: extentPoints(t.outerMarginLeft),
                                          bottom: extentPoints(t.outerMarginBottom),
                                          right: extentPoints(t.outerMarginRight))
            if outerMargin.top != nil || outerMargin.left != nil || outerMargin.bottom != nil
                || outerMargin.right != nil {
                format.outerMargin = outerMargin
            }
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
            if im.asChar != true, im.wrapsText != true, let paper = shapes.paper,
               let bytes = shapes.picture?(im.binDataId),
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
            // PINNED TO ITS PARAGRAPH — a 도장 over a signature line, which is what a scanned seal in
            // a Korean contract IS. The drawing branch below has had this since invariant 81; the
            // picture branch never did, so a seal fell into the flow at its paragraph's own left
            // edge and BOTH its offsets were discarded. Measured on a real contract: the seal
            // declares 어울림 없음 at column + 285.9pt, 155.3pt below its line, and was drawn at the
            // body's own margin instead — 264pt to the left of where the document puts it, on a page
            // where the signature block it belongs to is the whole point.
            if im.asChar != true, im.wrapsText != true, let paper = shapes.paper,
               let bytes = shapes.picture?(im.binDataId),
               let image = NSImage(data: bytes),
               let placement = paragraphAnchoredPlacement(
                    size: size, vertRelTo: im.vertRelTo ?? "para", horzRelTo: im.horzRelTo ?? "para",
                    vertAlign: im.vertAlign ?? "top", horzAlign: im.horzAlign ?? "left",
                    offset: CGPoint(x: points(im.offsetX ?? 0), y: points(im.offsetY ?? 0)),
                    page: paper) {
                shapes.lastAnchoredFrame = placement.frame
                shapes.anchored.append(OfficeAnchoredObject(
                    blockIndex: shapes.blockIndex,
                    object: OfficeMasterObject(frame: placement.frame, content: .image(image)),
                    paragraphAnchor: placement.anchor))
                return .paragraph(spans: [])
            }
            return .image(id: "\(hwpImagePrefix)\(im.binDataId)\(cropSuffix(im))", size: size,
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
            if sh.asChar != true, sh.wrapsText != true, let paper = shapes.paper,
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
            if sh.asChar != true, sh.wrapsText != true, let paper = shapes.paper,
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
        let realImage = shapes.fillImage(fill?.bgImage)
        let fillImage = realImage ?? gradientImage(fill?.bgGradient)
        // The DECLARATION half of the same fact — see `Cell.backgroundGradient`'s own doc. `nil`
        // whenever a real picture won above, mirroring `mapping.rs`'s `real_image.is_none()`
        // priority at read time.
        let fillGradient = realImage == nil ? gradientDeclaration(fill?.bgGradient) : nil
        if shading == nil, fillImage == nil,
           let stops = fill?.bgGradient?.colors, !stops.isEmpty { shading = color(stops[0]) }
        return Cell(blocks: blocks, rowSpan: c.rowSpan, colSpan: c.colSpan,
                    backgroundColor: shading,
                    backgroundImage: fillImage,
                    backgroundGradient: fillGradient,
                    edgeBorders: edgeBorders(forFillId: c.borderFillId, in: borderFills),
                    verticalAlignment: vAlign, edgePadding: edges,
                    diagonal: cellDiagonal(fill))
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

    /// A fill's DIAGONAL, when the parser resolved one. The direction is taken verbatim — an
    /// unrecognised string is treated as no diagonal rather than guessed into one, so a future
    /// parser value cannot make this reader draw something it does not understand.
    ///
    /// The line is drawn at the same width the four edges would use for that step. HWP stores a
    /// diagonal's width as its 16-step enum rather than resolved points (which is what an edge
    /// gets), so this reuses the edge's own resolved width when the document gave one and falls
    /// back to the 1pt every undeclared rule in this reader uses.
    private static func cellDiagonal(_ fill: HwpBorderFill?) -> CellDiagonal? {
        guard let fill, let raw = fill.cellDiagonal else { return nil }
        let direction: CellDiagonal.Direction
        switch raw {
        case "slash": direction = .slash
        case "backslash": direction = .backslash
        case "both": direction = .both
        default: return nil
        }
        let style = fill.diagonalType.map { lineStyle(hwpLineTypeName($0)) } ?? .solid
        let side = BorderSide(width: diagonalWidthPt(fill.diagonalWidth),
                              color: color(fill.diagonalColor), style: style)
        return CellDiagonal(direction: direction, side: side)
    }

    /// A tab's FILL — what a Korean document rules between a heading and its page number, which is
    /// the dotted line every table of contents is made of. HWP states it in the SAME line-type enum
    /// its cell edges and diagonals use (spec table 25), so this reads that vocabulary rather than
    /// inventing a second one, and collapses it into the four leaders this reader can draw.
    ///
    /// Absent or `0` is the ordinary tab that fills with nothing.
    ///
    /// CARRIED, NOT YET REACHABLE — and measured, so nobody re-derives it. `markTabLeaders` marks
    /// TAB CHARACTERS, and the exporter emits none: across all 637 corpus documents there are
    /// 1,738,893 declared tab stops and 3,555 declared leaders, but **zero** U+0009 characters in
    /// any span's text. The 편람 is the sharpest case — 3,553 stops, 327 of them dotted, and its
    /// contents lines are ruled with U+2007 FIGURE SPACE by the author instead of tabs, so its PDF
    /// is byte-identical with and without this mapping.
    ///
    /// So the tab axis's real first task is not this: it is making a tab ARRIVE as a character at
    /// all (an exporter change), after which this mapping starts working with no further edit.
    /// Until then every HWP tab stop — alignment as much as leader — is inert.
    private static func tabLeader(_ fillType: Int?) -> TabLeader {
        switch fillType ?? 0 {
        case 0: return .none                        // 선 없음
        case 2, 6: return .hyphen                   // 파선 · 긴 파선
        case 3, 4, 5, 7: return .dot                // 점선 · 쇄선 · 원형 파선
        default: return .underscore                 // 실선과 이중선·물결·3D 계열 — 이어진 선
        }
    }

    /// HWP's 16-step border-width enum → points. The same ladder the parser applies to an EDGE's
    /// width before exporting it as `widthPt`; a diagonal's width arrives raw, so the reader climbs
    /// the ladder itself here rather than shipping a diagonal at a width no document declared.
    /// Step 0 is 0.1mm — the finest line HWP can state, and never zero.
    private static func diagonalWidthPt(_ step: Int?) -> CGFloat {
        // 0.1 / 0.12 / 0.15 / 0.2 / 0.25 / 0.3 / 0.4 / 0.5 / 0.6 / 0.7 / 1.0 / 1.5 / 2.0 / 3.0 / 4.0 / 5.0 mm
        let mm: [CGFloat] = [0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5,
                             0.6, 0.7, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0]
        let idx = min(max(step ?? 0, 0), mm.count - 1)
        return mm[idx] * 72.0 / 25.4
    }

    /// HWP's line-type CODE → the name the four edges arrive under, so one mapping table serves
    /// both. The parser exports an edge's type by name and a diagonal's by code; this is the bridge,
    /// and an unknown code stays `"solid"`, which is what an unrecognised edge does too.
    private static func hwpLineTypeName(_ code: Int) -> String {
        switch code {
        case 1: return "solid"
        case 2: return "dash"
        case 3: return "dot"
        case 4: return "dashDot"
        case 5: return "dashDotDot"
        case 6: return "longDash"
        case 7: return "circle"
        case 8: return "double"
        case 9: return "thinThickDouble"
        case 10: return "thickThinDouble"
        case 11: return "thinThickThinTriple"
        case 12: return "wave"
        case 13: return "doubleWave"
        default: return "solid"
        }
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
    /// The document's own font table, one list per language slot in the same order `charShapes`
    /// uses. `charShapes` already carries a resolved NAME, but that name went through rhwp's own
    /// substitution table on the way out, so it cannot say what the DOCUMENT nominated when its
    /// font is absent, nor whether the file carries the bytes. Absent against a parser built
    /// before this export existed.
    let fontFaces: [[HwpFontFace]]?
    /// One row per char shape, read by the SAME row number `charShapes` uses — everything a char
    /// shape does beyond weight, slant, underline presence, colour and size, which the span itself
    /// already carries. Absent against a parser built before this export existed.
    let charShapeDecor: [HwpCharDecor]?
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
    let footnotes: [HwpFootnoteEntry]?
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
/// One footnote, lifted out of the body flow by the exporter so it can be drawn at the foot of the
/// page its marker sits on. Shaped like `HwpHeaderFooterEntry` because it is drawn by the same
/// machinery — see `OfficeFootnote`. ENDNOTES never arrive here: they stay in the block flow, which
/// is already where an endnote belongs.
/// A section's own footnote/endnote shape — `FootnoteShape` in the format, exported per section.
/// Only the SEPARATOR half is read: numbering and placement are decided elsewhere (the corpus
/// declares one value for both across all 1,622 shapes, and `placement` is meaningless for an
/// endnote by the format's own definition).
private struct HwpFootnoteShape: Decodable {
    var separatorLineType: Int?
    var separatorLineWidth: Int?
    var separatorColor: String?
    var separatorLengthHwpUnit: Int?
    var separatorMarginTopHwpUnit: Int?
    var separatorMarginBottomHwpUnit: Int?
    var noteSpacingHwpUnit: Int?
}

private struct HwpFootnoteEntry: Decodable {
    var number: Int
    var section: Int?
    var blocks: [HwpBlock]
}

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

    // port-exclude: Codable machinery -- see `HwpSpan.CodingKeys` below for why serde leaves this
    // port-exclude: with no counterpart to name.
    private enum Keys: String, CodingKey { case t }
    // port-exclude-end

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
    /// The paragraph's OWN base character size in points — present even when it has no runs, which
    /// is the case that mattered: a paragraph with no text still has a char shape, and without it a
    /// percentage line height has no basis and falls back to a document default this document may
    /// never have stated. Measured on the 편람: 793 of its 2,789 paragraphs are empty AND carry no
    /// spans, so 28% of the document was being spaced against a guess.
    var baseSizePt: CGFloat?
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
    /// Where a line may be broken — Hangul: `0` between words, `1` between characters; Latin: `0`
    /// between words, `1` also at a hyphen, `2` between characters. The nominal schema says the
    /// opposite for Hangul; rhwp measured Hancom three separate ways and its own line breaker uses
    /// THIS reading (`composer/line_breaking.rs`, #2185), so it is the one to follow.
    var koreanBreakUnit: Int?
    var englishBreakUnit: Int?
    /// Whether the document widens the seam where Hangul meets Latin letters / digits.
    var autoSpaceKrEn: Bool?
    var autoSpaceKrNum: Bool?
    /// Whether the line height comes from the font's own metrics rather than the character size.
    var fontLineHeight: Bool?
    /// `"page"`/`"section"`/`"multiColumn"`/`"column"`, absent when the paragraph starts nothing.
    var breakBefore: String?
}

/// What a char shape does beyond the handful of things a span already carries. Every field is
/// omitted at its default, so an ordinary document's rows decode to all-nil.
///
/// Colours are present ONLY when the decoration that uses them is on: a colour of `000000` is
/// indistinguishable from "no colour stated", so carrying it unconditionally would shade every
/// document in black.
struct HwpCharDecor: Decodable, Equatable {
    var underlineShape: Int?
    var underlineColor: String?
    var strikeShape: Int?
    var strikeColor: String?
    var shadeColor: String?
    var outlineType: Int?
    var shadowType: Int?
    var shadowColor: String?
    var shadowOffsetX: Int?
    var shadowOffsetY: Int?
    var emboss: Bool?
    var engrave: Bool?
    var emphasisDot: Int?
    var kerning: Bool?
    /// Per language slot, in `charShapes`' own order: width %, letter spacing %, relative size %,
    /// baseline offset %. Absent when every slot is at its default (100 / 0 / 100 / 0).
    var ratios: [Int]?
    var spacings: [Int]?
    var relativeSizes: [Int]?
    var charOffsets: [Int]?
}

/// One entry of the document's font table — the name as the document wrote it (before any
/// substitution), the substitute the DOCUMENT nominates for it, what kind of font file it is
/// (`0` unknown, `1` TTF, `2` HFT — Hancom's own format, installed on no machine but a Hancom one),
/// and whether the file carries the bytes.
struct HwpFontFace: Decodable, Equatable {
    var name: String
    var altName: String?
    var type: Int?
    var embedded: Bool?
    var binDataId: Int?
    /// A second name for this SAME face (not a substitute) — the file's own bytes, always. The
    /// exporter sends this ONLY on the HWP5 binary path; on every other path (HWPX included) the
    /// same Rust field is filled from rhwp's own fixed lookup table rather than the file, so the
    /// exporter omits the key entirely there rather than sending the parser's guess as the
    /// document's word (`document_json.rs`'s `FontFaceDto.default_name`). `nil` here therefore means
    /// either "no such record" or "not on a path this reader can trust" — never "the parser guessed
    /// and we sent it anyway".
    var defaultName: String?
    /// The raw 10-byte PANOSE block (HWP5 FACE_NAME type info), undecoded — byte 0 is family kind,
    /// byte 1 is serif style — the file's own bytes, always. Sent ONLY on the HWP5 binary path, for
    /// the same reason as `defaultName`: on HWPX the same Rust field is filled from values this
    /// reader cannot trust as the document's statement (byte 1 is a name-morpheme guess with no XML
    /// attribute behind it at all; byte 0, though read from a real attribute, is Hancom's own face
    /// category renumbered 1-7, not standard PANOSE `bFamilyType`) — so the exporter omits the whole
    /// block there rather than let either byte be mistaken for what the document said. `nil` means
    /// either no such record, or a path this reader does not trust for this field; ten zeroes is
    /// PANOSE "Any", a real value, not the same as absent.
    var panose: [Int]?
    /// The type (`0` unknown / `1` TTF / `2` HFT) of the SUBSTITUTE face nominated in `altName`,
    /// independent of this font's own `type` above. `nil` when the document nominates no substitute.
    /// HWP5 has no such concept, so this is always `nil` there.
    var substType: Int?
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
    var footnoteShape: HwpFootnoteShape?
    var page: HwpSectionPage?
    var pageBorder: HwpPageBorder?
    var hideHeader: Bool?
    var hideFooter: Bool?
    var hideMasterPage: Bool?
    var pageNumberStart: Int?
    var lineGridHwpUnit: Int?
    var charGridHwpUnit: Int?
    var verticalText: Bool?
}

/// A section's 쪽 테두리/배경 — the frame a Korean document rules around the whole page. The line and
/// colour live in the SAME `borderFills` table a cell's `borderFillId` points at; `basis` says where
/// the spacings are measured FROM, and the two answers differ by a margin (70–110pt on real files).
private struct HwpPageBorder: Decodable {
    var borderFillId: Int
    var spacingLeftHwpUnit: Int?
    var spacingRightHwpUnit: Int?
    var spacingTopHwpUnit: Int?
    var spacingBottomHwpUnit: Int?
    var basis: String?
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
    /// Where the running head STARTS, measured from the paper's own edge — the document's raw
    /// `PageDef` declaration rather than the resolved body area the four `margin*` above carry.
    /// `marginTop` already includes this (body top = marginHeader + the top margin proper), so the
    /// two are not interchangeable: this is the only value that says where inside the band the
    /// header sits. Absent against a parser built before the declaration was exported.
    var marginHeader: CGFloat?
    var marginFooter: CGFloat?
}

private struct HwpTabStop: Decodable {
    var posHwpUnit: Int
    /// What the tab is FILLED with on its way to the stop — HWP's own line-type code, the same one
    /// the four cell edges and a diagonal use. Absent = no fill, which is the ordinary tab.
    var fillType: Int?
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
    /// How far this level's TEXT sits from its own head, in HWPUNIT — the numbered-head form and the
    /// bullet form of the same fact, only one of which a given level has.
    var numberingHeadTextDistance: Int?
    var bulletTextDistance: Int?
}

/// A form control embedded in the text — `FormObject` in the format.
private struct HwpForm: Decodable {
    var formType: String?
    var name: String?
    var caption: String?
    var text: String?
    var value: Int?
    var enabled: Bool?
}

/// What a section's text says about the columns it flows through — `ColumnDef` in the format.
private struct HwpColumnDef: Decodable {
    var columnCount: Int
    var direction: String?
    var sameWidth: Bool?
    var proportionalWidths: Bool?
    var separatorType: Int?
    var separatorWidth: Int?
    var separatorColor: String?
    var columnSpacingPt: Double?
    var columnWidths: [Double]?
    var columnGaps: [Double]?
}

private struct HwpSpan: Decodable {
    var text: String
    var bold: Bool?
    var italic: Bool?
    var underline: String?
    var strike: Bool?
    var superscript: Bool?      // JSON key "super" (a Swift keyword) — remapped below
    /// Which note this run references, and of which kind (`"footnote"`/`"endnote"`). Absent on
    /// every run that is not a note marker — a marker's glyphs are a superscript number and say
    /// nothing on their own.
    var noteRef: Int?
    var noteRefKind: String?
    /// What the note's own control says is printed around its number — `1` vs `1)`. Declared per
    /// INSTANCE, not just per section, so it is read here rather than from the section's shape.
    var noteBeforeChar: String?
    var noteAfterChar: String?
    /// `Control::ColumnDef`('cold') — "from here on, N columns". A zero-width anchor span, the same
    /// shape a bookmark or a note marker arrives as.
    var columnDef: HwpColumnDef?
    /// `Control::Form`('form') — a checkbox/button/field the document embedded.
    var form: HwpForm?
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

    /// `Control::PageHide`('pghd') — a per-paragraph veto that starts at this run's own position,
    /// carrying `hidePageNum` (plus five other switches this reader does not adopt — see
    /// `OfficeReadResult.hidePageNumberBlocks`). A zero-width anchor span, the same shape a
    /// bookmark or footnote-reference marker already arrives as.
    var pageHide: HwpPageHide?

    /// `Control::NewNumber`('nwno') — "start numbering again from here". It can restart a picture,
    /// table, footnote, endnote, equation or PAGE counter; only `page` is honoured, because those
    /// are the only numbers this reader computes rather than replays from the document's own text.
    var newNumber: HwpNewNumber?

    // port-exclude: Codable machinery. The engine does not decode HWP JSON into a mirror of these
    // port-exclude: types -- serde derives the same mapping from the struct itself, so there is no
    // port-exclude: second declaration for this one to be the port of.
    private enum CodingKeys: String, CodingKey {
        case text, bold, italic, underline, strike, color, size, font, link, bookmark, csId
        case pageNumberField, pageHide, newNumber
        // Listed EXPLICITLY, like every other key here. An explicit `CodingKeys` makes the
        // synthesised decoder ignore any property it does not name — silently, with no error and
        // no warning — so a marker tag that the exporter really does send arrived `nil` on every
        // run and the footnote path found nothing to place. Same failure shape as a stale binary
        // (invariant 45): the field is in the model, the value is on the wire, and the reader
    // port-exclude-end
        // never sees it. Anything added above must be added here too.
        case noteRef, noteRefKind, noteBeforeChar, noteAfterChar, columnDef, form
        case superscript = "super"
        case subscripted = "sub"
    }
}

/// `NewNumberDto` — which counter to restart, and at what. `numberType` is the parser's own name
/// (`page`/`picture`/`table`/`footnote`/`endnote`/`equation`).
private struct HwpNewNumber: Decodable {
    var numberType: String?
    var number: Int?
}

/// `PageHideDto` — only `hidePageNum` is read; see `OfficeReadResult.hidePageNumberBlocks` for why
/// the other five (header/footer/master-page/border/fill) are decoded here and then never used.
private struct HwpPageHide: Decodable {
    var hidePageNum: Bool?
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
    /// THE ANSWER, already resolved by the parser: `"slash"` / `"backslash"` / `"both"` when this
    /// fill declares a drawn cell diagonal, absent when it does not.
    ///
    /// HWP splits a diagonal across three places — the line TYPE in `diagonalType`, the DIRECTION in
    /// bits of `attr`, and a separate bit saying the whole thing is a centre line instead. The
    /// reader does not combine them: `BorderFill::cell_diagonal` in the parser does, and the
    /// parser's own table editor calls the same function, so there is one answer rather than two
    /// that can drift. Judging it here instead would rule lines across cells that carry a type but
    /// no direction — two thirds of the raw declarations in the measured corpus.
    var cellDiagonal: String?
    /// The diagonal's own line type, in the SAME 18-value enum the four edges use, so `lineStyle`
    /// maps it without a second table. Only meaningful when `cellDiagonal` is present.
    var diagonalType: Int?
    /// The diagonal's width in HWP's 16-step enum — NOT points, unlike an edge's `widthPt`, because
    /// the parser resolves an edge's width and leaves a diagonal's raw. Absent = the finest step.
    var diagonalWidth: Int?
    var diagonalColor: String?
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
    /// How many rows at the TOP are the table's heading — the author's own mark, not a guess that
    /// row one is a header. Absent for a parser predating the export.
    var headerRows: Int?
    /// Whether the author asked for those heading rows to be REPRINTED on each further page, which
    /// is a separate switch from having a heading at all.
    var repeatHeader: Bool?
    /// `"none"` / `"cell"` / `"row"` — where the document allows this table to be split when it
    /// reaches the foot of a page. Absent for a parser predating the export.
    var pageBreak: String?
    /// The table OBJECT's own outer margin (HWPUNIT), zero-omitted at the wire (`document_json.rs`'s
    /// `skip_serializing_if = "is_zero_i32"`) — so a declared `0` and "never declared" already look
    /// identical here, both decoding to `nil`. Absent for a parser predating the export.
    var outerMarginLeft: Int?
    var outerMarginRight: Int?
    var outerMarginTop: Int?
    var outerMarginBottom: Int?
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
    /// The object holds SPACE in the flow — 어울림/자연스럽게/통과/위아래, where HWP pushes the text
    /// out of the object's way. FALSE (and absent, which is a parser predating the export) means it
    /// is painted over or behind the text (글 앞으로/글 뒤로) and holds no space at all. A reader that
    /// floats BOTH kinds takes away the space the wrapping ones were holding, and every page that
    /// space was making disappears with it — measured across 2,066 documents: 7 lost 1–2 pages each.
    var wrapsText: Bool?
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
    /// The object holds SPACE in the flow — 어울림/자연스럽게/통과/위아래, where HWP pushes the text
    /// out of the object's way. FALSE (and absent, which is a parser predating the export) means it
    /// is painted over or behind the text (글 앞으로/글 뒤로) and holds no space at all. A reader that
    /// floats BOTH kinds takes away the space the wrapping ones were holding, and every page that
    /// space was making disappears with it — measured across 2,066 documents: 7 lost 1–2 pages each.
    var wrapsText: Bool?
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
    /// The rectangle of the ORIGINAL picture this object actually shows, in the original's own
    /// HWPUNIT coordinates. Absent for a parser predating the export → no crop, which is how every
    /// HWP picture was drawn before this.
    var crop: HwpCrop?
    /// The original picture's size, the SAME coordinates `crop` is in. Without it a crop cannot be
    /// read: most documents that do not crop still write a rectangle covering the whole original,
    /// and the two are indistinguishable without this. Measured across 637 documents — 3,159 crops
    /// are declared and 563 of them (138 documents) actually cut something.
    var originalWidth: Int?
    var originalHeight: Int?
}

/// A crop rectangle in the original picture's coordinates. `left`/`top` are inset from the
/// original's own origin; `right`/`bottom` are the far edges, NOT insets — so an uncropped picture
/// writes `(0, 0, originalWidth, originalHeight)`.
private struct HwpCrop: Decodable {
    var left: Int
    var top: Int
    var right: Int
    var bottom: Int
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
