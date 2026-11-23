using System;
using System.Runtime.InteropServices;

namespace FastDoc.Avalonia.Native;

/// <summary>
/// Raw P/Invoke declarations for the subset of fastdoc_engine_ffi.h this host uses, plus a
/// resolver that finds the dylib via the FASTDOC_ENGINE_LIB environment variable. No path is
/// hardcoded here — a missing/unset variable is a loud error, not a guessed default.
/// </summary>
// E2c-1: raised from internal to public so the struct shapes (FastdocTextMeasureParagraph etc.)
// can be built directly in unit tests (Paging.TextMeasurerPort.MeasureManaged's own testability
// hook) without a native FFI round-trip. Every P/Invoke entry point stays behind
// FASTDOC_ENGINE_LIB at call time regardless of this class's own accessibility.
public static class FastdocEngine
{
    private const string LibraryName = "fastdoc_engine_ffi";

    static FastdocEngine()
    {
        NativeLibrary.SetDllImportResolver(typeof(FastdocEngine).Assembly, Resolve);
    }

    /// <summary>Call once (e.g. from Main) before any P/Invoke below, so a missing library fails
    /// with a clear message instead of a bare DllNotFoundException from the first real call.</summary>
    public static void EnsureLoadable()
    {
        _ = ResolveLibraryPath();
    }

    private static string ResolveLibraryPath()
    {
        var envPath = Environment.GetEnvironmentVariable("FASTDOC_ENGINE_LIB");
        if (!string.IsNullOrWhiteSpace(envPath))
        {
            if (!System.IO.File.Exists(envPath))
            {
                throw new InvalidOperationException(
                    $"FASTDOC_ENGINE_LIB points at a file that does not exist: {envPath}");
            }
            return envPath;
        }

        // No override: a packaged build carries the engine dylib/so/dll next to the managed
        // assembly (runtimes/<rid>/native/) — the layout `dotnet publish` produces for a native
        // asset referenced this way, and also the flat bin/ directory a hand-copied dylib would
        // sit in. Try both before giving up, and name every path tried in the error so a missing
        // library is a one-line diagnosis, not a guess.
        var tried = new System.Collections.Generic.List<string>();
        foreach (var candidate in CandidatePaths())
        {
            tried.Add(candidate);
            if (System.IO.File.Exists(candidate))
            {
                return candidate;
            }
        }

        throw new InvalidOperationException(
            "FASTDOC_ENGINE_LIB is not set, and no bundled engine library was found. " +
            "Point FASTDOC_ENGINE_LIB at the built libfastdoc_engine_ffi.dylib/.so/.dll " +
            "(see hosts/avalonia/README.md), or place it at one of:\n  " +
            string.Join("\n  ", tried));
    }

    /// <summary>The bare filename for this platform's build of the engine — no directory, so it
    /// can be joined under either candidate root below.</summary>
    private static string PlatformLibraryFileName()
    {
        if (OperatingSystem.IsWindows()) { return "fastdoc_engine_ffi.dll"; }
        if (OperatingSystem.IsMacOS()) { return "libfastdoc_engine_ffi.dylib"; }
        return "libfastdoc_engine_ffi.so"; // Linux and other Unix-like targets.
    }

    /// <summary>The .NET runtime identifier for this process's OS+architecture, used only to
    /// name the runtimes/&lt;rid&gt;/native/ folder .NET's own native-asset convention expects —
    /// NOT read from RuntimeInformation.RuntimeIdentifier, which names the identifier the app was
    /// *built* for for a self-contained publish, not the machine it is running on.</summary>
    private static string CurrentRid()
    {
        var arch = RuntimeInformation.ProcessArchitecture switch
        {
            Architecture.Arm64 => "arm64",
            Architecture.X64 => "x64",
            var other => other.ToString().ToLowerInvariant(),
        };
        if (OperatingSystem.IsWindows()) { return $"win-{arch}"; }
        if (OperatingSystem.IsMacOS()) { return $"osx-{arch}"; }
        return $"linux-{arch}";
    }

    private static System.Collections.Generic.IEnumerable<string> CandidatePaths()
    {
        var fileName = PlatformLibraryFileName();
        var baseDir = AppContext.BaseDirectory;
        yield return System.IO.Path.Combine(baseDir, "runtimes", CurrentRid(), "native", fileName);
        yield return System.IO.Path.Combine(baseDir, fileName);
    }

