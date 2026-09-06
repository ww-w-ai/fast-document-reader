using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace FastDoc.Avalonia.Model;

/// <summary>
/// C# mirror of the RenderTree wire envelope (rust/crates/fastdoc-engine/src/render/
/// render_tree/wire.rs, EnvelopeV1). Only the top-level shape plus each node's kind/id/parent/
/// children/text is decoded structurally — every field this host does not read stays in the
/// JSON and is simply unread, so a field added later does not break this host (forward-compatible
/// by construction). The typed payload getters below (RenderNode.AsHeading etc.) decode ONE
/// node's "data" object into a typed record on demand, for E2a's flow layout — still leaving any
/// field neither this file nor those records name untouched in the raw JsonElement.
///
/// The wire has no bounding-box field: this schema version carries document STRUCTURE, not a
/// finished layout (see hosts/avalonia/README.md and docs/studio/adr/0002-host-layout-interim.md).
/// A host that wants boxes lays the tree out itself — FlowDocumentView does that with Avalonia's
/// own TextLayout, per ADR 0002.
/// </summary>
public sealed class RenderTreeEnvelope
{
    [JsonPropertyName("ok")]
    public JsonElement? Ok { get; set; }

    [JsonPropertyName("error")]
    public RenderTreeError? Error { get; set; }

    public bool IsOk => Ok is not null;
}

public sealed class RenderTreeError
{
    [JsonPropertyName("kind")]
    public string? Kind { get; set; }

    [JsonPropertyName("message")]
    public string? Message { get; set; }

    [JsonPropertyName("location")]
    public string? Location { get; set; }
}

/// <summary>The `ok` payload's own shape — schemaVersion/document/nodes/resources/annotations is
/// all this host reads. `Resources` (E2b) carries picture bytes for the image/vector nodes that
/// reference them by `resourceId` — absent for a document that declared none, per wire::Resource's
/// own doc. `Annotations` (S8-B2) is `wire::EnvelopeV1.annotations`, always present (not
/// `Option`) — a document with no comments/bookmarks still carries empty lists, never a missing
/// key, so this field is never null once the envelope decodes at all.</summary>
public sealed class RenderTree
{
    [JsonPropertyName("schemaVersion")]
    public uint SchemaVersion { get; set; }

    [JsonPropertyName("document")]
    public RenderDocument? Document { get; set; }

    [JsonPropertyName("nodes")]
    public List<RenderNode> Nodes { get; set; } = new();

    [JsonPropertyName("resources")]
    public List<ResourceWire> Resources { get; set; } = new();

    [JsonPropertyName("annotations")]
    public AnnotationsWire? Annotations { get; set; }
}

/// <summary>C# mirror of `wire::Annotations` (rust/crates/fastdoc-engine/src/render/render_tree/
/// wire.rs) — review comments and bookmarks the source document carried, independent of the node
/// tree (a comment anchors to a run via `TextRun.commentIds`, not by being a node itself).</summary>
public sealed class AnnotationsWire
{
    [JsonPropertyName("comments")] public List<CommentWire> Comments { get; set; } = new();
    [JsonPropertyName("bookmarks")] public List<BookmarkWire> Bookmarks { get; set; } = new();
}

/// <summary>C# mirror of `wire::Comment` — one review comment. `Number` is the comment's 1-based
/// DISPLAY order (by anchor position, or file order for an unanchored one), the same number a
/// native office app's review pane would show; `SourceId` is the document's OWN id for the
/// comment (docx `w:comment/@w:id`, odt `office:name`), not this tree's internal `Id`.</summary>
public sealed class CommentWire
{
    [JsonPropertyName("id")] public ulong Id { get; set; }
    [JsonPropertyName("sourceId")] public string SourceId { get; set; } = "";
    [JsonPropertyName("author")] public string Author { get; set; } = "";
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    [JsonPropertyName("dateIso")] public string? DateIso { get; set; }
    [JsonPropertyName("number")] public long Number { get; set; }
}

/// <summary>C# mirror of `wire::Bookmark` — not read by this host yet (S8-B2 scope is comments
/// only); carried so a future feature does not need another envelope round-trip to add it.</summary>
public sealed class BookmarkWire
{
    [JsonPropertyName("id")] public ulong Id { get; set; }
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("targetNodeId")] public ulong TargetNodeId { get; set; }
}

