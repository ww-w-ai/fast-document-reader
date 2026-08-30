//! swift: Render/Office/HwpReader.swift
//!
//! The Codable model mirroring rhwp's `{"v":1,"blocks":[…]}` schema — the SCHEMA half of the
//! HwpReader.swift split described in `mod.rs`. `mapping.rs` (the other half, owned by a
//! different worker) turns these into the format-neutral `OfficeBlock` vocabulary; nothing here
//! does that itself. Swift `Decodable` becomes `serde::Deserialize`; a Swift property list with
//! no explicit `CodingKeys` decodes against the SAME field names by default, which is what plain
//! `#[derive(Deserialize)]` does here too — the one place this file overrides that (`HwpSpan`'s
//! `super`/`sub` JSON keys) carries an explicit `#[serde(rename = …)]`, exactly mirroring the
//! Swift file's own explicit `CodingKeys` enum there.
//!
//! Swift `String` decodes here as plain Rust `String`, not `swiftshim::SwiftString` — these
//! fields are JSON payload the SAME as any other Decodable model reads, not text this file itself
//! indexes by UTF-16 offset (that indexing happens later, in `OfficeTextBuilder`, well outside
//! this range). `serde::Deserialize` cannot be implemented for a foreign shim type from this
//! crate either way (orphan rule) — schema.rs owns none of `swiftshim`.
//!
//! Visibility: every type in this range was Swift `private` (i.e. file-private — visible
//! anywhere in the ONE Swift file, including the `mapping.rs` half above line 1766) or, for the
//! two types Swift left at its default access level (`HwpCharDecor`, `HwpFontFace` — `internal`),
//! visible anywhere in the app module. Both collapse to the same Rust need here: `mapping.rs`
//! must be able to name every type in this file, so everything below is `pub(crate)`, matching
//! convention §3's `internal → pub(crate)` row for the whole range rather than Rust's stricter
//! module-private default.
//!
//! Field names are `snake_case` per convention §3's Swift→Rust table; the Swift property spelling
//! (`defaultFontSizePt`) is the JSON wire key, carried by `#[serde(rename = …)]` on every field —
//! convention's 「직렬화 키는 표기와 별개다」 rule. `swiftshim`'s `NSNotFound` is a different case
//! (a swiftshim type/const name, kept in Swift spelling because call sites type it directly) and
//! does not apply here. The two fields the SWIFT FILE ITSELF renames (`super`→`superscript`,
//! `sub`→`subscripted`) keep their existing `#[serde(rename = "super"/"sub")]`, and the Rust
//! keyword `type` stays literal via the raw-identifier `r#type` rather than `kind`/`type_`.

use serde::Deserialize;
use swiftshim::CGFloat;

// swift: Render/Office/HwpReader.swift:1809-1882
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpEnvelope {
    pub v: i64,
    /// The document's default body font size in points (rhwp: default style char-shape base_size
    /// ÷100), or absent/null when rhwp could not determine it → the mapper keeps the `11` fallback.
    #[serde(rename = "defaultFontSizePt")]
    pub default_font_size_pt: Option<f64>,
    /// The first section's page BODY width in points (rhwp: `PageAreas::from_page_def().body_area`
    /// width ÷100 — paper width − margins, landscape/binding/gutter honoured), or absent/null when
    /// no section/zero width → the mapper leaves `pageContentWidth` nil (reader falls back to
    /// window-filling). rhwp already emits points, so no further conversion.
    #[serde(rename = "pageContentWidth")]
    pub page_content_width: Option<f64>,
    /// The first section's page BODY height in points (rhwp: `PageAreas::from_page_def().body_area`
    /// height ÷100, landscape/binding/gutter honoured) — the vertical twin of `pageContentWidth`, same
    /// absent/null → nil semantics.
    #[serde(rename = "pageContentHeight")]
    pub page_content_height: Option<f64>,
    /// The first section's page margins in points (rhwp: paper size minus the resolved body area, on
    /// each of the four edges) — nil/absent for a parser built before this existed, same as
    /// `pageContentWidth`/`pageContentHeight`.
    #[serde(rename = "pageMarginLeft")]
    pub page_margin_left: Option<f64>,
    #[serde(rename = "pageMarginRight")]
    pub page_margin_right: Option<f64>,
    #[serde(rename = "pageMarginTop")]
    pub page_margin_top: Option<f64>,
    #[serde(rename = "pageMarginBottom")]
    pub page_margin_bottom: Option<f64>,
    /// One row per char shape, indexed by a span's `csId`; each row the SEVEN font families the
    /// document declared for that char shape, in HWP's own fixed slot order — 0 Hangul, 1 Latin,
    /// 2 Hanja, 3 Japanese, 4 Other, 5 Symbol, 6 User (`CharShape.font_ids`). An EMPTY string means
    /// the document's font table had no entry for that slot, which is a real answer ("nothing
    /// declared here") and not an error.
    ///
    /// Absent against a parser built before this existed — hence optional, and hence the reason a
    /// test has to assert it is PRESENT for a real file rather than trusting the Rust source.
    #[serde(rename = "charShapes")]
    pub char_shapes: Option<Vec<Vec<String>>>,
    /// The document's own font table, one list per language slot in the same order `charShapes`
    /// uses. `charShapes` already carries a resolved NAME, but that name went through rhwp's own
    /// substitution table on the way out, so it cannot say what the DOCUMENT nominated when its
    /// font is absent, nor whether the file carries the bytes. Absent against a parser built
    /// before this export existed.
    #[serde(rename = "fontFaces")]
    pub font_faces: Option<Vec<Vec<HwpFontFace>>>,
    /// One row per char shape, read by the SAME row number `charShapes` uses — everything a char
    /// shape does beyond weight, slant, underline presence, colour and size, which the span itself
    /// already carries. Absent against a parser built before this export existed.
    #[serde(rename = "charShapeDecor")]
    pub char_shape_decor: Option<Vec<HwpCharDecor>>,
    /// The document's own border/background definitions, indexed by `borderFillId - 1` (HWP's
    /// reference is 1-based; `0` means "nothing specified" and points at no row at all). Absent
    /// against a parser built before this export existed, which is exactly the state in which every
    /// HWP table was drawn with the reader's OWN grid: the ids arrived, nothing could resolve them.
    /// Measured on `2025_행정업무운영편람_최종.hwp`: 423 of 821 definitions turn all four edges OFF,
    /// so a document that deliberately erased its grid (layout tables) was ruled anyway.
    #[serde(rename = "borderFills")]
    pub border_fills: Option<Vec<HwpBorderFill>>,
    pub blocks: Vec<HwpBlock>,
    /// Running headers/footers (header-footer-design.md §3) — rhwp's `model/header_footer.rs`
    /// `Header`/`Footer`, each with its own `apply_to` and full paragraph body, exported by
    /// `document_json.rs`'s `append_control_blocks` (a Rust-side change tracked separately from
    /// this Swift mapper — see that design doc's step 6). `nil` for a parser built before this
    /// export existed, which the mapper treats exactly like `[]`: no running header/footer at all,
    /// unchanged from before this field existed (invariant 37's contract, restated for HWP).
    pub headers: Option<Vec<HwpHeaderFooterEntry>>,
    pub footers: Option<Vec<HwpHeaderFooterEntry>>,
    pub footnotes: Option<Vec<HwpFootnoteEntry>>,
    /// The section this document is typeset on (the one holding the most paragraphs, the same choice
    /// `pageContentWidth` comes from). Running heads are kept ONLY from this section: measured on a
    /// real manual, exactly one of 14 sections declares any — a five-paragraph landscape insert —
    /// and applying it document-wide printed a page number at the top of every even page and the
    /// bottom of every odd one, for 400 pages, while rhwp itself draws neither (invariant 77).
    #[serde(rename = "bodySection")]
    pub body_section: Option<i64>,
    /// The document's 바탕쪽 templates, each with the section that declares it and its objects at
    /// PAPER coordinates (HWPUNIT from the sheet's top-left). `nil` for a parser predating the
    /// export — treated exactly like `[]`, i.e. no master page, which is how this reader behaved
    /// before the feature existed.
    #[serde(rename = "masterPages")]
    pub master_pages: Option<Vec<HwpMasterPage>>,
    /// Where each section begins in the flat `blocks` array. `nil` for a parser predating it, and
    /// then no page can be told which section it is on — the reader keeps only the body section's
    /// template, which is what it did before per-page selection existed.
    #[serde(rename = "sectionStarts")]
    pub section_starts: Option<Vec<i64>>,
    pub sections: Option<Vec<HwpSection>>,
}

