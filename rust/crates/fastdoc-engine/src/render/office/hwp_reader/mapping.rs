//! swift: Render/Office/HwpReader.swift
//! swift-range: 1-11
//!
//! Mapping half of the HWP port — see `hwp_reader/mod.rs` for why this file stops where it does.
//! The schema half (rhwp's Codable model, lines 1767-2465) lives in `hwp_reader::schema` and is
//! referenced here by name only (`HwpEnvelope`, `HwpPara`, `HwpSpan`, `HwpCell`, `HwpImage`,
//! `HwpBorderFill`, `HwpBorderEdge`, `HwpGradient`, `HwpColumnDef`, `HwpCharDecor`,
//! `HwpShapePath`) — those types are not defined in this file.
//!
//! `OfficeBlock`/`Span`/`ParagraphFormat`/etc. come from `office_block.rs`, a sibling port not
//! yet populated at the time this file was written; referenced by their Swift names per
//! docs/plans/rust-port-convention.md §4.

// swift: Render/Office/HwpReader.swift:1-3
use swiftshim::{Data, EngineError, NSRange, SwiftString};
use swiftshim::geometry::{CGFloat, CGSize, CGRect, CGPoint, NSRect};
use crate::render::office::office_block::{
    OfficeReadResult, OfficeBlock, OfficeAnchoredObject, PaperGeometry, Span, UnderlineStyle,
    CellDiagonal, BorderLineStyle, EdgeBorders, BorderDecl, TablePageBreakPolicy, TabLeader,
    ParagraphFormat, LineBreakGranularity, HeaderFooterApplicability,
    OfficeSectionDeclaration,
};
use crate::render::office::column_geometry::OfficeColumnLayout;
use crate::render::office::hwp_font_slots::HwpSlotFonts;
use crate::render::office::hwp_reader::schema::{
    HwpEnvelope, HwpPara, HwpSpan, HwpCell, HwpImage, HwpBorderFill, HwpBorderEdge, HwpGradient,
    HwpColumnDef, HwpCharDecor, HwpShapePath, HwpBlock,
};

// swift: Render/Office/HwpReader.swift:4-11
// Bridge to the rhwp (Rust, MIT — github.com/edwardkim/rhwp, forked: FFI drift fix +
// structured-export FFI added) HWP/HWPX parser, statically linked via the RhwpNative
// xcframework. See docs/BUILD-RHWP.md to rebuild the binary.
//
// S2 scope = the raw parse bridge only (Data -> rhwp's structured document JSON).
// The JSON -> OfficeBlock/OfficeReadResult mapping lands in S3+ so the existing
// OfficeTextBuilder renders HWP the same way it renders Word/ODT.

// swift: Render/Office/HwpReader.swift:12-19
/// swift: enum HwpReader — a namespace, not a value; ported as a bare `impl` block of free
/// functions (Rust has no case-less-enum-as-namespace idiom worth inventing one for here).
pub struct HwpReader;

impl HwpReader {
    /// Parse HWP/HWPX bytes with rhwp and return its structured document JSON
    /// (`{"v":1,"blocks":[...]}`). Returns nil if rhwp cannot parse the bytes.
    ///
    /// Handle lifecycle: rhwp_open (one parse) -> rhwp_document_json -> rhwp_close,
    /// and every returned C string is freed via rhwp_string_free (see the FFI contract
    /// in bindings/Native/src/lib.rs of the fork).
    // swift: Render/Office/HwpReader.swift:19-32
    pub fn export_document_json(data: &Data) -> Option<String> {
        todo!("swift:19-32 rhwp_open/rhwp_document_json/rhwp_close FFI bridge — CRhwpNative has no Rust binding yet")
    }

    /// Base64 of an embedded image's bytes, by 1-based bin_data_id. Empty string when
    /// the id resolves to nothing. Requires a live handle from the same parse — S4 will
    /// use this from within a single open/close around the whole read.
    // swift: Render/Office/HwpReader.swift:33-40
    pub fn image_base64(handle: RhwpHandle, bin_data_id: u16) -> Option<String> {
        todo!("swift:34-40 rhwp_image_base64/rhwp_string_free FFI bridge")
    }

    // swift: Render/Office/HwpReader.swift:43
    // MARK: - S3: structured JSON -> OfficeBlock / OfficeReadResult
}

/// swift: `UnsafeMutableRawPointer` used as the rhwp parse handle — named here so the FFI stand-in
/// functions above have a real parameter type instead of an opaque pointer type nobody else uses.
// swift: Render/Office/HwpReader.swift:36 (parameter type)
pub type RhwpHandle = *mut std::ffi::c_void;

impl HwpReader {
    // swift: Render/Office/HwpReader.swift:45-59
    // swift: `enum MapError: Swift.Error, Equatable, LocalizedError`
    //
    // rhwp's `exportDocumentJSON` returned nil — the bytes are not a parseable HWP/HWPX
    // document (or empty). Named so a caller can tell a parse failure from a decode failure.
    //
    // The JSON rhwp produced (or a synthetic string) could not be decoded into the expected
    // `{"v":1,"blocks":[…]}` shape — malformed JSON, or a block whose `"t"` isn't one this
    // mapper handles.
}

// swift: Render/Office/HwpReader.swift:41-61
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MapError {
    /// rhwp's `exportDocumentJSON` returned nil — the bytes are not a parseable HWP/HWPX
    /// document (or empty). Named so a caller can tell a parse failure from a decode failure.
    ParseFailed,
    /// The JSON rhwp produced (or a synthetic string) could not be decoded into the expected
    /// `{"v":1,"blocks":[…]}` shape — malformed JSON, or a block whose `"t"` isn't one this
    /// mapper handles.
    MalformedJSON,
}

impl MapError {
    // swift: Render/Office/HwpReader.swift:53-59
    pub fn error_description(&self) -> &'static str {
        match self {
            MapError::ParseFailed => "This file could not be parsed as an HWP/HWPX document — it may be corrupt or an unsupported format.",
            MapError::MalformedJSON => "The HWP document's internal structure could not be read.",
        }
    }
}

impl std::fmt::Display for MapError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.error_description())
    }
}
impl std::error::Error for MapError {}

impl HwpReader {
    /// swift: the `data.withUnsafeBytes { … rhwp_open(base, data.count) }` handle-open expression —
    /// an FFI leaf split out of `read()` so the orchestration around it (guard/defer/mapJSON/merge/
    /// resolvingFontSubstitution) stays real logic rather than one function-wide `todo!()`.
    // swift: Render/Office/HwpReader.swift:75-79
    fn rhwp_open(data: &Data) -> Option<RhwpHandle> {
        todo!("swift:75-79 rhwp_open(base, data.count) FFI call — CRhwpNative has no Rust binding yet")
    }

    /// swift: `rhwp_close(handle)`, run via `defer` in the Swift original.
    // swift: Render/Office/HwpReader.swift:80
    fn rhwp_close(handle: RhwpHandle) {
        todo!("swift:80 rhwp_close(handle) FFI call")
    }

    /// swift: `guard let cstr = rhwp_document_json(handle) … let json = String(cString: cstr);
    /// rhwp_string_free(cstr)`.
    // swift: Render/Office/HwpReader.swift:82-84
    fn rhwp_document_json_owned(handle: RhwpHandle) -> Option<String> {
        todo!("swift:82-84 rhwp_document_json/rhwp_string_free FFI call")
    }

    /// The public office entry: HWP/HWPX bytes → the SAME `OfficeReadResult` `DocxReader`/`OdtReader`
    /// return, so `OfficeTextBuilder` renders HWP identically. Two steps kept separate on purpose —
    /// `exportDocumentJSON` (the FFI, untestable without a file) then `mapJSON` (a pure
    /// `String -> OfficeReadResult`, unit-tested with synthetic JSON, no FFI needed).
    // swift: Render/Office/HwpReader.swift:62-102
    pub fn read(data: &Data) -> Result<OfficeReadResult, MapError> {
        if data.0.is_empty() {
            return Err(MapError::ParseFailed);
        }
        // ONE open/close spans BOTH the JSON export AND the image fetch: rhwp's image FFI needs the
        // SAME live parse handle the JSON came from, and there is no archive to fall back on later
        // (HWP is CFB binary, not a zip), so an image not decoded inside this handle's lifetime is
        // gone. `exportDocumentJSON` stays a self-closing pure JSON getter for tests; this path
        // re-opens because it also needs the handle alive for `imageBase64`.
        let Some(handle) = Self::rhwp_open(data) else { return Err(MapError::ParseFailed) }; // parse failure -> null handle
        // `defer { rhwp_close(handle) }` in the Swift original — run via this closure's return path
        // so `rhwp_close` fires on every exit, error included.
        let outcome: Result<OfficeReadResult, MapError> = (|| {
            let Some(json) = Self::rhwp_document_json_owned(handle) else { return Err(MapError::ParseFailed) };
            // The picture provider is what lets a FILL image be decoded during the mapping walk; it is
            // the same FFI `collectImages` uses, handed in rather than reached for, so `mapJSON` stays a
            // pure function of its two arguments and every hand-built-envelope test is unaffected.
            let mut result = Self::map_json(&json, Some(Box::new(move |bin_data_id: i64| {
                let id = u16::try_from(bin_data_id).ok()?;
                let b64 = Self::image_base64(handle, id)?;
                Data::base64Encoded(&b64)
            })))?;
            // Embedded pictures are fetched here (they need the live handle); drawings were already
            // rendered inside `mapJSON` and must survive that — hence a merge rather than an assignment.
            for (k, v) in Self::collect_images(handle, &result.blocks) {
                result.images.insert(SwiftString::from(k), v);
            }
            // `.resolvingFontSubstitution()` is applied HERE, at HWP's own single dispatch point
            // (invariant 44 — HWP bypasses `DocumentTypes.readOffice` entirely, so it needs its own
            // call rather than `readOffice`'s), NOT inside `mapJSON`: `mapJSON` stays a pure JSON->
            // result mapper so every hand-built-envelope test that calls it directly is unaffected by
            // this pass. See `FontSubstitutionResolver`'s file doc for why read time is the right home.
            let font_cache = crate::render::office::font_substitution_resolver::FontSubstitutionCache::default();
            Ok(result.resolving_font_substitution(&font_cache))
        })();
        Self::rhwp_close(handle);
        outcome
    }

    /// Walk the mapped blocks (recursively, INCLUDING table cells) for every `.image(id:)` whose id
    /// is an embedded HWP image (`"hwpimg:<binDataId>"`), fetch its bytes via the live `handle`, and
    /// return them keyed by the SAME id string the block carries — the key `reconcileMedia` looks up.
    /// A linked (external-URL) image has no `hwpimg:` id and no embedded bytes, so it is skipped here
    /// and resolved by the URL path instead, exactly like a linked docx/odt image.
    // swift: Render/Office/HwpReader.swift:103-140
    fn collect_images(handle: RhwpHandle, blocks: &[OfficeBlock]) -> std::collections::HashMap<String, Data> {
        let mut out: std::collections::HashMap<String, Data> = std::collections::HashMap::new();
        fn walk(
            handle: RhwpHandle,
            block: &OfficeBlock,
            out: &mut std::collections::HashMap<String, Data>,
        ) {
            match block {
                OfficeBlock::Image { id, .. } => {
                    let id = id.to_string();
                    if out.contains_key(&id) || !id.starts_with(HwpReader::HWP_IMAGE_PREFIX) {
                        return;
                    }
                    // The id may carry the crop this occurrence applies (`hwpimg:5!crop=x,y,w,h`), so
                    // the same original shown twice at different crops keeps two entries.
                    let body = &id[HwpReader::HWP_IMAGE_PREFIX.len()..];
                    let parts: Vec<&str> = body.split(HwpReader::HWP_CROP_SEPARATOR).collect();
                    let Ok(bin_data_id) = parts[0].parse::<u16>() else { return };
                    let Some(b64) = HwpReader::image_base64(handle, bin_data_id) else { return };
                    let Some(data) = Data::base64Encoded(&b64) else { return };
                    if parts.len() > 1 {
                        if let Some(box_) = HwpReader::crop_box(parts[1]) {
                            if let Some(cropped) = HwpReader::cropped_image_data(&data, box_) {
                                out.insert(id, cropped);
                                return;
                            }
                        }
                    }
                    out.insert(id, data);
                }
                OfficeBlock::Table { rows, .. } => {
                    for row in rows {
                        for cell in row {
                            for b in &cell.blocks {
                                walk(handle, b, out);
                            }
                        }
                    }
                }
                _ => {}
            }
        }
        for block in blocks {
            walk(handle, block, &mut out);
        }
        out
    }

    /// The id prefix `mapBlock` stamps on an embedded HWP image — kept in ONE place so the writer
    /// (`mapBlock`) and the reader (`collectImages`, and `reconcileMedia`'s map lookup) can never
    /// drift on the string.
    // swift: Render/Office/HwpReader.swift:141-144
    pub const HWP_IMAGE_PREFIX: &'static str = "hwpimg:";
    /// Separates a picture's binData id from the crop applied to it. A cropped picture gets its own
    /// key so the SAME original shown twice, cropped differently, cannot collide — which is the
    /// whole reason the crop lives in the id rather than beside it.
    // swift: Render/Office/HwpReader.swift:145-148
    pub const HWP_CROP_SEPARATOR: &'static str = "!crop=";

    /// The id suffix for a picture that actually crops, empty for one that does not.
    ///
    /// A crop rectangle covering the whole original is NOT a crop — most documents write one
    /// (the 편람 declares 101 and cuts nothing with 28 of them). Reading those as crops would
    /// re-encode every picture in the corpus for no visible change.
    // swift: Render/Office/HwpReader.swift:149-155
    fn crop_suffix(im: &HwpImage) -> String {
        let Some(box_) = Self::real_crop_image(im) else { return String::new() };
        format!("{}{},{},{},{}", Self::HWP_CROP_SEPARATOR, box_.minX(), box_.minY(), box_.width(), box_.height())
    }

