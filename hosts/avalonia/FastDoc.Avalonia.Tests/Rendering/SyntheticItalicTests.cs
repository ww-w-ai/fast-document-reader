using System.Collections.Generic;
using System.Linq;
using Avalonia;
using Avalonia.Media;
using Avalonia.Media.Immutable;
using Avalonia.Media.TextFormatting;
using Avalonia.Utilities;
using FastDoc.Avalonia.Printing;
using FastDoc.Avalonia.Rendering;
using SkiaSharp;

namespace FastDoc.Avalonia.Tests.Rendering;

/// <summary>An italic run of any script slants (Rendering/SyntheticItalic.cs): Hangul falls back to a
/// face with no italic, and Avalonia resets that run's style to Normal, so the intent rides on the
/// foreground brush. Covers the PDF canvas (real ink measured), the screen decision (never a double
/// slant) and the screen draw (the shear reaches the drawing context).</summary>
public class SyntheticItalicTests
{
    public SyntheticItalicTests() => AvaloniaHeadlessSetup.EnsureReady();

    private static FlowRun Run(bool italic) => new("한", null, 12, false, italic, false, false, Colors.Black);

    // ---- the marker -------------------------------------------------------------------------

    [Fact]
    public void An_italic_run_carries_the_marker_on_its_brush_and_keeps_its_colour()
    {
        var props = FlowRun.PropertiesFor(Run(true) with { Foreground = Colors.Red }, 16,
            new ImmutableSolidColorBrush(Colors.Red));

        Assert.IsType<ItalicInkBrush>(props.ForegroundBrush);
        Assert.Equal(Colors.Red, ((ISolidColorBrush)props.ForegroundBrush!).Color);
    }

    [Fact]
    public void An_upright_run_carries_no_marker()
    {
        var props = FlowRun.PropertiesFor(Run(false), 16, new ImmutableSolidColorBrush(Colors.Black));

        Assert.IsNotType<ItalicInkBrush>(props.ForegroundBrush);
        Assert.False(SyntheticItalic.Intended(props));
    }

    [Fact]
    public void The_marker_alone_is_enough_when_Avalonia_has_reset_the_style_to_Normal()
    {
        // What a Hangul fallback run's properties look like after shaping.
        var fallback = new GenericTextRunProperties(new Typeface("Noto Sans KR"), 16,
            foregroundBrush: new ItalicInkBrush(new ImmutableSolidColorBrush(Colors.Black)));

        Assert.True(SyntheticItalic.Intended(fallback));
    }

    // ---- the screen decision: slant exactly once ----------------------------------------------

    private static TextLayout LayoutOf(string text, TextRunProperties props)
        => new(text, new Typeface("Inter"), 16, Brushes.Black,
            textStyleOverrides: new List<ValueSpan<TextRunProperties>> { new(0, text.Length, props) });

    [Fact]
    public void A_face_with_no_slant_of_its_own_is_synthesized()
    {
        // Normal style + marker: the shape of a fallback run (headless glyph face = BareMinimum, no italic).
        var props = new GenericTextRunProperties(new Typeface("Inter"), 16,
            foregroundBrush: new ItalicInkBrush(new ImmutableSolidColorBrush(Colors.Black)));
        var line = LayoutOf("한글", props).TextLines[0];

        Assert.True(SyntheticItalic.NeedsSynthesis(line));
    }

    [Fact]
    public void A_face_Avalonia_already_slants_is_not_slanted_twice()
    {
        var props = FlowRun.PropertiesFor(Run(true), 16, new ImmutableSolidColorBrush(Colors.Black));
        var line = LayoutOf("ab", props).TextLines[0];
        var face = ((ShapedTextRun)line.TextRuns[0]).GlyphRun.GlyphTypeface;

        // The headless face is simulated oblique for an Italic request, i.e. already slanted.
        Assert.True(face.Style != FontStyle.Normal || (face.FontSimulations & FontSimulations.Oblique) != 0);
        Assert.False(SyntheticItalic.NeedsSynthesis(line));
    }

    [Fact]
    public void An_upright_run_is_never_synthesized()
    {
        var props = FlowRun.PropertiesFor(Run(false), 16, new ImmutableSolidColorBrush(Colors.Black));

        Assert.False(SyntheticItalic.NeedsSynthesis(LayoutOf("한글", props).TextLines[0]));
    }

