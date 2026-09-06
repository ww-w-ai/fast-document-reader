using System;
using System.Collections.Generic;
using Avalonia.Media;
using FastDoc.Avalonia.Model;

namespace FastDoc.Avalonia.Rendering;

/// <summary>
/// Walks a RenderTree once into a flat List&lt;FlowBlock&gt; — the ONLY thing FlowDocumentView's
/// draw path reads. Splitting this out of the view keeps "what a node means" (this file) separate
/// from "how a block gets painted and virtualized" (FlowDocumentView).
///
/// Per ADR 0002, the wire carries no bounding box — this builder produces STYLED TEXT CONTENT
/// only (alignment/indent/spacing/run styles); actual line-breaking and pixel placement is
/// FlowDocumentView's job via Avalonia's own TextLayout.
///
/// Tables and images are E2b's scope; here they degrade honestly rather than crash: a table's
/// cells flow as indented text blocks in row/column order, and a picture/vector becomes a sized
/// placeholder box (Kind = Image) using its display size, falling back to its intrinsic size.
/// </summary>
public static class FlowDocumentBuilder
{
    private const double CellIndentPoints = 16;
    private const double BlockQuoteIndentPoints = 12;
    private const double ListIndentPoints = 18;

    /// <summary>How deep a table-inside-a-table-cell may recurse (E2b) before a nested table
    /// degrades to a plain placeholder line instead of building another grid — guards a malformed
    /// or pathological tree from unbounded recursion; three real levels covers every nested-table
    /// document this reader has ever needed to draw as a grid (deeper ones still show their text,
    /// just not as ruled cells).</summary>
    private const int MaxTableNestingDepth = 3;

    public static List<FlowBlock> Build(RenderTree tree)
    {
        var blocks = new List<FlowBlock>();
        if (tree.Document is null)
        {
            return blocks;
        }

        var byId = new Dictionary<ulong, RenderNode>(tree.Nodes.Count);
        foreach (var node in tree.Nodes)
        {
            byId[node.Id] = node;
        }
        if (!byId.TryGetValue(tree.Document.RootNodeId, out var root))
        {
            return blocks;
        }

        var defaultFontSize = tree.Document.DefaultBodyFontSize > 0 ? tree.Document.DefaultBodyFontSize : 12.0;
        Walk(root, byId, blocks, indent: 0, defaultFontSize, tableDepth: 0);
        return blocks;
    }

