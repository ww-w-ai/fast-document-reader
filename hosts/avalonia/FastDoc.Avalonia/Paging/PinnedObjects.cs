using System;
using System.Collections.Generic;
using System.Linq;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Native;
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

/// <summary>Which master-page template covers which page. The rule (section first, then the page's
/// own parity, then the section's catch-all, then the section veto) is owned by the engine —
/// `fastdoc_office_master_selection`, one batched call for every page this draw pass visits. The
/// managed copy below is the SAME rule for a host whose engine library predates that export (or
/// refuses the call); `MasterPagePainter.applicablePage` on macOS is the original.</summary>
public static class MasterPageSelector
{
    public static int[] Select(IReadOnlyList<MasterTemplate> templates, ISet<int> vetoedSections,
        IReadOnlyList<(int PageIndex, int? Section)> pages)
    {
        var answers = new int[pages.Count];
        if (templates.Count == 0 || pages.Count == 0)
        {
            Array.Fill(answers, -1);
            return answers;
        }
        if (TryNative(templates, vetoedSections, pages, answers)) { return answers; }
        for (var i = 0; i < pages.Count; i++)
        {
            answers[i] = Managed(templates, vetoedSections, pages[i].PageIndex, pages[i].Section);
        }
        return answers;
    }

    private static bool TryNative(IReadOnlyList<MasterTemplate> templates, ISet<int> vetoedSections,
        IReadOnlyList<(int PageIndex, int? Section)> pages, int[] answers)
    {
        try
        {
            var descs = templates.Select(t => new FastdocEngine.FastdocMasterTemplateDesc
            {
                Section = t.Section,
                AppliesTo = t.AppliesTo switch { "firstPage" => 1, "evenPages" => 2, "oddPages" => 3, _ => 0 },
            }).ToArray();
            var vetoed = vetoedSections.Select(s => (long)s).ToArray();
            var queries = pages.Select(p => new FastdocEngine.FastdocMasterPageQuery
            {
                PageIndex = p.PageIndex,
                HasSection = p.Section.HasValue,
                Section = p.Section ?? 0,
            }).ToArray();
            var outIndex = new long[pages.Count];
            if (!FastdocEngine.fastdoc_office_master_selection(descs, (nuint)descs.Length, vetoed, (nuint)vetoed.Length,
                    queries, (nuint)queries.Length, outIndex, (nuint)outIndex.Length))
            {
                return false;
            }
            for (var i = 0; i < answers.Length; i++) { answers[i] = (int)outIndex[i]; }
            return true;
        }
        catch (Exception e) when (e is EntryPointNotFoundException or DllNotFoundException or BadImageFormatException
            or InvalidOperationException)
        {
            return false;
        }
    }

    /// <summary>The same selection in managed code — see the class doc.</summary>
    internal static int Managed(IReadOnlyList<MasterTemplate> templates, ISet<int> vetoedSections, int pageIndex,
        int? section)
    {
        if (section is { } s && vetoedSections.Contains(s)) { return -1; }
        var candidates = new List<int>();
        for (var i = 0; i < templates.Count; i++)
        {
            if (section is null || templates[i].Section == section) { candidates.Add(i); }
        }
        if (candidates.Count == 0) { return -1; }
        // An evenPages template covers the even PAGE NUMBERS (page index 1, 3, ...), oddPages the odd.
        var parity = (pageIndex + 1) % 2 == 0 ? "evenPages" : "oddPages";
        foreach (var i in candidates) { if (templates[i].AppliesTo == parity) { return i; } }
        foreach (var i in candidates) { if (templates[i].AppliesTo == "defaultPages") { return i; } }
        return candidates[0];
    }
}

/// <summary>The page-number facts a document states per paragraph, resolved to PAGES: which pages
/// print no master-page number (HWP 쪽 감추기) and where the counter restarts (HWP 새 번호). The
/// same arithmetic macOS's `hiddenPageNumberPages` / `pageNumberRestarts` / `displayedPageNumber`
/// run, read from where the marked block's FIRST line landed.</summary>
public sealed class PageNumberFacts
{
    private readonly HashSet<int> _hidden;
    private readonly SortedDictionary<int, int> _restarts;

    private PageNumberFacts(HashSet<int> hidden, SortedDictionary<int, int> restarts)
    {
        _hidden = hidden;
        _restarts = restarts;
    }

    public static readonly PageNumberFacts None = new(new HashSet<int>(), new SortedDictionary<int, int>());

    public static PageNumberFacts From(PageLayoutResult layout, BlockPageMarkers.Markers markers)
    {
        var hides = markers.HidesPageNumber;
        var restarts = markers.PageNumberRestart;
        if ((hides is null || !hides.Contains(true)) && (restarts is null || !restarts.Any(r => r.HasValue)))
        {
            return None;
        }
        var firstPage = new Dictionary<int, int>();
        foreach (var line in layout.Lines) { firstPage.TryAdd(line.BlockIndex, line.PageIndex); }
        foreach (var placement in layout.Placements) { firstPage.TryAdd(placement.BlockIndex, placement.PageIndex); }

        var hidden = new HashSet<int>();
        var restartPages = new SortedDictionary<int, int>();
        foreach (var (block, page) in firstPage)
        {
            if (hides is not null && block < hides.Length && hides[block]) { hidden.Add(page); }
            // The FIRST restart on a page wins — two markers on one sheet must not depend on order.
            if (restarts is not null && block < restarts.Length && restarts[block] is { } start
                && !restartPages.ContainsKey(page))
            {
                restartPages[page] = (int)start;
            }
        }
        return new PageNumberFacts(hidden, restartPages);
    }

    /// <summary>The page vetoes its master-page number.</summary>
    public bool Hides(int pageIndex) => _hidden.Contains(pageIndex);

    /// <summary>The number page <paramref name="pageIndex"/> (0-based) SHOWS: its distance from the
    /// most recent restart at or before it, or <c>pageIndex + 1</c> before any restart — a document
    /// that renumbers its body does not renumber its front matter backwards.</summary>
    public int Displayed(int pageIndex)
    {
        var anchor = -1;
        foreach (var key in _restarts.Keys)
        {
            if (key <= pageIndex) { anchor = key; } else { break; }
        }
        return anchor < 0 ? pageIndex + 1 : _restarts[anchor] + (pageIndex - anchor);
    }
}
