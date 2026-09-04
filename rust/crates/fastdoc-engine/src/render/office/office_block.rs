//! swift: Render/Office/OfficeBlock.swift

use swiftshim::{
    CGFloat, CGRect, CGSize, Data, NSColor, NSEdgeInsets, NSFontDescriptor, NSImage,
    NSTextAlignment, SwiftString,
};

/// swift: `NSImage: Equatable` — Swift's `NSObject`-bridged `==` on `NSImage`. `swiftshim::NSImage`
/// derives no `PartialEq` (color_font.rs's own header: "Everything past colour is `todo!()`"), so
/// the handful of structs below that carry one implement `PartialEq` by hand rather than deriving
/// it, comparing the one field the shim actually has (`.size`) — that is also the one field
/// `SizedAttachmentCell`'s own doc comment says is load-bearing for identity here.
fn image_eq(a: &Option<NSImage>, b: &Option<NSImage>) -> bool {
    a.as_ref().map(|i| i.size) == b.as_ref().map(|i| i.size)
}

/// swift: `[String: T]: Equatable` — Swift's `Dictionary` equality needs only `Hashable` keys,
/// which `String` gives it for free. `swiftshim::SwiftString` (convention §3's `NSString`/`String`
/// stand-in) derives `PartialEq, Eq` but not `Hash`, so `HashMap<SwiftString, V>` cannot derive (or
/// even call) `PartialEq` — `std::collections::HashMap`'s own impl requires `K: Eq + Hash`. Compared
/// by linear scan instead, which needs only `PartialEq` on the key.
fn map_eq<V: PartialEq>(
    a: &std::collections::HashMap<SwiftString, V>,
    b: &std::collections::HashMap<SwiftString, V>,
) -> bool {
    a.len() == b.len() && a.iter().all(|(k, v)| b.iter().any(|(k2, v2)| k2 == k && v2 == v))
}

// swift: Span
/// A single formatted run of text — the smallest unit `OfficeTextBuilder` styles. Traits are
/// independent flags, not mutually exclusive: a run can be bold AND italic AND underlined AND
/// `code` at once (an office format's run properties are independent axes, unlike markdown where
/// `` `code` `` can't nest inside `**bold**`) — `code` only changes which FONT/COLOR the run
/// renders with (see `OfficeTextBuilder`), it doesn't suppress the others.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Span {
    pub text: SwiftString,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    /// The underline's STYLE (docx `w:rPr/w:u/@w:val`, §17.18.99 `ST_Underline`) — meaningful only
    /// when `underline` is `true`; a non-underlined span still carries whatever default this field
    /// has, but `OfficeTextBuilder` never reads it in that case. Defaults to `.single`, which is
    /// both `ST_Underline`'s own most common value AND what every span rendered before this field
    /// existed (unconditionally `NSUnderlineStyle.single`). `underline` itself stays the on/off
    /// toggle it always was — see `DocxReader.isOn` — this field only refines what an ON underline
    /// LOOKS like.
    pub underline_style: UnderlineStyle,
    pub code: bool,
    /// docx `w:rPr/w:caps` (§17.3.2.5) — renders the run's text UPPERCASE at build time, without
    /// changing the underlying source model (`OfficeTextBuilder` uppercases only the DISPLAYED
    /// string). Wins over `small_caps` when both are set (matches Word's own precedence — `w:caps`
    /// is the stronger of the two transforms).
    pub caps: bool,
    /// docx `w:rPr/w:small_caps` (§17.3.2.33) — renders lowercase letters as small capitals via an
    /// AppKit font feature, WITHOUT uppercasing the source text (unlike `caps` above) — the glyphs
    /// change, the characters don't.
    pub small_caps: bool,
    /// The link target, if this run is (or is inside) a hyperlink — `nil` for ordinary text. A
    /// later sprint's docx/odt parser resolves relationship ids / `text:a` hrefs down to this
    /// string; this sprint only carries the field through to rendering.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub link: Option<SwiftString>,
    pub strikethrough: bool,
    pub superscript: bool,
    /// Set on the superscript run that REFERENCES a footnote, to that note's own number — the only
    /// link between a marker and its note (`OfficeFootnote.number`), since the glyphs of a marker
    /// are indistinguishable from an exponent's. Becomes `MDAttr.footnote_ref` on the built text.
    /// `nil` on every other run, including an ENDNOTE's marker: an endnote stays in the body flow
    /// and nothing needs to go looking for it.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub footnote_ref: Option<i64>,
    /// A form control the document embedded — a checkbox, a radio button, a button, a field.
    /// `nil` on every ordinary run.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub form_control: Option<super::office_block::OfficeFormControl>,
    /// Where the document switches how many columns its text flows through, carried on the run the
    /// declaration sits at. A declaration is a POSITION, not a property of a section: HWP puts it in
    /// the text, so one document can go to two columns and back. Becomes `MDAttr.column_layout`.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub column_layout: Option<crate::render::office::column_geometry::OfficeColumnLayout>,
    /// Named `subscripted`, not `subscript` — that spelling is a Swift keyword and would need
    /// backticks at every call site (`` `subscript` ``). `superscript`/`subscripted` reads a little
    /// unevenly next to each other, but stays typeable everywhere without ceremony.
    pub subscripted: bool,
    /// Whether THIS run is explicitly marked right-to-left (docx `w:rPr/w:rtl`, a toggle read the
    /// same on/off way as `bold`/`italic` — see `DocxReader.isOn`: present-and-unset-`w:val` is ON,
    /// `w:val="0"`/`"false"` is explicitly OFF). This is a RUN-level override for text embedded
    /// inside a paragraph of the opposite direction (a Latin phrase inside an Arabic sentence, or
    /// the reverse) — it does not, by itself, decide where the paragraph begins; that is
    /// `OfficeBlock`'s own `rtl` (see there for why direction is a paragraph property, not a font
    /// one). ODF's run-level markup (`text:span`) carries no equivalent signal — only a PARAGRAPH
    /// style's `style:writing-mode` — so an ODT-sourced `Span` never sets this; it stays `false`.
    pub rtl: bool,
    /// Bookmark name(s) (docx `w:bookmarkStart`, odt `text:bookmark`/`text:bookmark-start`) whose
    /// target position is the START of this span — empty for ordinary text. `OfficeTextBuilder`
    /// turns a non-empty value into `MDAttr.bookmarkTarget` so an in-document anchor link elsewhere
    /// in the document can jump here by exact name. A span carrying a bookmark is never merged into
    /// its neighbour (see both readers' `appendMerging`) — merging would smear the marker's exact
    /// position across text that predates the bookmark.
    pub bookmarks: Vec<SwiftString>,
    /// The id(s) of the reviewer COMMENT(s) whose commented RANGE this span falls within (docx
    /// `w:commentRangeStart`/`w:commentRangeEnd` @w:id, odt `office:annotation`/
    /// `office:annotation-end` @office:name) — empty for ordinary text, matching `OfficeComment.id`.
    /// A span can carry more than one id when two comments' ranges overlap — always APPENDED, never
    /// replaced. A span carrying a comment id is never merged into its neighbour (see both readers'
    /// `appendMerging`), the same reasoning as `bookmarks` above: merging would smear the range's
    /// exact extent across text that predates or postdates it. This sprint (P6a) only CAPTURES this
    /// — no view draws a highlight or a sidebar from it yet (P6b).
    pub comment_ids: Vec<SwiftString>,
    /// The run's authored text colour, already resolved to a literal RGB — `nil` means the source
    /// didn't specify one (or, for a THEME colour reference such as docx `w:color/@themeColor`,
    /// that a reader hasn't resolved it to a literal value yet; resolving those references against
    /// the document's theme part is later work, but this field is exactly where that resolved
    /// colour goes once it exists — nothing about this vocabulary or `OfficeTextBuilder` needs to
    /// change to receive it). `nil` is NOT "black" — `OfficeTextBuilder` decides what an unset (or,
    /// per its own judgement call, a near-neutral authored) colour renders as; see its
    /// `resolvedTextColor`.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub text_color: Option<NSColor>,
    /// The run's highlighter/background colour (docx `w:highlight`/`w:shd`, odt
    /// `style:text-background-color`) — `nil` for no highlight. Unlike `text_color`, a highlight is
    /// never reinterpreted against the reading theme: painting a background behind text is already
    /// an unambiguous, deliberate mark (there's no "ordinary black highlight" the way there's
    /// "ordinary black body text"), so it is always drawn exactly as authored.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub highlight_color: Option<NSColor>,
    /// The run's LETTER SPACING as a percentage of its own em (HWP `CharShape.spacings`, 자간, −50…50;
    /// docx `w:spacing` states the same thing in twentieths of a point and a reader converts). `nil`
    /// = the source said nothing, and the font's own spacing stands. A percentage rather than points
    /// deliberately: the value has to survive the reader's zoom, and every absolute length in this
    /// vocabulary is already scaled at build time for the same reason.
    ///
    /// HWP states it PER SCRIPT, and this carries ONE value — so a reader fills it only when the
    /// document's seven slots agree, which they do in 95.9% of the 52,451 real char shapes that
    /// state it at all. A shape whose slots disagree carries nothing rather than one script's answer
    /// applied to all of them.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub letter_spacing_percent: Option<CGFloat>,
    /// The run's GLYPH WIDTH as a percentage of its own em (HWP `CharShape.ratios`, 장평, 50…200).
    /// `nil` = the source said nothing and the glyphs keep the face's own advance. Like letter
    /// spacing this is a PAGINATION fact rather than a flourish: a Korean government document sets
    /// its body at 95–99% and a reader drawing 100% breaks every line early, which compounds into
    /// whole sheets wherever the document also declares a hard page break.
    ///
    /// Filled under the same all-slots-agree rule as `letter_spacing_percent` (93.3% agree).
    #[serde(rename = "widthScalePercent", skip_serializing_if = "Option::is_none", default)]
    pub width_scale_percent: Option<CGFloat>,
    /// The run's baseline shift as a percentage of its own em (HWP `CharShape.char_offsets`, 글자
    /// 위치), positive being UP. Distinct from `superscript`/`subscripted`, which also resize.
    /// Filled under the same all-slots-agree rule as `letter_spacing_percent` (99.7% agree).
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub baseline_offset_percent: Option<CGFloat>,
    /// The colour of this run's UNDERLINE, when the document states one distinct from the text
    /// (HWP `CharShape.underline_color`, docx `w:u/@w:color`). `nil` = the underline takes the
    /// text's own colour, which is what every underline did before this existed.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub underline_color: Option<NSColor>,
    /// The colour of this run's STRIKETHROUGH, same rule as `underline_color`.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub strikethrough_color: Option<NSColor>,
    /// The run's authored font size, in POINTS — a reader converts from its own source unit before
    /// constructing this (docx `w:sz`/`w:szCs` are HALF-points; ODT `fo:font-size` is already
    /// points). `nil` means the source didn't specify a size for this run — see
    /// `OfficeTextBuilder.build`'s `documentDefaultFontSize` parameter for exactly how a non-nil
    /// value becomes a rendered size (the model is Word's own: authored size scaled by the ratio
    /// between the user's chosen reading size and the document's own default body size, so a
    /// heading stays proportionally larger than body text at ANY reading size, and the reading-size
    /// setting still governs how big the whole document looks).
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub font_size: Option<CGFloat>,
    /// The run's authored font FAMILY name (docx `w:rFonts/@w:ascii`, odt `style:font-name`) —
    /// `nil` means "the theme's own body/heading/code font", exactly as before this field existed.
    /// Never applied to a `code` span: `OfficeTextBuilder`'s inline-code styling is a single,
    /// consistent monospaced look across the whole app (see `Palette`'s "one deliberate spot of
    /// color" reasoning) — letting an authored family override it would make some code spans
    /// inconsistent with others for no reason a reader would understand.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub font_name: Option<SwiftString>,
    /// The SUBSTITUTE font's `NSFontDescriptor`, resolved ONCE at read time by
    /// `FontSubstitutionResolver` and never touched again.
    ///
    /// `nil` is the overwhelmingly common case and means **"this span's declared font draws the
    /// SAMPLE character the document's census picked for that font"** — not, as this doc claimed
    /// until the survey-and-apply design replaced the per-span one, that it covers every character
    /// in the span. The difference is real and a reader should know it: a Times New Roman paragraph
    /// whose census answers with a Latin letter comes back `nil` even though a stray Ⅴ or a
    /// Wingdings bullet inside it has no glyph there, and AppKit substitutes that one character at
    /// draw time exactly as it always did. That is the deliberate trade — see
    /// `docs/font-substitution-cost-design.md` §6 — bought because asking per span cost 2,209
    /// CoreText calls on the reference document where asking per declared font costs 22.
    ///
    /// `OfficeTextBuilder` constructs a `nil` span's font completely UNCHANGED, which is the
    /// byte-identical path invariant 37 depends on. Non-`nil` carries the descriptor of the font
    /// `CTFontCreateForString` itself chose for that sample — never a family of this app's own
    /// picking — and is stamped across the span's WHOLE text: the resolver no longer splits a span
    /// at all, because splitting on coverage was measured to create the very fragmentation this
    /// field exists to remove (reference document: 17,910 spans against 9,328 without it).
    ///
    /// A DESCRIPTOR, deliberately NOT a PostScript name string (this field's first shape, changed
    /// after measuring why it silently did nothing): the theme's body/heading fonts are `.systemFont`,
    /// Apple's PRIVATE system-UI face (`NSFont.font_name == ".AppleSystemUIFont"`), and CoreText's
    /// cascade for it substitutes OTHER private, dot-prefixed faces (`".AppleSDGothicNeoI-Regular"`,
    /// measured) — `NSFont(name:size:)` cannot construct those (CoreText logs a warning and returns
    /// `nil`), so a name-based field left this swap silently inert while the installed-run count
    /// stayed exactly where it started. `NSFont(descriptor:size:)` — the SAME reconstruction idiom
    /// `OfficeTextBuilder`'s own size-scaling and `fontAdding` already use elsewhere in this file for
    /// these very private system faces — rebuilds it correctly (verified: a descriptor captured from
    /// `CTFontCreateForString`'s result reconstructs at any size and still covers the text it was
    /// resolved for). A `font_name`-override span's substitute is a normal public font and reconstructs
    /// either way; the descriptor form costs nothing there and fixes the private-face case everywhere.
    ///
    /// A span whose declared font covers SOME but not all of its characters is split by the resolver
    /// into multiple `Span`s at read time (one per maximal same-substitute run), each carrying its
    /// own value here — this field is never "some characters use it, others don't" within one span.
    /// NOT serialised — it is an AppKit handle, and a face identity cannot survive being written
    /// down and read back on the other side. Nothing is lost across the boundary because nothing is
    /// there yet: the readers leave this nil and `resolvingFontSubstitution()` fills it afterwards,
    /// on the host. `assert_exportable` refuses a tree where that is not true, so the skip can
    /// never quietly drop a resolved face.
    #[serde(skip)]
    pub resolved_font_descriptor: Option<NSFontDescriptor>,
    /// A live page-number FIELD this span stands in for (docx `PAGE`/`NUMPAGES` — see
    /// header-footer-design.md §5), or `nil` for ordinary text. The span's own `text` still carries
    /// the document's CACHED result (Word's last-computed value, stale the moment the page reflows
    /// under a real reader), so a document with no live-substitution step yet — every one today —
    /// renders EXACTLY what it always would; this field only marks the span for a later pagination
    /// sprint to find and replace at draw time. Never set for `STYLEREF` (header-footer-design.md
    /// §7: no live value is planned for it — its cached result is kept as the honest stand-in), nor
    /// for any other field name this reader doesn't recognize.
    ///
    /// A span carrying a marker is never merged with its neighbour, in either direction (see both
    /// readers' `appendMerging`) — the same reasoning `bookmarks`/`comment_ids` document: merging
    /// would smear the substitutable text into literal characters that must never be replaced (the
    /// dashes around a page number, say), which is exactly the boundary a live substitution needs
    /// intact.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub page_number_field: Option<PageNumberField>,
}

