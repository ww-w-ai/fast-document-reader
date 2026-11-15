using System.Threading;
using System.Threading.Tasks;
using FastDoc.Avalonia.WebRender;
using FastDoc.Avalonia.WebRender.Renderers;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S12-F2 (PM 2026-09-07, docs/studio/sprints/S12/s12f-web-render-optin.md §9-10): pins
/// <see cref="ProcessIsolatedWebKitGtkRenderer"/>'s DECISION logic — given an isolated worker
/// run's outcome (exit code + whether it produced a usable image), what does <c>RenderAsync</c>
/// do — without ever spawning a real process. The real subprocess machinery
/// (<c>RunRealWorkerProcessAsync</c>) needs a genuine, thread-hopping await
/// (<c>Process.WaitForExitAsync</c>) and a real target to spawn, so it is NOT covered here — same
/// documented gap as <c>WebKitGtkBlockRenderer</c>/<c>OnDemandChromiumRenderer</c> (see this
/// class's own doc comment) and the same "no genuine await" rule every other file in this test
/// suite obeys (WebRenderCoordinatorTests.cs's class-level comment).
/// </summary>
public class ProcessIsolatedWebKitGtkRendererTests
{
    private static readonly WebBlockRequest MermaidRequest = new(WebBlockEngine.Mermaid, "graph TD; A-->B;");

    [Fact]
    public async Task A_zero_exit_with_an_image_returns_that_image()
    {
        var image = new WebBlockImage(new byte[] { 9, 9, 9 }, WebImageFormat.Png);
        var renderer = new ProcessIsolatedWebKitGtkRenderer((_, _) => Task.FromResult((0, (WebBlockImage?)image)));

        var result = await renderer.RenderAsync(MermaidRequest, CancellationToken.None);

        Assert.Same(image, result);
    }

    [Fact]
    public async Task A_nonzero_exit_code_throws_an_ordinary_exception_the_coordinator_already_knows_how_to_handle()
    {
        // 134 = 128 + SIGABRT on Linux — the exact exit shape a native abort inside the worker
        // process produces. This test's whole point: that number gets no special treatment here,
        // it becomes a plain thrown exception, exactly like a candidate that threw directly.
        var renderer = new ProcessIsolatedWebKitGtkRenderer((_, _) => Task.FromResult((134, (WebBlockImage?)null)));

        await Assert.ThrowsAsync<System.InvalidOperationException>(
            () => renderer.RenderAsync(MermaidRequest, CancellationToken.None));
    }

    [Fact]
    public async Task A_zero_exit_with_no_image_still_throws_rather_than_returning_a_null_image()
    {
        // Defensive: a worker that exits 0 but produced no readable output (a corrupt/missing
        // response file) must not be treated as success just because the exit code looks clean.
        var renderer = new ProcessIsolatedWebKitGtkRenderer((_, _) => Task.FromResult((0, (WebBlockImage?)null)));

        await Assert.ThrowsAsync<System.InvalidOperationException>(
            () => renderer.RenderAsync(MermaidRequest, CancellationToken.None));
    }
}
