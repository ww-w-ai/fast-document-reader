namespace FastDoc.Avalonia.WebRender;

/// <summary>One engine <see cref="WebRenderCoordinator"/> may try, in the order it appears in a
/// chain: a name for logging/reporting, a cheap <see cref="IWebRenderCapability"/> gate, and the
/// (possibly expensive) <see cref="IWebBlockRenderer"/> to run once the gate passes.</summary>
public sealed record WebRenderCandidate(string Name, IWebRenderCapability Capability, IWebBlockRenderer Renderer);
