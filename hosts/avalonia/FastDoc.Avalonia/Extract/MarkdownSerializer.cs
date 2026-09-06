using System.Collections.Generic;
using System.Linq;
using System.Text;
using FastDoc.Avalonia.Model;

namespace FastDoc.Avalonia.Extract;

/// <summary>
/// S7-G: the host's port of `Sources/FastDocReader/Render/Office/OfficeMarkdownSerializer.swift` —
/// turns a `RenderTree` (the SAME wire the GUI's `FlowDocumentBuilder` walks, ADR 0002) into
/// GitHub-flavoured Markdown for `--extract`. Pure and view-free: `RenderTree -> string`, so it is
/// fully unit-testable with a JSON fixture and no engine dylib, exactly like
/// `RenderTreeEnvelopeTests`.
///
/// Policy, ported unchanged from the Swift original (agreed with the owner there, not re-decided
/// here): map to real Markdown ONLY when it is unambiguous — headings, paragraphs, lists, simple
/// rectangular tables, inline bold/italic/strike/code/links, standalone formulas. A table that
/// cannot be safely mapped (a merged-cell grid, block content inside a cell) is NOT turned into a
/// pipe table that would read as correct — its rows are dumped as literal text inside a
/// `&lt;raw&gt;...&lt;/raw&gt;` marker, and the CLI (`Program.cs`'s `--extract` branch) prepends a
/// one-line legend explaining the marker the same way `HeadlessExtract.header` does.
/// </summary>
public static class MarkdownSerializer
{
    public const string RawOpen = "<raw>";
    public const string RawClose = "</raw>";
    public const string RawNote = "[table — not a grid; rows below are literal text]";

    public static string Serialize(RenderTree tree)
    {
        var byId = new Dictionary<ulong, RenderNode>(tree.Nodes.Count);
        foreach (var node in tree.Nodes)
        {
            byId[node.Id] = node;
        }
        if (tree.Document is null || !byId.TryGetValue(tree.Document.RootNodeId, out var root))
        {
            return "";
        }

        var pieces = new List<(string Text, bool IsList)>();
        Walk(root, byId, pieces);
        var body = JoinPieces(pieces);

        return AppendFootnotes(body, tree, byId);
    }

    // MARK: - Footnotes

    /// <summary>Footnotes are reached by scanning every node for `type == "footnote"` rather than
    /// through the main walk, which explicitly skips them (see <see cref="Walk"/>'s `"footnote"`
    /// case) — their content belongs to a page's foot band, not the in-flow column
    /// (`FootnoteFDocumentBuilder`'s own comment on the same node type). Sorted by number so the
    /// trailing `[^n]: ...` section reads in citation order regardless of node-id order.</summary>
    private static string AppendFootnotes(string body, RenderTree tree, Dictionary<ulong, RenderNode> byId)
    {
        var footnotes = tree.Nodes
            .Select(n => n.AsFootnote)
            .Where(f => f is not null)
            .Cast<FootnotePayload>()
            .OrderBy(f => f.Number)
            .ToList();
        if (footnotes.Count == 0) { return body; }

        var sb = new StringBuilder(body);
        foreach (var note in footnotes)
        {
            if (!byId.TryGetValue(note.BodyFlowId, out var flow)) { continue; }
            var noteBlocks = new List<(string Text, bool IsList)>();
            WalkChildren(flow, byId, noteBlocks);
            var noteBody = JoinPieces(noteBlocks);
            if (noteBody.Length == 0) { continue; }
            if (sb.Length > 0) { sb.Append("\n\n"); }
            // Markdown's own footnote spelling — the body's marker (the run carrying
            // FootnoteReferenceNumber) already became "[^n]" inline via Span; this is the
            // definition that reference points at. Continuation lines are indented so multi-block
            // footnote bodies (a footnote with more than one paragraph) stay inside the note.
            sb.Append($"[^{note.Number}]: ").Append(noteBody.Replace("\n", "\n    "));
        }
        return sb.ToString();
    }

    // MARK: - Block walk