/// <summary>C# mirror of wire::Resource — the picture bytes an Image/Vector node's `resourceId`
/// points into. `BytesBase64` is `null` when the document holds this resource by reference only
/// (no bytes shipped in this tree); ImageBlockRenderer treats that the same as a decode failure —
/// a placeholder, never a crash.</summary>
public sealed class ResourceWire
{
    [JsonPropertyName("id")] public ulong Id { get; set; }
    [JsonPropertyName("mimeType")] public string MimeType { get; set; } = "";
    [JsonPropertyName("bytesBase64")] public string? BytesBase64 { get; set; }
    [JsonPropertyName("intrinsicSize")] public SizeWire? IntrinsicSize { get; set; }
    /// <summary>E2d: the document's OWN id for this resource (wire::Resource.sourceKey, e.g.
    /// "hwpimg:3") — never the same as <see cref="Id"/>. This is the key
    /// fastdoc_office_image_base64 accepts for a lazy fetch when BytesBase64 is null (a picture
    /// carried by reference — P2c). Null for a producer that never declared one (markdown, or a
    /// resource this document's adapter always ships eagerly).</summary>
    [JsonPropertyName("sourceKey")] public string? SourceKey { get; set; }
}

public sealed class RenderDocument
{
    [JsonPropertyName("format")]
    public string? Format { get; set; }

    [JsonPropertyName("rootNodeId")]
    public ulong RootNodeId { get; set; }

    /// <summary>The size a run that declares none actually renders at, in points — the document's
    /// own default (wire::Document.default_body_font_size). 0 means "not stated"; FlowDocumentView
    /// falls back to 12pt in that case, matching the macOS reader's own "document default, or
    /// 12pt" rule.</summary>
    [JsonPropertyName("defaultBodyFontSize")]
    public double DefaultBodyFontSize { get; set; }

    /// <summary>E2c-1: `wire::Document.documentPaper` — the document's OWN page size/margins, when
    /// it declared one. Null for markdown/plain text (no paper at all) and for an office document
    /// that never stated a page size, in which case page mode stays disabled (Paging/PageGeometry).</summary>
    [JsonPropertyName("documentPaper")]
    public PaperWire? DocumentPaper { get; set; }

    /// <summary>E2c-1: `wire::Document.lineGridPoints` — a Korean document's own line-grid pitch,
    /// when declared. Null when the document never stated one.</summary>
    [JsonPropertyName("lineGridPoints")]
    public double? LineGridPoints { get; set; }
}

/// <summary>E2c-1: `wire::Paper` — one page's size, margins, and running-band distances, in points.
/// Carried at document level (<see cref="RenderDocument.DocumentPaper"/>) and again per section
/// (<see cref="SectionPayload.Paper"/>) for a document whose sections declare their own paper.</summary>
public sealed class PaperWire
{
    [JsonPropertyName("widthPoints")] public double WidthPoints { get; set; }
    [JsonPropertyName("heightPoints")] public double HeightPoints { get; set; }
    [JsonPropertyName("margins")] public InsetsWire Margins { get; set; } = new();
    [JsonPropertyName("headerDistancePoints")] public double? HeaderDistancePoints { get; set; }
    [JsonPropertyName("footerDistancePoints")] public double? FooterDistancePoints { get; set; }
}

/// <summary>`wire::Insets` — the four page margins, in points.</summary>
public sealed class InsetsWire
{
    [JsonPropertyName("top")] public double Top { get; set; }
    [JsonPropertyName("right")] public double Right { get; set; }
    [JsonPropertyName("bottom")] public double Bottom { get; set; }
    [JsonPropertyName("left")] public double Left { get; set; }
}

/// <summary>E2c-2c: `wire::OptionalInsets` — an edge padding/margin declaration where each side may
/// be simply UNSTATED (`null`), unlike <see cref="InsetsWire"/>'s always-present page margins.
/// Used for table/cell padding (`WireTableStyle.defaultPadding`, `WireTableCell.edgePadding`).</summary>
public sealed class OptionalInsetsWire
{
    [JsonPropertyName("top")] public double? Top { get; set; }
    [JsonPropertyName("right")] public double? Right { get; set; }
    [JsonPropertyName("bottom")] public double? Bottom { get; set; }
    [JsonPropertyName("left")] public double? Left { get; set; }
}