    private static void Walk(RenderNode node, Dictionary<ulong, RenderNode> byId, List<FlowBlock> blocks,
        double indent, double defaultFontSize, int tableDepth = 0)
    {
        switch (node.Type)
        {
            case "document":
            case "section":
            case "flow":
            case "list":
                WalkChildren(node, byId, blocks, indent, defaultFontSize, tableDepth);
                return;

            case "blockQuote":
                WalkChildren(node, byId, blocks, indent + BlockQuoteIndentPoints, defaultFontSize, tableDepth);
                return;

            case "heading":
            {
                var h = node.AsHeading;
                if (h is null) { return; }
                var runs = CollectRuns(node.Children, byId, HeadingFontSize(h.Level, defaultFontSize), boldDefault: true);
                blocks.Add(TextBlock(runs, h.Style, indent, defaultFontSize, node.Id));
                return;
            }

            case "paragraph":
            {
                var p = node.AsParagraph;
                if (p is null) { return; }
                var runs = CollectRuns(node.Children, byId, defaultFontSize, boldDefault: false);
                blocks.Add(TextBlock(runs, p.Style, indent, defaultFontSize, node.Id));
                return;
            }

            case "listItem":
            {
                var li = node.AsListItem;
                if (li is null) { return; }
                var runs = CollectRuns(node.Children, byId, defaultFontSize, boldDefault: false);
                var marker = li.Marker ?? (li.Ordered ? "-" : "•");
                runs.Insert(0, new FlowRun($"{marker} ", null, defaultFontSize, false, false, false, false, Colors.Black));
                blocks.Add(TextBlock(runs, li.Style, indent + ListIndentPoints * Math.Max(1, li.Level + 1), defaultFontSize, node.Id));
                return;
            }

            case "taskListItem":
            {
                var runs = CollectRuns(node.Children, byId, defaultFontSize, boldDefault: false);
                var t = node.AsTaskListItem;
                var box = t?.Checked == true ? "[x] " : "[ ] ";
                runs.Insert(0, new FlowRun(box, "monospace", defaultFontSize, false, false, false, false, Colors.Black));
                blocks.Add(new FlowBlock
                {
                    Kind = FlowBlockKind.Text,
                    Runs = runs,
                    IndentPoints = indent + ListIndentPoints,
                    SpacingAfterPoints = 2,
                    NodeId = node.Id,
                });
                return;
            }

            case "codeBlock":
            {
                var cb = node.AsCodeBlock;
                if (cb is null) { return; }
                blocks.Add(new FlowBlock
                {
                    Kind = FlowBlockKind.Text,
                    Runs = BuildCodeRuns(cb, defaultFontSize * 0.92),
                    IndentPoints = indent + 8,
                    SpacingBeforePoints = 4,
                    SpacingAfterPoints = 8,
                    NodeId = node.Id,
                });
                return;
            }

            case "table":
            {
                var t = node.AsTable;
                if (t is null)
                {
                    WalkChildren(node, byId, blocks, indent, defaultFontSize, tableDepth);
                    return;
                }
                if (tableDepth >= MaxTableNestingDepth)
                {
                    // Deeper than this reader draws as a grid — degrade to its cells' own text
                    // flow rather than crash or silently drop the content (same honest-degrade
                    // policy this builder already applies to a payload it does not recognize).
                    WalkChildren(node, byId, blocks, indent, defaultFontSize, tableDepth);
                    return;
                }
                var model = BuildTable(node, byId, t, defaultFontSize, tableDepth);
                blocks.Add(new FlowBlock
                {
                    Kind = FlowBlockKind.Table,
                    IndentPoints = indent,
                    SpacingBeforePoints = 6,
                    SpacingAfterPoints = 6,
                    Table = model,
                    NodeId = node.Id,
                });
                return;
            }

            case "tableRow":
                WalkChildren(node, byId, blocks, indent, defaultFontSize, tableDepth);
                return;

            case "tableCell":
                WalkChildren(node, byId, blocks, indent + CellIndentPoints, defaultFontSize, tableDepth);
                return;

            case "image":
            {
                var img = node.AsImage;
                if (img is null) { return; }
                var size = img.DisplaySize ?? img.IntrinsicSize;
                blocks.Add(new FlowBlock
                {
                    Kind = FlowBlockKind.Image,
                    IndentPoints = indent,
                    Alignment = AlignmentFrom(img.Alignment),
                    ImageResourceId = img.ResourceId,
                    ImageWidthPoints = size.Width,
                    ImageHeightPoints = size.Height,
                    SpacingBeforePoints = 4,
                    SpacingAfterPoints = 4,
                    NodeId = node.Id,
                });
                return;
            }

            case "vector":
            {
                var v = node.AsVector;
                if (v is null) { return; }
                var size = v.DisplaySize ?? v.IntrinsicSize;
                blocks.Add(new FlowBlock
                {
                    Kind = FlowBlockKind.Image,
                    IndentPoints = indent,
                    Alignment = AlignmentFrom(v.Alignment),
                    ImageResourceId = v.ResourceId,
                    ImageWidthPoints = size.Width,
                    ImageHeightPoints = size.Height,
                    SpacingBeforePoints = 4,
                    SpacingAfterPoints = 4,
                    NodeId = node.Id,
                });
                return;
            }

            case "unsupported":
            {
                // S8-A2 (C1): a placeholder BOX (Kind = Image, no ImageResourceId so
                // ImageBlockRenderer always falls to its placeholder rect) that reserves real
                // space via PictureGeometry — the same visual role macOS's grey `[ole]` card plays.
                // This used to emit a plain grey TEXT line with no reserved size at all, so two
                // real (but visually adjacent) unsupported objects in one document ran straight
                // into each other and read as one label printed twice (catalog finding F2).
                var u = node.AsUnsupported;
                var label = u?.PreservedText is { Length: > 0 } preserved ? preserved : (u?.Reason ?? u?.SourceFormatTag ?? "unsupported");
                var size = u?.IntrinsicSize;
                blocks.Add(new FlowBlock
                {
                    Kind = FlowBlockKind.Image,
                    IndentPoints = indent,
                    PlaceholderLabel = label,
                    ImageWidthPoints = size?.Width,
                    ImageHeightPoints = size?.Height,
                    SpacingBeforePoints = 4,
                    SpacingAfterPoints = 4,
                    NodeId = node.Id,
                });
                return;
            }

            case "thematicBreak":
                blocks.Add(new FlowBlock
                {
                    Kind = FlowBlockKind.Rule,
                    IndentPoints = indent,
                    SpacingBeforePoints = 8,
                    SpacingAfterPoints = 8,
                    NodeId = node.Id,
                });
                return;

            // Footnotes/headers/footers/master pages/anchored objects/standalone form controls are
            // laid out OFF the main flow by every real reader (this one included, on macOS) — E2a's
            // scope is the in-flow column, so these are skipped rather than guessed at. Skipping,
            // not recursing into their children, is deliberate: those children belong to a
            // different coordinate space (a footnote band, a page margin) and drawing them inline
            // would misrepresent the document, not merely omit a feature.
            case "footnote":
            case "header":
            case "footer":
            case "masterPage":
            case "masterPageObject":
            case "anchoredObject":
            case "formControl":
            case "textRun":
            case "lineBreak":
                return;

            default:
                // Unknown/future node kinds recurse into children at the same indent, so a payload
                // this host has not been taught yet still surfaces its descendants' text instead of
                // silently dropping a whole subtree.
                WalkChildren(node, byId, blocks, indent, defaultFontSize, tableDepth);
                return;
        }
    }