    /// The crop as FRACTIONS of the original (0…1), or nil when the picture is not cropped. Kept as
    /// fractions because the reader never learns the original's pixel dimensions until the bytes are
    /// decoded, and HWPUNIT-to-pixel needs both.
    // swift: Render/Office/HwpReader.swift:156-168
    pub fn real_crop(
        left: i64, top: i64, right: i64, bottom: i64,
        original_width: i64, original_height: i64,
    ) -> Option<CGRect> {
        if !(original_width > 0
            && original_height > 0
            && right > left
            && bottom > top
            && (left > 0 || top > 0 || right < original_width || bottom < original_height))
        {
            return None;
        }
        let w = original_width as CGFloat;
        let h = original_height as CGFloat;
        Some(CGRect {
            origin: CGPoint { x: left as CGFloat / w, y: top as CGFloat / h },
            size: CGSize {
                width: (right - left) as CGFloat / w,
                height: (bottom - top) as CGFloat / h,
            },
        })
    }

    /// `x,y,w,h` as fractions, back from an image id. Malformed = no crop, so a future id shape
    /// cannot make this reader cut a picture by accident.
    // swift: Render/Office/HwpReader.swift:169-176
    fn crop_box(text: &str) -> Option<CGRect> {
        let n: Vec<f64> = text.split(',').filter_map(|s| s.parse::<f64>().ok()).collect();
        if n.len() != 4 || !(n[2] > 0.0) || !(n[3] > 0.0) {
            return None;
        }
        Some(CGRect {
            origin: CGPoint { x: n[0], y: n[1] },
            size: CGSize { width: n[2], height: n[3] },
        })
    }

    /// The picture's bytes, cut down to the fraction of itself the document shows.
    ///
    /// Re-encoded as PNG rather than clipped at draw time because everything downstream — the
    /// reserved size (invariant 1), the media cache, `--extract`, the Quick Look preview — takes a
    /// picture as BYTES. Cutting here means every one of them sees the same picture the reader
    /// draws, with no second crop model to keep in step.
    // swift: Render/Office/HwpReader.swift:177-196
    pub fn cropped_image_data(data: &Data, fraction: CGRect) -> Option<Data> {
        todo!("swift:185-196 NSBitmapImageRep decode/crop/PNG re-encode — needs an image-codec shim, phase B")
    }

    // swift: Render/Office/HwpReader.swift:197-201
    fn real_crop_image(im: &HwpImage) -> Option<CGRect> {
        let c = im.crop.as_ref()?;
        let ow = im.original_width?;
        let oh = im.original_height?;
        Self::real_crop(c.left, c.top, c.right, c.bottom, ow, oh)
    }

    /// The id prefix for a DRAWING this reader rendered itself (`HwpShapeRenderer`) — distinct from
    /// `hwpImagePrefix` because these bytes are made here, not fetched from the file, so
    /// `collectImages` must not try to look them up by `binDataId`.
    // swift: Render/Office/HwpReader.swift:202-206
    pub const HWP_SHAPE_PREFIX: &'static str = "hwpshape:";
}

/// Where a drawing's rendered PDF goes while the block walk is still running. A reference type
/// so the `map` closures that build blocks can add to it without threading `inout` through five
/// signatures; `mapJSON` hands its contents to the result, which is what makes the shape bytes
/// reachable by `reconcileMedia` under the id the block carries.
// swift: Render/Office/HwpReader.swift:207-249
pub struct MediaContext {
    pub images: std::collections::HashMap<String, Data>,
    /// Objects pinned to the PAPER, collected during the block walk with the index of the block
    /// they were anchored at — see `OfficeAnchoredObject`. A reference type for the same reason
    /// `images` is: the `map` closures that build blocks add to it without threading `inout`.
    pub anchored: Vec<OfficeAnchoredObject>,
    /// The document's own paper, when it declared one — the reference an anchored object is
    /// placed against.
    pub paper: Option<PaperGeometry>,
    /// Where the drawing whose text box is being read sits on the paper. A text box's paragraphs
    /// arrive as the SIBLING blocks right after their own drawing (the exporter's contract, see
    /// `docs/BUILD-RHWP.md` item 7), and they state their geometry in that drawing's frame rather
    /// than the paper's — so the frame this records is the origin those coordinates are measured
    /// from. Nil until the walk has passed an anchored object, which is exactly when a box
    /// coordinate cannot be resolved and is therefore ignored.
    pub last_anchored_frame: Option<CGRect>,
    /// The index of the top-level block being mapped, so an anchored object knows where in the
    /// document it belongs. Set by `mapJSON`'s own loop; nested content (a table cell) keeps the
    /// top-level block's index, which is the page-bearing one.
    pub block_index: usize,
    /// Bytes for an embedded picture by `binDataId`, when the caller has a live parse handle.
    /// `nil` in `mapJSON`-only use (every unit test): a picture FILL then stays unpainted rather
    /// than the mapper inventing a colour for it.
    pub picture: Option<Box<dyn Fn(i64) -> Option<Data>>>,
    next: i64,
}

impl MediaContext {
    pub fn new(picture: Option<Box<dyn Fn(i64) -> Option<Data>>>) -> Self {
        Self {
            images: std::collections::HashMap::new(),
            anchored: Vec::new(),
            paper: None,
            last_anchored_frame: None,
            block_index: 0,
            picture,
            next: 0,
        }
    }

    /// The decoded image for a fill's `binDataId`, or nil when there is no provider or no bytes.
    // swift: Render/Office/HwpReader.swift:241-244
    pub fn fill_image(&self, bin_data_id: Option<i64>) -> Option<swiftshim::NSImage> {
        let bin_data_id = bin_data_id?;
        if bin_data_id <= 0 { return None; }
        let data = (self.picture.as_ref()?)(bin_data_id)?;
        swiftshim::NSImage::fromData(&data)
    }

    // swift: Render/Office/HwpReader.swift:245-249
    pub fn add(&mut self, data: Data) -> String {
        self.next += 1;
        let id = format!("{}{}", HwpReader::HWP_SHAPE_PREFIX, self.next);
        self.images.insert(id.clone(), data);
        id
    }
}

impl HwpReader {
    /// The longest a STYLE-INFERRED heading's text may be. A heading is a label; a paragraph of prose
    /// carrying a heading-ish style name is not one, however the document styled it. Only applies to
    /// inference — an explicitly outlined paragraph is honoured at any length.
    // swift: Render/Office/HwpReader.swift:250-254
    pub const HEADING_TEXT_LIMIT: usize = 80;

    /// HWP's own default line spacing, and the value a NON-PAGED HWP still treats as "nothing
    /// stated" — see `paragraphFormat`'s percent arm for why that treatment survives there and
    /// nowhere else. The match is near-exact (±0.5) on purpose: 158% is a choice, not a rounding
    /// of 160. Measured across 637 real files, 225,654 of 525,054 percent paragraphs (43%) sit
    /// here, so this constant decides the most common Korean page there is.
    // swift: Render/Office/HwpReader.swift:255-261
    pub const NEUTRAL_PERCENT_LINE_HEIGHT: CGFloat = 160.0;

    /// A percent line height as a plain percentage, whatever encoding the file used. HWP writes this
    /// field as a percentage in some versions and as percent×100 in others, so the value is accepted
    /// only from the two plausible bands and rejected outside them — a spacing this reader cannot
    /// identify must fall back to the house rhythm, never render a document at 160× line height.
    // swift: Render/Office/HwpReader.swift:262-271
    pub fn percent_line_height(raw: i64) -> Option<CGFloat> {
        let v = raw as CGFloat;
        if (50.0..=500.0).contains(&v) { return Some(v); }             // 160  → 160%
        if (5_000.0..=50_000.0).contains(&v) { return Some(v / 100.0); } // 16000 → 160%
        None
    }
}

use crate::render::office::office_block::{
    OfficeFootnoteSeparator, OfficePageBorder, OfficePageNumberRestart,
};
use crate::render::office::declared_font_kind::DeclaredFace;
use swiftshim::NSEdgeInsets;

