using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using Avalonia;
using Avalonia.Media;
using Avalonia.Media.TextFormatting;
using Avalonia.Utilities;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Printing;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Paging;

/// <summary>
/// E2c-1b: draws a <see cref="PageLayoutResult"/> as a stack of sheets — white paper, a visible
/// desk gap between them, the document's own margins, and every block/line placed where
/// <see cref="PageLayout"/> put it. Reuses <see cref="ImageBlockRenderer"/> and
/// <see cref="TableGridRenderer"/> as-is (both already work in pixel space keyed off a block's own
/// declared points) for Rule/Image/Table — still block-atomic, per E2c-2's own scope.
///
/// TEXT is drawn at LINE granularity now: <see cref="PageLayout.Build"/> measures each paragraph's
/// TextLines in POINTS (zoom-independent, so pagination never changes with zoom), and this painter
/// rebuilds an EQUIVALENT <see cref="TextLayout"/> at `points * 96/72 * zoomFactor` through the
/// SAME <see cref="PageLayout.BuildTextLayout"/> the pagination pass used — width and font size are
/// scaled by the identical factor, so the two layouts wrap into IDENTICAL line boundaries, and
/// PageLayout's own `LineIndex` picks out the matching <see cref="TextLine"/> to draw here. A block
/// whose lines land on more than one page is therefore drawn as several partial passes — one call
/// per page that shows any of its lines — never re-laid-out per page.
/// </summary>
public sealed class PageModePainter
{
    private const double PointsToPixels = 96.0 / 72.0;
    private const double PageGapPx = 24;

    private static readonly Color PaperColor = Colors.White;
    private static readonly Color PaperBorderColor = Color.FromRgb(0x99, 0x99, 0x99);
    private static readonly Color BandRuleColor = Color.FromRgb(0xcc, 0xcc, 0xcc);
    private static readonly IBrush BandTextBrush = new SolidColorBrush(Color.FromRgb(0x66, 0x66, 0x66));
    private static readonly Typeface DefaultTypeface = new("Inter");

    private readonly ImageBlockRenderer _imageRenderer;
    private readonly Dictionary<int, double[]> _tableRowHeightCache = new();

    /// <summary>Per-block pixel-scale TextLayout cache, keyed by block index — a block redraws
    /// across scroll frames far more often than its zoom factor changes, so rebuilding only when
    /// the cached entry's own zoom disagrees (or the tree/layout was replaced — see
    /// <see cref="InvalidateTextCache"/>) is the whole "줄 높이는 블록 높이 캐시와 함께 캐시" ask.</summary>
    private readonly Dictionary<int, (double Zoom, TextLayout Layout)> _textLayoutCache = new();

    private readonly PinnedObjectPainter _pinnedPainter;

    public PageModePainter(ImageBlockRenderer imageRenderer)
    {
        _imageRenderer = imageRenderer;
        _pinnedPainter = new PinnedObjectPainter(imageRenderer);
    }

    /// <summary>What a layout pass adds to a page beyond its blocks: the pinned objects (read off the
    /// tree once per tree+blocks), each anchored object's page and completed top, and the document's
    /// page-number vetoes / restarts. Rebuilt only when the layout object itself is replaced.</summary>
    private sealed class PageFacts
    {
        public required PinnedObjectSet Pinned { get; init; }
        public required Dictionary<int, List<(PinnedObject Object, double TopPoints)>> AnchoredByPage { get; init; }
    }

    private (RenderTree Tree, object Blocks, PinnedObjectSet Set)? _pinnedCache;
    private (PageLayoutResult Layout, BlockPageMarkers.Markers Markers, PageFacts Facts)? _factsCache;

    private PageFacts FactsFor(RenderTree tree, IReadOnlyList<FlowBlock> blocks, PageLayoutResult layout,
        PageGeometry geometry, BlockPageMarkers.Markers markers)
    {
        if (_factsCache is { } cached && ReferenceEquals(cached.Layout, layout)
            && ReferenceEquals(cached.Markers.NodeId, markers.NodeId)
            && ReferenceEquals(_pinnedCache?.Tree, tree) && ReferenceEquals(_pinnedCache?.Blocks, blocks))
        {
            return cached.Facts;
        }
        if (_pinnedCache is not { } p || !ReferenceEquals(p.Tree, tree) || !ReferenceEquals(p.Blocks, blocks))
        {
            _pinnedCache = (tree, blocks, PinnedObjectSet.Build(tree, blocks));
        }
        var pinned = _pinnedCache!.Value.Set;

        var anchored = new Dictionary<int, List<(PinnedObject, double)>>();
        if (pinned.Anchored.Count > 0)
        {
            var firstLine = new Dictionary<int, PagedLine>();
            foreach (var line in layout.Lines) { firstLine.TryAdd(line.BlockIndex, line); }
            var firstPlacement = new Dictionary<int, PagedBlock>();
            foreach (var placement in layout.Placements) { firstPlacement.TryAdd(placement.BlockIndex, placement); }
            // A table of a columned run has no placement of its own: it is dealt line by line, and the
            // first column it stands in is where it is.
            var firstRegion = new Dictionary<int, ColumnRegion>();
            foreach (var region in layout.ColumnTables) { firstRegion.TryAdd(region.BlockIndex, region); }
            foreach (var obj in pinned.Anchored)
            {
                int page;
                double lineTop, lineHeight;
                if (firstLine.TryGetValue(obj.AnchorBlockIndex, out var line))
                {
                    (page, lineTop, lineHeight) = (line.PageIndex, line.LocalTopPoints, line.HeightPoints);
                }
                else if (firstPlacement.TryGetValue(obj.AnchorBlockIndex, out var block))
                {
                    (page, lineTop, lineHeight) = (block.PageIndex, block.LocalTopPoints, block.HeightPoints);
                }
                else if (firstRegion.TryGetValue(obj.AnchorBlockIndex, out var region))
                {
                    (page, lineTop, lineHeight) = (region.PageIndex, region.TopPoints, region.HeightPoints);
                }
                else { continue; }
                // The line's top in PAPER points: the page body starts a top margin below the sheet's edge.
                var top = obj.Anchor is { } rule
                    ? rule.Top(geometry.MarginTopPoints + lineTop, lineHeight, obj.Height)
                    : obj.Y;
                if (!anchored.TryGetValue(page, out var list)) { anchored[page] = list = new(); }
                list.Add((obj, top));
            }
        }
        var facts = new PageFacts
        {
            Pinned = pinned,
            AnchoredByPage = anchored,
        };
        _factsCache = (layout, markers, facts);
        return facts;
    }