/// One 바탕쪽 as rhwp exports it. `section` is filtered against the envelope's `bodySection` for the
/// same reason a running head is (invariant 77).
// swift: Render/Office/HwpReader.swift:1884-1890
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpMasterPage {
    pub section: i64,
    #[serde(rename = "applyTo")]
    pub apply_to: String,
    pub objects: Vec<HwpMasterObject>,
}

/// One positioned object of a master page. `kind` says which of the three payloads is the real one:
/// `image` carries `binDataId`, `shape` carries `paths`, `text` carries `blocks` — AND, in real
/// files, its own `paths` too (a Korean number box is a rounded rectangle with a number in it), so
/// the two are not alternatives to each other.
// swift: Render/Office/HwpReader.swift:1892-1911
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpMasterObject {
    pub x: i64,
    pub y: i64,
    pub w: i64,
    pub h: i64,
    pub kind: String,
    /// The two halves of rhwp's OWN paper-plane sort key (`Layout::paper_node_sort_key`): the
    /// text-wrap band (1 behind text, 2 ordinary, 3 in front) and the z-order within it. A parser
    /// predating them decodes as nil, and the objects then keep their stored order — which is what
    /// this reader did until the 편람 showed why that is not the same thing.
    pub plane: Option<i64>,
    pub z: Option<i64>,
    #[serde(rename = "binDataId")]
    pub bin_data_id: Option<i64>,
    pub paths: Option<Vec<HwpShapePath>>,
    pub blocks: Option<Vec<HwpBlock>>,
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
// swift: Render/Office/HwpReader.swift:1913-1933
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpFootnoteShape {
    #[serde(rename = "separatorLineType")]
    pub separator_line_type: Option<i64>,
    #[serde(rename = "separatorLineWidth")]
    pub separator_line_width: Option<i64>,
    #[serde(rename = "separatorColor")]
    pub separator_color: Option<String>,
    #[serde(rename = "separatorLengthHwpUnit")]
    pub separator_length_hwp_unit: Option<i64>,
    #[serde(rename = "separatorMarginTopHwpUnit")]
    pub separator_margin_top_hwp_unit: Option<i64>,
    #[serde(rename = "separatorMarginBottomHwpUnit")]
    pub separator_margin_bottom_hwp_unit: Option<i64>,
    #[serde(rename = "noteSpacingHwpUnit")]
    pub note_spacing_hwp_unit: Option<i64>,
}

// swift: Render/Office/HwpReader.swift:1935-1939
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpFootnoteEntry {
    pub number: i64,
    pub section: Option<i64>,
    pub blocks: Vec<HwpBlock>,
}

// swift: Render/Office/HwpReader.swift:1941-1947
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpHeaderFooterEntry {
    #[serde(rename = "applyTo")]
    pub apply_to: String,
    /// Which section declared it. A running head belongs to its own section — see the envelope's
    /// `bodySection` for why a reader that lays the whole document on one page must filter by it.
    pub section: Option<i64>,
    pub blocks: Vec<HwpBlock>,
}

/// A body block, discriminated by its `"t"` tag. Decoding re-reads the SAME object through the
/// tag-specific struct rather than duplicating each field into a flat model — `#[serde(tag = "t")]`
/// does the same re-read serde's own way: it buffers the object once, dispatches on `"t"`, then
/// deserializes the WHOLE buffered object (this variant's payload struct simply ignores the `t`
/// key it does not declare a field for), so no field is duplicated into a flat model here either.
/// An unrecognised tag is serde's own "unknown variant" decode error, the same failure this file's
/// hand-written `default:` branch raised.
// swift: Render/Office/HwpReader.swift:1949-1975
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "t", rename_all = "lowercase")]
pub(crate) enum HwpBlock {
    Para(HwpPara),
    Table(HwpTable),
    Image(HwpImage),
    Shape(HwpShape),
    Unsupported(HwpUnsupported),
    Equation(HwpEquation),
}

