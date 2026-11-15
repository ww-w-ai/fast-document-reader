using System;

namespace FastDoc.Avalonia.WebRender;

/// <summary>
/// S12-F2 (PM 2026-09-07, docs/studio/sprints/S12/s12f-web-render-optin.md §9-9): the two hops a
/// background web-render pass needs — off the UI thread to do the (possibly seconds-long, per-
/// candidate up to 5s) candidate work <see cref="Rendering.FlowWebRenderPass.Apply"/> does, then
/// back onto it to touch document state safely once a result is ready. Kept as its own tiny port
/// (mirrors <see cref="IWebRenderSettingsSource"/>'s own reasoning) so <c>FlowDocumentView</c>'s
/// tests can run this pass INLINE, synchronously — see <see cref="ImmediateWebRenderScheduler"/>'s
/// own doc comment for why a real thread-hop cannot be allowed into this repo's test suite.
/// </summary>
public interface IWebRenderScheduler
{
    void RunInBackground(Action work);
    void PostToUiThread(Action work);
}

/// <summary>The real, production scheduler every app-constructed <c>FlowDocumentView</c> uses: a
/// threadpool hop out (<see cref="System.Threading.Tasks.Task.Run(Action)"/>), an Avalonia
/// dispatcher post back in.</summary>
public sealed class TaskWebRenderScheduler : IWebRenderScheduler
{
    public void RunInBackground(Action work) => System.Threading.Tasks.Task.Run(work);
    public void PostToUiThread(Action work) => global::Avalonia.Threading.Dispatcher.UIThread.Post(work);
}

/// <summary>Test-only scheduler: runs everything INLINE, synchronously, on the calling thread — no
/// real thread-hop, no genuine await. This whole test suite's <c>AvaloniaHeadlessSetup</c> static
/// constructor binds Avalonia's UI thread to whichever xunit worker thread first touches it (see
/// <c>WebRenderCoordinatorTests.cs</c>'s own class-level rule comment); a real background Task
/// scheduled by every <c>FlowDocumentView</c> test in this repo (there are 19+) would reintroduce
/// exactly the regression this repo already root-caused and fixed once this sprint. Using this
/// scheduler in a test keeps <c>SetTree</c>'s OBSERVABLE contract (raw first, then a swap once the
/// background pass "completes") fully testable without ever actually leaving the calling thread.
/// </summary>
public sealed class ImmediateWebRenderScheduler : IWebRenderScheduler
{
    public void RunInBackground(Action work) => work();
    public void PostToUiThread(Action work) => work();
}