    /// <summary>The master template covering a page, the running head and foot that apply to it and the
    /// number it prints are the engine's answer (the page plan, S5 of docs/plans/pagination-to-engine.md),
    /// read here from <see cref="PageLayoutResult.Sheets"/>; a layout built without the document's
    /// entries carries none, and a page then draws no furniture and prints its own ordinal.</summary>
    private static PageSheet SheetOf(PageLayoutResult layout, int pageIndex) =>
        pageIndex < layout.Sheets.Count ? layout.Sheets[pageIndex] : new PageSheet(pageIndex + 1, false, null, null, null);

    /// <summary>Drops every cached pixel-scale TextLayout — call whenever the tree/PageLayoutResult
    /// this painter draws is replaced (a new document, or a re-paginate), so a stale block index
    /// from the PREVIOUS tree is never drawn against the new one.</summary>
    public void InvalidateTextCache() => _textLayoutCache.Clear();

    public double PageHeightPx(PageGeometry geometry, double zoomFactor) => geometry.PageHeightPoints * PointsToPixels * zoomFactor;
    public double PageWidthPx(PageGeometry geometry, double zoomFactor) => geometry.PageWidthPoints * PointsToPixels * zoomFactor;
    public double PagePitchPx(PageGeometry geometry, double zoomFactor) => PageHeightPx(geometry, zoomFactor) + PageGapPx;

    /// <summary>Total scrollable content height, in pixels — FlowDocumentView-compatible so the
    /// same ScrollOffset/virtualization scheme works for either mode.</summary>
    public double TotalHeightPx(PageGeometry geometry, int pageCount, double zoomFactor) =>
        pageCount <= 0 ? 0 : PageGapPx + pageCount * PagePitchPx(geometry, zoomFactor);

    public double PageTopPx(PageGeometry geometry, int pageIndex, double zoomFactor) =>
        PageGapPx + pageIndex * PagePitchPx(geometry, zoomFactor);

    /// <summary>Which page index sits at pixel <paramref name="yPx"/> — the page-mode analogue of
    /// FlowDocumentView's binary search over its offset table (here a direct division works
    /// because every page has the identical pitch, unlike the flow list's variable block heights).</summary>
    public int PageIndexAt(PageGeometry geometry, double yPx, double zoomFactor)
    {
        var pitch = PagePitchPx(geometry, zoomFactor);
        if (pitch <= 0) { return 0; }
        return Math.Max(0, (int)Math.Floor((yPx - PageGapPx) / pitch));
    }