// swift: Render/Office/HwpReader.swift:1977-2032
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpPara {
    pub heading: Option<i64>,
    /// The paragraph STYLE's stable English name ("Outline 1", "Title"), and its Korean display name
    /// ("개요 1", "제목"). Both absent for a document whose styles carry neither.
    ///
    /// Why both: HWP's own `head_type` marks only paragraphs that use OUTLINE numbering, and measuring
    /// 14 real HWP files found 13 of them produce ZERO headings that way — practically every Korean
    /// report titles its sections with a named STYLE instead. That is invariant 33's lesson repeating
    /// itself (Word headings were missed for the same reason, in 103 of 188 documents): one signal is
    /// not the format, it is one of the ways the format expresses the same thing.
    #[serde(rename = "styleName")]
    pub style_name: Option<String>,
    #[serde(rename = "styleLocalName")]
    pub style_local_name: Option<String>,
    pub spans: Vec<HwpSpan>,
    pub align: Option<String>,
    #[serde(rename = "indentStart")]
    pub indent_start: Option<i64>,
    #[serde(rename = "indentEnd")]
    pub indent_end: Option<i64>,
    #[serde(rename = "indentFirst")]
    pub indent_first: Option<i64>,
    #[serde(rename = "spaceBefore")]
    pub space_before: Option<i64>,
    #[serde(rename = "spaceAfter")]
    pub space_after: Option<i64>,
    #[serde(rename = "lineHeight")]
    pub line_height: Option<HwpLineHeight>,
    pub list: Option<HwpList>,
    /// The paragraph's own tab stops, from HWP's shared tab-definition table.
    #[serde(rename = "tabStops")]
    pub tab_stops: Option<Vec<HwpTabStop>>,
    /// When the paragraph lives inside a drawing's TEXT BOX rather than in the body, the box's own
    /// position and size in HWPUNIT (accumulated through group nesting). Absent for a body paragraph.
    /// The paragraph's OWN base character size in points — present even when it has no runs, which
    /// is the case that mattered: a paragraph with no text still has a char shape, and without it a
    /// percentage line height has no basis and falls back to a document default this document may
    /// never have stated. Measured on the 편람: 793 of its 2,789 paragraphs are empty AND carry no
    /// spans, so 28% of the document was being spaced against a guess.
    #[serde(rename = "baseSizePt")]
    pub base_size_pt: Option<CGFloat>,
    #[serde(rename = "boxX")]
    pub box_x: Option<i64>,
    #[serde(rename = "boxY")]
    pub box_y: Option<i64>,
    #[serde(rename = "boxW")]
    pub box_w: Option<i64>,
    #[serde(rename = "boxH")]
    pub box_h: Option<i64>,
    /// Keep this paragraph with the next one / do not split it / do not strand its first or last
    /// line / the STYLE says start a page here (which is a different signal from the author's own
    /// `breakBefore`). All four are what stop a heading being paginated away from its body.
    #[serde(rename = "keepWithNext")]
    pub keep_with_next: Option<bool>,
    #[serde(rename = "keepLines")]
    pub keep_lines: Option<bool>,
    #[serde(rename = "widowOrphan")]
    pub widow_orphan: Option<bool>,
    #[serde(rename = "pageBreakBefore")]
    pub page_break_before: Option<bool>,
    /// Where a line may be broken — Hangul: `0` between words, `1` between characters; Latin: `0`
    /// between words, `1` also at a hyphen, `2` between characters. The nominal schema says the
    /// opposite for Hangul; rhwp measured Hancom three separate ways and its own line breaker uses
    /// THIS reading (`composer/line_breaking.rs`, #2185), so it is the one to follow.
    #[serde(rename = "koreanBreakUnit")]
    pub korean_break_unit: Option<i64>,
    #[serde(rename = "englishBreakUnit")]
    pub english_break_unit: Option<i64>,
    /// Whether the document widens the seam where Hangul meets Latin letters / digits.
    #[serde(rename = "autoSpaceKrEn")]
    pub auto_space_kr_en: Option<bool>,
    #[serde(rename = "autoSpaceKrNum")]
    pub auto_space_kr_num: Option<bool>,
    /// Whether the line height comes from the font's own metrics rather than the character size.
    #[serde(rename = "fontLineHeight")]
    pub font_line_height: Option<bool>,
    /// `"page"`/`"section"`/`"multiColumn"`/`"column"`, absent when the paragraph starts nothing.
    #[serde(rename = "breakBefore")]
    pub break_before: Option<String>,
}

/// What a char shape does beyond the handful of things a span already carries. Every field is
/// omitted at its default, so an ordinary document's rows decode to all-nil.
///
/// Colours are present ONLY when the decoration that uses them is on: a colour of `000000` is
/// indistinguishable from "no colour stated", so carrying it unconditionally would shade every
/// document in black.
// swift: Render/Office/HwpReader.swift:2034-2061
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub(crate) struct HwpCharDecor {
    #[serde(rename = "underlineShape")]
    pub underline_shape: Option<i64>,
    #[serde(rename = "underlineColor")]
    pub underline_color: Option<String>,
    #[serde(rename = "strikeShape")]
    pub strike_shape: Option<i64>,
    #[serde(rename = "strikeColor")]
    pub strike_color: Option<String>,
    #[serde(rename = "shadeColor")]
    pub shade_color: Option<String>,
    #[serde(rename = "outlineType")]
    pub outline_type: Option<i64>,
    #[serde(rename = "shadowType")]
    pub shadow_type: Option<i64>,
    #[serde(rename = "shadowColor")]
    pub shadow_color: Option<String>,
    #[serde(rename = "shadowOffsetX")]
    pub shadow_offset_x: Option<i64>,
    #[serde(rename = "shadowOffsetY")]
    pub shadow_offset_y: Option<i64>,
    pub emboss: Option<bool>,
    pub engrave: Option<bool>,
    #[serde(rename = "emphasisDot")]
    pub emphasis_dot: Option<i64>,
    pub kerning: Option<bool>,
    /// Per language slot, in `charShapes`' own order: width %, letter spacing %, relative size %,
    /// baseline offset %. Absent when every slot is at its default (100 / 0 / 100 / 0).
    pub ratios: Option<Vec<i64>>,
    pub spacings: Option<Vec<i64>>,
    #[serde(rename = "relativeSizes")]
    pub relative_sizes: Option<Vec<i64>>,
    #[serde(rename = "charOffsets")]
    pub char_offsets: Option<Vec<i64>>,
}

