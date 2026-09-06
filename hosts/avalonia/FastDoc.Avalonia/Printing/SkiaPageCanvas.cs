using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using Avalonia;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Media.TextFormatting;
using SkiaSharp;

namespace FastDoc.Avalonia.Printing;

/// <summary>The PDF-export implementation of <see cref="IPageCanvas"/> — draws straight onto the
/// <see cref="SKCanvas"/> an <see cref="SKDocument"/> page hands out, replacing S4/E6's raster
/// capture (a whole page rendered to a bitmap, then embedded as one PNG). Every renderer still
/// computes rects/points in the SAME PIXEL space the screen uses (96 DPI, zoom folded in already);
/// this class applies ONE canvas-wide 72/96 scale in its constructor so every call site's numbers
/// need no per-call conversion, and a page this canvas draws lands at the identical size a
/// pixel-space page would.
///
/// TEXT is real: each <see cref="TextLine"/>'s <see cref="TextRun"/>s are walked directly (a
/// <see cref="ShapedTextRun"/>'s own <see cref="TextRun.Text"/> range plus its
/// <see cref="TextRunProperties"/> for size/color/decoration) and drawn with
/// <see cref="SKCanvas.DrawText(string, float, float, SKTextAlign, SKFont, SKPaint)"/> against a
/// SINGLE bundled typeface (the same Noto Sans KR TTF <see cref="Fonts.FontSetup"/> registers as
/// the screen's CJK fallback — Noto Sans CJK's KR subset also carries full Latin/Cyrillic coverage,
/// so one embedded font serves every script this reader draws without depending on whatever Latin
/// font happens to be installed on the machine writing the PDF). Bold/italic are SYNTHETIC
/// (<see cref="SKFont.Embolden"/> / <see cref="SKFont.SkewX"/>) rather than a second weight/style
/// file — there is no bundled bold or italic Noto Sans KR today. Underline/strikethrough are drawn
/// as a plain rule under/through the run's own baseline, not a real font decoration.
///
/// IMAGES (S5-C2 — rewritten from S5-C's always-PNG-re-encode, which on a picture-heavy document
/// grew the PDF past the OLD raster path's size: S5-C flattened a whole page, pictures included,
/// into one 72dpi bitmap, so a picture's OWN resolution never mattered; drawing pictures at their
/// real size instead exposed a 4961x7015px source that a lossless PNG re-encode ships at full
/// size). Three rules, in order — see <see cref="ResolveImage"/>:
/// 1. A JPEG source that is not GROSSLY oversized for how it is drawn (see
///    <see cref="IsGrosslyOversized"/> — a header-only dimension check, no pixel decode) is
///    embedded AS-IS (<see cref="SKImage.FromEncodedData(SKData)"/> on the ORIGINAL bytes) —
///    Skia's PDF backend recognizes already-JPEG-encoded data and writes it straight through as
///    `/DCTDecode`, no decode-then-re-encode round trip at all. Measured need for the size guard:
///    the hwpx sample carries a 4961x7015px JPEG (a scanned stamp) printed at signature size —
///    without it, "JPEG passthrough" would ship that scan at full resolution regardless.
/// 2. Anything else (PNG/BMP/unknown/no source bytes/grossly-oversized JPEG) is decoded, downsampled to at most 2x the
///    SIZE IT IS ACTUALLY DRAWN AT (a ~144dpi-equivalent ceiling — a picture is never drawn at
///    more than twice its own printed size' worth of pixels, whatever the source resolution was),
///    then re-encoded JPEG quality 85 if it has no alpha channel or PNG if it does (JPEG cannot
///    carry transparency).
/// 3. The result is cached by a HASH of the source bytes (or by the decoded <see cref="Bitmap"/>'s
///    reference when there ARE no source bytes) in <see cref="_imageCache"/>, which this class
///    OWNS ACROSS THE WHOLE EXPORT (constructed once by <see cref="Printing.PdfExporter"/>, fed a
///    new <see cref="SKCanvas"/> per page via <see cref="SetCanvas"/>) rather than once per page —
///    a background picture repeated on every page of a document is now encoded ONCE and the SAME
///    <see cref="SKImage"/> object is handed to every page's `DrawImage`, which is what lets
///    Skia's PDF writer dedupe it to a single XObject instead of embedding it once per page.</summary>
public sealed class SkiaPageCanvas : IPageCanvas
{
    private const double PixelsToPoints = 72.0 / 96.0;
    private const int JpegQuality = 85;
    private const double MaxDrawnPixelRatio = 2.0; // the "~144dpi" ceiling relative to printed size

