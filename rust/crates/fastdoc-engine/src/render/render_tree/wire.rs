//! Private Serde wire model. No value here is canonical before validation.

macro_rules! string_enum {
    ($name:ident { $($variant:ident => $wire:literal),+ $(,)? }) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
        pub enum $name { $(#[serde(rename = $wire)] $variant),+ }
        impl $name {
            pub const ALL: &'static [&'static str] = &[$($wire),+];
            #[cfg(test)] pub const VARIANTS: &'static [Self] = &[$(Self::$variant),+];
        }
    };
}

macro_rules! all_string_enums {
    ($($name:ident { $($variant:ident => $wire:literal),+ $(,)? }),+ $(,)?) => {
        $(string_enum!($name { $($variant => $wire),+ });)+
        pub const ALL_ENUM_VALUES: &[&[&str]] = &[$($name::ALL),+];
        pub const ALL_ENUM_CATALOG: &[(&str, &[&str])] = &[$((stringify!($name), $name::ALL)),+];
        #[cfg(test)]
        pub fn assert_all_enum_round_trips() {
            fn check<T>(variants: &'static [T])
            where T: serde::Serialize + serde::de::DeserializeOwned + PartialEq
                + std::fmt::Debug + Copy + 'static {
                assert!(!variants.is_empty());
                for variant in variants {
                    let bytes = serde_json::to_vec(variant).unwrap();
                    let decoded: T = serde_json::from_slice(&bytes).unwrap();
                    assert_eq!(*variant, decoded);
                }
            }
            $(check($name::VARIANTS);)+
        }
    };
}

all_string_enums! {
    Representation { Semantic => "semantic" },
    DocumentFormat { Markdown => "markdown", PlainText => "plainText", Docx => "docx", Odt => "odt", Hwp => "hwp", Hwpx => "hwpx" },
    SourceKind { OriginalFile => "originalFile", ArchivePart => "archivePart", DecodedText => "decodedText", LogicalText => "logicalText", Generated => "generated" },
    SpanPurpose { Provenance => "provenance", Editable => "editable" },
    Affinity { Exact => "exact", Before => "before", After => "after", Covering => "covering" },
    EditOperation { InsertText => "insertText", ReplaceText => "replaceText", DeleteText => "deleteText", Structure => "structure" },
    Direction { Natural => "natural", LeftToRight => "leftToRight", RightToLeft => "rightToLeft" },
    Alignment { Natural => "natural", Left => "left", Center => "center", Right => "right", Justified => "justified" },
    VerticalAlignment { Top => "top", Middle => "middle", Bottom => "bottom" },
    UnderlineStyle { Single => "single", Double => "double", Dotted => "dotted", Dashed => "dashed", Wavy => "wavy" },
    LineBreakKind { Soft => "soft", Hard => "hard" },
    DiagramLanguage { Mermaid => "mermaid", Other => "other" },
    FormControlKind { CheckBox => "checkBox", RadioButton => "radioButton", PushButton => "pushButton", ComboBox => "comboBox", Edit => "edit", ListBox => "listBox", ScrollBar => "scrollBar", Unknown => "unknown" },
    VerticalPosition { Normal => "normal", Superscript => "superscript", Subscript => "subscript" },
    PageNumberField { Page => "page", NumPages => "numPages" },
    TabAlignment { Left => "left", Center => "center", Right => "right", Decimal => "decimal" },
    TabLeader { None => "none", Dot => "dot", Hyphen => "hyphen", Underscore => "underscore" },
    LineHeightMode { Multiple => "multiple", Exact => "exact", AtLeast => "atLeast" },
    HeaderFooterApplicability { DefaultPages => "defaultPages", FirstPage => "firstPage", EvenPages => "evenPages" },
    LineBreakGranularity { Word => "word", Hyphen => "hyphen", Character => "character" },
    ListNumberingGlyphs { Decimal => "decimal", CircledDecimal => "circledDecimal", RomanUpper => "romanUpper", RomanLower => "romanLower", LatinUpper => "latinUpper", LatinLower => "latinLower", HangulSyllable => "hangulSyllable", HangulNumber => "hangulNumber", HanjaNumber => "hanjaNumber" },
    ColorSpace { Srgb => "sRGB", DeviceRgb => "deviceRGB" },
    BorderLineStyle { Solid => "solid", Dashed => "dashed", Dotted => "dotted", Double => "double" },
    CellDiagonalDirection { Slash => "slash", Backslash => "backslash", Both => "both" },
    TablePageBreakPolicy { Never => "never", AtRowBoundary => "atRowBoundary", Anywhere => "anywhere" },
    ColumnFlowType { Normal => "normal", Distribute => "distribute", Parallel => "parallel" },
    ColumnFlowDirection { LeftToRight => "leftToRight", RightToLeft => "rightToLeft" },
    ColumnWidthMode { Equal => "equal", Absolute => "absolute", Proportional => "proportional" },
    ColumnSeparatorStyle { None => "none", Solid => "solid", Dash => "dash", Dot => "dot", DashDot => "dashDot", DashDotDot => "dashDotDot", LongDash => "longDash", Circle => "circle" },
}