    // ---- the screen draw -----------------------------------------------------------------------

    [Fact]
    public void The_shear_keeps_the_baseline_and_moves_higher_points_right()
    {
        var m = SyntheticItalic.ShearAboutBaseline(baselineY: 20);

        Assert.Equal(new Point(5, 20), m.Transform(new Point(5, 20)));
        var top = m.Transform(new Point(5, 0));
        Assert.Equal(5 + 20 * SyntheticItalic.Slant, top.X, 6);
        Assert.Equal(0, top.Y, 6);
    }

    [Fact]
    public void The_screen_canvas_pushes_the_shear_for_a_synthesized_run_and_not_for_an_upright_one()
    {
        var italic = new GenericTextRunProperties(new Typeface("Inter"), 16,
            foregroundBrush: new ItalicInkBrush(new ImmutableSolidColorBrush(Colors.Black)));
        var upright = new GenericTextRunProperties(new Typeface("Inter"), 16,
            foregroundBrush: new ImmutableSolidColorBrush(Colors.Black));

        Assert.Single(ShearsPushed(LayoutOf("한글", italic)));
        Assert.Empty(ShearsPushed(LayoutOf("한글", upright)));
    }

    private static List<Matrix> ShearsPushed(TextLayout layout)
    {
        var group = new DrawingGroup();
        using (var context = group.Open())
        {
            new AvaloniaPageCanvas(context).DrawTextLayout(layout, new Point(0, 0));
        }
        var found = new List<Matrix>();
        void Walk(Drawing d)
        {
            if (d is DrawingGroup g)
            {
                if (g.Transform is { } t && t.Value.M21 != 0) { found.Add(t.Value); }
                foreach (var child in g.Children) { Walk(child); }
            }
        }
        Walk(group);
        return found;
    }

    // ---- the PDF canvas: real ink -------------------------------------------------------------

    /// <summary>Horizontal ink centroid of the top third minus that of the bottom third: about zero
    /// for upright glyphs, positive when the glyphs lean right.</summary>
    private static double Lean(SKBitmap bitmap)
    {
        double CentroidX(int y0, int y1)
        {
            double sum = 0, weight = 0;
            for (var y = y0; y < y1; y++)
            {
                for (var x = 0; x < bitmap.Width; x++)
                {
                    var ink = 255 - bitmap.GetPixel(x, y).Red;
                    sum += ink * x;
                    weight += ink;
                }
            }
            return weight == 0 ? 0 : sum / weight;
        }
        var (top, bottom) = (bitmap.Height / 3, 2 * bitmap.Height / 3);
        return CentroidX(0, top) - CentroidX(bottom, bitmap.Height);
    }

    private static double PdfCanvasLean(TextRunProperties props)
    {
        using var typeface = SkiaPageCanvas.LoadBundledTypeface();
        using var bitmap = new SKBitmap(160, 160);
        using var skCanvas = new SKCanvas(bitmap);
        skCanvas.Clear(SKColors.White);
        var canvas = new SkiaPageCanvas(skCanvas, typeface);
        var layout = new TextLayout("I", new Typeface("Inter"), 96, Brushes.Black,
            textStyleOverrides: new List<ValueSpan<TextRunProperties>> { new(0, 1, props) });
        canvas.DrawTextLayout(layout, new Point(40, 0));
        skCanvas.Flush();
        return Lean(bitmap);
    }

    [Fact]
    public void The_PDF_canvas_slants_a_run_whose_style_Avalonia_reset_to_Normal()
    {
        var upright = new GenericTextRunProperties(new Typeface("Inter"), 96,
            foregroundBrush: new ImmutableSolidColorBrush(Colors.Black));
        var markedOnly = new GenericTextRunProperties(new Typeface("Inter"), 96,
            foregroundBrush: new ItalicInkBrush(new ImmutableSolidColorBrush(Colors.Black)));

        var flat = PdfCanvasLean(upright);
        var slanted = PdfCanvasLean(markedOnly);

        Assert.True(slanted > flat + 5, $"upright lean {flat:F1}px, marked-only lean {slanted:F1}px");
    }
}
