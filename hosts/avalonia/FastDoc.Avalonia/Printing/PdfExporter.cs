using System;
using Avalonia;
using FastDoc.Avalonia.Rendering;
using SkiaSharp;

namespace FastDoc.Avalonia.Printing;

/// <summary>
/// S5-C: turns any document this reader opens into a PDF file — VECTOR now, not the S4/E6 raster
/// bitmap-per-page it shipped with. Office documents drive <see cref="FlowDocumentView"/>'s page
/// mode (<see cref="FlowDocumentView.ExportPageCount"/>/ExportPageWidthPx/ExportPageHeightPx/
/// ExportPageTopPx, thin pass-throughs onto the one <see cref="Paging.PageModePainter"/> instance
/// the view already owns), and markdown/text (no declared page geometry) is cut into fixed A4
/// pages by scroll offset — one traversal drives both the screen and the PDF, never a second paint
/// implementation.
///
/// The S4/E6 shape hosted a <see cref="Avalonia.Controls.Window"/> per export purely so a real
/// compositor existed to capture a frame FROM. That capture step is GONE: this unit draws straight
/// onto the <see cref="SKCanvas"/> an <see cref="SKDocument"/> page hands out
/// (<see cref="SkiaPageCanvas"/>), through the SAME <see cref="FlowDocumentView.RenderCore"/> the
/// screen calls — so no Window, no headless-vs-real-platform branch, and no
/// Dispatcher/CaptureRenderedFrame trap to work around (<see cref="Measure"/>/<see cref="Arrange"/>
/// on a Control were already proven window-free by the S4 code this replaced, which called both
/// before ever constructing its Window). <see cref="Rendering.FlowDocumentView"/>,
/// <see cref="Rendering.TableGridRenderer"/> and <see cref="Rendering.ImageBlockRenderer"/> paint
/// through <see cref="IPageCanvas"/> now instead of a raw <see cref="Avalonia.Media.DrawingContext"/>
/// — see that interface's own doc for why, and <see cref="AvaloniaPageCanvas"/> for the screen path
/// this refactor left unchanged.
///
/// TEXT is real: <see cref="SkiaPageCanvas.DrawTextLine"/> walks each drawn <see
/// cref="Avalonia.Media.TextFormatting.TextLine"/>'s own shaped runs and calls
/// <see cref="SKCanvas.DrawText(string, float, float, SKTextAlign, SKFont, SKPaint)"/> against the
/// SAME bundled Noto Sans KR OTF the screen uses as its CJK fallback — see that class's own doc for
/// why one embedded font covers Latin and Hangul/Hanja both, and what is synthetic (bold, italic,
/// underline/strikethrough) rather than a second font file. IMAGES still rasterize (a picture was
/// never a text-stream candidate either way).
/// </summary>
public static class PdfExporter
{
    private const double PointsToPixels = 96.0 / 72.0;
    private const double PixelsToPoints = 72.0 / 96.0;

    // Fallback page size for a document with no declared page geometry (markdown/text) — A4. The
    // fallback path re-uses FlowDocumentView's OWN fixed flow margins (24px left/right, 12px top)
    // rather than re-deriving a second 54pt-margin scheme here.
    private const double FallbackPageWidthPoints = 595.0;
    private const double FallbackPageHeightPoints = 842.0;

    /// <param name="PageCount">Pages written to the output file.</param>
    /// <param name="Vector">True — every page's text is drawn as real glyph runs against a real
    /// PDF font object (S5-C); only embedded pictures stay raster.</param>
    /// <param name="FontEmbedded">True — the bundled Noto Sans KR OTF backs every glyph SkiaSharp
    /// writes, so the PDF carries a real font object instead of a bitmap.</param>
    public sealed record Result(int PageCount, bool Vector, bool FontEmbedded);

