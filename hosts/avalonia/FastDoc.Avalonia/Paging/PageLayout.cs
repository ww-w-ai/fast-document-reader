using System;
using System.Collections.Generic;
using System.Linq;
using Avalonia;
using Avalonia.Media;
using Avalonia.Media.TextFormatting;
using Avalonia.Utilities;
using FastDoc.Avalonia.Native;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Paging;

/// <summary>The engine's own header/footer/band answer (fastdoc_office_band_sides), or this
/// host's fallback when the engine refused (no measurer, unreadable document, NULL handle) —
/// mirrors PageBandGeometry.Sides on macOS. All three fields are in POINTS.</summary>
public readonly record struct PageBandSides(double HeaderPoints, double FooterPoints, double BandPoints, bool FromEngine);

/// <summary>S5C1-02/S5C2-01 wrappers — one static call each, engine-first with a host fallback that
/// mirrors the Swift formulas verbatim (PageBandGeometry.measure / PagePagination.sheets), so a
/// document this engine build cannot answer for (no dylib, an office parse this host has not
/// opened a handle for) still shows SOMETHING rather than refusing page mode outright.</summary>
public static class PageBandResolver
{
    public static PageBandSides Resolve(IntPtr handle, PageGeometry geometry, double columnWidthPoints,
        bool headersOn, bool footersOn, bool separatesPages, double? deskGapPoints)
    {
        if (handle != IntPtr.Zero)
        {
            var out3 = new double[3];
            var ok = FastdocEngine.fastdoc_office_band_sides(
                handle, columnWidthPoints,
                geometry.ContentWidthPoints, true,
                geometry.MarginTopPoints, true,
                geometry.MarginBottomPoints, true,
                headersOn, footersOn, separatesPages,
                deskGapPoints ?? 0, deskGapPoints.HasValue,
                out3);
            if (ok)
            {
                return new PageBandSides(out3[0], out3[1], out3[2], FromEngine: true);
            }
        }

        // Host fallback — mirrors PageBandGeometry.measure's declaredBand/max(h, f) formula, minus
        // the header/footer CONTENT height (h, f): this host does not independently build
        // header/footer text (TextMeasurerPort's own doc explains why it does not need to for the
        // engine-answered path), so the fallback's only honest number is the document's own
        // declared margins — a document whose header/footer draws TALLER than its margins will
        // under-reserve on this fallback path exactly the way PageBandGeometry.measure's own doc
        // says an un-declared margin does.
        if (!headersOn && !footersOn && !separatesPages)
        {
            return new PageBandSides(0, 0, 0, FromEngine: false);
        }
        var declared = Math.Max(0, geometry.MarginTopPoints) + Math.Max(0, geometry.MarginBottomPoints);
        var band = declared + (separatesPages ? (deskGapPoints ?? 12) : 0);
        return new PageBandSides(0, 0, band, FromEngine: false);
    }
}

public static class PageSheetsResolver
{
    public static Rect[] Resolve(IntPtr handle, int count, double widthPoints, double textOriginYPoints,
        double leadingBandPoints, double pitchPoints, double topMarginPoints, double deskGapPoints)
    {
        if (count <= 0 || pitchPoints <= 0 || widthPoints <= 0) { return Array.Empty<Rect>(); }

        if (handle != IntPtr.Zero)
        {
            var outCapacity = (nuint)(count * 4);
            var out4 = new double[count * 4];
            var ok = FastdocEngine.fastdoc_office_sheets(handle, count, widthPoints, textOriginYPoints,
                leadingBandPoints, pitchPoints, topMarginPoints, deskGapPoints, out4, outCapacity, out _);
            if (ok)
            {
                var fromEngine = new Rect[count];
                for (var i = 0; i < count; i++)
                {
                    fromEngine[i] = new Rect(out4[i * 4], out4[i * 4 + 1], out4[i * 4 + 2], out4[i * 4 + 3]);
                }
                return fromEngine;
            }
        }

        // Host fallback — PagePagination.sheets/sheetTop, verbatim.
        var paperHeight = Math.Max(1, pitchPoints - deskGapPoints);
        var rects = new Rect[count];
        for (var page = 0; page < count; page++)
        {
            var top = textOriginYPoints + leadingBandPoints + page * pitchPoints - topMarginPoints;
            rects[page] = new Rect(0, top, widthPoints, paperHeight);
        }
        return rects;
    }
}

