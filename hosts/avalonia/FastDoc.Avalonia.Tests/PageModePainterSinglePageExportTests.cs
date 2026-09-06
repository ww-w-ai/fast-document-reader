using System.Linq;
using System.Text.Json;
using SkiaSharp;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Paging;
using FastDoc.Avalonia.Printing;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// PageModePainter.Draw's own scroll-virtualization buffer is sized to the WHOLE viewport
/// (Math.Max(200, viewportHeightPx)) — meant for smooth on-screen scroll pre-paint. But
/// PdfExporter.WritePdf arranges the view to EXACTLY one page's height and calls RenderCore once
/// per SkiaPageCanvas page, so that buffer would otherwise open wide enough to also draw the NEXT
/// page's content onto the current page's canvas (positioned past the page's own bottom edge, but
/// still recorded). When the surface passed to Draw is a SkiaPageCanvas, only the page named by
/// its CurrentPageNumber is drawn at all — every other pageIndex is skipped outright, not merely
/// positioned off-canvas.
///
/// This test proves it WITHOUT the real engine dylib or a PDF file: it builds a real
/// SkiaPageCanvas backed by a raster SKBitmap sized to cover BOTH pages' vertical extent (so a
/// regression — page 2's content being drawn during page 1's export call — would land inside this
/// bitmap's own bounds and be observable as non-transparent pixels), calls Draw with
/// CurrentPageNumber = 1, and asserts the region where page 2's own paper rectangle would be
/// painted is untouched (still the cleared, fully-transparent background).
/// </summary>
public class PageModePainterSinglePageExportTests
{
    // SkiaPageCanvas.LoadBundledTypeface() reads the bundled font through Avalonia's AssetLoader,
    // which needs the platform initialized once per test run — same headless setup PagingTests.cs
    // uses for its TextLayout-backed assertions.
    public PageModePainterSinglePageExportTests() => AvaloniaHeadlessSetup.EnsureReady();

    private const string TwoPageTreeJson = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": {
          "format": "docx",
          "rootNodeId": 0,
          "defaultBodyFontSize": 12,
          "documentPaper": {
            "widthPoints": 200,
            "heightPoints": 200,
            "margins": { "top": 20, "right": 20, "bottom": 20, "left": 20 }
          }
        },
        "nodes": [
          { "id": 0, "parentId": null, "children": [1, 2], "type": "document", "data": {} },
          {
            "id": 1, "parentId": 0, "children": [],
            "type": "paragraph",
            "data": { "text": "page one text", "style": {}, "pagination": { "keepWithNext": false, "pageBreakBefore": false, "hidesPageNumber": false } }
          },
          {
            "id": 2, "parentId": 0, "children": [],
            "type": "paragraph",
            "data": { "text": "page two text", "style": {}, "pagination": { "keepWithNext": false, "pageBreakBefore": true, "hidesPageNumber": false } }
          }
        ]
      }
    }
    """;

    [Fact]
    public void Single_page_export_never_paints_the_next_pages_paper_rectangle()
    {
        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(TwoPageTreeJson)!;
        Assert.True(envelope.IsOk);
        var tree = envelope.Ok!.Value.Deserialize<RenderTree>()!;
        var geometry = PageGeometry.FromDocument(tree)!;
        var blocks = FlowDocumentBuilder.Build(tree);
        var markers = BlockPageMarkers.Compute(tree);
        var layout = PageLayout.Build(blocks, markers, geometry, System.IntPtr.Zero, headersOn: false, footersOn: false);
        Assert.Equal(2, layout.PageCount); // sanity: this really is a two-page document

        var painter = new PageModePainter(new ImageBlockRenderer());
        var pageWidthPx = painter.PageWidthPx(geometry, 1.0);
        var pageHeightPx = painter.PageHeightPx(geometry, 1.0);
        var page1TopPx = painter.PageTopPx(geometry, 0, 1.0);
        var page2TopPx = painter.PageTopPx(geometry, 1, 1.0); // > pageHeightPx: where the bug used to paint

        // Bitmap tall enough to cover BOTH pages' paper rectangles, so a regression has somewhere
        // to actually land instead of being clipped away by the bitmap's own bounds (which would
        // make this test pass for the wrong reason).
        var bitmapHeight = (int)System.Math.Ceiling(page2TopPx + pageHeightPx) + 10;
        using var bitmap = new SKBitmap((int)System.Math.Ceiling(pageWidthPx), bitmapHeight);
        using var canvas = new SKCanvas(bitmap);
        canvas.Clear(SKColors.Transparent);
        using var typeface = SkiaPageCanvas.LoadBundledTypeface();
        var surface = new SkiaPageCanvas(canvas, typeface) { CurrentPageNumber = 1 }; // 1-based: page index 0

        painter.Draw(surface, blocks, tree, layout, geometry, zoomFactor: 1.0,
            viewportWidthPx: pageWidthPx, viewportHeightPx: pageHeightPx,
            scrollOffsetPx: page1TopPx, markers);

        // SkiaPageCanvas applies ONE canvas-wide 72/96 scale in its constructor (every call site
        // draws in the SAME pixel space the screen uses; this class converts to PDF points) — so
        // a pixel-space Y this test computed (page2TopPx) lands at that Y times 72/96 in the
        // actual device pixels this bitmap stores. Page 2's paper rectangle (a filled+stroked
        // Rect, PaperColor/PaperBorderColor — see PageModePainter.Draw) would have painted SOLID
        // pixels there. Sample its top-left corner, a few pixels in so it lands inside the fill
        // rather than exactly on the stroke's antialiased edge.
        const double PixelsToPoints = 72.0 / 96.0; // mirrors SkiaPageCanvas's own private constant
        var sampleX = 5;
        var sampleY = (int)(page2TopPx * PixelsToPoints) + 5;
        var pixel = bitmap.GetPixel(sampleX, sampleY);

        Assert.Equal(0, pixel.Alpha); // still the cleared background — page 2 was never drawn here
    }
}
