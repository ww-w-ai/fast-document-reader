using System;
using System.Collections.Generic;
using System.Linq;
using Avalonia;
using Avalonia.Media;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Printing;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Paging;

/// <summary>The rule above a section's footnotes and the air around it (`wire::FootnoteSeparator`),
/// every length already in points. `IsDeclared` is false for a section that declared none — the
/// reader's own minimum applies — and is distinct from a declared line TYPE of 0, which declares
/// "no rule at all".</summary>
public sealed record FootnoteSeparatorSpec(bool IsDeclared, long LineType, double LineWidthPoints, Color? Color,
    double? LengthPoints, double MarginTopPoints, double MarginBottomPoints, double NoteSpacingPoints);

/// <summary>One footnote: its number and the blocks of its body, already built (the body carries
/// its own "1)" marker run, as the document wrote it).</summary>
public sealed record FootnoteNote(long Number, IReadOnlyList<FlowBlock> Blocks);

/// <summary>
/// Where each footnote is drawn in page mode: at the foot of the page its marker is CITED on, inside
/// a band that page reserved so the body stops above it. <see cref="NoteBands"/> is the band height
/// per page (points), <see cref="NotesByPage"/> the note numbers each page cites in citation order,
/// <see cref="Separators"/> each page's section separator. Built by <see cref="FootnoteLayout"/>,
/// drawn by <see cref="PageModePainter"/>.
/// </summary>
public sealed class FootnotePlan
{
    public static readonly FootnotePlan Empty = new();

    public IReadOnlyDictionary<int, double> NoteBands { get; init; } = new Dictionary<int, double>();
    public IReadOnlyDictionary<int, List<long>> NotesByPage { get; init; } = new Dictionary<int, List<long>>();
    public IReadOnlyDictionary<long, FootnoteNote> Notes { get; init; } = new Dictionary<long, FootnoteNote>();
    public IReadOnlyList<FootnoteSeparatorSpec?> SeparatorBySection { get; init; } = Array.Empty<FootnoteSeparatorSpec?>();

    public bool IsEmpty => NoteBands.Count == 0;

    public FootnoteSeparatorSpec? SeparatorForPage(PageLayoutResult layout, int page)
    {
        var section = page < layout.PageSectionIndex.Count ? layout.PageSectionIndex[page] : 0;
        return section >= 0 && section < SeparatorBySection.Count ? SeparatorBySection[section] : null;
    }
}

/// <summary>
/// Page-mode footnotes: a band reserved at the foot of each page that cites notes, found as a
/// FIXPOINT — the band a page reserves depends on which markers land on it, and which markers land
/// on it depends on how much room the band left the body (invariant 98). The whole loop is the
/// engine's, run inside the one page-plan call (`fastdoc_office_page_plan_json`, S5 of
/// docs/plans/pagination-to-engine.md): this host measures each note at the width it is drawn at,
/// says which notes every block cites, and takes back the bands and the page each note is on. Note
/// heights are measured with the SAME text layout that draws them, so what is reserved is what is
/// painted.
///
/// Flow mode keeps the notes at the end of the document (macOS's continuous view has no sheets and so
/// no band; ending the flow with them loses nothing).
/// </summary>
public static class FootnoteLayout
{
    /// <summary>The separator allowance of a section that declared none
    /// (`FootnotePainter.defaultSeparatorAllowance`).</summary>
    public const double DefaultSeparatorAllowance = 8;