    /// <summary>Ported from `OfficeMarkdownSerializer.serialize`'s own loop, which drops a block
    /// the instant it renders empty (`guard !rendered.text.isEmpty else { continue }`) BEFORE it
    /// ever reaches the separator logic below — an empty paragraph (a blank line the source
    /// author left, or a run whose text ended up empty after escaping) must not still cost a
    /// blank-line separator. Filtering here, once, rather than at every `pieces.Add(...)` call
    /// site in <see cref="Walk"/>, keeps that call sites' loops themselves unconditional.</summary>
    private static string JoinPieces(List<(string Text, bool IsList)> rawPieces)
    {
        var pieces = rawPieces.Where(p => p.Text.Length > 0).ToList();
        var sb = new StringBuilder();
        for (var i = 0; i < pieces.Count; i++)
        {
            if (i > 0)
            {
                sb.Append(pieces[i].IsList && pieces[i - 1].IsList ? "\n" : "\n\n");
            }
            sb.Append(pieces[i].Text);
        }
        return sb.ToString();
    }

    private static void Walk(RenderNode node, Dictionary<ulong, RenderNode> byId, List<(string Text, bool IsList)> pieces)
    {
        switch (node.Type)
        {
            case "document":
            case "section":
            case "flow":
            case "list":
                WalkChildren(node, byId, pieces);
                return;

            case "blockQuote":
            {
                var sub = new List<(string Text, bool IsList)>();
                WalkChildren(node, byId, sub);
                var quoted = string.Join("\n", JoinPieces(sub).Split('\n').Select(line => "> " + line));
                pieces.Add((quoted, false));
                return;
            }

            case "heading":
            {
                var h = node.AsHeading;
                if (h is null) { return; }
                var hashes = new string('#', System.Math.Min(System.Math.Max((int)h.Level, 1), 6));
                pieces.Add(($"{hashes} {Inline(node.Children, byId, inCell: false)}", false));
                return;
            }

            case "paragraph":
            {
                var p = node.AsParagraph;
                if (p is null) { return; }
                pieces.Add((Inline(node.Children, byId, inCell: false), false));
                return;
            }

            case "listItem":
            {
                var li = node.AsListItem;
                if (li is null) { return; }
                var indent = new string(' ', 2 * (int)li.Level);
                string mark;
                if (li.Ordered)
                {
                    var m = li.Marker?.Trim();
                    mark = !string.IsNullOrEmpty(m) ? li.Marker!.TrimEnd() + " " : "1. ";
                }
                else
                {
                    mark = "- ";
                }
                pieces.Add((indent + mark + Inline(node.Children, byId, inCell: false), true));
                return;
            }

            case "taskListItem":
            {
                var t = node.AsTaskListItem;
                var indent = new string(' ', 2 * (int)(t?.Level ?? 0));
                var box = t?.Checked == true ? "[x] " : "[ ] ";
                pieces.Add((indent + "- " + box + Inline(node.Children, byId, inCell: false), true));
                return;
            }

            case "codeBlock":
            {
                var cb = node.AsCodeBlock;
                if (cb is null) { return; }
                pieces.Add(($"```{cb.Language ?? ""}\n{cb.Text}\n```", false));
                return;
            }

            case "table":
            {
                var t = node.AsTable;
                if (t is null) { WalkChildren(node, byId, pieces); return; }
                var rendered = RenderTable(node, byId);
                if (rendered.Length > 0) { pieces.Add((rendered, false)); }
                return;
            }

            case "tableRow":
            case "tableCell":
                WalkChildren(node, byId, pieces);
                return;

            // Image and vector both become the SAME OfficeBlock.image(id:) case on the macOS side
            // (RenderTreeOfficeAdapter.swift's mapVector also returns `.image(id: key, ...)`, not
            // a distinct vector block) -- literal alt text "image" always, keyed by the document's
            // OWN id (`wire::Image.source_key`/`Vector.source_key`, e.g. a docx media path or
            // "hwpimg:3"), never the wire's numeric `resourceId`.
            case "image":
            {
                var img = node.AsImage;
                if (img is null) { return; }
                pieces.Add(($"![image]({img.SourceKey ?? img.ResourceId?.ToString() ?? ""})", false));
                return;
            }

            case "vector":
            {
                var v = node.AsVector;
                if (v is null) { return; }
                pieces.Add(($"![image]({v.SourceKey ?? v.ResourceId?.ToString() ?? ""})", false));
                return;
            }

            // `OfficeMarkdownSerializer.render`'s `.unsupportedGraphic(label, _, _)` case wraps
            // ONLY `wire::Unsupported.reason` (`RenderTreeOfficeAdapter.swift`'s
            // `.unsupported(let u): return .unsupportedGraphic(label: u.reason, ...)`) -- neither
            // `sourceFormatTag` nor `preservedText` reaches this case on the macOS side, so this
            // does not fall back to either.
            case "unsupported":
            {
                var u = node.AsUnsupported;
                pieces.Add(($"*[{u?.Reason ?? "unsupported"}]*", false));
                return;
            }

            case "formula":
            {
                var f = node.AsFormula;
                if (f is null) { return; }
                pieces.Add(($"$$\n{f.Source}\n$$", false));
                return;
            }

            case "thematicBreak":
                pieces.Add(("---", false));
                return;

            // Footnotes/headers/footers/master pages/anchored objects/standalone form controls are
            // laid out OFF the main flow by every real reader (macOS included — its own serializer
            // takes `footnotes` as a SEPARATE parameter for the same reason, invariant 98). Skipping
            // rather than recursing is deliberate: their children belong to a different coordinate
            // space (a page's foot band, a margin), so drawing them inline would misrepresent the
            // document, not merely omit a feature. Mirrors `FlowDocumentBuilder.Walk`'s own list.
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
                WalkChildren(node, byId, pieces);
                return;
        }
    }

