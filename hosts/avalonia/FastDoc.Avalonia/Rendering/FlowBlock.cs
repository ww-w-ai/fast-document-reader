using System.Collections.Generic;
using Avalonia.Media;
using FastDoc.Avalonia.Model;

namespace FastDoc.Avalonia.Rendering;

/// <summary>E2c-2b: a paragraph's line-height rule, carried WHOLE from `wire::LineHeightMode`
/// rather than collapsed into one ratio — the three modes apply to a line's own measured height
/// differently (mirrors `OfficeTextBuilder.applyParagraphFormat`, macOS): `Multiple` SCALES it
/// (`naturalHeight * Value`, a floor never a cap); `Exact` REPLACES it (`Value` points, fixed,
/// regardless of what the line actually measured); `AtLeast` FLOORS it (`Max(naturalHeight,
/// Value)`, in points — never a cap either). `Value` is in POINTS for `Exact`/`AtLeast`, a
/// unitless RATIO for `Multiple`.</summary>
public enum LineHeightMode { Multiple, Exact, AtLeast }

public readonly record struct LineHeightRule(LineHeightMode Mode, double Value)
{
    public static readonly LineHeightRule Default = new(LineHeightMode.Multiple, 1.0);

    public static LineHeightRule From(Model.LineHeightWire? wire)
    {
        if (wire is null || wire.Value <= 0) { return Default; }
        var mode = wire.Mode switch
        {
            "exact" => LineHeightMode.Exact,
            "atLeast" => LineHeightMode.AtLeast,
            _ => LineHeightMode.Multiple,
        };
        return new LineHeightRule(mode, wire.Value);
    }

    /// <summary>Applies this rule to one line's own measured (natural) height, in the SAME unit
    /// <paramref name="naturalHeight"/> is given in (points for pagination, pixels for drawing —
    /// the caller decides, this method is unit-agnostic as long as `Exact`/`AtLeast`'s own `Value`
    /// was already converted to match, e.g. via <see cref="ScaledBy"/>).</summary>
    public double Apply(double naturalHeight) => Mode switch
    {
        LineHeightMode.Exact => Value,
        LineHeightMode.AtLeast => System.Math.Max(naturalHeight, Value),
        _ => naturalHeight * (Value > 0 ? Value : 1.0),
    };

    /// <summary>Converts a POINT-valued `Exact`/`AtLeast` into another linear unit (e.g. pixels, by
    /// `factor = 96/72 * zoom`) — `Multiple`'s own `Value` is a unitless ratio and is never scaled.</summary>
    public LineHeightRule ScaledBy(double factor) =>
        Mode == LineHeightMode.Multiple ? this : new LineHeightRule(Mode, Value * factor);
}

/// <summary>One character run inside a FlowBlock — the smallest style-uniform slice of text a
/// paragraph carries (wire::TextRun's C# projection, ADR-0002 flow layer). A run's font/size/
/// color/decoration are resolved ONCE here, at tree-walk time, so FlowDocumentView's draw path
/// only ever reads plain values, never re-derives them from the wire per frame.</summary>
/// <summary>S8-B4 (D2-c): `LinkTarget` is `wire::TextRun.link` carried through unchanged — either
/// an external URL/mailto (contains a scheme, e.g. "https://" or "mailto:") or an internal
/// anchor name a document's own bookmark declares (resolved against
/// <see cref="Model.AnnotationsWire"/>'s bookmarks by <see cref="FlowDocumentView"/>, never here —
/// this record stays a plain wire mirror, per this file's own top-level doc). Null for a run no
/// link covers, the overwhelming majority. Trailing/optional so every pre-S8-B4 positional
/// constructor call keeps compiling unchanged.</summary>
public sealed record FlowRun(
    string Text,
    string? FontFamily,
    double FontSizePoints,
    bool Bold,
    bool Italic,
    bool Underline,
    bool Strike,
    Color Foreground,
    string? LinkTarget = null);

/// <summary>What kind of thing a FlowBlock draws. List items stay indented-paragraph text; tables
/// (E2b) get real grid geometry via <see cref="TableGridRenderer"/>, and pictures (E2b) decode to
/// a real bitmap via <see cref="ImageBlockRenderer"/> — a decode failure degrades to the same
/// placeholder box this Kind drew before E2b, never a crash.</summary>
public enum FlowBlockKind
{
    Text,
    Image,
    Rule,
    Table,
}

/// <summary>One vertically-stacked unit of the flow — a paragraph/heading/list item/code block
/// (Text), a picture (Image), a table (Table, E2b — see <see cref="TableGridModel"/>), or a
/// thematic break (Rule). FlowDocumentView never inspects the RenderTree again once this list
/// exists — every value a draw needs already lives on the block, its runs, or its Table model.</summary>
public sealed class FlowBlock
{
    public required FlowBlockKind Kind { get; init; }
    /// <summary>S8-B4: the RenderTree node this block was built FROM (`RenderNode.Id` — the wire
    /// already gives every node one, so no pre-order-index fallback was needed). Lets a panel
    /// (table of contents, comments) that only knows a NODE resolve to the block a click should
    /// scroll to, via <see cref="FlowDocumentView.ScrollToNodeId"/>, without re-deriving
    /// FlowDocumentBuilder's own block-counting rules (the duplication <see
    /// cref="Panels.TableOfContentsModel"/> used to carry until this field existed). Null only for
    /// a block this builder could not trace to one node (there are none today — every block-adding
    /// switch arm below sets it from the node it is handling).</summary>
    public ulong? NodeId { get; init; }
    public List<FlowRun> Runs { get; init; } = new();
    /// <summary>Text alignment for Text blocks; doubles as the picture's paragraph alignment
    /// (left/center/right) for Image blocks — the same field, because both are "how this block
    /// sits in the column", never two spellings of one concept.</summary>
    public TextAlignment Alignment { get; init; } = TextAlignment.Left;
    public double IndentPoints { get; init; }
    public double SpacingBeforePoints { get; init; }
    public double SpacingAfterPoints { get; init; }
    /// <summary>E2c-2b: the paragraph's WHOLE line-height rule (mode + value), not just a ratio —
    /// see <see cref="Rendering.LineHeightRule"/>'s own doc for why the three modes cannot be
    /// collapsed into one number.</summary>
    public LineHeightRule LineHeight { get; init; } = LineHeightRule.Default;
    public double? ImageWidthPoints { get; init; }
    public double? ImageHeightPoints { get; init; }
    /// <summary>The wire resource this Image block's bytes live in — null when the document
    /// declared no resource (an external link, or bytes this tree did not carry), in which case
    /// ImageBlockRenderer draws the same placeholder box FlowDocumentView drew before E2b.</summary>
    public ulong? ImageResourceId { get; init; }
    /// <summary>S8-A2 (C1): non-null only for an Image block built from an "unsupported" node (an
    /// OLE object, a chart/SmartArt this reader has no picture fallback for) — <see
    /// cref="ImageBlockRenderer"/> draws it centered inside the placeholder box a missing
    /// ImageResourceId already produces, mirroring macOS's `drawPlaceholderCard`. Null for a real
    /// Image/Vector node, which never shows a label even when its bitmap fails to decode.</summary>
    public string? PlaceholderLabel { get; init; }
    /// <summary>Non-null only for Kind == Table — the resolved grid TableGridRenderer draws.</summary>
    public TableGridModel? Table { get; init; }
}