    public void Draw(IPageCanvas surface, IReadOnlyList<FlowBlock> blocks, RenderTree tree,
        PageLayoutResult layout, PageGeometry geometry, double zoomFactor,
        double viewportWidthPx, double viewportHeightPx, double scrollOffsetPx,
        BlockPageMarkers.Markers markers, bool masterPageFurniture = true, FootnotePlan? footnotes = null)
    {
        var pageWidthPx = PageWidthPx(geometry, zoomFactor);
        var pageHeightPx = PageHeightPx(geometry, zoomFactor);
        var deskX = Math.Max(0, (viewportWidthPx - pageWidthPx) / 2);

        // PdfExporter.WritePdf drives this same Draw through one SkiaPageCanvas per page,
        // arranging the view to EXACTLY one page's height and rendering ONE page per call — the
        // viewport-sized buffer below exists for smooth on-screen scroll pre-paint, and must not
        // apply here: at export size it would open wide enough for the NEXT page's blocks/lines to
        // also be visited and drawn onto the same single-page SKCanvas (positioned past the page's
        // own bottom edge, but still recorded into that page's PDF content stream). A
        // SkiaPageCanvas identifies itself by CurrentPageNumber (PdfExporter sets it before each
        // RenderCore call, 1-based) — when the surface IS one, this is a single-page export call,
        // so the buffer collapses to zero and every OTHER page index is skipped outright rather
        // than merely clipped. AvaloniaPageCanvas (the screen) is not a SkiaPageCanvas, so
        // on-screen scrolling's multi-page pre-paint buffer is unaffected.
        var singlePageIndex = surface is Printing.SkiaPageCanvas skiaExportCanvas
            ? skiaExportCanvas.CurrentPageNumber - 1
            : -1;
        var isSinglePageExport = singlePageIndex >= 0;
        var buffer = isSinglePageExport ? 0.0 : Math.Max(200, viewportHeightPx);

        // Group placements/lines by page once per frame — cheap for the page counts this reader
        // targets (a few hundred), and keeps the per-page loop below ignorant of any other page.
        var blocksByPage = new Dictionary<int, List<PagedBlock>>();
        foreach (var placement in layout.Placements)
        {
            if (!blocksByPage.TryGetValue(placement.PageIndex, out var list))
            {
                list = new List<PagedBlock>();
                blocksByPage[placement.PageIndex] = list;
            }
            list.Add(placement);
        }
        // The tables of a columned run, per page: each column a table reaches is one region.
        var columnTablesByPage = new Dictionary<int, List<ColumnRegion>>();
        foreach (var region in layout.ColumnTables)
        {
            if (!columnTablesByPage.TryGetValue(region.PageIndex, out var regions))
            {
                regions = new List<ColumnRegion>();
                columnTablesByPage[region.PageIndex] = regions;
            }
            regions.Add(region);
        }
        var linesByPage = new Dictionary<int, List<PagedLine>>();
        foreach (var line in layout.Lines)
        {
            if (!linesByPage.TryGetValue(line.PageIndex, out var list))
            {
                list = new List<PagedLine>();
                linesByPage[line.PageIndex] = list;
            }
            list.Add(line);
        }

        // S8-A2 (C3/C5): candidates are collected ONCE (a handful of nodes at most) and RESOLVED
        // per page below — see HeaderFooterText.Resolve's own doc for why extracting one
        // concatenated string for the whole document (the previous shape) drew a first-page
        // header on the cover, a stale page number everywhere, and two different footers stacked
        // on one page (catalog findings F5/F6/F8-F10).
        var headerCandidates = HeaderFooterText.CollectCandidates(tree, "header");
        var footerCandidates = HeaderFooterText.CollectCandidates(tree, "footer");
        var byId = new Dictionary<ulong, RenderNode>(tree.Nodes.Count);
        foreach (var n in tree.Nodes) { byId[n.Id] = n; }

        // What the document pins to its sheets: master-page templates (every page they cover) and
        // anchored objects (the page their carrier paragraph lands on). Resolved once per layout.
        var facts = FactsFor(tree, blocks, layout, geometry, markers);
        // S12-J: the fallback size for a header/footer run that declared no size of its own —
        // the document's own default body size (mirrors FlowDocumentBuilder.Build's identical
        // fallback), never a bare literal.
        var defaultFontSize = tree.Document is { DefaultBodyFontSize: > 0 } doc ? doc.DefaultBodyFontSize : 12.0;

        for (var pageIndex = 0; pageIndex < layout.PageCount; pageIndex++)
        {
            if (isSinglePageExport && pageIndex != singlePageIndex) { continue; }

            var localTop = PageTopPx(geometry, pageIndex, zoomFactor) - scrollOffsetPx;
            if (!isSinglePageExport)
            {
                if (localTop + pageHeightPx < -buffer) { continue; }
                if (localTop > viewportHeightPx + buffer) { break; }
            }

            var paperRect = new Rect(deskX, localTop, pageWidthPx, pageHeightPx);
            surface.DrawRect(paperRect, PaperColor, PaperBorderColor, 1);

            var marginTopPx = geometry.MarginTopPoints * PointsToPixels * zoomFactor;
            var marginLeftPx = geometry.MarginLeftPoints * PointsToPixels * zoomFactor;
            var marginBottomPx = geometry.MarginBottomPoints * PointsToPixels * zoomFactor;
            var contentWidthPx = layout.PageContentWidthPoints * PointsToPixels * zoomFactor;
            var contentTop = localTop + marginTopPx;

            // What the page carries besides its body — which head, foot and master page apply and the
            // number it prints (the document's own counter: a 새 번호 restart renumbers from that page
            // on) — is the plan's answer, not this host's.
            var sheet = SheetOf(layout, pageIndex);
            var pageNumber = sheet.Number;

            // 바탕쪽 first (behind everything): the artwork, the ruled title and the page number a
            // Korean document draws on the sheet itself. View > Master Page Furniture governs it
            // like the running header/footer — off means nothing pinned, nothing reserved.
            if (masterPageFurniture && sheet.Master is { } templateIndex && templateIndex < facts.Pinned.Masters.Count)
            {
                var template = facts.Pinned.Masters[templateIndex];
                foreach (var obj in template.Objects)
                {
                    _pinnedPainter.Draw(surface, obj, obj.Y, paperRect, zoomFactor, pageNumber, layout.PageCount,
                        sheet.NumberHidden);
                }
            }
            // S9-B3 batch 2: View > Master Page Furniture off suppresses the running header/footer
            // band entirely — mirrors PageViewOptions.header/footer deriving from `outline` on
            // macOS (turning the furniture off leaves the content flowing with nothing drawn in
            // the margin it would otherwise have reserved). ResolveStyled() is skipped outright
            // rather than resolved-then-hidden, since it walks the tree per page.
            //
            // S12-J: ResolveStyled replaces the plain-string Resolve() on this draw path — it
            // carries the header/footer paragraph's own declared alignment and each run's own
            // font/size/bold/italic, so DrawBandText paints the document's actual typography
            // instead of a fixed 9pt Inter, always centered (gap.md row "헤더/푸터(러닝 헤더)").
            // Resolve() itself is untouched (S8A2RenderFixesTests/RecursionGuardTests pin its
            // plain-string contract).
            var headerBand = masterPageFurniture && sheet.Header is { } headerAt && headerAt < headerCandidates.Count
                ? HeaderFooterText.ResolveStyled(headerCandidates[headerAt], byId, pageNumber, layout.PageCount, defaultFontSize)
                : null;
            var footerBand = masterPageFurniture && sheet.Footer is { } footerAt && footerAt < footerCandidates.Count
                ? HeaderFooterText.ResolveStyled(footerCandidates[footerAt], byId, pageNumber, layout.PageCount, defaultFontSize)
                : null;

            if (headerBand is not null)
            {
                DrawBandText(surface, headerBand.Value, deskX + marginLeftPx, localTop + marginTopPx * 0.35, contentWidthPx, zoomFactor);
            }
            if (footerBand is not null)
            {
                var footerY = localTop + pageHeightPx - marginBottomPx * 0.65;
                DrawBandText(surface, footerBand.Value, deskX + marginLeftPx, footerY, contentWidthPx, zoomFactor);
            }

            var left = deskX + marginLeftPx;

            facts.AnchoredByPage.TryGetValue(pageIndex, out var anchoredHere);
            if (anchoredHere is not null)
            {
                foreach (var (obj, topPoints) in anchoredHere)
                {
                    if (obj.Content is not PinnedImage) { continue; }
                    _pinnedPainter.Draw(surface, obj, topPoints, paperRect, zoomFactor, pageNumber, layout.PageCount,
                        sheet.NumberHidden);
                }
            }

            if (blocksByPage.TryGetValue(pageIndex, out var placements))
            {
                foreach (var placement in placements)
                {
                    if (placement.BlockIndex < 0 || placement.BlockIndex >= blocks.Count) { continue; }
                    var block = blocks[placement.BlockIndex];
                    var top = contentTop + placement.LocalTopPoints * PointsToPixels * zoomFactor;
                    var repeatsHeader = placement.BlockIndex < markers.TableRepeatsHeader.Length
                        && markers.TableRepeatsHeader[placement.BlockIndex];
                    if (placement.Flowed && layout.Flowed is { } flowedTables && block.Table is { } flowedModel
                        && placement.RowRangeStart is { } flowStart && placement.RowRangeCount is { } flowCount)
                    {
                        var indent = block.IndentPoints * PointsToPixels * zoomFactor;
                        TableGridRenderer.DrawFlowed(surface, flowedModel, placement.BlockIndex, flowedTables, pageIndex,
                            flowStart, flowCount, left + indent, contentTop, Math.Max(40, contentWidthPx - indent),
                            zoomFactor, _imageRenderer, layout.SplitTables);
                        continue;
                    }
                    // A block of a columned run stands in the column the plan dealt it to.
                    var (blockLeft, blockWidth) = ColumnBox(layout, placement.BlockIndex, placement.Column, left, contentWidthPx, zoomFactor);
                    DrawNonTextBlock(surface, block, placement, blockLeft, top, blockWidth, zoomFactor, repeatsHeader, layout.SplitTables);
                }
            }

            if (layout.Flowed is { } columnFlowed && columnTablesByPage.TryGetValue(pageIndex, out var columnRegions))
            {
                foreach (var region in columnRegions)
                {
                    if (region.BlockIndex < 0 || region.BlockIndex >= blocks.Count || blocks[region.BlockIndex].Table is not { } columnModel) { continue; }
                    var columnBlock = blocks[region.BlockIndex];
                    var (columnLeft, columnWidth) = ColumnBox(layout, region.BlockIndex, region.Column, left, contentWidthPx, zoomFactor);
                    var columnIndent = columnBlock.IndentPoints * PointsToPixels * zoomFactor;
                    TableGridRenderer.DrawFlowed(surface, columnModel, region.BlockIndex, columnFlowed,
                        FlowedTables.RegionKey(pageIndex, region.Column), 0, columnModel.Rows.Count, columnLeft + columnIndent,
                        contentTop, Math.Max(40, columnWidth - columnIndent), zoomFactor, _imageRenderer, layout.SplitTables);
                }
            }

            if (linesByPage.TryGetValue(pageIndex, out var pageLines))
            {
                DrawTextLinesOnPage(surface, blocks, pageLines, left, contentTop, contentWidthPx, zoomFactor, layout);
            }

            if (footnotes is { IsEmpty: false }) { DrawFootnotes(surface, footnotes, layout, pageIndex, localTop, geometry, left, contentWidthPx, zoomFactor); }

            // Drawings and text boxes the document anchored at a place in the text, on the page
            // their carrier paragraph lands on — a seal over a signature line, a rule beside a
            // table. Drawn OVER the page's blocks: the carrier is very often a table whose cells are
            // filled, and the tree carries no wrap/z-order, so the order that never hides a stamp is
            // the one chosen. Pictures went under the blocks above (a cover's full-page artwork must
            // not bury its own title).
            if (anchoredHere is not null)
            {
                foreach (var (obj, topPoints) in anchoredHere)
                {
                    if (obj.Content is PinnedImage) { continue; }
                    _pinnedPainter.Draw(surface, obj, topPoints, paperRect, zoomFactor, pageNumber, layout.PageCount,
                        sheet.NumberHidden);
                }
            }
        }
    }

