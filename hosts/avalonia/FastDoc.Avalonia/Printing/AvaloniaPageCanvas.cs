using Avalonia;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Media.TextFormatting;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Printing;

/// <summary>The screen implementation of <see cref="IPageCanvas"/> — every call forwards straight
/// onto the real <see cref="DrawingContext"/> a Control's Render override was handed, with the same
/// Pen/Brush shapes the renderers built inline before this abstraction existed (S5-C). Nothing here
/// changes what appears on screen; it exists only so the SAME renderer code also runs against
/// <see cref="SkiaPageCanvas"/> for PDF export.</summary>
public sealed class AvaloniaPageCanvas : IPageCanvas
{
    private readonly DrawingContext _context;

    public AvaloniaPageCanvas(DrawingContext context) => _context = context;

    public void DrawRect(Rect rect, Color? fill, Color? stroke, double strokeThicknessPx)
    {
        IBrush? brush = fill is { } f ? new SolidColorBrush(f) : null;
        IPen? pen = stroke is { } s ? new Pen(new SolidColorBrush(s), strokeThicknessPx) : null;
        _context.DrawRectangle(brush, pen, rect);
    }

    public void DrawLine(Point a, Point b, Color color, double thicknessPx)
        => _context.DrawLine(new Pen(new SolidColorBrush(color), thicknessPx), a, b);

    public void DrawImage(Bitmap bitmap, byte[]? sourceBytes, string? sourceMimeType, Rect destRect)
        => _context.DrawImage(bitmap, destRect); // screen path: source bytes/MIME are a PDF-export-only concern

    /// <summary>Avalonia's own <c>TextLayout.Draw</c> unless a line holds an italic run drawn by a face
    /// with no slant of its own (Hangul/Hanja fallback) — then each line goes through
    /// <see cref="DrawTextLine"/>, which shears that run (<see cref="SyntheticItalic"/>).</summary>
    public void DrawTextLayout(TextLayout layout, Point origin)
    {
        var lines = layout.TextLines;
        var needsSynthesis = false;
        foreach (var line in lines)
        {
            if (SyntheticItalic.NeedsSynthesis(line)) { needsSynthesis = true; break; }
        }
        if (!needsSynthesis) { layout.Draw(_context, origin); return; }

        var y = origin.Y;
        foreach (var line in lines)
        {
            DrawTextLine(line, new Point(origin.X, y));
            y += line.Height;
        }
    }

    public void DrawTextLine(TextLine line, Point origin)
    {
        if (SyntheticItalic.NeedsSynthesis(line)) { SyntheticItalic.DrawTextLine(_context, line, origin); }
        else { line.Draw(_context, origin); }
    }
}
