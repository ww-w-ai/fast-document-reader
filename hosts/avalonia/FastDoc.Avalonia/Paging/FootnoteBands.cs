using System;
using System.Collections.Generic;
using System.Linq;
using Avalonia;
using Avalonia.Media;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Native;
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
/// on it depends on how much room the band left the body (invariant 98). The stopping rule and the
/// band arithmetic are the engine's (`fastdoc_office_footnote_band_settle`); the managed copy below
/// is the same rule for an engine library that predates the export. Note heights are measured with
/// the SAME text layout that draws them, so what is reserved is what is painted.
///
/// Flow mode keeps the notes at the end of the document (macOS's continuous view has no sheets and so
/// no band; ending the flow with them loses nothing).
/// </summary>
public static class FootnoteLayout
{
    /// <summary>The settle's round budget — the same one the table settle shares
    /// (`FootnoteBandSettle.maxRounds`).</summary>
    public const int MaxRounds = 8;

    /// <summary>The most of a page's body a band may take (`FootnoteBandSettle.maxBandFraction`) — a
    /// termination guard that keeps the body's height positive.</summary>
    public const double MaxBandFraction = 0.75;

    /// <summary>The separator allowance of a section that declared none
    /// (`FootnotePainter.defaultSeparatorAllowance`).</summary>
    public const double DefaultSeparatorAllowance = 8;

    /// <summary>The page layout WITH footnote bands, and the plan that draws them. A document with no
    /// footnotes returns the plain table-settled layout and <see cref="FootnotePlan.Empty"/>.</summary>
    public static (PageLayoutResult Layout, FootnotePlan Plan) Build(RenderTree tree, IReadOnlyList<FlowBlock> blocks,
        BlockPageMarkers.Markers markers, PageGeometry geometry, IntPtr engineHandle, bool headersOn, bool footersOn,
        bool splitTablesDefault, ImageBlockRenderer? imageRenderer = null)
    {
        var (first, _, _, _) = PageLayout.BuildWithTableSettle(blocks, markers, geometry, engineHandle, headersOn,
            footersOn, splitTablesDefault, imageRenderer);
        var notes = ReadNotes(tree);
        if (notes.Count == 0) { return (first, FootnotePlan.Empty); }

        var separators = ReadSeparators(tree);
        var contentWidth = geometry.ContentWidthPoints;
        var heights = notes.ToDictionary(n => n.Key, n => MeasureNote(n.Value, contentWidth, geometry.LineGridPitchPoints, imageRenderer));

        var layout = first;
        var bands = new Dictionary<int, double>();
        var history = new List<Dictionary<int, double>>();
        Dictionary<int, List<long>> assignment = Assign(layout, blocks, notes.Keys);

        for (var round = 0; round < MaxRounds; round++)
        {
            var plan = new FootnotePlan { SeparatorBySection = separators };
            var proposal = Propose(assignment, heights, layout, plan, geometry.ContentHeightPoints);
            var (outcomeStops, outcomeBands) = Step(proposal, history, MaxRounds, assignment, heights, plan, layout, geometry.ContentHeightPoints);
            if (!outcomeStops)
            {
                history.Add(Normalise(proposal));
                bands = outcomeBands;
                layout = Rebuild(blocks, markers, geometry, engineHandle, headersOn, footersOn, splitTablesDefault, imageRenderer, bands);
                assignment = Assign(layout, blocks, notes.Keys);
                continue;
            }
            // STOPPED. The assignment the ruling stopped ON is frozen with it; the layout is rebuilt
            // against the final bands, and the assignment refreshed from it only when the frozen
            // bands already cover that assignment (a band grown after the fact would shorten pages no
            // rule re-checks).
            var changed = !SameBands(bands, outcomeBands);
            bands = outcomeBands;
            if (changed)
            {
                layout = Rebuild(blocks, markers, geometry, engineHandle, headersOn, footersOn, splitTablesDefault, imageRenderer, bands);
                var refreshed = Assign(layout, blocks, notes.Keys);
                if (Covers(bands, refreshed, heights, separators, layout, geometry.ContentHeightPoints)) { assignment = refreshed; }
            }
            break;
        }

        return (layout, new FootnotePlan
        {
            NoteBands = bands,
            NotesByPage = assignment,
            Notes = notes,
            SeparatorBySection = separators,
        });
    }

