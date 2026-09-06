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

    /// <summary>Builds page geometry from the document's OWN declared paper — the first section's
    /// paper when present (mirroring the reader's own "a page takes its own section's" rule,
    /// invariant 78) falling back to the document-level paper wire.SectionPayload carries a
    /// per-section override; this unit reads only the FIRST section's declaration (or the
    /// document's own) since multi-section paper changes mid-document are E2c's own later scope —
    /// disclosed here rather than silently ignored.</summary>
    public static PageGeometry? FromDocument(RenderTree tree)
    {
        var paper = FirstSectionPaper(tree) ?? tree.Document?.DocumentPaper;
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
    public readonly record struct Markers(
        bool[] SectionStart, bool[] PageBreakBefore, bool[] TableKeepsWhole, bool[] TableRepeatsHeader);

    /// <summary>The four parallel per-block lists <see cref="Walk"/> fills, bundled so adding a
    /// fifth marker later does not mean widening every method's parameter list again.</summary>
    private sealed class MarkerLists
    {
        public readonly List<bool> SectionStart = new();
        public readonly List<bool> PageBreakBefore = new();
        public readonly List<bool> TableKeepsWhole = new();
        public readonly List<bool> TableRepeatsHeader = new();

        public Markers ToMarkers() => new(
            SectionStart.ToArray(), PageBreakBefore.ToArray(), TableKeepsWhole.ToArray(), TableRepeatsHeader.ToArray());
    }

    public static Markers Compute(RenderTree tree)
    {
        var empty = new Markers(Array.Empty<bool>(), Array.Empty<bool>(), Array.Empty<bool>(), Array.Empty<bool>());
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
        return acc.ToMarkers();
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
                Emit(node.AsHeading?.Pagination, false, false, acc, ref pendingSectionStart);
                return;

            case "paragraph":
                Emit(node.AsParagraph?.Pagination, false, false, acc, ref pendingSectionStart);
                return;

            case "listItem":
            case "taskListItem":
            case "codeBlock":
            case "image":
            case "vector":
            case "unsupported":
            case "thematicBreak":
                Emit(null, false, false, acc, ref pendingSectionStart);
                return;

            case "table":
            {
                var t = node.AsTable;
                if (t is null || tableDepth >= MaxTableNestingDepth)
                {
                    WalkChildren(node, byId, acc, ref pendingSectionStart, tableDepth, visiting);
                    return;
                }
                Emit(null, t.Style.PageBreakPolicy == "never", t.Style.RepeatHeaderRows == true,
                    acc, ref pendingSectionStart);
                // A table's rows/cells are NOT walked at the top level when it builds a grid model
                // (BuildTable in FlowDocumentBuilder walks them into the TABLE's OWN cell content
                // lists, never appending to the top-level block list) — so this mirror stops here
                // too, matching that one-block-per-table shape exactly.
                return;
            }

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
                WalkChildren(node, byId, acc, ref pendingSectionStart, tableDepth, visiting);
                return;
        }
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

    private static void Emit(PaginationWire? pagination, bool keepsWhole, bool repeatsHeader,
        MarkerLists acc, ref bool pendingSectionStart)
    {
        acc.SectionStart.Add(pendingSectionStart);
        acc.PageBreakBefore.Add(pagination?.PageBreakBefore ?? false);
        acc.TableKeepsWhole.Add(keepsWhole);
        acc.TableRepeatsHeader.Add(repeatsHeader);
        pendingSectionStart = false;
    }
}