impl HwpReader {
    /// PURE mapping: rhwp's structured JSON string → `OfficeReadResult`. Separated from the FFI so
    /// the whole JSON→OfficeBlock vocabulary is testable with hand-built envelopes. HWP comments are
    /// a later/never sprint, so `comments` is always `[]`.
    // swift: Render/Office/HwpReader.swift:272-524
    pub fn map_json(
        json: &str,
        picture_provider: Option<Box<dyn Fn(i64) -> Option<Data>>>,
    ) -> Result<OfficeReadResult, MapError> {
        let envelope: HwpEnvelope =
            serde_json::from_str(json).map_err(|_| MapError::MalformedJSON)?;
        // The page body width is resolved FIRST: a picture whose width is stored as a share of the
        // page (HWP's `widthCriterion`) can only become points once that width is known.
        let page_width: Option<CGFloat> = envelope
            .page_content_width
            .and_then(|w| if w > 0.0 { Some(w as CGFloat) } else { None });
        // The document's own default body size is resolved BEFORE mapping: a percent line height is
        // relative to the text's size, so the mapper needs it to turn "200%" into points.
        let default_body_size: CGFloat = envelope
            .default_font_size_pt
            .and_then(|p| if p > 0.0 { Some(p as CGFloat) } else { None })
            .unwrap_or(11.0);
        // The seven families per char shape, each row resolved through HWP's fallback chain ONCE for
        // the whole document — tens to low hundreds of rows, against the ~1.1 M spans that index into
        // them. A parser predating the `charShapes` export yields `[]`, and every span then keeps
        // rhwp's own `font`, which is exactly what this reader drew before per-slot fonts existed.
        let decor_rows = envelope.char_shape_decor.clone().unwrap_or_default();
        let slot_fonts: Vec<HwpSlotFonts> = envelope
            .char_shapes
            .clone()
            .unwrap_or_default()
            .into_iter()
            .enumerate()
            .map(|(index, row)| HwpSlotFonts::new(&row, decor_rows.get(index).cloned()))
            .collect();
        // The document's own border/background table, resolved ONCE for the whole document the same
        // way `slotFonts` is — a cell carries only an id. `[]` (a parser predating this export)
        // leaves every table exactly as this reader drew it before: the theme grid.
        let border_fills = envelope.border_fills.clone().unwrap_or_default();
        // Drawings are rendered DURING the block walk (see `HwpShapeRenderer`); the bytes they produce
        // join the result's own media map, keyed by the id their block carries.
        let mut shapes = MediaContext::new(picture_provider);
        // `paged` is not a second flag — it is the SAME predicate `OfficeTextBuilder.build` resolves
        // as `pageBasis != nil` (a page content width the document actually stated), read here from
        // the same field so the reader and the builder cannot drift on what "paged" means.
        // The paper an anchored object is placed on. Only present when the document declared a page
        // at all; without it nothing can be pinned to a sheet and every object stays in the flow.
        if let (Some(w), Some(h)) = (envelope.page_content_width, envelope.page_content_height) {
            if w > 0.0 && h > 0.0 {
                shapes.paper = Some(PaperGeometry {
                    content_width: w as CGFloat,
                    content_height: h as CGFloat,
                    margin_left: envelope.page_margin_left.unwrap_or(0.0) as CGFloat,
                    margin_top: envelope.page_margin_top.unwrap_or(0.0) as CGFloat,
                    margin_right: envelope.page_margin_right.unwrap_or(0.0) as CGFloat,
                    margin_bottom: envelope.page_margin_bottom.unwrap_or(0.0) as CGFloat,
                });
            }
        }
        let paged = page_width.is_some();
        let mut blocks: Vec<OfficeBlock> = Vec::with_capacity(envelope.blocks.len());
        for (index, block) in envelope.blocks.iter().enumerate() {
            shapes.block_index = index;
            blocks.push(Self::map_block(
                block, page_width, default_body_size, &slot_fonts, &border_fills, &mut shapes, paged,
            ));
        }
        let mut result = OfficeReadResult { blocks, comments: Vec::new(), ..Default::default() };
        result.anchored_objects = shapes.anchored.clone();
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
        {
            let mut table: std::collections::HashMap<String, DeclaredFace> = std::collections::HashMap::new();
            for row in envelope.font_faces.clone().unwrap_or_default() {
                for face in row {
                    if face.name.is_empty() || table.contains_key(&face.name) { continue; }
                    table.insert(
                        face.name.clone(),
                        DeclaredFace {
                            nominated_substitute: face.alt_name.filter(|s| !s.is_empty()),
                            is_embedded: face.embedded.unwrap_or(false),
                            type_info: face.panose.map(|p| p.into_iter().map(|v| v as u8).collect()),
                        },
                    );
                }
            }
            result.declared_faces = table.into_iter()
                .map(|(k, v)| (SwiftString::from(k), v))
                .collect();
        }
        // The author's OWN page breaks. `section` counts too: a Korean document starts a new page at
        // a section break, and this reader flattens every section into one column (invariant 57), so
        // without it the sections simply run together. `multiColumn`/`column` are NOT page breaks —
        // they move to the next COLUMN, which a single-column reader has nowhere to honour, and
        // treating them as pages would invent breaks the document never asked for.
        result.page_break_blocks = envelope
            .blocks
            .iter()
            .enumerate()
            .filter_map(|(index, block)| {
                let HwpBlock::Para(p) = block else { return None };
                // The author's own break, and the STYLE's — two separate signals in HWP, the same
                // instruction to a reader.
                if p.break_before.as_deref() == Some("page")
                    || p.break_before.as_deref() == Some("section")
                    || p.page_break_before == Some(true)
                {
                    Some(index as i64)
                } else {
                    None
                }
            })
            .collect();
        // The author's own PageHide('쪽 감추기') — a span-level marker rather than a paragraph
        // field, because HWP lets it start mid-paragraph. Only `hidePageNum == true` matters here
        // (see `OfficeReadResult.hidePageNumberBlocks`); `false` and absent are the same "this
        // paragraph said nothing" case, so both are excluded the same way.
        result.hide_page_number_blocks = envelope
            .blocks
            .iter()
            .enumerate()
            .filter_map(|(index, block)| {
                let HwpBlock::Para(p) = block else { return None };
                p.spans
                    .iter()
                    .any(|s| s.page_hide.as_ref().and_then(|h| h.hide_page_num) == Some(true))
                    .then_some(index as i64)
            })
            .collect();
        // The author's own NewNumber('쪽 번호 새로 시작') — same span-level shape as PageHide, and
        // read the same way. Only `numberType == "page"` is taken: a picture or table counter
        // restart has no consumer here, because this reader never numbers a caption itself.
        result.page_number_restart_blocks = envelope
            .blocks
            .iter()
            .enumerate()
            .filter_map(|(index, block)| {
                let HwpBlock::Para(p) = block else { return None };
                for span in &p.spans {
                    if let Some(restart) = &span.new_number {
                        if restart.number_type.as_deref() == Some("page") {
                            if let Some(n) = restart.number {
                                return Some(OfficePageNumberRestart { block: index as i64, number: n });
                            }
                        }
                    }
                }
                None
            })
            .collect();
        result.sections = envelope
            .sections
            .clone()
            .unwrap_or_default()
            .into_iter()
            .map(|section| OfficeSectionDeclaration {
                // Every length is the document's own HWPUNIT, through the SAME `points`
                // conversion every other authored length in this reader goes through — a
                // separator measured differently from the margins around it would drift.
                footnote_separator: section.footnote_shape.map(|shape| OfficeFootnoteSeparator {
                    line_type: shape.separator_line_type.unwrap_or(0),
                    line_width_pt: shape
                        .separator_line_width
                        .and_then(|w| if w > 0 { Some(Self::diagonal_width_pt(Some(w))) } else { None })
                        .unwrap_or(0.0),
                    color: shape.separator_color.and_then(|c| Self::color(Some(&c))),
                    length_pt: shape.separator_length_hwp_unit.map(Self::points),
                    margin_top_pt: Self::points(shape.separator_margin_top_hwp_unit.unwrap_or(0)),
                    margin_bottom_pt: Self::points(shape.separator_margin_bottom_hwp_unit.unwrap_or(0)),
                    note_spacing_pt: Self::points(shape.note_spacing_hwp_unit.unwrap_or(0)),
                }),
                page_border: section.page_border.map(|pb| OfficePageBorder {
                    borders: Self::edge_borders(Some(pb.border_fill_id), &border_fills),
                    background: Self::border_fill(Some(pb.border_fill_id), &border_fills)
                        .and_then(|fill| Self::color(fill.bg.as_deref())),
                    spacing: NSEdgeInsets {
                        top: Self::points(pb.spacing_top_hwp_unit.unwrap_or(0)),
                        left: Self::points(pb.spacing_left_hwp_unit.unwrap_or(0)),
                        bottom: Self::points(pb.spacing_bottom_hwp_unit.unwrap_or(0)),
                        right: Self::points(pb.spacing_right_hwp_unit.unwrap_or(0)),
                    },
                    measured_from_paper: pb.basis.as_deref() != Some("body"),
                }),
                paper: section.page.as_ref().map(|p| PaperGeometry {
                    content_width: p.content_width,
                    content_height: p.content_height,
                    margin_left: p.margin_left,
                    margin_top: p.margin_top,
                    margin_right: p.margin_right,
                    margin_bottom: p.margin_bottom,
                }),
                hides_header: section.hide_header.unwrap_or(false),
                hides_footer: section.hide_footer.unwrap_or(false),
                hides_master_page: section.hide_master_page.unwrap_or(false),
                page_number_start: section.page_number_start.and_then(|n| if n > 0 { Some(n) } else { None }),
                line_grid_pitch: section
                    .line_grid_hwp_unit
                    .and_then(|u| if u > 0 { Some(Self::points(u)) } else { None }),
                is_vertical: section.vertical_text.unwrap_or(false),
            })
            .collect();
        // The 원고지 line grid the document is written on. HWP states it per SECTION and this reader
        // lays a document out in ONE container, so there is exactly one grid to honour — and the only
        // honest answer is the one every section agrees on. A document where sections disagree, or
        // where some are on a grid and others are not, cannot be expressed at one pitch, and saying
        // nothing is what tells a caller "we could not" apart from "the document never said"
        // (invariant 83's own rule). Until now HWP set this NOWHERE: the pitch reached the section
        // vocabulary and stopped, while the builder that consumes it (`OfficeTextBuilder`, a FLOOR on
        // line height) was fed by docx alone.
        let declared_grids: Vec<Option<CGFloat>> =
            result.sections.iter().map(|s| s.line_grid_pitch).collect();
        if let Some(first) = declared_grids.first().copied() {
            if first.is_some() && declared_grids.iter().all(|g| *g == first) {
                result.line_grid_pitch = first;
            }
        }
        result.keep_with_next_blocks = envelope
            .blocks
            .iter()
            .enumerate()
            .filter_map(|(index, block)| {
                let HwpBlock::Para(p) = block else { return None };
                (p.keep_with_next == Some(true)).then_some(index as i64)
            })
            .collect();
        // The drawings this read rendered — merged, not assigned, so a later `read()` that also
        // fetches embedded pictures keeps both (invariant: one media map, one id space).
        result.images = shapes.images.iter()
            .map(|(k, v)| (SwiftString::from(k.clone()), v.clone()))
            .collect();
        // The document's own default body size (Normal/"바탕글" style char-shape base size, in pt),
        // rhwp's analog of docx `w:docDefaults/…/w:sz`. `null`/≤0 → leave the `11` default so an HWP
        // that declares none scales exactly like a docx/odt that declares none (invariant 37).
        if let Some(pt) = envelope.default_font_size_pt {
            if pt > 0.0 { result.default_body_font_size = pt as CGFloat; }
        }
        // The document's own page body width (paper − margins, in pt) — the denominator of the office
        // GRAPHIC scale (see `OfficeReadResult.pageContentWidth`), so an HWP image keeps the share of
        // the reading column it held of rhwp's page. The column itself always fills the window, and
        // tables are untouched. Absent/≤0 → leave nil = authored sizes verbatim. Identical handling to
        // docx/odt: one field, one consumer, no HWP-specific layout path.
        if let Some(w) = envelope.page_content_width {
            if w > 0.0 { result.page_content_width = Some(w as CGFloat); }
        }
        // The vertical twin, plus all four margins — HWP wired NONE of these before this change
        // (only the body width was read), so this is new ground for the format, not an extension of
        // an existing HWP layout path. Each is adopted independently and ONLY when present and
        // positive, exactly like the `pageContentWidth` line above: a document a parser predating
        // these fields produced leaves every one of them nil, unchanged (invariant 37's "unspecified
        // → theme/fallback" contract, restated for geometry rather than typography).
        if let Some(h) = envelope.page_content_height { if h > 0.0 { result.page_content_height = Some(h as CGFloat); } }
        if let Some(l) = envelope.page_margin_left { if l > 0.0 { result.page_margin_left = Some(l as CGFloat); } }
        if let Some(r) = envelope.page_margin_right { if r > 0.0 { result.page_margin_right = Some(r as CGFloat); } }
        if let Some(t) = envelope.page_margin_top { if t > 0.0 { result.page_margin_top = Some(t as CGFloat); } }
        if let Some(b) = envelope.page_margin_bottom { if b > 0.0 { result.page_margin_bottom = Some(b as CGFloat); } }
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
        let geometry_section = envelope
            .body_section
            .and_then(|index| envelope.sections.as_ref().and_then(|s| s.get(index as usize)))
            .cloned()
            .or_else(|| envelope.sections.as_ref().and_then(|s| s.first().cloned()));
        if let Some(page) = geometry_section.as_ref().and_then(|s| s.page.as_ref()) {
            // A distance at or past the body's own start would put the running head inside the body
            // text, which no document means — the same rejection `DocxReader` makes for `w:header`.
            if let Some(h) = page.margin_header {
                if h > 0.0 && h < page.margin_top { result.page_header_distance = Some(h); }
            }
            if let Some(f) = page.margin_footer {
                if f > 0.0 && f < page.margin_bottom { result.page_footer_distance = Some(f); }
            }
        }
        // header-footer-design.md step 2/3 — read ONLY, nothing renders these yet. `nil` (a parser
        // built before this field existed) behaves exactly like `[]`: no running header/footer
        // captured, same as every other reader that finds none.
        // Running heads from the BODY section only — a header declared by some other section
        // describes that section's pages, not this reading column's. A parser predating
        // `bodySection`/`section` leaves both nil and every entry is kept, exactly as before.
        let body_section = envelope.body_section;
        let section_starts = envelope.section_starts.clone().unwrap_or_default();
        result.section_start_blocks = section_starts.clone();
        let in_body_section = |entry: &HwpHeaderFooterEntry| -> bool {
            let (Some(body_section), Some(section)) = (body_section, entry.section) else { return true };
            section == body_section
        };
        // Every section's entries are kept when the parser said where sections start — the painter
        // picks per page, the same way it picks a master page. Without `sectionStarts` a page cannot
        // be placed in a section at all, and then the body section's are the only honest answer
        // (invariant 77: applying another section's put a page number on 400 pages that never had one).
        let keep_every_head_section = !section_starts.is_empty();
        result.headers = envelope
            .headers
            .clone()
            .unwrap_or_default()
            .into_iter()
            .filter(|e| keep_every_head_section || in_body_section(e))
            .map(|e| {
                Self::map_header_footer_entry(
                    &e, page_width, default_body_size, &slot_fonts, &border_fills, &mut shapes, paged,
                )
            })
            .collect();
        result.footers = envelope
            .footers
            .clone()
            .unwrap_or_default()
            .into_iter()
            .filter(|e| keep_every_head_section || in_body_section(e))
            .map(|e| {
                Self::map_header_footer_entry(
                    &e, page_width, default_body_size, &slot_fonts, &border_fills, &mut shapes, paged,
                )
            })
            .collect();
        result.footnotes = envelope
            .footnotes
            .clone()
            .unwrap_or_default()
            .into_iter()
            .map(|f| {
                Self::map_footnote(
                    &f, page_width, default_body_size, &slot_fonts, &border_fills, &mut shapes, paged,
                )
            })
            .collect();
        // EVERY section's template is kept, and the painter picks per page (`sectionStartBlocks`).
        // Keeping only the body section's — the rule a running head needs (invariant 77) — put that
        // section's chapter title on the cover, on the table of contents and on every other
        // chapter's pages, which is the same defect one level up. Without `sectionStarts` no page
        // can be placed in a section at all, and then the body section's is the honest single answer.
        result.master_pages = envelope
            .master_pages
            .clone()
            .unwrap_or_default()
            .into_iter()
            .filter(|mp| !section_starts.is_empty() || body_section.is_none() || Some(mp.section) == body_section)
            .filter_map(|mp| {
                Self::map_master_page(
                    &mp, page_width, default_body_size, &slot_fonts, &border_fills, &mut shapes, paged,
                )
            })
            .collect();
        Ok(result)
    }
}

use crate::render::office::office_block::{
    ParagraphAnchor, OfficeMasterPage, OfficeMasterObject, OfficeMasterObjectContent,
    OfficeHeaderFooter,
};
use crate::render::office::hwp_reader::schema::{HwpMasterPage, HwpHeaderFooterEntry};
// swift: hwp shape renderer — referenced by name, ported elsewhere (out of this file's range).
use crate::render::office::hwp_shape_path::HwpShapeRenderer;