/// <summary>E2c-1: `wire::ParagraphPagination` — the pagination flags a heading or paragraph
/// carries alongside its style. `PageBreakBefore` is what <see cref="Paging.PageGeometry"/> reads
/// to force a hard page break ahead of a block, mirroring the macOS reader's own
/// `OfficeParagraphFormat.pageBreakBefore` (CLAUDE.md / RenderTreeOfficeAdapter.swift).</summary>
public sealed class PaginationWire
{
    [JsonPropertyName("keepWithNext")] public bool KeepWithNext { get; set; }
    [JsonPropertyName("pageBreakBefore")] public bool PageBreakBefore { get; set; }
    [JsonPropertyName("hidesPageNumber")] public bool HidesPageNumber { get; set; }
    [JsonPropertyName("pageNumberRestart")] public long? PageNumberRestart { get; set; }
}

/// <summary>E2c-1: `wire::Section` — a section node's own page declaration.
/// <see cref="Paper"/> is the section's OWN paper only when <see cref="PaperIsDeclared"/> is true;
/// a section that never declared one still carries whatever the wire's own inheritance already
/// resolved (mirrors `OfficeSectionDeclaration` on the macOS side), so this host reads
/// <see cref="Paper"/> unconditionally and treats <see cref="PaperIsDeclared"/> as informational.</summary>
public sealed class SectionPayload
{
    [JsonPropertyName("paper")] public PaperWire? Paper { get; set; }
    [JsonPropertyName("paperIsDeclared")] public bool PaperIsDeclared { get; set; }
    [JsonPropertyName("lineGridIsDeclared")] public bool LineGridIsDeclared { get; set; }
    [JsonPropertyName("lineGridPoints")] public double? LineGridPoints { get; set; }
    [JsonPropertyName("hidesHeader")] public bool HidesHeader { get; set; }
    [JsonPropertyName("hidesFooter")] public bool HidesFooter { get; set; }
}

/// <summary>
/// One RenderTree node. `Type`/`Data` mirror the Rust side's `#[serde(tag = "type", content =
/// "data")]` flatten on Node.payload — so the wire JSON carries "type" and "data" as siblings of
/// id/parentId/children. `Data` is kept as a raw JsonElement (this host reads only the payload
/// shapes it names below, out of NodePayload's 27 variants) and the AsXxx getters below decode it
/// on demand into the matching typed record, keyed by `Type` so a mismatched call returns null
/// rather than throwing.
/// </summary>
public sealed class RenderNode
{
    [JsonPropertyName("id")]
    public ulong Id { get; set; }

    [JsonPropertyName("parentId")]
    public ulong? ParentId { get; set; }

    [JsonPropertyName("children")]
    public List<ulong> Children { get; set; } = new();

    [JsonPropertyName("type")]
    public string Type { get; set; } = "";

    [JsonPropertyName("data")]
    public JsonElement Data { get; set; }

    /// <summary>The node's own "text" field when its payload variant carries one (paragraph,
    /// textRun, heading, codeBlock, ...) — null for a payload shape without one (table, image, ...).</summary>
    public string? Text =>
        Data.ValueKind == JsonValueKind.Object && Data.TryGetProperty("text", out var t) &&
        t.ValueKind == JsonValueKind.String
            ? t.GetString()
            : null;

    private T? Decode<T>(string expectedType) where T : class =>
        Type == expectedType && Data.ValueKind == JsonValueKind.Object
            ? Data.Deserialize<T>()
            : null;