/// A plain, unformatted text run — every trait off, every optional unset. Requested by the docx/odt
/// readers so `Span { text: ..., ..Default::default() }` can build a run without restating every
/// field; matches the zero-value every `Span` had for a field before that field existed.
impl Default for Span {
    fn default() -> Self {
        Span {
            text: SwiftString::default(),
            bold: false,
            italic: false,
            underline: false,
            underline_style: UnderlineStyle::default(),
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
            bookmarks: vec![],
            comment_ids: vec![],
            text_color: None,
            highlight_color: None,
            letter_spacing_percent: None,
            width_scale_percent: None,
            baseline_offset_percent: None,
            underline_color: None,
            strikethrough_color: None,
            font_size: None,
            font_name: None,
            resolved_font_descriptor: None,
            page_number_field: None,
        }
    }
}

// swift: PageNumberField
/// Which live page-number field a span stands in for — see `Span.page_number_field`'s own doc.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PageNumberField {
    // swift: PageNumberField
    Page,
    // swift: PageNumberField
    NumPages,
}

// swift: UnderlineStyle
/// An underline's drawn style — docx `w:rPr/w:u/@w:val` (§17.18.99 `ST_Underline`), collapsed from
/// that enumeration's ~20 named values down to the handful AppKit can actually distinguish.
/// `DocxReader` maps `double`→`.double`; `dotted`/`dottedHeavy`→`.dotted`; every `dash*` variant
/// (`dash`/`dashLong`/`dashedHeavy`/…)→`.dashed`; every `wave*` variant (`wave`/`wavyHeavy`/
/// `wavyDouble`)→`.wavy`; anything else, including `single` itself and an absent/unrecognized
/// `@w:val`, →`.single`. Only consulted when `Span.underline` is `true` — see that field's doc.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum UnderlineStyle {
    // swift: UnderlineStyle
    Single,
    Double,
    Dotted,
    Dashed,
    Wavy,
}

/// `Span.underline_style`'s own default value (see field doc: "Defaults to `.single`") — the
/// value every span carried before this field existed.
impl Default for UnderlineStyle {
    fn default() -> Self {
        UnderlineStyle::Single
    }
}

// swift: OfficeGradient
/// A gradient fill the document DECLARED — stops and angle, exactly as stated, never a rendered
/// bitmap. S6-4: `Cell.background_image`/`TableFormat.background_image` merge a real document
/// picture with a reader-SYNTHESIZED 64×64 gradient bitmap into one `Option<NSImage>` (`HwpReader
/// .gradientImage`/`mapping.rs`'s own `gradient_image`, kept for the host's existing draw path),
/// which the wire tree cannot tell apart from an authored picture without carrying the bitmap as
/// if the document had declared it — a fabrication. This field is the document's own fact instead:
/// populated ONLY when no real picture won the fill (`fill_image` returned `None`), mirroring the
/// same `fill_image(...).or_else(gradient_image(...))` priority the image field already resolves
/// by, so the two fields are never both "the deciding one" for the same cell/table.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct OfficeGradient {
    pub stops: Vec<NSColor>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub angle_degrees: Option<CGFloat>,
}

// swift: Cell
/// One cell of a table row. Only ANCHOR cells — the top-left corner of a merge — appear in
/// `OfficeBlock.table`'s `rows`; a grid position covered by another cell's `row_span`/`col_span` is
/// simply absent, not present-and-empty. `TableBlockBuilder` derives which columns those covered
/// positions land in at render time, the same way `NSTextTableBlock` itself only needs to be told
/// about anchors. All-1 spans (this sprint's parsers emit nothing else yet) reproduce a plain
/// rectangular grid exactly — one `Cell` per visible position, nothing skipped.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct Cell {
    /// A cell's content is the SAME format-neutral block vocabulary as the top of a document —
    /// a paragraph, heading, list item, image, or (flattened, never a real nested grid — see
    /// `OfficeTextBuilder`'s cell renderer) another table — not a bare run of spans. That is what
    /// gives an image or a list item inside a cell somewhere to go at all: before this sprint
    /// `Cell` could only ever hold formatted text, so both `.image` and `.listItem` collection had
    /// to be skipped the moment the cell walk found them (gap-list rows 6 and 7). Rendering
    /// recurses through `OfficeTextBuilder`'s existing per-block machinery rather than growing a
    /// second, cell-only set of cases.
    pub blocks: Vec<OfficeBlock>,
    pub row_span: i64,
    pub col_span: i64,
    /// The cell's own shading (docx `w:tcPr/w:shd/@w:fill`, odt `style:background-color` on the
    /// cell's style) — `nil` means unshaded, which `TableBlockBuilder` still shades with
    /// `Palette.tableHeaderBg` for a header row exactly as it did before this field existed (an
    /// explicit `background_color` on a HEADER cell overrides that theme shading; on a body cell it
    /// is the only shading there is).
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub background_color: Option<NSColor>,
    /// The cell's own PICTURE fill, already decoded. HWP is the only format here that fills a cell
    /// with an image, and it does so constantly: measured on one manual, 352 of its 821 fill
    /// definitions are pictures and 610 cells use one — the rounded frames and tinted panels a
    /// Korean document is built out of. A reader that knows only `background_color` renders all of
    /// them as blank paper. `nil` everywhere else, and nil from `mapJSON` alone (the bytes need the
    /// parse handle, so `HwpReader.read` is what fills it).
    /// Only `HwpReader` fills this (HWP has no archive a host could resolve a picture from later);
    /// the zip readers leave it nil and the host loads the picture from the archive it already
    /// holds. S6-4: SERIALISED as ordinary decoded bytes (`NSImage` already derives `Serialize`,
    /// the same shape `OfficeMasterObjectContent::Image` used honestly since S6-2) — previously
    /// `#[serde(skip)]` and refused by `assert_exportable`, which silently dropped a real picture
    /// from the schema-v4 envelope the moment the refusal was lifted without this change too. See
    /// `background_gradient` just below for the other half of this field's old ambiguity.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub background_image: Option<NSImage>,
    /// See `OfficeGradient`'s own doc (above `Cell`) for why this exists beside `background_image`
    /// rather than folded into it. `nil` whenever a real picture won the fill, or the source
    /// declared no gradient at all.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub background_gradient: Option<OfficeGradient>,
    /// The cell's own border colour/width (docx `w:tcPr/w:tcBorders`, odt cell-style borders) —
    /// either or both may be `nil`, in which case `TableBlockBuilder`'s existing theme default
    /// (`Palette.tableBorder` at 1pt) is used for that one, exactly as before this field existed.
    /// A real per-edge border model (top/bottom/left/right independently) is out of this sprint's
    /// scope — both readers' input formats can express far more than this vocabulary carries yet,
    /// and one uniform colour/width already covers the measured "borders" need without inventing
    /// four fields no parser fills in this sprint.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub border_color: Option<NSColor>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub border_width: Option<CGFloat>,
    /// The cell's own FOUR edges when the document declared them individually (docx `w:tcBorders`).
    /// Takes precedence over `border_color`/`border_width`, which stay as the uniform model every other
    /// format and markdown still use. `nil` = this cell said nothing per-edge → unchanged behaviour.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub edge_borders: Option<EdgeBorders>,
    /// Where `edge_borders` is, when the wire filed it in the envelope's table instead of repeating
    /// it here — see `edge_border_pool`. Exactly one of the two is ever set on the wire, and this
    /// one is always `None` in memory, so a result that round-trips equals the one that was read.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub edge_borders_ref: Option<u32>,
    /// The cell's own declared column width in POINTS (docx `w:tcPr/w:tcW`, converted from twips;
    /// odt column widths) — `nil` leaves `TableBlockBuilder`'s existing auto layout (equal-ish,
    /// content-driven column sizing via the table's own `percentageValueType`) untouched, exactly
    /// as before this field existed. Set on the grid's anchor cells; a merged cell's covered
    /// positions have no `Cell` of their own to carry a width at all (see `OfficeBlock.table`'s doc
    /// comment on anchor-only rows).
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub width: Option<CGFloat>,
    /// The cell's own vertical alignment (docx `w:tcPr/w:vAlign/@w:val` — `top`/`center`/`bottom`;
    /// ODT, P4, carries no equivalent yet) — `nil` means the source didn't say, which is also
    /// Word's own default (`top`), so `TableBlockBuilder` leaves `NSTextTableBlock`'s already-`.top`
    /// vertical alignment untouched rather than setting it explicitly. `CellVAlign` is a closed
    /// three-case vocabulary rather than reusing `NSTextBlock.VerticalAlignment` directly so the
    /// reader stays free of AppKit's own `.baseline` case, which no source format expresses.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub vertical_alignment: Option<CellVAlign>,
    /// The cell's own resolved cell margin/padding, in POINTS, ALREADY resolved by the reader
    /// against the table's default before reaching this struct (docx: per-cell `w:tcPr/w:tcMar` →
    /// table-wide `w:tblPr/w:tblCellMar` → `nil`; odt `fo:padding`/its per-side fallbacks) — `nil`
    /// means neither the cell nor its table said anything, and `TableBlockBuilder` keeps its own
    /// pre-existing 7pt default exactly as before this field existed. A uniform value, mirroring
    /// `border_color`/`border_width`'s same simplification: this reader takes the START/left edge as
    /// representative (the same edge `ParagraphFormat.indent_start` reads for indentation).
    ///
    /// Consulted ONLY by the non-paged (window-filling) rendering model — a PAGED document uses
    /// `edge_padding` below instead, where four independent edges genuinely matter (Word's own stock
    /// `w:tblCellMar` default is `top=bottom=0, left=right=5.4pt`, and smearing that 5.4pt onto top
    /// and bottom is exactly the "표가 너무 큼" defect this field's sibling exists to fix).
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub padding: Option<CGFloat>,
    /// The cell's own FOUR edges of padding/inset, independently — docx `w:tcPr/w:tcMar` (this
    /// cell's own declaration ONLY; the table's `w:tblPr/w:tblCellMar` default lives on
    /// `TableFormat.default_padding`, and the two are combined per edge by `TableBlockBuilder`,
    /// mirroring `EdgeBorders`' cell-then-table cascade), odt `fo:padding-{top,left,bottom,right}`
    /// (falling back to the uniform `fo:padding` shorthand per edge). `nil` per edge means THAT
    /// edge wasn't declared, carried through undiminished — a genuinely-zero edge must stay
    /// distinguishable from an edge nobody mentioned, invariant 47's discipline reused here for
    /// padding instead of borders. Consulted ONLY by the PAGED table-geometry model
    /// (`TableBlockBuilder.build`'s own per-edge resolution); the non-paged model keeps using the
    /// single `padding` value above, unaffected — this field did not exist before it, so a
    /// non-paged document renders byte-identical whether or not its reader populates this.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub edge_padding: Option<EdgePadding>,
    /// The row height the DOCUMENT declared for this cell, in points — `nil` when it said nothing.
    ///
    /// It is the only authority for a row that holds no text. A Korean document builds its section
    /// headings and panels out of tables with DECORATIVE BANDS: rows a couple of points high, every
    /// cell empty, drawn as a thin rule of colour. A reader that measures such a row by its content
    /// gives the empty paragraph a full line box and inflates the band five-fold. Measured on
    /// `2025_행정업무운영편람_최종.hwp`: of 1,980 rows, 213 are declared under 5pt and 198 of those
    /// are entirely empty, with 419 more between 5 and 15pt — every one of them taller here than the
    /// document asked for.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub declared_height: Option<CGFloat>,
    /// The cell's own DIAGONAL, when the document drew one across it. `nil` = no diagonal, which is
    /// every cell of every other format this reader opens — only HWP states one, and the decision of
    /// whether a declaration IS a drawn diagonal is made by the parser (`BorderFill::cell_diagonal`),
    /// never re-derived here. Two thirds of the raw declarations are not diagonals at all, so a
    /// reader that judged them itself would rule lines across cells the document left plain.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub diagonal: Option<CellDiagonal>,
    /// The cell's shading RESOLVED from the table's named STYLE (docx `w:tbl/w:tblPr/w:tblStyle`
    /// cascaded through that style's `w:tblStylePr` conditional blocks for this cell's grid
    /// position — P5) — `nil` means the table either has no named style, or that style has no
    /// shading applicable to this position. A LOWER-priority layer than `background_color`
    /// (this cell's own direct `w:tcPr/w:shd`) and the table's own DIRECT default
    /// (`TableFormat.default_shading`): `TableBlockBuilder` only falls to this when both of those
    /// are `nil`, and falls further still to the header theme colour when this is `nil` too.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub style_shading: Option<NSColor>,
    /// The cell's border colour/width RESOLVED from the table's named STYLE, mirroring
    /// `style_shading`'s doc — same lower-priority layer, same position-conditional resolution.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub style_border_color: Option<NSColor>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub style_border_width: Option<CGFloat>,
}

impl PartialEq for Cell {
    fn eq(&self, other: &Self) -> bool {
        let Self {
            blocks, row_span, col_span, background_color, background_image, background_gradient,
            border_color, border_width, edge_borders, edge_borders_ref, width, vertical_alignment,
            padding, edge_padding, declared_height, diagonal, style_shading, style_border_color, style_border_width,
        } = self;
        blocks == &other.blocks
            && row_span == &other.row_span
            && col_span == &other.col_span
            && background_color == &other.background_color
            && image_eq(background_image, &other.background_image)
            && background_gradient == &other.background_gradient
            && border_color == &other.border_color
            && border_width == &other.border_width
            && edge_borders == &other.edge_borders
            && edge_borders_ref == &other.edge_borders_ref
            && width == &other.width
            && vertical_alignment == &other.vertical_alignment
            && padding == &other.padding
            && edge_padding == &other.edge_padding
            && declared_height == &other.declared_height
            && diagonal == &other.diagonal
            && style_shading == &other.style_shading
            && style_border_color == &other.style_border_color
            && style_border_width == &other.style_border_width
    }
}

/// An empty single-position cell — one blank block, unmerged, nothing shaded or bordered. Requested
/// by the docx/odt readers so `Cell { blocks: vec![...], ..Default::default() }` can build a cell
/// without restating every optional field; `row_span`/`col_span` default to `1` (the un-merged
/// case), matching `Cell::new`/`Cell::new_with_spans`'s own defaults.
impl Default for Cell {
    fn default() -> Self {
        Cell {
            blocks: vec![],
            row_span: 1,
            col_span: 1,
            background_color: None,
            background_image: None,
            background_gradient: None,
            border_color: None,
            border_width: None,
            edge_borders: None,
            edge_borders_ref: None,
            width: None,
            vertical_alignment: None,
            padding: None,
            edge_padding: None,
            declared_height: None,
            diagonal: None,
            style_shading: None,
            style_border_color: None,
            style_border_width: None,
        }
    }
}

impl Cell {
    /// Back-compat convenience for the many construction sites (both readers' plain-text cells,
    /// most existing tests) that only ever need a cell of formatted text — wraps the spans in a
    /// single `.paragraph`, which `OfficeTextBuilder` renders BYTE-IDENTICAL to the pre-sprint
    /// direct-spans path: no block-level separator is added around a lone paragraph, so a
    /// plain-text cell looks exactly as it did before `Cell` could hold anything else.
    ///
    /// Overload label `_with_spans` — Swift's `init(spans:rowSpan:colSpan:)` overload of `init`.
    pub fn new_with_spans(spans: Vec<Span>, row_span: i64, col_span: i64) -> Cell {
        Cell {
            blocks: vec![OfficeBlock::Paragraph {
                spans,
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
                format_ref: None,
            }],
            row_span,
            col_span,
            background_color: None,
            background_image: None,
            background_gradient: None,
            border_color: None,
            border_width: None,
            edge_borders: None,
            edge_borders_ref: None,
            width: None,
            vertical_alignment: None,
            padding: None,
            edge_padding: None,
            declared_height: None,
            diagonal: None,
            style_shading: None,
            style_border_color: None,
            style_border_width: None,
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn new(
        blocks: Vec<OfficeBlock>,
        row_span: i64,
        col_span: i64,
        background_color: Option<NSColor>,
        background_image: Option<NSImage>,
        border_color: Option<NSColor>,
        border_width: Option<CGFloat>,
        edge_borders: Option<EdgeBorders>,
        width: Option<CGFloat>,
        vertical_alignment: Option<CellVAlign>,
        padding: Option<CGFloat>,
        edge_padding: Option<EdgePadding>,
        diagonal: Option<CellDiagonal>,
    ) -> Cell {
        Cell {
            blocks,
            row_span,
            col_span,
            declared_height: None,
            background_color,
            background_image,
            background_gradient: None,
            border_color,
            border_width,
            edge_borders,
            edge_borders_ref: None,
            width,
            vertical_alignment,
            padding,
            edge_padding,
            diagonal,
            style_shading: None,
            style_border_color: None,
            style_border_width: None,
        }
    }
}

// swift: OfficePageNumberRestart
/// One "start the page numbering again here" instruction, resolved to the block that carries it.
#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct OfficePageNumberRestart {
    pub block: i64,
    pub number: i64,
}

// swift: CellVAlign
/// A cell's vertical alignment — docx `w:tcPr/w:vAlign/@w:val`. See `Cell.vertical_alignment`'s own
/// doc comment for why this is a closed three-case vocabulary rather than AppKit's own
/// `NSTextBlock.VerticalAlignment`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CellVAlign {
    // swift: OfficeGradient
    Top,
    Center,
    Bottom,
}

