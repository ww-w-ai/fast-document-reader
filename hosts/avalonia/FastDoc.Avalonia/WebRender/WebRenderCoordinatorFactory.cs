using System;
using FastDoc.Avalonia.WebRender.Renderers;

namespace FastDoc.Avalonia.WebRender;

/// <summary>The one place production code builds a real <see cref="WebRenderCoordinator"/> —
/// disk-backed settings, the current platform's real candidate chain
/// (<see cref="WebRenderCandidateFactory"/>), and the bundled asset paths
/// (<see cref="WebRenderAssets"/>). Kept separate from <see cref="Rendering.FlowDocumentView"/> so
/// that file stays about drawing, not about assembling this dependency graph.</summary>
public static class WebRenderCoordinatorFactory
{
    /// <summary>S12-F's known, documented shortcut for THIS sprint: <see cref="Rendering.
    /// FlowWebRenderPass"/> calls <see cref="WebRenderCoordinator.RenderAsync"/> SYNCHRONOUSLY
    /// (`.GetAwaiter().GetResult()`) while building a document's block list, which blocks the UI
    /// thread for up to this long PER web-rendered block. This is acceptable only because the
    /// switch defaults OFF (see s12f-scope-v2.md) — a document with the switch off pays none of
    /// this cost, since <see cref="WebRenderCoordinator.RenderAsync"/> returns
    /// <see cref="WebRenderResult.Raw"/> immediately when disabled. Turning the switch on trades a
    /// slower document open for a rendered diagram; a proper async/lazy-repaint pipeline (the same
    /// shape <see cref="Rendering.ImageBlockRenderer"/> already uses for lazy docx/odt pictures) is
    /// the follow-up, not attempted here.</summary>
    public static readonly TimeSpan DefaultPerCandidateTimeout = TimeSpan.FromSeconds(5);

    public static WebRenderCoordinator CreateDefault(TimeSpan? perCandidateTimeout = null)
    {
        var chain = WebRenderCandidateFactory.BuildForCurrentPlatform(
            WebRenderAssets.MermaidJsPath, WebRenderAssets.KatexJsPath, WebRenderAssets.KatexCssPath);
        return new WebRenderCoordinator(
            new DiskWebRenderSettingsSource(), chain, perCandidateTimeout ?? DefaultPerCandidateTimeout,
            faultGuard: new DispatcherFaultGuard());
    }
}