    /// <summary>Opens <paramref name="documentPath"/> through the same door the GUI/--extract/
    /// --sheets paths use, paginates it, and writes a PDF to <paramref name="outPath"/>. Throws on
    /// an open failure (the caller's headless/GUI entry decides how to report that) rather than
    /// returning a sentinel pageCount, matching RenderTreeLoader's own "IsOk" contract instead of
    /// inventing a second one here.</summary>
    public static Result ExportPdf(string documentPath, string outPath)
    {
        var loaded = RenderTreeLoader.Load(documentPath);
        using var handle = loaded.Handle;
        if (!loaded.IsOk)
        {
            throw new InvalidOperationException($"[{loaded.Error?.Kind}] {loaded.Error?.Message}");
        }

        var view = new FlowDocumentView();
        view.SetTree(loaded.Tree);
        if (handle is not null) { view.SetHandle(handle); }
        view.SetZipSource(loaded.DocumentPath, System.IO.Path.GetExtension(documentPath));
        return WritePdf(view, outPath);
    }

    /// <summary>The part of <see cref="ExportPdf"/> after the tree is already loaded — paginate an
    /// already-<c>SetTree</c>'d view and write it to <paramref name="outPath"/>. Kept separate from
    /// <see cref="ExportPdf"/> (which owns RenderTreeLoader.Load and handle disposal) purely for
    /// readability.</summary>
    private static Result WritePdf(FlowDocumentView view, string outPath)
    {
        view.PageMode = view.HasPageGeometry; // export always uses page mode when the document has one, independent of the GUI's own flow-by-default (E6)

        double pageWidthPx;
        double pageHeightPx;
        int pageCount;

        if (view.HasPageGeometry)
        {
            // Page-mode geometry is independent of the size Measure is given (PageModePainter
            // derives it from the document's OWN declared paper) — Measure only needs calling once
            // so MeasureOverride's EnsurePageLayout() populates the layout this export reads next.
            view.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            pageWidthPx = view.ExportPageWidthPx ?? FallbackPageWidthPoints * PointsToPixels;
            pageHeightPx = view.ExportPageHeightPx ?? FallbackPageHeightPoints * PointsToPixels;
            pageCount = Math.Max(1, view.ExportPageCount);
        }
        else
        {
            pageWidthPx = FallbackPageWidthPoints * PointsToPixels;
            pageHeightPx = FallbackPageHeightPoints * PointsToPixels;
            view.Measure(new Size(pageWidthPx, pageHeightPx));
            view.Arrange(new Rect(0, 0, pageWidthPx, pageHeightPx));
            pageCount = Math.Max(1, (int)Math.Ceiling(view.ContentHeight / pageHeightPx));
        }

        var pageWidthPt = pageWidthPx * PixelsToPoints;
        var pageHeightPt = pageHeightPx * PixelsToPoints;

        using var stream = new SKFileWStream(outPath);
        using var document = SKDocument.CreatePdf(stream)
            ?? throw new InvalidOperationException($"SKDocument.CreatePdf could not open {outPath}");
        using var typeface = SkiaPageCanvas.LoadBundledTypeface();

        // ONE SkiaPageCanvas for the WHOLE export, not one per page (S5-C2) — its image cache
        // (keyed by source-byte hash, see that class's own doc) must survive across pages for a
        // repeated picture (a page background, a letterhead) to be encoded once and dedup to a
        // single PDF XObject instead of once per page.
        SkiaPageCanvas? surface = null;
        for (var pageIndex = 0; pageIndex < pageCount; pageIndex++)
        {
            // Arrange every page (not just once) — page mode's own content does not depend on the
            // Arrange size (PageModePainter measures paper from the document itself), but the flow
            // fallback's virtualization window (EnsureEstimates) reads Bounds, so this keeps both
            // paths on the identical call sequence the screen uses every frame.
            view.Arrange(new Rect(0, 0, pageWidthPx, pageHeightPx));
            view.ScrollOffset = view.HasPageGeometry ? view.ExportPageTopPx(pageIndex) : pageIndex * pageHeightPx;

            var canvas = document.BeginPage((float)pageWidthPt, (float)pageHeightPt);
            if (surface is null) { surface = new SkiaPageCanvas(canvas, typeface); }
            else { surface.SetCanvas(canvas); }
            surface.CurrentPageNumber = pageIndex + 1; // 1-based, for FMD_AVALONIA_PDF_TRACE
            view.RenderCore(surface);
            document.EndPage();
        }

        document.Close();
        return new Result(pageCount, Vector: true, FontEmbedded: true);
    }
}
