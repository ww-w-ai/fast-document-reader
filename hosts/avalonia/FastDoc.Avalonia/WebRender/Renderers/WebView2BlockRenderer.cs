using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Web.WebView2.Core;

namespace FastDoc.Avalonia.WebRender.Renderers;

/// <summary>
/// S12-F Windows path: drives the OS-provided WebView2 runtime DIRECTLY through the official
/// Microsoft.Web.WebView2.Core SDK — not through Avalonia.Controls.WebView's integrated control,
/// and not through the WinForms/WPF wrapper controls the same NuGet package also ships (this repo
/// is an Avalonia app; those wrappers assume a WinForms/WPF host window). A hidden message-only
/// window (a standard Win32 technique — `HWND_MESSAGE` as the parent, never shown, never painted)
/// hosts the CoreWebView2Controller so this stays purely off-screen; `CapturePreviewAsync` is the
/// same STABLE, non-experimental API s12e-web-render-decision.md cites, distinct from
/// Avalonia.Controls.WebView's own offscreen mode which that document already flagged as
/// "experimental" on this platform.
///
/// UNVERIFIED ON THIS DEVELOPMENT MACHINE (macOS): every API call here only runs under
/// <c>OperatingSystem.IsWindows()</c> and none of it has been exercised against a real Windows
/// WebView2 runtime. Real-engine verification is a QA task on Windows (docs/studio/sprints/S12/
/// s12f-web-render-optin.md's "미검증" section names exactly what to check there).
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class WebView2BlockRenderer : IWebBlockRenderer, IDisposable
{
    private readonly string _mermaidJsPath;
    private readonly string _katexJsPath;
    private readonly string _katexCssPath;
    private CoreWebView2Environment? _environment;
    private CoreWebView2Controller? _controller;
    private IntPtr _hiddenWindow;

    public WebView2BlockRenderer(string mermaidJsPath, string katexJsPath, string katexCssPath)
    {
        _mermaidJsPath = mermaidJsPath;
        _katexJsPath = katexJsPath;
        _katexCssPath = katexCssPath;
    }

    public async Task<WebBlockImage> RenderAsync(WebBlockRequest request, CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("WebView2BlockRenderer only runs on Windows.");
        }

        var webView = await EnsureWebViewAsync().ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();

        var contentLoaded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void OnContentLoading(object? sender, CoreWebView2ContentLoadingEventArgs e) => contentLoaded.TrySetResult();
        webView.ContentLoading += OnContentLoading;
        try
        {
            webView.NavigateToString(WebRenderHtml.Build(request, _mermaidJsPath, _katexJsPath, _katexCssPath));
            await contentLoaded.Task.ConfigureAwait(false);
        }
        finally
        {
            webView.ContentLoading -= OnContentLoading;
        }

        // CapturePreviewAsync fails if called before the first ContentLoading event (see the ADR's
        // citation of the official docs) — that ordering is exactly what the wait above provides.
        using var stream = new MemoryStream();
        await webView.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, stream).ConfigureAwait(false);
        return new WebBlockImage(stream.ToArray(), WebImageFormat.Png);
    }

    private async Task<CoreWebView2> EnsureWebViewAsync()
    {
        if (_controller?.CoreWebView2 is not null)
        {
            return _controller.CoreWebView2;
        }

        _hiddenWindow = NativeMethods.CreateMessageOnlyWindow();
        _environment ??= await CoreWebView2Environment.CreateAsync().ConfigureAwait(false);
        _controller = await _environment.CreateCoreWebView2ControllerAsync(_hiddenWindow).ConfigureAwait(false);
        return _controller.CoreWebView2;
    }

    public void Dispose()
    {
        _controller?.Close();
        if (_hiddenWindow != IntPtr.Zero)
        {
            NativeMethods.CloseMessageOnlyWindow(_hiddenWindow);
        }
    }

    /// <summary>The minimum Win32 P/Invoke to create and later destroy an invisible message-only
    /// window — the standard technique for hosting a control that must never appear on screen.
    /// `HWND_MESSAGE` (-3) needs no window class registration beyond one already-registered class
    /// name; "STATIC" is a built-in system class present on every Windows install, chosen so this
    /// needs no `RegisterClassEx` call of its own.</summary>
    [SupportedOSPlatform("windows")]
    private static class NativeMethods
    {
        private static readonly IntPtr HwndMessage = new(-3);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateWindowExW(
            int dwExStyle, string lpClassName, string lpWindowName, int dwStyle,
            int x, int y, int nWidth, int nHeight,
            IntPtr hWndParent, IntPtr hMenu, IntPtr hInstance, IntPtr lpParam);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DestroyWindow(IntPtr hWnd);

        public static IntPtr CreateMessageOnlyWindow() =>
            CreateWindowExW(0, "STATIC", "FastDocWebRenderHost", 0, 0, 0, 0, 0, HwndMessage, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

        public static void CloseMessageOnlyWindow(IntPtr hWnd) => DestroyWindow(hWnd);
    }
}