/// One entry of the document's font table — the name as the document wrote it (before any
/// substitution), the substitute the DOCUMENT nominates for it, what kind of font file it is
/// (`0` unknown, `1` TTF, `2` HFT — Hancom's own format, installed on no machine but a Hancom one),
/// and whether the file carries the bytes.
// swift: Render/Office/HwpReader.swift:2063-2095
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub(crate) struct HwpFontFace {
    pub name: String,
    #[serde(rename = "altName")]
    pub alt_name: Option<String>,
    pub r#type: Option<i64>,
    pub embedded: Option<bool>,
    #[serde(rename = "binDataId")]
    pub bin_data_id: Option<i64>,
    /// A second name for this SAME face (not a substitute) — the file's own bytes, always. The
    /// exporter sends this ONLY on the HWP5 binary path; on every other path (HWPX included) the
    /// same Rust field is filled from rhwp's own fixed lookup table rather than the file, so the
    /// exporter omits the key entirely there rather than sending the parser's guess as the
    /// document's word (`document_json.rs`'s `FontFaceDto.default_name`). `nil` here therefore means
    /// either "no such record" or "not on a path this reader can trust" — never "the parser guessed
    /// and we sent it anyway".
    #[serde(rename = "defaultName")]
    pub default_name: Option<String>,
    /// The raw 10-byte PANOSE block (HWP5 FACE_NAME type info), undecoded — byte 0 is family kind,
    /// byte 1 is serif style — the file's own bytes, always. Sent ONLY on the HWP5 binary path, for
    /// the same reason as `defaultName`: on HWPX the same Rust field is filled from values this
    /// reader cannot trust as the document's statement (byte 1 is a name-morpheme guess with no XML
    /// attribute behind it at all; byte 0, though read from a real attribute, is Hancom's own face
    /// category renumbered 1-7, not standard PANOSE `bFamilyType`) — so the exporter omits the whole
    /// block there rather than let either byte be mistaken for what the document said. `nil` means
    /// either no such record, or a path this reader does not trust for this field; ten zeroes is
    /// PANOSE "Any", a real value, not the same as absent.
    pub panose: Option<Vec<i64>>,
    /// The type (`0` unknown / `1` TTF / `2` HFT) of the SUBSTITUTE face nominated in `altName`,
    /// independent of this font's own `type` above. `nil` when the document nominates no substitute.
    /// HWP5 has no such concept, so this is always `nil` there.
    #[serde(rename = "substType")]
    pub subst_type: Option<i64>,
}

// swift: Render/Office/HwpReader.swift:2097-2100
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpLineHeight {
    pub r#type: String,
    pub value: i64,
}

/// What a SECTION declared about itself — which page furniture it hides, where it restarts page
/// numbering, whether it is written on a grid or vertically. Absent for a parser predating the
/// export, and then every section reads as declaring nothing, which is how this reader always
/// behaved.
// swift: Render/Office/HwpReader.swift:2102-2117
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpSection {
    #[serde(rename = "footnoteShape")]
    pub footnote_shape: Option<HwpFootnoteShape>,
    pub page: Option<HwpSectionPage>,
    #[serde(rename = "pageBorder")]
    pub page_border: Option<HwpPageBorder>,
    #[serde(rename = "hideHeader")]
    pub hide_header: Option<bool>,
    #[serde(rename = "hideFooter")]
    pub hide_footer: Option<bool>,
    #[serde(rename = "hideMasterPage")]
    pub hide_master_page: Option<bool>,
    #[serde(rename = "pageNumberStart")]
    pub page_number_start: Option<i64>,
    #[serde(rename = "lineGridHwpUnit")]
    pub line_grid_hwp_unit: Option<i64>,
    #[serde(rename = "charGridHwpUnit")]
    pub char_grid_hwp_unit: Option<i64>,
    #[serde(rename = "verticalText")]
    pub vertical_text: Option<bool>,
}

/// A section's 쪽 테두리/배경 — the frame a Korean document rules around the whole page. The line and
/// colour live in the SAME `borderFills` table a cell's `borderFillId` points at; `basis` says where
/// the spacings are measured FROM, and the two answers differ by a margin (70–110pt on real files).
// swift: Render/Office/HwpReader.swift:2119-2129
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpPageBorder {
    #[serde(rename = "borderFillId")]
    pub border_fill_id: i64,
    #[serde(rename = "spacingLeftHwpUnit")]
    pub spacing_left_hwp_unit: Option<i64>,
    #[serde(rename = "spacingRightHwpUnit")]
    pub spacing_right_hwp_unit: Option<i64>,
    #[serde(rename = "spacingTopHwpUnit")]
    pub spacing_top_hwp_unit: Option<i64>,
    #[serde(rename = "spacingBottomHwpUnit")]
    pub spacing_bottom_hwp_unit: Option<i64>,
    pub basis: Option<String>,
}

/// The paper a SECTION declared, in points. HWP defines a page per section; the envelope's own
/// `pageContentWidth`/`Height` carry only the section with the most paragraphs (invariant 73).
// swift: Render/Office/HwpReader.swift:2131-2147
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpSectionPage {
    #[serde(rename = "contentWidth")]
    pub content_width: CGFloat,
    #[serde(rename = "contentHeight")]
    pub content_height: CGFloat,
    #[serde(rename = "marginLeft")]
    pub margin_left: CGFloat,
    #[serde(rename = "marginRight")]
    pub margin_right: CGFloat,
    #[serde(rename = "marginTop")]
    pub margin_top: CGFloat,
    #[serde(rename = "marginBottom")]
    pub margin_bottom: CGFloat,
    /// Where the running head STARTS, measured from the paper's own edge — the document's raw
    /// `PageDef` declaration rather than the resolved body area the four `margin*` above carry.
    /// `marginTop` already includes this (body top = marginHeader + the top margin proper), so the
    /// two are not interchangeable: this is the only value that says where inside the band the
    /// header sits. Absent against a parser built before the declaration was exported.
    #[serde(rename = "marginHeader")]
    pub margin_header: Option<CGFloat>,
    #[serde(rename = "marginFooter")]
    pub margin_footer: Option<CGFloat>,
}

