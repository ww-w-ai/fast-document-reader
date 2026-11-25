using System;
using System.Collections.Generic;
using System.Reflection;
using Avalonia;
using Avalonia.Media;
using Avalonia.Media.TextFormatting;
using Avalonia.Platform;

namespace FastDoc.Avalonia.Rendering;

/// <summary>
/// 장평 (`wire::CharacterStyle.widthScalePercent`, a run's glyph advance as a percentage of normal) as
/// macOS draws it: every glyph's own advance times the scale — a space loses 9% of a space, a Hangul
/// syllable 9% of a syllable. Avalonia has no per-run horizontal glyph scale and its letter spacing is
/// one value per paragraph, so a per-character-class average taken out as letter spacing narrowed a
/// cell's spaces by a full syllable's share (s9: "최종 지원대상 사업계획, 사업비 심의 및 결과 통보" at
/// 91% fit 3 lines where macOS sets 4).
///
/// Mechanism: the run's properties carry the scale as a private OpenType feature tag
/// (<see cref="Tag"/>, value = percent × 100); a decorator over the platform shaper strips it, shapes
/// with the rest, and multiplies each glyph's advance by the scale. Glyph outlines are drawn at their
/// normal width (no horizontal squeeze), which is the measurement the plan is fed. Avalonia shapes
/// adjacent runs of one face and size together with the first run's options, so a scaled run directly
/// beside an unscaled run of the same face and size shares its neighbour's scale.
/// </summary>
internal static class GlyphWidthScale
{
    /// <summary>The private feature tag that carries the scale. No font defines it.</summary>
    public const string Tag = "fdws";
    private static readonly object InstallLock = new();
    private static volatile bool installed;

    /// <summary>The features a run of <paramref name="widthScalePercent"/> is shaped with: null at 100%.</summary>
    public static FontFeatureCollection? FeaturesFor(double widthScalePercent)
    {
        if (widthScalePercent <= 0 || Math.Abs(widthScalePercent - 100) < 0.001) { return null; }
        EnsureInstalled();
        return new FontFeatureCollection { new FontFeature { Tag = Tag, Value = (int)Math.Round(widthScalePercent * 100) } };
    }

    // Avalonia's reference assembly hides the locator's mutable side and marks `ITextShaperImpl` not
    // implementable, both public at run time: the binding goes through reflection
    // (`AvaloniaLocator.CurrentMutable.Bind<TextShaper>().ToConstant(..)`, as in HangulWordWrap) and
    // the decorator is a run-time `DispatchProxy` over the platform shaper.
    private static void EnsureInstalled()
    {
        if (installed && TextShaper.Current is ScaledShaper) { return; }
        lock (InstallLock)
        {
            var current = TextShaper.Current;
            if (current is ScaledShaper) { installed = true; return; }
            var platform = typeof(TextShaper).GetField("_platformImpl", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(current)!;
            var proxy = DispatchProxy.Create(typeof(ITextShaperImpl), typeof(ScalingProxy));
            ((ScalingProxy)proxy).Configure(platform, current);
            var locator = typeof(AvaloniaLocator).GetProperty("CurrentMutable")!.GetValue(null)!;
            var helper = locator.GetType().GetMethod("Bind", Type.EmptyTypes)!.MakeGenericMethod(typeof(TextShaper)).Invoke(locator, null)!;
            helper.GetType().GetMethod("ToConstant")!.MakeGenericMethod(typeof(TextShaper))
                .Invoke(helper, new object[] { new ScaledShaper((ITextShaperImpl)proxy) });
            installed = true;
        }
    }

    private sealed class ScaledShaper(ITextShaperImpl impl) : TextShaper(impl);

    /// <summary>Scales <c>ShapeText</c>'s advances for a run carrying <see cref="Tag"/>; forwards every
    /// other member to the platform shaper unchanged.</summary>
    public class ScalingProxy : DispatchProxy
    {
        private object platform = null!;
        private TextShaper shaper = null!;

        internal void Configure(object platformImpl, TextShaper platformShaper)
        {
            platform = platformImpl;
            shaper = platformShaper;
        }

        protected override object? Invoke(MethodInfo? targetMethod, object?[]? args)
        {
            if (targetMethod?.Name == "ShapeText" && args is [ReadOnlyMemory<char> text, TextShaperOptions options])
            {
                return ShapeText(text, options);
            }
            return targetMethod!.Invoke(platform, args);
        }

        private ShapedBuffer ShapeText(ReadOnlyMemory<char> text, TextShaperOptions options)
        {
            if (options.FontFeatures is not { Count: > 0 } features) { return shaper.ShapeText(text, options); }
            double scale = 0;
            List<FontFeature>? rest = null;
            foreach (var feature in features)
            {
                if (feature.Tag == Tag) { scale = feature.Value / 10000.0; continue; }
                (rest ??= new List<FontFeature>()).Add(feature);
            }
            if (scale <= 0) { return shaper.ShapeText(text, options); }
            var buffer = shaper.ShapeText(text, new TextShaperOptions(options.GlyphTypeface, options.FontRenderingEmSize,
                options.BidiLevel, options.Culture, options.IncrementalTabWidth, options.LetterSpacing, rest));
            for (var i = 0; i < buffer.Length; i++)
            {
                var g = buffer[i];
                buffer[i] = new GlyphInfo(g.GlyphIndex, g.GlyphCluster, g.GlyphAdvance * scale, g.GlyphOffset);
            }
            return buffer;
        }
    }
}