    private static IntPtr Resolve(string libraryName, System.Reflection.Assembly assembly,
        DllImportSearchPath? searchPath)
    {
        if (libraryName != LibraryName)
        {
            return IntPtr.Zero;
        }
        var path = ResolveLibraryPath();
        return NativeLibrary.Load(path);
    }

    // char *fastdoc_read_text_tree(const unsigned char *bytes, size_t len, const char *extension);
    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr fastdoc_read_text_tree(byte[] bytes, nuint len, byte[] extension);

    // char *fastdoc_take_last_error(void);
    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr fastdoc_take_last_error();

    // FastdocOfficeDocument *fastdoc_office_open(const unsigned char *bytes, size_t len, const char *extension);
    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr fastdoc_office_open(byte[] bytes, nuint len, byte[] extension);

    // void fastdoc_office_close(FastdocOfficeDocument *handle);
    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void fastdoc_office_close(IntPtr handle);

    // char *fastdoc_office_tree_json(const FastdocOfficeDocument *handle, const unsigned char *bytes, size_t len);
    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr fastdoc_office_tree_json(IntPtr handle, byte[] bytes, nuint len);

    // E2d: one embedded picture's bytes (base64), fetched lazily from the parse an already-open
    // handle still holds — NULL for a key this document does not have, a malformed key, or a
    // document that keeps no parse (docx/odt — their pictures come from the archive the host
    // holds, not this handle). See fastdoc_engine_ffi.h's own doc comment on this export.
    // char *fastdoc_office_image_base64(const FastdocOfficeDocument *handle, const char *key);
    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr fastdoc_office_image_base64(IntPtr handle, byte[] key);

    // void fastdoc_string_free(char *s);
    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void fastdoc_string_free(IntPtr s);

    // ---- E2c-1: text measurer + font provider ports, and the page-geometry FFI they unblock ----
    // (fastdoc_engine_ffi.h lines 94-225 — see docs' e2c-pagination-contract.md §1b/§1c/§1d).

    [StructLayout(LayoutKind.Sequential)]
    public struct FastdocTextMeasureTabStop
    {
        public byte Alignment;
        public double Location;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct FastdocTextMeasureParagraph
    {
        public byte Alignment;
        public double LineSpacing;
        public double LineHeightMultiple;
        public double MinimumLineHeight;
        public double MaximumLineHeight;
        public double SpacingBefore;
        public double SpacingAfter;
        public double FirstLineHeadIndent;
        public double HeadIndent;
        public double TailIndent;
        public IntPtr TabStops; // const FastdocTextMeasureTabStop*
        public nuint TabStopCount;
    }

    public const byte FastdocTextMeasureRunKindText = 0;
    public const byte FastdocTextMeasureRunKindAttachment = 1;

    [StructLayout(LayoutKind.Sequential)]
    public struct FastdocTextMeasureRun
    {
        public nuint ParagraphIndex;
        public byte Kind;
        public IntPtr FontName; // const char* — the face's OWN name, not family
        public double Size;
        [MarshalAs(UnmanagedType.I1)] public bool Bold;
        [MarshalAs(UnmanagedType.I1)] public bool Italic;
        public IntPtr Text; // const char*, null for an attachment run
        public double AttachmentWidth;
        public double AttachmentHeight;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct FastdocTextMeasurePayload
    {
        public IntPtr Paragraphs; // const FastdocTextMeasureParagraph*
        public nuint ParagraphCount;
        public IntPtr Runs; // const FastdocTextMeasureRun*
        public nuint RunCount;
    }

    /// <summary>`double (*measure)(const FastdocTextMeasurePayload *payload, double width_points)`.
    /// `payload` borrows Rust-owned memory for the duration of THIS call only — never retain the
    /// pointer past return (fastdoc_engine_ffi.h's own doc comment on the port).</summary>
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate double MeasureCallback(IntPtr payload, double widthPoints);

    /// <summary>One laid-out line (S3): `FastdocTextMeasureLine` in fastdoc_engine_ffi.h.
    /// `CharEnd` is a UTF-16 offset within the paragraph's own text; `Top` is measured from the top
    /// of the laid-out column; `Height` is the line's box under the paragraph style the payload
    /// carried.</summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct FastdocTextMeasureLine
    {
        public nuint ParagraphIndex;
        public nuint CharEnd;
        public double Top;
        public double Height;
        public double Baseline;
    }

