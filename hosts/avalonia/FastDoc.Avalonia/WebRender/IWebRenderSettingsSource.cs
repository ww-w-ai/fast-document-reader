namespace FastDoc.Avalonia.WebRender;

/// <summary>What <see cref="WebRenderCoordinator"/> needs from the persisted opt-in switch — kept
/// as its own tiny port (rather than the coordinator calling <see cref="WebRenderSettings.Load"/>
/// directly) so a unit test can flip the switch without touching a real file on disk.</summary>
public interface IWebRenderSettingsSource
{
    bool RenderingEnabled { get; }
}

/// <summary>The real, disk-backed source the app wires up — reads fresh on every access, so a
/// setting change through the UI takes effect on the very next block rendered without restarting
/// anything.</summary>
public sealed class DiskWebRenderSettingsSource : IWebRenderSettingsSource
{
    public bool RenderingEnabled => WebRenderSettings.Load().RenderingEnabled;
}
