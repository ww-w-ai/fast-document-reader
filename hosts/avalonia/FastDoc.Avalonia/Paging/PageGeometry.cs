using System;
using System.Collections.Generic;
using FastDoc.Avalonia.Model;

namespace FastDoc.Avalonia.Paging;

/// <summary>
/// E2c-1: a document's own page shape — paper size, margins, and the running-band distances it
/// declared (wire::Paper, carried at RenderDocument.DocumentPaper) — plus the per-block hard-break
/// markers PageLayout needs to decide where a page ends. Mirrors what
/// RenderTreeOfficeAdapter.swift's OfficeSectionDeclaration/pageBreakBlocks give the macOS reader,
/// read straight off the wire instead of through that (Swift-only) adapter (docs/studio/adr/
/// 0002-host-layout-interim.md: "the host has to lay the tree out itself").
///
/// A document with no declared paper (markdown, plain text, or an office document that never
/// stated one) has no PageGeometry at all — <see cref="FromDocument"/> returns null, and page mode
/// stays unavailable for it (PageViewOptions.swift's own rule: no page geometry, no page toggle).
/// </summary>
public sealed class PageGeometry
{
    public required double PageWidthPoints { get; init; }
    public required double PageHeightPoints { get; init; }
    public required double MarginTopPoints { get; init; }
    public required double MarginRightPoints { get; init; }
    public required double MarginBottomPoints { get; init; }
    public required double MarginLeftPoints { get; init; }
    public double? HeaderDistancePoints { get; init; }
    public double? FooterDistancePoints { get; init; }
    /// <summary>A Korean document's own line-grid pitch (wire::Document/Section.lineGridPoints),
    /// when declared — carried through for a future unit; this one does not yet snap lines to it.</summary>
    public double? LineGridPitchPoints { get; init; }

    public double ContentWidthPoints => Math.Max(1, PageWidthPoints - MarginLeftPoints - MarginRightPoints);
    public double ContentHeightPoints => Math.Max(1, PageHeightPoints - MarginTopPoints - MarginBottomPoints);

    /// <summary>Builds page geometry from the document's OWN declared paper: the engine's
    /// document-level paper (`wire::Document.documentPaper`), which for a multi-section Korean file is
    /// the section that holds most of the document, not its cover (invariant 73) — the same paper the
    /// macOS reader cuts every page from unless a section declared one of its own. Falls back to the
    /// first section's paper only when the document carries none. A section's own differing paper
    /// (`wire::Section.paper` with `paperIsDeclared`) is not laid out per page by this host yet.</summary>
    public static PageGeometry? FromDocument(RenderTree tree)
    {
        var paper = tree.Document?.DocumentPaper ?? FirstSectionPaper(tree);
        if (paper is null) { return null; }
        return new PageGeometry
        {
            PageWidthPoints = paper.WidthPoints,
            PageHeightPoints = paper.HeightPoints,
            MarginTopPoints = paper.Margins.Top,
            MarginRightPoints = paper.Margins.Right,
            MarginBottomPoints = paper.Margins.Bottom,
            MarginLeftPoints = paper.Margins.Left,
            HeaderDistancePoints = paper.HeaderDistancePoints,
            FooterDistancePoints = paper.FooterDistancePoints,
            LineGridPitchPoints = tree.Document?.LineGridPoints,
        };
    }

    private static PaperWire? FirstSectionPaper(RenderTree tree)
    {
        foreach (var node in tree.Nodes)
        {
            if (node.Type != "section") { continue; }
            var section = node.AsSection;
            if (section?.Paper is not null) { return section.Paper; }
        }
        return null;
    }
}

/// <summary>
/// E2c-1: per-block page markers, indexed IDENTICALLY to the FlowBlock list
/// FlowDocumentBuilder.Build(tree) returns — this file cannot call into that builder's private
/// Walk (FlowDocumentBuilder.cs is unowned by this unit, see the dispatch note), so it re-walks the
/// SAME node tree with the SAME block-emitting decisions, counting rather than building. A change
/// to which node types FlowDocumentBuilder treats as one block must be mirrored here or the two
/// index spaces drift — flagged, not silently risked, because PageLayout trusts this alignment
/// blindly.
/// </summary>
public static class BlockPageMarkers
{
    private const int MaxTableNestingDepth = 3; // must match FlowDocumentBuilder.MaxTableNestingDepth