    public HeadingPayload? AsHeading => Decode<HeadingPayload>("heading");
    public ParagraphPayload? AsParagraph => Decode<ParagraphPayload>("paragraph");
    /// <summary>E2c-1: a "section" node's own page declaration — null for any other node type.</summary>
    public SectionPayload? AsSection => Decode<SectionPayload>("section");
    public TextRunPayload? AsTextRun => Decode<TextRunPayload>("textRun");
    public ListItemPayload? AsListItem => Decode<ListItemPayload>("listItem");
    public TaskListItemPayload? AsTaskListItem => Decode<TaskListItemPayload>("taskListItem");
    public CodeBlockPayload? AsCodeBlock => Decode<CodeBlockPayload>("codeBlock");
    public ImagePayload? AsImage => Decode<ImagePayload>("image");
    public VectorPayload? AsVector => Decode<VectorPayload>("vector");
    public TablePayload? AsTable => Decode<TablePayload>("table");
    public TableRowPayload? AsTableRow => Decode<TableRowPayload>("tableRow");
    public TableCellPayload? AsTableCell => Decode<TableCellPayload>("tableCell");
    public UnsupportedPayload? AsUnsupported => Decode<UnsupportedPayload>("unsupported");
    /// <summary>S7-G: a "footnote" node's own home — null for any other node type. See
    /// <see cref="FootnotePayload"/>'s own doc for why the body is reached through
    /// <see cref="FootnotePayload.BodyFlowId"/> rather than this node's `Children`.</summary>
    public FootnotePayload? AsFootnote => Decode<FootnotePayload>("footnote");
    public FormulaPayload? AsFormula => Decode<FormulaPayload>("formula");
    /// <summary>S8-A2 (C3): a "header" or "footer" node's own payload — the ONE
    /// `wire::HeaderFooter` struct backs both node types (`node_payloads!` in wire.rs maps
    /// `Header => "header" (HeaderFooter), Footer => "footer" (HeaderFooter)`), so this getter
    /// (unlike every other `AsXxx` above) accepts either `Type`.</summary>
    public HeaderFooterPayload? AsHeaderFooter =>
        (Type == "header" || Type == "footer") && Data.ValueKind == JsonValueKind.Object
            ? Data.Deserialize<HeaderFooterPayload>()
            : null;
}

// ---- Typed payload shapes E2a's flow layout reads. Field names/casing mirror wire.rs's
// #[serde(rename_all = "camelCase")] structs; every field that struct also carries but this
// host does not use is simply absent here (System.Text.Json ignores unknown JSON members).

public sealed class SizeWire
{
    [JsonPropertyName("width")] public double Width { get; set; }
    [JsonPropertyName("height")] public double Height { get; set; }
}

public sealed class ColorWire
{
    [JsonPropertyName("red")] public double Red { get; set; }
    [JsonPropertyName("green")] public double Green { get; set; }
    [JsonPropertyName("blue")] public double Blue { get; set; }
    [JsonPropertyName("alpha")] public double Alpha { get; set; } = 1;
}

public sealed class LineHeightWire
{
    [JsonPropertyName("value")] public double Value { get; set; }
    /// <summary>"multiple" | "exact" | "atLeast" — wire::LineHeightMode.</summary>
    [JsonPropertyName("mode")] public string Mode { get; set; } = "multiple";
}

public sealed class ParagraphStyleWire
{
    /// <summary>"natural" | "left" | "center" | "right" | "justified" — wire::Alignment.</summary>
    [JsonPropertyName("alignment")] public string? Alignment { get; set; }
    [JsonPropertyName("direction")] public string? Direction { get; set; }
    [JsonPropertyName("firstLineIndent")] public double? FirstLineIndent { get; set; }
    [JsonPropertyName("headIndent")] public double? HeadIndent { get; set; }
    [JsonPropertyName("tailIndent")] public double? TailIndent { get; set; }
    [JsonPropertyName("spacingBefore")] public double? SpacingBefore { get; set; }
    [JsonPropertyName("spacingAfter")] public double? SpacingAfter { get; set; }
    [JsonPropertyName("lineHeight")] public LineHeightWire? LineHeight { get; set; }
}

