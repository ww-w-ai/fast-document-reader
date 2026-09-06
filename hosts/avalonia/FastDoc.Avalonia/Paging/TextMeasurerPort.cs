using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Avalonia.Media;
using Avalonia.Media.TextFormatting;
using Avalonia.Utilities;
using FastDoc.Avalonia.Native;

namespace FastDoc.Avalonia.Paging;

/// <summary>
/// E2c-1: this host's answer to the S5 measurement port (fastdoc_engine_ffi.h §1b) — "how tall is
/// this text at this width" — and the font-provider port §1h's font-world stand-in, mirroring
/// RustEngineMeasure.swift/RustEngineFonts.swift's role on macOS (see the pagination contract's
/// §1b/§1h and RustEngineMeasure.swift's own doc comment: "if the host has to decide anything, the
/// port is wrong").
///
/// MUST be installed once, process-global, BEFORE the first `fastdoc_office_open` — opening a real
/// document with neither port installed used to succeed and then PANIC inside the engine on the
/// first band query (RustOfficeDocumentHandle.swift's own measured note); this port exists so that
/// panic can never happen on this host either.
///
/// Approximation this host accepts (ADR 0002's own "known cost"): Avalonia's <see cref="TextLayout"/>
/// has no per-paragraph style span the way AppKit's `NSAttributedString` does, so unlike the macOS
/// mirror (which builds ONE attributed string across every paragraph and lays it out once), this
/// port lays out EACH paragraph as its own TextLayout and sums the results. For a running header/
/// footer (this port's only caller today — S5C1-02's band query) that is a handful of short
/// paragraphs, so the approximation's cost is small; a full per-line settle across a whole page is
/// explicitly out of this unit's scope (S4/E2c-1 dispatch note — table/footnote settle is E2c-2/3).
/// </summary>
public static class TextMeasurerPort
{
    private const double DefaultFontSizePoints = 12.0;
    private static readonly Typeface DefaultTypeface = new("Inter");

    // Kept as static fields so the GC never collects the delegate while the engine still holds its
    // native function pointer — the single most common P/Invoke callback bug, and the engine's own
    // installers are one-shot (a second install call is ignored), so there is exactly one delegate
    // instance for the life of the process.
    private static readonly FastdocEngine.MeasureCallback MeasureDelegate = Measure;
    private static readonly FastdocEngine.FaceNamedCallback FaceNamedDelegate = FaceNamed;
    private static readonly FastdocEngine.ResolveCallback ResolveDelegate = Resolve;
    private static readonly FastdocEngine.SystemFaceCallback SystemFaceDelegate = SystemFace;
    private static readonly FastdocEngine.DescribeCallback DescribeDelegate = Describe;
    private static readonly FastdocEngine.CoversCallback CoversDelegate = Covers;
    private static readonly FastdocEngine.SubstituteCallback SubstituteDelegate = Substitute;

    private static bool _installed;
    private static readonly object InstallLock = new();

    /// <summary>How many times <see cref="Measure"/> has actually been called by the engine since
    /// process start — the S4/E2c-1 gate's own observability counter (mirrors
    /// RustOfficeDocumentHandle.answeredQueries's role: two implementations that agree numerically
    /// are indistinguishable by their answers alone).</summary>
    public static long MeasureCallCount { get; private set; }

    /// <summary>Total wall-clock time spent inside <see cref="Measure"/>, in milliseconds — the
    /// measurements.md gate's own per-document cost breakdown.</summary>
    public static double MeasureTotalMs { get; private set; }

    /// <summary>Installs both ports, idempotently — safe to call before every `fastdoc_office_open`
    /// (RenderTreeLoader does exactly that, mirroring RustOfficeDocumentHandle.init?'s own
    /// per-open call to RustEngineFonts.install()/RustEngineMeasure.install()).</summary>
    public static void Install()
    {
        lock (InstallLock)
        {
            if (_installed) { return; }

            var measureCallbacks = new FastdocEngine.FastdocTextMeasureCallbacks { Measure = MeasureDelegate };
            FastdocEngine.fastdoc_install_text_measurer(measureCallbacks);

            var fontCallbacks = new FastdocEngine.FastdocFontProvider
            {
                FaceNamed = FaceNamedDelegate,
                Resolve = ResolveDelegate,
                SystemFace = SystemFaceDelegate,
                Describe = DescribeDelegate,
                Covers = CoversDelegate,
                Substitute = SubstituteDelegate,
            };
            FastdocEngine.fastdoc_install_font_provider(fontCallbacks);

            _installed = true;
        }
    }

    // ---- the measurer -----------------------------------------------------------------------

