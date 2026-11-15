using System;
using System.IO;
using System.Runtime.Versioning;
using System.Threading;
using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Threading;

namespace FastDoc.Avalonia.WebRender.Renderers;

/// <summary>
/// S12-F Linux path, first attempt: <c>Avalonia.Controls.NativeWebView</c>'s GTK/WebKitGTK backend —
/// the SAME "실험적" (experimental) offscreen path s12e-web-render-decision.md's candidate 3
/// already flagged, kept as Linux's first attempt per PM's S12-F judgment 2 (WebKitGTK first,
/// on-demand Chromium as the fallback the coordinator reaches when this throws or times out).
///
/// A real DISCOVERY made while wiring this class, not assumed going in: this package's Linux/GTK
/// adapter exposes NO pixel-screenshot method — only <c>PrintToPdfStreamAsync</c> (confirmed from
/// the package's own metadata: `Avalonia.Controls.Gtk.GtkWebViewAdapter` implements
/// `PrintToPdfStreamAsyncInternal`, and no screenshot-shaped method appears anywhere in that
/// adapter). So unlike Windows (real PNG via CapturePreviewAsync) this candidate hands back a PDF
/// — see <see cref="WebBlockImage"/>'s own doc comment for why the interface allows that instead
/// of forcing a PNG here.
///
/// A <c>NativeWebView</c> control must be attached to a real Avalonia visual tree to initialize
/// its native handle, so this renderer builds an off-screen, never-shown <see cref="Window"/> to
/// host it — analogous to <see cref="WebView2BlockRenderer"/>'s hidden Win32 message-only window,
/// using Avalonia's own APIs instead of P/Invoke since a <c>NativeWebView</c> control (unlike
/// WebView2's raw Core SDK) has no headless hosting mode of its own.
///
/// UNVERIFIED ON THIS DEVELOPMENT MACHINE (macOS): this class only runs under
/// <c>OperatingSystem.IsLinux()</c> and none of it has been exercised against a real WebKitGTK
/// runtime — including whether an off-screen `Window` this small is enough for the GTK backend to
/// actually attach and render (a real risk this size of window may not surface until real-hardware
/// QA, on top of the "experimental" flag the package's own docs already carry).
/// </summary>
[SupportedOSPlatform("linux")]
public sealed class WebKitGtkBlockRenderer : IWebBlockRenderer
{
    private readonly string _mermaidJsPath;
    private readonly string _katexJsPath;
    private readonly string _katexCssPath;

    public WebKitGtkBlockRenderer(string mermaidJsPath, string katexJsPath, string katexCssPath)
    {
        _mermaidJsPath = mermaidJsPath;
        _katexJsPath = katexJsPath;
        _katexCssPath = katexCssPath;
    }

    public async Task<WebBlockImage> RenderAsync(WebBlockRequest request, CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsLinux())
        {
            throw new PlatformNotSupportedException("WebKitGtkBlockRenderer only runs on Linux.");
        }

        // Every WebView/Window API below is UI-thread-affine; this renderer is invoked from
        // WebRenderCoordinator's async chain, which is not guaranteed to be the UI thread, so the
        // whole attempt is marshalled onto it and awaited back. `InvokeAsync<TResult>` with a
        // `Func<Task<TResult>>` yields `Task<Task<TResult>>` (it does not itself await the inner
        // async work) — the double `await` below unwraps that, same as a manual `.Unwrap()` would.
        // Confirmed by building against the real API: `InvokeAsync<TResult>` with a
        // `Func<Task<TResult>>` argument DOES unwrap the inner task itself (unlike, say,
        // `Task.Run`), so `pending` below is already the awaited `WebBlockImage`, not a task.
        var pending = await Dispatcher.UIThread.InvokeAsync(RenderOnUiThreadAsync).ConfigureAwait(false);
        return pending;

        async Task<WebBlockImage> RenderOnUiThreadAsync()
        {
            // `Window` is not `IDisposable` in Avalonia — `Close()` in the `finally` below is its
            // real teardown, so this is a plain `var`, not a `using`.
            var window = new Window
            {
                Width = 1,
                Height = 1,
                ShowInTaskbar = false,
                WindowStartupLocation = WindowStartupLocation.Manual,
                Position = new global::Avalonia.PixelPoint(-32000, -32000),
            };
            var webView = new NativeWebView();
            window.Content = webView;
            window.Show();
            try
            {
                var html = WebRenderHtml.Build(request, _mermaidJsPath, _katexJsPath, _katexCssPath);
                webView.NavigateToString(html);
                cancellationToken.ThrowIfCancellationRequested();

                using var pdfStream = await webView.PrintToPdfStreamAsync(new global::Avalonia.Platform.WebViewPrintSettings())
                    .ConfigureAwait(true);
                using var buffer = new MemoryStream();
                await pdfStream.CopyToAsync(buffer, cancellationToken).ConfigureAwait(true);
                return new WebBlockImage(buffer.ToArray(), WebImageFormat.Pdf);
            }
            finally
            {
                window.Close();
            }
        }
    }
}