public sealed class CharacterStyleWire
{
    [JsonPropertyName("bold")] public bool Bold { get; set; }
    [JsonPropertyName("italic")] public bool Italic { get; set; }
    [JsonPropertyName("strike")] public bool Strike { get; set; }
    /// <summary>S7-G: `wire::CharacterStyle.inline_code` — verbatim/code-formatted text. Rendered
    /// as a backtick-fenced span by `MarkdownSerializer`, never mixed with bold/italic/strike.</summary>
    [JsonPropertyName("inlineCode")] public bool InlineCode { get; set; }
    [JsonPropertyName("underline")] public string? Underline { get; set; }
    [JsonPropertyName("declaredFontName")] public string? DeclaredFontName { get; set; }
    [JsonPropertyName("fontFamilies")] public List<string> FontFamilies { get; set; } = new();
    [JsonPropertyName("fontSizePoints")] public double? FontSizePoints { get; set; }
    [JsonPropertyName("foreground")] public ColorWire? Foreground { get; set; }
}

public sealed class HeadingPayload
{
    [JsonPropertyName("level")] public long Level { get; set; }
    [JsonPropertyName("style")] public ParagraphStyleWire Style { get; set; } = new();
    /// <summary>E2c-1: null for a producer that never emitted pagination (older fixtures) — treated
    /// as "no hard break, no keep-with-next" by <see cref="Paging.PageGeometry"/>.</summary>
    [JsonPropertyName("pagination")] public PaginationWire? Pagination { get; set; }
}

public sealed class ParagraphPayload
{
    [JsonPropertyName("style")] public ParagraphStyleWire Style { get; set; } = new();
    [JsonPropertyName("pagination")] public PaginationWire? Pagination { get; set; }
}

public sealed class TextRunPayload
{
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    [JsonPropertyName("style")] public CharacterStyleWire Style { get; set; } = new();
    /// <summary>S7-G: `wire::TextRun.link` — a hyperlink URL/anchor this run carries, when one was
    /// declared. `MarkdownSerializer` wraps the run's text in `[text](link)`.</summary>
    [JsonPropertyName("link")] public string? Link { get; set; }
    /// <summary>S8-B4: `wire::TextRun.comment_ids` — the tree-internal <see cref="CommentWire.Id"/>
    /// values of every review comment anchored to this run, per this file's own doc on
    /// <see cref="RenderTree"/> ("a comment anchors to a run via `TextRun.commentIds`, not by
    /// being a node itself"). Empty for a run no comment anchors to.</summary>
    [JsonPropertyName("commentIds")] public List<ulong>? CommentIds { get; set; }
    /// <summary>S7-G: `wire::TextRun.footnote_reference_number` — set only on the run that IS a
    /// footnote's in-body marker (its own glyph, e.g. a superscript digit, is dropped in favour of
    /// Markdown's own `[^n]` reference syntax — mirrors `Span.footnoteRef` in
    /// `OfficeMarkdownSerializer.swift`).</summary>
    [JsonPropertyName("footnoteReferenceNumber")] public long? FootnoteReferenceNumber { get; set; }
}

public sealed class ListItemPayload
{
    [JsonPropertyName("level")] public uint Level { get; set; }
    [JsonPropertyName("ordered")] public bool Ordered { get; set; }
    [JsonPropertyName("marker")] public string? Marker { get; set; }
    [JsonPropertyName("style")] public ParagraphStyleWire Style { get; set; } = new();
}

public sealed class TaskListItemPayload
{
    [JsonPropertyName("checked")] public bool Checked { get; set; }
    [JsonPropertyName("level")] public uint? Level { get; set; }
}

public sealed class CodeBlockPayload
{
    [JsonPropertyName("language")] public string? Language { get; set; }
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    /// <summary>S8-B3: `wire::CodeBlock.runs` — additive (`schema_version` unchanged), `null` for a
    /// fence language `CodeHighlighter::tokenize` does not recognise. Consumed by
    /// <c>FlowDocumentBuilder</c> to split the code block's `FlowRun` at token boundaries; a
    /// `null`/empty list means the block paints as one uncoloured run, same as before this field
    /// existed.</summary>
    [JsonPropertyName("runs")] public List<CodeRunPayload>? Runs { get; set; }
}