/// <summary>One NON-TEXT block's placement (Rule/Image/Table) — treated as a single atomic unit
/// per E2c-2's own scope (a table's row-level settle is that unit's job, not this one's).
/// <see cref="BlockIndex"/> indexes the SAME FlowBlock list FlowDocumentBuilder.Build(tree)
/// returned. All measurements are in POINTS — PageModePainter converts to pixels at draw time.</summary>
/// <summary><paramref name="RowRangeStart"/>/<paramref name="RowRangeCount"/> are non-null ONLY for
/// a table piece the settle loop broke off a bigger table (E2c-2b) — the real row indices (into
/// the SAME <see cref="Rendering.TableGridModel.Rows"/> the whole table uses) this specific piece
/// covers, so <see cref="PageModePainter"/> can ask <see cref="Rendering.TableGridRenderer.Draw"/>
/// to paint exactly this piece's rows (plus a repeated header, if the document asks for one)
/// instead of the whole grid on every page it touches.</summary>
/// <summary><paramref name="Flowed"/> marks a table piece the plan cut through the middle of its rows
/// (a table that fits no page): its rows are drawn from <see cref="PageLayoutResult.Flowed"/>, not whole.</summary>
public readonly record struct PagedBlock(int BlockIndex, int PageIndex, double LocalTopPoints, double HeightPoints,
    int? RowRangeStart = null, int? RowRangeCount = null, bool Flowed = false);

/// <summary>One row's box on one page of a flowed table, in page-local points.</summary>
internal readonly record struct FlowSegment(double Top, double Bottom);

/// <summary>What the plan decided about the tables it flowed across pages line by line: where each row
/// stands on each page it touches and where every cell line landed (S4 of
/// docs/plans/pagination-to-engine.md). Keyed by the FlowBlock index, the row, the cell's position in
/// its row and the line's position in the cell.</summary>
public sealed class FlowedTables
{
    private readonly Dictionary<(int Block, int Row), List<(int Page, FlowSegment Box)>> _segments = new();
    private readonly Dictionary<(int Block, int Row, int Cell, int Line, int Page), double> _lines = new();

    public bool IsEmpty => _segments.Count == 0;

    internal void Add(PlannedRowSegment s)
    {
        if (!_segments.TryGetValue((s.Block, s.Row), out var list))
        {
            list = new List<(int, FlowSegment)>(1);
            _segments[(s.Block, s.Row)] = list;
        }
        list.Add((s.Page, new FlowSegment(s.Top, s.Bottom)));
    }

    internal void Add(PlannedCellLine l) => _lines[(l.Block, l.Row, l.Cell, l.Line, l.Page)] = l.Top;

    internal bool TryGetSegment(int block, int row, int page, out FlowSegment segment)
    {
        segment = default;
        if (!_segments.TryGetValue((block, row), out var list)) { return false; }
        foreach (var (p, box) in list)
        {
            if (p == page) { segment = box; return true; }
        }
        return false;
    }

    internal bool StartsOnPage(int block, int row, int page) =>
        _segments.TryGetValue((block, row), out var list) && list.Count > 0 && list[0].Page == page;

    internal bool EndsOnPage(int block, int row, int page) =>
        _segments.TryGetValue((block, row), out var list) && list.Count > 0 && list[^1].Page == page;

    internal bool TryGetLine(int block, int row, int cell, int line, int page, out double top) =>
        _lines.TryGetValue((block, row, cell, line, page), out top);
}

/// <summary>E2c-1b: one TEXT LINE's placement — the granularity PageBandLayoutDelegate.swift
/// shifts at on macOS. A text block ("paragraph"/"heading"/"listItem"/... FlowDocumentBuilder
/// treats as one flow entry) contributes one entry per <see cref="Avalonia.Media.TextFormatting.
/// TextLayout.TextLines"/> line — so a paragraph that does not fit its starting page contributes
/// SOME lines to page N and the rest to page N+1, each at PageModePainter's own page-local y.
/// <see cref="LineIndex"/> is the line's position within its OWN block's TextLayout (rebuilt at
/// draw time at pixel scale — see PageModePainter's own doc for why the two layouts wrap
/// identically) — never a global line number.</summary>
public readonly record struct PagedLine(int BlockIndex, int LineIndex, int PageIndex, double LocalTopPoints, double HeightPoints,
    int FirstChar = 0, int Length = 0);