    private static void WalkChildren(RenderNode node, Dictionary<ulong, RenderNode> byId, List<(string Text, bool IsList)> pieces)
    {
        foreach (var childId in node.Children)
        {
            if (byId.TryGetValue(childId, out var child))
            {
                Walk(child, byId, pieces);
            }
        }
    }

    // MARK: - Tables

    private static List<RenderNode> ChildrenOfType(RenderNode node, Dictionary<ulong, RenderNode> byId, string type)
    {
        var result = new List<RenderNode>();
        foreach (var id in node.Children)
        {
            if (byId.TryGetValue(id, out var child) && child.Type == type) { result.Add(child); }
        }
        return result;
    }

    private static string RenderTable(RenderNode tableNode, Dictionary<ulong, RenderNode> byId)
    {
        var rowNodes = ChildrenOfType(tableNode, byId, "tableRow");
        if (rowNodes.Count == 0) { return ""; }
        return IsSimpleGrid(tableNode, byId) ? PipeTable(rowNodes, byId) : RawTable(rowNodes, byId);
    }

    /// <summary>Ported from `OfficeMarkdownSerializer.isSimpleGrid`: a grid a GFM pipe table can
    /// hold — rectangular, no merged cells (`rowSpan`/`columnSpan` both 1), and every cell's
    /// content is paragraph text or a nested table that is itself such a grid.</summary>
    private static bool IsSimpleGrid(RenderNode tableNode, Dictionary<ulong, RenderNode> byId)
    {
        var rowNodes = ChildrenOfType(tableNode, byId, "tableRow");
        if (rowNodes.Count == 0) { return false; }
        int? width = null;
        foreach (var row in rowNodes)
        {
            var cells = ChildrenOfType(row, byId, "tableCell");
            if (width is null) { width = cells.Count; }
            else if (cells.Count != width) { return false; }
            foreach (var cell in cells)
            {
                var cp = cell.AsTableCell;
                if (cp is null || cp.RowSpan != 1 || cp.ColumnSpan != 1) { return false; }
                if (!IsSimpleCellContent(cell, byId)) { return false; }
            }
        }
        return width is > 0;
    }

    private static bool IsSimpleCellContent(RenderNode cellNode, Dictionary<ulong, RenderNode> byId)
    {
        foreach (var childId in cellNode.Children)
        {
            if (!byId.TryGetValue(childId, out var child)) { continue; }
            if (child.Type == "paragraph") { continue; }
            if (child.Type == "table") { if (IsSimpleGrid(child, byId)) { continue; } return false; }
            return false;
        }
        return true;
    }

    private static string PipeTable(List<RenderNode> rowNodes, Dictionary<ulong, RenderNode> byId)
    {
        var rows = rowNodes.Select(r => ChildrenOfType(r, byId, "tableCell")).ToList();
        var width = rows[0].Count;
        string RowLine(List<RenderNode> cells) => "| " + string.Join(" | ", cells.Select(c => CellInline(c, byId))) + " |";
        var lines = new List<string>
        {
            RowLine(rows[0]),
            "| " + string.Join(" | ", System.Linq.Enumerable.Repeat("---", width)) + " |",
        };
        for (var i = 1; i < rows.Count; i++) { lines.Add(RowLine(rows[i])); }
        return string.Join("\n", lines);
    }