/// <summary>S8-B3: `wire::CodeRun` — `Start`/`End` are UTF-16 code-unit offsets into the owning
/// <see cref="CodeBlockPayload.Text"/>, `End` exclusive. `Role` is one of `wire::CodeRole`'s seven
/// string values (`keyword`/`type`/`string`/`number`/`comment`/`added`/`removed`); an unrecognised
/// string here is a FUTURE role this host does not know how to colour yet — ignore it rather than
/// throwing, so a wire-forward host stays forward-compatible.</summary>
public sealed class CodeRunPayload
{
    [JsonPropertyName("start")] public uint Start { get; set; }
    [JsonPropertyName("end")] public uint End { get; set; }
    [JsonPropertyName("role")] public string Role { get; set; } = "";
}

public sealed class ImagePayload
{
    [JsonPropertyName("resourceId")] public ulong? ResourceId { get; set; }
    [JsonPropertyName("intrinsicSize")] public SizeWire IntrinsicSize { get; set; } = new();
    [JsonPropertyName("displaySize")] public SizeWire? DisplaySize { get; set; }
    [JsonPropertyName("displayWidthFraction")] public double? DisplayWidthFraction { get; set; }
    [JsonPropertyName("alignment")] public string? Alignment { get; set; }
    [JsonPropertyName("altText")] public string? AltText { get; set; }
    /// <summary>S7-G: `wire::Image.source_key` — the id the DOCUMENT itself used for this picture
    /// (`"hwpimg:3"`, a docx media path) — always set by the engine's own adapter, resource-backed
    /// or not, so this is the one field that round-trips a `Resource`-backed image and a
    /// declared-without-bytes one identically. `MarkdownSerializer` uses this (never `ResourceId`,
    /// the wire's own sequential numbering) so its `![...](id)` matches
    /// `RenderTreeOfficeAdapter.swift`'s `OfficeBlock.image(id:)` byte-for-byte.</summary>
    [JsonPropertyName("sourceKey")] public string? SourceKey { get; set; }
}

public sealed class VectorPayload
{
    [JsonPropertyName("resourceId")] public ulong? ResourceId { get; set; }
    [JsonPropertyName("intrinsicSize")] public SizeWire IntrinsicSize { get; set; } = new();
    [JsonPropertyName("displaySize")] public SizeWire? DisplaySize { get; set; }
    [JsonPropertyName("alignment")] public string? Alignment { get; set; }
    /// <summary>S7-G: `wire::Vector.source_key` — see <see cref="ImagePayload.SourceKey"/>'s own
    /// doc; the same rule, the same reason.</summary>
    [JsonPropertyName("sourceKey")] public string? SourceKey { get; set; }
}

// ---- Table/border/shading wire types (E2b) — mirror wire.rs's Table/TableRow/TableCell/
// BorderSet/UniformBorder/DrawnBorder/BorderDeclaration. A border/shading is read straight off
// the cell/table that declared it; TableGridRenderer resolves cell -> table -> "no line" itself,
// the same fallback order the macOS reader's border-collapse logic uses (INVARIANTS.md 47).

/// <summary>wire::UniformBorder — the same width+color on all four edges, no per-edge override.</summary>
public sealed class UniformBorderWire
{
    [JsonPropertyName("color")] public ColorWire? Color { get; set; }
    [JsonPropertyName("widthPoints")] public double? WidthPoints { get; set; }
}

/// <summary>wire::DrawnBorder — one real edge: a width, an optional color, a line style.</summary>
public sealed class DrawnBorderWire
{
    [JsonPropertyName("widthPoints")] public double WidthPoints { get; set; }
    [JsonPropertyName("color")] public ColorWire? Color { get; set; }
    /// <summary>"solid" | "dashed" | "dotted" | "double" — wire::BorderLineStyle.</summary>
    [JsonPropertyName("style")] public string Style { get; set; } = "solid";
}

/// <summary>wire::BorderDeclaration — `{"kind":"suppressed"}` (the document SILENCED this edge,
/// told apart from never having mentioned it) or `{"kind":"drawn","value":{...}}`. `Kind` is read
/// directly rather than through a converter since the tag/content shape decodes as two plain
/// properties.</summary>
public sealed class BorderDeclarationWire
{
    [JsonPropertyName("kind")] public string Kind { get; set; } = "";
    [JsonPropertyName("value")] public DrawnBorderWire? Value { get; set; }

    public bool IsSuppressed => Kind == "suppressed";
}

