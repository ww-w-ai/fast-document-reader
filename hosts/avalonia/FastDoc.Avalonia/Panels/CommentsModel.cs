using System.Collections.Generic;
using System.Linq;
using FastDoc.Avalonia.Model;

namespace FastDoc.Avalonia.Panels;

/// <summary>One review comment as the panel shows it — <see cref="Model.CommentWire"/>'s fields,
/// ordered for display, plus (S8-B4) the RenderTree node id a click should scroll to via
/// <c>FlowDocumentView.ScrollToNodeId</c>. Null when the comment could not be traced to any node —
/// an unanchored comment (no run declared it in `commentIds`), or one anchored to a run this
/// builder does not walk (see <see cref="BuildCommentOwnerMap"/>'s own doc); the panel still lists
/// the comment's text, it just cannot scroll to it.</summary>
public sealed record CommentEntry(long Number, string Author, string Text, string? DateIso, ulong? NodeId);

/// <summary>
/// Reads the review comments a loaded <see cref="RenderTree"/> carries — <c>wire::Annotations
/// .comments</c>, decoded by <see cref="Model.RenderTreeEnvelope"/>'s <c>AnnotationsWire</c>
/// (added in S8-B2; the envelope carried no comment data at all before that). Ordered by the
/// document's own display <see cref="CommentWire.Number"/>, the same order a native office app's
/// review pane would use — never this tree's internal <see cref="CommentWire.Id"/>, which is a
/// fresh mint with no relation to reading order.
/// </summary>
public static class CommentsModel
{
    /// <summary>The same "one node owns exactly one FlowBlock" set FlowDocumentBuilder.Walk's
    /// switch treats as block-producing — a comment anchored to a run inside one of these is
    /// reported against THAT node's id, because that id is exactly what ends up on the FlowBlock
    /// FlowDocumentView.ScrollToNodeId looks up. Kept as a literal list here (rather than imported
    /// from Rendering/) because this file is independent of Rendering/ by the same S8-B2 dispatch
    /// convention TableOfContentsModel's own doc records — duplicating a closed, rarely-changing
    /// set of node-type strings is a much smaller liability than duplicating a whole block-counting
    /// walk (which S8-B4 removed from this panel's sibling for exactly that reason).</summary>
    private static readonly HashSet<string> BlockOwnerTypes = new()
    {
        "heading", "paragraph", "listItem", "taskListItem", "codeBlock",
        "table", "image", "vector", "unsupported", "thematicBreak",
    };

    public static List<CommentEntry> Build(RenderTree tree)
    {
        var ownerByCommentId = BuildCommentOwnerMap(tree);
        return (tree.Annotations?.Comments ?? new List<CommentWire>())
            .OrderBy(c => c.Number)
            .Select(c => new CommentEntry(c.Number, c.Author, c.Text, c.DateIso,
                ownerByCommentId.TryGetValue(c.Id, out var nodeId) ? nodeId : null))
            .ToList();
    }

    /// <summary>Walks the tree once, tracking the nearest enclosing block-owner node id as it
    /// descends, and records `commentId -> that owner's id` for every id a `textRun` node's own
    /// <see cref="TextRunPayload.CommentIds"/> names — the mapping <c>wire::TextRun.comment_ids</c>
    /// exists for (this file's own doc on <see cref="RenderTree"/>: "a comment anchors to a run via
    /// TextRun.commentIds, not by being a node itself"). A comment_id with no owning run in the
    /// tree at all (or one this host does not yet decode `commentIds` for, on an older engine
    /// build) simply never appears in the returned map — <see cref="Build"/> then reports that
    /// comment's NodeId as null rather than guessing.</summary>
    private static Dictionary<ulong, ulong> BuildCommentOwnerMap(RenderTree tree)
    {
        var map = new Dictionary<ulong, ulong>();
        if (tree.Document is null) { return map; }

        var byId = new Dictionary<ulong, RenderNode>(tree.Nodes.Count);
        foreach (var node in tree.Nodes) { byId[node.Id] = node; }
        if (!byId.TryGetValue(tree.Document.RootNodeId, out var root)) { return map; }

        WalkForComments(root, byId, map, owner: null);
        return map;
    }

    private static void WalkForComments(RenderNode node, Dictionary<ulong, RenderNode> byId,
        Dictionary<ulong, ulong> map, ulong? owner)
    {
        var thisOwner = BlockOwnerTypes.Contains(node.Type) ? node.Id : owner;

        if (node.Type == "textRun")
        {
            var tr = node.AsTextRun;
            if (tr?.CommentIds is { Count: > 0 } commentIds && thisOwner is { } ownerId)
            {
                foreach (var commentId in commentIds) { map[commentId] = ownerId; }
            }
            return; // a textRun has no children of interest
        }

        foreach (var childId in node.Children)
        {
            if (byId.TryGetValue(childId, out var child)) { WalkForComments(child, byId, map, thisOwner); }
        }
    }
}
