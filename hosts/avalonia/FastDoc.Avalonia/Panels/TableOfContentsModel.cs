using System.Collections.Generic;
using System.Text;
using FastDoc.Avalonia.Model;

namespace FastDoc.Avalonia.Panels;

/// <summary>One heading in the table of contents: its level (1 = top), its text, and the RenderTree
/// node id a click should scroll to (via <c>FlowDocumentView.ScrollToNodeId</c>, which resolves it
/// to whichever <see cref="Rendering.FlowBlock"/> shares that <see cref="Rendering.FlowBlock.NodeId"/>).</summary>
public sealed record TocEntry(int Level, string Text, ulong NodeId);

/// <summary>
/// Builds a flat table of contents directly from the loaded <see cref="RenderTree"/> — independent
/// of <c>Rendering/FlowDocumentBuilder.cs</c>, which another worker owns for the S8-B2 sprint this
/// panel was built in.
///
/// S8-B4: this used to duplicate FlowDocumentBuilder.Walk's own block-counting switch (which node
/// types are transparent containers, which contribute exactly one block, which are skipped) purely
/// to compute a heading's target flow-block INDEX — see this file's git history for that version.
/// Now that <see cref="Rendering.FlowBlock"/> carries its own source <see
/// cref="Rendering.FlowBlock.NodeId"/>, a heading only needs to report the id of the NODE it came
/// from; <c>FlowDocumentView.ScrollToNodeId</c> does the id-&gt;block-index lookup once, at scroll
/// time, against the SAME block list FlowDocumentBuilder actually built — so the two walks can
/// never drift apart the way the duplicated switch used to risk.
/// </summary>
public static class TableOfContentsModel
{
    /// <summary>Node types this walk does not recurse into at all — the same "laid out off the
    /// main flow" set FlowDocumentBuilder.Walk skips (a heading could not legitimately live inside
    /// one of these anyway), kept here only to avoid a wasted descent.</summary>
    private static readonly HashSet<string> SkippedTypes = new()
    {
        "footnote", "header", "footer", "masterPage", "masterPageObject",
        "anchoredObject", "formControl", "textRun", "lineBreak",
    };

    public static List<TocEntry> Build(RenderTree tree)
    {
        var entries = new List<TocEntry>();
        if (tree.Document is null) { return entries; }

        var byId = new Dictionary<ulong, RenderNode>(tree.Nodes.Count);
        foreach (var node in tree.Nodes) { byId[node.Id] = node; }
        if (!byId.TryGetValue(tree.Document.RootNodeId, out var root)) { return entries; }

        Walk(root, byId, entries);
        return entries;
    }

    private static void Walk(RenderNode node, Dictionary<ulong, RenderNode> byId, List<TocEntry> entries)
    {
        if (SkippedTypes.Contains(node.Type)) { return; }

        if (node.Type == "heading")
        {
            var h = node.AsHeading;
            if (h is null) { return; } // matches FlowDocumentBuilder: no block added either
            var text = CollectText(node, byId).Trim();
            if (text.Length > 0) { entries.Add(new TocEntry((int)h.Level, text, node.Id)); }
            return; // a heading's own children are its textRuns — nothing further to recurse into
        }

        WalkChildren(node, byId, entries);
    }

    private static void WalkChildren(RenderNode node, Dictionary<ulong, RenderNode> byId, List<TocEntry> entries)
    {
        foreach (var childId in node.Children)
        {
            if (byId.TryGetValue(childId, out var child)) { Walk(child, byId, entries); }
        }
    }

    private static string CollectText(RenderNode node, Dictionary<ulong, RenderNode> byId)
    {
        var sb = new StringBuilder();
        if (node.Text is { } t) { sb.Append(t); }
        foreach (var childId in node.Children)
        {
            if (byId.TryGetValue(childId, out var child)) { sb.Append(CollectText(child, byId)); }
        }
        return sb.ToString();
    }
}