    /// <summary>Every paragraph of a cell on its own line (`&lt;br&gt;`, the one line break a pipe
    /// cell can carry); a nested table as its rows, each row's cells split by an escaped bar. Ported
    /// from `OfficeMarkdownSerializer.cellInline`.</summary>
    private static string CellInline(RenderNode cellNode, Dictionary<ulong, RenderNode> byId)
    {
        var parts = new List<string>();
        foreach (var childId in cellNode.Children)
        {
            if (!byId.TryGetValue(childId, out var child)) { continue; }
            if (child.Type == "paragraph")
            {
                var s = Inline(child.Children, byId, inCell: true);
                if (s.Length > 0) { parts.Add(s); }
            }
            else if (child.Type == "table")
            {
                foreach (var row in ChildrenOfType(child, byId, "tableRow"))
                {
                    var cells = ChildrenOfType(row, byId, "tableCell");
                    var line = string.Join(" \\| ", cells.Select(c => CellInline(c, byId)).Where(s => s.Length > 0));
                    if (line.Length > 0) { parts.Add(line); }
                }
            }
        }
        return string.Join("<br>", parts);
    }

    private static string RawTable(List<RenderNode> rowNodes, Dictionary<ulong, RenderNode> byId)
    {
        var lines = new List<string> { RawOpen, RawNote };
        foreach (var row in rowNodes)
        {
            var cells = ChildrenOfType(row, byId, "tableCell");
            lines.Add(string.Join(" | ", cells.Select(c => PlainCell(c, byId))));
        }
        lines.Add(RawClose);
        return string.Join("\n", lines);
    }

    private static string PlainCell(RenderNode cellNode, Dictionary<ulong, RenderNode> byId)
    {
        var parts = new List<string>();
        foreach (var childId in cellNode.Children)
        {
            if (!byId.TryGetValue(childId, out var child)) { continue; }
            var text = PlainBlock(child, byId);
            if (text.Length > 0) { parts.Add(text); }
        }
        return string.Join("<br>", parts).Replace("\n", "<br>");
    }

    /// <summary>Plain-text extraction for a `&lt;raw&gt;` dump — no Markdown delimiters, ever
    /// (mirrors `OfficeMarkdownSerializer.plainBlock`/`plainCell`).</summary>
    private static string PlainBlock(RenderNode node, Dictionary<ulong, RenderNode> byId)
    {
        switch (node.Type)
        {
            case "heading":
            case "paragraph":
            case "listItem":
            case "taskListItem":
                return PlainRuns(node.Children, byId);
            case "codeBlock":
                return node.AsCodeBlock?.Text ?? "";
            case "table":
            {
                var lines = ChildrenOfType(node, byId, "tableRow")
                    .Select(row => string.Join(" \\| ", ChildrenOfType(row, byId, "tableCell")
                        .Select(c => PlainCell(c, byId)).Where(s => s.Length > 0)))
                    .Where(s => s.Length > 0);
                return string.Join("<br>", lines);
            }
            // Same collapse as the block-level "image"/"vector"/"unsupported" cases above (see
            // their comments): vector shares image's `[image {id}]` wording on the macOS side, and
            // unsupported's raw-dump wording is `plainBlock`'s `.unsupportedGraphic` case, `reason`
            // only.
            case "image": return $"[image {node.AsImage?.SourceKey ?? node.AsImage?.ResourceId?.ToString()}]";
            case "vector": return $"[image {node.AsVector?.SourceKey ?? node.AsVector?.ResourceId?.ToString()}]";
            case "unsupported": return $"[{node.AsUnsupported?.Reason ?? "unsupported"}]";
            case "formula": return node.AsFormula?.Source ?? "";
            case "thematicBreak": return "---";
            case "blockQuote":
            case "list":
            case "flow":
            case "section":
            case "document":
            {
                var parts = node.Children
                    .Select(id => byId.TryGetValue(id, out var c) ? PlainBlock(c, byId) : "")
                    .Where(s => s.Length > 0);
                return string.Join("<br>", parts);
            }
            default:
                return "";
        }
    }