/// <summary>The result of one pagination pass: how many pages, the page content box, and where
/// every block/line landed.</summary>
public sealed class PageLayoutResult
{
    public required int PageCount { get; init; }
    public required double PageContentWidthPoints { get; init; }
    public required double PageContentHeightPoints { get; init; }
    public required PageBandSides Band { get; init; }
    /// <summary>Rule/Image/Table blocks only — see <see cref="PagedBlock"/>.</summary>
    public required IReadOnlyList<PagedBlock> Placements { get; init; }
    /// <summary>Text blocks only, one entry per TextLine — see <see cref="PagedLine"/>.</summary>
    public required IReadOnlyList<PagedLine> Lines { get; init; }
    /// <summary>S8-A2 (C3/C5): which SECTION (0-based, document order) each page belongs to —
    /// index <c>p</c> holds the section active on page <c>p</c>. A document with one section is
    /// all zeros. <see cref="Paging.PageModePainter"/> uses this to pick the right
    /// header/footer/first-page band for a page instead of concatenating every header/footer node
    /// in the whole document onto every page (the bug behind catalog findings F5/F6/F8-F10).</summary>
    public required IReadOnlyList<int> PageSectionIndex { get; init; }
    /// <summary>What the engine's page plan reported, for `--sheets`: tables placed as row-bounded
    /// pieces, tables carried whole to the next page, hard breaks dropped by invariant 147.</summary>
    public int SplitTableCount { get; init; }
    /// <summary>The reader's "tables break across pages" preference this layout was built under: it
    /// decides whether a table cell's last line gives its spacing back (invariant 161b), so the painter
    /// must draw with the same value the rows were solved with.</summary>
    public bool SplitTables { get; init; }
    public int CarriedTableCount { get; init; }
    public int DroppedBreakCount { get; init; }
    /// <summary>The tables the plan cut through the middle of their rows; null when there are none.</summary>
    public FlowedTables? Flowed { get; init; }
}

/// <summary>
/// Assigns every FlowBlock to a page. This host MEASURES — a paragraph's line boxes, a picture's
/// height, a table's row heights — and the engine's page plan DECIDES (`fastdoc_office_page_plan_json`,
/// S2 of docs/plans/pagination-to-engine.md): a paragraph that will not finish on the page it
/// starts on is split at a line boundary and continues flush at the top of the next page, a hard
/// break at the top of an empty page opens nothing, keep-with-next carries a heading with what
/// follows, and a table that overruns its page is carried whole, split at the rows no merged cell
/// crosses, or — when it fits no page — broken at every such boundary.
///
/// A line taller than the whole page body (invariant 142's own case) is placed at the top of the
/// page it starts on and simply overruns it — never split further.
///
/// Zoom is deliberately NOT an input here: page shape and line-breaking both come from the
/// DOCUMENT's own declared points, so re-pagination never needs to happen on a zoom change — the
/// zoom factor only scales the final points-to-pixels conversion PageModePainter performs (and
/// PageModePainter rebuilds an equivalent TextLayout at that scale to get drawable TextLine
/// instances — see that file's own doc for why the two layouts' line breaks are guaranteed
/// identical).
/// </summary>
public static class PageLayout
{
    private static readonly Typeface DefaultTypeface = new("Inter");

    private static readonly System.Collections.Concurrent.ConcurrentDictionary<double, double> NaturalLineHeights = new();

    /// <summary>The line an empty paragraph still occupies: its OWN line-height rule applied to a
    /// line of its own size (an `exact 0.01` anchor is 0.01 pt, an `atLeast 16` blank is at least 16),
    /// then floored by the line grid like any other line. A fixed constant here stood for every
    /// blank paragraph whatever it declared (diagnosis cause 3). The host supplies only the glyph
    /// metrics, and only when the rule leaves the height to them.</summary>
    internal static double BlankLineHeightPoints(FlowBlock block, double? lineGridPitchPoints)
    {
        var natural = block.LineHeight.Mode == LineHeightMode.Exact ? 0 : NaturalLineHeightPoints(block.BlankLineSizePoints);
        return EffectiveLineHeight(natural, block.LineHeight, lineGridPitchPoints);
    }

