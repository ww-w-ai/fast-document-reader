using Avalonia;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Media.TextFormatting;

namespace FastDoc.Avalonia.Printing;

/// <summary>
/// S5-C: the minimal drawing surface every block renderer (<see cref="Rendering.FlowDocumentView"/>,
/// <see cref="Rendering.TableGridRenderer"/>, <see cref="Rendering.ImageBlockRenderer"/>,
/// <see cref="Paging.PageModePainter"/>) paints through, instead of each one calling
/// <see cref="DrawingContext"/> directly. Two implementations exist: <see cref="AvaloniaPageCanvas"/>
/// (the screen — a thin pass-through onto a real DrawingContext, so on-screen pixels are unchanged)
/// and <see cref="SkiaPageCanvas"/> (PDF export — draws straight onto an SkiaSharp SKCanvas inside
/// an SKDocument page, so <c>--pdf</c> writes real vector text/lines/fills instead of rasterizing a
/// captured frame). The surface is deliberately primitive (fill/stroke a rect, a line, an image, one
/// text line or a whole TextLayout) — anything a renderer needs beyond that (column widths, cell
/// borders, table geometry) stays exactly where it already lived, in the renderer itself.
/// </summary>
public interface IPageCanvas
{
    /// <summary>Fills <paramref name="rect"/> with <paramref name="fill"/> when given, and strokes
    /// it with <paramref name="stroke"/> at <paramref name="strokeThicknessPx"/> when given — either
    /// or both may be null/zero, mirroring <see cref="DrawingContext.DrawRectangle(IBrush?, IPen?, Rect)"/>'s
    /// own "either half is optional" shape instead of splitting fill and stroke into two calls.</summary>
    void DrawRect(Rect rect, Color? fill, Color? stroke, double strokeThicknessPx);

    /// <summary>A single straight stroke, <paramref name="thicknessPx"/> wide, solid-colored — table
    /// borders, band rules, and the flow view's horizontal-rule blocks all reduce to this.</summary>
    void DrawLine(Point a, Point b, Color color, double thicknessPx);

    /// <summary>Draws an already-decoded picture (the SAME <see cref="Bitmap"/> instance
    /// <see cref="Rendering.ImageBlockRenderer"/> already resolves and caches once per resource id)
    /// scaled into <paramref name="destRect"/>. A picture stays a raster image in the PDF either
    /// way — only TEXT is the vector target of S5-C — but <paramref name="sourceBytes"/>/
    /// <paramref name="sourceMimeType"/> (S5-C2: the document's OWN encoded bytes, when
    /// <see cref="Rendering.ImageBlockRenderer"/> still has them) let a PDF-writing implementation
    /// skip a lossy/lossless re-encode entirely for a format it can embed as-is (a JPEG source
    /// embeds as JPEG, `/DCTDecode`, unchanged) — the screen implementation ignores both and draws
    /// <paramref name="bitmap"/> exactly as before (pixels unchanged).</summary>
    void DrawImage(Bitmap bitmap, byte[]? sourceBytes, string? sourceMimeType, Rect destRect);

    /// <summary>Draws every line of <paramref name="layout"/> starting at <paramref name="origin"/> —
    /// the whole-block case (a paragraph, a table cell's content), used wherever the reader already
    /// called <c>TextLayout.Draw(context, origin)</c> as one shot.</summary>
    void DrawTextLayout(TextLayout layout, Point origin);

    /// <summary>Draws exactly one already-built <see cref="TextLine"/> at <paramref name="origin"/> —
    /// the piece-by-piece case <see cref="Paging.PageModePainter"/> needs when a block's lines are
    /// split across pages and only SOME of a block's lines belong to the page being drawn right now.</summary>
    void DrawTextLine(TextLine line, Point origin);
}