    /// <summary>The page layout WITH footnote bands, and the plan that draws them. A document with no
    /// footnotes returns the plain layout and <see cref="FootnotePlan.Empty"/>.</summary>
    public static (PageLayoutResult Layout, FootnotePlan Plan) Build(RenderTree tree, IReadOnlyList<FlowBlock> blocks,
        BlockPageMarkers.Markers markers, PageGeometry geometry, IntPtr engineHandle, bool headersOn, bool footersOn,
        bool splitTablesDefault, ImageBlockRenderer? imageRenderer = null)
    {
        var notes = ReadNotes(tree);
        var separators = ReadSeparators(tree);
        var heights = notes.ToDictionary(n => n.Key,
            n => MeasureNote(n.Value, geometry.ContentWidthPoints, geometry.LineGridPitchPoints, imageRenderer));
        var furniture = PageFurniture.Read(tree, heights, separators);
        var layout = PageLayout.Build(blocks, markers, geometry, engineHandle, headersOn,
            footersOn, splitTablesDefault, imageRenderer, noteBands: null, furniture: furniture);
        if (notes.Count == 0) { return (layout, FootnotePlan.Empty); }
        return (layout, new FootnotePlan
        {
            NoteBands = layout.NoteBands,
            NotesByPage = layout.NotesByPage,
            Notes = notes,
            SeparatorBySection = separators,
        });
    }

    // ---- reading the tree ---------------------------------------------------------------------

    private static Dictionary<long, FootnoteNote> ReadNotes(RenderTree tree)
    {
        var notes = new Dictionary<long, FootnoteNote>();
        if (tree.Document is null) { return notes; }
        var byId = new Dictionary<ulong, RenderNode>(tree.Nodes.Count);
        foreach (var node in tree.Nodes) { byId[node.Id] = node; }
        foreach (var node in tree.Nodes)
        {
            var note = node.AsFootnote;
            if (note is null || notes.ContainsKey((long)note.Number)) { continue; }
            if (!byId.TryGetValue(note.BodyFlowId, out var flow)) { continue; }
            var blocks = FlowDocumentBuilder.BuildFlowBlocks(tree, byId, flow);
            if (blocks.Count > 0) { notes[(long)note.Number] = new FootnoteNote((long)note.Number, blocks); }
        }
        return notes;
    }

    private static List<FootnoteSeparatorSpec?> ReadSeparators(RenderTree tree)
    {
        var result = new List<FootnoteSeparatorSpec?>();
        foreach (var node in tree.Nodes)
        {
            if (node.Type != "section") { continue; }
            var s = node.AsSection?.FootnoteSeparator;
            result.Add(s is null
                ? null
                : new FootnoteSeparatorSpec(true, s.LineType, s.LineWidthPoints, s.Color is { } c ? ColorOf(c) : null,
                    s.LengthPoints, s.MarginTopPoints, s.MarginBottomPoints, s.NoteSpacingPoints));
        }
        return result;
    }

    private static Color ColorOf(ColorWire c)
    {
        static byte Channel(double v) => (byte)Math.Clamp(v * 255.0, 0, 255);
        return Color.FromArgb(Channel(c.Alpha), Channel(c.Red), Channel(c.Green), Channel(c.Blue));
    }

    /// <summary>The notes a block cites, in the order it cites them — a table's, through its cells.</summary>
    internal static IEnumerable<long> NumbersIn(FlowBlock block)
    {
        if (block.Kind == FlowBlockKind.Text)
        {
            foreach (var run in block.Runs) { if (run.FootnoteRef > 0) { yield return run.FootnoteRef; } }
        }
        else if (block.Table is { } table)
        {
            foreach (var row in table.Rows)
            {
                foreach (var cell in row.Cells)
                {
                    foreach (var inner in cell.Content)
                    {
                        foreach (var n in NumbersIn(inner)) { yield return n; }
                    }
                }
            }
        }
    }

    // ---- heights ------------------------------------------------------------------------------

    /// <summary>A note's height in points at the page's content width — the sum of its blocks, each
    /// laid out the way <see cref="PageLayout"/> lays a body block out.</summary>
    internal static double MeasureNote(FootnoteNote note, double widthPoints, double? lineGridPitch,
        ImageBlockRenderer? imageRenderer)
    {
        double total = 0;
        foreach (var block in note.Blocks) { total += MeasureBlock(block, widthPoints, lineGridPitch, imageRenderer); }
        return total;
    }