    /// <summary>The notes a page cites, at the foot of its body in the band the page reserved: the
    /// separator rule, then each note's own blocks (the number is part of the body, as the document
    /// wrote it). Mirrors macOS's `FootnotePainter` — the rule sits on the section's own top margin
    /// (or centred in the reader's minimum), runs the declared length or a third of the column, and a
    /// declared line type of 0 draws none.</summary>
    private static void DrawFootnotes(IPageCanvas surface, FootnotePlan plan, PageLayoutResult layout, int pageIndex,
        double pageTopPx, PageGeometry geometry, double left, double columnWidthPx, double zoomFactor)
    {
        if (!plan.NoteBands.TryGetValue(pageIndex, out var bandPoints) || bandPoints <= 0) { return; }
        if (!plan.NotesByPage.TryGetValue(pageIndex, out var numbers) || numbers.Count == 0) { return; }
        var scale = PointsToPixels * zoomFactor;
        var bodyBottom = pageTopPx + (geometry.MarginTopPoints + layout.PageContentHeightPoints) * scale;
        var top = bodyBottom - bandPoints * scale;
        var separator = plan.SeparatorForPage(layout, pageIndex);
        var allowance = FootnoteLayout.SeparatorAllowance(separator);

        if (!(separator is { IsDeclared: true, LineType: 0 }))
        {
            var offset = separator is { IsDeclared: true } ? separator.MarginTopPoints : allowance / 2;
            var y = Math.Round(top + offset * scale) + 0.5;
            var length = separator?.LengthPoints is { } declared
                ? (declared <= 0 || declared * scale >= columnWidthPx ? columnWidthPx : declared * scale)
                : columnWidthPx / 3;
            var color = separator?.Color ?? Color.FromArgb(0x8c, 0x66, 0x66, 0x66);
            surface.DrawLine(new Point(left, y), new Point(left + Math.Min(length, columnWidthPx), y), color,
                Math.Max(separator?.LineWidthPoints ?? 0, 0.5) * scale);
        }

        var cursor = top + allowance * scale;
        var spacing = (separator?.NoteSpacingPoints ?? 0) * scale;
        for (var i = 0; i < numbers.Count; i++)
        {
            if (i > 0) { cursor += spacing; }
            if (!plan.Notes.TryGetValue(numbers[i], out var note)) { continue; }
            cursor = PinnedObjectPainter.DrawBlocks(surface, note.Blocks,
                new Rect(left, cursor, columnWidthPx, 0), scale);
        }
    }