    private static double Measure(IntPtr payloadPtr, double widthPoints)
    {
        var started = DateTime.UtcNow;
        try
        {
            if (payloadPtr == IntPtr.Zero || widthPoints <= 0) { return 0; }
            var payload = Marshal.PtrToStructure<FastdocEngine.FastdocTextMeasurePayload>(payloadPtr);
            if (payload.ParagraphCount == 0) { return 0; }

            var paragraphs = ReadArray<FastdocEngine.FastdocTextMeasureParagraph>(payload.Paragraphs, payload.ParagraphCount);
            var runs = payload.RunCount > 0
                ? ReadArray<FastdocEngine.FastdocTextMeasureRun>(payload.Runs, payload.RunCount)
                : Array.Empty<FastdocEngine.FastdocTextMeasureRun>();

            return MeasureManaged(paragraphs, runs, widthPoints);
        }
        catch
        {
            // A measurer that throws across the FFI boundary is undefined behaviour on the Rust
            // side — fail to "no contribution" rather than crash the engine's caller.
            return 0;
        }
        finally
        {
            MeasureCallCount++;
            MeasureTotalMs += (DateTime.UtcNow - started).TotalMilliseconds;
        }
    }

    /// <summary>The managed half of <see cref="Measure"/> — everything after unmarshaling the raw
    /// payload pointer. Kept public (not private), the same reason RustEngineMeasure.swift's own
    /// `measure(_:widthPoints:)` is `internal` rather than `private`: it is the one caller a unit
    /// test needs, exercising this port's mapping without a native FFI round-trip
    /// (PagingTests.MeasurerPort_height_matches_a_directly_built_TextLayout).</summary>
    public static double MeasureManaged(FastdocEngine.FastdocTextMeasureParagraph[] paragraphs,
        FastdocEngine.FastdocTextMeasureRun[] runs, double widthPoints)
    {
        double total = 0;
        for (var index = 0; index < paragraphs.Length; index++)
        {
            total += MeasureParagraph(paragraphs[index], runs, index, widthPoints);
        }
        return total;
    }

    private static double MeasureParagraph(FastdocEngine.FastdocTextMeasureParagraph paragraph,
        FastdocEngine.FastdocTextMeasureRun[] runs, int paragraphIndex, double widthPoints)
    {
        var text = new System.Text.StringBuilder();
        var overrides = new List<ValueSpan<TextRunProperties>>();
        double maxFontSize = DefaultFontSizePoints;
        double maxAttachmentHeight = 0;
        var hasContent = false;

        foreach (var run in runs)
        {
            if ((int)run.ParagraphIndex != paragraphIndex) { continue; }
            hasContent = true;
            if (run.Kind == FastdocEngine.FastdocTextMeasureRunKindAttachment)
            {
                maxAttachmentHeight = Math.Max(maxAttachmentHeight, run.AttachmentHeight);
                continue;
            }
            var runText = PtrToUtf8String(run.Text);
            if (string.IsNullOrEmpty(runText)) { continue; }
            var start = text.Length;
            text.Append(runText);
            var size = run.Size > 0 ? run.Size : DefaultFontSizePoints;
            maxFontSize = Math.Max(maxFontSize, size);
            var faceName = PtrToUtf8String(run.FontName);
            var typeface = new Typeface(
                string.IsNullOrEmpty(faceName) ? "Inter" : faceName,
                run.Italic ? FontStyle.Italic : FontStyle.Normal,
                run.Bold ? FontWeight.Bold : FontWeight.Normal);
            overrides.Add(new ValueSpan<TextRunProperties>(
                start, runText.Length,
                new GenericTextRunProperties(typeface, size, foregroundBrush: Brushes.Black)));
        }

        var indent = Math.Max(0, paragraph.HeadIndent) + Math.Max(0, paragraph.FirstLineHeadIndent > 0 ? 0 : 0);
        var availableWidth = Math.Max(1, widthPoints - Math.Max(0, paragraph.HeadIndent) - Math.Max(0, paragraph.TailIndent));

        double textHeight;
        if (text.Length == 0)
        {
            // A blank paragraph still gets its own style applied to the terminating "\n" — the
            // same rule RustEngineMeasure.swift's own comment states — so it contributes exactly
            // one line at whatever font size its runs (none) or the document default implies.
            textHeight = LineHeight(paragraph, maxFontSize);
        }
        else
        {
            var alignment = WireAlignment(paragraph.Alignment);
            var lineHeight = paragraph.LineHeightMultiple > 0
                ? maxFontSize * paragraph.LineHeightMultiple
                : maxFontSize * 1.2;
            var layout = new TextLayout(
                text.ToString(),
                DefaultTypeface,
                maxFontSize,
                Brushes.Black,
                alignment,
                TextWrapping.Wrap,
                maxWidth: availableWidth,
                lineHeight: lineHeight,
                textStyleOverrides: overrides);
            textHeight = layout.Height;
        }

        var spacingBefore = Math.Max(0, paragraph.SpacingBefore);
        var spacingAfter = Math.Max(0, paragraph.SpacingAfter);
        var contentHeight = hasContent ? Math.Max(textHeight, maxAttachmentHeight) : textHeight;
        return spacingBefore + contentHeight + spacingAfter;
    }