// swift: Render/Office/HwpReader.swift:2149-2155
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpTabStop {
    #[serde(rename = "posHwpUnit")]
    pub pos_hwp_unit: i64,
    /// What the tab is FILLED with on its way to the stop — HWP's own line-type code, the same one
    /// the four cell edges and a diagonal use. Absent = no fill, which is the ordinary tab.
    #[serde(rename = "fillType")]
    pub fill_type: Option<i64>,
    pub kind: Option<String>,
}

// swift: Render/Office/HwpReader.swift:2157-2171
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpList {
    pub level: i64,
    pub ordered: bool,
    /// The document's OWN marker — its number format string (`^1.`, 가./나./다.) or its bullet
    /// character (▶). Absent means the document declared none and the reader's default stands.
    pub marker: Option<String>,
    /// The level's start number when the author set one other than 1.
    #[serde(rename = "startNumber")]
    pub start_number: Option<i64>,
    /// Which glyphs the number is written in (HWP's own table 43), named — see `ListNumbering.Glyphs`.
    #[serde(rename = "numberFormat")]
    pub number_format: Option<String>,
    /// How far this level's TEXT sits from its own head, in HWPUNIT — the numbered-head form and the
    /// bullet form of the same fact, only one of which a given level has.
    #[serde(rename = "numberingHeadTextDistance")]
    pub numbering_head_text_distance: Option<i64>,
    #[serde(rename = "bulletTextDistance")]
    pub bullet_text_distance: Option<i64>,
}

/// A form control embedded in the text — `FormObject` in the format.
// swift: Render/Office/HwpReader.swift:2173-2181
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpForm {
    #[serde(rename = "formType")]
    pub form_type: Option<String>,
    pub name: Option<String>,
    pub caption: Option<String>,
    pub text: Option<String>,
    pub value: Option<i64>,
    pub enabled: Option<bool>,
}

/// What a section's text says about the columns it flows through — `ColumnDef` in the format.
// swift: Render/Office/HwpReader.swift:2183-2195
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpColumnDef {
    #[serde(rename = "columnCount")]
    pub column_count: i64,
    pub direction: Option<String>,
    #[serde(rename = "sameWidth")]
    pub same_width: Option<bool>,
    #[serde(rename = "proportionalWidths")]
    pub proportional_widths: Option<bool>,
    #[serde(rename = "separatorType")]
    pub separator_type: Option<i64>,
    #[serde(rename = "separatorWidth")]
    pub separator_width: Option<i64>,
    #[serde(rename = "separatorColor")]
    pub separator_color: Option<String>,
    #[serde(rename = "columnSpacingPt")]
    pub column_spacing_pt: Option<f64>,
    #[serde(rename = "columnWidths")]
    pub column_widths: Option<Vec<f64>>,
    #[serde(rename = "columnGaps")]
    pub column_gaps: Option<Vec<f64>>,
}

// swift: Render/Office/HwpReader.swift:2197-2268
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpSpan {
    pub text: String,
    pub bold: Option<bool>,
    pub italic: Option<bool>,
    pub underline: Option<String>,
    pub strike: Option<bool>,
    /// JSON key "super" (a Swift keyword) — remapped below, the same way the Swift file's own
    /// explicit `CodingKeys` remaps it. The Swift PROPERTY name is `superscript`, not `super`
    /// (`super` is a Rust keyword too, so the literal spelling could not be a field name here
    /// even if the convention's "keep the property name" rule wanted it).
    #[serde(rename = "super")]
    pub superscript: Option<bool>,
    /// Which note this run references, and of which kind (`"footnote"`/`"endnote"`). Absent on
    /// every run that is not a note marker — a marker's glyphs are a superscript number and say
    /// nothing on their own.
    #[serde(rename = "noteRef")]
    pub note_ref: Option<i64>,
    #[serde(rename = "noteRefKind")]
    pub note_ref_kind: Option<String>,
    /// What the note's own control says is printed around its number — `1` vs `1)`. Declared per
    /// INSTANCE, not just per section, so it is read here rather than from the section's shape.
    #[serde(rename = "noteBeforeChar")]
    pub note_before_char: Option<String>,
    #[serde(rename = "noteAfterChar")]
    pub note_after_char: Option<String>,
    /// `Control::ColumnDef`('cold') — "from here on, N columns". A zero-width anchor span, the same
    /// shape a bookmark or a note marker arrives as.
    #[serde(rename = "columnDef")]
    pub column_def: Option<HwpColumnDef>,
    /// `Control::Form`('form') — a checkbox/button/field the document embedded.
    pub form: Option<HwpForm>,
    /// JSON key "sub" — the Swift property name is `subscripted`.
    #[serde(rename = "sub")]
    pub subscripted: Option<bool>,
    pub color: Option<String>,
    pub size: Option<i64>,
    pub font: Option<String>,
    pub link: Option<String>,
    pub bookmark: Option<String>,
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
    #[serde(rename = "csId")]
    pub cs_id: Option<i64>,
    /// `"page"` when this run stands in for HWP's live page-number control, absent otherwise.
    ///
    /// HWP writes a page number as a `Control::AutoNumber(Page)` — a control, not characters — so
    /// before rhwp exported it a Korean footer reading `- 3 -` arrived as `-   -` with the number
    /// missing entirely. The number rhwp computed rides along as this run's text (what a reader with
    /// no pagination would show), and this marker lets `PageBandPainter` replace it with the page
    /// actually being drawn, exactly as it does for Word's `PAGE` field.
    #[serde(rename = "pageNumberField")]
    pub page_number_field: Option<String>,

    /// `Control::PageHide`('pghd') — a per-paragraph veto that starts at this run's own position,
    /// carrying `hidePageNum` (plus five other switches this reader does not adopt — see
    /// `OfficeReadResult.hidePageNumberBlocks`). A zero-width anchor span, the same shape a
    /// bookmark or footnote-reference marker already arrives as.
    #[serde(rename = "pageHide")]
    pub page_hide: Option<HwpPageHide>,

    /// `Control::NewNumber`('nwno') — "start numbering again from here". It can restart a picture,
    /// table, footnote, endnote, equation or PAGE counter; only `page` is honoured, because those
    /// are the only numbers this reader computes rather than replays from the document's own text.
    #[serde(rename = "newNumber")]
    pub new_number: Option<HwpNewNumber>,

    // swift's own explicit `CodingKeys` (listed EXPLICITLY, like every other key here — see the
    // Swift comment this mirrors) is expressed here as the `#[serde(rename = …)]` attributes above,
    // one per field; serde's derive already ignores any JSON key with no matching field, the same
    // silent-drop behaviour an explicit `CodingKeys` gives Swift. Anything added above needs a
    // rename here too, for the identical reason the Swift comment states.
}