    private void DrawNonTextBlock(IPageCanvas surface, FlowBlock block, PagedBlock placement, double left, double top,
        double columnWidthPx, double zoomFactor, bool repeatsHeader, bool splitTables)
    {
        var blockIndex = placement.BlockIndex;
        var indentPx = block.IndentPoints * PointsToPixels * zoomFactor;
        switch (block.Kind)
        {
            case FlowBlockKind.Rule:
                surface.DrawLine(new Point(left, top), new Point(left + columnWidthPx, top), BandRuleColor, 0.5);
                return;

            case FlowBlockKind.Image:
                _imageRenderer.Draw(surface, block, left, top, columnWidthPx, indentPx);
                return;

            case FlowBlockKind.Table:
                if (block.Table is null) { return; }
                _tableRowHeightCache.TryGetValue(blockIndex, out var cachedRows);
                // E2c-2b: draw exactly THIS piece's rows (RowRangeStart/Count — see PagedBlock's own
                // doc), with the document's declared header row(s) stitched above it when the
                // piece does not already start at row 0 and the table asks for a repeated header
                // (`wire::TableStyle.repeatHeaderRows`). A whole, unsplit table still passes its
                // full 0..rowCount-1 range, so this is not a special case for it.
                var rowsToDraw = BuildRowDrawOrder(block.Table, placement, repeatsHeader);
                var tableHeight = TableGridRenderer.Draw(surface, block.Table, left + indentPx, top,
                    Math.Max(40, columnWidthPx - indentPx), zoomFactor, -1e9, 1e9, cachedRows, out var rowHeights,
                    rowsToDraw, imageRenderer: _imageRenderer, splitTables: splitTables);
                _tableRowHeightCache[blockIndex] = rowHeights;
                _ = tableHeight;
                return;

            default:
                return; // text never reaches here — see DrawTextLinesOnPage
        }
    }

    /// <summary>Null (draw everything, the un-split default) unless this placement names a row
    /// range — then the range itself, with any Header==true rows stitched above it when
    /// <paramref name="repeatsHeader"/> and the range does not already start at row 0 (a piece that
    /// legitimately BEGINS at the header needs no repeat of it).</summary>
    private static List<int>? BuildRowDrawOrder(TableGridModel model, PagedBlock placement, bool repeatsHeader)
    {
        if (placement.RowRangeStart is not { } start || placement.RowRangeCount is not { } count) { return null; }
        if (start == 0 && count == model.Rows.Count) { return null; } // whole table — fast default path
        var order = new List<int>(count + 1);
        if (repeatsHeader && start > 0)
        {
            for (var i = 0; i < model.Rows.Count; i++)
            {
                if (model.Rows[i].Header) { order.Add(i); }
            }
        }
        for (var i = start; i < start + count; i++) { order.Add(i); }
        return order;
    }

    /// <summary>Draws every TEXT line this page shows, grouped by their owning block so each
    /// block's pixel-scale TextLayout is rebuilt (or reused from cache) exactly ONCE per page even
    /// when several of its lines land here — never once per line.</summary>
    private void DrawTextLinesOnPage(IPageCanvas surface, IReadOnlyList<FlowBlock> blocks,
        List<PagedLine> pageLines, double left, double contentTop, double columnWidthPx, double zoomFactor,
        PageLayoutResult layout)
    {
        var byBlock = new Dictionary<int, List<PagedLine>>();
        foreach (var line in pageLines)
        {
            if (!byBlock.TryGetValue(line.BlockIndex, out var list))
            {
                list = new List<PagedLine>();
                byBlock[line.BlockIndex] = list;
            }
            list.Add(line);
        }

        foreach (var (blockIndex, linesForBlock) in byBlock)
        {
            if (blockIndex < 0 || blockIndex >= blocks.Count) { continue; }
            var block = blocks[blockIndex];
            var indentPx = block.IndentPoints * PointsToPixels * zoomFactor;
            // A block of a columned run is measured at its run's column width and drawn in the
            // column the plan dealt each of its lines to.
            var (_, blockColumnWidthPx) = ColumnBox(layout, blockIndex, 0, left, columnWidthPx, zoomFactor);
            var maxWidth = Math.Max(20, blockColumnWidthPx - indentPx);
            var pixelLayout = GetOrBuildPixelLayout(blockIndex, block, maxWidth, zoomFactor);

            // A shaded / ruled paragraph: ONE rectangle per page, from the first of its lines on
            // this page to the last (a paragraph that continues onto the next page is boxed again there).
            var scale = PointsToPixels * zoomFactor;
            if (ParagraphDecor.HasAny(block) && linesForBlock.Count > 0)
            {
                var first = linesForBlock.Min(l => l.LocalTopPoints);
                var last = linesForBlock.Max(l => l.LocalTopPoints + l.HeightPoints);
                var (decorLeft, decorWidth) = ColumnBox(layout, blockIndex, linesForBlock[0].Column, left, columnWidthPx, zoomFactor);
                ParagraphDecor.Draw(surface, block, decorLeft, decorWidth, contentTop + first * scale, (last - first) * scale, scale);
            }
            if (pixelLayout is null) { continue; } // a blank paragraph's single "line" has no TextLayout to draw

            // The first line of a hanging / first-line-indented paragraph starts left or right of the rest.
            var firstLineOffsetPx = block.FirstLineOffsetPoints * scale;
            foreach (var line in linesForBlock)
            {
                if (line.LineIndex < 0 || line.LineIndex >= pixelLayout.TextLines.Count) { continue; }
                var top = contentTop + line.LocalTopPoints * PointsToPixels * zoomFactor;
                var textLine = pixelLayout.TextLines[line.LineIndex];
                var (lineLeft, _) = ColumnBox(layout, blockIndex, line.Column, left, columnWidthPx, zoomFactor);
                if (block.QuoteBarColor is { } barColor)
                {
                    var barX = lineLeft + block.QuoteBarXPoints * PointsToPixels * zoomFactor;
                    surface.DrawRect(new Rect(barX, top, 3, textLine.Height), barColor, null, 0);
                }
                surface.DrawTextLine(textLine, new Point(lineLeft + indentPx + (line.LineIndex == 0 ? firstLineOffsetPx : 0), top));
            }
        }
    }