    /// <summary>`size_t (*measure_lines)(payload, width_points, FastdocTextMeasureLine *out, size_t
    /// capacity)` — writes up to `capacity` lines and returns how many the layout HAS; the engine
    /// calls again with room for them all when that exceeds `capacity`.</summary>
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate nuint MeasureLinesCallback(IntPtr payload, double widthPoints, IntPtr output, nuint capacity);

    [StructLayout(LayoutKind.Sequential)]
    public struct FastdocTextMeasureCallbacks
    {
        public MeasureCallback Measure;
        public MeasureLinesCallback MeasureLines;
    }

    // bool fastdoc_install_text_measurer(FastdocTextMeasureCallbacks callbacks);
    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool fastdoc_install_text_measurer(FastdocTextMeasureCallbacks callbacks);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate ulong FaceNamedCallback(IntPtr name);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate ulong ResolveCallback(ulong baseFace, uint traits, IntPtr features, nuint featureCount);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate ulong SystemFaceCallback(double weight, [MarshalAs(UnmanagedType.I1)] bool monospaced);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void DescribeCallback(ulong face, IntPtr namePtr, nuint nameCap,
        IntPtr familyPtr, nuint familyCap, IntPtr hasFamilyPtr, IntPtr traitsPtr);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public delegate bool CoversCallback(ulong face, uint scalar);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate ulong SubstituteCallback(ulong declared, uint scalar);

    [StructLayout(LayoutKind.Sequential)]
    public struct FastdocFontProvider
    {
        public FaceNamedCallback FaceNamed;
        public ResolveCallback Resolve;
        public SystemFaceCallback SystemFace;
        public DescribeCallback Describe;
        public CoversCallback Covers;
        public SubstituteCallback Substitute;
    }

    // bool fastdoc_install_font_provider(FastdocFontProvider callbacks);
    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool fastdoc_install_font_provider(FastdocFontProvider callbacks);

    // bool fastdoc_office_band_sides(const FastdocOfficeDocument *handle, double column_width,
    //     double page_content_width, bool has_page_content_width,
    //     double page_margin_top, bool has_page_margin_top,
    //     double page_margin_bottom, bool has_page_margin_bottom,
    //     bool headers_on, bool footers_on, bool separates_pages,
    //     double desk_gap, bool has_desk_gap, double *out);
    // Fills out[0..3] = header, footer, band.
    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool fastdoc_office_band_sides(
        IntPtr handle, double columnWidth,
        double pageContentWidth, [MarshalAs(UnmanagedType.I1)] bool hasPageContentWidth,
        double pageMarginTop, [MarshalAs(UnmanagedType.I1)] bool hasPageMarginTop,
        double pageMarginBottom, [MarshalAs(UnmanagedType.I1)] bool hasPageMarginBottom,
        [MarshalAs(UnmanagedType.I1)] bool headersOn, [MarshalAs(UnmanagedType.I1)] bool footersOn,
        [MarshalAs(UnmanagedType.I1)] bool separatesPages,
        double deskGap, [MarshalAs(UnmanagedType.I1)] bool hasDeskGap,
        [In, Out] double[] out_);

    // bool fastdoc_office_sheets(const FastdocOfficeDocument *handle, long long count, double width,
    //     double text_origin_y, double leading_band, double pitch, double top_margin,
    //     double desk_gap, double *out, size_t out_capacity, size_t *out_count);
    // Fills out[0..count*4] as [x, y, width, height] per sheet.
    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool fastdoc_office_sheets(
        IntPtr handle, long count, double width, double textOriginY, double leadingBand,
        double pitch, double topMargin, double deskGap,
        [In, Out] double[] out_, nuint outCapacity, out nuint outCount);

    // ---- footnote bands (fastdoc_office_footnote_band_settle) ----

    [StructLayout(LayoutKind.Sequential)]
    public struct FastdocNoteBandEntry
    {
        public long Page;
        public double Value;
    }

    // char *fastdoc_office_page_plan_json(const FastdocOfficeDocument *handle, const char *input_json);
    // The page plan (S2): where every whole block goes, from the heights the host observed. Returns
    // An ok envelope carrying the PagePlanV1, or an error envelope; free with TakeOwnedString.
    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr fastdoc_office_page_plan_json(IntPtr handle, byte[] inputJson);