    private static readonly bool TraceEnabled = Environment.GetEnvironmentVariable("FMD_AVALONIA_PDF_TRACE") == "1";

    private SKCanvas _canvas;
    private readonly SKTypeface _typeface;
    private readonly Dictionary<(bool Bold, bool Italic, float SizePx), SKFont> _fontCache = new();
    private readonly Dictionary<string, SKImage?> _imageCache = new();

    /// <summary>1-based page number the CALLER (<see cref="Printing.PdfExporter"/>) is currently
    /// drawing — set once per <see cref="SetCanvas"/> call, purely so
    /// <see cref="FMD_AVALONIA_PDF_TRACE"/>'s downsample trace can name a page without every
    /// drawing method threading a page number through its whole call chain.</summary>
    public int CurrentPageNumber { get; set; }

    public SkiaPageCanvas(SKCanvas canvas, SKTypeface typeface)
    {
        _typeface = typeface;
        _canvas = canvas;
        ApplyPageScale();
    }

    /// <summary>Points this canvas at a NEW page's <see cref="SKCanvas"/> (one call to
    /// <see cref="SKDocument.BeginPage"/> per page) while keeping every cache (fonts, resolved
    /// images) — see the class doc's point 3 for why that sharing matters for image dedup.</summary>
    public void SetCanvas(SKCanvas canvas)
    {
        _canvas = canvas;
        ApplyPageScale();
    }

    private void ApplyPageScale()
    {
        // Every call below stays in the SAME pixel space FlowDocumentView/TableGridRenderer/
        // PageModePainter already compute in — this single transform is what turns those pixel
        // numbers into PDF points, so no caller needs its own points conversion.
        _canvas.Scale((float)PixelsToPoints);
    }

    /// <summary>Loads the bundled Noto Sans KR TTF straight from the app's own AvaloniaResource
    /// asset stream (the SAME file <see cref="Fonts.FontSetup"/> registers for the screen) — one
    /// load per exported document, shared across every page's <see cref="SkiaPageCanvas"/>.
    ///
    /// TTF, not the OTF this bundled through S5-C (S5-C2): SkiaSharp's PDF backend embeds a
    /// non-system CFF/OTTO-outline typeface as `/Type3` — every glyph pasted in as its own vector
    /// path — regardless of platform (measured identically on macOS/CoreText AND Linux/FreeType;
    /// a SYSTEM-registered font of either outline format embeds fine, so this is about the outline
    /// format plus "not system-registered", not the backend). A `glyf`-outline TTF embeds as a
    /// real `/CIDFontType2` + `/FontFile2` instead — isolated repro: a plain system TTF loaded the
    /// SAME way (`SKTypeface.FromData`) produced `/CIDFontType2`, zero `/Type3`. The bundled OTF
    /// was converted to this TTF with fontTools' `cu2qu` pen (cubic Bezier CFF outlines refit to
    /// quadratic `glyf` contours) — see `docs/studio/sprints/S5/measurements.md`'s S5-C2 section
    /// for the conversion script and the glyph-count parity check (11,172 Hangul + 8,138 Hanja,
    /// unchanged). On a CJK-dense document this turns a PER-GLYPH cost (thousands of distinct
    /// Hangul/Hanja outlines, each pasted into `/Type3`) into a FIXED one-time font-embed cost
    /// (SkiaSharp does not subset a non-system typeface either way, so the whole font is embedded
    /// once — just as one compact table instead of N expanded path streams).
    ///
    /// Copies the bytes into an <see cref="SKData"/> BEFORE handing them to
    /// <see cref="SKTypeface.FromData(SKData)"/> rather than passing the AvaloniaResource stream
    /// straight to <c>SKTypeface.FromStream</c> — measured trap (S5-C): FreeType-backed SkiaSharp
    /// (the Linux backend) reads a stream-backed typeface's glyph outlines LAZILY, on the first
    /// DrawText call, not eagerly at load time. A `using` around the source stream that disposes
    /// it once this method returns (looked harmless — the method's own job is done) left every
    /// later glyph read hitting a disposed stream, which failed SILENTLY: no exception, `--pdf`
    /// still reported the right page count, but the PDF carried outright NO text (zero Font
    /// objects, zero Tj operators — confirmed on the linux-arm64 self-contained publish under
    /// Docker with a real libfontconfig installed). CoreText-backed SkiaSharp (macOS, the dev
    /// machine that built this) copies a stream typeface's bytes eagerly at load time, so this bug
    /// was invisible there — it produced a Type3-fallback PDF with a real font, and only showed on
    /// the actual shipping platform.</summary>
    public static SKTypeface LoadBundledTypeface()
    {
        var uri = new Uri("avares://FastDoc.Avalonia/Assets/Fonts/NotoSansKR-Regular.ttf");
        using var stream = global::Avalonia.Platform.AssetLoader.Open(uri);
        using var memory = new MemoryStream();
        stream.CopyTo(memory);
        using var data = SKData.CreateCopy(memory.ToArray());
        return SKTypeface.FromData(data)
            ?? throw new InvalidOperationException("could not load bundled Noto Sans KR as an SKTypeface");
    }