    private static void WalkChildren(RenderNode node, Dictionary<ulong, RenderNode> byId, List<FlowBlock> blocks,
        double indent, double defaultFontSize, int tableDepth = 0)
    {
        foreach (var childId in node.Children)
        {
            if (byId.TryGetValue(childId, out var child))
            {
                Walk(child, byId, blocks, indent, defaultFontSize, tableDepth);
            }
        }
    }

    private static FlowBlock TextBlock(List<FlowRun> runs, ParagraphStyleWire style, double indent, double defaultFontSize, ulong nodeId)
    {
        return new FlowBlock
        {
            Kind = FlowBlockKind.Text,
            Runs = runs,
            Alignment = AlignmentFrom(style.Alignment),
            IndentPoints = indent + Math.Max(0, style.HeadIndent ?? 0),
            SpacingBeforePoints = Math.Max(0, style.SpacingBefore ?? (defaultFontSize * 0.3)),
            SpacingAfterPoints = Math.Max(0, style.SpacingAfter ?? (defaultFontSize * 0.3)),
            // E2c-2b: the whole mode + value now, not just `.multiple`'s ratio (see LineHeightRule's
            // own doc) — `.exact`/`.atLeast` used to be silently dropped to 1.0 here.
            LineHeight = LineHeightRule.From(style.LineHeight),
            NodeId = nodeId,
        };
    }

    private static TextAlignment AlignmentFrom(string? wire) => wire switch
    {
        "center" => TextAlignment.Center,
        "right" => TextAlignment.Right,
        "justified" => TextAlignment.Justify,
        _ => TextAlignment.Left,
    };

    private static double HeadingFontSize(long level, double defaultFontSize) => level switch
    {
        <= 1 => defaultFontSize * 1.8,
        2 => defaultFontSize * 1.5,
        3 => defaultFontSize * 1.3,
        4 => defaultFontSize * 1.15,
        _ => defaultFontSize * 1.05,
    };

    private static List<FlowRun> CollectRuns(List<ulong> childIds, Dictionary<ulong, RenderNode> byId,
        double defaultFontSize, bool boldDefault)
    {
        var runs = new List<FlowRun>();
        foreach (var id in childIds)
        {
            if (!byId.TryGetValue(id, out var child)) { continue; }
            if (child.Type == "textRun")
            {
                var tr = child.AsTextRun;
                if (tr is null) { continue; }
                var style = tr.Style;
                var family = style.FontFamilies.Count > 0 ? style.FontFamilies[0] : style.DeclaredFontName;
                AppendTextRunSplitOnControlChars(runs, tr.Text, family,
                    style.FontSizePoints ?? defaultFontSize, style.Bold || boldDefault, style.Italic,
                    style.Underline is not null, style.Strike, ColorFrom(style.Foreground), tr.Link);
            }
            else if (child.Type == "lineBreak")
            {
                runs.Add(new FlowRun("\n", null, defaultFontSize, false, false, false, false, Colors.Black));
            }
        }
        return runs;
    }

