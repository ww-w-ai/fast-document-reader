using System;
using System.Threading.Tasks;

namespace FastDoc.Avalonia.WebRender;

/// <summary>
/// S12-F crash-defense gap (found visually on a real Linux VM on 2026-09-07, PM judgment 2026-09-07):
/// a candidate renderer can fail entirely OUT-OF-BAND — on a continuation that never flows back
/// through the <see cref="Task{WebBlockImage}"/> <see cref="WebRenderCoordinator"/> is awaiting, so
/// no try/catch around that await can ever see it (see <c>Renderers.DispatcherFaultGuard</c>'s own
/// doc comment for the concrete case: <c>Avalonia.Controls.NativeWebView.OnAttached()</c> throwing a
/// <c>DllNotFoundException</c> asynchronously when WebKitGTK isn't actually loadable). This interface
/// lets <see cref="WebRenderCoordinator"/> stay pure/testable — no platform dependency — while a real
/// implementation races the guarded work against whatever a platform-specific out-of-band channel
/// reports, turning "the platform crashed the process" into "this candidate failed", the same as a
/// thrown exception or a timeout.
/// </summary>
public interface IWebRenderFaultGuard
{
    Task<WebBlockImage> Guard(Func<Task<WebBlockImage>> body);
}

/// <summary>The default: no out-of-band channel to watch, so this is exactly
/// <c>body()</c> — every existing candidate keeps behaving exactly as before this guard existed.</summary>
public sealed class NoOpFaultGuard : IWebRenderFaultGuard
{
    public Task<WebBlockImage> Guard(Func<Task<WebBlockImage>> body) => body();
}