    private static string PlainRuns(List<ulong> childIds, Dictionary<ulong, RenderNode> byId)
    {
        var sb = new StringBuilder();
        foreach (var id in childIds)
        {
            if (!byId.TryGetValue(id, out var child)) { continue; }
            if (child.Type == "textRun") { sb.Append(child.AsTextRun?.Text ?? ""); }
            else if (child.Type == "lineBreak") { sb.Append(' '); }
        }
        return sb.ToString();
    }

    // MARK: - Inline spans

    private readonly record struct SpanX(string Text, bool Bold, bool Italic, bool Strike, bool Code, string? Link, long? FootnoteRef);

    private static string Inline(List<ulong> childIds, Dictionary<ulong, RenderNode> byId, bool inCell)
    {
        var sb = new StringBuilder();
        foreach (var s in Coalesced(CollectRuns(childIds, byId)))
        {
            sb.Append(Span(s, inCell));
        }
        return sb.ToString();
    }

    private static List<SpanX> CollectRuns(List<ulong> childIds, Dictionary<ulong, RenderNode> byId)
    {
        var runs = new List<SpanX>();
        foreach (var id in childIds)
        {
            if (!byId.TryGetValue(id, out var child)) { continue; }
            if (child.Type == "textRun")
            {
                var tr = child.AsTextRun;
                if (tr is null) { continue; }
                runs.Add(new SpanX(tr.Text, tr.Style.Bold, tr.Style.Italic, tr.Style.Strike, tr.Style.InlineCode,
                    tr.Link, tr.FootnoteReferenceNumber));
            }
            else if (child.Type == "lineBreak")
            {
                runs.Add(new SpanX("\n", false, false, false, false, null, null));
            }
        }
        return runs;
    }

    /// <summary>Ported from `OfficeMarkdownSerializer.coalesced`/`sameMarkdownIdentity`: merges
    /// adjacent runs that agree on every field Markdown can actually express (code/bold/italic/
    /// strike/link), undoing a read-time span split (e.g. per-script font substitution) that would
    /// otherwise close and reopen a delimiter between two pieces of one logical run. A run carrying
    /// a footnote reference is never merged into its neighbour.</summary>
    private static List<SpanX> Coalesced(List<SpanX> spans)
    {
        if (spans.Count <= 1) { return spans; }
        var outSpans = new List<SpanX>(spans.Count);
        foreach (var s in spans)
        {
            if (outSpans.Count > 0)
            {
                var last = outSpans[^1];
                if (last.FootnoteRef is null && s.FootnoteRef is null && SameMarkdownIdentity(last, s))
                {
                    outSpans[^1] = last with { Text = last.Text + s.Text };
                    continue;
                }
            }
            outSpans.Add(s);
        }
        return outSpans;
    }

    private static bool SameMarkdownIdentity(SpanX a, SpanX b) =>
        a.Code == b.Code && a.Bold == b.Bold && a.Italic == b.Italic && a.Strike == b.Strike && a.Link == b.Link;

    private static string Span(SpanX s, bool inCell)
    {
        if (s.FootnoteRef is not null) { return $"[^{s.FootnoteRef}]"; }
        if (s.Text.Length == 0) { return ""; }
        if (s.Code)
        {
            var ticks = new string('`', LongestBacktickRun(s.Text) + 1);
            var pad = (s.Text[0] == '`' || s.Text[^1] == '`') ? " " : "";
            return ticks + pad + s.Text + pad + ticks;
        }
        var t = EscapeText(s.Text, inCell);
        if (s.Strike) { t = $"~~{t}~~"; }
        if (s.Bold && s.Italic) { t = $"***{t}***"; }
        else if (s.Bold) { t = $"**{t}**"; }
        else if (s.Italic) { t = $"*{t}*"; }
        if (!string.IsNullOrWhiteSpace(s.Link)) { t = $"[{t}]({s.Link})"; }
        return t;
    }

    private static string EscapeText(string text, bool inCell)
    {
        var t = text.Replace("\n", " ");
        if (inCell) { t = t.Replace("|", "\\|"); }
        return t;
    }

    private static int LongestBacktickRun(string s)
    {
        int longest = 0, cur = 0;
        foreach (var ch in s)
        {
            if (ch == '`') { cur++; longest = System.Math.Max(longest, cur); }
            else { cur = 0; }
        }
        return longest;
    }
}