// swift: CellDiagonal
/// A table's OWN default border/shading — docx `w:tbl/w:tblPr/w:tblBorders` and
/// `w:tbl/w:tblPr/w:shd/@w:fill` — that every cell in the table inherits unless it declares its
/// own (see `Cell.border_color`/`.background_color`). Mirrors `Cell`'s own uniform-border
/// simplification: `w:tblBorders` can express four edges (plus `inside_h`/`inside_v`) independently,
/// and this reader takes the first drawn edge, same as `Cell`'s own border reading. `nil` in any
/// field means the table didn't declare one — `TableBlockBuilder` falls through past it to its
/// existing theme default (`Palette.tableBorder`/1pt/header shading), exactly as before this
/// struct existed. A table with no `w:tblPr` at all (every markdown table; any docx table that
/// declares neither) constructs the all-`nil` default, which renders BYTE-IDENTICAL to before.
/// One DRAWN edge of a border, exactly as the document declared it: a width in points and an
/// optional colour (`nil` = the theme decides, OOXML's `w:color="auto"`). This type describes ONLY
/// an edge that is drawn — "the document turned this edge off" and "the document never mentioned
/// this edge" are two further states, and they are carried by `BorderDecl`/`EdgeBorders` below, not
/// by this struct's presence or absence.
/// A rule drawn ACROSS a cell rather than around it — the line a Korean document puts through a
/// cell to mean "this box is deliberately empty" (해당 없음), and the `X` it puts through a table's
/// corner header cell.
///
/// Not an `EdgeBorders` case: an edge is a boundary BETWEEN two cells and is resolved against its
/// neighbour, while a diagonal belongs to one cell alone and never participates in border collapse.
/// Folding it into the edge vocabulary would have put it through that resolution and let a
/// neighbour's declaration erase it.
///
/// Measured before it was built: of 637 real documents, 47 draw one and they hold 208 such cells —
/// rare enough that it is a decoration rather than a defect, common enough that the reader was
/// silently dropping a mark the document made on purpose. Every one of the three directions occurs.
#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct CellDiagonal {
    pub direction: CellDiagonalDirection,
    /// The line's own width, colour and dash — the SAME vocabulary an edge uses, because HWP states
    /// a diagonal's type in the same 18-value enum it states an edge's in. Reusing `BorderSide` is
    /// what gives a dotted diagonal its dots for free.
    pub side: BorderSide,
}

// swift: CellDiagonal.Direction
/// `CellDiagonal.Direction` in Swift — which way the line runs, from the reader's point of view —
/// `slash` is bottom-left to top-right (`/`), `backslash` top-left to bottom-right (`\`), `both` is
/// the `X`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CellDiagonalDirection {
    Slash,
    Backslash,
    Both,
}

// swift: BorderSide
#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct BorderSide {
    pub width: CGFloat,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub color: Option<NSColor>,
    /// How the rule is DRAWN. All three office formats state this and all three used to drop it, so a
    /// document's dotted rule was painted as a solid one — measured on one Korean manual, 59 of its
    /// 1,097 declared edges are dotted and 13 are double, and the dotted ones are the boxes a reader
    /// notices, because a dotted frame reads as "example/annotation" and a solid frame as a real table.
    /// A style this reader cannot draw (wavy, the 3-D bevels) resolves to the nearest thing it can,
    /// never to nothing — see each reader's own mapping.
    pub style: BorderLineStyle,
}

impl Default for BorderSide {
    fn default() -> Self {
        BorderSide { width: 0.0, color: None, style: BorderLineStyle::Solid }
    }
}

// swift: BorderLineStyle
/// The four ways a table rule can be PAINTED, which is all the vocabulary this reader can honour:
/// docx `w:val`, ODF's `fo:border` style token and HWP's own 18-value line-type enum all collapse
/// into these. Deliberately NOT a copy of any one format's list — a `dashDotStroked` and a
/// `dash-dot` are the same picture on screen, and carrying eighteen cases would oblige the painter
/// to invent seventeen dash patterns nobody can tell apart at a 0.3pt rule.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BorderLineStyle {
    Solid,
    Dashed,
    Dotted,
    Double,
}

// swift: BorderDecl
/// What a document said about ONE edge — the three states the renderer has to tell apart:
///
/// - `.drawn(side)` — a real border, at that width/colour.
/// - `.suppressed` — the document explicitly turned this edge OFF (`w:val="none"`/`"nil"`). Nothing
///   is drawn there and nothing is inherited or substituted in its place.
/// - `nil` (the edge's `BorderDecl?` in `EdgeBorders` below) — the document never mentioned it. A
///   cell's unmentioned edge inherits the table's; if the TABLE drew a box and still never named
///   this edge, nothing is drawn, and if the table drew no box at all the edge falls back to the
///   ordinary cell > table > style > theme cascade — see `TableBlockBuilder`'s per-placement
///   resolution. The distinction from `.suppressed` is what keeps one cell's lone "off" from
///   stripping its own other three edges of that cascade.
///
/// One enum rather than a side plus a parallel "was this declared" mask: two sources of truth for
/// the same fact can disagree, and a disagreement here surfaces as a stray or missing rule on screen.
#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BorderDecl {
    // swift: BorderLineStyle
    Drawn(BorderSide),
    // swift: BorderLineStyle
    Suppressed,
}

// swift: EdgeBorders
/// A cell's four edges — and, when this describes a TABLE, the two interior directions Word states
/// separately (`w:inside_h`/`w:inside_v`), which apply to the edges between cells rather than around
/// the table.
///
/// Why per-edge at all: real reports declare edges INDIVIDUALLY — a measured example gives one row
/// "top = solid 1pt blue, bottom = dotted 0.5pt" and the next "top and bottom both dotted 0.5pt".
/// Collapsing that to one width per cell (what this vocabulary did before) made each row's whole box
/// take a different weight and colour, which is exactly the ragged look a reader notices. It also
/// perturbed the content width, since that subtracts the border twice.
#[derive(Clone, Copy, Debug, PartialEq, Default, serde::Serialize, serde::Deserialize)]
pub struct EdgeBorders {
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub top: Option<BorderDecl>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub left: Option<BorderDecl>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub bottom: Option<BorderDecl>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub right: Option<BorderDecl>,
    // swift: BorderDecl
    /// Table-level only: the horizontal/vertical edges BETWEEN cells.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub inside_h: Option<BorderDecl>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub inside_v: Option<BorderDecl>,
}

impl EdgeBorders {
    /// True only when the document said NOTHING about any of the six edges. A set of edges that are
    /// all `.suppressed` is NOT empty — "every border is off" is a declaration, and a reader that
    /// erased it here would hand the renderer the same input as silence, which is what makes the
    /// renderer fall back to its own default rule (exactly the border the document turned off).
    pub fn is_empty(&self) -> bool {
        self.top.is_none()
            && self.left.is_none()
            && self.bottom.is_none()
            && self.right.is_none()
            && self.inside_h.is_none()
            && self.inside_v.is_none()
    }

    /// True when at least one edge is a real rule. This is what separates "the document drew a box
    /// here and left some edges out of the description" from "the document only ever turned edges
    /// OFF" — only the first is missing anything worth standing in for. Suppression-only and silence
    /// both answer `false`, deliberately: neither started a box.
    pub fn draws_any_edge(&self) -> bool {
        [self.top, self.left, self.bottom, self.right, self.inside_h, self.inside_v]
            .iter()
            .any(|e| matches!(e, Some(BorderDecl::Drawn(_))))
    }
}

// swift: EdgePadding
/// A cell's (or a table's own default) four edges of PADDING/INSET, in POINTS, independently —
/// `Cell.edge_padding`'s and `TableFormat.default_padding`'s shared shape. Only two states per edge
/// (unlike `BorderDecl`'s three): a declared value, which may legitimately be `0`, or `nil` meaning
/// the edge wasn't declared at all — there is no "explicitly turned off" equivalent for padding the
/// way `.suppressed` exists for a border, so a plain optional says everything this needs to. `nil`
/// is carried through undiminished rather than defaulted here so a genuinely-zero edge (Word's own
/// stock `w:tblCellMar` is `top=bottom=0, left=right=5.4pt`) stays distinguishable from an edge
/// nobody mentioned — the same discipline `EdgeBorders`/`BorderDecl` apply to borders, reused here
/// for padding. Consulted ONLY by the PAGED table-geometry model; see `Cell.edge_padding`'s own doc
/// for why the non-paged (window-filling) model keeps its separate, single-value `Cell.padding`.
#[derive(Clone, Copy, Debug, PartialEq, Default, serde::Serialize, serde::Deserialize)]
pub struct EdgePadding {
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub top: Option<CGFloat>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub left: Option<CGFloat>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub bottom: Option<CGFloat>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub right: Option<CGFloat>,
}

// swift: EdgePadding
/// `extension OfficeBlock` in Swift.
impl OfficeBlock {
    // swift: OfficeBlock.aligningGraphic
    /// Returns this block with the CONTAINING paragraph's alignment applied, if it is a graphic and
    /// doesn't already carry one of its own. Shared by every reader so "a figure inherits its
    /// paragraph's alignment" is stated once instead of re-derived per format — a graphic's own
    /// explicit alignment (should a format ever supply one) always wins, and a non-graphic block is
    /// returned untouched.
    pub fn aligning_graphic(self, alignment: Option<NSTextAlignment>) -> OfficeBlock {
        let Some(alignment) = alignment else { return self };
        match self {
            OfficeBlock::Image { id, size, alignment: own } => {
                OfficeBlock::Image { id, size, alignment: Some(own.unwrap_or(alignment)) }
            }
            OfficeBlock::UnsupportedGraphic { label, size, alignment: own } => {
                OfficeBlock::UnsupportedGraphic { label, size, alignment: Some(own.unwrap_or(alignment)) }
            }
            other => other,
        }
    }
}

// swift: TableFormat
#[derive(Clone, Debug, Default, serde::Serialize, serde::Deserialize)]
pub struct TableFormat {
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub default_border_color: Option<NSColor>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub default_border_width: Option<CGFloat>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub default_shading: Option<NSColor>,
    // swift: OfficeBlock.aligningGraphic
    /// The TABLE's own picture fill, painted once across the whole grid rather than repeated per
    /// cell — HWP's rounded annotation box is exactly this: one image behind a table whose cells
    /// declare nothing at all (55 tables in one measured manual). Filled by `HwpReader.read`, nil
    /// for every other format and for `mapJSON` alone.
    /// Only `HwpReader` fills this (HWP has no archive a host could resolve a picture from later);
    /// the zip readers leave it nil and the host loads the picture from the archive it already
    /// holds. S6-4: SERIALISED — see `Cell.background_image`'s own doc for why the old
    /// `#[serde(skip)]` had to go together with the refusal that used to guard it.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub background_image: Option<NSImage>,
    /// See `Cell.background_gradient`'s own doc — same split, table-scoped.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub background_gradient: Option<OfficeGradient>,
    // swift: TableFormat
    /// The table's own total width in POINTS as the SOURCE document laid it out (docx `w:tblGrid`
    /// twips summed, HWP's HWPUNIT column widths summed, ODF `style:column-width` summed) — `nil`
    /// when the format states only proportions (ODF `style:rel-column-width`) or nothing at all.
    ///
    /// Used for TWO things, one original and one added by the paged-geometry work. Originally: a
    /// picture inside a cell is sized against THIS width, not the page width. The NON-paged model
    /// stretches every table to fill the reading column (invariant 39), so a table that was half the
    /// page wide in the source becomes twice as wide relative to its content there — a picture scaled
    /// against the page would then sit small in a cell that grew around it. Scaling against the
    /// table's own width keeps the picture's share of its cell exactly as authored, at any window
    /// size. Each reader converts to points itself, so this field has ONE unit whatever the format
    /// stored (a mixed-unit field is how a "source width" quietly becomes twips here and points
    /// there). Second, for a PAGED document: the table itself is laid out at this width (clamped to
    /// the reading column, never wider) rather than stretched to fill it — `TableBlockBuilder`'s own
    /// `GridTextTable.maxWidth`. `nil` (every markdown table, and any office table whose grid total
    /// wasn't readable) leaves a paged table exactly as before this second use — filling the column.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub source_width: Option<CGFloat>,
    /// The table's own declared edges, INCLUDING the interior ones (`w:tblBorders`' `w:inside_h`/
    /// `w:inside_v`). A cell inherits the outer edge when it sits on that side of the table and the
    /// interior edge when it does not — the position test lives in `TableBlockBuilder`, which is the
    /// only place that knows where a cell sits in the grid.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub edge_borders: Option<EdgeBorders>,
    /// Where `edge_borders` is when the wire pooled it — see `Cell.edge_borders_ref`.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub edge_borders_ref: Option<u32>,
    /// The table's own default cell margin/padding per edge (docx `w:tblPr/w:tblCellMar`; ODT has no
    /// table-wide equivalent — `fo:padding` lives on the cell's own STYLE only, so an ODT-sourced
    /// `TableFormat` never populates this) — the layer beneath a cell's own `Cell.edge_padding`,
    /// mirroring `edge_borders`' cell-then-table cascade). `nil` per edge (including a wholly-`nil`
    /// `default_padding`) means the table said nothing about that edge either, and the PAGED
    /// resolution falls through to `TableBlockBuilder.defaultCellPadding`. Consulted ONLY by the
    /// PAGED model — see `Cell.edge_padding`'s own doc.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub default_padding: Option<EdgePadding>,
    /// Whether the AUTHOR asked for the heading rows to be reprinted on every page the table runs
    /// onto (HWP `Table.repeat_header`, docx `w:trPr/w:tblHeader` on the row). Distinct from
    /// `OfficeBlock.table`'s `header_rows`, which says only WHICH rows are the heading: a table can
    /// have a heading and not ask for it to repeat, and reprinting it then invents a row the
    /// document never put there. `nil` = the source said nothing.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub repeat_header_rows: Option<bool>,
    /// Where the DOCUMENT allows this table to be split when it reaches the foot of a page — HWP's
    /// own three-way answer (`Table.page_break`), whose docx cousin is `w:trPr/w:cantSplit` on each
    /// row. `nil` = the source said nothing, and the reader's own policy stands (invariant 92).
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub page_break_policy: Option<TablePageBreakPolicy>,
    // swift: TableFormat
    /// The gap between the TABLE OBJECT ITSELF and what surrounds it — HWP's own
    /// `Table.outer_margin_left/right/top/bottom` — distinct from `default_padding` (inside a
    /// cell's border) and from any paragraph's own spacing/indent (there is no such paragraph; a
    /// table has no wrapper of its own in this vocabulary). `nil` per edge = the source said
    /// nothing, same discipline as every other field here; a genuinely-declared `0` is carried as
    /// `0`, not `nil` — HWP's own export already drops a zero at the wire (see `HwpReader`), so on
    /// this side the two are indistinguishable and both read as "no gap", which is correct either
    /// way. Docx/ODT never populate this (docx tables have no equivalent field close enough to
    /// reuse honestly; ODT's page-flow default paragraph spacing is a different declaration this
    /// reader does not thread through the table path) — `mapJSON` and every other reader leave it
    /// `nil`, unchanged behaviour.
    ///
    /// ALL FOUR edges are decoded and carried here, but only `.left`/`.right` are ever APPLIED —
    /// `TableBlockBuilder.build` narrows the grid by them (`GridTextTable.outerMarginLeft`/`Right`).
    /// `.top`/`.bottom` are read by nothing downstream: a `.minY`/`.maxY` `NSTextBlock` margin box
    /// on the first/last row was built, measured against a real 545-page manual, and REMOVED — 38
    /// pages lost glyphs and several rendered completely empty, because a table crossing a page
    /// boundary lands its first/last row at the top or bottom of a SHEET, where the page-band and
    /// mid-table-split machinery (invariants 61/64/72/96) reads that same box geometry and was never
    /// built to absorb a margin there. This is the same shape invariant 97 already names for six of
    /// a char shape's sixteen decorations: carried on the model because the source declares it and a
    /// future reader may need it, deliberately not drawn because the one place that tried is unsafe.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub outer_margin: Option<EdgePadding>,
}

