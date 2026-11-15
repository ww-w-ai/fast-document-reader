using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.Versioning;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace FastDoc.Avalonia.WebRender.Renderers;

/// <summary>
/// S12-F2 (PM 2026-09-07): closes the crash class §9-4's <see cref="DispatcherFaultGuard"/> could
/// not — a native SIGABRT from <c>Avalonia.Controls.NativeWebView</c> (Mesa/llvmpipe aborting on
/// an unsupported GL renderer, observed on a real Linux VM on 2026-09-08:
/// `OpenGlException: Renderer 'llvmpipe (LLVM 15.0.7, 256 bits)' is blacklisted`) is not a managed
/// .NET exception at all — it terminates the OS process directly, and nothing running IN that
/// process, managed or not, can intercept it. <see cref="DispatcherFaultGuard"/> only ever sees
/// exceptions the CLR itself raises; a native abort skips the CLR entirely. A stronger capability
/// probe (real GL-context creation, not just <c>dlopen</c>) narrows how OFTEN this happens but
/// cannot GUARANTEE it never does — a driver can still fail mid-render, after the probe passed.
///
/// The only mechanism that can make a native abort survivable for the caller is for it to happen
/// in a DIFFERENT process. This class runs the actual <c>WebKitGtkBlockRenderer</c> work inside a
/// disposable child process (this same executable, re-invoked with
/// <c>--webrender-worker &lt;request&gt; &lt;output&gt;</c> — see Program.cs) and reports that
/// child's outcome as an ordinary managed exception when it fails, exactly like a normal thrown
/// exception or a timeout — <see cref="WebRenderCoordinator"/> needs no special case for this: a
/// process that aborts partway through simply produces no output file and a non-zero/abnormal
/// exit code, which this class turns into a thrown exception, which the coordinator already knows
/// how to fall through on.
///
/// The real subprocess machinery (<see cref="RunRealWorkerProcessAsync"/>) is NOT covered by this
/// repo's test suite, for the same reason <c>WebKitGtkBlockRenderer</c> and
/// <c>OnDemandChromiumRenderer</c> already are not (see their own doc comments): spawning a real
/// child process and waiting on it is a genuine, thread-hopping await, which this whole test
/// suite's rule forbids (AvaloniaHeadlessSetup binds the UI thread to whichever xunit worker
/// thread first touches it — see WebRenderCoordinatorTests.cs's class-level comment) — and a real
/// end-to-end run needs an actual Linux machine with WebKitGTK to mean anything anyway. What IS
/// tested (see ProcessIsolatedWebKitGtkRendererTests.cs) is the DECISION this class makes from an
/// isolated run's outcome — success, non-zero exit, or a zero exit with no output — via the
/// injectable <see cref="_runIsolated"/> seam.
/// </summary>
public sealed class ProcessIsolatedWebKitGtkRenderer : IWebBlockRenderer
{
    private readonly Func<WebBlockRequest, CancellationToken, Task<(int ExitCode, WebBlockImage? Image)>> _runIsolated;

    public ProcessIsolatedWebKitGtkRenderer(string mermaidJsPath, string katexJsPath, string katexCssPath)
        : this((request, ct) => RunRealWorkerProcessAsync(request, ct, mermaidJsPath, katexJsPath, katexCssPath))
    {
    }

    /// <summary>Test seam: injecting the isolated-run outcome lets this class's DECISION logic
    /// (what a given exit code / output combination means) be pinned without ever spawning a real
    /// process — <c>internal</c> rather than <c>public</c> because it exists for this repo's own
    /// tests, not as an API surface for callers.</summary>
    internal ProcessIsolatedWebKitGtkRenderer(
        Func<WebBlockRequest, CancellationToken, Task<(int ExitCode, WebBlockImage? Image)>> runIsolated) =>
        _runIsolated = runIsolated;

    public async Task<WebBlockImage> RenderAsync(WebBlockRequest request, CancellationToken cancellationToken)
    {
        var (exitCode, image) = await _runIsolated(request, cancellationToken).ConfigureAwait(false);
        if (exitCode != 0 || image is null)
        {
            // Deliberately ONE failure shape for every cause (non-zero exit from a caught
            // exception inside the worker, a SIGABRT-style abnormal exit, or a zero exit that
            // somehow produced no output) — WebRenderCoordinator does not need to, and must not,
            // tell them apart: all of them mean "this candidate failed", nothing more.
            throw new InvalidOperationException(
                $"webrender-worker exited {exitCode} without a usable image (a native crash inside " +
                "that process, including a SIGABRT, exits abnormally here rather than taking this " +
                "process down with it).");
        }
        return image;
    }

    [SupportedOSPlatform("linux")]
    private static async Task<(int, WebBlockImage?)> RunRealWorkerProcessAsync(
        WebBlockRequest request, CancellationToken cancellationToken,
        string mermaidJsPath, string katexJsPath, string katexCssPath)
    {
        // mermaidJsPath/katexJsPath/katexCssPath are not sent over the wire — the worker resolves
        // the SAME WebRenderAssets paths itself (see Program.cs's --webrender-worker branch), so
        // they are accepted here only to keep this constructor's shape symmetric with every other
        // IWebBlockRenderer this factory builds (WebKitGtkBlockRenderer, OnDemandChromiumRenderer).
        _ = mermaidJsPath; _ = katexJsPath; _ = katexCssPath;

        var exePath = Environment.ProcessPath
            ?? throw new InvalidOperationException("Environment.ProcessPath is null — cannot locate this executable to re-invoke as a worker.");
        var requestPath = Path.Combine(Path.GetTempPath(), $"fastdoc-webrender-req-{Guid.NewGuid():N}.json");
        var outputPath = Path.Combine(Path.GetTempPath(), $"fastdoc-webrender-out-{Guid.NewGuid():N}.json");
        try
        {
            File.WriteAllText(requestPath, JsonSerializer.Serialize(
                new WebRenderWorkerRequest { Engine = request.Engine.ToString(), Code = request.Code }));

            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = exePath,
                    ArgumentList = { "--webrender-worker", requestPath, outputPath },
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                },
            };
            process.Start();
            try
            {
                await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                TryKill(process);
                throw;
            }

            if (process.ExitCode != 0 || !File.Exists(outputPath))
            {
                return (process.ExitCode, null);
            }

            var response = JsonSerializer.Deserialize<WebRenderWorkerResponse>(File.ReadAllText(outputPath));
            if (response is null || !Enum.TryParse<WebImageFormat>(response.Format, out var format))
            {
                return (process.ExitCode, null);
            }
            return (0, new WebBlockImage(Convert.FromBase64String(response.BytesBase64), format));
        }
        finally
        {
            TryDelete(requestPath);
            TryDelete(outputPath);
        }
    }

    private static void TryKill(Process process)
    {
        try { process.Kill(entireProcessTree: true); } catch { /* already gone */ }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch { /* best effort — a leaked temp file is not worth failing the render over */ }
    }
}