    private static double NaturalLineHeightPoints(double sizePoints) => NaturalLineHeight(sizePoints);

    /// <summary>The natural line box of a line of <paramref name="size"/> (in whatever unit the caller
    /// lays out in — points for pagination, pixels for a table cell): the host's glyph metrics, the
    /// one input an empty paragraph's line needs from this side.</summary>
    internal static double NaturalLineHeight(double size0)
    {
        var size = Math.Max(1, size0);
        return NaturalLineHeights.GetOrAdd(size, s =>
        {
            var layout = new TextLayout(" ", DefaultTypeface, s, Brushes.Black);
            return layout.TextLines.Count > 0 ? layout.TextLines[0].Height : s * 1.2;
        });
    }

    /// <summary>One text block as this host measured it: each line box's placed height and the source
    /// range it covers — what <see cref="PagedLine"/> carries back once the engine has said which
    /// page each line is on.</summary>
    private sealed class TextShape
    {
        public required double[] Heights { get; init; }
        public required int[] FirstChars { get; init; }
        public required int[] Lengths { get; init; }
    }

    /// <summary>Measures the blocks, asks the engine where each goes (the page plan, S2 of
    /// docs/plans/pagination-to-engine.md) and carries its answer back. This host decides nothing
    /// about pages: it supplies line boxes, picture heights and table row heights, and the engine
    /// answers every "does it fit, does it break, does it move" question — hard breaks, keep-with-next,
    /// table push and split, the section each page belongs to.</summary>
    public static PageLayoutResult Build(IReadOnlyList<FlowBlock> blocks, BlockPageMarkers.Markers markers,
        PageGeometry geometry, IntPtr engineHandle, bool headersOn, bool footersOn,
        bool splitTables = false, ImageBlockRenderer? imageRenderer = null,
        IReadOnlyDictionary<int, double>? noteBands = null)
    {
        var contentWidth = geometry.ContentWidthPoints;
        var contentHeight = geometry.ContentHeightPoints;
        var band = PageBandResolver.Resolve(engineHandle, geometry, contentWidth, headersOn, footersOn,
            separatesPages: true, deskGapPoints: null);

        var inputs = new List<PlanBlockInput>(blocks.Count);
        var shapes = new TextShape?[blocks.Count];
        // Every text block's natural line boxes go to the engine's line model in ONE call; it answers
        // the heights the document's rules make of them, in the same order.
        var facts = new List<ParagraphFactsIn>();
        var slots = new List<(int Input, int Block, bool Blank)>();
        for (var i = 0; i < blocks.Count; i++)
        {
            var block = blocks[i];
            var key = i < markers.NodeId.Length ? (long)markers.NodeId[i] : i;
            var sectionStart = i < markers.SectionStart.Length && markers.SectionStart[i];
            var pageBreakBefore = i < markers.PageBreakBefore.Length && markers.PageBreakBefore[i];
            // The footnote tail flow mode shows after the body is NOT part of a sheet's flow: each
            // note is drawn at the foot of the page that cites it (FootnoteLayout).
            if (block.FootnoteOf is not null && noteBands is not null)
            {
                inputs.Add(new PlanBlockInput { Key = key, Kind = "atomic", Skip = true });
                continue;
            }
            var keepWithNext = markers.KeepWithNext is { } keeps && i < keeps.Length && keeps[i];
            var widthForBlock = Math.Max(1, contentWidth - block.IndentPoints);

            if (block.Kind == FlowBlockKind.Text)
            {
                var empty = block.Runs.TrueForAll(r => string.IsNullOrWhiteSpace(r.Text));
                var layout = BuildPointsTextLayout(block, widthForBlock);
                if (layout is null)
                {
                    // A blank paragraph is one unit: its spacing and its own line, as the old
                    // placement summed them. The line's height is the engine's (below).
                    shapes[i] = new TextShape { Heights = new double[1], FirstChars = new[] { 0 }, Lengths = new[] { 0 } };
                    facts.Add(ParagraphFactsIn.From(block, new[] { NaturalLineHeight(block.BlankLineSizePoints) }, blank: true));
                    slots.Add((inputs.Count, i, true));
                    inputs.Add(new PlanBlockInput
                    {
                        Key = key, Kind = "text", SectionStart = sectionStart, PageBreakBefore = pageBreakBefore,
                        KeepWithNext = keepWithNext, Empty = true,
                    });
                    continue;
                }
                var lines = layout.TextLines;
                var shape = new TextShape
                {
                    Heights = new double[lines.Count], FirstChars = new int[lines.Count], Lengths = new int[lines.Count],
                };
                var natural = new double[lines.Count];
                for (var l = 0; l < lines.Count; l++)
                {
                    natural[l] = lines[l].Height;
                    shape.FirstChars[l] = lines[l].FirstTextSourceIndex;
                    shape.Lengths[l] = lines[l].Length;
                }
                shapes[i] = shape;
                facts.Add(ParagraphFactsIn.From(block, natural, blank: false));
                slots.Add((inputs.Count, i, false));
                inputs.Add(new PlanBlockInput
                {
                    Key = key, Kind = "text", SectionStart = sectionStart, PageBreakBefore = pageBreakBefore,
                    KeepWithNext = keepWithNext, Empty = empty, SpacingBefore = block.SpacingBeforePoints,
                    SpacingAfter = block.SpacingAfterPoints,
                });
                continue;
            }

            if (block.Kind == FlowBlockKind.Table && block.Table is { } table)
            {
                var rowHeights = TableSettle.EstimateRowHeights(table, widthForBlock, imageRenderer, splitTables);
                var canBreak = TableSettle.RowsThatCanBreakAbove(table);
                // A table taller than the page body is flowed line by line by the plan, which needs each
                // cell's lines; every other table is placed from its rows alone.
                var flowable = rowHeights.Sum() > contentHeight;
                inputs.Add(new PlanBlockInput
                {
                    Key = key, Kind = "table", SectionStart = sectionStart, PageBreakBefore = pageBreakBefore,
                    SpacingBefore = block.SpacingBeforePoints, SpacingAfter = block.SpacingAfterPoints,
                    RowHeights = rowHeights.Length == canBreak.Length ? rowHeights : PadRows(rowHeights, canBreak.Length),
                    RowCanBreakAbove = canBreak,
                    RowCells = flowable ? TableGridRenderer.FlowFacts(table, widthForBlock, imageRenderer, splitTables) : null,
                    KeepsWhole = i < markers.TableKeepsWhole.Length && markers.TableKeepsWhole[i],
                });
                continue;
            }

            inputs.Add(new PlanBlockInput
            {
                Key = key, Kind = "atomic", SectionStart = sectionStart, PageBreakBefore = pageBreakBefore,
                Height = NonTextBlockHeightPoints(block, widthForBlock, imageRenderer, splitTables),
            });
        }

        var (answers, _) = LineModelClient.Solve(geometry.LineGridPitchPoints, facts, Array.Empty<TableFactsIn>());
        for (var n = 0; n < slots.Count; n++)
        {
            var (inputIndex, blockIndex, blank) = slots[n];
            var shape = shapes[blockIndex]!;
            var answer = answers[n];
            if (blank)
            {
                var block = blocks[blockIndex];
                shape.Heights[0] = block.SpacingBeforePoints + answer.Heights[0] + block.SpacingAfterPoints;
                inputs[inputIndex].Lines = shape.Heights;
                continue;
            }
            for (var l = 0; l < shape.Heights.Length; l++) { shape.Heights[l] = answer.Heights[l]; }
            inputs[inputIndex].Lines = shape.Heights;
            inputs[inputIndex].Trailing = answer.Trailing;
        }

        var plan = PagePlanClient.Plan(engineHandle, contentHeight, splitTables, noteBands, inputs, band.BandPoints);

        var blockPlacements = new List<PagedBlock>(plan.Placements.Count);
        foreach (var placed in plan.Placements)
        {
            var hasRows = blocks[placed.Block].Kind == FlowBlockKind.Table && blocks[placed.Block].Table is not null;
            blockPlacements.Add(new PagedBlock(placed.Block, placed.Page, placed.Top, placed.Height,
                RowRangeStart: hasRows ? placed.RowStart : null, RowRangeCount: hasRows ? placed.RowCount : null,
                Flowed: placed.Flowed));
        }
        FlowedTables? flowed = null;
        if (plan.RowSegments.Count > 0)
        {
            flowed = new FlowedTables();
            foreach (var segment in plan.RowSegments) { flowed.Add(segment); }
            foreach (var line in plan.CellLines) { flowed.Add(line); }
        }
        var linePlacements = new List<PagedLine>(plan.Lines.Count);
        foreach (var placed in plan.Lines)
        {
            var shape = shapes[placed.Block]!;
            linePlacements.Add(new PagedLine(placed.Block, placed.Line, placed.Page, placed.Top,
                shape.Heights[placed.Line], shape.FirstChars[placed.Line], shape.Lengths[placed.Line]));
        }

        var pageSectionIndex = new int[plan.PageCount];
        for (var p = 0; p < pageSectionIndex.Length; p++) { pageSectionIndex[p] = plan.Pages[p].Section; }

        return new PageLayoutResult
        {
            PageCount = plan.PageCount,
            PageContentWidthPoints = contentWidth,
            PageContentHeightPoints = contentHeight,
            Band = band,
            Placements = blockPlacements,
            Lines = linePlacements,
            PageSectionIndex = pageSectionIndex,
            SplitTables = splitTables,
            Flowed = flowed,
            SplitTableCount = plan.SplitTableCount,
            CarriedTableCount = plan.CarriedTableCount,
            DroppedBreakCount = plan.DroppedBreakCount,
        };
    }

