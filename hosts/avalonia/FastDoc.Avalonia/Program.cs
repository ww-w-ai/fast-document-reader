using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Headless;
using Avalonia.Media;
using Avalonia.Media.TextFormatting;
using Avalonia.Threading;
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Threading;
using System.Threading.Tasks;
using FastDoc.Avalonia.Extract;
using FastDoc.Avalonia.Fonts;
using FastDoc.Avalonia.Native;
using FastDoc.Avalonia.Printing;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia;

class Program
{
    /// <summary>Set below, before the classic desktop lifetime starts, when the command line
    /// carried a single bare document path (no leading "--") — the file-association /
    /// double-click case on Windows and Linux. MainWindow reads this once in its constructor to
    /// auto-open the document; null means "start with an empty window" (menu-launch case).</summary>
    public static string? PendingDocumentPath { get; private set; }

    // Initialization code. Don't use any Avalonia, third-party APIs or any
    // SynchronizationContext-reliant code before AppMain is called: things aren't initialized
    // yet and stuff might break.
    //
    // Entry convention (mirrors the macOS app: --pdf/--extract are its only headless doors,
    // everything else is GUI — INVARIANTS.md 66/40): the flags below are the ONLY headless
    // paths. No args, or a single bare document path, always goes to the GUI — a document
    // handed to this process by a file association (a double-click on Windows/Linux) is a bare
    // path with no "--" prefix, and it must open a window, not exit silently.
    [STAThread]
    public static int Main(string[] args)
    {
        // Proves the single-instance pipe transport headlessly. An automation session
        // cannot open a real window (host-gate.sh step 4's comment: Avalonia GUI start exits 134
        // with no WindowServer connection), so this branch drives the SAME
        // NamedPipeServerStream/NamedPipeClientStream code the real forwarding path below uses,
        // with no GUI on either side. FMD_AVALONIA_PIPE_PROBE=1 is the SERVER role (listens for
        // exactly one message, prints it, exits); FMD_AVALONIA_PIPE_PROBE=client plus a path
        // argument is the CLIENT role (sends that path, exits). Checked before any args[0] switch
        // below because it is an env-var-gated mode, not a flag.
        var pipeProbeMode = Environment.GetEnvironmentVariable("FMD_AVALONIA_PIPE_PROBE");
        if (pipeProbeMode == "1")
        {
            Console.Error.WriteLine("mode: headless --pipe-probe");
            return RunPipeProbeServer();
        }
        if (pipeProbeMode == "client")
        {
            Console.Error.WriteLine("mode: headless --pipe-probe");
            if (args.Length < 1)
            {
                Console.Error.WriteLine("error: FMD_AVALONIA_PIPE_PROBE=client requires a path argument");
                return 1;
            }
            return RunPipeProbeClient(args[0]);
        }

        // Baseline path: exit before the engine library is even loaded, so a caller can time
        // pure .NET runtime boot (process start -> managed Main -> exit) separately from the
        // dylib-load + JIT-warmup cost the engine calls pay on their first invocation.
        if (args.Length > 0 && args[0] == "--noop")
        {
            Console.Error.WriteLine("mode: headless --noop");
            Console.WriteLine("noop");
            return 0;
        }

        // D4 paint probe: how long does the FFI call, the JSON deserialize, and the FIRST frame
        // of NodeTreeCanvas.Render take, for one real document, run under Avalonia.Headless (no
        // real window, no display server) so this is runnable on any machine including CI.
        if (args.Length > 1 && args[0] == "--paint-probe")
        {
            Console.Error.WriteLine("mode: headless --paint-probe");
            if (!TryEnsureEngineLoadable(gui: false, out var engineExitCode)) { return engineExitCode; }
            var repeatEnv = Environment.GetEnvironmentVariable("FMD_AVALONIA_REPEAT");
            var reps = !string.IsNullOrEmpty(repeatEnv) && int.TryParse(repeatEnv, out var r) && r > 0 ? r : 5;
            return RunPaintProbe(args[1], reps);
        }

        // --extract <path> opens the document through the SAME engine call the GUI uses, with no
        // AppBuilder/window started, and prints the document as MARKDOWN to stdout on success (an
        // office document goes through MarkdownSerializer.Serialize; markdown/plain text is
        // printed verbatim, matching HeadlessExtract.swift's own choice for those two kinds) or
        // "error: ..."/"exception: ..." on failure (S7-G). The "opened: N nodes, M ms" smoke line
        // the repeat/regression gates parse is on STDERR, alongside "mode: headless --extract"
        // below -- so a caller can trust stdout to be only the document, the same discipline
        // HeadlessExtract.swift states for its own two stdout/stderr channels. It used to be
        // triggered by a bare path with no flag, which is now the GUI's auto-open arg instead (see
        // the entry-convention note above).
        //
        // FMD_AVALONIA_REPEAT=N reopens the SAME document N times in this one process and
        // prints one "rep i: M ms" line per attempt, so a caller can tell a cold first call
        // (dylib load + JIT warmup) apart from warm, already-JITted reopens.
        if (args.Length > 1 && args[0] == "--extract")
        {
            Console.Error.WriteLine("mode: headless --extract");
            if (!TryEnsureEngineLoadable(gui: false, out var engineExitCode)) { return engineExitCode; }
            var repeatEnv = Environment.GetEnvironmentVariable("FMD_AVALONIA_REPEAT");
            if (!string.IsNullOrEmpty(repeatEnv) && int.TryParse(repeatEnv, out var repeatCount) && repeatCount > 1)
            {
                return RunHeadlessRepeat(args[1], repeatCount);
            }
            return RunHeadless(args[1]);
        }

        // E2c-1: --sheets <path> paginates the document (same PageLayout the GUI's page mode
        // uses) with no window, and prints "sheets: N" plus one page-geometry line — the S4
        // pagination gate's own count, comparable to macOS's `--pdf` reader.printSheets.count
        // (see docs/studio/sprints/S4/measurements.md's E2c-1 section for the reference numbers).
        if (args.Length > 1 && args[0] == "--sheets")
        {
            Console.Error.WriteLine("mode: headless --sheets");
            if (!TryEnsureEngineLoadable(gui: false, out var engineExitCode)) { return engineExitCode; }
            return RunSheets(args[1]);
        }

        // E6: --pdf <input> <output> renders every page through the SAME FlowDocumentView the
        // GUI's File > Export PDF... menu item calls (PdfExporter.ExportPdf) -- prints "pages: N"
        // on success, matching the macOS app's `--pdf` contract (INVARIANTS.md 66: GUI print and
        // the headless door share one function) even though this host's PDF path is raster today,
        // not the print pipeline itself (see Printing/PdfExporter.cs's own doc).
        if (args.Length > 2 && args[0] == "--pdf")
        {
            Console.Error.WriteLine("mode: headless --pdf");
            if (!TryEnsureEngineLoadable(gui: false, out var engineExitCode)) { return engineExitCode; }
            return RunPdf(args[1], args[2]);
        }

        if (args.Length > 0 && args[0].StartsWith("--", StringComparison.Ordinal))
        {
            Console.Error.WriteLine($"error: unknown flag {args[0]}");
            return 1;
        }

        if (!TryEnsureEngineLoadable(gui: true, out var guiEngineExitCode)) { return guiEngineExitCode; }
        PendingDocumentPath = args.Length > 0 ? args[0] : null;
        Console.Error.WriteLine("mode: gui");

        // Single instance: a named Mutex decides which process is primary. The primary opens
        // its window as normal (below) and additionally starts a pipe server; every OTHER launch
        // forwards its document path to that server and exits without ever building an AppBuilder
        // or a window. If the primary cannot be reached (e.g. it is mid-shutdown and the Mutex is
        // momentarily unclaimed by anyone), this process falls through and opens its own window
        // rather than exiting with nothing visible to the user.
        if (TryClaimPrimaryInstance(out var singleInstanceMutex))
        {
            _singleInstanceMutex = singleInstanceMutex;
            StartSingleInstancePipeServer();
        }
        else if (TryForwardToPrimaryInstance(PendingDocumentPath))
        {
            return 0;
        }

        var appBuilder = BuildAvaloniaApp();
        if (Environment.GetEnvironmentVariable("FMD_AVALONIA_GUI_EXIT_IMMEDIATELY") == "1")
        {
            // AfterSetup runs on the UI thread once Avalonia's platform init has completed, so
            // scheduling the shutdown timer here (rather than from an independent background
            // Timer racing that init) avoids handing Dispatcher.UIThread's first-ever access to
            // the wrong thread — which throws "the calling thread cannot access this object"
            // during AvaloniaNativePlatform.Initialize. Measured: an unconditioned background
            // Timer reproduced that crash on every run.
            appBuilder = appBuilder.AfterSetup(_ =>
            {
                var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
                timer.Tick += (_, _) =>
                {
                    timer.Stop();
                    if (Application.Current?.ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
                    {
                        desktop.Shutdown();
                    }
                };
                timer.Start();
            });
        }
        appBuilder.StartWithClassicDesktopLifetime(args);
        return 0;
    }

    /// <summary>Set when the engine library could not be found, so <see cref="App"/>'s
    /// OnFrameworkInitializationCompleted shows an error window instead of the real
    /// <see cref="MainWindow"/> (which would immediately fault on its first engine call). Null in
    /// every normal run.</summary>
    public static string? EngineMissingDetail { get; private set; }

    /// <summary>Calls <see cref="FastdocEngine.EnsureLoadable"/> and, on failure, reports it and
    /// returns the process exit code the caller should return immediately — a missing/misplaced
    /// engine library is an ENVIRONMENT failure (exit 2), never a bare stack trace (
    /// docs/studio/sprints/S6/s6e-error-surface.md scenarios 3a/3b: previously an unhandled
    /// exception before any window or output appeared). <paramref name="gui"/> selects how the
    /// failure is shown: a headless door writes one stderr line, the GUI entry additionally tries
    /// to put up a small window naming the paths tried.</summary>
    private static bool TryEnsureEngineLoadable(bool gui, out int exitCode)
    {
        try
        {
            FastdocEngine.EnsureLoadable();
            exitCode = 0;
            return true;
        }
        catch (InvalidOperationException ex)
        {
            exitCode = HandleEngineMissing(ex.Message, gui);
            return false;
        }
    }

    private static int HandleEngineMissing(string detail, bool gui)
    {
        var oneLine = $"engine library not found: {detail}";
        if (!gui)
        {
            Console.Error.WriteLine(oneLine);
            return 2;
        }
        try
        {
            EngineMissingDetail = detail;
            BuildAvaloniaApp().StartWithClassicDesktopLifetime(Array.Empty<string>());
        }
        catch (Exception)
        {
            // No WindowServer/Aqua bootstrap (or any other platform failure) to put a window in
            // — the same limitation host-gate.sh's step 4 comment already documents for a
            // HEALTHY engine's no-args GUI smoke. Fall back to the same one-line stderr message
            // the headless doors use rather than letting this exception surface unhandled.
            Console.Error.WriteLine(oneLine);
        }
        return 2;
    }

    /// <summary>Turns a headless-door exception into ONE line naming the common cases in plain
    /// words (file not found / is a directory / permission denied) rather than a .NET type name,
    /// with the full ToString() (stack trace, inner exceptions) appended only under
    /// FMD_AVALONIA_DEBUG=1 — a normal run never leaks this machine's absolute paths or internal
    /// call chain (s6e-error-surface.md scenarios 4/6/7). <paramref name="path"/> is the
    /// document path this door was asked to open, when known, used only to word the sentence and
    /// to tell a directory apart from a permission-denied file (both raise
    /// UnauthorizedAccessException on macOS with no distinguishing message).</summary>
    private static string DescribeHeadlessException(Exception ex, string? path)
    {
        string oneLine = ex switch
        {
            FileNotFoundException or DirectoryNotFoundException =>
                $"file not found: {path ?? ex.Message}",
            UnauthorizedAccessException when path is not null && Directory.Exists(path) =>
                $"is a directory: {path}",
            UnauthorizedAccessException =>
                $"permission denied: {path ?? ex.Message}",
            _ => ex.Message,
        };
        if (Environment.GetEnvironmentVariable("FMD_AVALONIA_DEBUG") == "1")
        {
            return $"{oneLine}\n{ex}";
        }
        return oneLine;
    }

    private static int RunPdf(string inputPath, string outputPath)
    {
        // TextLayout (this export's raster pass) needs Avalonia's font manager/platform set up --
        // the same headless bootstrap --sheets/--paint-probe perform, with no window, PLUS the
        // bundled Korean fallback (RunSheets/RunPaintProbe don't need it; this path draws real
        // glyphs into a bitmap that becomes the PDF page, so a font-less CI box must still resolve
        // Hangul the same way the GUI does) AND UseHeadlessDrawing=false -- the default headless
        // backend fakes drawing (no real Skia surface behind it, CaptureRenderedFrame returns
        // null), which is fine for --sheets/--paint-probe (they never look at pixels) but not for
        // a PDF page, which literally IS the captured pixels.
        AppBuilder.Configure<App>()
            .UseSkia()
            .UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false })
            .WithBundledKoreanFallback()
            .SetupWithoutStarting();
        try
        {
            var result = PdfExporter.ExportPdf(inputPath, outputPath);
            Console.WriteLine($"pages: {result.PageCount}");
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"error: {DescribeHeadlessException(ex, inputPath)}");
            return 1;
        }
    }

    private static int RunSheets(string path)
    {
        // TextLayout (PageLayout's own line-breaking) needs Avalonia's font manager/platform
        // set up — the same headless bootstrap --paint-probe performs below, with no window.
        AppBuilder.Configure<App>()
            .UseHeadless(new AvaloniaHeadlessPlatformOptions())
            .WithBundledKoreanFallback()
            .SetupWithoutStarting();
        try
        {
            var result = Rendering.RenderTreeLoader.Load(path);
            using var _ = result.Handle;
            if (!result.IsOk)
            {
                var extension = System.IO.Path.GetExtension(path).TrimStart('.');
                Console.WriteLine($"error: {Native.EngineErrorText.Humanize(result.Error?.Kind, result.Error?.Message, extension)}");
                return 1;
            }

            var geometry = FastDoc.Avalonia.Paging.PageGeometry.FromDocument(result.Tree!);
            if (geometry is null)
            {
                Console.WriteLine("sheets: 0 (no declared page geometry)");
                return 0;
            }

            var blocks = Rendering.FlowDocumentBuilder.Build(result.Tree!);
            var markers = FastDoc.Avalonia.Paging.BlockPageMarkers.Compute(result.Tree!);
            // A cell's own pictures/nested tables must reserve real height here too, or this CLI's
            // sheet count disagrees with the GUI/--pdf page count for the exact same document (both
            // go through PageLayout.BuildWithTableSettle) — bound the same way FlowDocumentView
            // binds its own instance (SetHandle for hwp/hwpx's live-parse fetch, SetZipSource for
            // docx/odt's zip-archive fetch), so a cell picture with no eagerly-inlined bytes still
            // resolves here exactly as it would on screen.
            var imageRenderer = new Rendering.ImageBlockRenderer();
            imageRenderer.Reset(result.Tree);
            imageRenderer.SetHandle(result.Handle);
            imageRenderer.SetZipSource(path, System.IO.Path.GetExtension(path));
            // splitTablesDefault: true mirrors PageViewOptions.default.splitTables (Swift) — this
            // headless CLI has no per-document preference store, so it uses the document-level
            // default every fresh document opens with.
            var (layout, settleRounds, pushedCount, oversizedCount) =
                FastDoc.Avalonia.Paging.PageLayout.BuildWithTableSettle(blocks, markers, geometry,
                    result.Handle?.RawHandle ?? IntPtr.Zero, headersOn: true, footersOn: true,
                    splitTablesDefault: true, imageRenderer: imageRenderer);

            Console.WriteLine($"sheets: {layout.PageCount}");
            Console.WriteLine(
                $"page: {geometry.PageWidthPoints:F1}x{geometry.PageHeightPoints:F1} " +
                $"content: {layout.PageContentWidthPoints:F1}x{layout.PageContentHeightPoints:F1} " +
                $"band: {layout.Band.HeaderPoints:F1}/{layout.Band.FooterPoints:F1}/{layout.Band.BandPoints:F1} " +
                $"(fromEngine={layout.Band.FromEngine})");
            Console.WriteLine($"settle rounds: {settleRounds}, pushed: {pushedCount}, oversized: {oversizedCount}");
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"exception: {DescribeHeadlessException(ex, path)}");
            return 1;
        }
    }

    private static int RunHeadless(string path)
    {
        try
        {
            var result = RenderTreeLoader.Load(path);
            // E2d: this smoke path prints and exits -- nothing here ever draws a picture, so the
            // handle (if any) is dispose-on-print rather than held past this call.
            using var _ = result.Handle;
            if (result.IsOk)
            {
                // S7-G: the smoke diagnostic moved to stderr (Scripts/host-gate.sh reads it there
                // now) so stdout is free to carry the document itself, matching HeadlessExtract
                // .swift's own discipline: "Errors go to stderr, never stdout, so a caller can
                // trust stdout to be only the document" -- this is the success line that used to
                // share stdout with nothing, and now would share it with real content.
                Console.Error.WriteLine($"opened: {result.Tree!.Nodes.Count} nodes, {result.ElapsedMs} ms");
                Console.WriteLine(BuildExtractedMarkdown(path, result.Tree!));
                return 0;
            }
            var errExtension = System.IO.Path.GetExtension(path).TrimStart('.');
            Console.WriteLine($"error: {Native.EngineErrorText.Humanize(result.Error?.Kind, result.Error?.Message, errExtension)}");
            return 1;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"exception: {DescribeHeadlessException(ex, path)}");
            return 1;
        }
    }

    /// <summary>S8-B2: the SAME extraction the headless <c>--extract</c> door above prints, factored
    /// out so File ▸ "Extract to Markdown…" (MainWindow.axaml.cs) calls this exact code rather than
    /// a second implementation -- an office document goes through <see cref="MarkdownSerializer"/>
    /// .Serialize with the <see cref="ExtractHeader"/> legend prefixed; markdown/plain text is
    /// printed verbatim (re-deriving Markdown from the parsed structure risks a formatting drift
    /// the raw bytes never had -- the same reasoning as invariant 40's HeadlessExtract.swift
    /// choice). <paramref name="tree"/> must be the tree <see cref="RenderTreeLoader"/> loaded for
    /// <paramref name="path"/> -- this method does not re-open the document itself.</summary>
    internal static string BuildExtractedMarkdown(string path, Model.RenderTree tree)
    {
        var extension = System.IO.Path.GetExtension(path).TrimStart('.');
        if (RenderTreeLoader.IsOfficeExtension(extension))
        {
            var body = MarkdownSerializer.Serialize(tree);
            return ExtractHeader(path, body) + body;
        }
        // Already Markdown/plain text: printed verbatim, the SAME choice HeadlessExtract.swift
        // makes for .markdown/.plainText (invariant 40).
        return System.IO.File.ReadAllText(path);
    }

    /// <summary>S7-G: a short HTML-comment legend at the very top -- invisible to a Markdown
    /// renderer, visible to an agent reading the raw text -- mirroring HeadlessExtract.swift's
    /// `header(for:body:)`. Added only for an office document's serialized body (never for
    /// markdown/plain-text passthrough, which macOS doesn't decorate either); the &lt;raw&gt; line
    /// only when the body actually used the marker.</summary>
    private static string ExtractHeader(string path, string body)
    {
        var note = $"<!-- Extracted from {System.IO.Path.GetFileName(path)} by FastDoc. Best-effort Markdown. -->\n";
        if (body.Contains(MarkdownSerializer.RawOpen))
        {
            note += $"<!-- {MarkdownSerializer.RawOpen}…{MarkdownSerializer.RawClose}" +
                    " marks content whose original structure (e.g. merged-cell tables) could not be " +
                    "safely mapped; treat the text inside as literal. -->\n";
        }
        return note + "\n";
    }

    private static int RunHeadlessRepeat(string path, int count)
    {
        try
        {
            for (var i = 1; i <= count; i++)
            {
                var result = RenderTreeLoader.Load(path);
                // E2d: each rep reopens the SAME file fresh (measuring cold-open cost, per the
                // comment above) -- its handle answers no query in this loop, so close it before
                // the next rep rather than accumulating open native handles across reps.
                using var _ = result.Handle;
                if (result.IsOk)
                {
                    Console.WriteLine($"rep {i}: {result.ElapsedMs} ms");
                }
                else
                {
                    var extension = System.IO.Path.GetExtension(path).TrimStart('.');
                    Console.WriteLine($"rep {i}: error {Native.EngineErrorText.Humanize(result.Error?.Kind, result.Error?.Message, extension)}");
                    return 1;
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"exception: {DescribeHeadlessException(ex, path)}");
            return 1;
        }
    }

    // Reps repeat times: for each, open the document fresh (FFI + deserialize timed separately by
    // RenderTreeLoader.LoadWithBreakdown), build a NEW FlowDocumentView from that tree, host it in
    // a headless window, and time CaptureRenderedFrame — which forces layout + the FIRST Render
    // call to actually run, the same way opening a real window would. One line per rep:
    // "probe rep i: ffi=F ms deserialize=D ms paint=P ms".
    //
    // After the reps, the LAST window stays open for a five-step scroll sweep (0/25/50/75/100% of
    // content height) — each step sets ScrollOffset directly (no pointer, headless) and times the
    // forced re-render, printing "scroll k: M ms" so a caller can see whether the virtualized
    // offset table stays cheap once real (not estimated) heights have settled in from the reps.
    private static int RunPaintProbe(string path, int reps)
    {
        AppBuilder.Configure<App>()
            .UseHeadless(new AvaloniaHeadlessPlatformOptions())
            .WithBundledKoreanFallback()
            .SetupWithoutStarting();

        // E4 font-bundle check: lay out a Hangul syllable through the SAME TextLayout path
        // FlowDocumentView uses, with a base typeface ("Inter") that has no Hangul glyph.
        // Measured, two ways that turned out NOT to be valid signals: (1) TextLayout/GlyphRun's
        // ADVANCE width (layout.Width, GlyphRun.Bounds) stays nonzero (the font's default em
        // width) even for Skia's .notdef ("tofu") glyph, so a font-less run and a real-glyph run
        // both report width>0 — reproduced with width=32 both with and without the bundled
        // fallback registered. (2) GlyphRun.InkBounds — expected to be the real black-pixel
        // extent — is Rect(0,0,0,0) in BOTH cases too; this codepath only shapes, it does not
        // rasterize, and InkBounds is apparently not computed until an actual paint happens.
        // GlyphTypeface.FamilyName IS the valid signal: it names which font resolved the
        // character, and differs cleanly — "BareMinimum" (Avalonia's built-in placeholder,
        // Skia's tofu source) with the fallback disabled, "Noto Sans KR" with it enabled —
        // confirmed on a font-less Linux container (fontprobe: family=BareMinimum without the
        // fallback, family=Noto Sans KR with it, same container, same document).
        try
        {
            var fontProbeLayout = new TextLayout(
                "가", // U+AC00 — first syllable of the Hangul block this fallback covers.
                new Typeface("Inter"),
                16,
                Brushes.Black,
                TextAlignment.Left,
                TextWrapping.NoWrap,
                maxWidth: double.PositiveInfinity);
            var shapedRun = (ShapedTextRun)fontProbeLayout.TextLines[0].TextRuns[0];
            var glyphRun = shapedRun.GlyphRun;
            Console.Error.WriteLine(
                $"fontprobe: inkWidth={glyphRun.InkBounds.Width}, inkHeight={glyphRun.InkBounds.Height}, family={glyphRun.GlyphTypeface.FamilyName}");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"fontprobe: exception {ex.Message}");
        }

        // Same signal as above, for a Hanja character (U+6F22 "漢") — the bundled Noto Sans KR
        // font (docs/studio/sprints/S5/measurements.md) carries Hanja glyphs, so this should also
        // resolve to "Noto Sans KR" rather than falling through to BareMinimum/tofu.
        try
        {
            var hanjaProbeLayout = new TextLayout(
                "漢", // U+6F22 — common Hanja, also present in the reader's own demo corpus.
                new Typeface("Inter"),
                16,
                Brushes.Black,
                TextAlignment.Left,
                TextWrapping.NoWrap,
                maxWidth: double.PositiveInfinity);
            var hanjaShapedRun = (ShapedTextRun)hanjaProbeLayout.TextLines[0].TextRuns[0];
            var hanjaGlyphRun = hanjaShapedRun.GlyphRun;
            Console.Error.WriteLine(
                $"fontprobe-hanja: inkWidth={hanjaGlyphRun.InkBounds.Width}, inkHeight={hanjaGlyphRun.InkBounds.Height}, family={hanjaGlyphRun.GlyphTypeface.FamilyName}");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"fontprobe-hanja: exception {ex.Message}");
        }

        try
        {
            FlowDocumentView? lastView = null;
            Window? lastWindow = null;
            Rendering.OfficeDocumentHandle? lastHandle = null;

            for (var i = 1; i <= reps; i++)
            {
                var breakdown = RenderTreeLoader.LoadWithBreakdown(path);
                if (!breakdown.IsOk)
                {
                    breakdown.Handle?.Dispose();
                    Console.WriteLine($"probe rep {i}: error [{breakdown.Error?.Kind}] {breakdown.Error?.Message}");
                    return 1;
                }

                var view = new FlowDocumentView();
                view.SetTree(breakdown.Tree);
                view.SetHandle(breakdown.Handle); // must follow SetTree — see FlowDocumentView.SetHandle's own doc
                view.SetZipSource(breakdown.DocumentPath, System.IO.Path.GetExtension(path)); // docx/odt lazy pictures

                var window = new Window
                {
                    Width = 1200,
                    Height = 900,
                    Content = view,
                };
                window.Show();

                var paintWatch = Stopwatch.StartNew();
                window.CaptureRenderedFrame();
                paintWatch.Stop();

                Console.WriteLine(
                    $"probe rep {i}: ffi={breakdown.FfiMs} ms deserialize={breakdown.DeserializeMs} ms paint={paintWatch.ElapsedMilliseconds} ms");

                if (i == reps)
                {
                    lastView = view;
                    lastWindow = window;
                    lastHandle = breakdown.Handle;
                }
                else
                {
                    window.Close();
                    breakdown.Handle?.Dispose();
                }
            }

            if (lastView is not null && lastWindow is not null)
            {
                var fractions = new[] { 0.0, 0.25, 0.5, 0.75, 1.0 };
                for (var k = 0; k < fractions.Length; k++)
                {
                    var maxScroll = Math.Max(0, lastView.ContentHeight - lastWindow.Height);
                    lastView.ScrollOffset = maxScroll * fractions[k];
                    var scrollWatch = Stopwatch.StartNew();
                    lastWindow.CaptureRenderedFrame();
                    scrollWatch.Stop();
                    Console.WriteLine($"scroll {k}: {scrollWatch.ElapsedMilliseconds} ms");
                }
                // E2d: printed after the scroll sweep so every visible block has had a chance to
                // draw at least once (virtualization only builds a real TextLayout for a block
                // that was actually revealed) -- a count taken right after the first frame would
                // undercount a document whose pictures sit below the fold.
                Console.Error.WriteLine(
                    $"decodeSuccess={lastView.ImageDecodeSuccessCount} decodeFail={lastView.ImageDecodeFailureCount}");
                lastWindow.Close();
                lastHandle?.Dispose();
            }

            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"exception: {DescribeHeadlessException(ex, path)}");
            return 1;
        }
    }

    // Single instance. Avalonia 12 has no built-in "single instance, forward args to the running
    // window" API (checked: no SingleInstance/IActivatable/SingleOrNewInstance symbol in the
    // Avalonia, Avalonia.Desktop or Avalonia.Controls XML docs shipped with the 12.1.2 NuGet
    // packages). This is the standard .NET pattern for it — a named Mutex decides "am I first",
    // and a named pipe lets a second launch (a second file double-clicked while the app is
    // already open) hand its document path to the first process, which opens it in its EXISTING
    // window and activates it, instead of a second window appearing.
    //
    // Naming: the Mutex name MUST carry the "Global\" prefix. Measured on Ubuntu 24.04 (S7-H): an
    // unprefixed name is scoped by .NET's Unix PAL to the process's SESSION id — it lives at
    // $TMPDIR/.dotnet/shm/session<sid>/<name> — and every desktop launch (xdg-open, the launcher,
    // a file double-click) runs under a fresh session, so two double-clicks each saw createdNew
    // and two windows appeared; only launches from the SAME terminal ever forwarded. "Global\"
    // maps to $TMPDIR/.dotnet/shm/global/ on Unix and to the machine-wide namespace on Windows,
    // which is why the user name is appended: on a multi-user box each user must get their own
    // primary rather than forwarding into another user's pipe (which CurrentUserOnly would
    // reject, falling through to a second window — correct, but slower). System.IO.Pipes'
    // NamedPipeServerStream/NamedPipeClientStream are a single cross-platform API (Windows named
    // pipes; a Unix domain socket under /tmp on macOS/Linux) and take no prefix at all, so
    // SingleInstancePipeName needs no platform branch.
    //
    // The pipe name is kept SHORT deliberately (measured, not guessed): on macOS/Linux
    // NamedPipeServerStream backs onto a Unix domain socket at $TMPDIR/CoreFxPipe_<name>, and
    // AF_UNIX socket paths are capped at 104 bytes on macOS (108 on Linux) INCLUDING that
    // directory and prefix. A first attempt named "ai.ww-w.fast-md-reader.avalonia.single-
    // instance.pipe" (54 chars) overran the cap under this machine's $TMPDIR
    // (/var/folders/.../T/, ~51 chars) with "path ... is of an invalid length for use with domain
    // sockets" on BOTH the probe server and client. The Mutex name has no such constraint (it is
    // not a filesystem path) but is shortened to match for one obvious pair of names.
    private static readonly string SingleInstanceMutexName =
        @"Global\ai.ww-w.fastdoc.avalonia.mutex." + Environment.UserName;
    private const string SingleInstancePipeName = "ai.ww-w.fastdoc.avalonia.pipe";

    // 2s: long enough for a healthy primary (already running, event loop free) to accept a pipe
    // connection, short enough that a launch racing a primary's shutdown falls through to opening
    // its own window instead of hanging the double-click the user just made.
    private static readonly TimeSpan PrimaryInstanceConnectTimeout = TimeSpan.FromSeconds(2);

    // Kept alive for the process lifetime once claimed (a static field is a GC root) — an
    // unreferenced Mutex is eligible for finalization, which would release the claim out from
    // under a still-running primary instance.
    private static Mutex? _singleInstanceMutex;

    /// <summary>True if this process won the race to be the primary instance; ownership of
    /// <paramref name="mutex"/> passes to the caller, which must keep it referenced for the
    /// process lifetime (see <see cref="_singleInstanceMutex"/>). False means another instance
    /// already holds it — the caller should forward its document path via
    /// <see cref="TryForwardToPrimaryInstance"/> instead of starting a second GUI.</summary>
    private static bool TryClaimPrimaryInstance(out Mutex mutex)
    {
        mutex = new Mutex(initiallyOwned: true, name: SingleInstanceMutexName, out var createdNew);
        return createdNew;
    }

    /// <summary>Sends <paramref name="path"/> (or an empty line, meaning "just activate the
    /// window") to the primary instance's pipe server. Returns false — meaning "no primary
    /// reachable, open your own window" — on ANY failure: no listener, a timeout, or the primary
    /// closing the pipe mid-write. A launch racing the primary's shutdown must fall through
    /// rather than exit with nothing visible to the user.</summary>
    private static bool TryForwardToPrimaryInstance(string? path)
    {
        try
        {
            // CurrentUserOnly restricts the pipe to this OS user's own session — without it, the
            // fixed, predictable pipe name is reachable by any other local user on a multi-user
            // machine, who could otherwise forward an arbitrary file path into this app's window
            // under this user's identity. Supported cross-platform (.NET docs: Windows sets a
            // DACL restricting to the current user's SID; Unix sets the socket file's owner and
            // 0700 permissions) — the matching server side sets the same option.
            using var client = new NamedPipeClientStream(".", SingleInstancePipeName, PipeDirection.Out,
                PipeOptions.CurrentUserOnly);
            client.Connect((int)PrimaryInstanceConnectTimeout.TotalMilliseconds);
            using var writer = new StreamWriter(client) { AutoFlush = true };
            writer.WriteLine(path ?? string.Empty);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>Runs for the lifetime of the primary instance on a background task: accepts one
    /// pipe connection at a time, reads the single line a forwarding launch sends, and marshals
    /// the open onto the UI thread. A per-iteration try/catch plus a short backoff means one
    /// misbehaving client (a stalled write, an unexpected disconnect) cannot permanently kill
    /// forwarding for the rest of the session.</summary>
    private static void StartSingleInstancePipeServer()
    {
        _ = Task.Run(async () =>
        {
            while (true)
            {
                try
                {
                    // CurrentUserOnly — see TryForwardToPrimaryInstance's matching comment on why.
                    using var server = new NamedPipeServerStream(SingleInstancePipeName, PipeDirection.In, 1,
                        PipeTransmissionMode.Byte, PipeOptions.CurrentUserOnly);
                    await server.WaitForConnectionAsync().ConfigureAwait(false);
                    using var reader = new StreamReader(server);
                    var path = await reader.ReadLineAsync().ConfigureAwait(false);
                    await Dispatcher.UIThread.InvokeAsync(() => ActivateAndMaybeLoad(path));
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"single-instance pipe server error: {ex.Message}");
                    await Task.Delay(500).ConfigureAwait(false);
                }
            }
        });
    }

    /// <summary>UI-thread callback for a forwarded open: loads <paramref name="path"/> into the
    /// EXISTING main window (empty/null means "just bring the window forward, nothing to open" —
    /// the no-args double-launch case) and brings it to front, restoring it first if minimized.
    /// A no-op if the application has not finished creating its main window yet (a forwarding
    /// launch racing this process's own startup) — nothing calls this before then, but a stale
    /// message on a slow start should not throw.</summary>
    private static void ActivateAndMaybeLoad(string? path)
    {
        if (Application.Current?.ApplicationLifetime is not IClassicDesktopStyleApplicationLifetime desktop
            || desktop.MainWindow is not MainWindow mainWindow)
        {
            return;
        }
        if (!string.IsNullOrEmpty(path))
        {
            mainWindow.LoadPath(path);
        }
        if (mainWindow.WindowState == WindowState.Minimized)
        {
            mainWindow.WindowState = WindowState.Normal;
        }
        mainWindow.Activate();
    }

    private static int RunPipeProbeServer()
    {
        try
        {
            // CurrentUserOnly — see TryForwardToPrimaryInstance's matching comment on why.
            using var server = new NamedPipeServerStream(SingleInstancePipeName, PipeDirection.In, 1,
                PipeTransmissionMode.Byte, PipeOptions.CurrentUserOnly);
            var connected = server.WaitForConnectionAsync().Wait(TimeSpan.FromSeconds(5));
            if (!connected)
            {
                Console.Error.WriteLine("error: pipe-probe server timed out waiting for a connection");
                return 1;
            }
            using var reader = new StreamReader(server);
            var path = reader.ReadLine() ?? string.Empty;
            Console.Error.WriteLine($"received-path: {path}");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"error: pipe-probe server failed: {ex.Message}");
            return 1;
        }
    }

    private static int RunPipeProbeClient(string path)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", SingleInstancePipeName, PipeDirection.Out,
                PipeOptions.CurrentUserOnly);
            client.Connect((int)PrimaryInstanceConnectTimeout.TotalMilliseconds);
            using var writer = new StreamWriter(client) { AutoFlush = true };
            writer.WriteLine(path);
            Console.WriteLine($"sent-path: {path}");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"error: pipe-probe client failed: {ex.Message}");
            return 1;
        }
    }

    // Avalonia configuration, don't remove; also used by visual designer.
    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>()
            .UsePlatformDetect()
#if DEBUG
            .WithDeveloperTools()
#endif
            .WithInterFont()
            .WithBundledKoreanFallback()
            .LogToTrace();
}