    internal static double MeasureBlock(FlowBlock block, double widthPoints, double? lineGridPitch, ImageBlockRenderer? imageRenderer)
    {
        var width = Math.Max(1, widthPoints - block.IndentPoints);
        if (block.Kind != FlowBlockKind.Text) { return PageLayout.NonTextBlockHeightPoints(block, width, imageRenderer); }
        var layout = PageLayout.BuildPointsTextLayout(block, width);
        double height = block.SpacingBeforePoints + block.SpacingAfterPoints;
        if (layout is null) { return height + PageLayout.BlankLineHeightPoints(block, lineGridPitch); }
        foreach (var line in layout.TextLines)
        {
            var applied = block.LineHeight.Apply(line.Height);
            height += lineGridPitch is > 0 ? Math.Max(applied, lineGridPitch.Value) : applied;
        }
        return height;
    }

    /// <summary>The allowance a page's rule and its margins claim above the notes — what the painter
    /// draws (`FootnotePainter.separatorAllowance`); the engine reserves the same figure.</summary>
    public static double SeparatorAllowance(FootnoteSeparatorSpec? separator)
    {
        if (separator is not { IsDeclared: true }) { return DefaultSeparatorAllowance; }
        var rule = separator.LineType == 0 ? 0 : Math.Max(separator.LineWidthPoints, 0.5);
        return separator.MarginTopPoints + rule + separator.MarginBottomPoints;
    }
}

/// <summary>What the page plan chooses among for each sheet — the document's running heads and feet
/// and its master pages, and the sections that veto them — read off the tree, plus the notes whose
/// band the plan settles (S5). The host holds the entries; the engine says which one applies to which
/// page.</summary>
internal static class PageFurniture
{
    public static PlanFurnitureInput Read(RenderTree tree, IReadOnlyDictionary<long, double> noteHeights,
        IReadOnlyList<FootnoteSeparatorSpec?> separators)
    {
        var headers = HeaderFooterText.CollectCandidates(tree, "header").Select(c => new PlanEntryInput(c.AppliesTo, c.Section)).ToList();
        var footers = HeaderFooterText.CollectCandidates(tree, "footer").Select(c => new PlanEntryInput(c.AppliesTo, c.Section)).ToList();
        var masters = new List<PlanEntryInput>();
        var hidingHeader = new List<int>();
        var hidingFooter = new List<int>();
        var hidingMaster = new List<int>();
        if (tree.Document is not null)
        {
            var byId = new Dictionary<ulong, RenderNode>(tree.Nodes.Count);
            foreach (var node in tree.Nodes) { byId[node.Id] = node; }
            if (byId.TryGetValue(tree.Document.RootNodeId, out var root))
            {
                var sectionIndex = -1;
                foreach (var sectionId in root.Children)
                {
                    if (!byId.TryGetValue(sectionId, out var section) || section.Type != "section") { continue; }
                    sectionIndex++;
                    if (section.AsSection is { } declared)
                    {
                        if (declared.HidesHeader) { hidingHeader.Add(sectionIndex); }
                        if (declared.HidesFooter) { hidingFooter.Add(sectionIndex); }
                        if (declared.HidesMasterPage) { hidingMaster.Add(sectionIndex); }
                    }
                    foreach (var childId in section.Children)
                    {
                        if (byId.TryGetValue(childId, out var child) && child.Type == "masterPage" && child.AsMasterPage is { } master)
                        {
                            masters.Add(new PlanEntryInput(master.AppliesTo, sectionIndex));
                        }
                    }
                }
            }
        }
        return new PlanFurnitureInput
        {
            Headers = headers,
            Footers = footers,
            Masters = masters,
            SectionsHidingHeader = hidingHeader,
            SectionsHidingFooter = hidingFooter,
            SectionsHidingMaster = hidingMaster,
            Notes = noteHeights.Select(n => new PlanNoteInput(n.Key, n.Value)).OrderBy(n => n.Number).ToList(),
            Separators = separators
                .Select((s, section) => (s, section))
                .Where(p => p.s is { IsDeclared: true })
                .Select(p => new PlanSeparatorInput(p.section, p.s!.LineType, p.s.LineWidthPoints, p.s.MarginTopPoints,
                    p.s.MarginBottomPoints, p.s.NoteSpacingPoints))
                .ToList(),
        };
    }
}