    private static double[] PadRows(double[] heights, int rowCount)
    {
        var padded = new double[rowCount];
        Array.Copy(heights, padded, Math.Min(heights.Length, rowCount));
        return padded;
    }

    /// <summary>The paged layout with the reader's table split preference applied — what every
    /// caller that draws or counts sheets goes through. The engine's plan settles tables itself, so
    /// there is one round; the counts are what the plan reported (`Pushed` = tables carried whole to
    /// the next page, `Oversized` = tables placed as row-bounded pieces).</summary>
    public static (PageLayoutResult Layout, int Rounds, int Pushed, int Oversized) BuildWithTableSettle(
        IReadOnlyList<FlowBlock> blocks, BlockPageMarkers.Markers markers, PageGeometry geometry,
        IntPtr engineHandle, bool headersOn, bool footersOn, bool splitTablesDefault,
        ImageBlockRenderer? imageRenderer = null, IReadOnlyDictionary<int, double>? noteBands = null)
    {
        var layout = Build(blocks, markers, geometry, engineHandle, headersOn, footersOn, splitTablesDefault,
            imageRenderer, noteBands);
        return (layout, 1, layout.CarriedTableCount, layout.SplitTableCount);
    }

    /// <summary>E2c-2b: a line's PLACED height — the document's own <see cref="LineHeightRule"/>
    /// applied to Avalonia's measured <paramref name="naturalHeight"/> (`TextLine.Height`, real
    /// font metrics), THEN floored by the line-grid pitch when one is declared
    /// (`OfficeTextBuilder.bodyParagraphStyle`'s own rule: the grid is a floor under whatever the
    /// paragraph's own rule already produced, never a cap — applying it after, not instead of, the
    /// rule is what lets an `.exact` line still be raised by a grid taller than it). Replaces
    /// E2c-2's "known gap" — `.exact`/`.atLeast` now apply their own point values instead of being
    /// silently treated as `.multiple(1.0)`.</summary>
    private static double EffectiveLineHeight(double naturalHeight, LineHeightRule lineHeight, double? lineGridPitchPoints)
    {
        var applied = lineHeight.Apply(naturalHeight);
        return lineGridPitchPoints is > 0 ? Math.Max(applied, lineGridPitchPoints.Value) : applied;
    }

