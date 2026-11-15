using System;
using System.Threading.Tasks;
using Avalonia.Threading;

namespace FastDoc.Avalonia.WebRender.Renderers;

/// <summary>
/// Defense for the crash class found on a real Linux VM on 2026-09-07 (PM judgment 2026-09-07,
/// docs/studio/sprints/S12/s12f-web-render-optin.md §9-4): when WebKitGTK is not actually loadable,
/// <c>Avalonia.Controls.NativeWebView.OnAttached()</c> throws a <see cref="DllNotFoundException"/>
/// ASYNCHRONOUSLY — via the TPL's own internal continuation-posting machinery, on a callback
/// Avalonia's layout pass scheduled onto the UI dispatcher. That exception never flows back through
/// the <see cref="Task{WebBlockImage}"/> a renderer's own caller is awaiting; it originates entirely
/// outside that call stack, so no try/catch anywhere around
/// <c>candidate.Renderer.RenderAsync(...)</c> can ever see it. Left alone, it surfaces on
/// <see cref="Dispatcher.UnhandledException"/> and, unhandled there, crashes the whole process.
///
/// This class races the guarded work against whatever THAT event reports during the same window,
/// marking it <c>Handled = true</c> either way so the process itself never crashes on this class's
/// account — turning "the platform crashed the app" into "this candidate failed", which
/// <see cref="WebRenderCoordinator"/> already knows how to treat exactly like a thrown exception or
/// a timeout: try the next candidate, or land on raw. The handler is unsubscribed the moment this
/// method returns, so an unrelated LATER crash is still fatal, as it should be — this only widens
/// the definition of "this specific render attempt failed", nothing more.
///
/// Not covered by this repo's test suite for the same reason <see cref="WebRenderCoordinator"/>'s
/// own doc comment gives for the real platform renderers: this development machine cannot make a
/// real WebKitGTK OnAttached failure happen. <c>WebRenderCoordinatorTests</c> pins the CONTRACT this
/// class exists to satisfy (a fault reported through <see cref="IWebRenderFaultGuard"/> falls
/// through the chain like any other failure) against a scripted fake — see
/// <c>FaultInjectingGuard</c> there.
/// </summary>
public sealed class DispatcherFaultGuard : IWebRenderFaultGuard
{
    public async Task<WebBlockImage> Guard(Func<Task<WebBlockImage>> body)
    {
        var faultTcs = new TaskCompletionSource<WebBlockImage>(TaskCreationOptions.RunContinuationsAsynchronously);

        void OnUnhandled(object? sender, DispatcherUnhandledExceptionEventArgs e)
        {
            e.Handled = true; // this candidate failed — not a reason to take the whole app down.
            faultTcs.TrySetException(e.Exception);
        }

        Dispatcher.UIThread.UnhandledException += OnUnhandled;
        try
        {
            var bodyTask = body();
            var completed = await Task.WhenAny(bodyTask, faultTcs.Task).ConfigureAwait(false);
            return await completed.ConfigureAwait(false);
        }
        finally
        {
            Dispatcher.UIThread.UnhandledException -= OnUnhandled;
        }
    }
}
