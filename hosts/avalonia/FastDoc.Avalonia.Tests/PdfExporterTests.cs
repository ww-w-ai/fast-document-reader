using System;
using System.Diagnostics;
using System.IO;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// E6: exercises PdfExporter end to end through the SAME `--pdf` door host-gate.sh's own PDF step
/// drives, by shelling out to the already-built host binary rather than calling
/// FastDoc.Avalonia.Printing.PdfExporter in-process.
///
/// This is a deliberate departure from the fixture-JSON pattern PagingTests/RenderTreeEnvelopeTests
/// use (build a RenderTree from a string, call the unit directly, no process). PdfExporter.WritePdf
/// constructs a real Avalonia <c>Window</c> to host the view it renders (see that class's own doc:
/// a detached Control produces a zero-byte frame with nothing behind it), and creating a Window
/// asserts Dispatcher thread ownership — the SAME assertion [STAThread] Program.Main satisfies by
/// construction, but that an xunit worker thread does not, since the shared
/// <see cref="AvaloniaHeadlessSetup"/> static constructor and a given test METHOD are not
/// guaranteed to run on the same physical thread. Measured: calling WritePdf directly from a test
/// throws "The calling thread cannot access this object because a different thread owns it.", and
/// marshaling onto Dispatcher.UIThread via Invoke() deadlocks (headless SetupWithoutStarting never
/// runs a pump for another thread's Invoke to land on). A subprocess sidesteps this entirely — the
/// child process's own Main owns its own UI thread outright, matching how a real user's `--pdf`
/// invocation runs. The trade-off: these two tests need the real engine dylib and a prior Release
/// build (like host-gate.sh's own step 3+), so they SKIP (not fail) when either is absent — this
/// project's own "no FASTDOC_ENGINE_LIB needed" gate step (host-gate.sh step 2) still passes with
/// nothing configured; the real assertions run once host-gate.sh's later steps have built and
/// pointed at the engine.
/// </summary>
public class PdfExporterTests
{
    private static readonly string RepoRoot = ResolveRepoRoot();
    private static readonly string HostDll = Path.Combine(RepoRoot, "hosts", "avalonia", "FastDoc.Avalonia", "bin", "Release", "net9.0", "FastDoc.Avalonia.dll");
    private static readonly string EngineLib = Environment.GetEnvironmentVariable("FASTDOC_ENGINE_LIB")
        ?? Path.Combine(RepoRoot, "rust", "dist", "xplat", "macos-arm64", "libfastdoc_engine_ffi.dylib");

    // hosts/avalonia/FastDoc.Avalonia.Tests/bin/Release/net9.0 -> repo root is six levels up.
    private static string ResolveRepoRoot() =>
        Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", ".."));

    private static bool PrerequisitesMissing(out string reason)
    {
        if (!File.Exists(HostDll))
        {
            reason = $"host build not found at {HostDll} (run: dotnet build FastDoc.Avalonia.csproj -c Release)";
            return true;
        }
        if (!File.Exists(EngineLib))
        {
            reason = $"engine library not found at {EngineLib} (set FASTDOC_ENGINE_LIB, or build with Scripts/build-engine-xplat.sh)";
            return true;
        }
        reason = "";
        return false;
    }

    private static (int ExitCode, string Stdout, string Stderr) RunPdfCli(string inputPath, string outputPath)
    {
        var psi = new ProcessStartInfo
        {
            FileName = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH") ?? "dotnet", // set by `dotnet test`; the bare name serves a shell that has it on PATH
            ArgumentList = { "exec", HostDll, "--pdf", inputPath, outputPath },
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        psi.Environment["FASTDOC_ENGINE_LIB"] = EngineLib;

        using var process = Process.Start(psi)!;
        var stdout = process.StandardOutput.ReadToEnd();
        var stderr = process.StandardError.ReadToEnd();
        process.WaitForExit(60_000);
        return (process.ExitCode, stdout, stderr);
    }

    [Fact]
    public void Empty_markdown_document_exports_to_exactly_one_page()
    {
        if (PrerequisitesMissing(out var reason))
        {
            Console.WriteLine($"SKIP (prerequisites missing): {reason}");
            return;
        }

        var inputPath = Path.Combine(Path.GetTempPath(), $"fastdoc-pdf-test-{Guid.NewGuid():N}.md");
        var outputPath = Path.Combine(Path.GetTempPath(), $"fastdoc-pdf-test-{Guid.NewGuid():N}.pdf");
        try
        {
            File.WriteAllText(inputPath, "");
            var (exitCode, stdout, stderr) = RunPdfCli(inputPath, outputPath);

            Assert.Equal(0, exitCode);
            Assert.Contains("mode: headless --pdf", stderr);
            Assert.Contains("pages: 1", stdout);
            Assert.True(File.Exists(outputPath));
            var bytes = File.ReadAllBytes(outputPath);
            Assert.True(bytes.Length > 0);
            Assert.Equal("%PDF-", System.Text.Encoding.ASCII.GetString(bytes, 0, 5));
        }
        finally
        {
            File.Delete(inputPath);
            File.Delete(outputPath);
        }
    }

    [Fact]
    public void Multi_page_markdown_document_reports_more_than_one_page()
    {
        if (PrerequisitesMissing(out var reason))
        {
            Console.WriteLine($"SKIP (prerequisites missing): {reason}");
            return;
        }

        var inputPath = Path.Combine(Path.GetTempPath(), $"fastdoc-pdf-test-{Guid.NewGuid():N}.md");
        var outputPath = Path.Combine(Path.GetTempPath(), $"fastdoc-pdf-test-{Guid.NewGuid():N}.pdf");
        try
        {
            // ~400 short paragraphs comfortably overflows a single A4-at-96dpi fallback page
            // (see PdfExporter's FallbackPageHeightPoints), so this is a sheet-count assertion,
            // not a byte-count one.
            var content = string.Join("\n\n", System.Linq.Enumerable.Repeat("One short paragraph of text.", 400));
            File.WriteAllText(inputPath, content);
            var (exitCode, stdout, stderr) = RunPdfCli(inputPath, outputPath);

            Assert.Equal(0, exitCode);
            Assert.Contains("mode: headless --pdf", stderr);
            var pagesLine = stdout.Split('\n', StringSplitOptions.RemoveEmptyEntries)[^1];
            Assert.StartsWith("pages: ", pagesLine);
            var pageCount = int.Parse(pagesLine.Substring("pages: ".Length).Trim());
            Assert.True(pageCount > 1, $"expected more than one page, got: {pagesLine}");
            Assert.True(File.Exists(outputPath));
        }
        finally
        {
            File.Delete(inputPath);
            File.Delete(outputPath);
        }
    }
}