/// <summary>wire::BorderSet — the six edges a table or cell can declare (four sides plus the two
/// interior rulings a table's own grid needs).</summary>
public sealed class BorderSetWire
{
    [JsonPropertyName("top")] public BorderDeclarationWire? Top { get; set; }
    [JsonPropertyName("right")] public BorderDeclarationWire? Right { get; set; }
    [JsonPropertyName("bottom")] public BorderDeclarationWire? Bottom { get; set; }
    [JsonPropertyName("left")] public BorderDeclarationWire? Left { get; set; }
    [JsonPropertyName("insideHorizontal")] public BorderDeclarationWire? InsideHorizontal { get; set; }
    [JsonPropertyName("insideVertical")] public BorderDeclarationWire? InsideVertical { get; set; }
}

public sealed class TableStyleWire
{
    [JsonPropertyName("defaultUniformBorder")] public UniformBorderWire? DefaultUniformBorder { get; set; }
    [JsonPropertyName("defaultShading")] public ColorWire? DefaultShading { get; set; }
    [JsonPropertyName("edgeBorders")] public BorderSetWire? EdgeBorders { get; set; }
    /// <summary>wire::TableStyle.pageBreakPolicy — "never" | "atRowBoundary" | "anywhere". `null`
    /// means the document never declared one; E2c-2's settle loop treats that the same as
    /// "anywhere" (no whole-table keep requested).</summary>
    [JsonPropertyName("pageBreakPolicy")] public string? PageBreakPolicy { get; set; }
    [JsonPropertyName("repeatHeaderRows")] public bool? RepeatHeaderRows { get; set; }
    /// <summary>E2c-2c: the table's own default cell padding when a cell states none of its
    /// own — `TableBlockBuilder.defaultCellPadding`'s cascade, one step up (7pt is the FLOOR
    /// past this, not carried on the wire itself — see <see cref="TableCellPayload"/>'s own doc).</summary>
    [JsonPropertyName("defaultPadding")] public OptionalInsetsWire? DefaultPadding { get; set; }
}

public sealed class TablePayload
{
    /// <summary>The document's own column-width proportions, one entry per grid column — E2b's
    /// grid distributes the reading column's width by these ratios (CLAUDE.md: "table columns
    /// that fill the width by the document's own grid proportions"), never an equal split.</summary>
    [JsonPropertyName("gridWidths")] public List<double> GridWidths { get; set; } = new();
    [JsonPropertyName("sourceColumnWidths")] public List<double> SourceColumnWidths { get; set; } = new();
    [JsonPropertyName("alignment")] public string? Alignment { get; set; }
    [JsonPropertyName("preferredWidth")] public double? PreferredWidth { get; set; }
    [JsonPropertyName("headerRows")] public uint HeaderRows { get; set; }
    [JsonPropertyName("style")] public TableStyleWire Style { get; set; } = new();
}

public sealed class TableRowPayload
{
    [JsonPropertyName("row")] public uint Row { get; set; }
    [JsonPropertyName("header")] public bool Header { get; set; }
    [JsonPropertyName("height")] public double? Height { get; set; }
}

