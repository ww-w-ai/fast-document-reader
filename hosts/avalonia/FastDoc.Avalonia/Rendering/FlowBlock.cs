using System.Collections.Generic;
using System.Linq;
using Avalonia.Media;
using Avalonia.Media.Immutable;
using Avalonia.Media.TextFormatting;
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
/// <remarks>`Background` is a highlight/spoiler wash behind the run (null for none); `Script` is 1 for
/// a superscript, -1 for a subscript (the run's own <see cref="FontSizePoints"/> is already the
/// reduced size) and 0 otherwise. `PageField` is 1 for a live PAGE number placeholder, 2 for the
/// page COUNT (`wire::TextRun.pageNumberField`) — the run's own text is only the document's
/// literal value at parse time; a pinned master-page text box substitutes the real page's number
/// before drawing (<c>Paging.PinnedObjectPainter</c>).</remarks>
public sealed record FlowRun(
    string Text,
    string? FontFamily,
    double FontSizePoints,
    bool Bold,
    bool Italic,
    bool Underline,
    bool Strike,
    Color Foreground,
    string? LinkTarget = null,
    Color? Background = null,
    int Script = 0,
    int PageField = 0,
    bool Tab = false,
    double LetterSpacingPercent = 0,
    long FootnoteRef = 0,
    double LineFloorRatio = 0,
    double WidthScalePercent = 100)
{
    /// <summary>The ONE place a run becomes Avalonia text properties, for the flow view, pagination,
    /// and table cells alike. <paramref name="fontSizePx"/> is the run's size at the caller's scale.
    /// Immutable brushes, so this is safe on a background layout thread.</summary>
    internal static GenericTextRunProperties PropertiesFor(FlowRun run, double fontSizePx, IBrush foreground)
    {
        var typeface = new Typeface(
            run.FontFamily ?? "Inter",
            run.Italic ? FontStyle.Italic : FontStyle.Normal,
            run.Bold ? FontWeight.Bold : FontWeight.Normal);
        TextDecorationCollection? decorations = null;
        if (run.Underline) { decorations = TextDecorations.Underline; }
        else if (run.Strike) { decorations = TextDecorations.Strikethrough; }
        IBrush? background = run.Background is { } wash ? new ImmutableSolidColorBrush(wash) : null;
        var baseline = run.Script > 0 ? BaselineAlignment.Superscript
            : run.Script < 0 ? BaselineAlignment.Subscript
            : BaselineAlignment.Baseline;
        return new GenericTextRunProperties(typeface, fontSizePx, textDecorations: decorations,
            foregroundBrush: run.Italic ? SyntheticItalic.Mark(foreground) : foreground,
            backgroundBrush: background, baselineAlignment: baseline,
            fontFeatures: GlyphWidthScale.FeaturesFor(run.WidthScalePercent));
    }

    /// <summary>The run properties a paragraph's TextLayout takes as its DEFAULT: the larger of
    /// <paramref name="current"/> and <paramref name="candidate"/> (the earlier on a tie). Avalonia
    /// stands every line at least as tall as the default face's box at the default size, even a line
    /// no run of that face lands on, so a default the paragraph never uses — a fixed "Inter" at the
    /// document's 10 or 12pt — floored 8pt lines at 10pt Inter (16.1px against 10.7px). AppKit, the
    /// other host, measures a line from the fonts on it alone.</summary>
    internal static TextRunProperties Larger(TextRunProperties? current, TextRunProperties candidate)
        => current is null || candidate.FontRenderingEmSize > current.FontRenderingEmSize ? candidate : current;
}