impl HwpReader {
    /// Where an anchored object sits on the SHEET, in points from the paper's top-left — rhwp's own
    /// placement rule (`renderer/layout/shape_layout.rs`'s `calc_shape_bottom_y`), restated for the
    /// two references this reader can honour.
    ///
    /// `paper` measures against the whole sheet, `page` against the body area inside the margins.
    /// `para`/`column` need the anchoring paragraph's own position — the floating layer invariant 75
    /// measured and rejected — so they never reach here.
    // swift: Render/Office/HwpReader.swift:525-547
    pub fn anchored_frame(
        size: CGSize, vert_rel_to: &str, horz_rel_to: &str,
        vert_align: &str, horz_align: &str, offset: CGPoint, page: &PaperGeometry,
    ) -> Option<CGRect> {
        if !(vert_rel_to == "paper" || vert_rel_to == "page") { return None; }
        if !(horz_rel_to == "paper" || horz_rel_to == "page") { return None; }
        fn place(ref_origin: CGFloat, ref_extent: CGFloat, own: CGFloat, align: &str, offset: CGFloat) -> CGFloat {
            match align {
                "center" => ref_origin + (ref_extent - own) / 2.0 + offset,
                "bottom" | "outside" => ref_origin + ref_extent - own - offset,
                _ => ref_origin + offset, // top / inside
            }
        }
        let v_ref: (CGFloat, CGFloat) = if vert_rel_to == "paper" {
            (0.0, page.paper_height())
        } else {
            (page.margin_top, page.content_height)
        };
        let h_ref: (CGFloat, CGFloat) = if horz_rel_to == "paper" {
            (0.0, page.paper_width())
        } else {
            (page.margin_left, page.content_width)
        };
        Some(CGRect {
            origin: CGPoint {
                x: place(h_ref.0, h_ref.1, size.width, horz_align, offset.x),
                y: place(v_ref.0, v_ref.1, size.height, vert_align, offset.y),
            },
            size,
        })
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
    // swift: Render/Office/HwpReader.swift:548-596
    pub fn paragraph_anchored_placement(
        size: CGSize, vert_rel_to: &str, horz_rel_to: &str, vert_align: &str, horz_align: &str,
        offset: CGPoint, page: &PaperGeometry,
    ) -> Option<(CGRect, ParagraphAnchor)> {
        if vert_rel_to != "para" { return None; }
        let h_ref: (CGFloat, CGFloat) = match horz_rel_to {
            "paper" => (0.0, page.paper_width()),
            _ => (page.margin_left, page.content_width), // page / column / para
        };
        let x: CGFloat = match horz_align {
            "center" => h_ref.0 + (h_ref.1 - size.width) / 2.0 + offset.x,
            "right" | "outside" => h_ref.0 + h_ref.1 - size.width - offset.x,
            _ => h_ref.0 + offset.x, // left / inside
        };
        let align = match vert_align {
            "center" => crate::render::office::office_block::ParagraphAnchorAlign::Center,
            "bottom" | "outside" => crate::render::office::office_block::ParagraphAnchorAlign::Bottom,
            _ => crate::render::office::office_block::ParagraphAnchorAlign::Top, // top / inside
        };
        Some((
            CGRect { origin: CGPoint { x, y: 0.0 }, size },
            ParagraphAnchor { align, offset: offset.y },
        ))
    }

    // swift: Render/Office/HwpReader.swift:598-601
    // (PaperGeometry alias — `HwpReader.PaperGeometry` in Swift is a typealias to the
    // format-neutral `FastDocReader.PaperGeometry`; this port uses the format-neutral
    // `crate::render::office::office_block::PaperGeometry` directly, imported above.)

    /// One 바탕쪽 → the format-neutral `OfficeMasterPage`, or nil when nothing in it can be drawn.
    ///
    /// Every object is resolved HERE, at read time, into bytes or blocks — the same choice
    /// `HwpShapeRenderer` already forced for inline drawings (invariant 75): the picture provider and
    /// the live parse handle exist during the read and are gone by the time anything paints.
    // swift: Render/Office/HwpReader.swift:597-651
    fn map_master_page(
        page: &HwpMasterPage, page_width: Option<CGFloat>, default_body_size: CGFloat,
        slot_fonts: &[HwpSlotFonts], border_fills: &[HwpBorderFill], shapes: &mut MediaContext, paged: bool,
    ) -> Option<OfficeMasterPage> {
        let mut objects: Vec<OfficeMasterObject> = Vec::new();
        // rhwp's own order, not the storage order: measured on the 편람, the full-page background
        // picture is stored FIRST and the running title SECOND, so drawing them as stored painted
        // the artwork over the title. Sorted by the SAME key the renderer sorts paper-relative nodes
        // by — text-wrap band, then z-order, then stable position — with a stable sort so an object
        // that declares neither keeps its place.
        let mut indexed: Vec<(usize, &crate::render::office::hwp_reader::schema::HwpMasterObject)> =
            page.objects.iter().enumerate().collect();
        indexed.sort_by_key(|(offset, o)| (o.plane.unwrap_or(2), o.z.unwrap_or(0), *offset));
        let ordered: Vec<_> = indexed.into_iter().map(|(_, o)| o).collect();
        for object in ordered {
            let frame = CGRect {
                origin: CGPoint { x: Self::points(object.x), y: Self::points(object.y) },
                size: CGSize { width: Self::points(object.w), height: Self::points(object.h) },
            };
            // A picture first, because an object that HAS one is that picture: the paths beside it
            // are the frame the document drew round it, and rhwp already exports the two separately.
            if let Some(bin_data_id) = object.bin_data_id {
                if let Some(image) = shapes.fill_image(Some(bin_data_id)) {
                    objects.push(OfficeMasterObject { frame, content: OfficeMasterObjectContent::Image(image) });
                    continue;
                }
            }
            // A drawing is rendered to the SAME vector PDF an inline shape becomes, so the tab down
            // the page edge is drawn by the code that already draws the arrows in the body.
            let paths: Vec<_> = object.paths.clone().unwrap_or_default().into_iter()
                .filter_map(|p| Self::shape_path(&p)).collect();
            if !paths.is_empty() && frame.size.width > 0.5 && frame.size.height > 0.5 {
                if let Some(pdf) = HwpShapeRenderer::pdf(&paths, frame.size) {
                    objects.push(OfficeMasterObject { frame, content: OfficeMasterObjectContent::Drawing(pdf) });
                }
            }
            let blocks: Vec<OfficeBlock> = object.blocks.clone().unwrap_or_default().iter()
                .map(|b| Self::map_block(b, page_width, default_body_size, slot_fonts, border_fills, shapes, paged))
                .collect();
            // A DEGENERATE box is dropped rather than given a width this reader invents. Measured on
            // the 편람, one master text box states a width of zero (a rotated tab label on the cover
            // section) — laying text into a box the document sized at nothing means choosing the
            // width ourselves, which is invariant 57's mistake. The body section's own four objects
            // all state real boxes.
            if !blocks.is_empty() && frame.size.width > 0.5 && frame.size.height > 0.5 {
                objects.push(OfficeMasterObject { frame, content: OfficeMasterObjectContent::Text(blocks) });
            }
        }
        if objects.is_empty() { return None; }
        Some(OfficeMasterPage {
            section: page.section,
            applies_to: Self::map_header_footer_apply_to(&page.apply_to),
            objects,
        })
    }
}

use crate::render::office::office_block::OfficeFootnote;
use crate::render::office::hwp_reader::schema::{HwpFootnoteEntry, HwpFontFace};

impl HwpReader {
    // swift: Render/Office/HwpReader.swift:652-662
    fn map_header_footer_entry(
        entry: &HwpHeaderFooterEntry, page_width: Option<CGFloat>, default_body_size: CGFloat,
        slot_fonts: &[HwpSlotFonts], border_fills: &[HwpBorderFill], shapes: &mut MediaContext, paged: bool,
    ) -> OfficeHeaderFooter {
        OfficeHeaderFooter {
            applies_to: Self::map_header_footer_apply_to(&entry.apply_to),
            blocks: entry.blocks.iter()
                .map(|b| Self::map_block(b, page_width, default_body_size, slot_fonts, border_fills, shapes, paged))
                .collect(),
            section: entry.section,
        }
    }

    /// Every section's footnotes are kept, unfiltered — unlike a running head, which belongs to one
    /// section (invariant 77). A footnote is drawn on the page that CITES it, and that page is found
    /// from its marker rather than from any section rule, so filtering by section here could only
    /// throw away a note whose marker is still in the text.
    // swift: Render/Office/HwpReader.swift:663-680
    fn map_footnote(
        entry: &HwpFootnoteEntry, page_width: Option<CGFloat>, default_body_size: CGFloat,
        slot_fonts: &[HwpSlotFonts], border_fills: &[HwpBorderFill], shapes: &mut MediaContext, paged: bool,
    ) -> OfficeFootnote {
        OfficeFootnote {
            number: entry.number,
            blocks: entry.blocks.iter()
                .map(|b| Self::map_block(b, page_width, default_body_size, slot_fonts, border_fills, shapes, paged))
                .collect(),
            section: entry.section,
        }
    }