    /// <summary>S8-A2 (C4): a docx/hwp author can embed a raw TAB (U+0009 — a table cell's own
    /// line break represented as an in-run character, or a tab-leader stop before a table-of-
    /// contents page number) or a raw LINE FEED (U+000A — measured on a docx cell's XML example
    /// text) directly INSIDE one run's text, rather than as a separate structural node the way a
    /// genuine "lineBreak" child already is (see the branch above). Avalonia's plain
    /// <see cref="Avalonia.Media.TextFormatting.TextLayout"/> has no paragraph tab-stop concept
    /// (unlike TextKit's <c>NSTextTab</c> the macOS reader draws these through — see
    /// OfficeTextBuilder.swift's <c>resolvedTabStops</c>/<c>markTabLeaders</c>), and measured on
    /// this corpus, passing either control character straight into a styled run made the font draw
    /// a `.notdef` (tofu) box for it instead of treating it as whitespace or a break — catalog
    /// finding F7 (docx).
    ///
    /// A HWP table-of-contents entry carries no embedded control character at all (confirmed
    /// against this test's own corpus, see the S8-A2 report) — its tab-leader is a real PRINTED
    /// character instead, U+2024 ONE DOT LEADER, repeated many times. The bundled Inter/Noto Sans
    /// KR fallback has no glyph for it, so the same tofu box appears — catalog finding F9.
    ///
    /// Per-code-point handling (never a blanket strip): TAB becomes a short run of ordinary spaces
    /// IN THE SAME STYLE as its surrounding text (a real tab-stop/leader-dot layout is a separate,
    /// larger feature this host does not have yet — this keeps the visible field separation an
    /// author intended instead of a lost or tofu'd character). LINE FEED becomes exactly the same
    /// default-styled break <c>FlowRun("\n", ...)</c> a genuine "lineBreak" node already produces
    /// above, so a line inside one run breaks the same way a line between two runs does. ONE DOT
    /// LEADER becomes an ordinary FULL STOP (U+002E) in the SAME style — visually the closest
    /// glyph this reader is guaranteed to have, until a real tab-leader layout exists.</summary>
    private static void AppendTextRunSplitOnControlChars(List<FlowRun> runs, string text, string? family,
        double fontSize, bool bold, bool italic, bool underline, bool strike, Color foreground, string? link = null)
    {
        // S8-B5: a run carrying a link draws underlined in the theme's link colour — otherwise a
        // link was visually indistinguishable from body text (the bug this unit was dispatched
        // for). Overridden here, once, rather than at draw time, matching this file's own existing
        // precedent for a theme-resolved run colour (see ResolveCodeRoleColor below) — neither
        // reacts to a live theme toggle without a fresh SetTree, a disclosed limitation shared by
        // both, not a new one.
        if (link is not null)
        {
            foreground = ResolveLinkColor() ?? DefaultLinkColor;
            underline = true;
        }

        var start = 0;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (c != '\t' && c != '\n' && c != '․') { continue; }
            if (i > start)
            {
                runs.Add(new FlowRun(text[start..i], family, fontSize, bold, italic, underline, strike, foreground, link));
            }
            if (c == '\t')
            {
                // A synthetic run standing in for whitespace — not part of the document's own run
                // text, so it never carries the surrounding run's link (S8-B4).
                runs.Add(new FlowRun("    ", family, fontSize, bold, italic, underline, strike, foreground));
            }
            else if (c == '․')
            {
                runs.Add(new FlowRun(".", family, fontSize, bold, italic, underline, strike, foreground));
            }
            else
            {
                runs.Add(new FlowRun("\n", null, fontSize, false, false, false, false, Colors.Black));
            }
            start = i + 1;
        }
        if (start < text.Length)
        {
            runs.Add(new FlowRun(text[start..], family, fontSize, bold, italic, underline, strike, foreground, link));
        }
        else if (text.Length == 0)
        {
            runs.Add(new FlowRun(text, family, fontSize, bold, italic, underline, strike, foreground, link));
        }
    }

    /// <summary>Builds a <see cref="TableGridModel"/> from a "table" node's tableRow/tableCell
    /// children — the fallback chain a document's cell/style/table shading and borders form is
    /// collapsed HERE (direct ?? style), once, so <see cref="TableGridRenderer"/> only ever
    /// resolves cell -&gt; table at draw time, never re-walks three wire levels per frame.</summary>
    private static TableGridModel BuildTable(RenderNode tableNode, Dictionary<ulong, RenderNode> byId,
        TablePayload t, double defaultFontSize, int tableDepth)
    {
        var rows = new List<TableGridRow>();
        var columnCount = t.GridWidths.Count;

        foreach (var rowId in tableNode.Children)
        {
            if (!byId.TryGetValue(rowId, out var rowNode) || rowNode.Type != "tableRow") { continue; }
            var rp = rowNode.AsTableRow;
            var cells = new List<TableGridCell>();

            foreach (var cellId in rowNode.Children)
            {
                if (!byId.TryGetValue(cellId, out var cellNode) || cellNode.Type != "tableCell") { continue; }
                var cp = cellNode.AsTableCell;
                if (cp is null) { continue; }

                var content = new List<FlowBlock>();
                foreach (var childId in cellNode.Children)
                {
                    if (byId.TryGetValue(childId, out var child))
                    {
                        Walk(child, byId, content, indent: 0, defaultFontSize, tableDepth + 1);
                    }
                }

                cells.Add(new TableGridCell
                {
                    Row = cp.Row,
                    Column = cp.Column,
                    RowSpan = Math.Max(1, cp.RowSpan),
                    ColumnSpan = Math.Max(1, cp.ColumnSpan),
                    Content = content,
                    EdgeBorders = cp.DirectEdgeBorders,
                    UniformBorder = cp.DirectUniformBorder ?? cp.StyleUniformBorder,
                    Shading = cp.DirectShading ?? cp.StyleShading,
                    VerticalAlignment = cp.VerticalAlignment,
                    UniformPaddingPoints = cp.UniformPaddingPoints,
                    EdgePadding = cp.EdgePadding,
                    DeclaredHeight = cp.DeclaredHeight,
                    MinimumRowHeight = cp.MinimumRowHeight,
                });

                var maxColumn = (int)(cp.Column + Math.Max(1, cp.ColumnSpan));
                if (maxColumn > columnCount) { columnCount = maxColumn; }
            }

            rows.Add(new TableGridRow
            {
                Row = rp?.Row ?? (uint)rows.Count,
                Header = rp?.Header ?? false,
                Cells = cells,
            });
        }

        return new TableGridModel
        {
            ColumnWidthRatios = t.GridWidths,
            Rows = rows,
            ColumnCount = Math.Max(1, columnCount),
            DefaultUniformBorder = t.Style.DefaultUniformBorder,
            DefaultShading = t.Style.DefaultShading,
            TableEdgeBorders = t.Style.EdgeBorders,
            DefaultPadding = t.Style.DefaultPadding,
            DefaultBodyFontSizePoints = defaultFontSize,
        };
    }

    // ---------------------------------------------------------------------------------------
    // S8-B5: link run colour (App.axaml LinkColor -> FlowRun.Foreground, when tr.Link is set)
    // ---------------------------------------------------------------------------------------

    /// <summary>Fallback for a host with no themed `Application` (a bare unit test) — the exact
    /// LIGHT value `Sources/FastDocReader/Render/RenderTheme.swift`'s `Palette.link` already ships
    /// on macOS (`NSColor(rgb: 0x2E7AB8)`), so a link reads the same blue on both hosts even before
    /// a theme resource resolves.</summary>
    private static readonly Color DefaultLinkColor = Color.FromRgb(0x2E, 0x7A, 0xB8);

    private const string LinkColorResourceKey = "LinkColor";

    /// <summary>`null` only when no themed `Application` is available at all (see
    /// <see cref="ResolveCodeRoleColor"/>'s own doc for the identical fallback policy this
    /// mirrors) — never for a missing key, since <c>App.axaml</c> always declares this one.</summary>
    private static Color? ResolveLinkColor()
    {
        var app = global::Avalonia.Application.Current;
        if (app is null) { return null; }
        return app.TryGetResource(LinkColorResourceKey, app.ActualThemeVariant, out var value) && value is Color color
            ? color
            : null;
    }

    private static Color ColorFrom(ColorWire? wire)
    {
        if (wire is null) { return Colors.Black; }
        byte Clamp(double v) => (byte)Math.Clamp(v * 255.0, 0, 255);
        return Color.FromArgb(Clamp(wire.Alpha), Clamp(wire.Red), Clamp(wire.Green), Clamp(wire.Blue));
    }

    // ---------------------------------------------------------------------------------------
    // S8-B3: code-block token colouring (wire::CodeRole -> App.axaml theme resource -> FlowRun)
    // ---------------------------------------------------------------------------------------

    // internal (not private): S9-B3 batch 6's "Copy Code" context-menu item needs the SAME literal
    // to detect a code block, rather than a second copy of this string drifting from this one.
    internal const string CodeFontFamily = "Menlo, Consolas, monospace";

    /// <summary>The colour an uncoloured span (no `CodeRun` covers it, or `cb.Runs` is null/empty)
    /// paints in — unchanged from before this field existed, and NOT theme-resolved: this app's
    /// other baked `FlowRun` colours (list markers, task-list boxes) are the same fixed literal,
    /// so making only the code block's base colour theme-aware would be an inconsistent one-off
    /// this sprint's contract does not ask for.</summary>
    private static readonly Color DefaultCodeColor = Color.FromRgb(0x33, 0x33, 0x33);

    /// <summary>`wire::CodeRole`'s seven string values -> the `App.axaml` `ThemeDictionaries` key
    /// each one reads. Kept as data rather than a switch so `ResolveCodeRoleColor`'s "unknown role"
    /// path is the ONE place that decides what happens when this table doesn't have an entry.</summary>
    private static readonly Dictionary<string, string> CodeRoleResourceKeys = new()
    {
        ["keyword"] = "CodeRoleKeywordColor",
        ["type"] = "CodeRoleTypeColor",
        ["string"] = "CodeRoleStringColor",
        ["number"] = "CodeRoleNumberColor",
        ["comment"] = "CodeRoleCommentColor",
        ["added"] = "CodeRoleAddedColor",
        ["removed"] = "CodeRoleRemovedColor",
    };

    /// <summary>Splits a code block's text into one <see cref="FlowRun"/> per token boundary
    /// `cb.Runs` declares, colouring each from the theme; text the highlighter did not cover (gaps
    /// between runs, or the whole block when `cb.Runs` is null/empty) stays <see
    /// cref="DefaultCodeColor"/>. `CodeRun.Start`/`End` are UTF-16 code-unit offsets — the SAME
    /// unit a C# `string`'s indexer already uses, so no conversion is needed before slicing.</summary>
    private static List<FlowRun> BuildCodeRuns(CodeBlockPayload cb, double fontSizePoints)
    {
        var text = cb.Text;
        var runs = new List<FlowRun>();
        if (cb.Runs is null || cb.Runs.Count == 0)
        {
            runs.Add(new FlowRun(text, CodeFontFamily, fontSizePoints, false, false, false, false, DefaultCodeColor));
            return runs;
        }

        var length = text.Length;
        var cursor = 0;
        // `code_highlighter::tokenize`'s single left-to-right scan emits runs in ascending,
        // non-overlapping order — this walk trusts that order rather than re-sorting defensively,
        // the same trust `wire.rs`'s other producer-ordered lists (e.g. `TextRun.bookmark_ids`)
        // place in their own single-pass producers.
        foreach (var token in cb.Runs)
        {
            var start = (int)Math.Min(token.Start, (uint)length);
            var end = (int)Math.Min(token.End, (uint)length);
            if (end <= start || start < cursor) { continue; }
            if (start > cursor)
            {
                runs.Add(new FlowRun(text.Substring(cursor, start - cursor), CodeFontFamily, fontSizePoints,
                    false, false, false, false, DefaultCodeColor));
            }
            var color = ResolveCodeRoleColor(token.Role) ?? DefaultCodeColor;
            runs.Add(new FlowRun(text.Substring(start, end - start), CodeFontFamily, fontSizePoints,
                false, false, false, false, color));
            cursor = end;
        }
        if (cursor < length)
        {
            runs.Add(new FlowRun(text.Substring(cursor), CodeFontFamily, fontSizePoints,
                false, false, false, false, DefaultCodeColor));
        }
        return runs;
    }

    /// <summary>`null` for a `role` this table does not recognise (a future wire value an older
    /// host has not learned to colour yet — ignored rather than thrown, same forward-compatible
    /// policy `RenderNode`'s own unknown-node-type case documents) OR when no `Application` /
    /// theme resource is available (e.g. a headless test with no `App.axaml` loaded).</summary>
    private static Color? ResolveCodeRoleColor(string role)
    {
        if (!CodeRoleResourceKeys.TryGetValue(role, out var key)) { return null; }
        var app = global::Avalonia.Application.Current;
        if (app is null) { return null; }
        return app.TryGetResource(key, app.ActualThemeVariant, out var value) && value is Color color
            ? color
            : null;
    }
}