    private static PageLayoutResult Rebuild(IReadOnlyList<FlowBlock> blocks, BlockPageMarkers.Markers markers,
        PageGeometry geometry, IntPtr engineHandle, bool headersOn, bool footersOn, bool splitTablesDefault,
        ImageBlockRenderer? imageRenderer, Dictionary<int, double> bands)
    {
        var (layout, _, _, _) = PageLayout.BuildWithTableSettle(blocks, markers, geometry, engineHandle, headersOn,
            footersOn, splitTablesDefault, imageRenderer, bands);
        return layout;
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

    // ---- which page cites which note ----------------------------------------------------------

    /// <summary>Note number -> the page its marker landed on, grouped per page in citation order. A
    /// note is drawn once, on the first page that cites it. A marker in a text block is found by the
    /// line holding its character; one inside a table cell, or any other non-text block, by the page
    /// the block starts on.</summary>
    internal static Dictionary<int, List<long>> Assign(PageLayoutResult layout, IReadOnlyList<FlowBlock> blocks,
        IEnumerable<long> knownNotes)
    {
        var known = new HashSet<long>(knownNotes);
        var linesOfBlock = new Dictionary<int, List<PagedLine>>();
        foreach (var line in layout.Lines)
        {
            if (!linesOfBlock.TryGetValue(line.BlockIndex, out var list)) { linesOfBlock[line.BlockIndex] = list = new(); }
            list.Add(line);
        }
        var firstPlacement = new Dictionary<int, PagedBlock>();
        foreach (var placement in layout.Placements) { firstPlacement.TryAdd(placement.BlockIndex, placement); }

        var citations = new List<(int Page, int Block, int Offset, long Number)>();
        for (var i = 0; i < blocks.Count; i++)
        {
            var block = blocks[i];
            if (block.FootnoteOf is not null) { continue; }
            if (block.Kind == FlowBlockKind.Text)
            {
                if (!linesOfBlock.TryGetValue(i, out var lines)) { continue; }
                var offset = 0;
                foreach (var run in block.Runs)
                {
                    if (run.FootnoteRef > 0 && known.Contains(run.FootnoteRef))
                    {
                        var line = lines.FirstOrDefault(l => l.Length > 0 && offset >= l.FirstChar && offset < l.FirstChar + l.Length);
                        if (line == default) { line = lines[^1]; }
                        citations.Add((line.PageIndex, i, offset, run.FootnoteRef));
                    }
                    offset += run.Text.Length;
                }
            }
            else if (firstPlacement.TryGetValue(i, out var placed))
            {
                foreach (var number in NumbersIn(block))
                {
                    if (known.Contains(number)) { citations.Add((placed.PageIndex, i, 0, number)); }
                }
            }
        }

        var result = new Dictionary<int, List<long>>();
        var placedNumbers = new HashSet<long>();
        foreach (var citation in citations.OrderBy(c => c.Page).ThenBy(c => c.Block).ThenBy(c => c.Offset))
        {
            // A note cited twice is drawn once, on the first page that cites it.
            if (!placedNumbers.Add(citation.Number)) { continue; }
            if (!result.TryGetValue(citation.Page, out var list)) { result[citation.Page] = list = new(); }
            list.Add(citation.Number);
        }
        return result;
    }

    private static IEnumerable<long> NumbersIn(FlowBlock block)
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

    // ---- heights and the proposal -------------------------------------------------------------

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

    /// <summary>The allowance a page's rule and its margins claim above the notes — the one function
    /// the reservation and the painter share (`FootnotePainter.separatorAllowance`).</summary>
    public static double SeparatorAllowance(FootnoteSeparatorSpec? separator)
    {
        if (separator is not { IsDeclared: true }) { return DefaultSeparatorAllowance; }
        var rule = separator.LineType == 0 ? 0 : Math.Max(separator.LineWidthPoints, 0.5);
        return separator.MarginTopPoints + rule + separator.MarginBottomPoints;
    }

    /// <summary>This round's band per page: the allowance, the heights of the notes it cites and the
    /// spacing between them, clamped (`PageBandGeometry.footnoteBandHeight` + `clamped`).</summary>
    private static Dictionary<int, double> Propose(Dictionary<int, List<long>> assignment,
        Dictionary<long, double> heights, PageLayoutResult layout, FootnotePlan plan, double pageContentHeight)
    {
        var proposed = new Dictionary<int, double>();
        foreach (var (page, numbers) in assignment)
        {
            var drawn = numbers.Select(n => heights.GetValueOrDefault(n)).Where(h => h > 0).ToList();
            if (drawn.Count == 0) { continue; }
            var separator = plan.SeparatorForPage(layout, page);
            var spacing = separator?.NoteSpacingPoints ?? 0;
            var raw = SeparatorAllowance(separator) + drawn.Sum() + Math.Max(0, spacing * (drawn.Count - 1));
            var clamped = Clamp(raw, pageContentHeight);
            if (clamped > 0) { proposed[page] = clamped; }
        }
        return proposed;
    }

    internal static double Clamp(double raw, double pageContentHeight)
    {
        if (pageContentHeight <= 0 || double.IsNaN(raw) || raw <= 0) { return 0; }
        return Math.Min(raw, pageContentHeight * MaxBandFraction);
    }

    private static bool Covers(Dictionary<int, double> bands, Dictionary<int, List<long>> assignment,
        Dictionary<long, double> heights, IReadOnlyList<FootnoteSeparatorSpec?> separators, PageLayoutResult layout,
        double pageContentHeight)
    {
        var plan = new FootnotePlan { SeparatorBySection = separators };
        var need = Propose(assignment, heights, layout, plan, pageContentHeight);
        return need.All(kv => bands.TryGetValue(kv.Key, out var have) && have + 0.01 >= kv.Value);
    }

    // ---- the stopping rule --------------------------------------------------------------------

    /// <summary>Whether to retry with these bands or stop on them. Engine first
    /// (`fastdoc_office_footnote_band_settle`: proposal arithmetic AND the rule), the managed copy
    /// when the export is missing.</summary>
    private static (bool Stop, Dictionary<int, double> Bands) Step(Dictionary<int, double> proposed,
        List<Dictionary<int, double>> history, int cap, Dictionary<int, List<long>> assignment,
        Dictionary<long, double> heights, FootnotePlan plan, PageLayoutResult layout, double pageContentHeight)
    {
        if (TryEngineStep(assignment, heights, plan, layout, history, pageContentHeight, cap) is { } engine) { return engine; }
        return ManagedStep(proposed, history, cap);
    }

    /// <summary>`FootnoteBandSettle.step`: stillness (the proposal equals the last), a repeat (a cycle
    /// — resolved to the pointwise MAXIMUM, the loose half of the oscillation), or the round cap.</summary>
    internal static (bool Stop, Dictionary<int, double> Bands) ManagedStep(Dictionary<int, double> proposed,
        List<Dictionary<int, double>> history, int cap)
    {
        var now = Normalise(proposed);
        var seen = history.Select(Normalise).ToList();
        if (seen.Count > 0 && SameBands(seen[^1], now)) { return (true, now); }
        var repeat = seen.FindIndex(s => SameBands(s, now));
        if (repeat >= 0) { return (true, PointwiseMax(seen.Skip(repeat).Append(now))); }
        if (seen.Count + 1 >= cap) { return (true, PointwiseMax(seen.Append(now))); }
        return (false, now);
    }

    private static Dictionary<int, double> Normalise(Dictionary<int, double> state) =>
        state.Where(kv => kv.Value > 0).ToDictionary(kv => kv.Key, kv => kv.Value);

    private static Dictionary<int, double> PointwiseMax(IEnumerable<Dictionary<int, double>> states)
    {
        var result = new Dictionary<int, double>();
        foreach (var state in states)
        {
            foreach (var (page, band) in state)
            {
                if (band > 0) { result[page] = Math.Max(result.GetValueOrDefault(page), band); }
            }
        }
        return result;
    }

    private static bool SameBands(Dictionary<int, double> a, Dictionary<int, double> b)
    {
        var x = Normalise(a);
        var y = Normalise(b);
        return x.Count == y.Count && x.All(kv => y.TryGetValue(kv.Key, out var v) && Math.Abs(v - kv.Value) < 1e-9);
    }

    private static (bool Stop, Dictionary<int, double> Bands)? TryEngineStep(Dictionary<int, List<long>> assignment,
        Dictionary<long, double> heights, FootnotePlan plan, PageLayoutResult layout,
        List<Dictionary<int, double>> history, double pageContentHeight, int cap)
    {
        try
        {
            var noteHeights = new List<double>();
            var pages = new List<FastdocEngine.FastdocFootnotePageDesc>();
            foreach (var (page, numbers) in assignment.OrderBy(kv => kv.Key))
            {
                var separator = plan.SeparatorForPage(layout, page);
                pages.Add(new FastdocEngine.FastdocFootnotePageDesc
                {
                    PageIndex = page,
                    NoteOffset = (nuint)noteHeights.Count,
                    NoteCount = (nuint)numbers.Count,
                    HasSeparator = separator is not null,
                    SeparatorIsDeclared = separator?.IsDeclared ?? false,
                    SeparatorLineType = separator?.LineType ?? 0,
                    SeparatorLineWidthPt = separator?.LineWidthPoints ?? 0,
                    SeparatorMarginTopPt = separator?.MarginTopPoints ?? 0,
                    SeparatorMarginBottomPt = separator?.MarginBottomPoints ?? 0,
                    SeparatorNoteSpacingPt = separator?.NoteSpacingPoints ?? 0,
                });
                foreach (var number in numbers) { noteHeights.Add(heights.GetValueOrDefault(number)); }
            }
            var rounds = new List<FastdocEngine.FastdocFootnoteHistoryRoundDesc>();
            var entries = new List<FastdocEngine.FastdocNoteBandEntry>();
            foreach (var round in history)
            {
                rounds.Add(new FastdocEngine.FastdocFootnoteHistoryRoundDesc
                {
                    EntryOffset = (nuint)entries.Count,
                    EntryCount = (nuint)round.Count,
                });
                foreach (var (page, band) in round.OrderBy(kv => kv.Key))
                {
                    entries.Add(new FastdocEngine.FastdocNoteBandEntry { Page = page, Value = band });
                }
            }
            var capacity = Math.Max(1, pages.Count);
            var outBands = new FastdocEngine.FastdocNoteBandEntry[capacity];
            var ok = FastdocEngine.fastdoc_office_footnote_band_settle(
                pages.ToArray(), (nuint)pages.Count, noteHeights.ToArray(), (nuint)noteHeights.Count,
                rounds.ToArray(), (nuint)rounds.Count, entries.ToArray(), (nuint)entries.Count,
                pageContentHeight, cap, outBands, (nuint)capacity, out var count, out var outcome, out _);
            if (!ok || outcome < 0) { return null; }
            var bands = new Dictionary<int, double>();
            for (var i = 0; i < (int)count; i++) { bands[(int)outBands[i].Page] = outBands[i].Value; }
            return (outcome == 1, bands);
        }
        catch (Exception e) when (e is EntryPointNotFoundException or DllNotFoundException or BadImageFormatException
            or InvalidOperationException)
        {
            return null;
        }
    }
}