    /// <summary>E2c-2: <see cref="TableKeepsWhole"/> is one entry per emitted block (false for
    /// every non-table block) — the document's own `wire::TableStyle.pageBreakPolicy == "never"`.
    /// E2c-2b adds <see cref="TableRepeatsHeader"/> the same way — `wire::TableStyle.
    /// repeatHeaderRows == true`. Both are read HERE rather than on <see
    /// cref="Rendering.TableGridModel"/> (which carries neither — that type lives in
    /// TableGridRenderer.cs, unowned by this unit, see the dispatch note above) so the table
    /// settle loop and PageModePainter can ask these questions without touching that file.</summary>
    /// <summary>S12-A: <see cref="NodeId"/> is the RenderNode each entry was emitted FOR —
    /// FlowDocumentBuilder already carries the same value on every <c>FlowBlock.NodeId</c>, so a
    /// test (or a future consumer) can assert POSITIONAL correspondence between the two lists
    /// directly, rather than trusting that matching COUNTS implies matching order. Added when a
    /// mutation that reversed only <see cref="AppendFootnoteMarkers"/>'s footnote sort order
    /// passed every existing test here — they compared lengths, never identities.</summary>
    /// <summary>`HidesPageNumber` / `PageNumberRestart` are per-block too (null = a producer that
    /// states none): the page a block lands on prints no master-page number / restarts the counter
    /// there — `wire::ParagraphPagination`, mirroring macOS's `hiddenPageNumberPages` and
    /// `pageNumberRestarts`.</summary>
    /// <summary>`KeepWithNext` is per-block too (null = a producer that states none): the paragraph
    /// asks to stay on the page its successor starts on, which the page plan applies.</summary>
    /// <summary>`ColumnFlow` is the multi-column declaration a block's own text runs carry (null: none
    /// begins here) — a run of blocks lasts from one declaration to the next.</summary>
    public readonly record struct Markers(
        bool[] SectionStart, bool[] PageBreakBefore, bool[] TableKeepsWhole, bool[] TableRepeatsHeader, ulong[] NodeId,
        bool[]? HidesPageNumber = null, long?[]? PageNumberRestart = null, bool[]? KeepWithNext = null,
        ColumnFlowWire?[]? ColumnFlow = null);

    /// <summary>The five parallel per-block lists <see cref="Walk"/> fills, bundled so adding a
    /// sixth marker later does not mean widening every method's parameter list again.</summary>
    private sealed class MarkerLists
    {
        public readonly List<bool> SectionStart = new();
        public readonly List<bool> PageBreakBefore = new();
        public readonly List<bool> TableKeepsWhole = new();
        public readonly List<bool> TableRepeatsHeader = new();
        public readonly List<ulong> NodeId = new();
        public readonly List<bool> HidesPageNumber = new();
        public readonly List<long?> PageNumberRestart = new();
        public readonly List<bool> KeepWithNext = new();
        public readonly List<ColumnFlowWire?> ColumnFlow = new();
        /// <summary>The declaration the NEXT emitted block carries: set where a node's own runs are
        /// read, taken (and cleared) by the first <see cref="Emit"/> after it.</summary>
        public ColumnFlowWire? PendingColumnFlow;

        public Markers ToMarkers() => new(
            SectionStart.ToArray(), PageBreakBefore.ToArray(), TableKeepsWhole.ToArray(), TableRepeatsHeader.ToArray(),
            NodeId.ToArray(), HidesPageNumber.ToArray(), PageNumberRestart.ToArray(), KeepWithNext.ToArray(),
            ColumnFlow.ToArray());
    }