public sealed class TableCellPayload
{
    [JsonPropertyName("row")] public uint Row { get; set; }
    [JsonPropertyName("column")] public uint Column { get; set; }
    [JsonPropertyName("rowSpan")] public uint RowSpan { get; set; } = 1;
    [JsonPropertyName("columnSpan")] public uint ColumnSpan { get; set; } = 1;
    [JsonPropertyName("directShading")] public ColorWire? DirectShading { get; set; }
    [JsonPropertyName("styleShading")] public ColorWire? StyleShading { get; set; }
    [JsonPropertyName("directUniformBorder")] public UniformBorderWire? DirectUniformBorder { get; set; }
    [JsonPropertyName("styleUniformBorder")] public UniformBorderWire? StyleUniformBorder { get; set; }
    [JsonPropertyName("directEdgeBorders")] public BorderSetWire? DirectEdgeBorders { get; set; }
    [JsonPropertyName("declaredWidthPoints")] public double? DeclaredWidthPoints { get; set; }
    [JsonPropertyName("declaredHeight")] public double? DeclaredHeight { get; set; }
    [JsonPropertyName("minimumRowHeight")] public double? MinimumRowHeight { get; set; }
    /// <summary>"top" | "middle" | "bottom" — wire::VerticalAlignment.</summary>
    [JsonPropertyName("verticalAlignment")] public string? VerticalAlignment { get; set; }
    /// <summary>E2c-2c: this cell's own padding cascade — `uniformPaddingPoints` (all four edges
    /// alike) or `edgePadding` (per edge), either possibly null on any given edge. Resolution order
    /// (mirrors `OfficeTextBuilder`'s own, `TableBlockBuilder.swift:1544`): this cell's edge value,
    /// else the table's `WireTableStyle.defaultPadding`, else the reader's own floor
    /// (`TableBlockBuilder.defaultCellPadding` = 7pt, `TableGridRenderer.DefaultCellPaddingPoints`
    /// on this host).</summary>
    [JsonPropertyName("uniformPaddingPoints")] public double? UniformPaddingPoints { get; set; }
    [JsonPropertyName("edgePadding")] public OptionalInsetsWire? EdgePadding { get; set; }
}

/// <summary>S7-G: `wire::Footnote` — a footnote is parented at its OWNING SECTION (a real
/// `RenderNode.Children` entry there, office_adapter.rs's `build_footnote_node`), which is why
/// `FlowDocumentBuilder`'s tree walk explicitly skips the "footnote" case: its content lives in a
/// different coordinate space (a page's foot band), not the in-flow column. `BodyFlowId` names the
/// "flow" node holding the actual paragraphs — also a real `Children` entry of THIS node, so a
/// walker that does recurse into a footnote reaches the same content either way; `MarkdownSerializer`
/// finds it by id instead, mirroring `OfficeMarkdownSerializer.swift`'s separate `footnotes: []`
/// parameter (footnote bodies are no longer part of the main block stream on the Swift side either,
/// invariant 98/S14).</summary>
public sealed class FootnotePayload
{
    [JsonPropertyName("number")] public ulong Number { get; set; }
    [JsonPropertyName("bodyFlowId")] public ulong BodyFlowId { get; set; }
}

/// <summary>S7-G: `wire::Formula` — a standalone equation, LaTeX source already resolved by the
/// engine's own formula reader (the same source `OfficeBlock.formula(latex)` carries on the Swift
/// side). `Block` distinguishes a display equation from an inline one; `MarkdownSerializer` treats
/// every formula node as block-level (a `$$...$$` fence), matching `OfficeMarkdownSerializer`'s own
/// `OfficeBlock.formula` case, which has no inline form either.</summary>
public sealed class FormulaPayload
{
    [JsonPropertyName("block")] public bool Block { get; set; }
    [JsonPropertyName("source")] public string Source { get; set; } = "";
}

/// <summary>S8-A2 (C3): `wire::HeaderFooter` (rust/crates/fastdoc-engine/src/render/render_tree/
/// wire.rs:938-951) — which pages a "header"/"footer" node applies to, and (HWP only) which
/// section declared it. `AppliesTo` is `wire::HeaderFooterApplicability`'s wire spelling
/// ("defaultPages" | "firstPage" | "evenPages" | "oddPages"); `Section` is `null` for "declared by
/// no section, applies to every page" (docx/odt always) or an HWP section's 0-based index.
/// `Paging.PageModePainter.HeaderFooterText` reads this to pick the right band per page instead of
/// concatenating every header/footer node in the tree onto every page (catalog findings F5/F6/
/// F8-F10).</summary>
public sealed class HeaderFooterPayload
{
    [JsonPropertyName("appliesTo")] public string AppliesTo { get; set; } = "defaultPages";
    [JsonPropertyName("section")] public long? Section { get; set; }
}

public sealed class UnsupportedPayload
{
    [JsonPropertyName("sourceFormatTag")] public string SourceFormatTag { get; set; } = "";
    [JsonPropertyName("reason")] public string Reason { get; set; } = "";
    [JsonPropertyName("preservedText")] public string? PreservedText { get; set; }
    [JsonPropertyName("intrinsicSize")] public SizeWire? IntrinsicSize { get; set; }
}