    // char *fastdoc_office_line_model_json(const char *input_json);
    // The line model (S3): placed line heights and table row heights from the line boxes the host
    // measured. An ok envelope carrying the LineModelOutput, or an error envelope; free with
    // TakeOwnedString.
    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr fastdoc_office_line_model_json(byte[] inputJson);

    [StructLayout(LayoutKind.Sequential)]
    public struct FastdocMasterTemplateDesc
    {
        public long Section;
        /// <summary>0 default, 1 first page, 2 even pages, 3 odd pages.</summary>
        public int AppliesTo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct FastdocMasterPageQuery
    {
        public long PageIndex;
        [MarshalAs(UnmanagedType.I1)] public bool HasSection;
        public long Section;
    }

    // bool fastdoc_office_master_selection(templates, template_count, vetoed_sections,
    //     vetoed_section_count, pages, page_count, out_template_index, out_capacity);
    // Static (no document handle): which master-page template covers each page, -1 for none.
    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool fastdoc_office_master_selection(
        [In] FastdocMasterTemplateDesc[] templates, nuint templateCount,
        [In] long[] vetoedSections, nuint vetoedSectionCount,
        [In] FastdocMasterPageQuery[] pages, nuint pageCount,
        [Out] long[] outTemplateIndex, nuint outCapacity);

    [StructLayout(LayoutKind.Sequential)]
    public struct FastdocFootnotePageDesc
    {
        public long PageIndex;
        public nuint NoteOffset;
        public nuint NoteCount;
        [MarshalAs(UnmanagedType.I1)] public bool HasSeparator;
        [MarshalAs(UnmanagedType.I1)] public bool SeparatorIsDeclared;
        public long SeparatorLineType;
        public double SeparatorLineWidthPt;
        public double SeparatorMarginTopPt;
        public double SeparatorMarginBottomPt;
        public double SeparatorNoteSpacingPt;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct FastdocFootnoteHistoryRoundDesc
    {
        public nuint EntryOffset;
        public nuint EntryCount;
    }

    // bool fastdoc_office_footnote_band_settle(pages, page_count, note_heights, note_heights_count,
    //     history_rounds, history_round_count, history_entries, history_entry_count,
    //     page_content_height, cap, out_bands, out_capacity, out_count, out_outcome, out_stop_reason);
    // Static: this round's bands per page and whether to retry (0) or stop (1) on them.
    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool fastdoc_office_footnote_band_settle(
        [In] FastdocFootnotePageDesc[] pages, nuint pageCount,
        [In] double[] noteHeights, nuint noteHeightsCount,
        [In] FastdocFootnoteHistoryRoundDesc[] historyRounds, nuint historyRoundCount,
        [In] FastdocNoteBandEntry[] historyEntries, nuint historyEntryCount,
        double pageContentHeight, long cap,
        [Out] FastdocNoteBandEntry[] outBands, nuint outCapacity, out nuint outCount,
        out int outOutcome, out int outStopReason);

    /// <summary>Marshals a UTF-8 NUL-terminated byte array for a `const char *extension` argument.</summary>
    public static byte[] Utf8NulTerminated(string s)
    {
        var bytes = System.Text.Encoding.UTF8.GetBytes(s);
        var withNul = new byte[bytes.Length + 1];
        Array.Copy(bytes, withNul, bytes.Length);
        return withNul;
    }

    /// <summary>Reads a `char *` this library owns as UTF-8, then frees it with
    /// fastdoc_string_free — the ownership rule fastdoc_engine_ffi.h states for every export on
    /// this page. Returns null for a NULL pointer (nothing to read, nothing to free).</summary>
    public static string? TakeOwnedString(IntPtr ptr)
    {
        if (ptr == IntPtr.Zero)
        {
            return null;
        }
        try
        {
            return Marshal.PtrToStringUTF8(ptr);
        }
        finally
        {
            fastdoc_string_free(ptr);
        }
    }

    /// <summary>The last diagnostic recorded for this thread, if any — mirrors
    /// fastdoc_take_last_error's own ownership (caller frees a non-NULL result).</summary>
    public static string? TakeLastError() => TakeOwnedString(fastdoc_take_last_error());
}