#[allow(clippy::derivable_impls)]
impl Default for VerticalPosition {
    fn default() -> Self {
        Self::Normal
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct EnvelopeV1 {
    pub schema_version: u32,
    pub representation: Representation,
    pub producer: Producer,
    pub document: Document,
    pub sources: Vec<SourceDescriptor>,
    pub nodes: Vec<Node>,
    pub resources: Vec<Resource>,
    pub annotations: Annotations,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Producer {
    pub engine_version: String,
    pub schema_version: u32,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Document {
    pub format: DocumentFormat,
    pub editable: bool,
    pub root_node_id: u64,
    pub source_ids: Vec<u64>,
    #[serde(default)]
    pub default_locale: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceDescriptor {
    pub id: u64,
    pub kind: SourceKind,
    pub name: String,
    #[serde(default)]
    pub encoding: Option<String>,
    pub revision: String,
    pub sha256: String,
    #[serde(default)]
    pub byte_length: Option<u64>,
    #[serde(default)]
    pub utf8_length: Option<u64>,
    #[serde(default)]
    pub utf16_length: Option<u64>,
    pub editable: bool,
    #[serde(default)]
    pub text_content: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Node {
    pub id: u64,
    #[serde(default)]
    pub parent_id: Option<u64>,
    #[serde(default)]
    pub children: Vec<u64>,
    #[serde(default)]
    pub source_spans: Vec<SourceSpan>,
    #[serde(default)]
    pub edit: Option<EditMetadata>,
    #[serde(flatten)]
    pub payload: NodePayload,
}

macro_rules! node_payloads {
    ($($variant:ident => $tag:literal ($payload:ty)),+ $(,)?) => {
        #[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
        #[serde(tag = "type", content = "data")]
        pub enum NodePayload { $(#[serde(rename = $tag)] $variant($payload)),+ }
        impl NodePayload {
            pub const ALL_TAGS: &'static [&'static str] = &[$($tag),+];
            pub fn tag(&self) -> &'static str { match self { $(Self::$variant(_) => $tag),+ } }
        }
    };
}

node_payloads! {
    Document => "document" (Empty), Section => "section" (Section), Flow => "flow" (Empty),
    Heading => "heading" (Heading), Paragraph => "paragraph" (Paragraph), TextRun => "textRun" (TextRun),
    LineBreak => "lineBreak" (LineBreak), BlockQuote => "blockQuote" (Empty), CodeBlock => "codeBlock" (CodeBlock),
    ThematicBreak => "thematicBreak" (Empty), List => "list" (List), ListItem => "listItem" (ListItem),
    TaskListItem => "taskListItem" (TaskListItem), Table => "table" (Table), TableRow => "tableRow" (TableRow),
    TableCell => "tableCell" (TableCell), Image => "image" (Image), Vector => "vector" (Vector),
    Formula => "formula" (Formula), Diagram => "diagram" (Diagram), RawHtml => "rawHtml" (RawHtml),
    Footnote => "footnote" (Footnote), Header => "header" (HeaderFooter), Footer => "footer" (HeaderFooter),
    FormControl => "formControl" (FormControl), Unsupported => "unsupported" (Unsupported),
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct Empty {}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceSpan {
    pub source_id: u64,
    pub purpose: SpanPurpose,
    pub affinity: Affinity,
    pub segments: Vec<RangeSegment>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum RangeSegment {
    Byte {
        start: u64,
        end: u64,
    },
    Text {
        utf8_start: u64,
        utf8_end: u64,
        utf16_start: u64,
        utf16_end: u64,
    },
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditMetadata {
    pub editable: bool,
    #[serde(default)]
    pub source_id: Option<u64>,
    #[serde(default)]
    pub revision: Option<String>,
    #[serde(default)]
    pub operation_class: Option<EditOperation>,
}

#[derive(Debug, Clone, Copy, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Color {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    pub alpha: f64,
    pub space: ColorSpace,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Copy, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Insets {
    pub top: f64,
    pub right: f64,
    pub bottom: f64,
    pub left: f64,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DrawnBorder {
    pub width_points: f64,
    #[serde(default)]
    pub color: Option<Color>,
    pub style: BorderLineStyle,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "camelCase")]
pub enum BorderDeclaration {
    Suppressed,
    Drawn(DrawnBorder),
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BorderSet {
    #[serde(default)]
    pub top: Option<BorderDeclaration>,
    #[serde(default)]
    pub right: Option<BorderDeclaration>,
    #[serde(default)]
    pub bottom: Option<BorderDeclaration>,
    #[serde(default)]
    pub left: Option<BorderDeclaration>,
    #[serde(default)]
    pub inside_horizontal: Option<BorderDeclaration>,
    #[serde(default)]
    pub inside_vertical: Option<BorderDeclaration>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OptionalInsets {
    #[serde(default)]
    pub top: Option<f64>,
    #[serde(default)]
    pub right: Option<f64>,
    #[serde(default)]
    pub bottom: Option<f64>,
    #[serde(default)]
    pub left: Option<f64>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CellDiagonal {
    pub direction: CellDiagonalDirection,
    pub side: DrawnBorder,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UniformBorder {
    #[serde(default)]
    pub color: Option<Color>,
    #[serde(default)]
    pub width_points: Option<f64>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TableStyle {
    #[serde(default)]
    pub default_uniform_border: Option<UniformBorder>,
    #[serde(default)]
    pub default_shading: Option<Color>,
    #[serde(default)]
    pub edge_borders: Option<BorderSet>,
    #[serde(default)]
    pub default_padding: Option<OptionalInsets>,
    #[serde(default)]
    pub source_width_points: Option<f64>,
    #[serde(default)]
    pub repeat_header_rows: Option<bool>,
    #[serde(default)]
    pub page_break_policy: Option<TablePageBreakPolicy>,
    #[serde(default)]
    pub outer_margin: Option<OptionalInsets>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CharacterStyle {
    #[serde(default)]
    pub bold: bool,
    #[serde(default)]
    pub italic: bool,
    #[serde(default)]
    pub strike: bool,
    #[serde(default)]
    pub inline_code: bool,
    #[serde(default)]
    pub caps: bool,
    #[serde(default)]
    pub small_caps: bool,
    #[serde(default)]
    pub underline: Option<UnderlineStyle>,
    #[serde(default)]
    pub vertical_position: VerticalPosition,
    #[serde(default)]
    pub letter_spacing_percent: Option<f64>,
    #[serde(default)]
    pub baseline_offset_percent: Option<f64>,
    #[serde(default)]
    pub underline_color: Option<Color>,
    #[serde(default)]
    pub strikethrough_color: Option<Color>,
    #[serde(default)]
    pub declared_font_name: Option<String>,
    #[serde(default)]
    pub font_families: Vec<String>,
    #[serde(default)]
    pub font_size_points: Option<f64>,
    #[serde(default)]
    pub foreground: Option<Color>,
    #[serde(default)]
    pub background: Option<Color>,
    #[serde(default)]
    pub baseline_offset_points: Option<f64>,
    #[serde(default)]
    pub language: Option<String>,
    #[serde(default)]
    pub script: Option<String>,
    #[serde(default)]
    pub feature_flags: Vec<String>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ParagraphStyle {
    #[serde(default)]
    pub alignment: Option<Alignment>,
    #[serde(default)]
    pub direction: Option<Direction>,
    #[serde(default)]
    pub first_line_indent: Option<f64>,
    #[serde(default)]
    pub head_indent: Option<f64>,
    #[serde(default)]
    pub tail_indent: Option<f64>,
    #[serde(default)]
    pub spacing_before: Option<f64>,
    #[serde(default)]
    pub spacing_after: Option<f64>,
    #[serde(default)]
    pub line_height: Option<LineHeight>,
    #[serde(default)]
    pub borders: Option<BorderSet>,
    #[serde(default)]
    pub shading: Option<Color>,
    #[serde(default, rename = "columns", skip_serializing)]
    pub(crate) legacy_columns: Option<SectionColumns>,
    #[serde(default)]
    pub list_text_distance: Option<f64>,
    #[serde(default)]
    pub hanging_indent: Option<f64>,
    #[serde(default)]
    pub contextual_spacing: bool,
    #[serde(default)]
    pub east_asian_line_break: Option<LineBreakGranularity>,
    #[serde(default)]
    pub latin_line_break: Option<LineBreakGranularity>,
    #[serde(default)]
    pub auto_space_east_asian_latin: Option<bool>,
    #[serde(default)]
    pub auto_space_east_asian_number: Option<bool>,
    #[serde(default)]
    pub line_height_from_font_metrics: Option<bool>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LineHeight {
    pub value: f64,
    /// Three states, because a document that asks for a MINIMUM line height means something a
    /// two-state exact/multiple pair cannot say: a line needing more room must be allowed to grow.
    /// Collapsing "at least" into "exact" clips tall glyphs and inline images.
    pub mode: LineHeightMode,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SectionColumns {
    pub count: u32,
    #[serde(default)]
    pub widths: Vec<f64>,
    #[serde(default)]
    pub gaps: Vec<f64>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ColumnSeparator {
    pub style: ColumnSeparatorStyle,
    pub source_width_code: u8,
    pub width_points: f64,
    pub source_color_ref: u32,
    pub color: Color,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ColumnFlowDeclaration {
    pub count: u32,
    pub spacing_points: f64,
    pub widths: Vec<f64>,
    pub gaps: Vec<f64>,
    pub flow_type: ColumnFlowType,
    pub direction: ColumnFlowDirection,
    pub width_mode: ColumnWidthMode,
    pub source_same_width: bool,
    pub source_proportional_widths: bool,
    pub source_raw_attributes: u16,
    pub separator: ColumnSeparator,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Paper {
    pub width_points: f64,
    pub height_points: f64,
    pub margins: Insets,
    /// How far the running header sits from the sheet's own edge, when the document says. Beside
    /// the margins because it is the same kind of fact: `None` is "this format did not say", which
    /// is not the same as zero. Anchoring the band to the sheet rather than splitting the margin is
    /// what keeps the header from drifting page to page (invariant 62).
    #[serde(default)]
    pub header_distance_points: Option<f64>,
    /// The footer's own distance from the sheet edge, read the same way.
    #[serde(default)]
    pub footer_distance_points: Option<f64>,
}
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PageNumbering {
    pub start: Option<i64>,
    pub hidden: bool,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Section {
    pub paper: Option<Paper>,
    pub columns: Option<SectionColumns>,
    #[serde(default)]
    pub header_ids: Vec<u64>,
    #[serde(default)]
    pub footer_ids: Vec<u64>,
    #[serde(default)]
    pub page_numbering: PageNumbering,
    #[serde(default)]
    pub line_grid_points: Option<f64>,
}
/// The document's own pagination instructions for ONE paragraph-class block.
///
/// Not style: style is how the block looks, these are orders the document gives the paginator, and
/// every Office format attaches them to the paragraph rather than to a section. They live in one
/// shared struct because the source carries them as parallel block-index lists
/// (`OfficeReadResult.keep_with_next_blocks`, `page_break_blocks`, `hide_page_number_blocks`,
/// `page_number_restart_blocks`) whose indices may land on ANY paragraph-class block — and in HWP
/// a paragraph becomes a `Heading` whenever it declares an outline level or a heading style
/// (invariant 33). Carrying these on `Paragraph` alone loses the two commonest cases in real
/// documents: a heading kept with the paragraph below it, and a chapter heading that starts a new
/// page.
///
/// `hides_page_number` and `page_number_restart` are per-BLOCK facts and deliberately NOT the
/// section-level `PageNumbering`: HWP's `Control::PageHide` (쪽 감추기) is documented as distinct
/// from a section turning its running head off, and `NewNumber` restarts the counter at an
/// arbitrary paragraph. The readers already collapse both from HWP's span-level markers to
/// paragraph granularity, so matching that resolution here is faithful rather than lossy.
#[derive(Debug, Clone, Default, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ParagraphPagination {
    pub keep_with_next: bool,
    pub page_break_before: bool,
    /// The page this block lands on prints NO page number.
    pub hides_page_number: bool,
    /// The page counter restarts at this number on the page this block lands on.
    pub page_number_restart: Option<i64>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Heading {
    pub level: i64,
    #[serde(default)]
    pub style: ParagraphStyle,
    #[serde(default)]
    pub tab_stops: Vec<TabStop>,
    #[serde(default)]
    pub pagination: ParagraphPagination,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Paragraph {
    #[serde(default)]
    pub style: ParagraphStyle,
    #[serde(default)]
    pub tab_stops: Vec<TabStop>,
    #[serde(default)]
    pub pagination: ParagraphPagination,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Field {
    pub kind: String,
    pub value: String,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextRun {
    pub text: String,
    #[serde(default)]
    pub style: CharacterStyle,
    #[serde(default)]
    pub direction: Option<Direction>,
    #[serde(default)]
    pub link: Option<String>,
    #[serde(default)]
    pub bookmark_ids: Vec<u64>,
    #[serde(default)]
    pub comment_ids: Vec<u64>,
    #[serde(default)]
    pub field: Option<Field>,
    #[serde(default)]
    pub footnote_reference_number: Option<i64>,
    #[serde(default)]
    pub form_control: Option<InlineFormControl>,
    #[serde(default)]
    pub page_number_field: Option<PageNumberField>,
    #[serde(default)]
    pub column_flow: Option<ColumnFlowDeclaration>,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LineBreak {
    pub kind: LineBreakKind,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodeBlock {
    pub language: Option<String>,
    pub fenced: bool,
    pub text: String,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Numbering {
    pub glyphs: ListNumberingGlyphs,
    #[serde(default)]
    pub start_number: Option<i64>,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct List {
    pub numbering: Numbering,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListItem {
    pub level: u32,
    pub ordered: bool,
    pub marker: Option<String>,
    pub numbering: Option<Numbering>,
    #[serde(default)]
    pub style: ParagraphStyle,
    #[serde(default)]
    pub tab_stops: Vec<TabStop>,
    #[serde(default)]
    pub pagination: ParagraphPagination,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TabStop {
    pub position_points: f64,
    pub alignment: TabAlignment,
    pub leader: TabLeader,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InlineFormControl {
    pub kind: FormControlKind,
    pub caption: String,
    pub text: String,
    pub value: i64,
    pub enabled: bool,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskListItem {
    pub checked: bool,
    pub level: Option<u32>,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Table {
    #[serde(default)]
    pub grid_widths: Vec<f64>,
    pub alignment: Alignment,
    pub preferred_width: Option<f64>,
    pub header_rows: u32,
    #[serde(default)]
    pub source_column_widths: Vec<f64>,
    pub style: TableStyle,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TableRow {
    pub row: u32,
    pub header: bool,
    pub cant_split: bool,
    pub height: Option<f64>,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TableCell {
    pub row: u32,
    pub column: u32,
    pub row_span: u32,
    pub column_span: u32,
    #[serde(default)]
    pub direct_shading: Option<Color>,
    #[serde(default)]
    pub direct_uniform_border: Option<UniformBorder>,
    #[serde(default)]
    pub direct_edge_borders: Option<BorderSet>,
    #[serde(default)]
    pub declared_width_points: Option<f64>,
    #[serde(default)]
    pub vertical_alignment: Option<VerticalAlignment>,
    #[serde(default)]
    pub uniform_padding_points: Option<f64>,
    #[serde(default)]
    pub edge_padding: Option<OptionalInsets>,
    #[serde(default)]
    pub diagonal: Option<CellDiagonal>,
    #[serde(default)]
    pub style_shading: Option<Color>,
    #[serde(default)]
    pub style_uniform_border: Option<UniformBorder>,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Image {
    pub resource_id: u64,
    pub intrinsic_size: Size,
    pub display_size: Option<Size>,
    pub alignment: Alignment,
    pub alt_text: Option<String>,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PathCommand {
    pub command: String,
    #[serde(default)]
    pub values: Vec<f64>,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
/// One drawn path of a vector graphic. The geometry alone is not the drawing: a document states a
/// stroke, a fill and arrowheads per path, and a shape reduced to its outline loses the difference
/// between a filled callout and a bare line.
pub struct VectorPath {
    #[serde(default)]
    pub commands: Vec<PathCommand>,
    #[serde(default)]
    pub stroke: Option<DrawnBorder>,
    #[serde(default)]
    pub fill: Option<Color>,
    pub arrow_start: bool,
    pub arrow_end: bool,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Vector {
    pub resource_id: Option<u64>,
    #[serde(default)]
    pub paths: Vec<VectorPath>,
    pub intrinsic_size: Size,
    pub display_size: Option<Size>,
    pub alignment: Alignment,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Formula {
    pub source: String,
    pub display: bool,
    pub alignment: Alignment,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Diagram {
    pub language: DiagramLanguage,
    pub source: String,
    pub rendered_resource_id: Option<u64>,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RawHtml {
    pub block: bool,
    pub source: String,
}
/// Which pages a running header or footer applies to. Without this, a document that gives its
/// title page its own header prints that header on every page: docx states the three-way split
/// directly (`w:headerReference/@w:type`) and ODF states it by element suffix, so the distinction
/// is authored, not inferred. HWP has no first-page concept in this mechanism and folds onto
/// `DefaultPages`/`EvenPages`.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HeaderFooter {
    pub applies_to: HeaderFooterApplicability,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Footnote {
    pub label: Option<String>,
    pub number: u64,
    pub body_flow_id: u64,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FormControl {
    pub kind: FormControlKind,
    pub caption: String,
    pub text: String,
    pub value: i64,
    pub enabled: bool,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Unsupported {
    pub source_format_tag: String,
    pub reason: String,
    pub preserved_text: Option<String>,
    #[serde(default)]
    pub resource_ids: Vec<u64>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Resource {
    pub id: u64,
    pub mime_type: String,
    pub sha256: String,
    pub byte_length: u64,
    pub bytes_base64: String,
    pub intrinsic_size: Option<Size>,
}
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Annotations {
    #[serde(default)]
    pub comments: Vec<Comment>,
    #[serde(default)]
    pub bookmarks: Vec<Bookmark>,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Comment {
    pub id: u64,
    pub author: String,
    pub text: String,
    pub date_iso: Option<String>,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Bookmark {
    pub id: u64,
    pub name: String,
    pub target_node_id: u64,
}
