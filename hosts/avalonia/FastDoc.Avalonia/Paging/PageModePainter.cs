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

    public PageModePainter(ImageBlockRenderer imageRenderer)
    {
        _imageRenderer = imageRenderer;
    }

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
        BlockPageMarkers.Markers markers, bool masterPageFurniture = true)
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

            var sectionIndex = pageIndex < layout.PageSectionIndex.Count ? layout.PageSectionIndex[pageIndex] : 0;
            var isFirstPageOfSection = pageIndex == 0
                || (pageIndex - 1 < layout.PageSectionIndex.Count && layout.PageSectionIndex[pageIndex - 1] != sectionIndex);
            var pageNumber = pageIndex + 1;
            // S9-B3 batch 2: View > Master Page Furniture off suppresses the running header/footer
            // band entirely — mirrors PageViewOptions.header/footer deriving from `outline` on
            // macOS (turning the furniture off leaves the content flowing with nothing drawn in
            // the margin it would otherwise have reserved). Resolve() is skipped outright rather
            // than resolved-then-hidden, since it walks the tree per page.
            var headerText = masterPageFurniture
                ? HeaderFooterText.Resolve(headerCandidates, byId, sectionIndex, isFirstPageOfSection, pageNumber, layout.PageCount)
                : null;
            var footerText = masterPageFurniture
                ? HeaderFooterText.Resolve(footerCandidates, byId, sectionIndex, isFirstPageOfSection, pageNumber, layout.PageCount)
                : null;

            if (!string.IsNullOrWhiteSpace(headerText))
            {
                DrawBandText(surface, headerText!, deskX + marginLeftPx, localTop + marginTopPx * 0.35, contentWidthPx, zoomFactor);
            }
            if (!string.IsNullOrWhiteSpace(footerText))
            {
                var footerY = localTop + pageHeightPx - marginBottomPx * 0.65;
                DrawBandText(surface, footerText!, deskX + marginLeftPx, footerY, contentWidthPx, zoomFactor);
            }

            var left = deskX + marginLeftPx;

            if (blocksByPage.TryGetValue(pageIndex, out var placements))
            {
                foreach (var placement in placements)
                {
                    if (placement.BlockIndex < 0 || placement.BlockIndex >= blocks.Count) { continue; }
                    var block = blocks[placement.BlockIndex];
                    var top = contentTop + placement.LocalTopPoints * PointsToPixels * zoomFactor;
                    var repeatsHeader = placement.BlockIndex < markers.TableRepeatsHeader.Length
                        && markers.TableRepeatsHeader[placement.BlockIndex];
                    DrawNonTextBlock(surface, block, placement, left, top, contentWidthPx, zoomFactor, repeatsHeader);
                }
            }

            if (linesByPage.TryGetValue(pageIndex, out var pageLines))
            {
                DrawTextLinesOnPage(surface, blocks, pageLines, left, contentTop, contentWidthPx, zoomFactor);
            }
        }
    }

    private void DrawNonTextBlock(IPageCanvas surface, FlowBlock block, PagedBlock placement, double left, double top,
        double columnWidthPx, double zoomFactor, bool repeatsHeader)
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
                    rowsToDraw, imageRenderer: _imageRenderer);
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
        List<PagedLine> pageLines, double left, double contentTop, double columnWidthPx, double zoomFactor)
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
            var maxWidth = Math.Max(20, columnWidthPx - indentPx);
            var pixelLayout = GetOrBuildPixelLayout(blockIndex, block, maxWidth, zoomFactor);
            if (pixelLayout is null) { continue; } // a blank paragraph's single "line" has no TextLayout to draw

            foreach (var line in linesForBlock)
            {
                if (line.LineIndex < 0 || line.LineIndex >= pixelLayout.TextLines.Count) { continue; }
                var top = contentTop + line.LocalTopPoints * PointsToPixels * zoomFactor;
                surface.DrawTextLine(pixelLayout.TextLines[line.LineIndex], new Point(left + indentPx, top));
            }
        }
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

    private static void DrawBandText(IPageCanvas surface, string text, double left, double top, double width, double zoomFactor)
    {
        var fontSizePx = 9.0 * zoomFactor * PointsToPixels;
        var layout = new TextLayout(text, DefaultTypeface, fontSizePx, BandTextBrush, TextAlignment.Center,
            TextWrapping.NoWrap, maxWidth: width);
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
        if (chosen.Count == 0) { return null; }

        var texts = new List<string>();
        foreach (var candidate in chosen)
        {
            CollectText(candidate.Node, byId, texts, new HashSet<ulong>(), pageNumber, totalPages);
        }
        var joined = string.Join(" ", texts.Where(t => !string.IsNullOrWhiteSpace(t)));
        return string.IsNullOrWhiteSpace(joined) ? null : joined;
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
}