    public static Markers Compute(RenderTree tree)
    {
        var empty = new Markers(
            Array.Empty<bool>(), Array.Empty<bool>(), Array.Empty<bool>(), Array.Empty<bool>(), Array.Empty<ulong>());
        if (tree.Document is null) { return empty; }

        var byId = new Dictionary<ulong, RenderNode>(tree.Nodes.Count);
        foreach (var node in tree.Nodes) { byId[node.Id] = node; }
        if (!byId.TryGetValue(tree.Document.RootNodeId, out var root)) { return empty; }

        var acc = new MarkerLists();
        // True for exactly the first block emitted after entering a "section" node — set on the
        // shared cursor, consumed (and cleared) the next time a block is actually emitted, so a
        // section with no in-flow content of its own does not spuriously flag some later sibling.
        var pendingSectionStart = false;

        // Nodes on the CURRENT root-to-here path, so a node that (through an engine parsing bug
        // or a hand-crafted document) lists an ancestor — or itself — as a child is caught as a
        // cycle instead of recursing until the process stack overflows. Removed again on the way
        // back out of Walk (post-order), so a node legitimately reachable via two different
        // siblings is still walked both times — only an actual ancestor cycle is cut.
        var visiting = new HashSet<ulong>();
        Walk(root, byId, acc, ref pendingSectionStart, tableDepth: 0, visiting);
        // S12-A: FlowDocumentBuilder.Build appends every footnote's body at the end of its block
        // list (AppendFootnotes) instead of dropping it — mirrored here with the exact same
        // selection, sort, and per-node emit count, or PageLayout's index space drifts from that
        // list (this file's own top-level doc).
        AppendFootnoteMarkers(tree, byId, acc, ref pendingSectionStart, visiting);
        return acc.ToMarkers();
    }

    private static void AppendFootnoteMarkers(RenderTree tree, Dictionary<ulong, RenderNode> byId,
        MarkerLists acc, ref bool pendingSectionStart, HashSet<ulong> visiting)
    {
        var footnotes = CollectFootnotes(tree);
        if (footnotes.Count == 0) { return; }

        // NodeId mirrors FlowDocumentBuilder.AppendFootnotes exactly: the separator Rule is
        // stamped with the document's own root id, and each label is stamped with ITS OWN
        // footnote node's id — so a test (or a future consumer) can zip FlowDocumentBuilder's
        // block list against these markers and assert positional identity, not just count.
        Emit(tree.Document!.RootNodeId, null, false, false, acc, ref pendingSectionStart);

        foreach (var (nodeId, note) in footnotes)
        {
            Emit(nodeId, null, false, false, acc, ref pendingSectionStart); // the "[n]" label block
            if (byId.TryGetValue(note.BodyFlowId, out var flow))
            {
                WalkChildren(flow, byId, acc, ref pendingSectionStart, tableDepth: 0, visiting);
            }
        }
    }

    /// <summary>Every "footnote" node in the tree (with its own node id), sorted by citation
    /// number — MUST select and sort identically to FlowDocumentBuilder.CollectFootnotes, the two
    /// files' own copy of the same rule (dispatch note above: this file cannot call into that
    /// builder's private method).</summary>
    private static List<(ulong NodeId, FootnotePayload Note)> CollectFootnotes(RenderTree tree)
    {
        var result = new List<(ulong, FootnotePayload)>();
        foreach (var node in tree.Nodes)
        {
            var note = node.AsFootnote;
            if (note is not null) { result.Add((node.Id, note)); }
        }
        result.Sort((a, b) => a.Item2.Number.CompareTo(b.Item2.Number));
        return result;
    }

    private static void Walk(RenderNode node, Dictionary<ulong, RenderNode> byId,
        MarkerLists acc, ref bool pendingSectionStart, int tableDepth, HashSet<ulong> visiting)
    {
        if (!visiting.Add(node.Id)) { return; } // cycle: node.Id is already an ancestor on this path
        try
        {
            WalkCore(node, byId, acc, ref pendingSectionStart, tableDepth, visiting);
        }
        finally
        {
            visiting.Remove(node.Id);
        }
    }