    /// rhwp's `apply_to` (`"both"`/`"even"`/`"odd"`) → `HeaderFooterApplicability` — see that enum's
    /// own doc for why this is NOT a case-for-case correspondence with docx's three types. `"even"`
    /// is the one honest match. `"both"` (no even override declared anywhere in the section — this
    /// entry covers every page) and `"odd"` (an even override EXISTS elsewhere, so this entry is
    /// explicitly the non-even pages) both fold into `.defaultPages`: this reader has no consumer
    /// yet that would need the two told apart, and docx's own `.defaultPages` already means "every
    /// page not covered by a more specific entry" — the same shape. An unrecognized value (a rhwp
    /// version ahead of this mapper) degrades to `.defaultPages` too, rather than being dropped.
    // swift: Render/Office/HwpReader.swift:681-692
    fn map_header_footer_apply_to(raw: &str) -> HeaderFooterApplicability {
        if raw == "even" { HeaderFooterApplicability::EvenPages } else { HeaderFooterApplicability::DefaultPages }
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
// swift: Render/Office/HwpReader.swift:693-745
#[derive(Debug, Clone, PartialEq, Default)]
pub struct FontSlotExport {
    /// `charShapes`, or `[]` when the envelope carried none (a parser predating this field).
    pub char_shapes: Vec<Vec<String>>,
    /// Every span's `csId` in document order, table cells included, `nil` where the span
    /// carries none. Kept in order rather than as a set so a caller can also see how many spans
    /// have no char shape at all.
    pub span_char_shape_ids: Vec<Option<i64>>,
    /// One entry per span, in the same order, carrying what a MEASUREMENT of the per-slot
    /// classifier needs and the id list alone cannot give: the text a slot decision is made
    /// over, and the single family rhwp itself resolved for that span.
    ///
    /// This exists so the two questions the design leaves open — how much a Symbol-slot
    /// exception costs in extra pieces, and whether this reader's fallback chain ever disagrees
    /// with rhwp's own `font` field — can be asked of a real corpus rather than argued. It is
    /// read only by probes; the render path takes the mapped `Span`s, not this.
    pub spans: Vec<SpanSample>,
    /// The document's own font table, one list per language slot — what it NAMED, before
    /// rhwp's substitution table rewrote it, and what it nominates instead when that name is
    /// not installed. `[]` for a parser predating the export.
    pub font_faces: Vec<Vec<HwpFontFace>>,
    /// One row per char shape, same row number as `charShapes` — the decoration table.
    /// `[]` for a parser predating the export.
    pub char_shape_decor: Vec<HwpCharDecor>,
}

// swift: Render/Office/HwpReader.swift:729-733
#[derive(Debug, Clone, PartialEq)]
pub struct SpanSample {
    pub text: String,
    pub cs_id: Option<i64>,
    /// rhwp's own single-family answer for this span — slot 0, falling back to slot 1 only
    /// when slot 0 resolves empty. The value this reader drew before per-slot fonts existed.
    pub font: Option<String>,
}

impl HwpReader {
    // swift: Render/Office/HwpReader.swift:744-772
    pub fn font_slot_export(json: &str) -> Result<FontSlotExport, MapError> {
        let envelope: HwpEnvelope = serde_json::from_str(json).map_err(|_| MapError::MalformedJSON)?;
        let mut ids: Vec<Option<i64>> = Vec::new();
        let mut samples: Vec<SpanSample> = Vec::new();
        fn walk(block: &HwpBlock, ids: &mut Vec<Option<i64>>, samples: &mut Vec<SpanSample>) {
            match block {
                HwpBlock::Para(p) => {
                    ids.extend(p.spans.iter().map(|s| s.cs_id));
                    samples.extend(p.spans.iter().map(|s| SpanSample {
                        text: s.text.clone(), cs_id: s.cs_id, font: s.font.clone(),
                    }));
                }
                HwpBlock::Table(t) => {
                    for row in &t.rows {
                        for cell in row {
                            for b in &cell.blocks {
                                walk(b, ids, samples);
                            }
                        }
                    }
                }
                HwpBlock::Image(_) | HwpBlock::Shape(_) | HwpBlock::Unsupported(_) | HwpBlock::Equation(_) => {}
            }
        }
        for block in &envelope.blocks {
            walk(block, &mut ids, &mut samples);
        }
        Ok(FontSlotExport {
            char_shapes: envelope.char_shapes.clone().unwrap_or_default(),
            span_char_shape_ids: ids,
            spans: samples,
            font_faces: envelope.font_faces.clone().unwrap_or_default(),
            char_shape_decor: envelope.char_shape_decor.clone().unwrap_or_default(),
        })
    }

    // swift: Render/Office/HwpReader.swift:773
    // MARK: unit conversion (HWPUNIT = 1/7200 inch; points = HWPUNIT ÷ 100)
}

use swiftshim::{NSColor, NSTextAlignment};

impl HwpReader {
    /// A raw HWPUNIT PARAGRAPH-METRIC length (spacing / indent / margin) → points. HWP5 stores these
    /// at 2× the effective value (rhwp halves them — `style_resolver.rs` `variant_div = 2.0`), so the
    /// scale is ÷200 (HWPUNIT→pt = ÷100, then ÷2). `nil`/`0` → `nil` so unspecified leaves the theme
    /// token in place, byte-identical to a block with no format (invariant 37).
    /// NOTE: font size and image/column extents are NOT 2×-stored — those use `points()` (÷100).
    // swift: Render/Office/HwpReader.swift:773-783
    fn non_zero_points(hwpunit: Option<i64>) -> Option<CGFloat> {
        let v = hwpunit?;
        if v == 0 { return None; }
        Some(v as CGFloat / 200.0)
    }

    /// A raw HWPUNIT EXTENT (font size, image/column width/height) → points. These are stored at true
    /// HWPUNIT (NOT 2×), so ÷100 (confirmed against rhwp `hwpunit_to_px` + `base_size`/`common.width`).
    // swift: Render/Office/HwpReader.swift:784-787
    fn points(hwpunit: i64) -> CGFloat { hwpunit as CGFloat / 100.0 }

    /// A raw HWPUNIT EXTENT that is `nil`/absent when unspecified (unlike `points`, whose callers
    /// already hold a non-optional `Int`) — `nonZeroPoints` cannot be reused here: `outer_margin_*`
    /// is a plain EXTENT (÷100, confirmed against `hwpunit_to_px` — the rust source's own `outer_margin:
    /// i16 = 283 // ~1mm` is exactly `283 / 100 = 2.83pt = 1mm`), NOT a 2×-stored paragraph metric.
    // swift: Render/Office/HwpReader.swift:788-796
    fn extent_points(hwpunit: Option<i64>) -> Option<CGFloat> {
        let v = hwpunit?;
        if v == 0 { return None; }
        Some(Self::points(v))
    }

    /// "RRGGBB" (6 hex digits, optional leading '#') → sRGB colour; anything else → nil (theme
    /// decides — invariant 37). Mirrors `DocxReader.colorFromHex`.
    // swift: Render/Office/HwpReader.swift:797-809
    fn color(hex: Option<&str>) -> Option<NSColor> {
        let digits = hex?.strip_prefix('#').unwrap_or(hex?);
        if digits.len() != 6 { return None; }
        let value = u32::from_str_radix(digits, 16).ok()?;
        Some(NSColor::srgb(
            ((value >> 16) & 0xFF) as CGFloat / 255.0,
            ((value >> 8) & 0xFF) as CGFloat / 255.0,
            (value & 0xFF) as CGFloat / 255.0,
            1.0,
        ))
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
    // swift: Render/Office/HwpReader.swift:810-841
    fn gradient_image(gradient: Option<&HwpGradient>) -> Option<swiftshim::NSImage> {
        let gradient = gradient?;
        let stops: Vec<NSColor> = gradient.colors.iter().filter_map(|c| Self::color(Some(c))).collect();
        if stops.len() < 2 { return None; }
        todo!("swift:825-840 NSGradient rendering into a 64x64 NSImage — needs a raster/drawing shim, phase B")
    }

    /// HWP paragraph `align` → the block's `NSTextAlignment?`, resolved exactly the way
    /// `DocxReader.alignmentFromJc` does: `"both"`/`"justify"`/`"distribute"` → `.justified`
    /// (`NSTextAlignment` has no distributed case, so distribute collapses to justify — same choice
    /// DocxReader makes for `w:jc="distribute"`); an unrecognized/absent value → `nil` so `rtl`/the
    /// theme default decides, never a hardcoded `.left`.
    // swift: Render/Office/HwpReader.swift:842-852
    fn alignment(align: Option<&str>) -> Option<NSTextAlignment> {
        match align {
            Some("left") => Some(NSTextAlignment::Left),
            Some("center") => Some(NSTextAlignment::Center),
            Some("right") => Some(NSTextAlignment::Right),
            Some("justify") | Some("both") | Some("distribute") => Some(NSTextAlignment::Justified),
            _ => None,
        }
    }

    /// HWP span `underline` string → (`underline` on/off, `underlineStyle`). `"none"`/absent → off;
    /// each named style maps to the matching `UnderlineStyle` case (all five HWP names have an exact
    /// AppKit equivalent, so no nearest-case approximation is needed).
    // swift: Render/Office/HwpReader.swift:853-866
    fn underline(u: Option<&str>) -> (bool, UnderlineStyle) {
        match u {
            Some("single") => (true, UnderlineStyle::Single),
            Some("double") => (true, UnderlineStyle::Double),
            Some("dotted") => (true, UnderlineStyle::Dotted),
            Some("dashed") => (true, UnderlineStyle::Dashed),
            Some("wavy") => (true, UnderlineStyle::Wavy),
            _ => (false, UnderlineStyle::Single), // "none" / null / unknown
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
    // swift: Render/Office/HwpReader.swift:884-900
    fn column_layout(cd: &HwpColumnDef) -> OfficeColumnLayout {
        // The rule's thickness reuses HWP's sixteen-step line-width table, the same one a cell
        // diagonal and a footnote separator are measured with — one table, three consumers.
        let rule = if cd.separator_type.unwrap_or(0) != 0 {
            Self::diagonal_width_pt(Some(cd.separator_width.unwrap_or(0)))
        } else {
            0.0
        };
        OfficeColumnLayout {
            count: cd.column_count.max(1),
            spacing: cd.column_spacing_pt.unwrap_or(0.0) as CGFloat,
            widths: cd.column_widths.clone().unwrap_or_default().into_iter().map(|w| w as CGFloat).collect(),
            gaps: cd.column_gaps.clone().unwrap_or_default().into_iter().map(|g| g as CGFloat).collect(),
            proportional: cd.proportional_widths.unwrap_or(false),
            separator_type: cd.separator_type.unwrap_or(0),
            separator_width_pt: rule,
            separator_color: if rule > 0.0 { Self::color(cd.separator_color.as_deref()) } else { None },
        }
    }
}

use crate::render::office::office_block::{OfficeFormControl, OfficeFormControlKind, PageNumberField};
// swift: ScriptRunSplitter / HwpSlotTable — referenced by name; ported elsewhere (out of this file's range).
use crate::render::office::script::script_run_splitter::ScriptRunSplitter;
use crate::render::office::hwp_font_slots::HwpSlotTable;

impl HwpReader {
    // swift: Render/Office/HwpReader.swift:867-1006
    fn map_span(s: &HwpSpan, slot_fonts: &[HwpSlotFonts]) -> Vec<Span> {
        let (ul, ul_style) = Self::underline(s.underline.as_deref());
        // `Span` carries no `new`/`Default` (office_block.rs) — every field is spelled out here,
        // mirroring the Swift struct's own per-field default-argument initializer.
        let mut span = Span {
            text: SwiftString::from(s.text.clone()),
            bold: false,
            italic: false,
            underline: false,
            underline_style: UnderlineStyle::Single,
            code: false,
            caps: false,
            small_caps: false,
            link: None,
            strikethrough: false,
            superscript: false,
            footnote_ref: None,
            form_control: None,
            column_layout: None,
            subscripted: false,
            rtl: false,
            bookmarks: Vec::new(),
            comment_ids: Vec::new(),
            text_color: None,
            highlight_color: None,
            letter_spacing_percent: None,
            baseline_offset_percent: None,
            underline_color: None,
            strikethrough_color: None,
            font_size: None,
            font_name: None,
            resolved_font_descriptor: None,
            page_number_field: None,
        };
        span.bold = s.bold.unwrap_or(false);
        span.italic = s.italic.unwrap_or(false);
        span.underline = ul;
        span.underline_style = ul_style;
        span.strikethrough = s.strike.unwrap_or(false);
        span.superscript = s.superscript.unwrap_or(false);
        // ONLY a footnote's marker is carried. An endnote's marker is left bare: its note is still
        // in the block flow where it belongs, so nothing has to find it.
        // SUPERSCRIPT is what makes it a marker. A note's own BODY carries the same `noteRef` on
        // its leading number run — that run is the note introducing itself (`1) `, already spelled
        // out by the exporter), not a citation of it. Treating both as markers printed the
        // decoration twice (`1) )`) and made the extraction emit a reference where the note's text
        // should be (`[^1]: [^1] …`).
        if s.note_ref_kind.as_deref() == Some("footnote") && s.superscript == Some(true) {
            if let Some(r) = &s.note_ref {
                span.footnote_ref = Some(*r);
                // The marker's glyphs are ASSEMBLED here rather than carried as three more fields on
                // `Span`: what is printed around a number is a per-format convention (HWP states it on
                // the note's own control; a docx puts it in the numbering definition), while `Span` is
                // the format-neutral vocabulary. Measured on the 637-sample corpus: 791 of 811 shape
                // declarations print a closing `)` and NONE prints anything before the number, so a
                // reader that draws the bare digit is wrong on 97% of the documents that have notes.
                span.text = SwiftString::from(format!(
                    "{}{}{}",
                    s.note_before_char.clone().unwrap_or_default(),
                    span.text,
                    s.note_after_char.clone().unwrap_or_default()
                ));
            }
        }
        if let Some(cd) = &s.column_def { span.column_layout = Some(Self::column_layout(cd)); }
        if let Some(f) = &s.form {
            let control = OfficeFormControl {
                kind: OfficeFormControlKind::new(f.form_type.as_deref()),
                caption: SwiftString::from(f.caption.clone().unwrap_or_default()),
                text: SwiftString::from(f.text.clone().unwrap_or_default()),
                value: f.value.unwrap_or(0),
                enabled: f.enabled.unwrap_or(true),
            };
            // The control's own glyphs ARE its text. A form control arrives on a zero-width anchor
            // span (like a bookmark or a note marker), so without this the run has nothing to draw
            // and the document renders blank — which is exactly what a corpus form sample did.
            if span.text.length() == 0 { span.text = control.display_text(); }
            span.form_control = Some(control);
        }
        span.subscripted = s.subscripted.unwrap_or(false);
        span.text_color = Self::color(s.color.as_deref());
        // size is a base_size in HWPUNIT; ÷100 = points. 0/absent → unspecified (theme decides).
        if let Some(sz) = s.size {
            if sz > 0 { span.font_size = Some(sz as CGFloat / 100.0); }
        }
        span.link = s.link.clone().map(SwiftString::from);
        if let Some(bm) = &s.bookmark {
            if !bm.is_empty() { span.bookmarks = vec![SwiftString::from(bm.clone())]; }
        }
        // Only "page" is exported today; anything else is a future rhwp speaking a word this build
        // does not know, and a page number drawn as its cached value beats one drawn as a guess.
        if s.page_number_field.as_deref() == Some("page") { span.page_number_field = Some(PageNumberField::Page); }

        /// rhwp's own single-family answer, kept for every span this pass cannot improve on: a
        /// synthetic span with no char shape, a `csId` outside the table, or a parser predating the
        /// `charShapes` export. Each of those degrades to EXACTLY what this reader drew before.
        let declared: Option<String> = s.font.clone().filter(|f| !f.is_empty());

        // An empty-text span is a bookmark anchor or a footnote marker, not something to classify —
        // and the splitter yields no pieces for empty input, which would DELETE it. Bookmarks must
        // survive (invariant 38: they are never merged away), so this returns before the walk.
        if s.text.is_empty() {
            span.font_name = declared.map(SwiftString::from);
            return vec![span];
        }
        let Some(id) = s.cs_id else {
            span.font_name = declared.map(SwiftString::from);
            return vec![span];
        };
        let Some(fonts) = slot_fonts.get(id as usize) else {
            span.font_name = declared.map(SwiftString::from);
            return vec![span];
        };
        Self::apply_decor(fonts.decor.as_ref(), &mut span);
        // The case invariant 37 rests on, and the one 46.4% of real documents are in: when all seven
        // slots resolve to one family — or to none at all — no character can select anything
        // different from any other, so the scalar walk is skipped rather than run to rediscover
        // that. Before/after is then identical by CONSTRUCTION, and this path costs nothing it did
        // not cost before slots existed. `neutralFamily` is rhwp's own answer here: proven equal to
        // the exported `font` on all 1,085,915 spans of the corpus, 0 disagreements.
        if fonts.is_uniform {
            span.font_name = fonts.neutral_family().map(SwiftString::from);
            return vec![span];
        }
        let pieces = ScriptRunSplitter::split(
            &s.text,
            HwpSlotTable::slot,
            |slot| fonts.family(slot),
        );
        // A run of nothing but absorbing characters — a tab, a stretch of spaces, `(3)` — classifies
        // nothing, and the splitter rightly hands back one piece carrying no family. Emitting that
        // verbatim would strand a theme-font span between two runs of a real family, which is
        // absorption failing at exactly the boundary it exists to protect. Unlike the docx and ODT
        // readers this needs no re-scan to recognise: on a NON-uniform row every slot resolves to a
        // non-nil family by construction (some slot is named, so the chain's fallback is non-nil for
        // all seven), so a `nil` family on this path can ONLY mean nothing classified.
        if pieces.len() == 1 && pieces[0].family.is_none() {
            span.font_name = fonts.neutral_family().map(SwiftString::from);
            return vec![span];
        }
        pieces
            .into_iter()
            .enumerate()
            .map(|(index, piece)| {
                let mut out = span.clone();
                out.text = SwiftString::from(piece.text.to_string());
                out.font_name = piece.family.map(SwiftString::from);
                // The anchor is a POINT in the document, not a property of the text, so it rides the
                // first piece alone — copying it onto every piece would publish the same bookmark name
                // several times and give an internal link more than one place to land.
                if index > 0 { out.bookmarks = Vec::new(); }
                // Same reason, and the same shape: the field is ONE substitution site. Left on every
                // piece, a page number that happened to split would be replaced once per piece and draw
                // "33" on page 3. (Digits are one script, so this is a guard, not a path taken today.)
                if index > 0 { out.page_number_field = None; }
                out
            })
            .collect()
    }

    /// The char shape's decorations that this reader draws — and only those. The rest of the
    /// sixteen are decoded and left alone; `HwpCharDecorProbeTests` measured all of them over 1,589
    /// real documents and invariant 97 carries the table that decided which is which.
    ///
    /// The per-script values are applied ONLY when the document's seven slots agree. A span carries
    /// one letter spacing, so honouring a shape whose Hangul and Latin ask for different values
    /// would mean applying one script's answer to the other — measured, the slots agree on 95.9% of
    /// the char shapes that state a spacing at all, and the remaining 4.1% keep the font's own.
    // swift: Render/Office/HwpReader.swift:1007-1028
    fn apply_decor(d: Option<&HwpCharDecor>, span: &mut Span) {
        let Some(d) = d else { return };
        if let Some(v) = Self::uniform_value(d.spacings.as_deref()) {
            if v != 0 { span.letter_spacing_percent = Some(v as CGFloat); }
        }
        if let Some(v) = Self::uniform_value(d.char_offsets.as_deref()) {
            if v != 0 { span.baseline_offset_percent = Some(v as CGFloat); }
        }
        if let Some(c) = &d.underline_color { span.underline_color = Self::color(Some(c)); }
        if let Some(c) = &d.strike_color { span.strikethrough_color = Self::color(Some(c)); }
        // 음영 is a background painted behind the glyphs — the same thing `highlightColor` already
        // carries for docx's highlighter, so it reuses that rather than growing a second attribute
        // that would paint the same pixels.
        if span.highlight_color.is_none() {
            if let Some(c) = &d.shade_color { span.highlight_color = Self::color(Some(c)); }
        }
    }
}

impl HwpReader {
    // swift: Render/Office/HwpReader.swift:1029-1033
    pub fn uniform_value(slots: Option<&[i64]>) -> Option<i64> {
        let slots = slots?;
        if slots.len() != 7 { return None; }
        let first = *slots.first()?;
        if slots.iter().all(|v| *v == first) { Some(first) } else { None }
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
    // swift: Render/Office/HwpReader.swift:1034-1050
    fn max_run_size(spans: &[HwpSpan]) -> Option<CGFloat> {
        // Same conversion `mapSpan` applies to `Span.fontSize` (base_size in HWPUNIT, ÷100 = points),
        // so the basis a line is spaced by is the size that line is actually drawn at.
        spans
            .iter()
            .filter_map(|s| s.size.and_then(|v| if v > 0 { Some(v as CGFloat / 100.0) } else { None }))
            .fold(None, |acc, v| Some(acc.map_or(v, |a: CGFloat| a.max(v))))
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
    // swift: Render/Office/HwpReader.swift:1051-1089
    fn boxed_format(format: &ParagraphFormat, p: &HwpPara, shapes: &MediaContext) -> ParagraphFormat {
        let (Some(paper), Some(owner)) = (&shapes.paper, shapes.last_anchored_frame) else { return format.clone() };
        let (Some(bx), Some(bw)) = (p.box_x, p.box_w) else { return format.clone() };
        if bw <= 0 { return format.clone(); }
        let column = (paper.margin_left, paper.content_width);
        if !(column.1 > 0.0) { return format.clone(); }
        let box_left = owner.origin.x + Self::points(bx);
        let box_width = Self::points(bw);
        let start = (box_left - column.0).max(0.0);
        let end = (column.1 - start - box_width).max(0.0);
        // Below this the "box" is telling us something we cannot draw — a coordinate we misread, or a
        // box that genuinely sits outside the body column. Flowing at full width is wrong but legible;
        // a 40pt column is neither.
        if !(column.1 - start - end >= column.1 * 0.25) { return format.clone(); }
        let mut f = format.clone();
        f.indent_start = Some(start);
        f.indent_end = Some(end);
        f
    }
}

use crate::render::office::office_block::LineHeight;

impl HwpReader {
    // swift: Render/Office/HwpReader.swift:1090-1178
    fn paragraph_format(p: &HwpPara, default_body_size: CGFloat, paged: bool) -> ParagraphFormat {
        let mut f = ParagraphFormat::default();
        f.spacing_before = Self::non_zero_points(p.space_before);
        f.spacing_after = Self::non_zero_points(p.space_after);
        f.indent_start = Self::non_zero_points(p.indent_start);
        f.indent_end = Self::non_zero_points(p.indent_end);
        // firstLine indent is mutually exclusive with hanging (mirrors docx `w:firstLine`/`w:hanging`
        // and ODF's signed `fo:text-indent`): a positive value is a first-line indent, a negative
        // one is a hanging indent expressed as its magnitude.
        if let Some(fi) = p.indent_first {
            if fi != 0 {
                // first-line/hanging indent is also a 2×-stored paragraph metric → ÷200 (see nonZeroPoints).
                if fi > 0 {
                    f.first_line_indent = Some(fi as CGFloat / 200.0);
                } else {
                    f.hanging_indent = Some(-fi as CGFloat / 200.0);
                }
            }
        }
        if let Some(lh) = &p.line_height {
            if lh.value > 0 {
                match lh.r#type.as_str() {
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
                    "percent" => {
                        if let Some(percent) = Self::percent_line_height(lh.value) {
                            if paged {
                                let basis = Self::max_run_size(&p.spans)
                                    .or(p.base_size_pt)
                                    .unwrap_or(default_body_size);
                                f.line_height = Some(LineHeight::AtLeast(basis * percent / 100.0));
                            } else if (percent - Self::NEUTRAL_PERCENT_LINE_HEIGHT).abs() > 0.5 {
                                f.line_height = Some(LineHeight::AtLeast(default_body_size * percent / 100.0));
                            }
                        }
                    }
                    // Author-chosen ABSOLUTE line heights are honoured in both models; HWP5 stores these
                    // 2× → ÷200 (see `nonZeroPoints`).
                    "at_least" => { f.line_height = Some(LineHeight::AtLeast(lh.value as CGFloat / 200.0)); }
                    "fixed" => { f.line_height = Some(LineHeight::Exact(lh.value as CGFloat / 200.0)); }
                    _ => {}
                }
            }
        }
        // Zero is a REAL value in both codes (break between words), so the export sends it rather
        // than omitting it the way it omits every other default — see `document_json.rs`. An absent
        // key therefore means a parser predating that export, and the reader leaves its own line
        // breaking alone rather than reading silence as a setting.
        f.east_asian_line_break = p.korean_break_unit.and_then(Self::hangul_break);
        f.latin_line_break = p.english_break_unit.and_then(Self::latin_break);
        f.auto_space_east_asian_latin = p.auto_space_kr_en;
        f.auto_space_east_asian_number = p.auto_space_kr_num;
        f.line_height_from_font_metrics = p.font_line_height;
        f
    }
}

impl HwpReader {
    /// HWP's two line-break codes, in this reader's vocabulary. The export omits a zero, so a
    /// paragraph that never states one decodes to `nil` and the reader's own default stands — which
    /// is why "unstated" and "stated as 0" are deliberately NOT collapsed here.
    // swift: Render/Office/HwpReader.swift:1179-1185
    pub fn hangul_break(code: i64) -> Option<LineBreakGranularity> {
        match code {
            0 => Some(LineBreakGranularity::Word),
            1 => Some(LineBreakGranularity::Character),
            _ => None,
        }
    }

    /// HWP's three page-break answers for a table, in this reader's vocabulary. An unknown string
    /// is not guessed at — a parser that grows a fourth answer should read as "said nothing" rather
    /// than as whichever case happened to be the default here.
    // swift: Render/Office/HwpReader.swift:1186-1198
    pub fn table_page_break_policy(raw: &str) -> Option<TablePageBreakPolicy> {
        match raw {
            "none" => Some(TablePageBreakPolicy::Never),
            "row" => Some(TablePageBreakPolicy::AtRowBoundary),
            "cell" => Some(TablePageBreakPolicy::Anywhere),
            _ => None,
        }
    }

    // swift: Render/Office/HwpReader.swift:1199-1206
    pub fn latin_break(code: i64) -> Option<LineBreakGranularity> {
        match code {
            0 => Some(LineBreakGranularity::Word),
            1 => Some(LineBreakGranularity::Hyphen),
            2 => Some(LineBreakGranularity::Character),
            _ => None,
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
    // swift: Render/Office/HwpReader.swift:1207-1271
    pub fn heading_level(style_name: Option<&str>, local_name: Option<&str>) -> Option<i64> {
        // "Outline 1"…"Outline 7" / "개요 1"…"개요 7" — the level is the trailing digit.
        fn level(name: &str) -> Option<i64> {
            let n = name.trim().to_lowercase();
            for prefix in ["outline", "개요", "heading", "제목 수준"] {
                if let Some(rest) = n.strip_prefix(prefix) {
                    let rest = rest.trim();
                    if let Ok(digit) = rest.parse::<i64>() {
                        if (1..=7).contains(&digit) { return Some(digit); }
                    }
                    if rest.is_empty() { return Some(1); }
                }
            }
            // A document title is the shallowest heading there is.
            if n == "title" || n == "제목" { return Some(1); }
            None
        }
        /// Korean documents overwhelmingly name their own styles rather than using the built-ins —
        /// measured on real files: "각 장 제목" / "각 절 제목" (chapter/section title),
        /// "목차,발간사 제목". Those ARE headings and were being dropped. But the same corpus also
        /// carries "표의 제목" (a TABLE's caption, 112 occurrences in one document) and "그림"
        /// (figure) — promoting those would bury a real outline under captions, which is worse than
        /// no outline at all. So: a name must SAY title/chapter/section, and must not be about a
        /// table, figure, footnote or running head. Depth comes from the word used (장 chapter → 1,
        /// 절 section → 2, 항 clause → 3), defaulting to 1.
        fn custom_level(name: &str) -> Option<i64> {
            let n = name.trim();
            // `목차` earns its place in this list by measurement, not theory: one real document styles
            // its table-of-contents ENTRIES with "목차,발간사 제목", so accepting it turned 40-odd
            // contents lines and body sentences into headings — an outline made of the outline.
            let excluded = ["표", "그림", "캡션", "각주", "미주", "머리말", "꼬리말", "쪽번호", "번호", "목차"];
            if !n.contains("제목") { return None; }
            for word in excluded {
                if n.contains(word) { return None; }
            }
            if n.contains('장') { return Some(1); }
            if n.contains('절') { return Some(2); }
            if n.contains('항') { return Some(3); }
            Some(1)
        }
        if let Some(sn) = style_name { if let Some(l) = level(sn) { return Some(l); } }
        if let Some(ln) = local_name { if let Some(l) = level(ln) { return Some(l); } }
        if let Some(ln) = local_name { if let Some(l) = custom_level(ln) { return Some(l); } }
        if let Some(sn) = style_name { if let Some(l) = custom_level(sn) { return Some(l); } }
        None
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
    // swift: Render/Office/HwpReader.swift:1272-1279
    pub fn relative_graphic_size(w: i64, h: i64, criterion: Option<&str>, page_width: Option<CGFloat>) -> Option<CGSize> {
        let criterion = criterion?;
        if criterion == "absolute" { return None; }
        let page_width = page_width?;
        if !(page_width > 0.0) || !(w > 0) { return None; }
        let share = w as CGFloat / 10_000.0;
        if !(share > 0.0) || !(share <= 10.0) { return None; } // a nonsense share is not applied
        let width = page_width * share;
        let aspect = if w > 0 { h as CGFloat / w as CGFloat } else { 0.0 };
        Some(CGSize { width, height: (width * aspect).round() })
    }

    /// The alignment HWP stored on the picture itself. `inside`/`outside` are page-relative (mirror
    /// margins) and have no meaning in a single continuous reading column, so they are reported as
    /// nil — the reader's default — rather than being flattened to left, which would state something
    /// the document did not.
    // swift: Render/Office/HwpReader.swift:1280-1293
    pub fn image_alignment(raw: Option<&str>) -> Option<NSTextAlignment> {
        match raw {
            Some("left") => Some(NSTextAlignment::Left),
            Some("center") => Some(NSTextAlignment::Center),
            Some("right") => Some(NSTextAlignment::Right),
            _ => None,
        }
    }
}

use crate::render::office::office_block::{
    TabStop, TabAlignment, TableFormat, EdgePadding, ListNumbering, ListNumberingGlyphs,
};
use crate::render::office::hwp_reader::schema::{HwpTable, HwpShape, HwpUnsupported, HwpEquation};

impl HwpReader {
    // swift: Render/Office/HwpReader.swift:1294-1538
    fn map_block(
        b: &HwpBlock, page_width: Option<CGFloat>, default_body_size: CGFloat,
        slot_fonts: &[HwpSlotFonts], border_fills: &[HwpBorderFill], shapes: &mut MediaContext, paged: bool,
    ) -> OfficeBlock {
        match b {
            HwpBlock::Para(p) => {
                let spans: Vec<Span> = p.spans.iter().flat_map(|s| Self::map_span(s, slot_fonts)).collect();
                let align = Self::alignment(p.align.as_deref());
                let base = Self::paragraph_format(p, default_body_size, paged);
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
                let tab_stops: Vec<TabStop> = p.tab_stops.clone().unwrap_or_default().into_iter()
                    .filter_map(|stop| {
                        let position = Self::points(stop.pos_hwp_unit);
                        if !(position > 0.0) { return None; }
                        let alignment = match stop.kind.as_deref().unwrap_or("") {
                            "right" => TabAlignment::Right,
                            "center" => TabAlignment::Center,
                            "decimal" => TabAlignment::Decimal,
                            _ => TabAlignment::Left,
                        };
                        Some(TabStop { position, alignment, leader: Self::tab_leader(stop.fill_type) })
                    })
                    .collect();
                let format = Self::boxed_format(&base, p, shapes);
                // An EXPLICIT outline paragraph is a heading because the document said so — no second
                // guessing. A STYLE-derived one is an inference, so it also has to look like a heading:
                // non-empty, and short enough to be a label rather than a sentence. Measured need — one
                // document applies its "…제목" style to running body text, which produced 80-character
                // "headings" in the table of contents. `headingTextLimit` is generous on purpose (Korean
                // section titles run long); it only rejects prose.
                if let Some(explicit) = p.heading {
                    return OfficeBlock::Heading {
                        level: explicit, spans, rtl: false, alignment: align, tab_stops: Vec::new(), format,
                    };
                }
                if let Some(inferred) = Self::heading_level(p.style_name.as_deref(), p.style_local_name.as_deref()) {
                    let text: String = spans.iter().map(|s| s.text.to_string()).collect::<String>()
                        .trim().to_string();
                    if !text.is_empty() && text.chars().count() <= Self::HEADING_TEXT_LIMIT {
                        return OfficeBlock::Heading {
                            level: inferred, spans, rtl: false, alignment: align, tab_stops: Vec::new(), format,
                        };
                    }
                }
                if let Some(list) = &p.list {
                    let mut format = format;
                    // The document's own gap between a marker and its text. `ordered` picks which of the
                    // two the level actually has — a numbered head and a bullet are the same fact in two
                    // records, and a level is one or the other.
                    let raw = if list.ordered { list.numbering_head_text_distance } else { list.bullet_text_distance };
                    if let Some(raw) = raw {
                        if raw > 0 { format.list_text_distance = Some(Self::points(raw)); }
                    }
                    return OfficeBlock::ListItem {
                        level: list.level, ordered: list.ordered, spans,
                        marker: list.marker.clone().map(SwiftString::from),
                        rtl: false, alignment: align, tab_stops, format,
                        numbering: Some(ListNumbering {
                            glyphs: Self::list_numbering_glyphs(list.number_format.as_deref().unwrap_or("")),
                            start_number: list.start_number,
                        }),
                    };
                }
                OfficeBlock::Paragraph { spans, rtl: false, alignment: align, tab_stops, format }
            }
            HwpBlock::Table(t) => {
                let rows: Vec<Vec<_>> = t.rows.iter()
                    .map(|row| row.iter()
                        .map(|c| Self::map_cell(c, page_width, default_body_size, slot_fonts, border_fills, shapes, paged))
                        .collect())
                    .collect();
                // colWidths as ABSOLUTE INTEGER-derived points, never percentages (invariant 39/42).
                let column_widths: Vec<CGFloat> = t.col_widths.iter().map(|w| Self::points(*w)).collect();
                // The table's own width as HWP laid it out (points), so a picture in a cell scales against
                // the TABLE rather than the page — identical treatment to docx (`TableFormat.sourceWidth`),
                // no HWP-specific layout path. Zero/absent widths → nil → the page basis, as before.
                let mut format = TableFormat::default();
                let source_width: CGFloat = column_widths.iter().sum();
                if source_width > 0.0 { format.source_width = Some(source_width); }
                // A table's own border-fill is its BACKGROUND, not a box around the grid: rhwp's renderer
                // hands the table's fill to `render_cell_background` and to nothing else
                // (`layout/table_cell_content.rs:529`), and every rule on screen comes from the CELL
                // fills. So the id becomes shading here and never a border — see invariant 74 for the
                // measurement that corrected the opposite assumption.
                let table_fill = Self::border_fill(t.border_fill_id, border_fills);
                format.default_shading = table_fill.and_then(|f| Self::color(f.bg.as_deref()));
                // A PICTURE fill on the table is one image behind the whole grid — the rounded box a
                // Korean document draws around an annotation. Painted once by `GridTextTable`, never
                // repeated per cell, which is what turns one frame into a wall of frames.
                format.background_image = shapes.fill_image(table_fill.and_then(|f| f.bg_image))
                    .or_else(|| Self::gradient_image(table_fill.and_then(|f| f.bg_gradient.as_ref())));
                // A single-stop gradient is a plain fill, and one that could not be drawn still reads
                // closer to the document as its first colour than as blank paper.
                if format.default_shading.is_none() && format.background_image.is_none() {
                    if let Some(stops) = table_fill.and_then(|f| f.bg_gradient.as_ref()).map(|g| &g.colors) {
                        if !stops.is_empty() { format.default_shading = Self::color(Some(&stops[0])); }
                    }
                }
                // The AUTHOR's own repeating header rows. Inventing "row one is a header" was the
                // alternative and it bolds ordinary text; taking the document's mark costs nothing and
                // is the only way a table that crosses a page keeps its column labels on page two.
                format.repeat_header_rows = t.repeat_header;
                format.page_break_policy = t.page_break.as_deref().and_then(Self::table_page_break_policy);
                // The table OBJECT's own outer margin — the gap to what surrounds it, not a cell's
                // padding. Left `nil` (the whole `EdgePadding`, not just its fields) when the source
                // declared none of the four, so a table with no outer margin at all costs nothing.
                let outer_margin = EdgePadding {
                    top: Self::extent_points(t.outer_margin_top),
                    left: Self::extent_points(t.outer_margin_left),
                    bottom: Self::extent_points(t.outer_margin_bottom),
                    right: Self::extent_points(t.outer_margin_right),
                };
                if outer_margin.top.is_some() || outer_margin.left.is_some()
                    || outer_margin.bottom.is_some() || outer_margin.right.is_some() {
                    format.outer_margin = Some(outer_margin);
                }
                OfficeBlock::Table {
                    rows, header_rows: t.header_rows.unwrap_or(0).max(0), column_widths, format,
                }
            }
            HwpBlock::Image(im) => Self::map_image_block(im, page_width, shapes),
            HwpBlock::Shape(sh) => Self::map_shape_block(sh, shapes),
            HwpBlock::Unsupported(u) => OfficeBlock::UnsupportedGraphic {
                label: SwiftString::from(u.label.clone()),
                size: CGSize { width: Self::points(u.w), height: Self::points(u.h) },
                alignment: None,
            },
            HwpBlock::Equation(e) => {
                // rhwp now hands us real LaTeX; route it to the SAME `.formula` case a Word `m:oMathPara`
                // becomes, so `OfficeTextBuilder` renders it through the app's formula engine with no
                // HWP-specific path (invariant: office `.formula` rides the markdown `$$…$$` web-block
                // pipeline). `w`/`h` are advisory only — the formula engine sizes from the rendered LaTeX.
                let latex = e.latex.trim().to_string();
                if !latex.is_empty() { return OfficeBlock::Formula { latex: SwiftString::from(latex) }; }
                // Empty/whitespace latex → an honest placeholder, NEVER an empty formula (mirrors
                // DocxReader.formulaBlock's never-nothing ladder). rhwp already degrades a parse failure
                // to `unsupported`; this guards the residual "equation block with nothing translatable".
                OfficeBlock::UnsupportedGraphic {
                    label: SwiftString::from("equation".to_string()),
                    size: CGSize { width: Self::points(e.w.unwrap_or(0)), height: Self::points(e.h.unwrap_or(0)) },
                    alignment: None,
                }
            }
        }
    }

    // swift: Render/Office/HwpReader.swift:1408-1471 (the `.image` arm, split out for one level less nesting)
    fn map_image_block(im: &HwpImage, page_width: Option<CGFloat>, shapes: &mut MediaContext) -> OfficeBlock {
        // `read` resolves binDataId → pixels via `imageBase64` at read time (pre-decoded into
        // OfficeReadResult.images); the block only RESERVES the layout area here (invariant
        // 1/2/11). id is the stable key `collectImages`/`reconcileMedia` look the bytes up by.
        // `w`/`h` are absolute HWPUNIT ONLY when the document says so. A relative criterion
        // (paper/page/column/para) stores a share in ten-thousandths instead, which converted as
        // if it were HWPUNIT yields a picture hundreds of points wide — so a non-absolute width is
        // resolved against the page body width the same read already carries. `page`/`paper` both
        // resolve against it here (we have no separate paper measure at this layer), and
        // `column`/`para` against the same width, since this reader lays out a single column.
        let declared = CGSize { width: Self::points(im.w), height: Self::points(im.h) };
        let size = Self::relative_graphic_size(im.w, im.h, im.width_criterion.as_deref(), page_width)
            .unwrap_or(declared);
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
        if im.as_char != Some(true) && im.wraps_text != Some(true) {
            if let Some(paper) = shapes.paper.clone() {
                if let Some(image) = shapes.picture.as_ref().and_then(|f| f(im.bin_data_id))
                    .and_then(|bytes| swiftshim::NSImage::fromData(&bytes)) {
                    let offset = CGPoint {
                        x: Self::points(im.offset_x.unwrap_or(0)),
                        y: Self::points(im.offset_y.unwrap_or(0)),
                    };
                    if let Some(frame) = Self::anchored_frame(
                        size, im.vert_rel_to.as_deref().unwrap_or("para"), im.horz_rel_to.as_deref().unwrap_or("para"),
                        im.vert_align.as_deref().unwrap_or("top"), im.horz_align.as_deref().unwrap_or("left"),
                        offset, &paper,
                    ) {
                        shapes.last_anchored_frame = Some(frame);
                        shapes.anchored.push(OfficeAnchoredObject {
                            block_index: shapes.block_index as i64,
                            object: OfficeMasterObject { frame, content: OfficeMasterObjectContent::Image(image) },
                            paragraph_anchor: None,
                        });
                        return OfficeBlock::Paragraph {
                            spans: Vec::new(), rtl: false, alignment: None, tab_stops: Vec::new(),
                            format: ParagraphFormat::default(),
                        };
                    }
                }
            }
        }
        // PINNED TO ITS PARAGRAPH — a 도장 over a signature line, which is what a scanned seal in
        // a Korean contract IS. The drawing branch below has had this since invariant 81; the
        // picture branch never did, so a seal fell into the flow at its paragraph's own left
        // edge and BOTH its offsets were discarded. Measured on a real contract: the seal
        // declares 어울림 없음 at column + 285.9pt, 155.3pt below its line, and was drawn at the
        // body's own margin instead — 264pt to the left of where the document puts it, on a page
        // where the signature block it belongs to is the whole point.
        if im.as_char != Some(true) && im.wraps_text != Some(true) {
            if let Some(paper) = shapes.paper.clone() {
                if let Some(image) = shapes.picture.as_ref().and_then(|f| f(im.bin_data_id))
                    .and_then(|bytes| swiftshim::NSImage::fromData(&bytes)) {
                    let offset = CGPoint {
                        x: Self::points(im.offset_x.unwrap_or(0)),
                        y: Self::points(im.offset_y.unwrap_or(0)),
                    };
                    if let Some((frame, anchor)) = Self::paragraph_anchored_placement(
                        size, im.vert_rel_to.as_deref().unwrap_or("para"), im.horz_rel_to.as_deref().unwrap_or("para"),
                        im.vert_align.as_deref().unwrap_or("top"), im.horz_align.as_deref().unwrap_or("left"),
                        offset, &paper,
                    ) {
                        shapes.last_anchored_frame = Some(frame);
                        shapes.anchored.push(OfficeAnchoredObject {
                            block_index: shapes.block_index as i64,
                            object: OfficeMasterObject { frame, content: OfficeMasterObjectContent::Image(image) },
                            paragraph_anchor: Some(anchor),
                        });
                        return OfficeBlock::Paragraph {
                            spans: Vec::new(), rtl: false, alignment: None, tab_stops: Vec::new(),
                            format: ParagraphFormat::default(),
                        };
                    }
                }
            }
        }
        OfficeBlock::Image {
            id: SwiftString::from(format!("{}{}{}", Self::HWP_IMAGE_PREFIX, im.bin_data_id, Self::crop_suffix(im))),
            size,
            alignment: Self::image_alignment(im.align.as_deref()),
        }
    }

    // swift: Render/Office/HwpReader.swift:1472-1521 (the `.shape` arm, split out for one level less nesting)
    fn map_shape_block(sh: &HwpShape, shapes: &mut MediaContext) -> OfficeBlock {
        // An ANCHORED drawing is placed by the document's own rule — the offsets ALONE are not
        // enough, and that is exactly what the float layer invariant 75 rejected got wrong: it
        // guessed the reference edge and laid a 431pt rule over a table's own column label.
        // `vert_align`/`horz_align` say which edge the offset is measured from (invariant 81),
        // so with those exported, a paper-, page- or paragraph-anchored drawing lands where the
        // document put it. A PICTURE is still never floated — see the `.image` case above for
        // the 451→436 measurement that decided it.
        let paths: Vec<_> = sh.paths.iter().filter_map(|p| Self::shape_path(p)).collect();
        let mut size = CGSize { width: Self::points(sh.w), height: Self::points(sh.h) };
        if size.width < 1.0 || size.height < 1.0 {
            if let Some(extent) = Self::paths_extent(&paths) { size = extent; }
        }
        let offset = CGPoint {
            x: Self::points(sh.offset_x.unwrap_or(0)),
            y: Self::points(sh.offset_y.unwrap_or(0)),
        };
        // PINNED TO THE PAPER — a cover's decoration, a rule down a margin. Placed by the
        // document's own rule (`anchoredFrame`) and drawn on the sheet the anchoring block falls
        // on, rather than pushed into the text where inlining one cost 29 pages (invariant 75).
        if sh.as_char != Some(true) && sh.wraps_text != Some(true) {
            if let Some(paper) = shapes.paper.clone() {
                if let Some(frame) = Self::anchored_frame(
                    size, sh.vert_rel_to.as_deref().unwrap_or("para"), sh.horz_rel_to.as_deref().unwrap_or("para"),
                    sh.vert_align.as_deref().unwrap_or("top"), sh.horz_align.as_deref().unwrap_or("left"),
                    offset, &paper,
                ) {
                    if let Some(pdf) = HwpShapeRenderer::pdf(&paths, size) {
                        shapes.last_anchored_frame = Some(frame);
                        shapes.anchored.push(OfficeAnchoredObject {
                            block_index: shapes.block_index as i64,
                            object: OfficeMasterObject { frame, content: OfficeMasterObjectContent::Drawing(pdf) },
                            paragraph_anchor: None,
                        });
                        return OfficeBlock::Paragraph {
                            spans: Vec::new(), rtl: false, alignment: None, tab_stops: Vec::new(),
                            format: ParagraphFormat::default(),
                        };
                    }
                }
            }
        }
        // PINNED TO ITS PARAGRAPH — a seal over a signature line, an arrow onto the table beside
        // it. Only the horizontal half can be settled here; the vertical one is finished by the
        // draw pass, which is the only place that knows where the anchoring line ended up.
        if sh.as_char != Some(true) && sh.wraps_text != Some(true) {
            if let Some(paper) = shapes.paper.clone() {
                if let Some((frame, anchor)) = Self::paragraph_anchored_placement(
                    size, sh.vert_rel_to.as_deref().unwrap_or("para"), sh.horz_rel_to.as_deref().unwrap_or("para"),
                    sh.vert_align.as_deref().unwrap_or("top"), sh.horz_align.as_deref().unwrap_or("left"),
                    offset, &paper,
                ) {
                    if let Some(pdf) = HwpShapeRenderer::pdf(&paths, size) {
                        shapes.last_anchored_frame = Some(frame);
                        shapes.anchored.push(OfficeAnchoredObject {
                            block_index: shapes.block_index as i64,
                            object: OfficeMasterObject { frame, content: OfficeMasterObjectContent::Drawing(pdf) },
                            paragraph_anchor: Some(anchor),
                        });
                        return OfficeBlock::Paragraph {
                            spans: Vec::new(), rtl: false, alignment: None, tab_stops: Vec::new(),
                            format: ParagraphFormat::default(),
                        };
                    }
                }
            }
        }
        if sh.as_char != Some(true) {
            return OfficeBlock::Paragraph {
                spans: Vec::new(), rtl: false, alignment: None, tab_stops: Vec::new(),
                format: ParagraphFormat::default(),
            };
        }
        let Some(pdf) = HwpShapeRenderer::pdf(&paths, size) else {
            return OfficeBlock::Paragraph {
                spans: Vec::new(), rtl: false, alignment: None, tab_stops: Vec::new(),
                format: ParagraphFormat::default(),
            };
        };
        OfficeBlock::Image { id: SwiftString::from(shapes.add(pdf)), size, alignment: Self::image_alignment(sh.align.as_deref()) }
    }

    /// `ListNumbering.Glyphs(rawValue:) ?? .decimal` — a Swift `String`-backed enum's raw values,
    /// restated as a match since `ListNumberingGlyphs` (office_block.rs) carries no `FromStr`/
    /// raw-value constructor of its own.
    fn list_numbering_glyphs(raw: &str) -> ListNumberingGlyphs {
        match raw {
            "decimal" => ListNumberingGlyphs::Decimal,
            "circledDecimal" => ListNumberingGlyphs::CircledDecimal,
            "romanUpper" => ListNumberingGlyphs::RomanUpper,
            "romanLower" => ListNumberingGlyphs::RomanLower,
            "latinUpper" => ListNumberingGlyphs::LatinUpper,
            "latinLower" => ListNumberingGlyphs::LatinLower,
            "hangulSyllable" => ListNumberingGlyphs::HangulSyllable,
            "hangulNumber" => ListNumberingGlyphs::HangulNumber,
            "hanjaNumber" => ListNumberingGlyphs::HanjaNumber,
            _ => ListNumberingGlyphs::Decimal,
        }
    }
}

use crate::render::office::office_block::{Cell, CellVAlign, BorderSide};

impl HwpReader {
    // swift: Render/Office/HwpReader.swift:1539-1589
    fn map_cell(
        c: &HwpCell, page_width: Option<CGFloat>, default_body_size: CGFloat,
        slot_fonts: &[HwpSlotFonts], border_fills: &[HwpBorderFill], shapes: &mut MediaContext, paged: bool,
    ) -> Cell {
        let blocks: Vec<OfficeBlock> = c.blocks.iter()
            .map(|b| Self::map_block(b, page_width, default_body_size, slot_fonts, border_fills, shapes, paged))
            .collect();
        // "top" is Word/HWP's own default → nil, so a cell that only ever says "top" renders
        // byte-identical to one that says nothing (Cell.verticalAlignment's contract); only an
        // explicit center/bottom is carried.
        let v_align = match c.v_align.as_deref() {
            Some("center") => Some(CellVAlign::Center),
            Some("bottom") => Some(CellVAlign::Bottom),
            _ => None, // "top" / null / unknown → unspecified default
        };
        // The cell's own four-edge inner margin, ALREADY resolved by rhwp's
        // `Cell::effective_padding` (the `aim` flag, the table-wide fallback and the preserved-pad
        // hygiene limit, all measured against Hancom's own PDFs) — so the rule lives in ONE place and
        // this reader does not invent a second one. Before this existed HWP declared no padding at
        // all and every cell fell to `TableBlockBuilder.defaultCellPadding` (7pt on all four edges):
        // measured on a real 490-page 편람, that invented number alone made the document 66 pages
        // longer than the official viewer's 429. Invariant 57(a)'s failure, in a fourth place.
        //
        // A parser predating this field decodes as nil and behaves exactly as before.
        let edges: Option<EdgePadding> = if c.pad_left.is_some() || c.pad_right.is_some()
            || c.pad_top.is_some() || c.pad_bottom.is_some()
        {
            Some(EdgePadding {
                top: c.pad_top.map(|v| v as CGFloat),
                left: c.pad_left.map(|v| v as CGFloat),
                bottom: c.pad_bottom.map(|v| v as CGFloat),
                right: c.pad_right.map(|v| v as CGFloat),
            })
        } else {
            None
        };
        // The cell's own four edges and background, resolved from the id it carries. Before this the
        // id arrived and resolved to nothing, so EVERY HWP table was ruled with the reader's theme
        // grid — including the layout tables a Korean document uses to place things, whose borders it
        // had deliberately turned off (measured: 423 of the 편람's 821 definitions are all-off).
        let fill = Self::border_fill(c.border_fill_id, border_fills);
        let mut shading = fill.and_then(|f| Self::color(f.bg.as_deref()));
        let fill_image = shapes.fill_image(fill.and_then(|f| f.bg_image))
            .or_else(|| Self::gradient_image(fill.and_then(|f| f.bg_gradient.as_ref())));
        if shading.is_none() && fill_image.is_none() {
            if let Some(stops) = fill.and_then(|f| f.bg_gradient.as_ref()).map(|g| &g.colors) {
                if !stops.is_empty() { shading = Self::color(Some(&stops[0])); }
            }
        }
        Cell {
            blocks, row_span: c.row_span, col_span: c.col_span,
            background_color: shading,
            background_image: fill_image,
            border_color: None,
            border_width: None,
            edge_borders: Self::edge_borders(c.border_fill_id, border_fills),
            width: None,
            vertical_alignment: v_align,
            padding: None,
            edge_padding: edges,
            diagonal: Self::cell_diagonal(fill),
            style_shading: None,
            style_border_color: None,
            style_border_width: None,
        }
    }

    /// One exported path → the renderer's own vocabulary, converting HWPUNIT to points as it goes.
    /// A command whose operator or arity this reader does not recognise is DROPPED rather than
    /// guessed at — a mis-read control point draws a line across the page, which is worse than a
    /// missing segment.
    // swift: Render/Office/HwpReader.swift:1590-1620
    fn shape_path(p: &HwpShapePath) -> Option<crate::render::office::hwp_shape_path::PathSpec> {
        use crate::render::office::hwp_shape_path::{PathCommand, PathSpec};
        let mut commands: Vec<PathCommand> = Vec::new();
        for token in &p.d {
            let numbers: Vec<CGFloat> = token.iter().filter_map(|v| v.value()).map(|v| v as CGFloat / 100.0).collect();
            match (token.first().and_then(|t| t.name()).unwrap_or_default(), numbers.len()) {
                ("M", 2) => commands.push(PathCommand::Move(CGPoint { x: numbers[0], y: numbers[1] })),
                ("L", 2) => commands.push(PathCommand::Line(CGPoint { x: numbers[0], y: numbers[1] })),
                ("C", 6) => commands.push(PathCommand::Curve(
                    CGPoint { x: numbers[0], y: numbers[1] },
                    CGPoint { x: numbers[2], y: numbers[3] },
                    CGPoint { x: numbers[4], y: numbers[5] },
                )),
                ("Z", _) => commands.push(PathCommand::Close),
                _ => continue,
            }
        }
        if commands.is_empty() { return None; }
        let stroke: Option<BorderSide> = p.stroke.as_ref().map(|s| BorderSide {
            width: s.width_pt.unwrap_or(0.5) as CGFloat,
            color: Some(Self::color(s.color.as_deref()).unwrap_or(NSColor::srgb(0.0, 0.0, 0.0, 1.0))),
            style: Self::line_style(s.r#type.as_deref().unwrap_or("solid")),
        });
        Some(PathSpec {
            commands, stroke, fill: Self::color(p.fill.as_deref()),
            arrow_start: p.arrow_start.unwrap_or(false), arrow_end: p.arrow_end.unwrap_or(false),
        })
    }

    /// The box the paths themselves occupy — the fallback size for an object whose own record states
    /// none, so a drawing with real geometry is never collapsed to nothing.
    // swift: Render/Office/HwpReader.swift:1621-1637
    fn paths_extent(paths: &[crate::render::office::hwp_shape_path::PathSpec]) -> Option<CGSize> {
        use crate::render::office::hwp_shape_path::PathCommand;
        let (mut maxX, mut maxY, mut any) = (0.0 as CGFloat, 0.0 as CGFloat, false);
        for path in paths {
            for command in &path.commands {
                let points: Vec<CGPoint> = match command {
                    PathCommand::Move(p) | PathCommand::Line(p) => vec![*p],
                    PathCommand::Curve(a, b, c) => vec![*a, *b, *c],
                    PathCommand::Close => vec![],
                };
                for p in points { maxX = maxX.max(p.x); maxY = maxY.max(p.y); any = true; }
            }
        }
        if !any || !(maxX > 0.5) || !(maxY > 0.5) { return None; }
        Some(CGSize { width: maxX, height: maxY })
    }
}

impl HwpReader {
    // swift: Render/Office/HwpReader.swift:1638-1645
    fn border_fill<'a>(id: Option<i64>, fills: &'a [HwpBorderFill]) -> Option<&'a HwpBorderFill> {
        let id = id?;
        if id <= 0 { return None; }
        fills.get((id - 1) as usize)
    }

    /// A border-fill id → the four edges it declares. `nil` when no fill resolves (id absent, `0`,
    /// out of range, or a parser predating the export) → unchanged behaviour: the theme grid.
    ///
    /// Every resolved edge is a DECLARATION, never silence — HWP's fill states all four, so an edge
    /// this document turned off becomes `.suppressed` rather than nil. That distinction is the whole
    /// fix: nil would fall back through the cascade to the very border the document erased
    /// (invariant 47).
    // swift: Render/Office/HwpReader.swift:1646-1658
    fn edge_borders(id: Option<i64>, fills: &[HwpBorderFill]) -> Option<EdgeBorders> {
        let fill = Self::border_fill(id, fills)?;
        Some(EdgeBorders {
            top: Some(Self::border_decl(&fill.top)), left: Some(Self::border_decl(&fill.left)),
            bottom: Some(Self::border_decl(&fill.bottom)), right: Some(Self::border_decl(&fill.right)),
            ..Default::default()
        })
    }

    /// One exported edge → the reader's three-state declaration. `"none"` (the document switched the
    /// edge off) → `.suppressed`; anything else is a real rule at the width and colour the document
    /// gave. A width that failed to arrive falls back to the same 1pt the theme uses, so a malformed
    /// edge is still drawn rather than silently vanishing.
    // swift: Render/Office/HwpReader.swift:1659-1668
    fn border_decl(edge: &HwpBorderEdge) -> BorderDecl {
        if edge.r#type == "none" { return BorderDecl::Suppressed; }
        let width = edge.width_pt.filter(|w| *w > 0.0).unwrap_or(1.0);
        BorderDecl::Drawn(BorderSide { width, color: Self::color(edge.color.as_deref()), style: Self::line_style(&edge.r#type) })
    }

    /// A fill's DIAGONAL, when the parser resolved one. The direction is taken verbatim — an
    /// unrecognised string is treated as no diagonal rather than guessed into one, so a future
    /// parser value cannot make this reader draw something it does not understand.
    ///
    /// The line is drawn at the same width the four edges would use for that step. HWP stores a
    /// diagonal's width as its 16-step enum rather than resolved points (which is what an edge
    /// gets), so this reuses the edge's own resolved width when the document gave one and falls
    /// back to the 1pt every undeclared rule in this reader uses.
    // swift: Render/Office/HwpReader.swift:1669-1691
    fn cell_diagonal(fill: Option<&HwpBorderFill>) -> Option<CellDiagonal> {
        let fill = fill?;
        let raw = fill.cell_diagonal.as_deref()?;
        let direction = match raw {
            "slash" => crate::render::office::office_block::CellDiagonalDirection::Slash,
            "backslash" => crate::render::office::office_block::CellDiagonalDirection::Backslash,
            "both" => crate::render::office::office_block::CellDiagonalDirection::Both,
            _ => return None,
        };
        let style = fill.diagonal_type.map(|t| Self::line_style(&Self::hwp_line_type_name(t)))
            .unwrap_or(BorderLineStyle::Solid);
        let side = BorderSide {
            width: Self::diagonal_width_pt(fill.diagonal_width),
            color: Self::color(fill.diagonal_color.as_deref()),
            style,
        };
        Some(CellDiagonal { direction, side })
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
    // swift: Render/Office/HwpReader.swift:1692-1717
    fn tab_leader(fill_type: Option<i64>) -> TabLeader {
        match fill_type.unwrap_or(0) {
            0 => TabLeader::None,                 // 선 없음
            2 | 6 => TabLeader::Hyphen,            // 파선 · 긴 파선
            3 | 4 | 5 | 7 => TabLeader::Dot,        // 점선 · 쇄선 · 원형 파선
            _ => TabLeader::Underscore,             // 실선과 이중선·물결·3D 계열 — 이어진 선
        }
    }

    /// HWP's 16-step border-width enum → points. The same ladder the parser applies to an EDGE's
    /// width before exporting it as `widthPt`; a diagonal's width arrives raw, so the reader climbs
    /// the ladder itself here rather than shipping a diagonal at a width no document declared.
    /// Step 0 is 0.1mm — the finest line HWP can state, and never zero.
    // swift: Render/Office/HwpReader.swift:1718-1730
    fn diagonal_width_pt(step: Option<i64>) -> CGFloat {
        // 0.1 / 0.12 / 0.15 / 0.2 / 0.25 / 0.3 / 0.4 / 0.5 / 0.6 / 0.7 / 1.0 / 1.5 / 2.0 / 3.0 / 4.0 / 5.0 mm
        let mm: [CGFloat; 16] = [0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5,
                                  0.6, 0.7, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0];
        let idx = step.unwrap_or(0).clamp(0, mm.len() as i64 - 1) as usize;
        mm[idx] * 72.0 / 25.4
    }

    /// HWP's line-type CODE → the name the four edges arrive under, so one mapping table serves
    /// both. The parser exports an edge's type by name and a diagonal's by code; this is the bridge,
    /// and an unknown code stays `"solid"`, which is what an unrecognised edge does too.
    // swift: Render/Office/HwpReader.swift:1731-1753
    fn hwp_line_type_name(code: i64) -> String {
        match code {
            1 => "solid", 2 => "dash", 3 => "dot", 4 => "dashDot", 5 => "dashDotDot",
            6 => "longDash", 7 => "circle", 8 => "double", 9 => "thinThickDouble",
            10 => "thickThinDouble", 11 => "thinThickThinTriple", 12 => "wave", 13 => "doubleWave",
            _ => "solid",
        }.to_string()
    }

    /// HWP's 18-value line type (spec table 27, exported by name) → the four this reader paints.
    /// The dash family collapses to one dash and the multi-line family to `double`; `wave` and the
    /// four 3-D bevels have no honest match and stay `solid`, which is what they are made of.
    // swift: Render/Office/HwpReader.swift:1754-1766
    fn line_style(r#type: &str) -> BorderLineStyle {
        match r#type {
            "dash" | "dashDot" | "dashDotDot" | "longDash" => BorderLineStyle::Dashed,
            "dot" | "circle" => BorderLineStyle::Dotted,
            "double" | "thinThickDouble" | "thickThinDouble" | "thinThickThinTriple" | "doubleWave" =>
                BorderLineStyle::Double,
            _ => BorderLineStyle::Solid,
        }
    }
}
