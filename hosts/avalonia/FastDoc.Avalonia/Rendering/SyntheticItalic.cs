using Avalonia;
using Avalonia.Media;
using Avalonia.Media.Immutable;
using Avalonia.Media.TextFormatting;

namespace FastDoc.Avalonia.Rendering;

/// <summary>
/// An italic run of ANY script slants, whether or not the face that ends up drawing it has an
/// italic. A Latin run asks Avalonia for Inter Italic (or an oblique simulation of Inter) and
/// gets one. A Hangul/Hanja run is shaped by a FALLBACK face (the bundled Noto Sans KR, or the
/// platform's Korean font), and Avalonia builds that fallback typeface WITHOUT the requested
/// style: the shaped run comes back with <c>Properties.Typeface.Style == Normal</c> and a glyph
/// typeface with no <see cref="FontSimulations.Oblique"/>, so the run draws upright (measured on
/// the PDF path: <c>TextRunProperties</c> of a fallback run is a fresh
/// <c>GenericTextRunProperties</c> over the fallback family, style Normal). Korean fonts ship no
/// italic face, so the slant has to be synthesized, as the macOS reader does
/// (<c>FontSubstitutionResolver.syntheticItalicObliqueness</c>).
///
/// The italic INTENT must therefore survive the fallback. The foreground brush is the one
/// property Avalonia copies across it unchanged, so an italic run's brush is an
/// <see cref="ItalicInkBrush"/> (still a plain solid colour to every consumer). The two canvases
/// read the intent back with <see cref="Intended"/>: <see cref="Printing.SkiaPageCanvas"/> skews
/// every italic run (its one bundled font has no italic), and the screen canvas calls
/// <see cref="DrawTextLine"/>, which shears ONLY a run whose glyph face has neither a real italic
/// nor an Avalonia oblique simulation — so a face that already slants is never slanted twice.
/// </summary>
internal static class SyntheticItalic
{
    /// <summary>Horizontal shear per unit of height above the baseline (about 14 degrees), shared by
    /// the screen and PDF canvases so a page reads the same on both.</summary>
    public const double Slant = 0.25;

    /// <summary>The brush an italic run is drawn with: <paramref name="brush"/> as an
    /// <see cref="ItalicInkBrush"/> when it is a solid colour, otherwise unchanged.</summary>
    public static IBrush Mark(IBrush brush) => brush is ISolidColorBrush solid ? new ItalicInkBrush(solid) : brush;

    /// <summary>True when the run's properties ask for italics, by style or by the carried marker.</summary>
    public static bool Intended(TextRunProperties? props)
        => props is not null
           && (props.ForegroundBrush is ItalicInkBrush || props.Typeface.Style is FontStyle.Italic or FontStyle.Oblique);

    /// <summary>True when <paramref name="run"/> asks for italics but its glyph face does not slant
    /// by itself (no italic style, no Avalonia oblique simulation).</summary>
    public static bool NeedsSynthesis(ShapedTextRun run)
    {
        if (!Intended(run.Properties)) { return false; }
        var face = run.GlyphRun.GlyphTypeface;
        return face.Style == FontStyle.Normal && (face.FontSimulations & FontSimulations.Oblique) == 0;
    }

    /// <summary>True when any run of <paramref name="line"/> needs <see cref="DrawTextLine"/>.</summary>
    public static bool NeedsSynthesis(TextLine line)
    {
        foreach (var run in line.TextRuns)
        {
            if (run is ShapedTextRun shaped && shaped.Length > 0 && NeedsSynthesis(shaped)) { return true; }
        }
        return false;
    }

    /// <summary>Shear about the horizontal line <paramref name="baselineY"/>: points above it move
    /// right by <see cref="Slant"/> per unit of height, the baseline itself stays put.</summary>
    public static Matrix ShearAboutBaseline(double baselineY)
        => new(1, 0, -Slant, 1, Slant * baselineY, 0);

    /// <summary>Draws <paramref name="line"/> exactly as <c>TextLine.Draw</c> does (run by run, each
    /// at its own baseline offset), shearing the runs that <see cref="NeedsSynthesis(ShapedTextRun)"/>.</summary>
    public static void DrawTextLine(DrawingContext context, TextLine line, Point origin)
    {
        var x = origin.X + line.Start;
        foreach (var run in line.TextRuns)
        {
            if (run is not DrawableTextRun drawable) { continue; }
            var at = new Point(x, origin.Y + BaselineOffset(line, drawable));
            if (run is ShapedTextRun shaped && shaped.Length > 0 && NeedsSynthesis(shaped))
            {
                using (context.PushTransform(ShearAboutBaseline(at.Y + shaped.Baseline)))
                {
                    drawable.Draw(context, at);
                }
            }
            else
            {
                drawable.Draw(context, at);
            }
            x += drawable.Size.Width;
        }
    }

    /// <summary>Avalonia's own per-run vertical placement (<c>TextLineImpl.GetBaselineOffset</c>,
    /// internal there), reproduced from the public run and line metrics.</summary>
    private static double BaselineOffset(TextLine line, DrawableTextRun run)
    {
        var negBaseline = -run.Baseline;
        return (run.Properties?.BaselineAlignment ?? BaselineAlignment.Baseline) switch
        {
            BaselineAlignment.Top or BaselineAlignment.TextTop
                => negBaseline + (line.Height - line.Extent + run.Size.Height / 2.0),
            BaselineAlignment.Center
                => negBaseline + (line.Height / 2.0 + run.Baseline - run.Size.Height / 2.0),
            BaselineAlignment.Bottom or BaselineAlignment.TextBottom or BaselineAlignment.Subscript
                => negBaseline + (line.Height - run.Size.Height + run.Baseline),
            BaselineAlignment.Superscript => negBaseline + run.Baseline,
            _ => negBaseline + line.Baseline,
        };
    }
}

/// <summary>A solid colour that also says "this run is italic" (see <see cref="SyntheticItalic"/>).
/// Equal colours still compare equal as brushes; the type is the marker.</summary>
internal sealed class ItalicInkBrush : ImmutableSolidColorBrush
{
    public ItalicInkBrush(ISolidColorBrush source) : base(source) { }
}