    public void DrawRect(Rect rect, Color? fill, Color? stroke, double strokeThicknessPx)
    {
        var skRect = ToSkRect(rect);
        if (fill is { } f)
        {
            using var paint = new SKPaint { Color = ToSk(f), Style = SKPaintStyle.Fill, IsAntialias = true };
            _canvas.DrawRect(skRect, paint);
        }
        if (stroke is { } s && strokeThicknessPx > 0)
        {
            using var paint = new SKPaint
            {
                Color = ToSk(s),
                Style = SKPaintStyle.Stroke,
                StrokeWidth = (float)strokeThicknessPx,
                IsAntialias = true,
            };
            _canvas.DrawRect(skRect, paint);
        }
    }

    public void DrawLine(Point a, Point b, Color color, double thicknessPx)
    {
        using var paint = new SKPaint
        {
            Color = ToSk(color),
            StrokeWidth = (float)Math.Max(0.1, thicknessPx),
            IsAntialias = true,
        };
        _canvas.DrawLine((float)a.X, (float)a.Y, (float)b.X, (float)b.Y, paint);
    }

    public void DrawImage(Bitmap bitmap, byte[]? sourceBytes, string? sourceMimeType, Rect destRect)
    {
        var image = ResolveImage(bitmap, sourceBytes, sourceMimeType, destRect);
        if (image is null) { return; }
        _canvas.DrawImage(image, ToSkRect(destRect));
    }

    public void DrawTextLayout(TextLayout layout, Point origin)
    {
        var y = origin.Y;
        foreach (var line in layout.TextLines)
        {
            DrawTextLine(line, new Point(origin.X, y));
            y += line.Height;
        }
    }

    public void DrawTextLine(TextLine line, Point origin)
    {
        var x = origin.X;
        var baselineY = origin.Y + line.Baseline;
        foreach (var run in line.TextRuns)
        {
            if (run is not ShapedTextRun shaped || shaped.Length == 0) { continue; }
            var text = shaped.Text.ToString();
            if (text.Length == 0) { x += shaped.Size.Width; continue; }

            var props = shaped.Properties;
            var sizePx = (float)(props?.FontRenderingEmSize ?? 12.0);
            var isBold = props?.Typeface.Weight is { } w && w >= FontWeight.Bold;
            var isItalic = props?.Typeface.Style is FontStyle.Italic or FontStyle.Oblique;
            var color = (props?.ForegroundBrush as ISolidColorBrush)?.Color ?? Colors.Black;

            var font = GetOrBuildFont(isBold, isItalic, sizePx);
            using var paint = new SKPaint { Color = ToSk(color), IsAntialias = true };
            _canvas.DrawText(SanitizeForBundledFont(text, font), (float)x, (float)baselineY, SKTextAlign.Left, font, paint);

            if (props?.TextDecorations is { Count: > 0 } decorations)
            {
                var width = (float)shaped.Size.Width;
                foreach (var decoration in decorations)
                {
                    var lineY = decoration.Location == TextDecorationLocation.Strikethrough
                        ? baselineY - sizePx * 0.3
                        : baselineY + sizePx * 0.08;
                    _canvas.DrawLine((float)x, (float)lineY, (float)x + width, (float)lineY, paint);
                }
            }

            x += shaped.Size.Width;
        }
    }