impl PartialEq for TableFormat {
    fn eq(&self, other: &Self) -> bool {
        let Self {
            default_border_color, default_border_width, default_shading, background_image,
            background_gradient, source_width, edge_borders, edge_borders_ref, default_padding,
            repeat_header_rows, page_break_policy, outer_margin,
        } = self;
        default_border_color == &other.default_border_color
            && default_border_width == &other.default_border_width
            && default_shading == &other.default_shading
            && image_eq(background_image, &other.background_image)
            && background_gradient == &other.background_gradient
            && source_width == &other.source_width
            && edge_borders == &other.edge_borders
            && edge_borders_ref == &other.edge_borders_ref
            && default_padding == &other.default_padding
            && repeat_header_rows == &other.repeat_header_rows
            && page_break_policy == &other.page_break_policy
            && outer_margin == &other.outer_margin
    }
}

// swift: TablePageBreakPolicy
/// What a document permits when its table meets a page boundary — see `TableFormat.page_break_policy`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TablePageBreakPolicy {
    // swift: TableFormat
    /// Never split: the whole table moves to the next page rather than being cut.
    Never,
    // swift: TableFormat
    /// Split at a ROW boundary only — a row is never cut through the middle.
    AtRowBoundary,
    // swift: TableFormat
    /// Split anywhere, including through a row's own cells.
    Anywhere,
}

// swift: LineHeight
/// A paragraph's line-spacing mode — docx `w:pPr/w:spacing/@w:lineRule` (`auto`/`exact`/`atLeast`)
/// and ODF's equivalent `style:line-height-at-least`/`fo:line-height` distinction, carried as one
/// closed vocabulary rather than a raw (rule, value) pair so a later sprint's builder can switch
/// over it exhaustively. Reserved for P2 (the reader that populates it, and
/// `OfficeTextBuilder`'s translation to `NSParagraphStyle` line-height, are next sprint's job) —
/// this sprint only carries the vocabulary, nothing constructs a non-nil value yet.
#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LineHeight {
    // swift: TableFormat
    /// docx `w:lineRule="auto"` — a RATIO of the line's own font size, not an absolute value;
    /// `1.0` means single spacing (the same as no line-height set at all), `2.0` double, etc.
    Multiple(CGFloat),
    // swift: TableFormat
    /// docx `w:lineRule="exact"` — an EXACT height in POINTS, overriding the line's natural size
    /// (a tall glyph or embedded object can be clipped if the exact value is smaller than it needs).
    Exact(CGFloat),
    // swift: TablePageBreakPolicy
    /// docx `w:lineRule="atLeast"` — a MINIMUM height in POINTS; the line grows past this value
    /// when its own content needs more room, but never shrinks below it.
    AtLeast(CGFloat),
}

// swift: TabAlignment
/// A tab stop's ALIGNMENT — docx `w:tabs/w:tab/@w:val` (`start`/`left` → `.left`, `center` →
/// `.center`, `end`/`right` → `.right`, `decimal` → `.decimal`; `bar`/`clear` never reach this
/// vocabulary at all — see the reader's own `w:tab` parse for why). Text before the stop is
/// positioned relative to `position` according to this case, exactly the way Word itself lays a
/// tab column out — `.left` pushes text to start AT `position` (the paragraph's pre-P2b behaviour,
/// and every markdown/office call site that never authored a real alignment), `.right` ends text
/// AT `position`, `.center` centers it ON `position`, and `.decimal` aligns the decimal point (or,
/// for non-numeric text, the whole run) ON `position`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TabAlignment {
    // swift: LineHeight
    Left,
    Center,
    Right,
    Decimal,
}

// swift: TabLeader
/// A tab stop's LEADER (fill) character — docx `w:tabs/w:tab/@w:leader` (`dot` → `.dot`, `hyphen` →
/// `.hyphen`, `underscore` → `.underscore`; absent or any other value → `.none`). Carried through
/// the vocabulary but NOT drawn this sprint — AppKit's `NSTextTab` has no native leader-fill
/// primitive, and a faithful dotted/dashed fill between the preceding text and the tab stop is a
/// real (measured-later) rendering cost this sprint doesn't take on. A tab with a leader still
/// renders as an ordinary aligned tab, just without the fill; `OfficeTextBuilder`'s `NSTextTab`
/// construction reads `position`/`alignment` only, and comments why `leader` is inert.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TabLeader {
    // swift: LineHeight
    None,
    Dot,
    Hyphen,
    Underscore,
}

/// One authored tab stop — docx `w:tabs/w:tab` (`@w:pos` in twips → `position` in points, `@w:val`
/// → `alignment`, `@w:leader` → `leader`), odt `style:tab-stop` (`style:position` → `position`;
/// this sprint migrates the VOCABULARY only for ODT — see `OdtReader`'s own doc on why it doesn't
/// yet read ODF's `style:type`/`style:leader-text` into `alignment`/`leader`, so an ODT-sourced
/// stop is always `.left`/`.none`, identical to how it rendered before this type existed).
///
/// `init(position:)` is the ergonomic, position-only constructor every pre-P2b call site (tests,
/// `OdtReader`, markdown-adjacent code that never touches this vocabulary) becomes with a single
/// added token — `alignment`/`leader` default to `.left`/`.none`, which is EXACTLY what a bare
/// `CGFloat` position meant before this type existed, so a call site that only ever cared about
/// position renders byte-identical after the one-token change.
///
/// NOTE: `CGFloat` maps to `f64` (`swiftshim::CGFloat`), which has no `Eq`/`Hash` impl — the
/// `Hashable` conformance this struct declares in Swift cannot compile as a plain `#[derive]` in
/// Rust; a manual impl is phase-B work (see `docs/plans/rust-port-convention.md` §0).
#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct TabStop {
    pub position: CGFloat,
    pub alignment: TabAlignment,
    pub leader: TabLeader,
}

impl TabStop {
    // swift: TabLeader
    /// `init(position:alignment:leader:)` — a SINGLE Swift initializer with default parameter
    /// values (`alignment = .left`, `leader = .none`), not an overload; Rust has no default
    /// parameters, so every call site now states all three explicitly.
    pub fn new(position: CGFloat, alignment: TabAlignment, leader: TabLeader) -> TabStop {
        TabStop { position, alignment, leader }
    }
}

// swift: ParagraphFormat
/// A paragraph's block-level formatting — spacing, indentation, shading and border — read from the
/// source but not yet applied anywhere. Every field defaults to `nil`/`false`, meaning "the source
/// didn't say → `OfficeTextBuilder` keeps using its own token/theme default, exactly as before this
/// struct existed." This sprint (P1) only adds the vocabulary and a default-constructed instance to
/// every block that can carry one; NEITHER reader (`DocxReader`/`OdtReader`) constructs a non-default
/// value yet, NOR does `OfficeTextBuilder` read any of these fields into layout — both are P2's job.
/// A default `ParagraphFormat()` therefore renders BYTE-IDENTICAL to a block with no `format` at all.
#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct ParagraphFormat {
    // swift: TabStop
    /// Space before/after the paragraph, in POINTS (docx `w:pPr/w:spacing/@w:before`/`@w:after` are
    /// TWIPS — a reader converts twips→points before constructing this; ODT `fo:margin-top`/
    /// `fo:margin-bottom` are already points). `nil` leaves the builder's own theme spacing in place.
    /// How far a LIST item's text sits from its own marker, in POINTS, when the document said so
    /// (HWP's `NumberingHead.text_distance` for a numbered head, `Bullet.text_distance` for a
    /// bullet). `nil` — every other format, and most HWP paragraphs — leaves the builder's own
    /// hanging indent (`theme.listHangRatio` × the base size) exactly as it was.
    ///
    /// This is the gap between the MARKER and the TEXT, not the item's indent: how far the whole
    /// item sits from the margin is `indent_start`, which the reader already honours.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub list_text_distance: Option<CGFloat>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub spacing_before: Option<CGFloat>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub spacing_after: Option<CGFloat>,
    /// The paragraph's line-spacing mode — see `LineHeight` above. `nil` leaves whatever line
    /// height the builder already computes (typically driven by font size) untouched.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub line_height: Option<LineHeight>,
    // swift: ParagraphFormat
    /// Indentation from the text block's start/end edge (docx `w:pPr/w:ind/@w:start`(or `@w:left`)/
    /// `@w:end`(or `@w:right`), converted twips→points; odt `fo:margin-left`/`fo:margin-right`), and
    /// first-line/hanging indent (`w:ind/@w:firstLine`/`@w:hanging`; odt `fo:text-indent` — a
    /// negative value there is ODF's own hanging-indent spelling, so a reader normalizes it into
    /// EITHER `first_line_indent` OR `hanging_indent`, never both at once, mirroring docx's own
    /// mutually-exclusive pair). All four in POINTS. Named after the SOURCE spec's own attributes
    /// deliberately — mapping `start`/`end` (which flip with `rtl`) onto `NSParagraphStyle`'s
    /// physical `firstLineHeadIndent`/`headIndent` is P2's job, not this struct's.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub indent_start: Option<CGFloat>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub indent_end: Option<CGFloat>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub first_line_indent: Option<CGFloat>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub hanging_indent: Option<CGFloat>,
    /// docx `w:pPr/w:contextual_spacing` (a toggle, read the same on/off way as `Span.rtl` — see
    /// `DocxReader.isOn`) / odt paragraph-style `style:contextual-spacing` — when `true`, suppresses
    /// `spacing_before`/`spacing_after` between two consecutive paragraphs of the SAME style (list
    /// items are the common case: no gap wanted between "1." and "2.", but one wanted before the
    /// list and after it). Applying that adjacency rule is P2's job; this field only carries the bit.
    pub contextual_spacing: bool,
    /// The paragraph's own background fill (docx `w:pPr/w:shd/@w:fill`, odt paragraph-style
    /// `fo:background-color`) — `nil` means unshaded, exactly as every paragraph renders today.
    /// Mirrors `Cell.background_color`'s naming/semantics one level up, for the same reason: a
    /// paragraph can carry its own fill independent of any table it might sit inside.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub shading: Option<NSColor>,
    /// The paragraph's border box (docx `w:pPr/w:pBdr`, odt paragraph-style `fo:border`) — one
    /// uniform colour/width, mirroring `Cell.border_color`/`Cell.border_width`'s existing model and
    /// its documented reasoning: a real per-edge border (top/bottom/left/right independently) is
    /// out of scope for the same reason it is on `Cell` — both source formats can express far more
    /// than this vocabulary carries, and one uniform colour/width already covers the measured need.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub border_color: Option<NSColor>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub border_width: Option<CGFloat>,
    /// WHICH of the four edges the document actually declared — `[.top, .bottom]` for a rule above
    /// and below, `[.bottom]` for the single underline Word's own stock Title and Heading styles
    /// draw. Empty means "every edge", the box this reader drew before the set existed, so a
    /// paragraph that declared nothing per-edge is unchanged (invariant 37).
    ///
    /// This is a SET rather than a full three-state `EdgeBorders`: a paragraph border has no
    /// neighbour to disagree with, so invariant 47's "silenced vs never mentioned" distinction —
    /// which exists to resolve a shared boundary between two cells — has nothing to resolve here.
    /// What a paragraph needs is only "draw this edge or don't", and reducing the four edges to one
    /// colour and width is still the deliberate simplification above; a document that rules its top
    /// in red and its bottom in blue gets whichever it declared first, on both.
    pub border_edges: RectEdge,
    /// Where a line may be broken inside a stretch of East Asian text (HWP `ParaShape` attr1 bit 7;
    /// docx's nearest spelling is `w:pPr/w:kinsoku`, which governs the same question from the other
    /// side). `nil` = the source said nothing, and the reader's own line-breaking default stands —
    /// which is what every document did before this field existed.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub east_asian_line_break: Option<LineBreakGranularity>,
    /// The same question for a stretch of Latin text (HWP attr1 bits 5-6; docx `w:pPr/w:wordWrap`,
    /// whose `w:val="0"` is this vocabulary's `.character`). `.hyphen` is HWP's middle setting:
    /// break at a word boundary, and additionally at a hyphen already in the word.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub latin_line_break: Option<LineBreakGranularity>,
    /// Whether the document itself widens the seam where East Asian text meets Latin letters
    /// (docx `w:pPr/w:autoSpaceDE`, HWP attr1 bit 20 / attr2 bit 4) or digits (`w:autoSpaceDN`,
    /// attr1 bit 21 / attr2 bit 5). `nil` = unstated.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub auto_space_east_asian_latin: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub auto_space_east_asian_number: Option<bool>,
    /// Whether the line's height is taken from the FONT's own metrics rather than from the
    /// character size the paragraph declares (HWP attr1 bit 22 — 글꼴에 어울리는 줄 높이).
    /// `nil` = unstated.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub line_height_from_font_metrics: Option<bool>,
    /// Whether a line's spacing sits BELOW its glyphs (HWP: the glyphs at the top of the line box,
    /// the rest of the pitch under them) rather than above (Word, and TextKit's own floor). Decides
    /// how the builder carries an at-least pitch and what has to fit at the foot of a page.
    /// `nil` = unstated (above).
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub line_spacing_below: Option<bool>,
    /// The document's own page break in front of this paragraph — docx `w:pageBreakBefore` (direct
    /// or through the style chain) and the paragraph opened by a `<w:br w:type="page"/>`. Read into
    /// `OfficeReadResult.page_break_blocks` for a top-level block; ignored inside a cell.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub page_break_before: Option<bool>,
    /// docx `w:keepNext`: this paragraph stays on the page of the one that follows it. Read into
    /// `OfficeReadResult.keep_with_next_blocks` the same way.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub keep_with_next: Option<bool>,
}

impl ParagraphFormat {
    /// Whether this says nothing at all — the state a block with no `format` key means.
    ///
    /// Used to keep the field OFF the wire when it carries no information, which is the
    /// half of the `format` repair that needs no pool: a paragraph that declares nothing
    /// still cost a nested container per block before this.
    pub fn is_default(&self) -> bool {
        *self == ParagraphFormat::default()
    }
}

impl Default for ParagraphFormat {
    fn default() -> Self {
        ParagraphFormat {
            list_text_distance: None,
            spacing_before: None,
            spacing_after: None,
            line_height: None,
            indent_start: None,
            indent_end: None,
            first_line_indent: None,
            hanging_indent: None,
            contextual_spacing: false,
            shading: None,
            border_color: None,
            border_width: None,
            border_edges: RectEdge::default(),
            east_asian_line_break: None,
            latin_line_break: None,
            auto_space_east_asian_latin: None,
            auto_space_east_asian_number: None,
            line_height_from_font_metrics: None,
            line_spacing_below: None,
            page_break_before: None,
            keep_with_next: None,
        }
    }
}

