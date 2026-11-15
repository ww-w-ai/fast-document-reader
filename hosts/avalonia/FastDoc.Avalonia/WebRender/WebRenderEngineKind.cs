using System.Collections.Generic;

namespace FastDoc.Avalonia.WebRender;

/// <summary>The three engines S12-F's design settled on (s12f-scope-v2.md) — kept as an enum
/// separate from the wiring in <see cref="WebRenderCandidateFactory"/> so
/// <see cref="WebRenderChainFactory"/>'s platform-to-order POLICY can be unit tested without
/// constructing a single real capability probe or renderer.</summary>
public enum WebRenderEngineKind
{
    /// <summary>Windows: the OS-provided Edge WebView2 runtime, driven directly through the
    /// official Microsoft.Web.WebView2 SDK (not Avalonia's own WebView control — see
    /// s12e-web-render-decision.md's candidate 3 for why that path stays out).</summary>
    WindowsWebView2,

    /// <summary>Linux: WebKitGTK, if present, through Avalonia.Controls.WebView's offscreen
    /// backend — the "실험적" (experimental) path S12-E's candidate 3 already flagged. PM's
    /// judgment on S12-F kept this as Linux's FIRST attempt, with on-demand Chromium as the
    /// fallback when it is absent or fails.</summary>
    LinuxWebKitGtk,

    /// <summary>Common fallback for both platforms: a headless Chromium fetched on demand only
    /// when the switch is on and no native engine worked — never part of the base install.</summary>
    OnDemandChromium,
}

/// <summary>Pure policy: which <see cref="WebRenderEngineKind"/>s to try, and in what order, for a
/// given platform. Contains no I/O and constructs nothing — <see cref="WebRenderCandidateFactory"/>
/// turns this list into real <see cref="WebRenderCandidate"/> instances.</summary>
public static class WebRenderChainFactory
{
    public static IReadOnlyList<WebRenderEngineKind> ForWindows() =>
        new[] { WebRenderEngineKind.WindowsWebView2, WebRenderEngineKind.OnDemandChromium };

    public static IReadOnlyList<WebRenderEngineKind> ForLinux() =>
        new[] { WebRenderEngineKind.LinuxWebKitGtk, WebRenderEngineKind.OnDemandChromium };

    /// <summary>Any platform this host does not specifically target (this app ships Windows and
    /// Linux only — macOS already has its own native WebKit renderer, see CLAUDE.md) still gets
    /// the one engine that needs no OS-specific integration, so opting in never simply does
    /// nothing on an untargeted OS.</summary>
    public static IReadOnlyList<WebRenderEngineKind> ForOther() =>
        new[] { WebRenderEngineKind.OnDemandChromium };
}