    /// <summary>S8-A4: a control character (U+000A LINE FEED — the whole-run break marker
    /// <c>Rendering.FlowDocumentBuilder</c>'s "lineBreak" case and its own control-char splitter
    /// both produce) or a separator character the bundled Noto Sans KR TTF's cmap does not map
    /// (measured: U+2007 FIGURE SPACE, the HWP table-of-contents leader — see
    /// docs/studio/sprints/S8/s8a2-render-fixes.md's C4 section for why this specific character,
    /// not U+2024 as first suspected) draws as a `.notdef` tofu BOX through this method, but never
    /// through the on-screen path (<see cref="AvaloniaPageCanvas"/>) — that difference is the whole
    /// root cause, not a missing character-substitution rule.
    ///
    /// <see cref="AvaloniaPageCanvas"/> never calls <c>SKCanvas.DrawText(string, ...)</c> at all: it
    /// draws the ALREADY-SHAPED <see cref="ShapedTextRun.GlyphRun"/> Avalonia's own text shaper
    /// built, and a real shaper (HarfBuzz on Linux, the backend Avalonia's own <c>TextLayout</c>
    /// construction always goes through) treats a control character or a Unicode separator
    /// (`Zs`/`Cc` general category) as ZERO-WIDTH/NO-GLYPH by convention — it is a layout signal,
    /// never something meant to draw. This method instead re-shapes the run's raw text from
    /// scratch against ONE hardcoded typeface (deliberately, per this class's own doc — Linux
    /// cannot be trusted to resolve the same font-fallback chain the GUI would), which is a much
    /// cruder path: `SKCanvas.DrawText` asks the font's OWN cmap for a glyph per character and
    /// draws WHATEVER it gets back, `.notdef` included, with no "this general category never
    /// draws" rule of its own. The bundled Noto Sans KR TTF's cmap does not define an entry for
    /// U+000A or U+2007, so both produced a visible box only on THIS path.
    ///
    /// Fix has TWO layers, not one — a single "ask <see cref="SKFont.ContainsGlyph"/>" check turned
    /// out not to be enough. MEASURED on this machine's SkiaSharp/font backend:
    /// <c>font.ContainsGlyph(0x000A)</c> (LINE FEED) returns TRUE — this bundled TTF's cmap maps it
    /// to a real, non-<c>.notdef</c> glyph id, not to "no glyph". A real text shaper never draws
    /// LINE FEED regardless of what the font's cmap happens to contain for it (it is a layout
    /// signal, not a character to render); this method's font-lookup-per-character approach has no
    /// way to know that from <c>ContainsGlyph</c> alone, and a font backend on a different platform
    /// resolving the SAME codepoint against the SAME TTF file to a DIFFERENT glyph id is exactly the
    /// kind of divergence this codebase has already measured elsewhere (page counts differ between
    /// a macOS local build and the real Linux VM — see this sprint's page-count table). Trusting
    /// glyph presence for a control character is therefore fragile across platforms in a way this
    /// fix cannot afford to be silently wrong about.
    ///
    /// So: a Unicode General Category test decides the two categories a real shaper always treats as
    /// invisible — <c>Control</c> (Cc: U+000A included) and <c>SpaceSeparator</c> other than the
    /// ordinary U+0020 SPACE (Zs: U+2007 FIGURE SPACE included) — and substitutes a plain space for
    /// those UNCONDITIONALLY, never asking the font's cmap at all. Every other character keeps
    /// asking <see cref="SKFont.ContainsGlyph"/>, which remains the right tool for a genuinely
    /// unsupported symbol or rare Hanja this font's cmap has no entry for at all. Substitution never
    /// changes glyph COUNT or the run's already-computed <see cref="ShapedTextRun.Size"/> advance
    /// this method draws at (so text after a sanitized run is never repositioned).</summary>
    private static string SanitizeForBundledFont(string text, SKFont font)
    {
        char[]? chars = null; // allocated only once a run actually needs a substitution
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            var category = System.Globalization.CharUnicodeInfo.GetUnicodeCategory(c);
            var alwaysInvisibleToAShaper = category == System.Globalization.UnicodeCategory.Control
                || (category == System.Globalization.UnicodeCategory.SpaceSeparator && c != ' ');

            if (alwaysInvisibleToAShaper)
            {
                (chars ??= text.ToCharArray())[i] = ' ';
                continue;
            }
            if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
            {
                var codepoint = char.ConvertToUtf32(c, text[i + 1]);
                if (!font.ContainsGlyph(codepoint))
                {
                    chars ??= text.ToCharArray();
                    chars[i] = ' ';
                    chars[i + 1] = ' ';
                }
                i++;
                continue;
            }
            if (!font.ContainsGlyph(c)) { (chars ??= text.ToCharArray())[i] = ' '; }
        }
        return chars is null ? text : new string(chars);
    }

    private SKFont GetOrBuildFont(bool bold, bool italic, float sizePx)
    {
        var key = (bold, italic, sizePx);
        if (_fontCache.TryGetValue(key, out var cached)) { return cached; }
        var font = new SKFont(_typeface, sizePx)
        {
            Embolden = bold,
            SkewX = italic ? -0.25f : 0f,
            Edging = SKFontEdging.SubpixelAntialias,
        };
        _fontCache[key] = font;
        return font;
    }

    /// <summary>Cache key = a hash of the document's OWN encoded bytes when available (S5-C2 point
    /// 3 — the same picture used many times in a document, e.g. a repeated page background, must
    /// resolve to the identical cache entry so its <see cref="SKImage"/> object — not just its
    /// pixels — is reused across every page). No source bytes (a placeholder-shaped resource, or a
    /// format this reader decoded but never kept raw bytes for) falls back to a per-`Bitmap`-
    /// instance key, matching <see cref="Rendering.ImageBlockRenderer"/>'s own per-resource-id
    /// bitmap cache (same picture, same Bitmap reference every call).</summary>
    private SKImage? ResolveImage(Bitmap bitmap, byte[]? sourceBytes, string? sourceMimeType, Rect destRect)
    {
        var key = sourceBytes is { Length: > 0 }
            ? Convert.ToHexString(SHA256.HashData(sourceBytes))
            : "bitmap:" + bitmap.GetHashCode();
        if (_imageCache.TryGetValue(key, out var cached)) { return cached; }

        SKImage? image;
        try
        {
            var isJpeg = string.Equals(sourceMimeType, "image/jpeg", StringComparison.OrdinalIgnoreCase) && sourceBytes is { Length: > 0 };
            image = isJpeg && !IsGrosslyOversized(sourceBytes!, destRect)
                ? ResolveJpegPassthrough(sourceBytes!)
                : ResolveByDecodeAndReencode(bitmap, sourceBytes, destRect);
        }
        catch
        {
            image = null; // never let one bad picture fail the whole export — same contract
                            // ImageBlockRenderer.Resolve already follows on the screen path.
        }
        _imageCache[key] = image;
        return image;
    }

    /// <summary>Guards rule 1 — a source JPEG scanned/photographed far above what it is ever
    /// printed at (measured: a 4961x7015px JPEG drawn at signature-stamp size in the hwpx sample)
    /// still passes through at FULL resolution if this guard does not exist, because
    /// `SKImage.FromEncodedData` on raw JPEG bytes never looks at how big the picture is drawn.
    /// Reads only the JPEG's HEADER dimensions (<see cref="SKBitmap.DecodeBounds(byte[])"/> — no
    /// full pixel decode) to decide; a source already within <see cref="MaxDrawnPixelRatio"/>x of
    /// its drawn size keeps the true zero-re-encode passthrough.</summary>
    private static bool IsGrosslyOversized(byte[] sourceBytes, Rect destRect)
    {
        var info = SKBitmap.DecodeBounds(sourceBytes);
        if (info.Width <= 0 || info.Height <= 0) { return false; }
        var maxWidthPx = Math.Max(1, destRect.Width * PixelsToPoints * MaxDrawnPixelRatio);
        var maxHeightPx = Math.Max(1, destRect.Height * PixelsToPoints * MaxDrawnPixelRatio);
        return info.Width > maxWidthPx || info.Height > maxHeightPx;
    }

    /// <summary>Rule 1 — a JPEG source embeds AS-IS. `SKImage.FromEncodedData` on already-JPEG
    /// bytes hands Skia's PDF writer the original DCT-encoded stream, which it writes straight
    /// through as `/DCTDecode` with no decode-then-re-encode round trip (verified by `/DCTDecode`
    /// object counts in the exported PDF — see measurements.md).</summary>
    private static SKImage? ResolveJpegPassthrough(byte[] sourceBytes)
    {
        using var data = SKData.CreateCopy(sourceBytes);
        return SKImage.FromEncodedData(data);
    }

    /// <summary>Rule 2 — decode (from the document's own bytes when present, else the Avalonia
    /// Bitmap's own PNG re-encode — the only path left when no source bytes survived), downsample
    /// to at most <see cref="MaxDrawnPixelRatio"/>x the pixel size this picture is ACTUALLY drawn
    /// at (a picture is never usefully sharper than ~144dpi once printed at its own paragraph
    /// width). An opaque result tries BOTH JPEG(85) and PNG and keeps whichever is smaller —
    /// measured need: a PNG source that is a screenshot/UI capture (sharp edges, flat colors,
    /// text) compresses BETTER as PNG than JPEG-85 (the OpenAPI docx sample's five screenshots:
    /// 161,547B as PNG source, 184,088B forced through JPEG — a regression a blanket
    /// "opaque means JPEG" rule would have shipped). A source with real alpha stays PNG (JPEG
    /// carries no alpha channel at all).</summary>
    private SKImage? ResolveByDecodeAndReencode(Bitmap bitmap, byte[]? sourceBytes, Rect destRect)
    {
        using var skBitmap = DecodeToSkBitmap(bitmap, sourceBytes);
        if (skBitmap is null) { return null; }

        var maxWidthPx = Math.Max(1, (int)Math.Ceiling(destRect.Width * PixelsToPoints * MaxDrawnPixelRatio));
        var maxHeightPx = Math.Max(1, (int)Math.Ceiling(destRect.Height * PixelsToPoints * MaxDrawnPixelRatio));

        var source = skBitmap;
        SKBitmap? resized = null;
        if (source.Width > maxWidthPx || source.Height > maxHeightPx)
        {
            var scale = Math.Min((double)maxWidthPx / source.Width, (double)maxHeightPx / source.Height);
            var targetSize = new SKSizeI(Math.Max(1, (int)Math.Round(source.Width * scale)),
                Math.Max(1, (int)Math.Round(source.Height * scale)));
            resized = source.Resize(targetSize, SKSamplingOptions.Default);
            if (resized is not null)
            {
                // FMD_AVALONIA_PDF_TRACE=1 names the first page a downsample lands on, in
                // (original px -> result px) terms, so a reviewer can rasterize exactly that page
                // instead of guessing.
                if (TraceEnabled)
                {
                    Console.Error.WriteLine(
                        $"pdftrace: page={CurrentPageNumber} downsample {source.Width}x{source.Height} -> {targetSize.Width}x{targetSize.Height}");
                }
                source = resized;
            }
        }

        var isOpaque = source.Info.AlphaType == SKAlphaType.Opaque;
        using var toEncode = SKImage.FromBitmap(source);
        SKData? encoded;
        if (isOpaque)
        {
            using var jpeg = toEncode.Encode(SKEncodedImageFormat.Jpeg, JpegQuality);
            using var png = toEncode.Encode(SKEncodedImageFormat.Png, 100);
            encoded = (jpeg is not null && (png is null || jpeg.Size <= png.Size))
                ? SKData.CreateCopy(jpeg.Span)
                : png is not null ? SKData.CreateCopy(png.Span) : null;
        }
        else
        {
            using var png = toEncode.Encode(SKEncodedImageFormat.Png, 100);
            encoded = png is null ? null : SKData.CreateCopy(png.Span);
        }
        resized?.Dispose();
        return encoded is null ? null : SKImage.FromEncodedData(encoded);
    }

    /// <summary>Decodes straight from the document's own bytes when they survived
    /// (<see cref="Rendering.ImageBlockRenderer"/>'s cache) — a direct <see cref="SKBitmap.Decode(byte[])"/>
    /// call, never a second trip through Avalonia. Only falls back to re-encoding the ALREADY-
    /// decoded Avalonia <see cref="Bitmap"/> as PNG when no source bytes exist at all (a resource
    /// this reader only ever had as a decoded bitmap, not raw bytes).</summary>
    private static SKBitmap? DecodeToSkBitmap(Bitmap bitmap, byte[]? sourceBytes)
    {
        if (sourceBytes is { Length: > 0 })
        {
            var direct = SKBitmap.Decode(sourceBytes);
            if (direct is not null) { return direct; }
        }
        using var stream = new MemoryStream();
        bitmap.Save(stream, new PngBitmapEncoderOptions()); // explicit overload -- Save(Stream, int?) is obsolete
        stream.Position = 0;
        return SKBitmap.Decode(stream.ToArray());
    }

    private static SKRect ToSkRect(Rect rect) =>
        new((float)rect.X, (float)rect.Y, (float)rect.Right, (float)rect.Bottom);

    private static SKColor ToSk(Color color) => new(color.R, color.G, color.B, color.A);
}