// swift: LineBreakGranularity
/// How finely a line may be broken inside one script's text — see `ParagraphFormat`'s two
/// `…LineBreak` fields. Named after what the setting DOES rather than after any one format's
/// spelling, because the two formats that state it disagree about which value is the default.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LineBreakGranularity {
    /// Break only between words — a word is never split across two lines.
    Word,
    /// Break between words, and also at a hyphen the word already contains.
    Hyphen,
    /// Break between any two characters, which is how a line of Han/Kana/Hangul is normally filled.
    Character,
}

// swift: RectEdge
/// The four sides of a rectangle, as a set — see `ParagraphFormat.border_edges`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
/// `transparent` so an edge set crosses as the bit field it is, not as an object wrapping one.
/// A host models this as its own option set, and an option set reads a number.
#[serde(transparent)]
pub struct RectEdge {
    pub raw_value: i64,
}

impl RectEdge {
    pub const TOP: RectEdge = RectEdge { raw_value: 1 << 0 };
    pub const LEFT: RectEdge = RectEdge { raw_value: 1 << 1 };
    pub const BOTTOM: RectEdge = RectEdge { raw_value: 1 << 2 };
    pub const RIGHT: RectEdge = RectEdge { raw_value: 1 << 3 };
    pub const ALL: RectEdge = RectEdge {
        raw_value: RectEdge::TOP.raw_value | RectEdge::LEFT.raw_value | RectEdge::BOTTOM.raw_value | RectEdge::RIGHT.raw_value,
    };

    // swift: `RectEdge: OptionSet` (OfficeBlock.swift:746-753) — the rest of this surface is
    // Swift's `OptionSet` protocol's own default implementation, not something this type declares
    // itself, so it is given here rather than left for a call site to reinvent per-caller.

    /// swift: `RectEdge()` — `OptionSet`'s parameterless init, the empty set.
    pub fn empty() -> RectEdge {
        RectEdge { raw_value: 0 }
    }

    /// swift: `.all` — kept as a lowercase alias so a call site written against the Swift static
    /// member name (`RectEdge.all`) resolves without deciding case per caller.
    pub fn all() -> RectEdge {
        RectEdge::ALL
    }

    /// swift: `.isEmpty`
    pub fn is_empty(&self) -> bool {
        self.raw_value == 0
    }

    /// swift: `OptionSet.union(_:)`
    pub fn union(self, other: RectEdge) -> RectEdge {
        RectEdge { raw_value: self.raw_value | other.raw_value }
    }

    /// swift: `OptionSet.contains(_:)`
    pub fn contains(&self, other: RectEdge) -> bool {
        (self.raw_value & other.raw_value) == other.raw_value
    }

    /// swift: `OptionSet.insert(_:)`
    pub fn insert(&mut self, other: RectEdge) {
        self.raw_value |= other.raw_value;
    }
}

/// swift: `|` on an `OptionSet` — `Self.union(_:)` via `SetAlgebra`'s own operator overload.
impl std::ops::BitOr for RectEdge {
    type Output = RectEdge;
    fn bitor(self, rhs: RectEdge) -> RectEdge {
        self.union(rhs)
    }
}

/// swift: `|=` on an `OptionSet` — `formUnion(_:)` via `SetAlgebra`'s own operator overload,
/// which is what `part_a.rs`'s `paragraph_border` (`edges |= edge`) needs.
impl std::ops::BitOrAssign for RectEdge {
    fn bitor_assign(&mut self, rhs: RectEdge) {
        self.raw_value |= rhs.raw_value;
    }
}

// swift: OfficeBlock
/// The format-neutral block vocabulary between a document-format parser (docx/odt/… — later
/// sprints) and `OfficeTextBuilder`, which turns these into typography. Deliberately knows
/// nothing about Word, ODF or XML: a parser's only job is to produce this vocabulary, and
/// `OfficeTextBuilder`'s only job is to consume it, so the two are built and tested apart.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OfficeBlock {
    /// Every case below that holds spans also carries `rtl`, defaulted `false` so every existing
    /// caller (hundreds, mostly tests) that never mentions it keeps meaning "not explicitly marked
    /// right-to-left" — the same reading an absent source attribute gets.
    ///
    /// This is a PARAGRAPH property, not a font one: docx's `w:pPr/w:bidi` and ODT's paragraph-style
    /// `style:writing-mode="rl-tb"` both mark the whole block, deciding where it BEGINS, which side
    /// neutral characters (digits, punctuation, brackets) resolve toward at its edges, and — when
    /// `alignment` below is `nil` — which edge the block starts flush against. TextKit's own
    /// bidirectional algorithm already reorders mixed-direction RUNS correctly within a line once
    /// it knows the paragraph's base direction; what it cannot recover on its own is THAT base
    /// direction when the source doesn't say, which is exactly what carrying this bit through from
    /// the reader restores (see `OfficeTextBuilder`, which turns it into
    /// `NSParagraphStyle.baseWritingDirection`). An EXPLICIT `alignment` always wins over this
    /// default — `.natural` alignment already resolves to the right edge once the base direction is
    /// `.rightToLeft`, so `rtl` alone is only ever a fallback for when the source has no explicit
    /// alignment of its own to say instead.
    ///
    /// `alignment` (docx `w:pPr/w:jc`, odt `fo:text-align`) is `nil` when the source didn't say —
    /// meaning "let `rtl`/the theme's own default decide", never a hardcoded `.left`. `tab_stops`
    /// (docx `w:pPr/w:tabs`, odt `style:tab-stop`) are the paragraph's OWN authored stops, in
    /// POINTS, in addition to whatever tab machinery the block already has for other reasons — a
    /// `listItem`'s marker tab (see below) is never replaced by these, only added to.
    /// `format` (trailing, defaulted — see `ParagraphFormat` above) is this sprint's (P1)
    /// vocabulary-only addition: every existing caller that never mentions it keeps meaning "no
    /// paragraph formatting beyond what the builder already applies," identical to before this
    /// field existed. Populating it from a real document (the reader) and consuming it in layout
    /// (`OfficeTextBuilder`) are both P2's job — this sprint changes no rendered output.
    Heading {
        level: i64,
        spans: Vec<Span>,
        rtl: bool,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        alignment: Option<NSTextAlignment>,
        tab_stops: Vec<TabStop>,
        #[serde(skip_serializing_if = "ParagraphFormat::is_default", default)]
        format: ParagraphFormat,
        /// The slot in `OfficeReadResult.paragraph_format_pool` this paragraph's format
        /// occupies, when the wire pooled it instead of repeating it — see
        /// `paragraph_format_pool`. Exactly one of the two is ever set on the wire.
        #[serde(skip_serializing_if = "Option::is_none", default)]
        format_ref: Option<u32>,
    },
    Paragraph {
        spans: Vec<Span>,
        rtl: bool,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        alignment: Option<NSTextAlignment>,
        tab_stops: Vec<TabStop>,
        #[serde(skip_serializing_if = "ParagraphFormat::is_default", default)]
        format: ParagraphFormat,
        /// The slot in `OfficeReadResult.paragraph_format_pool` this paragraph's format
        /// occupies, when the wire pooled it instead of repeating it — see
        /// `paragraph_format_pool`. Exactly one of the two is ever set on the wire.
        #[serde(skip_serializing_if = "Option::is_none", default)]
        format_ref: Option<u32>,
    },
    /// `level` is a 0-based nesting depth. `ordered` selects "1. 2. 3." numbering — per level,
    /// restarting when a SHALLOWER level intervenes but continuing across a deeper nested run —
    /// vs a bullet. See `OfficeTextBuilder` for the exact restart rule.
    ///
    /// `marker` is the pre-computed display text for THIS item (e.g. `"1.2.3"`, `"iv."`, `"c)"`),
    /// or `nil`. Only a format that can actually resolve real numbering — a numId that names a
    /// concrete numbering definition, WITH an `w:lvlText` to substitute into — can honestly know
    /// this text, and only the READER (`DocxReader`) has that information: a numbering definition
    /// lives in a side part of the source file (`word/numbering.xml`), continues its counters
    /// across intervening body paragraphs, and can be overridden per-list (`w:startOverride`,
    /// `w:lvlOverride`) — none of which `OfficeTextBuilder` can see from one block in isolation.
    /// `nil` means "the source's numbering couldn't be resolved to real text" (no numbering part,
    /// an unresolvable numId, a level with no `w:lvlText`, ODF's list styles carrying no such
    /// field at all) — the field is OPTIONAL rather than mandatory precisely so that case keeps
    /// working: `OfficeTextBuilder` falls back to counting the item itself from `level`+`ordered`
    /// alone, EXACTLY as it always has (never inventing a number the source didn't give a way to
    /// compute — same principle as `image`'s reserved-but-unloaded size, applied to text instead
    /// of pixels). `ordered`/`level` still drive indentation and the bullet glyph even when
    /// `marker` is supplied — only the marker TEXT bypasses the builder's own counters.
    ///
    /// `alignment`/`tab_stops` mean exactly what they mean on `.paragraph`/`.heading` above. A
    /// custom tab stop never displaces the marker's own hanging-indent tab — `OfficeTextBuilder`
    /// APPENDS these after it, so `1.\t<text>` still lands the text at the item's hanging indent
    /// first and any authored stops beyond that still work inside the item's own text.
    /// `format` means exactly what it means on `.paragraph`/`.heading` above — this sprint's
    /// vocabulary-only addition, trailing and defaulted so no existing caller changes meaning.
    ListItem {
        level: i64,
        ordered: bool,
        spans: Vec<Span>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        marker: Option<SwiftString>,
        rtl: bool,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        alignment: Option<NSTextAlignment>,
        tab_stops: Vec<TabStop>,
        #[serde(skip_serializing_if = "ParagraphFormat::is_default", default)]
        format: ParagraphFormat,
        /// The slot in `OfficeReadResult.paragraph_format_pool` this paragraph's format
        /// occupies, when the wire pooled it instead of repeating it — see
        /// `paragraph_format_pool`. Exactly one of the two is ever set on the wire.
        #[serde(skip_serializing_if = "Option::is_none", default)]
        format_ref: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        numbering: Option<ListNumbering>,
    },
    /// Rows of ANCHOR cells only (`rows[row]` lists the cells that START in that row, left to
    /// right — a row's `count` is therefore the number of anchors in it, NOT the column count once
    /// any span is wider than 1; a parser reading `w:gridSpan`/`table:number-columns-spanned` must
    /// size the grid from the source's own column authority (`w:tblGrid` / repeated cells), not
    /// from `rows[row].count`). `header_rows` is the count of LEADING rows that are a genuine
    /// header, and the SOURCE format must say so explicitly — docx marks it with `w:tblHeader`, a
    /// markdown table always has exactly one. It is not a guess `OfficeTextBuilder` makes: pass 0
    /// when the format can't tell you. DEFAULT TO 0 WHEN UNKNOWN, never 1 — an un-styled table is a
    /// faithful rendering of the source; a wrongly-bolded row is a lie about it (real contracts
    /// commonly have zero header rows — guessing "row one" bolds ordinary text).
    /// `column_widths` is the table's own grid column widths in POINTS, in left-to-right grid
    /// order (docx `w:tbl/w:tblGrid/w:gridCol/@w:w`, twips converted the same way `cellWidth`
    /// converts a per-cell `w:tcW`; odt column widths, P4) — the AUTHORITATIVE proportions Word
    /// itself fills the table's width with, which is why they win over a per-cell `Cell.width`
    /// (that field is a fallback for when no grid was readable at all, see its own doc comment).
    /// Empty means "no grid known" — every markdown table (GFM has no such concept) and any docx
    /// table whose `w:tblGrid` couldn't be read — and `TableBlockBuilder` falls back to its
    /// pre-this-field per-cell/auto layout exactly as before this field existed. When non-empty
    /// its count is expected to equal the table's own derived column count; a caller that can't
    /// establish that (a malformed grid) should pass `[]` rather than a mismatched array — a
    /// mismatch is treated as "unusable" and ignored, never partially applied.
    /// `format` (trailing, defaulted — see `TableFormat` above) is this sprint's (P3b) table-level
    /// default border/shading, inherited by any cell that doesn't declare its own. A
    /// default-constructed `TableFormat()` — every markdown table, and every existing call site that
    /// never mentions this parameter — renders BYTE-IDENTICAL to before this field existed.
    Table { rows: Vec<Vec<Cell>>, header_rows: i64, column_widths: Vec<CGFloat>, format: TableFormat },
    /// `id` is an opaque key a later sprint resolves to pixels (a docx relationship id, an odt
    /// href, a markdown source path, …) — this sprint only reserves the LAYOUT area, exactly like
    /// a not-yet-loaded markdown image (invariant 1: reserved size must never depend on whether
    /// pixels are loaded).
    /// `alignment` is the CONTAINING paragraph's own horizontal alignment (docx `w:jc`, ODF
    /// `fo:text-align`, resolved through the same style cascade the paragraph itself uses). A picture
    /// in a report is centred far more often than not, and it used to render hard against the left
    /// margin no matter what the document said, because this case carried no alignment at all and the
    /// builder gave the attachment no paragraph style. `nil` = the document said nothing → the
    /// reader's default (leading), byte-identical to before this existed.
    Image { id: SwiftString, size: CGSize, alignment: Option<NSTextAlignment> },
    /// A chart or SmartArt diagram: DrawingML content this reader has no vector renderer for and
    /// for which no already-rendered `mc:Fallback` picture could be recovered either (see
    /// `DocxReader.graphicPlaceholderBlock`). Deliberately its OWN case rather than reusing
    /// `.image` with a synthetic id: an `.image` id names something `MarkdownDocument`'s async
    /// loader is expected to go find pixels FOR (an archive entry, a folder-grant path, or — when
    /// that lookup fails — the SAME generic "broken image" icon a corrupt picture reference gets).
    /// This case is different in kind, not just in degree: there was never any picture to look up
    /// in the first place, so showing the broken-image icon would misreport a decoding failure
    /// that didn't happen. `label` is the pre-formatted, reader-facing word to draw in the frame
    /// ("Chart", "Diagram" — never an XML element name); `size` is the drawing's own declared area
    /// (`wp:extent`, EMU-converted exactly like `.image`'s size), reserved up front and never
    /// revised — there is no later pixel arrival to protect invariant 1 against here, since unlike
    /// `.image` this case's rendering is synthesized once, fully, at build time.
    UnsupportedGraphic { label: SwiftString, size: CGSize, alignment: Option<NSTextAlignment> },
    /// A Word/OOXML equation (`m:oMathPara` — a display equation on its own line), translated to
    /// the LaTeX the app's existing formula engine already renders (`OmmlTranslator`). Rides the
    /// SAME web-block pipeline a markdown `$$…$$` does — `OfficeTextBuilder` reserves a placeholder
    /// tagged with the identical `MDAttr.math` attribute `MarkdownRenderer.appendWebBlock` uses —
    /// so `MarkdownDocument`'s pre-render/pre-size passes (which enumerate `MDAttr.math` wherever it
    /// appears, not by document kind) pick it up automatically; invariant 1/2's scroll stability is
    /// inherited, not re-earned. Only a genuinely STANDALONE display equation becomes this case — a
    /// bare inline `m:oMath` mixed into a sentence has no web-block equivalent this sprint (no
    /// inline placeholder mechanism exists in `WebBlock`), so `DocxReader` degrades it to plain text
    /// INSIDE the surrounding paragraph's spans instead of ever reaching here. `latex` is never
    /// empty: an equation with no translatable content at all is degraded, before construction, to
    /// a visible text block by the reader — this case never carries "nothing to render".
    Formula { latex: SwiftString },
}

// swift: OfficeComment
/// One reviewer comment (docx `word/comments.xml` `w:comment`, odt inline `office:annotation`) —
/// content and identity ONLY; where it anchors is on the `Span`s that carry its `id` in their own
/// `comment_ids` (see that field's doc), not here. `id` is the source's own key (docx `@w:id`, odt
/// `@office:name` or a reader-synthesized id when the source gave none — see each reader) — opaque,
/// only used to match back to `Span.comment_ids`. `author`/`date_iso` are `nil` when the source didn't
/// say (a comment with no name-tagged reviewer, or a producer that omits the timestamp); `date_iso`
/// is carried VERBATIM as the source wrote it (docx `@w:date` is already ISO-8601; odt `dc:date` the
/// same), never reformatted — this project has no comment-panel UI yet (P6b) to decide a display
/// format for. `number` is the comment's 1-based DISPLAY order — by first appearance of its anchor
/// in the body when it has one, or (for a comment the body never anchors at all) continuing that
/// same sequence in the source's own file order — so a reader can show "Comment 1", "Comment 2", …
/// the way a native office app's review pane would, even for an unanchored comment.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct OfficeComment {
    pub id: SwiftString,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub author: Option<SwiftString>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub date_iso: Option<SwiftString>,
    pub text: SwiftString,
    pub number: i64,
}

