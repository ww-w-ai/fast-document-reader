using Avalonia;
using Avalonia.Media;

namespace FastDoc.Avalonia.Fonts;

/// <summary>
/// Bundles Noto Sans KR (SIL OFL 1.1, Assets/Fonts/NotoSansKR-Regular.ttf +
/// NotoSansKR-OFL.txt) into the app and registers it as a fallback for Hangul syllables,
/// Hanja (CJK Unified Ideographs + Extension A + compatibility ideographs), Hangul
/// compatibility jamo, and the box-drawing/geometric-shape glyphs the reader's table
/// borders use — so a Linux machine with no Korean system font (no fontconfig
/// "kr"/"cjk"/"nanum" package) still shows real glyphs instead of tofu (□). This is a
/// FALLBACK, not the default family: it applies only to characters the platform's own
/// default font (Inter, via .WithInterFont() in Program.cs) cannot render, so Latin text
/// still uses the normal UI font. Decided in docs/studio/sprints/S3/d7-linux-fonts.md.
///
/// The bundled file is the full KR-region subset of Noto Sans CJK (Sans/SubsetOTF/KR from
/// notofonts/noto-cjk), not the Hangul-only Regular subset this app shipped before —
/// owner decision (option 3, docs/studio/sprints/S5/measurements.md): 8,138 Hanja glyphs
/// in U+4E00-9FFF, plus Extension A and compatibility ideographs, so a Hanja-bearing HWP
/// document renders real glyphs on a font-less Linux machine instead of tofu.
///
/// The ExtraLight weight in Vendor/rhwp-src/ttfs/opensource/ is intentionally not bundled
/// (registers under a different family name and has no box-drawing glyphs — see d7).
///
/// S5-C2: the bundled file was converted from Noto Sans CJK's own OTF (CFF/PostScript
/// outlines) to TrueType (`glyf`) outlines with fontTools' `cu2qu` pen — a PDF-export need
/// (SkiaSharp embeds a non-system CFF typeface as per-glyph `/Type3` vector paths instead of
/// a real font, see Printing/SkiaPageCanvas.cs's own doc), not a screen rendering need. Glyph
/// coverage (11,172 Hangul + 8,138 Hanja) and the "Noto Sans KR" family name are unchanged —
/// verified against the pre-conversion OTF with fontTools (measurements.md's S5-C2 section).
internal static class FontSetup
{
    private const string BundledFamilyUri = "avares://FastDoc.Avalonia/Assets/Fonts#Noto Sans KR";

    // U+AC00-D7A3: 11,172 precomposed Hangul syllables.
    // U+3130-318F: Hangul compatibility jamo (individual consonants/vowels).
    // U+4E00-9FFF: CJK Unified Ideographs (Hanja) — the common range Korean documents use.
    // U+3400-4DBF: CJK Unified Ideographs Extension A (rarer Hanja).
    // U+F900-FAFF: CJK Compatibility Ideographs — Korean HWP documents use these.
    // U+2500-25FF: box-drawing + geometric shapes (table borders, bullets) the bundled
    // font also carries, so a borderless-looking table on a font-less Linux box is
    // covered by the same fallback as the Korean text around it.
    private const string FallbackUnicodeRanges =
        "U+AC00-D7A3,U+3130-318F,U+4E00-9FFF,U+3400-4DBF,U+F900-FAFF,U+2500-25FF";

    /// <summary>Registers the bundled-font fallback on the given AppBuilder. Call this on
    /// every AppBuilder this process constructs — the interactive GUI path (BuildAvaloniaApp
    /// in Program.cs) and the --paint-probe headless path (RunPaintProbe in Program.cs) build
    /// separate AppBuilder instances, and both need Korean glyphs to render correctly.</summary>
    public static AppBuilder WithBundledKoreanFallback(this AppBuilder builder)
        => builder.With(new FontManagerOptions
        {
            FontFallbacks = new[]
            {
                new FontFallback
                {
                    FontFamily = new FontFamily(BundledFamilyUri),
                    UnicodeRange = UnicodeRange.Parse(FallbackUnicodeRanges),
                },
            },
        });
}