    /// <summary>A non-text block's own height in points, at <paramref name="widthPoints"/> — a
    /// simple declared/estimated height (E2c-2's own scope line: exact table-row and picture-wrap
    /// geometry inside a page is that unit's job).</summary>
    public static double NonTextBlockHeightPoints(FlowBlock block, double widthPoints, ImageBlockRenderer? imageRenderer = null,
        bool splitTables = true)
    {
        switch (block.Kind)
        {
            case FlowBlockKind.Rule:
                return block.SpacingBeforePoints + 1 + block.SpacingAfterPoints;

            case FlowBlockKind.Image:
                // S8-A2 (C2): the SAME clamp-to-column-preserve-aspect function
                // ImageBlockRenderer.Draw uses — see that method's own doc for why using the raw
                // declared height here (unclamped) let a wide picture's reserved space disagree
                // with what it was actually drawn at, overlapping the next block (finding F3).
                var (_, imageHeight) = PictureGeometry.Measure(block, widthPoints);
                return block.SpacingBeforePoints + imageHeight + block.SpacingAfterPoints;

            case FlowBlockKind.Table:
                // E2c-2 Part B: replaced the crude rows*20 placeholder with the SAME per-row
                // estimate TableSettle.BuildLaidOutTables uses for its row geometry — the whole-
                // table height and the settle loop's row-by-row heights must agree, or a table
                // that "fits" here could still be judged as overrunning by the settle loop against
                // a different number, and the two would never converge.
                var heights = block.Table is null
                    ? Array.Empty<double>()
                    : TableSettle.EstimateRowHeights(block.Table, widthPoints, imageRenderer, splitTables);
                var estimate = heights.Sum();
                return block.SpacingBeforePoints + estimate + block.SpacingAfterPoints;

            default:
                throw new ArgumentOutOfRangeException(nameof(block), block.Kind, "text blocks go through PlaceTextLines");
        }
    }