/// `NewNumberDto` — which counter to restart, and at what. `numberType` is the parser's own name
/// (`page`/`picture`/`table`/`footnote`/`endnote`/`equation`).
// swift: Render/Office/HwpReader.swift:2270-2275
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpNewNumber {
    #[serde(rename = "numberType")]
    pub number_type: Option<String>,
    pub number: Option<i64>,
}

/// `PageHideDto` — only `hidePageNum` is read; see `OfficeReadResult.hidePageNumberBlocks` for why
/// the other five (header/footer/master-page/border/fill) are decoded here and then never used.
// swift: Render/Office/HwpReader.swift:2277-2281
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpPageHide {
    #[serde(rename = "hidePageNum")]
    pub hide_page_num: Option<bool>,
}

/// One row of the document's border/background table (rhwp `borderFills`). Every HWP cell names one
/// of these, and it declares ALL FOUR of that cell's edges — so an HWP cell is never in
/// `BorderDecl`'s "never mentioned" state once its id resolves: an edge is either drawn or
/// explicitly `none`. That is why this maps to a fully-populated `EdgeBorders` rather than leaving
/// unmentioned edges to the table cascade the way docx's partial `w:tcBorders` does.
// swift: Render/Office/HwpReader.swift:2283-2321
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpBorderFill {
    pub left: HwpBorderEdge,
    pub right: HwpBorderEdge,
    pub top: HwpBorderEdge,
    pub bottom: HwpBorderEdge,
    /// Solid background fill as `"RRGGBB"`, already filtered by rhwp's own renderer rule — a
    /// pattern, gradient, image or transparent fill arrives absent, and the reader paints nothing
    /// rather than guessing an average colour.
    pub bg: Option<String>,
    /// A PICTURE fill's `binDataId`. This is how a Korean document draws a rounded annotation box:
    /// the TABLE's fill is an image and every cell declares no rules at all, so a reader that knows
    /// only `bg` renders the box as blank paper (measured on the 편람's 전자문서 box).
    #[serde(rename = "bgImage")]
    pub bg_image: Option<i64>,
    /// A GRADIENT fill's stops and angle. Painted as a linear gradient; a single stop degrades to a
    /// plain fill, which is what it is.
    #[serde(rename = "bgGradient")]
    pub bg_gradient: Option<HwpGradient>,
    /// THE ANSWER, already resolved by the parser: `"slash"` / `"backslash"` / `"both"` when this
    /// fill declares a drawn cell diagonal, absent when it does not.
    ///
    /// HWP splits a diagonal across three places — the line TYPE in `diagonalType`, the DIRECTION in
    /// bits of `attr`, and a separate bit saying the whole thing is a centre line instead. The
    /// reader does not combine them: `BorderFill::cell_diagonal` in the parser does, and the
    /// parser's own table editor calls the same function, so there is one answer rather than two
    /// that can drift. Judging it here instead would rule lines across cells that carry a type but
    /// no direction — two thirds of the raw declarations in the measured corpus.
    #[serde(rename = "cellDiagonal")]
    pub cell_diagonal: Option<String>,
    /// The diagonal's own line type, in the SAME 18-value enum the four edges use, so `lineStyle`
    /// maps it without a second table. Only meaningful when `cellDiagonal` is present.
    #[serde(rename = "diagonalType")]
    pub diagonal_type: Option<i64>,
    /// The diagonal's width in HWP's 16-step enum — NOT points, unlike an edge's `widthPt`, because
    /// the parser resolves an edge's width and leaves a diagonal's raw. Absent = the finest step.
    #[serde(rename = "diagonalWidth")]
    pub diagonal_width: Option<i64>,
    #[serde(rename = "diagonalColor")]
    pub diagonal_color: Option<String>,
}

// swift: Render/Office/HwpReader.swift:2323-2326
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpGradient {
    pub colors: Vec<String>,
    pub angle: Option<i64>,
}

/// One edge of an `HwpBorderFill`. `type == "none"` is the document SUPPRESSING that edge (and then
/// carries no width/colour); any other type is a real rule. The reader keeps only "is it drawn, and
/// at what width/colour" — `BorderSide` has no dash vocabulary — but the type is decoded as sent so
/// a later dash model has the fact rather than having to rebuild the parser for it.
// swift: Render/Office/HwpReader.swift:2328-2336
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpBorderEdge {
    pub r#type: String,
    #[serde(rename = "widthPt")]
    pub width_pt: Option<f64>,
    pub color: Option<String>,
}

// swift: Render/Office/HwpReader.swift:2338-2359
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpTable {
    pub cols: Option<i64>,
    #[serde(rename = "colWidths")]
    pub col_widths: Vec<i64>,
    #[serde(rename = "borderFillId")]
    pub border_fill_id: Option<i64>,
    pub rows: Vec<Vec<HwpCell>>,
    /// How many rows at the TOP are the table's heading — the author's own mark, not a guess that
    /// row one is a header. Absent for a parser predating the export.
    #[serde(rename = "headerRows")]
    pub header_rows: Option<i64>,
    /// Whether the author asked for those heading rows to be REPRINTED on each further page, which
    /// is a separate switch from having a heading at all.
    #[serde(rename = "repeatHeader")]
    pub repeat_header: Option<bool>,
    /// `"none"` / `"cell"` / `"row"` — where the document allows this table to be split when it
    /// reaches the foot of a page. Absent for a parser predating the export.
    #[serde(rename = "pageBreak")]
    pub page_break: Option<String>,
    /// The table OBJECT's own outer margin (HWPUNIT), zero-omitted at the wire (`document_json.rs`'s
    /// `skip_serializing_if = "is_zero_i32"`) — so a declared `0` and "never declared" already look
    /// identical here, both decoding to `nil`. Absent for a parser predating the export.
    #[serde(rename = "outerMarginLeft")]
    pub outer_margin_left: Option<i64>,
    #[serde(rename = "outerMarginRight")]
    pub outer_margin_right: Option<i64>,
    #[serde(rename = "outerMarginTop")]
    pub outer_margin_top: Option<i64>,
    #[serde(rename = "outerMarginBottom")]
    pub outer_margin_bottom: Option<i64>,
}