    private static double LineHeight(FastdocEngine.FastdocTextMeasureParagraph paragraph, double fontSize)
    {
        if (paragraph.MinimumLineHeight > 0) { return paragraph.MinimumLineHeight; }
        var multiple = paragraph.LineHeightMultiple > 0 ? paragraph.LineHeightMultiple : 1.0;
        return fontSize * multiple * 1.2;
    }

    private static TextAlignment WireAlignment(byte code) => code switch
    {
        0 => TextAlignment.Left,
        1 => TextAlignment.Right,
        2 => TextAlignment.Center,
        3 => TextAlignment.Justify,
        _ => TextAlignment.Left,
    };

    private static T[] ReadArray<T>(IntPtr basePtr, nuint count) where T : struct
    {
        if (basePtr == IntPtr.Zero || count == 0) { return Array.Empty<T>(); }
        var result = new T[(int)count];
        var size = Marshal.SizeOf<T>();
        for (var i = 0; i < result.Length; i++)
        {
            result[i] = Marshal.PtrToStructure<T>(IntPtr.Add(basePtr, i * size))!;
        }
        return result;
    }

    private static string? PtrToUtf8String(IntPtr ptr) => ptr == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(ptr);

    // ---- the font provider --------------------------------------------------------------------
    //
    // Avalonia resolves a family-name string to a real face (with system substitution) internally,
    // at TextLayout build time — there is no separate "does this face exist" query this host needs
    // to answer before that. So unlike RustEngineFonts.swift (which must reproduce AppKit's own
    // substitution cascade to match the shipped reader exactly), this port's only job is to keep
    // the engine's face-id bookkeeping satisfied without steering it wrong: every id maps back to
    // the SAME family-name string it was issued for, and TextMeasurerPort's own Measure never
    // actually calls back INTO these — it reads font_name directly off the run instead (mirroring
    // how the run's declared name, not a resolved id, is what MeasureParagraph above already uses).

    private static readonly List<string> Faces = new();
    private static readonly object FacesLock = new();

    private static ulong Issue(string family)
    {
        lock (FacesLock)
        {
            var existing = Faces.IndexOf(family);
            if (existing >= 0) { return (ulong)(existing + 1); }
            Faces.Add(family);
            return (ulong)Faces.Count;
        }
    }

    private static string? Face(ulong id)
    {
        lock (FacesLock)
        {
            var index = (int)id - 1;
            return index >= 0 && index < Faces.Count ? Faces[index] : null;
        }
    }

    private static ulong FaceNamed(IntPtr namePtr)
    {
        var name = PtrToUtf8String(namePtr);
        return string.IsNullOrEmpty(name) ? 0 : Issue(name);
    }

    private static ulong Resolve(ulong baseFace, uint traits, IntPtr features, nuint featureCount)
    {
        // Traits (bold/italic) are re-applied per run directly from FastdocTextMeasureRun.bold/
        // italic in MeasureParagraph, not by composing a new face id here — so "resolve" is a
        // pass-through to the same family the base face already names.
        var family = baseFace != 0 ? Face(baseFace) : null;
        return string.IsNullOrEmpty(family) ? Issue("Inter") : Issue(family);
    }

    private static ulong SystemFace(double weight, bool monospaced) => Issue(monospaced ? "monospace" : "Inter");

    private static void Describe(ulong face, IntPtr namePtr, nuint nameCap, IntPtr familyPtr, nuint familyCap,
        IntPtr hasFamilyPtr, IntPtr traitsPtr)
    {
        var family = Face(face) ?? "Inter";
        WriteUtf8(namePtr, nameCap, family);
        WriteUtf8(familyPtr, familyCap, family);
        if (hasFamilyPtr != IntPtr.Zero) { Marshal.WriteByte(hasFamilyPtr, 1); }
        if (traitsPtr != IntPtr.Zero) { Marshal.WriteInt32(traitsPtr, 0); }
    }

    private static bool Covers(ulong face, uint scalar) => true; // Avalonia substitutes at draw/measure time.

    private static ulong Substitute(ulong declared, uint scalar) => 0; // "nothing to offer" — keep the declared face.

    private static void WriteUtf8(IntPtr buffer, nuint capacity, string value)
    {
        if (buffer == IntPtr.Zero || capacity == 0) { return; }
        var bytes = System.Text.Encoding.UTF8.GetBytes(value);
        var writable = Math.Min(bytes.Length, (int)capacity - 1);
        if (writable > 0) { Marshal.Copy(bytes, 0, buffer, writable); }
        Marshal.WriteByte(buffer, writable, 0);
    }
}
