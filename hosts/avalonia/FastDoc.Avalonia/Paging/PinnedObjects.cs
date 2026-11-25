using System;
using System.Collections.Generic;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Paging;

/// <summary>What a pinned object draws: a picture (by the tree's resource id), a vector drawing
/// (the engine's already-flattened paths, in points inside the object's own box) or a text box
/// (blocks built by the SAME walk the body uses).</summary>
public abstract record PinnedContent;

public sealed record PinnedImage(ulong ResourceId) : PinnedContent;

public sealed record PinnedVector(IReadOnlyList<VectorPathWire> Paths, double Width, double Height) : PinnedContent;

public sealed record PinnedText(IReadOnlyList<FlowBlock> Blocks) : PinnedContent;

/// <summary>One object the document pins to the sheet — an anchored seal / stamp / text box /
/// floating picture, or an object of a master page. <see cref="X"/>/<see cref="Width"/>/
/// <see cref="Height"/> are final paper points; <see cref="Y"/> is final too unless
/// <see cref="Anchor"/> is set, in which case it is a placeholder and the vertical rule is
/// completed from the anchoring line (invariant 81 — nothing about it is ever stored).
/// <see cref="AnchorBlockIndex"/> is the flow block the object travels with (-1 for a master-page
/// object, which belongs to the sheet rather than to a place in the text).</summary>
public sealed record PinnedObject(double X, double Y, double Width, double Height, PinnedContent Content,
    ParagraphAnchorWire? Anchor, int AnchorBlockIndex);

/// <summary>One 바탕쪽 template a section declares — <see cref="Section"/> is the section node's
/// position among the document's sections, <see cref="AppliesTo"/> the wire's applicability.</summary>
public sealed record MasterTemplate(int Section, string AppliesTo, IReadOnlyList<PinnedObject> Objects);

/// <summary>Everything the page painter pins to a sheet, read off the tree ONCE per document:
/// the anchored objects (drawn on the page their carrier paragraph lands on), the master-page
/// templates, and the sections that veto their own master page. Rust decides every FACT here
/// (frames, anchors, applicability, vetoes); the host only places them on the sheets it painted.</summary>
public sealed class PinnedObjectSet
{
    public static readonly PinnedObjectSet Empty = new(new List<PinnedObject>(), new List<MasterTemplate>(), new HashSet<int>());

    public PinnedObjectSet(IReadOnlyList<PinnedObject> anchored, IReadOnlyList<MasterTemplate> masters,
        ISet<int> sectionsHidingMasterPage)
    {
        Anchored = anchored;
        Masters = masters;
        SectionsHidingMasterPage = sectionsHidingMasterPage;
    }

    public IReadOnlyList<PinnedObject> Anchored { get; }
    public IReadOnlyList<MasterTemplate> Masters { get; }
    public ISet<int> SectionsHidingMasterPage { get; }

    public bool IsEmpty => Anchored.Count == 0 && Masters.Count == 0;

    /// <summary>Reads the tree's section children: every "anchoredObject" / "masterPage" node, with
    /// its content node resolved. <paramref name="blocks"/> is the flow list
    /// <see cref="FlowDocumentBuilder.Build"/> produced for the SAME tree — an anchored object finds
    /// its carrier by node id (climbing to the enclosing block when the carrier sits inside a table
    /// cell), so it lands on the page its carrier does.</summary>
    public static PinnedObjectSet Build(RenderTree tree, IReadOnlyList<FlowBlock> blocks)
    {
        if (tree.Document is null) { return Empty; }
        var byId = new Dictionary<ulong, RenderNode>(tree.Nodes.Count);
        foreach (var node in tree.Nodes) { byId[node.Id] = node; }
        if (!byId.TryGetValue(tree.Document.RootNodeId, out var root)) { return Empty; }

        var blockOfNode = new Dictionary<ulong, int>();
        for (var i = 0; i < blocks.Count; i++)
        {
            if (blocks[i].NodeId is { } id) { blockOfNode.TryAdd(id, i); }
        }

        var anchored = new List<PinnedObject>();
        var masters = new List<MasterTemplate>();
        var vetoed = new HashSet<int>();

        var sectionIndex = -1;
        foreach (var sectionId in root.Children)
        {
            if (!byId.TryGetValue(sectionId, out var sectionNode) || sectionNode.Type != "section") { continue; }
            sectionIndex++;
            if (sectionNode.AsSection is { HidesMasterPage: true }) { vetoed.Add(sectionIndex); }

            foreach (var childId in sectionNode.Children)
            {
                if (!byId.TryGetValue(childId, out var child)) { continue; }
                switch (child.Type)
                {
                    case "anchoredObject":
                    {
                        var ao = child.AsAnchoredObject;
                        if (ao is null) { break; }
                        var content = ContentOf(tree, byId, ao.ContentId);
                        if (content is null) { break; }
                        var block = BlockOf(ao.AnchoredToId, byId, blockOfNode);
                        if (block < 0) { break; }
                        anchored.Add(new PinnedObject(ao.X, ao.Y ?? 0, ao.Width, ao.Height, content,
                            ao.ParagraphAnchor, block));
                        break;
                    }
                    case "masterPage":
                    {
                        var mp = child.AsMasterPage;
                        if (mp is null) { break; }
                        var objects = new List<PinnedObject>();
                        foreach (var objectId in mp.ObjectIds)
                        {
                            if (!byId.TryGetValue(objectId, out var objectNode)) { continue; }
                            var mo = objectNode.AsMasterPageObject;
                            if (mo is null) { continue; }
                            var content = ContentOf(tree, byId, mo.ContentId);
                            if (content is null) { continue; }
                            objects.Add(new PinnedObject(mo.X, mo.Y, mo.Width, mo.Height, content, null, -1));
                        }
                        masters.Add(new MasterTemplate(sectionIndex, mp.AppliesTo, objects));
                        break;
                    }
                }
            }
        }
        return anchored.Count == 0 && masters.Count == 0 && vetoed.Count == 0
            ? Empty
            : new PinnedObjectSet(anchored, masters, vetoed);
    }

    private static int BlockOf(ulong nodeId, Dictionary<ulong, RenderNode> byId, Dictionary<ulong, int> blockOfNode)
    {
        // The carrier is a top-level block, or sits inside a table cell / list item — climb to the
        // nearest ancestor that IS a block, with a bound so a malformed parent loop cannot spin.
        ulong? current = nodeId;
        for (var hops = 0; current is { } id && hops < 64; hops++)
        {
            if (blockOfNode.TryGetValue(id, out var index)) { return index; }
            current = byId.TryGetValue(id, out var node) ? node.ParentId : null;
        }
        return -1;
    }

    private static PinnedContent? ContentOf(RenderTree tree, Dictionary<ulong, RenderNode> byId, ulong contentId)
    {
        if (!byId.TryGetValue(contentId, out var node)) { return null; }
        switch (node.Type)
        {
            case "image":
                return node.AsImage is { ResourceId: { } resource } ? new PinnedImage(resource) : null;
            case "vector":
            {
                var v = node.AsVector;
                if (v is null || v.Paths.Count == 0) { return null; }
                return new PinnedVector(v.Paths, v.IntrinsicSize.Width, v.IntrinsicSize.Height);
            }
            case "flow":
            {
                var blocks = FlowDocumentBuilder.BuildFlowBlocks(tree, byId, node);
                return blocks.Count == 0 ? null : new PinnedText(blocks);
            }
            default:
                return null;
        }
    }
}