    private static void WalkCore(RenderNode node, Dictionary<ulong, RenderNode> byId,
        MarkerLists acc, ref bool pendingSectionStart, int tableDepth, HashSet<ulong> visiting)
    {
        switch (node.Type)
        {
            case "section":
                pendingSectionStart = true;
                WalkChildren(node, byId, acc, ref pendingSectionStart, tableDepth, visiting);
                return;

            case "document":
            case "flow":
            case "list":
            case "blockQuote":
            case "tableRow":
                WalkChildren(node, byId, acc, ref pendingSectionStart, tableDepth, visiting);
                return;

            case "tableCell":
                WalkChildren(node, byId, acc, ref pendingSectionStart, tableDepth, visiting);
                return;

            case "heading":
                acc.PendingColumnFlow = ColumnFlowOf(node, byId);
                Emit(node.Id, node.AsHeading?.Pagination, false, false, acc, ref pendingSectionStart);
                return;

            case "paragraph":
                acc.PendingColumnFlow = ColumnFlowOf(node, byId);
                EmitInlineContentMarkers(node, byId, node.AsParagraph?.Pagination, hasLeadingMarker: false, acc, ref pendingSectionStart);
                return;

            case "listItem":
            case "taskListItem":
                acc.PendingColumnFlow = ColumnFlowOf(node, byId);
                EmitItemMarkers(node, byId, acc, ref pendingSectionStart, tableDepth, visiting);
                return;

            case "codeBlock":
            // FlowDocumentBuilder emits one block for a formula and for a diagram (their raw
            // source); without a marker here every later block's page facts shifted one place.
            case "formula":
            case "diagram":
            case "image":
            case "vector":
            case "unsupported":
            case "formControl":
            case "thematicBreak":
                Emit(node.Id, null, false, false, acc, ref pendingSectionStart);
                return;

            case "table":
            {
                var t = node.AsTable;
                if (t is null || tableDepth >= MaxTableNestingDepth)
                {
                    WalkChildren(node, byId, acc, ref pendingSectionStart, tableDepth, visiting);
                    return;
                }
                Emit(node.Id, null, t.Style.PageBreakPolicy == "never", t.Style.RepeatHeaderRows == true,
                    acc, ref pendingSectionStart);
                // A table's rows/cells are NOT walked at the top level when it builds a grid model
                // (BuildTable in FlowDocumentBuilder walks them into the TABLE's OWN cell content
                // lists, never appending to the top-level block list) — so this mirror stops here
                // too, matching that one-block-per-table shape exactly.
                return;
            }

            // "footnote" skips here too — its body is walked separately by
            // AppendFootnoteMarkers, mirroring FlowDocumentBuilder's own AppendFootnotes (S12-A).
            case "footnote":
            case "header":
            case "footer":
            case "masterPage":
            case "masterPageObject":
            case "anchoredObject":
            case "textRun":
            case "lineBreak":
                return;

            default:
                WalkChildren(node, byId, acc, ref pendingSectionStart, tableDepth, visiting);
                return;
        }
    }

    /// <summary>The multi-column declaration one of this node's own text runs carries (the first one).</summary>
    private static ColumnFlowWire? ColumnFlowOf(RenderNode node, Dictionary<ulong, RenderNode> byId)
    {
        foreach (var childId in node.Children)
        {
            if (byId.TryGetValue(childId, out var child) && child.Type == "textRun" && child.AsTextRun?.ColumnFlow is { } flow)
            {
                return flow;
            }
        }
        return null;
    }

    private static void WalkChildren(RenderNode node, Dictionary<ulong, RenderNode> byId,
        MarkerLists acc, ref bool pendingSectionStart, int tableDepth, HashSet<ulong> visiting)
    {
        foreach (var childId in node.Children)
        {
            if (byId.TryGetValue(childId, out var child))
            {
                Walk(child, byId, acc, ref pendingSectionStart, tableDepth, visiting);
            }
        }
    }