/// <summary>A paragraph's border box: the rule colour and width (points) shared by every drawn
/// edge, and which of the four edges the document drew.</summary>
public sealed record ParagraphBorder(Color Color, double WidthPoints, bool Top, bool Right, bool Bottom, bool Left);

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
    /// <summary>S12-K (item 46 preflight): true ONLY for a block built from a real "codeBlock"
    /// wire node — never for a "formula"/"diagram" block, even though both borrow the same
    /// monospace <see cref="FlowDocumentBuilder.CodeFontFamily"/> styling today. Exists so a
    /// caller that needs to find "the actual fenced code blocks" (a Copy/Wrap chip overlay) does
    /// not have to sniff <c>Runs[0].FontFamily</c> the way the pre-existing <c>CodeBlockTextAt</c>
    /// hit-test did — that sniff also matches a formula/diagram block, which is a different
    /// feature with a different future (S12-F's web-render upgrade path), not a bug this flag
    /// needs to preserve compatibility with (nothing reads <c>FontFamily</c> for this purpose
    /// today; this field is additive).</summary>
    public bool IsCodeBlock { get; init; }
    /// <summary>S12-K (item 47, REVISE): the code block's own wrap INTENT — never mutates
    /// <see cref="Runs"/>' text (lead's ruling: substituting NBSP for a code block's real spaces
    /// corrupted a Copy chip's clipboard output, plain-selection copy, find, `--extract`, and
    /// `pdftotext` diffs — a document's literal bytes must stay literal). Only <c>true</c> means
    /// anything on a non-code block (default, unread there). `FlowDocumentView` — the sole owner
    /// of `TextWrapping` (this file's own header note: pixel line-breaking is its job, not this
    /// builder's) — reads this flag when constructing that block's `TextLayout` and chooses
    /// `TextWrapping.Wrap` vs `NoWrap` from it; this builder decides INTENT only, never pixels.</summary>
    public bool WrapCode { get; init; } = true;
    private List<FlowRun> _runs = new();
    public List<FlowRun> Runs { get => _runs; init => _runs = value; }
    /// <summary>Text alignment for Text blocks; doubles as the picture's paragraph alignment
    /// (left/center/right) for Image blocks — the same field, because both are "how this block
    /// sits in the column", never two spellings of one concept.</summary>
    public TextAlignment Alignment { get; init; } = TextAlignment.Left;
    public double IndentPoints { get; init; }
    /// <summary>The paragraph's declared distance from the column's right edge (`tailIndent`, the
    /// document's indent-end), in points. A table cell's lines wrap short of it, as TextKit's negative
    /// `tailIndent` makes them on macOS; body text does not read it yet.</summary>
    public double TailIndentPoints { get; init; }
    /// <summary>The bar drawn down this block's left edge when it sits inside a quote or alert (null
    /// outside one); <see cref="QuoteBarXPoints"/> is its x offset from the column's left edge.
    /// An alert's bar carries the alert kind's colour.</summary>
    public Color? QuoteBarColor { get; set; }
    public double QuoteBarXPoints { get; set; }
    /// <summary>Settable only so <see cref="FlowDocumentBuilder.Build"/> can replace a host default
    /// with the engine's paged value once the whole tree is known (see <see cref="SpacingBeforeDeclared"/>).</summary>
    public double SpacingBeforePoints { get; set; }
    public double SpacingAfterPoints { get; set; }
    /// <summary>The document itself stated this block's spacing (a paragraph's `spacingBefore` /
    /// `spacingAfter`). False means <see cref="SpacingBeforePoints"/> is this host's own default, which
    /// a paged document replaces with `wire::Document.pagedBlockSpacingPoints`.</summary>
    public bool SpacingBeforeDeclared { get; init; }
    public bool SpacingAfterDeclared { get; init; }
    /// <summary>The size an empty paragraph's line is measured at — its own runs' largest, else the
    /// document default. Read only when the block has no text to lay out.</summary>
    public double BlankLineSizePoints { get; init; } = 12;
    /// <summary>E2c-2b: the paragraph's WHOLE line-height rule (mode + value), not just a ratio —
    /// see <see cref="Rendering.LineHeightRule"/>'s own doc for why the three modes cannot be
    /// collapsed into one number.</summary>
    public LineHeightRule LineHeight { get; init; } = LineHeightRule.Default;
    /// <summary>The format puts its line spacing BELOW the glyphs (HWP, invariant 161e): the line
    /// model gives such a paragraph its rule's floor per line whatever the face's natural box.</summary>
    public bool LineSpacingBelow { get; init; }
    /// <summary>The paragraph breaks Korean by word, never between two Hangul characters while an
    /// earlier opportunity exists (`eastAsianLineBreak = word`; macOS `.hangulWordPriority`).</summary>
    public bool HangulWordBreak { get; init; }
    /// <summary>The paragraph's character size: its largest run WITH TEXT (macOS's `applyLineModel`
    /// reads the fonts of the paragraph's characters, so a text-less 24 pt run beside 12 pt text
    /// sizes nothing), else — a blank paragraph — its largest run, else the size the reader vouched
    /// for an empty paragraph: what the line model measures a below-the-glyphs gap against.</summary>
    public double CharSizePoints => Runs.Any(r => r.Text.Length > 0)
        ? Runs.Where(r => r.Text.Length > 0).Max(r => r.FontSizePoints)
        : Runs.Count > 0 ? Runs.Max(r => r.FontSizePoints) : BlankLineSizePoints;
    /// <summary>The declared faces' line floor in points (invariant 163), from each run's
    /// engine-resolved <see cref="FlowRun.LineFloorRatio"/>: the largest `size × ratio` over the
    /// runs with text, or — for a blank paragraph — of its largest run (the paragraph mark the reader
    /// vouched for). 0 when no run declares one. The line model decides where it applies.</summary>
    public double FaceFloorPoints
    {
        get
        {
            static double Floor(FlowRun r) => r.LineFloorRatio > 0 ? System.Math.Round(r.FontSizePoints * r.LineFloorRatio * 100) / 100 : 0;
            double floor = 0;
            var anyText = false;
            foreach (var r in Runs)
            {
                if (r.Text.Length == 0) { continue; }
                anyText = true;
                floor = System.Math.Max(floor, Floor(r));
            }
            if (anyText || Runs.Count == 0) { return floor; }
            FlowRun? largest = null;
            foreach (var r in Runs) { if (largest is null || r.FontSizePoints > largest.FontSizePoints) { largest = r; } }
            return Floor(largest!);
        }
    }
    /// <summary>The paragraph's background fill (office `w:shd`, HWP paragraph shading) — painted
    /// across the full column behind the block's lines, like macOS's `paraShading`.</summary>
    public Color? ShadingColor { get; init; }

    /// <summary>Non-null for a block of the footnote tail <see cref="FlowDocumentBuilder"/> appends
    /// after the body (the number of the note it belongs to; 0 for the separating rule). Flow mode
    /// shows that tail; page mode leaves it out of the flow and draws each note at the foot of the
    /// page that cites it (<c>Paging.FootnoteLayout</c>).</summary>
    public long? FootnoteOf { get; set; }

    /// <summary>The paragraph's rules, one colour and width for every drawn edge (macOS's
    /// `paraBorder*`) — null when the paragraph declares none.</summary>
    public ParagraphBorder? Border { get; init; }

    /// <summary>Where the FIRST line starts relative to the rest, in points: `firstLineIndent −
    /// hangingIndent` (macOS `firstLineHeadIndent = start + firstLine − hanging`). Negative outdents
    /// the first line — a list marker hanging out of its text — and never past the column's left edge.</summary>
    public double FirstLineOffsetPoints { get; init; }

    /// <summary>Extra advance after every character, in points at zoom 1 — the character-weighted
    /// mean of the runs' `letterSpacingPercent × font size`. Avalonia lays letter spacing out per
    /// paragraph, not per run, so a block carries ONE value (HWP states the same −5% on whole
    /// paragraphs; measured 4,908 of the 편람's runs).</summary>
    public double LetterSpacingPoints { get; init; }

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

    /// <summary>A copy of this block carrying <paramref name="runs"/> instead of its own — every
    /// other field is carried over unchanged, so a caller that substitutes text (a live page-number
    /// field) never has to know which fields exist.</summary>
    public FlowBlock WithRuns(List<FlowRun> runs)
    {
        var copy = (FlowBlock)MemberwiseClone();
        copy._runs = runs;
        return copy;
    }
}