// swift: Render/Office/HwpReader.swift:2361-2375
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpCell {
    #[serde(rename = "colSpan")]
    pub col_span: i64,
    #[serde(rename = "rowSpan")]
    pub row_span: i64,
    #[serde(rename = "vAlign")]
    pub v_align: Option<String>,
    #[serde(rename = "borderFillId")]
    pub border_fill_id: Option<i64>,
    /// The cell's resolved inner margin in POINTS, per edge (rhwp `Cell::effective_padding` ÷100).
    /// Absent against a parser built before this existed — which is exactly the state that made every
    /// HWP table fall to the reader's own invented default, so a rebuild that loses these fields
    /// silently inflates every table again rather than failing.
    #[serde(rename = "padLeft")]
    pub pad_left: Option<f64>,
    #[serde(rename = "padRight")]
    pub pad_right: Option<f64>,
    #[serde(rename = "padTop")]
    pub pad_top: Option<f64>,
    #[serde(rename = "padBottom")]
    pub pad_bottom: Option<f64>,
    pub blocks: Vec<HwpBlock>,
}

/// A drawing object, flattened to paths by rhwp (`{"t":"shape",…}`). See `HwpShapeRenderer` for why
/// this is drawn at read time instead of becoming a new kind of block.
// swift: Render/Office/HwpReader.swift:2377-2404
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpShape {
    pub w: i64,
    pub h: i64,
    pub align: Option<String>,
    /// TRUE when the document places the object AS A CHARACTER — in the text flow, where drawing it
    /// inline moves nothing. FALSE = anchored by coordinates, over or beside the text.
    #[serde(rename = "asChar")]
    pub as_char: Option<bool>,
    /// The object holds SPACE in the flow — 어울림/자연스럽게/통과/위아래, where HWP pushes the text
    /// out of the object's way. FALSE (and absent, which is a parser predating the export) means it
    /// is painted over or behind the text (글 앞으로/글 뒤로) and holds no space at all. A reader that
    /// floats BOTH kinds takes away the space the wrapping ones were holding, and every page that
    /// space was making disappears with it — measured across 2,066 documents: 7 lost 1–2 pages each.
    #[serde(rename = "wrapsText")]
    pub wraps_text: Option<bool>,
    /// What an anchored object's position is measured against (`paper`/`page`/`para`) and the two
    /// offsets in HWPUNIT. Only `para` is placeable by this reader: its anchor is a paragraph this
    /// layout knows the position of, while `paper`/`page` presuppose the document's own pagination.
    #[serde(rename = "vertRelTo")]
    pub vert_rel_to: Option<String>,
    #[serde(rename = "horzRelTo")]
    pub horz_rel_to: Option<String>,
    #[serde(rename = "offsetX")]
    pub offset_x: Option<i64>,
    #[serde(rename = "offsetY")]
    pub offset_y: Option<i64>,
    /// WHICH EDGE of that reference the offset is measured from — the other half of rhwp's own
    /// placement (`shape_layout.rs`'s `calc_shape_bottom_y`). Without it an offset is not a position.
    #[serde(rename = "vertAlign")]
    pub vert_align: Option<String>,
    #[serde(rename = "horzAlign")]
    pub horz_align: Option<String>,
    pub paths: Vec<HwpShapePath>,
}

// swift: Render/Office/HwpReader.swift:2406-2415
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpShapePath {
    /// Path commands as rhwp writes them: `["M",x,y]`, `["L",x,y]`, `["C",…6 numbers]`, `["Z"]`,
    /// in HWPUNIT relative to the object's own box. Decoded as a heterogeneous array because that
    /// is the shape SVG itself uses, and a per-command object would triple the JSON for 79 shapes.
    pub d: Vec<Vec<HwpPathToken>>,
    pub stroke: Option<HwpShapeStroke>,
    pub fill: Option<String>,
    #[serde(rename = "arrowStart")]
    pub arrow_start: Option<bool>,
    #[serde(rename = "arrowEnd")]
    pub arrow_end: Option<bool>,
}

/// One element of a path command — the leading operator string or one of its numbers.
// swift: Render/Office/HwpReader.swift:2417-2430
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub(crate) enum HwpPathToken {
    Op(String),
    Number(f64),
}

impl HwpPathToken {
    pub fn value(&self) -> Option<f64> {
        match self {
            HwpPathToken::Number(v) => Some(*v),
            _ => None,
        }
    }
    pub fn name(&self) -> Option<&str> {
        match self {
            HwpPathToken::Op(s) => Some(s.as_str()),
            _ => None,
        }
    }
}

// swift: Render/Office/HwpReader.swift:2432-2436
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpShapeStroke {
    pub color: Option<String>,
    #[serde(rename = "widthPt")]
    pub width_pt: Option<f64>,
    pub r#type: Option<String>,
}