    /// <summary>S12-img: mirrors <see cref="Rendering.FlowDocumentBuilder"/>'s
    /// <c>AppendInlineContentBlocks</c> marker-for-marker — a markdown image parses as a NODE
    /// inside its own paragraph/listItem/taskListItem's children (never as a standalone top-level
    /// "image" block), so that builder now emits 1..N sibling <c>FlowBlock</c>s from ONE such node
    /// (a text block, an image block, a text block...) instead of one. This walker must emit the
    /// exact same COUNT and ORDER of markers or <c>BlockPageMarkers</c> drifts out of positional
    /// alignment with the block list it is meant to describe (the same failure class S12-A's REVISE
    /// round caught for footnotes — see FootnoteContentLossTests' positional-alignment test). No
    /// marker content (font/text) is needed here, only the split POINTS, so this tracks "has any
    /// non-image inline content accumulated since the last flush" without materializing runs.</summary>
    private static void EmitInlineContentMarkers(RenderNode node, Dictionary<ulong, RenderNode> byId,
        PaginationWire? pagination, bool hasLeadingMarker, MarkerLists acc, ref bool pendingSectionStart)
    {
        var hasImageChild = false;
        foreach (var childId in node.Children)
        {
            if (byId.TryGetValue(childId, out var c) && c.Type == "image") { hasImageChild = true; break; }
        }
        if (!hasImageChild)
        {
            Emit(node.Id, pagination, false, false, acc, ref pendingSectionStart);
            return;
        }

        // A list item's own marker run (bullet/checkbox) counts as pending content from the start
        // (mirrors AppendInlineContentBlocks seeding `current` with leadingMarkerRuns), so an item
        // that OPENS with an image still gets a marker-only text block ahead of it, same as the
        // builder. A plain paragraph carries no such marker.
        var pendingContent = hasLeadingMarker;
        foreach (var childId in node.Children)
        {
            if (!byId.TryGetValue(childId, out var child)) { continue; }
            if (child.Type == "textRun" || child.Type == "lineBreak")
            {
                pendingContent = true;
            }
            else if (child.Type == "image")
            {
                if (pendingContent)
                {
                    Emit(node.Id, pagination, false, false, acc, ref pendingSectionStart);
                    pendingContent = false;
                }
                Emit(child.Id, null, false, false, acc, ref pendingSectionStart);
            }
        }
        if (pendingContent)
        {
            Emit(node.Id, pagination, false, false, acc, ref pendingSectionStart);
        }
    }

    /// <summary>Mirrors <c>FlowDocumentBuilder.AppendItemContent</c> marker-for-marker: the item's
    /// marker line (its own inline children, and a loose item's first paragraph) is one block, a
    /// picture splits it, and every other child is walked as a block of its own.</summary>
    private static void EmitItemMarkers(RenderNode node, Dictionary<ulong, RenderNode> byId,
        MarkerLists acc, ref bool pendingSectionStart, int tableDepth, HashSet<ulong> visiting)
    {
        var pending = true; // the marker alone is already content
        var emitted = false;
        foreach (var childId in node.Children)
        {
            if (!byId.TryGetValue(childId, out var child)) { continue; }
            switch (child.Type)
            {
                case "textRun":
                case "lineBreak":
                    pending = true;
                    break;
                case "image":
                    if (pending) { Emit(node.Id, null, false, false, acc, ref pendingSectionStart); pending = false; }
                    Emit(child.Id, null, false, false, acc, ref pendingSectionStart);
                    emitted = true;
                    break;
                case "paragraph" when !emitted:
                    foreach (var grandId in child.Children)
                    {
                        if (!byId.TryGetValue(grandId, out var grand)) { continue; }
                        if (grand.Type is "textRun" or "lineBreak") { pending = true; }
                        else if (grand.Type == "image")
                        {
                            if (pending) { Emit(node.Id, null, false, false, acc, ref pendingSectionStart); pending = false; }
                            Emit(grand.Id, null, false, false, acc, ref pendingSectionStart);
                        }
                    }
                    if (pending) { Emit(node.Id, null, false, false, acc, ref pendingSectionStart); pending = false; }
                    emitted = true;
                    break;
                default:
                    if (pending) { Emit(node.Id, null, false, false, acc, ref pendingSectionStart); pending = false; }
                    Walk(child, byId, acc, ref pendingSectionStart, tableDepth, visiting);
                    emitted = true;
                    break;
            }
        }
        if (pending) { Emit(node.Id, null, false, false, acc, ref pendingSectionStart); }
    }

    private static void Emit(ulong nodeId, PaginationWire? pagination, bool keepsWhole, bool repeatsHeader,
        MarkerLists acc, ref bool pendingSectionStart)
    {
        acc.SectionStart.Add(pendingSectionStart);
        acc.PageBreakBefore.Add(pagination?.PageBreakBefore ?? false);
        acc.TableKeepsWhole.Add(keepsWhole);
        acc.TableRepeatsHeader.Add(repeatsHeader);
        acc.NodeId.Add(nodeId);
        acc.HidesPageNumber.Add(pagination?.HidesPageNumber ?? false);
        acc.PageNumberRestart.Add(pagination?.PageNumberRestart);
        acc.KeepWithNext.Add(pagination?.KeepWithNext ?? false);
        acc.ColumnFlow.Add(acc.PendingColumnFlow);
        acc.PendingColumnFlow = null;
        pendingSectionStart = false;
    }
}
