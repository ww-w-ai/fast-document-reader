using System;
using System.Collections.Generic;
using System.Linq;
using FastDoc.Avalonia.WebRender.Renderers;

namespace FastDoc.Avalonia.WebRender;

/// <summary>
/// The composition root piece: turns <see cref="WebRenderChainFactory"/>'s pure platform→order
/// policy into real <see cref="WebRenderCandidate"/> instances backed by actual capability probes
/// and renderers. Intentionally NOT covered by this repo's unit tests — everything worth testing
/// about the DECISION (order, fallback, timeout, raw default) lives in
/// <see cref="WebRenderCoordinator"/> and is tested there with fakes; this class only wires real
/// objects together, which a test cannot meaningfully verify on a macOS development machine
/// anyway (see WebRenderCoordinator's own doc comment).
/// </summary>
public static class WebRenderCandidateFactory
{
    public static IReadOnlyList<WebRenderCandidate> BuildForCurrentPlatform(
        string mermaidJsPath, string katexJsPath, string katexCssPath)
    {
        var kinds = OperatingSystem.IsWindows() ? WebRenderChainFactory.ForWindows()
            : OperatingSystem.IsLinux() ? WebRenderChainFactory.ForLinux()
            : WebRenderChainFactory.ForOther();

        return kinds.Select(kind => BuildCandidate(kind, mermaidJsPath, katexJsPath, katexCssPath)).ToList();
    }

    private static WebRenderCandidate BuildCandidate(
        WebRenderEngineKind kind, string mermaidJsPath, string katexJsPath, string katexCssPath)
    {
        return kind switch
        {
            WebRenderEngineKind.WindowsWebView2 => new WebRenderCandidate(
                "windows-webview2",
                new WebView2CapabilityProbe(),
                new WebView2BlockRenderer(mermaidJsPath, katexJsPath, katexCssPath)),

            // S12-F2: runs the actual WebKitGtkBlockRenderer work in a disposable CHILD process
            // (ProcessIsolatedWebKitGtkRenderer, Program.cs's --webrender-worker) rather than
            // in-process — a native abort inside NativeWebView (see that class's own doc comment)
            // then kills the disposable worker, never this app.
            WebRenderEngineKind.LinuxWebKitGtk => new WebRenderCandidate(
                "linux-webkitgtk",
                new WebKitGtkCapabilityProbe(),
                new ProcessIsolatedWebKitGtkRenderer(mermaidJsPath, katexJsPath, katexCssPath)),

            WebRenderEngineKind.OnDemandChromium => new WebRenderCandidate(
                "on-demand-chromium",
                new AlwaysAvailableCapability(),
                new OnDemandChromiumRenderer(mermaidJsPath, katexJsPath, katexCssPath)),

            _ => throw new ArgumentOutOfRangeException(nameof(kind)),
        };
    }
}