    /// <summary>Where a block of a columned run stands: the left edge and width, in pixels, of the
    /// column the plan dealt it to (the first column when it named none — the width a block of the
    /// run is measured at). A block outside any run gets the body's own edge and width.</summary>
    private static (double Left, double Width) ColumnBox(PageLayoutResult layout, int blockIndex, int? column,
        double bodyLeft, double bodyWidthPx, double zoomFactor)
    {
        var scale = PointsToPixels * zoomFactor;
        if (blockIndex < layout.BlockColumnRun.Count && layout.BlockColumnRun[blockIndex] is { } run
            && run < layout.ColumnRuns.Count && layout.ColumnRuns[run].Count > 0)
        {
            var columns = layout.ColumnRuns[run];
            var at = column is { } c && c >= 0 && c < columns.Count ? c : 0;
            return (bodyLeft + columns[at].X * scale, columns[at].Width * scale);
        }
        return (bodyLeft, bodyWidthPx);
    }

    private TextLayout? GetOrBuildPixelLayout(int blockIndex, FlowBlock block, double maxWidthPx, double zoomFactor)
    {
        if (_textLayoutCache.TryGetValue(blockIndex, out var cached) && Math.Abs(cached.Zoom - zoomFactor) < 0.0001)
        {
            return cached.Layout;
        }
        // PointsToPixels * zoomFactor is the SAME linear scale PageLayout.Build applied to width
        // when it measured this block in points — see PageLayout.BuildTextLayout's own doc for why
        // that guarantees an identical line count/character split here.
        var fontScale = PointsToPixels * zoomFactor;
        var built = PageLayout.BuildTextLayout(block, maxWidthPx, fontScale);
        if (built is not null) { _textLayoutCache[blockIndex] = (zoomFactor, built); }
        return built;
    }

    /// <summary>S12-J: paints a header/footer band using the DOCUMENT's own declared alignment and
    /// per-run font/size/bold/italic/underline/strike — the same styled-run pattern
    /// <c>TableGridRenderer</c>'s cell-text builder already uses (<c>GenericTextRunProperties</c> +
    /// <c>ValueSpan&lt;TextRunProperties&gt;</c> overrides), so a header/footer with more than one
    /// styled run (e.g. a bold label followed by a plain page number) draws correctly rather than
    /// collapsing to one uniform style. Colour is deliberately NOT taken from the document — kept
    /// at the band's own muted <see cref="BandTextBrush"/>, matching gap.md's item 50 scope
    /// (font/size/alignment only) and keeping the band visually distinct from body text furniture.
    /// A band with no runs (a malformed tree, or every run was empty) draws nothing — callers
    /// already guard on <see cref="HeaderFooterText.ResolveStyled"/> returning null for that case,
    /// this is the defence for an empty-but-non-null band.</summary>
    private static void DrawBandText(IPageCanvas surface, HeaderFooterText.StyledBand band,
        double left, double top, double width, double zoomFactor)
    {
        var sb = new System.Text.StringBuilder();
        var overrides = new List<ValueSpan<TextRunProperties>>();
        var cursor = 0;
        var maxFontSizePx = 9.0 * zoomFactor * PointsToPixels; // bootstrap only — every run below overwrites it
        foreach (var run in band.Runs)
        {
            if (run.Text.Length == 0) { continue; }
            sb.Append(run.Text);
            var fontSizePx = run.FontSizePoints * PointsToPixels * zoomFactor;
            if (fontSizePx > maxFontSizePx) { maxFontSizePx = fontSizePx; }
            var typeface = new Typeface(run.FontFamily ?? "Inter",
                run.Italic ? FontStyle.Italic : FontStyle.Normal,
                run.Bold ? FontWeight.Bold : FontWeight.Normal);
            TextDecorationCollection? decorations = null;
            if (run.Underline) { decorations = TextDecorations.Underline; }
            else if (run.Strike) { decorations = TextDecorations.Strikethrough; }
            var props = new GenericTextRunProperties(typeface, fontSizePx,
                textDecorations: decorations, foregroundBrush: BandTextBrush);
            overrides.Add(new ValueSpan<TextRunProperties>(cursor, run.Text.Length, props));
            cursor += run.Text.Length;
        }
        var text = sb.ToString();
        if (text.Length == 0) { return; }
        var layout = new TextLayout(text, DefaultTypeface, maxFontSizePx, BandTextBrush, band.Alignment,
            TextWrapping.NoWrap, maxWidth: width, textStyleOverrides: overrides);
        surface.DrawTextLayout(layout, new Point(left, top));
    }
}

/// <summary>E2c-1: a rough text preview for a document's running header/footer — concatenates every
/// textRun descendant of the ONE header/footer node <see cref="Resolve"/> selects for a given page,
/// with no per-run styling. This is deliberately NOT the styled build OfficeTextBuilder performs on
/// macOS (that build feeds the engine's band-height query THROUGH the measurer port, never through
/// C# text extraction) — it exists only so the band this painter reserves is not left visually
/// empty when the document declared real header/footer content. Full per-run styling of
/// header/footer text is left to a later unit, same as the table/line-splitting scope lines
/// PageLayout's own doc states.
///
/// S8-A2 (C3/C5): a document can declare SEVERAL header (or footer) nodes — one per
/// <c>HeaderFooterApplicability</c> ("defaultPages"/"firstPage"/"evenPages"/"oddPages", wire.rs) and
/// optionally scoped to one <c>section</c> (an HWP document can give exactly one of many sections
/// its own running head, `section: Option&lt;i64&gt;` — `None` means every page). The PREVIOUS shape
/// here concatenated every one of them into a single string and drew that same string on every
/// page: a docx cover's blank "firstPage" header was overridden by the "defaultPages" header instead
/// of suppressing it (F5), a page number field's literal parsed-at-load text never changed page to
/// page (F6), and an HWP section-scoped footer text got joined onto the SAME footer as the whole
/// document's own page-number footer, so two different numbers appeared stacked on one page
/// (F8-F10). <see cref="Resolve"/> instead picks the ONE node that applies to THIS page's section
/// and position (first page of that section, or not) before collecting any text — the exact
/// selection rule `HeaderFooter.applies_to`/`section` was authored to answer.</summary>
public static class HeaderFooterText
{
    /// <summary>One header/footer node's selector facts, decoded straight off its raw wire
    /// <c>Data</c> — no <c>Model/RenderTreeEnvelope.cs</c> change needed (that file already exposes
    /// every node's `Data` as a plain <see cref="JsonElement"/>), which matters here because that
    /// file is being edited by another S8 worker in parallel.</summary>
    public readonly record struct Candidate(RenderNode Node, string AppliesTo, long? Section);

