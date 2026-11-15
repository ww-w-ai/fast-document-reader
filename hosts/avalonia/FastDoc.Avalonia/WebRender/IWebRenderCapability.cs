namespace FastDoc.Avalonia.WebRender;

/// <summary>Answers "can this engine even be tried right now" — cheap, synchronous, no network
/// and no process launch (a registry read, a library-presence check, or "always true" for an
/// on-demand engine that can attempt a download). <see cref="WebRenderCoordinator"/> only advances
/// to the (possibly expensive) <see cref="IWebBlockRenderer"/> when this returns true, so a
/// platform missing every native engine never even tries to spawn one.</summary>
public interface IWebRenderCapability
{
    bool IsAvailable();
}

/// <summary>A capability that is always available — the on-demand headless-Chromium path (S12-F's
/// common fallback) can always be ATTEMPTED; whether the download/launch itself then succeeds is
/// <see cref="IWebBlockRenderer"/>'s concern, reported by throwing.</summary>
public sealed class AlwaysAvailableCapability : IWebRenderCapability
{
    public bool IsAvailable() => true;
}
