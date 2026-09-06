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
public readonly record struct PagedBlock(int BlockIndex, int PageIndex, double LocalTopPoints, double HeightPoints,
    int? RowRangeStart = null, int? RowRangeCount = null);

/// <summary>E2c-1b: one TEXT LINE's placement — the granularity PageBandLayoutDelegate.swift
/// shifts at on macOS. A text block ("paragraph"/"heading"/"listItem"/... FlowDocumentBuilder
/// treats as one flow entry) contributes one entry per <see cref="Avalonia.Media.TextFormatting.
/// TextLayout.TextLines"/> line — so a paragraph that does not fit its starting page contributes
/// SOME lines to page N and the rest to page N+1, each at PageModePainter's own page-local y.
/// <see cref="LineIndex"/> is the line's position within its OWN block's TextLayout (rebuilt at
/// draw time at pixel scale — see PageModePainter's own doc for why the two layouts wrap
/// identically) — never a global line number.</summary>
public readonly record struct PagedLine(int BlockIndex, int LineIndex, int PageIndex, double LocalTopPoints, double HeightPoints);

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
}

/// <summary>
/// E2c-1b: assigns every FlowBlock to a page at LINE granularity for text — a paragraph that will
/// not finish on the page it starts on is split at the TextLine boundary and continues flush at
/// the top of the next page's content area, mirroring `PageBandLayoutDelegate.swift`'s own line
/// shift (the macOS reader never moves a line partway; it shifts the WHOLE remaining line to the
/// next band). Table/image/rule blocks stay BLOCK-atomic — invariant 61's own move-whole rule for
/// a table, extended to every non-text kind — because their row/cell-level settle is E2c-2's job
/// (`fastdoc_office_table_placement`), not this unit's.
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
    private const double BlankParagraphHeightPoints = 14;

    public static PageLayoutResult Build(IReadOnlyList<FlowBlock> blocks, BlockPageMarkers.Markers markers,
        PageGeometry geometry, IntPtr engineHandle, bool headersOn, bool footersOn,
        ISet<int>? forcePushTableBlocks = null, IReadOnlyDictionary<int, SortedSet<int>>? forcedTableRowBreaks = null,
        ImageBlockRenderer? imageRenderer = null)
    {
        var contentWidth = geometry.ContentWidthPoints;
        var contentHeight = geometry.ContentHeightPoints;
        var band = PageBandResolver.Resolve(engineHandle, geometry, contentWidth, headersOn, footersOn,
            separatesPages: true, deskGapPoints: null);

        var blockPlacements = new List<PagedBlock>();
        var linePlacements = new List<PagedLine>();
        var pageIndex = 0;
        var cursor = 0.0;
        // S8-A2 (C3/C5): pageIndex values at which a NEW section's first page begins — page 0 is
        // always section 0 implicitly, so this only records boundaries AFTER it. A section start
        // that lands on the very first block (pageIndex still 0, cursor still 0) is exactly that
        // implicit page-0/section-0 case and is not recorded again.
        var sectionBoundaryPages = new List<int>();

        for (var i = 0; i < blocks.Count; i++)
        {
            var block = blocks[i];
            var sectionStart = i < markers.SectionStart.Length && markers.SectionStart[i];
            var hardBreak = i < markers.PageBreakBefore.Length && markers.PageBreakBefore[i];
            if ((sectionStart || hardBreak) && (pageIndex > 0 || cursor > 0))
            {
                pageIndex++;
                cursor = 0;
                if (sectionStart) { sectionBoundaryPages.Add(pageIndex); }
            }

            var widthForBlock = Math.Max(1, contentWidth - block.IndentPoints);

            if (block.Kind == FlowBlockKind.Text)
            {
                PlaceTextLines(block, i, widthForBlock, contentHeight, geometry.LineGridPitchPoints,
                    linePlacements, ref pageIndex, ref cursor);
                continue;
            }

            // E2c-2 Part B: a table the settle loop decided must move whole starts a fresh page —
            // BEFORE the normal "does it overrun" check below, mirroring `tablesToPush`'s own
            // idempotent re-application (a pushed table sitting at a page top declines to move
            // again, since `cursor == 0` already and this guard only fires when `cursor > 0`).
            if (block.Kind == FlowBlockKind.Table && forcePushTableBlocks is not null
                && forcePushTableBlocks.Contains(i) && cursor > 0)
            {
                pageIndex++;
                cursor = 0;
            }

            if (block.Kind == FlowBlockKind.Table && block.Table is not null
                && forcedTableRowBreaks is not null && forcedTableRowBreaks.TryGetValue(i, out var breaks) && breaks.Count > 0)
            {
                PlaceTableRows(block, i, widthForBlock, contentHeight, breaks, blockPlacements, ref pageIndex, ref cursor, imageRenderer);
                continue;
            }

            var height = NonTextBlockHeightPoints(block, widthForBlock, imageRenderer);
            if (ShouldPushToFreshPage(cursor, height, contentHeight))
            {
                pageIndex++;
                cursor = 0;
            }
            var rowRangeCount = block.Kind == FlowBlockKind.Table ? block.Table?.Rows.Count : null;
            blockPlacements.Add(new PagedBlock(i, pageIndex, cursor, height,
                RowRangeStart: rowRangeCount is null ? null : 0, RowRangeCount: rowRangeCount));
            cursor += height;
        }

        var pageCount = pageIndex + 1;
        var pageSectionIndex = new int[pageCount];
        var section = 0;
        var boundaryCursor = 0;
        for (var p = 0; p < pageCount; p++)
        {
            while (boundaryCursor < sectionBoundaryPages.Count && sectionBoundaryPages[boundaryCursor] == p)
            {
                section++;
                boundaryCursor++;
            }
            pageSectionIndex[p] = section;
        }

        return new PageLayoutResult
        {
            PageCount = pageCount,
            PageContentWidthPoints = contentWidth,
            PageContentHeightPoints = contentHeight,
            Band = band,
            Placements = blockPlacements,
            Lines = linePlacements,
            PageSectionIndex = pageSectionIndex,
        };
    }

    /// <summary>E2c-2 Part B: places ONE table block as several row-bounded PIECES — each entry in
    /// <paramref name="forcedBreaksBeforeRow"/> (row indices from `TableSettle`'s oversized-piece
    /// resolution, all of them `CanBreakAbove`-safe) starts a fresh PagedBlock. A piece flows onto
    /// the CURRENT page whenever it fits the room left there — exactly the ordinary between-page
    /// rule `PlaceTextLines` already applies to a text line — and only starts a fresh page when it
    /// does not (contract §1e's own words: an oversized table is "handed to the reader's ORDINARY
    /// between-page rule, one line at a time, exactly as prose is"). Forcing every piece onto its
    /// OWN new page regardless of fit was tried first and measured: it multiplied a 400-page HWP
    /// manual to 722 sheets, because one huge table's row-boundary pieces (all safe to break, since
    /// the document has no merges) each claimed a whole page it did not need. PageModePainter still
    /// draws the FULL table on its first piece's page only (see that file's own doc for the
    /// disclosed multi-page table drawing gap) — this method only owns where pages break, not what
    /// gets painted.</summary>
    private static void PlaceTableRows(FlowBlock block, int blockIndex, double widthPoints, double contentHeight,
        SortedSet<int> forcedBreaksBeforeRow, List<PagedBlock> output, ref int pageIndex, ref double cursor,
        ImageBlockRenderer? imageRenderer = null)
    {
        var model = block.Table!;
        var rowHeights = TableSettle.EstimateRowHeights(model, widthPoints, imageRenderer);
        cursor += block.SpacingBeforePoints;

        var pieceStartRow = 0;
        for (var r = 0; r <= model.Rows.Count; r++)
        {
            if (r < model.Rows.Count && !forcedBreaksBeforeRow.Contains(r)) { continue; }

            var pieceHeight = 0.0;
            for (var k = pieceStartRow; k < r; k++) { pieceHeight += rowHeights[k]; }

            // NOTE: deliberately NOT ShouldPushToFreshPage here (unlike the other three placement
            // sites in this file) — TableSettle's own host-fallback resolver (ResolveViaHost)
            // re-derives each piece's row geometry from THIS method's own placement output on every
            // settle round, and pushing an already-oversized piece to a fresh page here changes the
            // geometry that resolver reads BEFORE it has registered a break for it, which starved a
            // 10-row/260pt fixture of the extra row-boundary break its 4-row/104pt piece needed to
            // shrink under one page (measured regression: PagingTests.
            // A_table_taller_than_one_page_splits_at_a_row_boundary). A piece this loop places is
            // always EITHER already page-width-safe (`CanBreakAbove`-bounded) or is about to be
            // re-evaluated by the very next settle round, so the narrower guard is kept here.
            if (cursor > 0 && cursor + pieceHeight > contentHeight + 0.01 && pieceHeight <= contentHeight)
            {
                pageIndex++;
                cursor = 0;
            }

            output.Add(new PagedBlock(blockIndex, pageIndex, cursor, pieceHeight,
                RowRangeStart: pieceStartRow, RowRangeCount: r - pieceStartRow));
            cursor += pieceHeight;
            pieceStartRow = r;
        }
        cursor += block.SpacingAfterPoints;
    }

    /// <summary>E2c-2 Part B: the outer settle loop — mirrors `DocumentWindowController.
    /// settlePagedTablesFully()`'s table half (footnote bands are out of this unit's scope, see
    /// measurements.md). Re-lays out up to <see cref="TableSettle.MaxRounds"/> times, feeding each
    /// round's `fastdoc_office_table_placement` answer back into the NEXT layout pass, and stops
    /// the moment a round changes nothing (idempotent, same as Swift's own loop). Counts (rounds
    /// actually run, pushed-table count, oversized-piece count) are returned for `--sheets`'s own
    /// reporting line — sheets must only be counted AFTER this returns (contract §2.7).</summary>
    public static (PageLayoutResult Layout, int Rounds, int Pushed, int Oversized) BuildWithTableSettle(
        IReadOnlyList<FlowBlock> blocks, BlockPageMarkers.Markers markers, PageGeometry geometry,
        IntPtr engineHandle, bool headersOn, bool footersOn, bool splitTablesDefault,
        ImageBlockRenderer? imageRenderer = null)
    {
        var layout = Build(blocks, markers, geometry, engineHandle, headersOn, footersOn, imageRenderer: imageRenderer);
        var pushed = new Dictionary<long, (double Height, double TopInset)>();
        var oversized = new Dictionary<long, long>();
        var rounds = 0;

        for (; rounds < TableSettle.MaxRounds; rounds++)
        {
            var pitch = layout.PageContentHeightPoints + layout.Band.BandPoints;
            var laidOut = TableSettle.BuildLaidOutTables(blocks, layout.Placements, markers.TableKeepsWhole,
                pitch, geometry.ContentWidthPoints, imageRenderer);
            var result = TableSettle.Resolve(engineHandle, laidOut, layout.PageContentHeightPoints,
                layout.Band.BandPoints, leadingBand: 0, splitTablesDefault, pushed, oversized);
            if (!result.Changed) { break; }

            pushed = new Dictionary<long, (double, double)>(result.Pushed);
            oversized = new Dictionary<long, long>(result.Oversized);
            var (forcePush, forcedBreaks) = TableSettle.ExtractBlockOverrides(pushed.Keys, oversized);
            layout = Build(blocks, markers, geometry, engineHandle, headersOn, footersOn, forcePush, forcedBreaks, imageRenderer);
        }

        var (finalPush, finalBreaks) = TableSettle.ExtractBlockOverrides(pushed.Keys, oversized);
        return (layout, rounds, finalPush.Count, finalBreaks.Values.Sum(b => b.Count));
    }

    /// <summary>Places one text block's lines, mutating <paramref name="pageIndex"/>/<paramref
    /// name="cursor"/> exactly the way the block-level loop above does for a non-text block — a
    /// line that does not fit the REMAINING room on its page (and would fit a fresh page) starts
    /// the next page instead, at local y 0. A blank paragraph (no visible runs) still contributes
    /// exactly one line, matching TextMeasurerPort's own "the terminator still gets a line" rule.</summary>
    private static void PlaceTextLines(FlowBlock block, int blockIndex, double widthPoints, double contentHeight,
        double? lineGridPitchPoints, List<PagedLine> output, ref int pageIndex, ref double cursor)
    {
        var layout = BuildPointsTextLayout(block, widthPoints);
        if (layout is null)
        {
            var blankHeight = block.SpacingBeforePoints + BlankParagraphHeightPoints + block.SpacingAfterPoints;
            if (ShouldPushToFreshPage(cursor, blankHeight, contentHeight))
            {
                pageIndex++;
                cursor = 0;
            }
            output.Add(new PagedLine(blockIndex, 0, pageIndex, cursor, blankHeight));
            cursor += blankHeight;
            return;
        }

        cursor += block.SpacingBeforePoints;
        var lines = layout.TextLines;
        for (var lineIndex = 0; lineIndex < lines.Count; lineIndex++)
        {
            var lineHeight = EffectiveLineHeight(lines[lineIndex].Height, block.LineHeight, lineGridPitchPoints);
            if (ShouldPushToFreshPage(cursor, lineHeight, contentHeight))
            {
                pageIndex++;
                cursor = 0;
            }
            output.Add(new PagedLine(blockIndex, lineIndex, pageIndex, cursor, lineHeight));
            cursor += lineHeight;
        }
        cursor += block.SpacingAfterPoints;
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

    /// <summary>The one push/stay decision every placement loop in this file makes (a text line,
    /// a blank paragraph, a table row-piece, a whole non-text block) — extracted so all four share
    /// ONE answer instead of four copies that can drift. Pushes to a fresh page whenever the item
    /// does not fit the room left on the current page, WITHOUT also requiring that it fit a FULL
    /// fresh page. An item taller than <paramref name="contentHeight"/> still overflows wherever it
    /// starts (a table row's own content is drawn as one atomic block — see <see
    /// cref="TableGridRenderer.Draw"/> — with no mid-row page break), but the amount that overflows
    /// past the page's own bottom edge is exactly <c>itemHeight - (contentHeight - startCursor)</c>
    /// — strictly SMALLER the closer <paramref name="cursor"/> is to 0. A prior version required
    /// <c>itemHeight &lt;= contentHeight</c> too (reasoning: "pushing an oversized item does not
    /// help it fit, so don't bother") — that reasoning ignored the printing pipeline's own PAGE
    /// CLIP: content that lands past a page's bottom edge is not merely visually cropped, it is
    /// never emitted to that page at all (measured: a single-row table cell whose reserved height
    /// grew to ~1.4pt over one full page, starting 575pt into an already-used page, lost ~85% of
    /// its own text to that clip — pushing it to page-top first would have clipped only the ~1.4pt
    /// tail). Pushing an oversized item is therefore never worse than leaving it (cursor stays 0 or
    /// smaller either way) and is often the difference between losing a sliver and losing most of a
    /// block's content.</summary>
    private static bool ShouldPushToFreshPage(double cursor, double itemHeight, double contentHeight) =>
        cursor > 0 && cursor + itemHeight > contentHeight + 0.01;

    /// <summary>A non-text block's own height in points, at <paramref name="widthPoints"/> — a
    /// simple declared/estimated height (E2c-2's own scope line: exact table-row and picture-wrap
    /// geometry inside a page is that unit's job).</summary>
    public static double NonTextBlockHeightPoints(FlowBlock block, double widthPoints, ImageBlockRenderer? imageRenderer = null)
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
                    : TableSettle.EstimateRowHeights(block.Table, widthPoints, imageRenderer);
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
                var typeface = new Typeface(
                    run.FontFamily ?? "Inter",
                    run.Italic ? FontStyle.Italic : FontStyle.Normal,
                    run.Bold ? FontWeight.Bold : FontWeight.Normal);
                TextDecorationCollection? decorations = null;
                if (run.Underline) { decorations = TextDecorations.Underline; }
                else if (run.Strike) { decorations = TextDecorations.Strikethrough; }
                overrides.Add(new ValueSpan<TextRunProperties>(cursor, length,
                    new GenericTextRunProperties(typeface, fontSize, textDecorations: decorations,
                        foregroundBrush: new SolidColorBrush(run.Foreground))));
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
            TextWrapping.Wrap, maxWidth: Math.Max(1, widthAtScale), textStyleOverrides: overrides);
    }
}