    /// <summary>Every "header" or "footer" node in the tree, decoded once — cheap to keep across
    /// the whole page-drawing loop (there are only ever a handful, one per section/applicability
    /// combination the document actually declared), unlike re-scanning all of
    /// <see cref="RenderTree.Nodes"/> per page the way the single-string shape used to.</summary>
    public static List<Candidate> CollectCandidates(RenderTree tree, string nodeType)
    {
        var candidates = new List<Candidate>();
        foreach (var node in tree.Nodes)
        {
            if (node.Type != nodeType) { continue; }
            // S8-A2 (C3): decoded through the typed Model.HeaderFooterPayload (added additively to
            // RenderTreeEnvelope.cs once that file was free of the parallel B2 edit) rather than
            // reading raw JsonElement properties by hand.
            var payload = node.AsHeaderFooter;
            candidates.Add(new Candidate(node, payload?.AppliesTo ?? "defaultPages", payload?.Section));
        }
        return candidates;
    }

    /// <summary>Picks the header/footer text for ONE page: candidates scoped to a DIFFERENT section
    /// are dropped first (an HWP section's own running head never leaks onto another section's
    /// pages — the exact defect measured in invariant 176's own doc for a different field). Among
    /// what is left, the section's OPENING page prefers an explicit "firstPage" declaration — even
    /// an EMPTY one, which is how docx represents "no header on the title page" (`w:titlePg`) — and
    /// only falls back to "defaultPages" when the document declared no first-page variant at all.
    /// Every other page uses "defaultPages" (or, failing that, whatever is left that is not itself
    /// scoped to the first page). A "page"/"numPages" field inside a selected node's text is
    /// substituted with THIS page's own 1-based number/total — see <see cref="CollectText"/>.</summary>
    public static string? Resolve(List<Candidate> candidates, Dictionary<ulong, RenderNode> byId,
        int sectionIndex, bool isFirstPageOfSection, int pageNumber, int totalPages)
    {
        var chosen = SelectChosen(candidates, sectionIndex, isFirstPageOfSection);
        if (chosen is null) { return null; }

        var texts = new List<string>();
        foreach (var candidate in chosen)
        {
            CollectText(candidate.Node, byId, texts, new HashSet<ulong>(), pageNumber, totalPages);
        }
        var joined = string.Join(" ", texts.Where(t => !string.IsNullOrWhiteSpace(t)));
        return string.IsNullOrWhiteSpace(joined) ? null : joined;
    }

    /// <summary>The section/first-page selection rule <see cref="Resolve"/>'s own doc describes,
    /// factored out so <see cref="ResolveStyled"/> (S12-J) picks the identical node(s) rather than
    /// a second copy of the rule drifting from this one. Returns null for "draw nothing on this
    /// page" (no candidate in this section, or an explicit empty first-page declaration) — the
    /// same case both callers already treat as null.</summary>
    private static List<Candidate>? SelectChosen(List<Candidate> candidates, int sectionIndex, bool isFirstPageOfSection)
    {
        var inSection = candidates.Where(c => c.Section is null || c.Section == sectionIndex).ToList();
        if (inSection.Count == 0) { return null; }

        List<Candidate> chosen;
        if (isFirstPageOfSection)
        {
            var firstPage = inSection.Where(c => c.AppliesTo == "firstPage").ToList();
            chosen = firstPage.Count > 0 ? firstPage : inSection.Where(c => c.AppliesTo == "defaultPages").ToList();
        }
        else
        {
            chosen = inSection.Where(c => c.AppliesTo == "defaultPages").ToList();
            if (chosen.Count == 0) { chosen = inSection.Where(c => c.AppliesTo != "firstPage").ToList(); }
        }
        // An explicit first-page match with no visible text (docx's blank w:titlePg header) is a
        // deliberate "draw nothing on this page" — not a signal to fall back to the default band.
        return chosen.Count == 0 ? null : chosen;
    }

    private static void CollectText(RenderNode node, Dictionary<ulong, RenderNode> byId, List<string> texts,
        HashSet<ulong> visiting, int pageNumber, int totalPages)
    {
        if (!visiting.Add(node.Id)) { return; } // cycle: node.Id is already an ancestor on this path
        if (node.Type == "textRun")
        {
            // S8-A2 (C3): `wire::TextRun.page_number_field` ("page"/"numPages") names a run that
            // stands in for a LIVE page-number field rather than literal text — substituted with
            // THIS page's own number so it actually changes page to page (catalog finding F6),
            // instead of the field's value at whatever page the document happened to declare it on.
            if (node.Data.ValueKind == JsonValueKind.Object
                && node.Data.TryGetProperty("pageNumberField", out var field) && field.ValueKind == JsonValueKind.String)
            {
                texts.Add(field.GetString() == "numPages" ? totalPages.ToString() : pageNumber.ToString());
            }
            else
            {
                var tr = node.AsTextRun;
                if (tr is not null && tr.Text.Length > 0) { texts.Add(tr.Text); }
            }
        }
        foreach (var childId in node.Children)
        {
            if (byId.TryGetValue(childId, out var child)) { CollectText(child, byId, texts, visiting, pageNumber, totalPages); }
        }
        visiting.Remove(node.Id);
    }