// swift: HeaderFooterApplicability
/// Which pages a header or footer entry applies to — deliberately ONE enum shared by every source
/// format, even though the formats don't carve the space up the same way (header-footer-design.md
/// §2d/§3). docx states three named types directly (`w:headerReference`/`w:footerReference`'s
/// `@w:type`: `"default"`/`"first"`/`"even"`); ODF's `style:master-page` names its variants by
/// element suffix (`style:header`/`-first`/`-left`) rather than an attribute, but the three-way
/// split is the same shape and maps case-for-case. HWP (rhwp's `apply_to`) has NO first-page
/// concept in this mechanism at all — see `HwpReader`'s own mapping comment for exactly what its
/// `"both"`/`"odd"`/`"even"` fold onto here, and what distinction is lost by doing so.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HeaderFooterApplicability {
    // swift: OfficeComment
    /// docx `w:type="default"`; odt `style:header`/`style:footer` (the un-suffixed, base variant);
    /// HWP `"both"` — the template a section applies to EVERY page unless a parity-specific one
    /// overrides it. HWP's `"odd"` is NOT this: it has its own case below.
    DefaultPages,
    // swift: OfficeComment
    /// docx `w:type="first"`, OR the explicit blank header/footer OOXML creates when `w:titlePg` is
    /// set and no `first`-type reference exists (see `DocxReader`'s own comment on that rule — both
    /// are represented as an entry here, the synthesized one with empty `blocks`); odt
    /// `style:header-first`/`style:footer-first`. HWP has no equivalent in THIS mechanism — its own
    /// first-page device (바탕쪽/master-page overrides) is a separate feature, out of v1.
    FirstPage,
    // swift: OfficeComment
    /// docx `w:type="even"`; odt `style:header-left`/`style:footer-left` (ODF names the mirrored
    /// page by reading side, not parity — treated as the even-page equivalent here, the same
    /// approximation every other "first section only" scope in this reader makes); HWP `"even"` —
    /// the one case where every format means the same thing.
    EvenPages,
    // swift: OfficeComment
    /// HWP `"odd"`. docx and odt have no equivalent — Word and ODF name the mirrored pair
    /// default+even, and an odd-only running head is not expressible there — so no reader but
    /// `HwpReader` ever produces this.
    ///
    /// It used to FOLD into `DefaultPages`, on the reasoning that an even override elsewhere made
    /// the remainder implicitly odd. That holds for a running head, where a section declares at
    /// most one of each; it does NOT hold for a 바탕쪽, where a section declares a `"both"` template
    /// AND an `"odd"` one and the two are told apart by nothing else. Measured on
    /// `2025_행정업무운영편람_최종.hwp`: section 1 declares exactly that pair, both arrived as
    /// `DefaultPages`, and the selector — which takes the FIRST default it finds — drew the cover's
    /// template on every body page in the section (its artwork appearing as an empty white box, its
    /// page number on the wrong edge) while the odd template was never drawn at all.
    OddPages,
}

// swift: OfficeHeaderFooter
/// One header or footer PART, resolved into the format-neutral block vocabulary (parsed through the
/// SAME `parseBody`/body-walk each reader already uses for the document's own text — see
/// header-footer-design.md §2c) plus which pages it applies to. Read-only vocabulary: nothing paints
/// these yet (steps 4/5 of that design), so this struct exists for a later sprint to consume.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct OfficeHeaderFooter {
    pub applies_to: HeaderFooterApplicability,
    pub blocks: Vec<OfficeBlock>,
    // swift: HeaderFooterApplicability
    /// WHICH SECTION declared it, for a format that says (HWP). A running head belongs to its own
    /// section — invariant 77 measured what applying one document-wide does — and now that a page
    /// can be placed in a section (`OfficeReadResult.section_start_blocks`) the entries are all kept
    /// and chosen per page instead of filtered down to one section's. `nil` = the format did not
    /// say (docx, odt), and the entry then applies wherever its parity does, exactly as before.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub section: Option<i64>,
}

// swift: OfficeFootnote
/// One footnote, ready to be laid out somewhere other than where it arrived.
///
/// Shaped exactly like `OfficeHeaderFooter` — blocks plus the section that declared them — because
/// it is drawn by the same machinery: a flow, built by `OfficeTextBuilder` and painted into a band
/// the reader reserved. The one thing that differs is HOW its page is chosen. A running head is
/// picked by the page's parity; a footnote is picked by where its own reference marker landed,
/// which is not known until the document has been laid out, and which the reservation then changes.
/// That circularity is why `FootnoteBandSettle` exists (invariant 98) and why this type carries no
/// page of its own — nothing may cache one.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct OfficeFootnote {
    // swift: OfficeHeaderFooter
    /// The number the document gave it, and the SAME number its reference marker carries
    /// (`MDAttr.footnote_ref`). This is the only link between the two: a marker is a superscript
    /// number and nothing about its glyphs says which note it points at.
    pub number: i64,
    pub blocks: Vec<OfficeBlock>,
    // swift: OfficeHeaderFooter
    /// WHICH SECTION declared it, for the format that says so (HWP) — a footnote's numbering and
    /// separator are section-level declarations, so a host that flattened the document into one
    /// flow would otherwise have no way back to them. `nil` = the format did not say.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub section: Option<i64>,
}

// swift: OfficeMasterObject
/// One object of a 바탕쪽 (master page), already resolved into something drawable and positioned on
/// the PAPER — `frame` is in points from the sheet's top-left corner, not from the reading column.
///
/// A master page is not a header/footer with different coordinates. A running head is a FLOW laid
/// into a band the reader reserved; these are a set of pieces the document pins to the sheet itself
/// — the full-page artwork behind the text, the tab down the outer edge, the ruled title line and,
/// in a real Korean document, the page number (invariant 77 measured exactly that: both bands empty
/// on a body page, the number coming from here). So there is nothing to lay out and nothing to
/// reserve: each piece is drawn where the paper says.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct OfficeMasterObject {
    pub frame: CGRect,
    pub content: OfficeMasterObjectContent,
}

// swift: OfficeFootnote
/// `OfficeMasterObject.Content` in Swift.
///
/// A picture arrives DECODED because HWP has no archive to resolve one from later
/// (`OfficeReadResult.images`' own reason), a drawing arrives as the vector PDF
/// `HwpShapeRenderer` already produces for an inline shape — the same bytes, drawn by the same
/// code, so a shape on a master page cannot render differently from the identical shape in the
/// body — and a text box arrives as ordinary blocks, so the page number inside it is the SAME
/// `MDAttr.page_number_field` span a running header carries and `PageBandPainter.
/// substitutingPageFields` already knows how to fill in.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub enum OfficeMasterObjectContent {
    Image(NSImage),
    Drawing(Data),
    Vector(crate::render::office::hwp_shape_path::VectorGraphic),
    Text(Vec<OfficeBlock>),
}

impl PartialEq for OfficeMasterObjectContent {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Image(a), Self::Image(b)) => a.size == b.size,
            (Self::Drawing(a), Self::Drawing(b)) => a == b,
            (Self::Vector(a), Self::Vector(b)) => a == b,
            (Self::Text(a), Self::Text(b)) => a == b,
            _ => false,
        }
    }
}

// swift: OfficeAnchoredObject
/// An object the document pins to the PAPER rather than to the text — a cover's artwork, a seal
/// over a signature line, a decorative rule down a margin.
///
/// It is the same drawable thing a master-page object is (`OfficeMasterObject`), with one extra
/// fact: WHICH BLOCK it was anchored at, so the reader can draw it on the page that block falls on
/// rather than on every page.
///
/// A PAPER- or PAGE-relative object is fully placed at read time — the sheet it is measured against
/// is the same on every page. A PARAGRAPH-relative one is not: its reference is the anchoring
/// paragraph's own line, which only layout knows, so `paragraph_anchor` carries the unfinished half
/// and the draw pass completes it (`ReaderTextView.drawAnchoredObjects`). Nothing is cached: the
/// line rect is asked for at draw time, so a reflow cannot leave a stale position behind.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct OfficeAnchoredObject {
    // swift: OfficeMasterObject.Content
    /// Index into `OfficeReadResult.blocks` — the block whose place in the text says which page this
    /// object belongs to.
    pub block_index: i64,
    pub object: OfficeMasterObject,
    // swift: OfficeMasterObject.Content
    /// Non-nil when the object is anchored to its PARAGRAPH: `object.frame`'s x/width/height are
    /// final, its `y` is a placeholder, and this says how to measure the real one.
    pub paragraph_anchor: Option<ParagraphAnchor>,
}

// swift: ParagraphAnchor
/// The vertical half of a paragraph-anchored object's placement — rhwp's own rule
/// (`renderer/layout/shape_layout.rs`'s `calc_shape_bottom_y`, the `Para` reference) with the
/// reference area left open until layout can supply it.
///
/// The ALIGN is the whole reason this is expressible at all. The float layer invariant 75 rejected
/// used the offsets alone and so put a 431pt rule over a table's column label; with the align
/// exported (invariant 81) the offset is measured from the edge the document actually named.
#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct ParagraphAnchor {
    pub align: ParagraphAnchorAlign,
    // swift: OfficeAnchoredObject
    /// The document's own vertical offset in points, measured from the aligned edge.
    pub offset: CGFloat,
}

// swift: OfficeAnchoredObject
// swift: ParagraphAnchor.Align
/// `ParagraphAnchor.Align` in Swift.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ParagraphAnchorAlign {
    Top,
    Center,
    Bottom,
}

impl ParagraphAnchor {
    // swift: ParagraphAnchor.top
    /// The object's top edge, given the anchoring line's own top and height in the SAME coordinate
    /// space the answer is wanted in (the reader hands it paper-relative values, so the answer is
    /// paper-relative too).
    pub fn top(&self, line_top: CGFloat, line_height: CGFloat, object_height: CGFloat) -> CGFloat {
        match self.align {
            ParagraphAnchorAlign::Top => line_top + self.offset,
            ParagraphAnchorAlign::Center => line_top + (line_height - object_height) / 2.0 + self.offset,
            ParagraphAnchorAlign::Bottom => line_top + line_height - object_height - self.offset,
        }
    }
}

// swift: ListNumbering
/// How a NUMBERED list item counts and what glyphs it counts in — the document's own scheme rather
/// than the reader's.
///
/// `marker` on a list item is the document's FORMAT (`^1.`, `제^1장`), not finished text: the number
/// itself is the reader's to compute, because only the reader knows how many items came before under
/// its own layout. This says which glyphs to write it in and where to start.
#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct ListNumbering {
    pub glyphs: ListNumberingGlyphs,
    // swift: ParagraphAnchor.top
    /// The level's first number when the author set one other than 1.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub start_number: Option<i64>,
}

impl Default for ListNumbering {
    fn default() -> Self {
        ListNumbering { glyphs: ListNumberingGlyphs::Decimal, start_number: None }
    }
}

// swift: ListNumbering.Glyphs
/// `ListNumbering.Glyphs` in Swift. HWP's own table-43 systems, named. `decimal` is the default and
/// the fallback for anything a document declares that this reader cannot write.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ListNumberingGlyphs {
    Decimal,
    CircledDecimal,
    RomanUpper,
    RomanLower,
    LatinUpper,
    LatinLower,
    // swift: ParagraphAnchor.top
    /// 가, 나, 다
    HangulSyllable,
    /// 일, 이, 삼
    HangulNumber,
    // swift: ParagraphAnchor.top
    /// 一, 二, 三
    HanjaNumber,
}

impl ListNumbering {
    // swift: ListNumbering.text
    /// `n` written in this system. Falls back to decimal past the end of a finite alphabet, which is
    /// what Word and Hancom both do rather than inventing a glyph.
    pub fn text(&self, n: i64) -> SwiftString {
        if n <= 0 {
            return SwiftString::from(format!("{}", n));
        }
        match self.glyphs {
            ListNumberingGlyphs::Decimal => SwiftString::from(format!("{}", n)),
            ListNumberingGlyphs::CircledDecimal => {
                if n <= 20 {
                    let scalar = char::from_u32((0x2460 + n - 1) as u32).unwrap();
                    SwiftString::from(scalar.to_string())
                } else {
                    SwiftString::from(format!("{}", n))
                }
            }
            ListNumberingGlyphs::RomanUpper => SwiftString::from(ListNumbering::roman(n)),
            ListNumberingGlyphs::RomanLower => SwiftString::from(ListNumbering::roman(n).to_lowercase()),
            ListNumberingGlyphs::LatinUpper => SwiftString::from(ListNumbering::alphabet(n, 'A')),
            ListNumberingGlyphs::LatinLower => SwiftString::from(ListNumbering::alphabet(n, 'a')),
            ListNumberingGlyphs::HangulSyllable => SwiftString::from(ListNumbering::pick(
                n,
                &["가", "나", "다", "라", "마", "바", "사", "아", "자", "차", "카", "타", "파", "하"],
            )),
            ListNumberingGlyphs::HangulNumber => SwiftString::from(ListNumbering::pick(
                n,
                &["일", "이", "삼", "사", "오", "육", "칠", "팔", "구", "십"],
            )),
            ListNumberingGlyphs::HanjaNumber => SwiftString::from(ListNumbering::pick(
                n,
                &["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"],
            )),
        }
    }

    // swift: ListNumbering.pick
    fn pick(n: i64, list: &[&str]) -> String {
        if n <= list.len() as i64 { list[(n - 1) as usize].to_string() } else { format!("{}", n) }
    }

    // swift: ListNumbering.alphabet
    fn alphabet(n: i64, base: char) -> String {
        if n > 26 {
            return format!("{}", n);
        }
        match char::from_u32(base as u32 + (n - 1) as u32) {
            Some(c) => c.to_string(),
            None => format!("{}", n),
        }
    }

    // swift: ListNumbering.roman
    fn roman(n: i64) -> String {
        if n >= 4000 {
            return format!("{}", n);
        }
        let table: [(i64, &str); 13] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
            (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ];
        let mut left = n;
        let mut out = String::new();
        for (value, glyph) in table {
            while left >= value {
                out += glyph;
                left -= value;
            }
        }
        out
    }
}

// swift: OfficePageBorder
/// A section's own declarations about its pages — the half of a section that is not geometry.
/// The 쪽 테두리/배경 a section rules around its whole page — a frame a Korean form or report draws
/// once per sheet, not per paragraph.
///
/// The line and colour are NOT here: they are the same `borderFills` table a cell's fill id points
/// at, so a reader that already resolved that table for its tables resolves this with it.
/// `measured_from_paper` decides where `spacing` is measured from — the sheet's own edge, or the body
/// area's. The two land a margin apart (70–110pt on real documents), so guessing draws the frame in
/// the wrong place rather than slightly off.
#[derive(Clone, Copy, Debug, serde::Serialize, serde::Deserialize)]
pub struct OfficePageBorder {
    /// The four edges, resolved through the document's own fill table at read time — the same
    /// resolution a cell's border gets, in the same vocabulary. Resolved here rather than carried as
    /// an id because the table itself does not outlive the read: it is folded into the blocks and
    /// dropped, so an id kept for later would point at nothing when the page is painted.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub borders: Option<EdgeBorders>,
    // swift: ListNumbering.roman
    /// The page's own background colour, when the same fill declares one.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub background: Option<NSColor>,
    pub spacing: NSEdgeInsets,
    // swift: ListNumbering.roman
    /// Where `spacing` is measured FROM — the sheet's own edge, or the body area's. The two land a
    /// margin apart (70–110pt on real documents), so this is not a detail to infer.
    pub measured_from_paper: bool,
}