    /// <summary>Builds a text block's <see cref="TextLayout"/> at <paramref name="widthPoints"/>
    /// (the document's own points — no zoom), or null for a block with no visible runs. Public so
    /// PageModePainter can rebuild the SAME shape at pixel/zoom scale — width and font size are
    /// always scaled by the identical factor there, so the two layouts wrap into the IDENTICAL
    /// number of lines with the same character ranges; only the units differ. Carries no line-grid
    /// floor of its own — that is a PLACEMENT concern (<see cref="EffectiveLineHeight"/>), not a
    /// layout-shape concern, since the grid never changes which characters land on which line.</summary>
    public static TextLayout? BuildPointsTextLayout(FlowBlock block, double widthPoints)
        => BuildTextLayout(block, widthPoints, fontScale: 1.0);

    /// <summary>The shared build both <see cref="BuildPointsTextLayout"/> (pagination, fontScale
    /// folds in only the document's own sizes) and PageModePainter (drawing, fontScale folds in
    /// `96/72 * zoomFactor` too) call — kept in ONE place so the two callers can never diverge in
    /// how a run's font/alignment/decoration is resolved, only in the linear scale applied to
    /// width and font size together (which preserves line breaks identically).</summary>
    internal static TextLayout? BuildTextLayout(FlowBlock block, double widthAtScale, double fontScale)
    {
        if (block.Runs.Count == 0 || block.Runs.TrueForAll(r => r.Text.Length == 0)) { return null; }

        var text = string.Concat(block.Runs.ConvertAll(r => r.Text));
        var overrides = new List<ValueSpan<TextRunProperties>>(block.Runs.Count);
        var cursor = 0;
        var maxFontSize = 12.0 * fontScale;
        foreach (var run in block.Runs)
        {
            var length = run.Text.Length;
            if (length > 0)
            {
                var fontSize = run.FontSizePoints * fontScale;
                if (fontSize > maxFontSize) { maxFontSize = fontSize; }
                overrides.Add(new ValueSpan<TextRunProperties>(cursor, length,
                    FlowRun.PropertiesFor(run, fontSize, new SolidColorBrush(run.Foreground))));
            }
            cursor += length;
        }

        // E2c-2: NO forced `lineHeight:` here — the constant `*1.25` this used to pass invented a
        // line height instead of measuring one. Omitting it lets Avalonia report each TextLine's
        // OWN natural height (its real font metrics for whatever runs land on that line), which
        // PlaceTextLines/EffectiveLineHeight then scale by the document's own multiple and floor by
        // the line grid — the SAME two-step OfficeTextBuilder.bodyParagraphStyle performs
        // (`lineHeightMultiple` against the natural height; the grid only when no explicit rule).
        return new TextLayout(text, DefaultTypeface, maxFontSize, Brushes.Black, block.Alignment,
            TextWrapping.Wrap, maxWidth: Math.Max(1, widthAtScale),
            letterSpacing: block.LetterSpacingPoints * fontScale, textStyleOverrides: overrides);
    }
}