// swift: Render/Office/HwpReader.swift:2438-2477
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpImage {
    #[serde(rename = "binDataId")]
    pub bin_data_id: i64,
    pub w: i64,
    pub h: i64,
    pub mime: Option<String>,
    /// The object's OWN horizontal alignment, which in HWP lives on the picture rather than on a
    /// containing paragraph (`left`/`center`/`right`/`inside`/`outside`).
    pub align: Option<String>,
    /// The anchor, exactly as a drawing carries it — a picture is anchored as often as a drawing is
    /// (a cover's artwork, a seal over a signature line). Absent for a parser predating the export,
    /// and then every picture reads as in-flow, which is how this reader always treated them.
    #[serde(rename = "asChar")]
    pub as_char: Option<bool>,
    /// The object holds SPACE in the flow — 어울림/자연스럽게/통과/위아래, where HWP pushes the text
    /// out of the object's way. FALSE (and absent, which is a parser predating the export) means it
    /// is painted over or behind the text (글 앞으로/글 뒤로) and holds no space at all. A reader that
    /// floats BOTH kinds takes away the space the wrapping ones were holding, and every page that
    /// space was making disappears with it — measured across 2,066 documents: 7 lost 1–2 pages each.
    #[serde(rename = "wrapsText")]
    pub wraps_text: Option<bool>,
    #[serde(rename = "vertRelTo")]
    pub vert_rel_to: Option<String>,
    #[serde(rename = "horzRelTo")]
    pub horz_rel_to: Option<String>,
    #[serde(rename = "vertAlign")]
    pub vert_align: Option<String>,
    #[serde(rename = "horzAlign")]
    pub horz_align: Option<String>,
    #[serde(rename = "offsetX")]
    pub offset_x: Option<i64>,
    #[serde(rename = "offsetY")]
    pub offset_y: Option<i64>,
    /// What `w` is measured against: `absolute` (HWPUNIT, the overwhelmingly common case) or
    /// `paper`/`page`/`column`/`para`, where `w` is instead a share in ten-thousandths. Honouring
    /// this is what "follow the option the document stored" means for HWP — the format has five
    /// ways to state a width and forcing them all through the absolute one is a guess.
    #[serde(rename = "widthCriterion")]
    // swift: Render/Office/HwpReader.swift:2462-2466
    pub width_criterion: Option<String>,
    /// The rectangle of the ORIGINAL picture this object actually shows, in the original's own
    /// HWPUNIT coordinates. Absent for a parser predating the export → no crop, which is how every
    /// HWP picture was drawn before this.
    // swift: Render/Office/HwpReader.swift:2467-2470
    pub crop: Option<HwpCrop>,
    /// The original picture's size, the SAME coordinates `crop` is in. Without it a crop cannot be
    /// read: most documents that do not crop still write a rectangle covering the whole original,
    /// and the two are indistinguishable without this. Measured across 637 documents — 3,159 crops
    /// are declared and 563 of them (138 documents) actually cut something.
    #[serde(rename = "originalWidth")]
    // swift: Render/Office/HwpReader.swift:2471-2475
    pub original_width: Option<i64>,
    #[serde(rename = "originalHeight")]
    // swift: Render/Office/HwpReader.swift:2476-2476
    pub original_height: Option<i64>,
}

/// A crop rectangle in the original picture's coordinates. `left`/`top` are inset from the
/// original's own origin; `right`/`bottom` are the far edges, NOT insets — so an uncropped picture
/// writes `(0, 0, originalWidth, originalHeight)`.
// swift: Render/Office/HwpReader.swift:2479-2487
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpCrop {
    pub left: i64,
    pub top: i64,
    pub right: i64,
    pub bottom: i64,
}

// swift: Render/Office/HwpReader.swift:2489-2493
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpUnsupported {
    pub label: String,
    pub w: i64,
    pub h: i64,
}

/// A display equation rhwp translated to LaTeX (`{"t":"equation","latex":…,"script":…,"w":…,"h":…}`).
/// `latex` is the TeX string the app's formula engine renders; `script` is the raw HWP equation script
/// (kept for provenance/fallback, not currently rendered); `w`/`h` are advisory HWPUNIT dimensions used
/// only to reserve a placeholder area when `latex` is empty. All but `latex` are optional — a minimal
/// producer may emit `{"t":"equation","latex":…}` alone.
// swift: Render/Office/HwpReader.swift:2495-2505
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct HwpEquation {
    pub latex: String,
    pub script: Option<String>,
    pub w: Option<i64>,
    pub h: Option<i64>,
}

// Boundary lines (closing braces, blank separators, field/case lines already
// covered in substance by the ranges above) that the coverage script's per-item
// markers did not individually re-state:
// swift: Render/Office/HwpReader.swift:2477-2478
// swift: Render/Office/HwpReader.swift:2488-2488
// swift: Render/Office/HwpReader.swift:2494-2494

// Boundary lines (closing braces, blank separators, field/case lines already
// covered in substance by the ranges above) that the coverage script's per-item
// markers did not individually re-state:
// swift: Render/Office/HwpReader.swift:1769-1770
// swift: Render/Office/HwpReader.swift:1805-1808
// swift: Render/Office/HwpReader.swift:1883-1883
// swift: Render/Office/HwpReader.swift:1891-1891
// swift: Render/Office/HwpReader.swift:1912-1912
// swift: Render/Office/HwpReader.swift:1934-1934
// swift: Render/Office/HwpReader.swift:1940-1940
// swift: Render/Office/HwpReader.swift:1948-1948
// swift: Render/Office/HwpReader.swift:1976-1976
// swift: Render/Office/HwpReader.swift:2033-2033
// swift: Render/Office/HwpReader.swift:2062-2062
// swift: Render/Office/HwpReader.swift:2096-2096
// swift: Render/Office/HwpReader.swift:2101-2101
// swift: Render/Office/HwpReader.swift:2118-2118
// swift: Render/Office/HwpReader.swift:2130-2130
// swift: Render/Office/HwpReader.swift:2148-2148
// swift: Render/Office/HwpReader.swift:2156-2156
// swift: Render/Office/HwpReader.swift:2172-2172
// swift: Render/Office/HwpReader.swift:2182-2182
// swift: Render/Office/HwpReader.swift:2196-2196
// swift: Render/Office/HwpReader.swift:2269-2269
// swift: Render/Office/HwpReader.swift:2276-2276
// swift: Render/Office/HwpReader.swift:2282-2282
// swift: Render/Office/HwpReader.swift:2322-2322
// swift: Render/Office/HwpReader.swift:2327-2327
// swift: Render/Office/HwpReader.swift:2337-2337
// swift: Render/Office/HwpReader.swift:2360-2360
// swift: Render/Office/HwpReader.swift:2376-2376
// swift: Render/Office/HwpReader.swift:2405-2405
// swift: Render/Office/HwpReader.swift:2416-2416
// swift: Render/Office/HwpReader.swift:2431-2431
// swift: Render/Office/HwpReader.swift:2437-2437