impl OfficePageBorder {
    /// The document declared a frame that actually draws something. An id pointing at an all-off
    /// fill is a declaration of NO frame, and HWP files are full of them: measured over 644 real
    /// documents, 494 name a page fill and only 48 name one with a drawn edge or a background.
    pub fn draws_anything(&self) -> bool {
        if self.background.is_some() {
            return true;
        }
        let Some(borders) = self.borders else { return false };
        // A SUPPRESSED edge is not a missing one (invariant 47): the document said "no line here",
        // which arrives as a declaration rather than as nothing. Only a DRAWN edge is a frame.
        [borders.top, borders.left, borders.bottom, borders.right]
            .iter()
            .any(|e| matches!(e, Some(BorderDecl::Drawn(_))))
    }
}

impl PartialEq for OfficePageBorder {
    // swift: OfficePageBorder
    fn eq(&self, other: &Self) -> bool {
        self.borders == other.borders
            && self.background == other.background
            && self.measured_from_paper == other.measured_from_paper
            && self.spacing.top == other.spacing.top
            && self.spacing.left == other.spacing.left
            && self.spacing.bottom == other.spacing.bottom
            && self.spacing.right == other.spacing.right
    }
}

// swift: OfficeFootnoteSeparator
/// What a section says about the rule above its footnotes, and the air around them.
///
/// Every length arrives as the document's own measurement in points, `nil`/`0` meaning the document
/// declared nothing and the reader's own minimum stands. Kept as a value on the SECTION rather than
/// on the document because HWP declares it per section — the corpus happens to agree section to
/// section today, but throwing that away would be inventing an answer the format actually gives.
#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct OfficeFootnoteSeparator {
    /// `1` = solid and so on, in the SAME code space as a border edge's line type — `DiagonalLine`'s
    /// own comment says the spaces are shared, which is what let the diagonal work reuse it. `0`
    /// means the document declared no line at all.
    pub line_type: i64,
    /// Already in POINTS — HWP states it as a 16-step enum and the reader resolves it exactly the
    /// way a cell diagonal's is resolved (`HwpReader.diagonalWidthPt`), so a separator and a border
    /// drawn from the same step cannot come out different weights.
    pub line_width_pt: CGFloat,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub color: Option<NSColor>,
    // swift: OfficePageBorder
    /// How long the rule is. The format's own "full width" sentinel is far outside any real page, so
    /// a value that exceeds the column is read as "all of it" rather than clamped silently.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub length_pt: Option<CGFloat>,
    pub margin_top_pt: CGFloat,
    pub margin_bottom_pt: CGFloat,
    /// The gap the document wants BETWEEN two notes — HWP's own UI calls it "주석 사이".
    pub note_spacing_pt: CGFloat,
}

impl Default for OfficeFootnoteSeparator {
    fn default() -> Self {
        OfficeFootnoteSeparator {
            line_type: 0,
            line_width_pt: 0.0,
            color: None,
            length_pt: None,
            margin_top_pt: 0.0,
            margin_bottom_pt: 0.0,
            note_spacing_pt: 0.0,
        }
    }
}

impl OfficeFootnoteSeparator {
    /// Did the document say anything at all? A section that declared nothing must not make the
    /// reader reserve or draw differently from one that has no notes.
    pub fn is_declared(&self) -> bool {
        self.line_type != 0
            || self.line_width_pt != 0.0
            || self.color.is_some()
            || self.length_pt.is_some()
            || self.margin_top_pt != 0.0
            || self.margin_bottom_pt != 0.0
            || self.note_spacing_pt != 0.0
    }
}

// swift: OfficeSectionDeclaration
#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct OfficeSectionDeclaration {
    /// The rule above this section's footnotes — see `OfficeFootnoteSeparator`. `nil` for every
    /// format but HWP, and for an HWP section that declared none.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub footnote_separator: Option<OfficeFootnoteSeparator>,
    /// The frame this section rules around its page, when it declares one. CARRIED, NOT YET PAINTED.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub page_border: Option<OfficePageBorder>,
    // swift: OfficeFootnoteSeparator
    /// The sheet THIS section declared. `nil` = the section stated no page of its own, and the
    /// document's own geometry is the answer. HWP defines a page per section and this reader used to
    /// keep only the busiest one (invariant 73), which typeset a 612pt appendix page on the body's
    /// 555pt sheet.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub paper: Option<PaperGeometry>,
    // swift: OfficeFootnoteSeparator
    /// The section turned its own running header / footer / master page off. A veto, not a
    /// preference: a page in this section shows none, whatever the document declares elsewhere.
    pub hides_header: bool,
    pub hides_footer: bool,
    pub hides_master_page: bool,
    // swift: OfficeFootnoteSeparator
    /// The page number this section restarts at, when it declares one (a chapter that begins at 1
    /// again). `nil` = continue from the previous section.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub page_number_start: Option<i64>,
    /// The 원고지-style fixed line pitch in points, when the section is written on a grid.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub line_grid_pitch: Option<CGFloat>,
    /// The section is set VERTICALLY. Recorded, not honoured: this reader lays text out
    /// horizontally, and saying so in the vocabulary is what lets a caller tell "we ignored it"
    /// apart from "the document never said".
    pub is_vertical: bool,
}

impl Default for OfficeSectionDeclaration {
    fn default() -> Self {
        OfficeSectionDeclaration {
            footnote_separator: None,
            page_border: None,
            paper: None,
            hides_header: false,
            hides_footer: false,
            hides_master_page: false,
            page_number_start: None,
            line_grid_pitch: None,
            is_vertical: false,
        }
    }
}

// swift: PaperGeometry
/// A sheet of paper, in points — the body area a page offers and the four margins around it.
///
/// Every office format states this per SECTION, not per document. This reader lays a document out at
/// ONE width (invariant 57), so the width here is what an anchored object is placed against and what
/// a page's own height is measured by; carrying it per section is what lets a page table know that
/// an appendix's sheet is not the body's.
#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct PaperGeometry {
    pub content_width: CGFloat,
    pub content_height: CGFloat,
    pub margin_left: CGFloat,
    pub margin_top: CGFloat,
    pub margin_right: CGFloat,
    pub margin_bottom: CGFloat,
}

impl PaperGeometry {
    pub fn paper_width(&self) -> CGFloat {
        self.margin_left + self.content_width + self.margin_right
    }
    // swift: PaperGeometry
    pub fn paper_height(&self) -> CGFloat {
        self.margin_top + self.content_height + self.margin_bottom
    }
}

// swift: OfficeMasterPage
/// One 바탕쪽 — the template a document repeats behind every page of a section.
///
/// `applies_to` reuses the header/footer vocabulary because HWP states it with the same three words
/// (`both`/`odd`/`even`) and means the same thing by them; see `HeaderFooterApplicability` for what
/// that folding does and does not preserve.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct OfficeMasterPage {
    /// WHICH SECTION declares it. A master page belongs to its own section the way a running head
    /// does (invariant 77), and unlike a running head this reader keeps them ALL: the flattened
    /// column runs through every section, so a page's template is chosen per page rather than once
    /// per document. Applying one section's everywhere put its chapter title on the cover, the
    /// table of contents and 400 pages of other chapters.
    pub section: i64,
    pub applies_to: HeaderFooterApplicability,
    pub objects: Vec<OfficeMasterObject>,
}

// swift: OfficeReadResult
/// What `OfficeDocumentReader.read` and `DocumentTypes.readOffice` return — the block vocabulary an
/// office document's BODY becomes, plus every reviewer comment the source declares (P6a; see
/// `OfficeComment`). Bundled into one result, rather than two independent return values, so the
/// single dispatch `DocumentTypes.readOffice` (invariant 29) and both readers' `read` stay ONE
/// call, not two that could silently drift out of sync (a comments-only second call would be
/// exactly the kind of second, divergent path invariant 29 exists to prevent). `comments` defaults
/// to `[]` so every pre-P6a construction site (tests building a bare `[OfficeBlock]` result) keeps
/// compiling and means exactly what it always meant: no comments captured.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct OfficeReadResult {
    pub blocks: Vec<OfficeBlock>,
    pub comments: Vec<OfficeComment>,
    // swift: OfficeMasterPage
    /// Pre-decoded embedded image bytes, keyed by the EXACT `.image(id:)` string the blocks carry
    /// (e.g. `"hwpimg:3"`). Empty for the zip-backed readers (`DocxReader`/`OdtReader`), which resolve
    /// an image's pixels lazily from the archive at reconcile time. HWP has NO archive (it is CFB
    /// binary) and the rhwp image FFI needs the LIVE parse handle, which is gone by reconcile — so
    /// `HwpReader.read` pre-decodes every embedded image here at read time and `MarkdownDocument`
    /// checks this map before the archive. Defaults to `[:]` so every existing construction site
    /// (both zip readers, all tests) keeps compiling and means exactly what it always meant: nothing
    /// pre-decoded, resolve from the archive.
    /// Serialized as base64 strings. Foundation's `Data: Decodable` consumes that exact JSON
    /// shape, preserving the bytes the live HWP parse handle extracted before it was closed.
    pub images: std::collections::HashMap<SwiftString, Data>,
    /// `.image(id:)` keys the reader itself established have NO bytes behind them — an empty
    /// `<hc:img binaryItemIDRef="">`, an external link, or bin_data_id's own "no bin data"
    /// sentinel (`0`). This is a POSITIVE statement, set only where the truth is known (the
    /// reader that just asked its own image FFI and got nothing back), and it exists specifically
    /// so that fact stays distinguishable from a caller's resource map simply being incomplete —
    /// which is a programming error and keeps `MissingResource`'s full strictness
    /// (`office_adapter::Ctx::resolve_resource`). Collapsing the two into "the key is just absent
    /// from `images`" was the defect this field replaces: 12 of 400 real documents were refused
    /// outright for a picture the shipped Swift reader has always drawn as an empty box at the
    /// authored size (`OfficeTextBuilder.appendImage` reserves regardless of whether bytes exist).
    /// Empty for the zip-backed readers, which have no equivalent "declared but linked/broken"
    /// signal yet, and for every HWP picture that DOES have bytes — so a document with no such
    /// picture is byte-identical to before this field existed.
    pub pictures_declared_without_bytes: std::collections::HashSet<SwiftString>,
    /// Picture bytes the WIRE carries once, keyed by content — see `picture_pool`.
    ///
    /// Deliberately NOT `images`: that map's key is the exact `.image(id:)` string a block carries,
    /// and a pooled picture has no such id (a table cell's background is not an image block). Two
    /// meanings in one map would make "is this key drawable by id" unanswerable. This one is empty
    /// in memory and empty again after `office_export::from_json`, so a result that round-trips is
    /// equal to the one that was read — which is what makes the round-trip check worth running.
    #[serde(default, skip_serializing_if = "std::collections::HashMap::is_empty")]
    pub picture_pool: std::collections::HashMap<SwiftString, Data>,
    /// Per-edge border declarations the WIRE carries once — see `edge_border_pool`. Empty in
    /// memory and empty again after `office_export::from_json`, exactly like `picture_pool`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub edge_border_pool: Vec<EdgeBorders>,
    /// Paragraph formats the WIRE carries once — see `paragraph_format_pool`. Empty in memory
    /// and empty again after `office_export::from_json`, exactly like `edge_border_pool`.
    ///
    /// Measured on the same manual that justified that one: `format` appears **10,864 times for
    /// 1,635 distinct values**, 1,655,374 bytes — twice the occurrences of `edge_borders`, and
    /// occurrences are what invariant 129 showed the host actually pays for.
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub paragraph_format_pool: Vec<ParagraphFormat>,
    /// Inline vector drawings keyed by the `.image(id:)` layout node that reserves their box.
    /// The host paints these paths and installs the resulting bytes into `images` before layout.
    pub vector_graphics: std::collections::HashMap<
        SwiftString,
        crate::render::office::hwp_shape_path::VectorGraphic,
    >,
    /// The document's own default BODY run size in points — the other half of `OfficeTextBuilder`'s
    /// font-size model (`documentDefaultFontSize`), used to scale every absolute size to the reader's
    /// base. For HWP this is the Normal("바탕글") style's char-shape base size, decoded from the rhwp
    /// envelope's `defaultFontSizePt` (or `11` when rhwp emitted null — the document declared none).
    /// ONLY `HwpReader` populates this: the zip readers (`DocxReader`/`OdtReader`) surface the same
    /// value through `DocumentTypes.officeDefaultBodyFontSize(archive:)` instead and leave this at
    /// its `11` default, because HWP has no `ZipArchive` to run that shared path against and rhwp
    /// already carries the value in the parse it just did — no second FFI call (invariant 29's HWP
    /// branch owns this the same way docx/odt own theirs through the reader lookup).
    pub default_body_font_size: CGFloat,
    // swift: OfficeReadResult
    /// What the document's OWN font table says about each family it names, keyed by that name. Read
    /// only when a declared family cannot be resolved on this machine — 99.5% of font slots across
    /// 1,589 real Korean documents (invariant 95) — to work out what should stand in for it. Empty
    /// means "the document told us nothing extra", which is what the zip readers currently pass and
    /// exactly what the resolver assumed before this existed, so every construction site keeps its
    /// meaning. Format-neutral by design: `.docx` and `.odt` keep equivalent tables and can fill this
    /// in without the substitution pass learning which format it is serving.
    pub declared_faces: std::collections::HashMap<SwiftString, crate::render::office::declared_font_kind::DeclaredFace>,
    /// The document's own page BODY width in points — the printable column between the left and right
    /// page margins (paper width − left margin − right margin), honouring page orientation. It is the
    /// DENOMINATOR of the graphic scale and nothing else: `MarkdownDocument.render(into:)` divides the
    /// reading column by it and hands the ratio to `OfficeTextBuilder.build(graphicScale:)`, so a
    /// picture — authored as a fraction of THIS body width — keeps that same fraction of the column at
    /// any window size, while remaining immune to the reading-size setting.
    ///
    /// It is ALSO, now, what makes a document PAGED: non-nil pins the reading column to this width and
    /// switches ⌘+/⌘− from re-typesetting to magnifying (see `MarkdownDocument.officePageContentWidth`).
    /// `nil` = the reader could not determine it (no section/page-layout, or an out-of-range value) →
    /// graphic scale 1, the old window-filling column, and authored point sizes verbatim, so a document
    /// that declares nothing is byte-identical to before this field existed. Each reader
    /// sources it from its own format: HWP from rhwp's `PageDef` (landscape swaps width/height), docx
    /// from the body `w:sectPr`'s `w:pgSz`/`w:pgMar` (twips), odt from `styles.xml`'s
    /// `style:page-layout-properties` (`fo:page-width`/`fo:margin-*`).
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub page_content_width: Option<CGFloat>,
    /// The page's own LEFT and RIGHT margins in points — the white space either side of
    /// `page_content_width`, so `left + page_content_width + right` is the PAPER width.
    ///
    /// Carried because a paged view has to reproduce the PAPER, not just the body. Word and Pages show
    /// the whole sheet, so at the same window width a reader that lays out only the body magnifies it
    /// by `paper ÷ body` relative to them — measured on four real A4 documents as **1.24× – 1.32×**,
    /// which is most of "우리가 폰트가 과도하게 큰데?". The margins were already being computed by every
    /// reader in order to SUBTRACT them; they were simply thrown away afterwards.
    ///
    /// Kept as two independent values rather than one symmetric inset because a document may set them
    /// differently (a bound report with a wide gutter), and the difference is visible: the text sits
    /// off-centre on the sheet exactly as the author placed it. `nil` for either = the reader did not
    /// find one, and the view falls back to its own margin, unchanged.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub page_margin_left: Option<CGFloat>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub page_margin_right: Option<CGFloat>,
    /// The document's page BODY height in points — the printable row span between the top and bottom
    /// page margins, the vertical twin of `page_content_width`. It exists for the same two reasons that
    /// field does, one already true and one still ahead: it is the second half of the PAPER a paged
    /// view has to reproduce (`top + page_content_height + bottom` is the sheet's full height, exactly
    /// as `left + page_content_width + right` is its full width), and it is the hard prerequisite for
    /// showing where a page ENDS and for placing running headers/footers, neither of which this
    /// change wires up. `nil` = the reader could not determine it (no section/page-layout, no
    /// declared height, or a computed value ≤0) → unchanged from before this field existed, exactly
    /// like a document that declares no `page_content_width`. Sourced the same way per format: HWP from
    /// rhwp's `PageAreas` (paper height − top/bottom margins, landscape-swapped), docx from the body
    /// `w:sectPr`'s `w:pgSz@w:h`/`w:pgMar@w:top`/`@w:bottom` (twips), odt from `styles.xml`'s
    /// `fo:page-height`/`fo:margin-top`/`fo:margin-bottom`.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub page_content_height: Option<CGFloat>,
    /// The page's own TOP and BOTTOM margins in points — the vertical twins of `page_margin_left`/
    /// `page_margin_right`, present together with `page_content_height` (one reader-internal computation
    /// each) and `nil` together with it when the reader found no page height. Kept as two independent
    /// values, not one symmetric inset, for the same reason the horizontal pair is: a document may
    /// set them differently (running headers eat more of the top margin than the bottom), and a
    /// consumer reproducing the sheet needs to know which is which.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub page_margin_top: Option<CGFloat>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub page_margin_bottom: Option<CGFloat>,
    /// How far a running HEADER sits from the paper's own TOP edge, and the FOOTER from its BOTTOM
    /// edge, in points — docx `w:pgMar/@w:header` and `@w:footer`. NOT the same as the body margins
    /// above: the header lives INSIDE the top margin, at its own distance from the sheet's edge.
    ///
    /// Why it matters, measured: without them the reader centred each band's header and footer in
    /// half the gap, and the gap is not constant — it is the body margin PLUS whatever room the last
    /// line of the previous page left unused, which varies with paragraph spacing, headings and
    /// tables. So the header drifted a few points page to page and the owner read it as "홀수쪽,
    /// 짝수쪽의 여백이 다름". Anchored to the sheet edge instead, the spacing is identical on every
    /// page and the leftover shows where it truly is: as white space above the footer, exactly as a
    /// short page looks in Word.
    ///
    /// `nil` = the format did not say (every ODT and HWP document today), and the band falls back to
    /// the halves it used before these existed.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub page_header_distance: Option<CGFloat>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub page_footer_distance: Option<CGFloat>,
    /// Running headers/footers this document declares (header-footer-design.md step 2) — read-only
    /// vocabulary, nothing paints these yet (steps 4/5 of that design). Empty for every document
    /// with none, and for markdown/plain text (they never reach this struct at all). See
    /// `OfficeHeaderFooter`/`HeaderFooterApplicability`. Defaults to `[]` so every pre-existing
    /// construction site (every test, every other reader) keeps compiling and means exactly what it
    /// always meant: no running header/footer captured.
    pub headers: Vec<OfficeHeaderFooter>,
    pub footers: Vec<OfficeHeaderFooter>,
    /// The document's FOOTNOTES, lifted out of the body flow so they can be drawn at the foot of the
    /// page each one is cited on rather than trailing the section that cites them.
    ///
    /// ENDNOTES ARE NOT HERE, deliberately. An endnote belongs at the end of the section or the
    /// document, which is exactly where the flat body flow already puts it — measured on the
    /// 637-document corpus, 1,832 endnotes across 33 documents are correct today and only the 333
    /// footnotes across 22 documents are in the wrong place. Moving both to fix one would be a net
    /// loss, so an endnote stays an ordinary trailing block and never appears in this array.
    pub footnotes: Vec<OfficeFootnote>,
    /// Every 바탕쪽 the document declares, each naming its own section — the reader picks per PAGE,
    /// through `section_start_blocks`. Empty for docx and odt, which have no equivalent mechanism, and
    /// for every HWP that declares none. See `OfficeMasterPage`.
    /// NOT serialised: the 바탕쪽 is an HWP concept, carrying decoded pictures and pre-rendered
    /// vector drawings — bytes, not document facts. `assert_exportable` refuses a non-empty list
    /// rather than letting a page's repeating artwork vanish without a word.
    pub master_pages: Vec<OfficeMasterPage>,
    /// What each SECTION declared about its own page furniture — hidden running head, hidden master
    /// page, a page number that restarts here. Indexed the same way `section_start_blocks` is.
    ///
    /// Which section's header applies to a page was already answerable; whether that section turned
    /// its header OFF was not, so a cover that says "no running head" still got one.
    pub sections: Vec<OfficeSectionDeclaration>,
    /// Objects the document pins to the paper, each naming the block it is anchored at — see
    /// `OfficeAnchoredObject`. Empty for docx and odt.
    /// NOT serialised: an anchored object carries an `OfficeMasterObject`, which is HWP's decoded
    /// pictures and pre-rendered drawings. Same reason as `master_pages`, and the same guard —
    /// `assert_exportable` refuses a non-empty list.
    pub anchored_objects: Vec<OfficeAnchoredObject>,
    /// Where each section begins in `blocks` — `section_start_blocks[i]` is the index of section `i`'s
    /// first block. The document is ONE continuous column here (invariant 57), so this is the only
    /// thing that says which stretch of it belongs to which section, and therefore which master page
    /// covers a given page. Empty for a format or a parser that does not say.
    pub section_start_blocks: Vec<i64>,
    /// Blocks that must not be separated from the block AFTER them (HWP's 다음 문단과 함께 —
    /// `keepWithNext`), plus the ones a STYLE breaks a page before.
    ///
    /// A heading is the whole point: styled "keep with next", it must not be typeset as the last
    /// line of a page with its body starting the next one. A reader that re-paginates on its own —
    /// this one does, at its own fonts and line heights — has no way to know that without the flag,
    /// and the defect looks exactly like a rendering bug rather than a missing input.
    pub keep_with_next_blocks: Vec<i64>,
    /// Blocks the DOCUMENT says must start a new page — a paragraph carrying HWP's own 쪽 나누기 or
    /// 구역 나누기 (`ColumnBreakType::Page`/`Section`).
    ///
    /// Without this a reader receives only the flow, so every break the author placed disappears and
    /// the text simply runs on: a cover's artwork and the foreword meant to follow it on its own page
    /// end up sharing one, and every page after that is off by however much slid up. It is the
    /// document's own instruction, not a heuristic about what looks like a new page.
    pub page_break_blocks: Vec<i64>,
    /// Blocks the DOCUMENT says must print NO PAGE NUMBER on the page they land on — HWP's
    /// `Control::PageHide` (쪽 감추기) with its own `hidePageNum` bit set, a per-paragraph veto
    /// distinct from a SECTION turning its running head off (`OfficeSectionDeclaration`). The
    /// covers and dividers of the 행정업무운영편람 say this 75 times; ignoring it numbered them.
    ///
    /// `Control::PageHide` carries five other switches (header/footer/master-page/border/fill) —
    /// NOT adopted here: the section-level equivalents already cover header/footer/master-page
    /// suppression, and there is no border/fill painter for this reader to veto in the first
    /// place. Only the page-number bit is unique to this per-paragraph marker. Empty for a format
    /// or a parser that does not say.
    pub hide_page_number_blocks: Vec<i64>,
    /// Where the document restarts its PAGE counter, as (block index, first number). HWP's
    /// NewNumber; empty for every other format. A page's displayed number is its distance from the
    /// most recent restart at or before it, which is arithmetic the reader has to do because it
    /// computes the number rather than reading it out of the document's text.
    pub page_number_restart_blocks: Vec<OfficePageNumberRestart>,
    /// The section's LINE GRID pitch in points — Word's `w:sectPr/w:docGrid` with
    /// `@w:type="lines"`/`"linesAndChars"`, whose `@w:linePitch` is in twips.
    ///
    /// This is how a Korean or Japanese Word document states "every line sits on an N-point grid",
    /// and it is applied to text that declares no line spacing of its own — which, in the document
    /// this was found on, is nearly all of it. Word snaps to 18.00pt there; TextKit, given the same
    /// runs and no instruction, produces the font's natural 13.0pt. Measured on that file's tables:
    /// a row Word draws at 18.48pt came out at 13.33pt once the cell-padding error above it was
    /// fixed — five points SHORT, not over. Reading the grid is what closes it.
    ///
    /// `nil` for ODT, HWP, markdown and every docx without a `w:docGrid`, which keeps all of them
    /// byte-identical (invariant 37): the paged branch falls back to the natural line height it uses
    /// today. It is a FLOOR, never a ceiling — a paragraph that states its own larger spacing keeps
    /// it, exactly as Word does.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub line_grid_pitch: Option<CGFloat>,
}