    // -----------------------------------------------------------------------------------------
    // S12-J: styled resolution — the SAME node selection as Resolve()/CollectText above, but
    // carrying each run's own font/size/bold/italic/underline/strike and the header/footer
    // paragraph's own declared alignment, instead of collapsing everything to a bare string.
    // Kept as a SEPARATE path (not a Resolve() overload) so the plain-string contract
    // S8A2RenderFixesTests/RecursionGuardTests already pin stays untouched.
    // -----------------------------------------------------------------------------------------

    /// <summary>One styled run inside a resolved header/footer band — the wire style fields
    /// <see cref="Model.CharacterStyleWire"/> carries, already resolved to a font family and a
    /// points-valued size (never null; falls back to the document's own default body size the same
    /// way <c>FlowDocumentBuilder.CollectRuns</c> does) so the painter never re-derives a
    /// fallback.</summary>
    public readonly record struct BandRun(
        string Text, string? FontFamily, double FontSizePoints, bool Bold, bool Italic, bool Underline, bool Strike);

    /// <summary>A resolved header/footer band: the paragraph's own alignment (falling back to
    /// Center — the band's prior fixed default — only when the document declared none) plus every
    /// styled run in citation order.</summary>
    public readonly record struct StyledBand(TextAlignment Alignment, List<BandRun> Runs);

    /// <summary>The styled counterpart of <see cref="Resolve"/> — same page/section selection
    /// (<see cref="SelectChosen"/>), but returns typography instead of a bare string. Null under
    /// the identical conditions <see cref="Resolve"/> returns null for (nothing selected for this
    /// page, or every selected run's text is empty/whitespace).</summary>
    public static StyledBand? ResolveStyled(List<Candidate> candidates, Dictionary<ulong, RenderNode> byId,
        int sectionIndex, bool isFirstPageOfSection, int pageNumber, int totalPages, double defaultFontSize)
        => StyleChosen(SelectChosen(candidates, sectionIndex, isFirstPageOfSection), byId, pageNumber, totalPages,
            defaultFontSize);

    /// <summary>The styled band of the ONE entry the page plan chose for a page (S5 of
    /// docs/plans/pagination-to-engine.md): which entry applies is the engine's decision, this only
    /// reads its text and typography. Null when the entry has no visible text.</summary>
    public static StyledBand? ResolveStyled(Candidate chosen, Dictionary<ulong, RenderNode> byId, int pageNumber,
        int totalPages, double defaultFontSize)
        => StyleChosen(new List<Candidate> { chosen }, byId, pageNumber, totalPages, defaultFontSize);

    private static StyledBand? StyleChosen(List<Candidate>? chosen, Dictionary<ulong, RenderNode> byId, int pageNumber,
        int totalPages, double defaultFontSize)
    {
        if (chosen is null) { return null; }

        var runs = new List<BandRun>();
        var alignment = TextAlignment.Center; // the band's own prior fixed default, kept when undeclared
        var alignmentSet = false;
        foreach (var candidate in chosen)
        {
            CollectStyledRuns(candidate.Node, byId, runs, new HashSet<ulong>(), pageNumber, totalPages,
                defaultFontSize, ref alignment, ref alignmentSet);
        }
        return runs.Exists(r => !string.IsNullOrWhiteSpace(r.Text)) ? new StyledBand(alignment, runs) : null;
    }

    private static void CollectStyledRuns(RenderNode node, Dictionary<ulong, RenderNode> byId, List<BandRun> runs,
        HashSet<ulong> visiting, int pageNumber, int totalPages, double defaultFontSize,
        ref TextAlignment alignment, ref bool alignmentSet)
    {
        if (!visiting.Add(node.Id)) { return; } // cycle: node.Id is already an ancestor on this path

        // The FIRST paragraph/heading's own alignment wins — a header/footer is overwhelmingly one
        // paragraph, and this mirrors CollectText's own "first thing found governs" shape.
        if (!alignmentSet)
        {
            var style = node.Type switch
            {
                "paragraph" => node.AsParagraph?.Style,
                "heading" => node.AsHeading?.Style,
                _ => null,
            };
            if (style is not null)
            {
                alignment = AlignmentFrom(style.Alignment);
                alignmentSet = true;
            }
        }

        if (node.Type == "textRun")
        {
            string? text = null;
            Model.CharacterStyleWire? charStyle = null;
            if (node.Data.ValueKind == JsonValueKind.Object
                && node.Data.TryGetProperty("pageNumberField", out var field) && field.ValueKind == JsonValueKind.String)
            {
                // Same live-field substitution as CollectText — a page-number run keeps ITS OWN
                // declared style (a bold page number stays bold), only the text is substituted.
                text = field.GetString() == "numPages" ? totalPages.ToString() : pageNumber.ToString();
                charStyle = node.AsTextRun?.Style;
            }
            else
            {
                var tr = node.AsTextRun;
                if (tr is not null && tr.Text.Length > 0) { text = tr.Text; charStyle = tr.Style; }
            }
            if (text is not null)
            {
                var family = charStyle is { FontFamilies.Count: > 0 } ? charStyle.FontFamilies[0] : charStyle?.DeclaredFontName;
                runs.Add(new BandRun(text, family, charStyle?.FontSizePoints ?? defaultFontSize,
                    charStyle?.Bold ?? false, charStyle?.Italic ?? false,
                    charStyle?.Underline is not null, charStyle?.Strike ?? false));
            }
        }

        foreach (var childId in node.Children)
        {
            if (byId.TryGetValue(childId, out var child))
            {
                CollectStyledRuns(child, byId, runs, visiting, pageNumber, totalPages, defaultFontSize,
                    ref alignment, ref alignmentSet);
            }
        }
        visiting.Remove(node.Id);
    }

    private static TextAlignment AlignmentFrom(string? wire) => wire switch
    {
        "left" => TextAlignment.Left,
        "right" => TextAlignment.Right,
        "center" => TextAlignment.Center,
        "justified" => TextAlignment.Justify,
        // "natural"/null: the document declared no alignment for this header/footer paragraph —
        // keep the band's PRIOR fixed default (Center) rather than guessing Left, so a document
        // that never touches this contract renders identically to before S12-J.
        _ => TextAlignment.Center,
    };
}