impl PartialEq for OfficeReadResult {
    fn eq(&self, other: &Self) -> bool {
        let Self {
            blocks, comments, images, pictures_declared_without_bytes, picture_pool,
            edge_border_pool, paragraph_format_pool, vector_graphics,
            default_body_font_size, declared_faces,
            page_content_width, page_margin_left, page_margin_right, page_content_height,
            page_margin_top, page_margin_bottom, page_header_distance, page_footer_distance,
            headers, footers, footnotes, master_pages, sections, anchored_objects,
            section_start_blocks, keep_with_next_blocks, page_break_blocks,
            hide_page_number_blocks, page_number_restart_blocks, line_grid_pitch,
        } = self;
        blocks == &other.blocks
            && comments == &other.comments
            && map_eq(images, &other.images)
            && pictures_declared_without_bytes == &other.pictures_declared_without_bytes
            && map_eq(picture_pool, &other.picture_pool)
            && edge_border_pool == &other.edge_border_pool
            && paragraph_format_pool == &other.paragraph_format_pool
            && map_eq(vector_graphics, &other.vector_graphics)
            && default_body_font_size == &other.default_body_font_size
            && map_eq(declared_faces, &other.declared_faces)
            && page_content_width == &other.page_content_width
            && page_margin_left == &other.page_margin_left
            && page_margin_right == &other.page_margin_right
            && page_content_height == &other.page_content_height
            && page_margin_top == &other.page_margin_top
            && page_margin_bottom == &other.page_margin_bottom
            && page_header_distance == &other.page_header_distance
            && page_footer_distance == &other.page_footer_distance
            && headers == &other.headers
            && footers == &other.footers
            && footnotes == &other.footnotes
            && master_pages == &other.master_pages
            && sections == &other.sections
            && anchored_objects == &other.anchored_objects
            && section_start_blocks == &other.section_start_blocks
            && keep_with_next_blocks == &other.keep_with_next_blocks
            && page_break_blocks == &other.page_break_blocks
            && hide_page_number_blocks == &other.hide_page_number_blocks
            && page_number_restart_blocks == &other.page_number_restart_blocks
            && line_grid_pitch == &other.line_grid_pitch
    }
}

impl Default for OfficeReadResult {
    fn default() -> Self {
        OfficeReadResult {
            blocks: vec![],
            comments: vec![],
            images: std::collections::HashMap::new(),
            pictures_declared_without_bytes: std::collections::HashSet::new(),
            picture_pool: std::collections::HashMap::new(),
            edge_border_pool: Vec::new(),
            paragraph_format_pool: Vec::new(),
            vector_graphics: std::collections::HashMap::new(),
            default_body_font_size: 11.0,
            declared_faces: std::collections::HashMap::new(),
            page_content_width: None,
            page_margin_left: None,
            page_margin_right: None,
            page_content_height: None,
            page_margin_top: None,
            page_margin_bottom: None,
            page_header_distance: None,
            page_footer_distance: None,
            headers: vec![],
            footers: vec![],
            footnotes: vec![],
            master_pages: vec![],
            sections: vec![],
            anchored_objects: vec![],
            section_start_blocks: vec![],
            keep_with_next_blocks: vec![],
            page_break_blocks: vec![],
            hide_page_number_blocks: vec![],
            page_number_restart_blocks: vec![],
            line_grid_pitch: None,
        }
    }
}

// swift: OfficeFormControl
/// A form control embedded in a document — HWP's `FormObject`.
///
/// This reader is a VIEWER, so a control is something to read, never something to operate: a
/// checkbox says whether it is ticked and a button says what it is labelled, and neither responds
/// to a click. Measured over the 637-sample corpus (`examples/scan_forms.rs`): 12 documents (1.9%)
/// embed one, but they hold 406 controls between them and **365 of those (90%) are checkboxes** —
/// so a document that has any tends to be a form, where the controls ARE the content. One such
/// sample renders as a completely blank page today, which is the state this replaces.
///
/// NOTE: same `CGFloat`-is-`f64` caveat as `TabStop` above — `Hashable` needs a manual impl.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct OfficeFormControl {
    pub kind: OfficeFormControlKind,
    /// The control's own label (a button's face, a checkbox's text).
    pub caption: SwiftString,
    /// What an editable control currently holds.
    pub text: SwiftString,
    /// Non-zero when a checkbox or radio button is ticked.
    pub value: i64,
    /// A control the document greyed out. Drawn dimmed rather than hidden — it is part of the form.
    pub enabled: bool,
}

impl Default for OfficeFormControl {
    fn default() -> Self {
        OfficeFormControl {
            kind: OfficeFormControlKind::Unknown,
            caption: SwiftString::from(String::new()),
            text: SwiftString::from(String::new()),
            value: 0,
            enabled: true,
        }
    }
}

// swift: OfficeFormControl.Kind
/// `OfficeFormControl.Kind` in Swift — a String-backed enum (docx form-field kind names).
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OfficeFormControlKind {
    CheckBox,
    RadioButton,
    PushButton,
    ComboBox,
    Edit,
    ListBox,
    ScrollBar,
    Unknown,
}

impl OfficeFormControlKind {
    pub fn new(exported: Option<&str>) -> OfficeFormControlKind {
        match exported.unwrap_or("") {
            "checkBox" => OfficeFormControlKind::CheckBox,
            "radioButton" => OfficeFormControlKind::RadioButton,
            "pushButton" => OfficeFormControlKind::PushButton,
            "comboBox" => OfficeFormControlKind::ComboBox,
            "edit" => OfficeFormControlKind::Edit,
            "listBox" => OfficeFormControlKind::ListBox,
            "scrollBar" => OfficeFormControlKind::ScrollBar,
            _ => OfficeFormControlKind::Unknown,
        }
    }
}

impl OfficeFormControl {
    pub fn is_ticked(&self) -> bool {
        self.value != 0
    }

    /// What the reader puts on the page for this control.
    ///
    /// TEXT, not a drawn widget, and deliberately: a glyph run is found by ⌘F, copied with the
    /// selection, carried into `--extract` and measured by the same typesetter as everything around
    /// it, all of which a custom-drawn box would have to re-earn one at a time. The characters are
    /// the ones the format itself is drawn with in every Korean form — a ticked box reads as ticked
    /// without a legend.
    pub fn display_text(&self) -> SwiftString {
        let caption = self.caption.to_string();
        let text = self.text.to_string();
        let s = match self.kind {
            OfficeFormControlKind::CheckBox => {
                self.join(if self.is_ticked() { "☒" } else { "☐" }, &caption)
            }
            OfficeFormControlKind::RadioButton => {
                self.join(if self.is_ticked() { "◉" } else { "○" }, &caption)
            }
            OfficeFormControlKind::PushButton => {
                format!("[ {} ]", if caption.is_empty() { " " } else { &caption })
            }
            OfficeFormControlKind::ComboBox => {
                format!("[ {} ▾ ]", if text.is_empty() { &caption } else { &text })
            }
            OfficeFormControlKind::Edit => {
                // An empty field is a RULE, not nothing: a blank form still has to show where the
                // answers go, which is the whole point of printing one.
                if text.is_empty() { "[________]".to_string() } else { format!("[ {} ]", text) }
            }
            OfficeFormControlKind::ListBox | OfficeFormControlKind::ScrollBar | OfficeFormControlKind::Unknown => {
                let label = if text.is_empty() { &caption } else { &text };
                if label.is_empty() { String::new() } else { format!("[ {} ]", label) }
            }
        };
        SwiftString::from(s)
    }

    // swift: OfficeFormControl.join
    fn join(&self, mark: &str, label: &str) -> String {
        if label.is_empty() { mark.to_string() } else { format!("{} {}", mark, label) }
    }
}
