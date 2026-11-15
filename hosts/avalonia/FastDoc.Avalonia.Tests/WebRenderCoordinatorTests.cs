using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using FastDoc.Avalonia.WebRender;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// Pins WebRenderCoordinator's whole decision state machine — switch off/on, per-candidate
/// capability gating, fall-through on exception, fall-through on timeout, and landing on raw when
/// every candidate is exhausted — entirely with fakes. No real WebView2/WebKitGTK/Chromium process
/// runs here; that is deliberate (see the coordinator's own doc comment) and is why this class
/// exists as the load-bearing test surface for S12-F's opt-in design.
///
/// RULE FOR THIS FILE: no test method may complete via a GENUINE (thread-hopping) await — every
/// task any fake hands back must already be completed (or cancelled) by the time it is awaited, so
/// the continuation runs synchronously on the calling thread. This suite's own
/// <c>AvaloniaHeadlessSetup</c> static constructor binds Avalonia's UI thread to whichever xunit
/// worker thread first touches it (see PagingTests.cs:28); with `parallelizeTestCollections=false`
/// that is meant to always be the same thread, but a real async suspension (e.g. a live
/// <c>Task.Delay</c> that resumes on a different threadpool thread once its wait elapses) breaks
/// that assumption for every OTHER test that runs after it in the same process, and they fail with
/// "the calling thread cannot access this object because a different thread owns it" when they
/// later touch a real Window/Compositor. This was root-caused and reproduced on 2026-09-07 — see
/// docs/studio/sprints/S12/s12f-web-render-optin.md's regression section.
/// </summary>
public class WebRenderCoordinatorTests
{
    private static readonly WebBlockRequest MermaidRequest = new(WebBlockEngine.Mermaid, "graph TD; A-->B;");

    private sealed class FixedSettingsSource : IWebRenderSettingsSource
    {
        public bool RenderingEnabled { get; init; }
    }

    private sealed class FixedCapability : IWebRenderCapability
    {
        private readonly bool _available;
        public FixedCapability(bool available) => _available = available;
        public bool IsAvailable() => _available;
    }

    /// <summary>A renderer whose behaviour is scripted per call: succeed with an image, throw, or
    /// hang forever (to prove the coordinator's timeout actually fires rather than waiting on a
    /// real network/process indefinitely). Also records whether it was invoked at all, so a test
    /// can assert a LATER candidate in the chain was never touched once an earlier one succeeded.</summary>
    private sealed class ScriptedRenderer : IWebBlockRenderer
    {
        public enum Behavior { Succeed, SucceedWithPdf, Throw, HangForever }

        private readonly Behavior _behavior;
        public bool WasInvoked { get; private set; }

        public ScriptedRenderer(Behavior behavior) => _behavior = behavior;

        public Task<WebBlockImage> RenderAsync(WebBlockRequest request, CancellationToken cancellationToken)
        {
            WasInvoked = true;
            switch (_behavior)
            {
                case Behavior.Succeed:
                    return Task.FromResult(new WebBlockImage(new byte[] { 1, 2, 3 }, WebImageFormat.Png));
                case Behavior.SucceedWithPdf:
                    // S12-F PM judgment (2026-09-07): Linux's WebKitGTK candidate hands back a PDF,
                    // not a PNG — the coordinator must NOT treat that as a rendered success (this
                    // reader has no PDF-page rasterizer wired to a picture block), so it needs to be
                    // indistinguishable, from the outside, from any other candidate failure.
                    return Task.FromResult(new WebBlockImage(new byte[] { 4, 5, 6 }, WebImageFormat.Pdf));
                case Behavior.Throw:
                    return Task.FromException<WebBlockImage>(new InvalidOperationException("scripted failure"));
                case Behavior.HangForever:
                    // Never completes on its own — only cancellation (the coordinator's timeout)
                    // ends it. A CancellationToken already cancelled (or cancelled synchronously by
                    // its owning CancellationTokenSource) fires a Register callback SYNCHRONOUSLY,
                    // inline, on the thread that cancels it — this is documented CancellationToken
                    // behaviour, not a race — so this never becomes a genuine (thread-hopping)
                    // await; see this file's own doc comment for why that distinction matters here.
                    var tcs = new TaskCompletionSource<WebBlockImage>();
                    cancellationToken.Register(() => tcs.TrySetCanceled(cancellationToken));
                    return tcs.Task;
                default:
                    throw new ArgumentOutOfRangeException();
            }
        }
    }

    private static WebRenderCoordinator Coordinator(
        bool renderingEnabled, IReadOnlyList<WebRenderCandidate> chain, TimeSpan? timeout = null,
        Action<string, Exception>? onCandidateFailed = null, IWebRenderFaultGuard? faultGuard = null) =>
        new(new FixedSettingsSource { RenderingEnabled = renderingEnabled }, chain,
            timeout ?? TimeSpan.FromSeconds(5), onCandidateFailed, faultGuard);

    /// <summary>
    /// Models the crash class found on a real Linux VM on 2026-09-07: `NativeWebView.OnAttached()`
    /// can throw a `DllNotFoundException` ASYNCHRONOUSLY, on a continuation that never flows back
    /// through the `Task&lt;WebBlockImage&gt;` a renderer hands the coordinator — the renderer's own
    /// task can sit there never completing while the real fault surfaces entirely out-of-band (on
    /// `Dispatcher.UIThread.UnhandledException`, see <c>DispatcherFaultGuard</c>'s own doc comment).
    /// Per this file's own no-genuine-await rule, the most faithful synchronous model of "the fault
    /// arrives before the guarded work could ever complete" is to hand back an already-faulted task
    /// directly, exactly as the real guard's race would resolve to once the dispatcher fires first.
    ///
    /// ONE coordinator instance wraps EVERY candidate's call with the same guard — in production
    /// that is correct (a process-wide dispatcher hook has no notion of "which candidate"), but it
    /// means a guard that always faults would also fault a later, unrelated, working candidate.
    /// This fake faults only its FIRST invocation and passes every one after it straight to
    /// <paramref name="body"/>, modelling "the platform failure is specific to one broken engine,
    /// not to the guard mechanism itself".
    /// </summary>
    private sealed class FaultInjectingGuard : IWebRenderFaultGuard
    {
        private bool _fired;

        public Task<WebBlockImage> Guard(Func<Task<WebBlockImage>> body)
        {
            if (_fired)
            {
                return body();
            }
            _fired = true;
            return Task.FromException<WebBlockImage>(new DllNotFoundException("scripted dispatcher fault"));
        }
    }

    [Fact]
    public async Task Switch_off_always_returns_raw_and_never_touches_any_candidate()
    {
        var renderer = new ScriptedRenderer(ScriptedRenderer.Behavior.Succeed);
        var chain = new[] { new WebRenderCandidate("only", new FixedCapability(true), renderer) };
        var coordinator = Coordinator(renderingEnabled: false, chain);

        var result = await coordinator.RenderAsync(MermaidRequest, CancellationToken.None);

        var raw = Assert.IsType<WebRenderResult.Raw>(result);
        Assert.Equal(MermaidRequest.Code, raw.Source);
        Assert.False(renderer.WasInvoked);
    }

    [Fact]
    public async Task Switch_on_with_an_available_candidate_returns_its_rendered_image()
    {
        var renderer = new ScriptedRenderer(ScriptedRenderer.Behavior.Succeed);
        var chain = new[] { new WebRenderCandidate("primary", new FixedCapability(true), renderer) };
        var coordinator = Coordinator(renderingEnabled: true, chain);

        var result = await coordinator.RenderAsync(MermaidRequest, CancellationToken.None);

        var rendered = Assert.IsType<WebRenderResult.Rendered>(result);
        Assert.Equal("primary", rendered.EngineName);
        Assert.Equal(WebImageFormat.Png, rendered.Image.Format);
    }

    [Fact]
    public async Task An_unavailable_capability_is_skipped_without_invoking_its_renderer()
    {
        var unavailableRenderer = new ScriptedRenderer(ScriptedRenderer.Behavior.Succeed);
        var fallbackRenderer = new ScriptedRenderer(ScriptedRenderer.Behavior.Succeed);
        var chain = new[]
        {
            new WebRenderCandidate("unavailable", new FixedCapability(false), unavailableRenderer),
            new WebRenderCandidate("fallback", new FixedCapability(true), fallbackRenderer),
        };
        var coordinator = Coordinator(renderingEnabled: true, chain);

        var result = await coordinator.RenderAsync(MermaidRequest, CancellationToken.None);

        var rendered = Assert.IsType<WebRenderResult.Rendered>(result);
        Assert.Equal("fallback", rendered.EngineName);
        Assert.False(unavailableRenderer.WasInvoked);
    }

    [Fact]
    public async Task A_renderer_that_throws_falls_through_to_the_next_candidate()
    {
        var failing = new ScriptedRenderer(ScriptedRenderer.Behavior.Throw);
        var succeeding = new ScriptedRenderer(ScriptedRenderer.Behavior.Succeed);
        var chain = new[]
        {
            new WebRenderCandidate("failing", new FixedCapability(true), failing),
            new WebRenderCandidate("succeeding", new FixedCapability(true), succeeding),
        };
        string? reportedFailure = null;
        var coordinator = Coordinator(renderingEnabled: true, chain,
            onCandidateFailed: (name, _) => reportedFailure = name);

        var result = await coordinator.RenderAsync(MermaidRequest, CancellationToken.None);

        var rendered = Assert.IsType<WebRenderResult.Rendered>(result);
        Assert.Equal("succeeding", rendered.EngineName);
        Assert.Equal("failing", reportedFailure);
    }

    [Fact]
    public async Task A_renderer_that_hangs_past_the_timeout_falls_through_rather_than_waiting_forever()
    {
        var hanging = new ScriptedRenderer(ScriptedRenderer.Behavior.HangForever);
        var succeeding = new ScriptedRenderer(ScriptedRenderer.Behavior.Succeed);
        var chain = new[]
        {
            new WebRenderCandidate("hanging", new FixedCapability(true), hanging),
            new WebRenderCandidate("succeeding", new FixedCapability(true), succeeding),
        };
        // TimeSpan.Zero (not a short real delay like 50ms): CancellationTokenSource(TimeSpan.Zero)
        // cancels synchronously in its own constructor rather than arming a timer, so this proves
        // the SAME bounded-fallthrough behaviour as any positive timeout without ever suspending
        // this test past a real timer callback (see this file's own doc comment for why that
        // distinction is load-bearing in this specific suite, not just a speed nicety).
        var coordinator = Coordinator(renderingEnabled: true, chain, timeout: TimeSpan.Zero);

        var result = await coordinator.RenderAsync(MermaidRequest, CancellationToken.None);

        var rendered = Assert.IsType<WebRenderResult.Rendered>(result);
        Assert.Equal("succeeding", rendered.EngineName);
    }

    [Fact]
    public async Task Every_candidate_failing_lands_on_raw_not_an_exception()
    {
        var chain = new[]
        {
            new WebRenderCandidate("a", new FixedCapability(true), new ScriptedRenderer(ScriptedRenderer.Behavior.Throw)),
            new WebRenderCandidate("b", new FixedCapability(false), new ScriptedRenderer(ScriptedRenderer.Behavior.Succeed)),
        };
        var coordinator = Coordinator(renderingEnabled: true, chain);

        var result = await coordinator.RenderAsync(MermaidRequest, CancellationToken.None);

        var raw = Assert.IsType<WebRenderResult.Raw>(result);
        Assert.Equal(MermaidRequest.Code, raw.Source);
    }

    [Fact]
    public async Task An_earlier_successful_candidate_is_never_shadowed_by_a_later_one()
    {
        var first = new ScriptedRenderer(ScriptedRenderer.Behavior.Succeed);
        var second = new ScriptedRenderer(ScriptedRenderer.Behavior.Succeed);
        var chain = new[]
        {
            new WebRenderCandidate("first", new FixedCapability(true), first),
            new WebRenderCandidate("second", new FixedCapability(true), second),
        };
        var coordinator = Coordinator(renderingEnabled: true, chain);

        var result = await coordinator.RenderAsync(MermaidRequest, CancellationToken.None);

        Assert.Equal("first", Assert.IsType<WebRenderResult.Rendered>(result).EngineName);
        Assert.False(second.WasInvoked);
    }

    [Fact]
    public async Task Caller_cancellation_propagates_instead_of_being_treated_as_a_candidate_failure()
    {
        var hanging = new ScriptedRenderer(ScriptedRenderer.Behavior.HangForever);
        var neverReached = new ScriptedRenderer(ScriptedRenderer.Behavior.Succeed);
        var chain = new[]
        {
            new WebRenderCandidate("hanging", new FixedCapability(true), hanging),
            new WebRenderCandidate("neverReached", new FixedCapability(true), neverReached),
        };
        var coordinator = Coordinator(renderingEnabled: true, chain, timeout: TimeSpan.FromSeconds(30));
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => coordinator.RenderAsync(MermaidRequest, cts.Token));
        Assert.False(neverReached.WasInvoked);
    }

    [Fact]
    public async Task A_pdf_only_result_falls_through_to_the_next_candidate_instead_of_being_treated_as_success()
    {
        var pdfOnly = new ScriptedRenderer(ScriptedRenderer.Behavior.SucceedWithPdf);
        var pngCapable = new ScriptedRenderer(ScriptedRenderer.Behavior.Succeed);
        var chain = new[]
        {
            new WebRenderCandidate("pdf-only", new FixedCapability(true), pdfOnly),
            new WebRenderCandidate("png-capable", new FixedCapability(true), pngCapable),
        };
        string? reportedFailure = null;
        var coordinator = Coordinator(renderingEnabled: true, chain,
            onCandidateFailed: (name, _) => reportedFailure = name);

        var result = await coordinator.RenderAsync(MermaidRequest, CancellationToken.None);

        var rendered = Assert.IsType<WebRenderResult.Rendered>(result);
        Assert.Equal("png-capable", rendered.EngineName);
        Assert.Equal(WebImageFormat.Png, rendered.Image.Format);
        Assert.Equal("pdf-only", reportedFailure);
    }

    [Fact]
    public async Task Every_candidate_producing_pdf_lands_on_raw_not_a_false_success()
    {
        var chain = new[]
        {
            new WebRenderCandidate("pdf-only", new FixedCapability(true), new ScriptedRenderer(ScriptedRenderer.Behavior.SucceedWithPdf)),
        };
        var coordinator = Coordinator(renderingEnabled: true, chain);

        var result = await coordinator.RenderAsync(MermaidRequest, CancellationToken.None);

        var raw = Assert.IsType<WebRenderResult.Raw>(result);
        Assert.Equal(MermaidRequest.Code, raw.Source);
    }

    [Fact]
    public async Task An_out_of_band_dispatcher_fault_falls_through_to_the_next_candidate()
    {
        // The underlying renderer for "faulting" is Succeed, not HangForever — on purpose. If the
        // coordinator stopped routing this call through _faultGuard.Guard(...) (calling
        // candidate.Renderer.RenderAsync directly instead), this renderer would return a real PNG
        // and "faulting" would WIN, breaking the assertion below. A HangForever renderer here would
        // let this test pass for the WRONG reason (the coordinator's pre-existing timeout
        // fallthrough, not the guard) even with the guard entirely removed — that was exactly the
        // gap lead's MG2 mutation (removing the `_faultGuard.Guard(...)` wrapping) found on
        // 2026-09-07: this test stayed 12/12 green with the guard bypassed, because it was really
        // pinning the coordinator's timeout path, not the guard.
        var faulting = new ScriptedRenderer(ScriptedRenderer.Behavior.Succeed);
        var succeeding = new ScriptedRenderer(ScriptedRenderer.Behavior.Succeed);
        var chain = new[]
        {
            new WebRenderCandidate("faulting", new FixedCapability(true), faulting),
            new WebRenderCandidate("succeeding", new FixedCapability(true), succeeding),
        };
        string? reportedFailure = null;
        // FaultInjectingGuard faults only its FIRST invocation (see its own doc comment) — that
        // first invocation is "faulting"'s, so the guard itself is what turns an otherwise-
        // succeeding renderer into a failed candidate. Only reachable if the coordinator actually
        // routes the call through the guard.
        var coordinator = Coordinator(renderingEnabled: true, chain,
            onCandidateFailed: (name, _) => reportedFailure = name, faultGuard: new FaultInjectingGuard());

        var result = await coordinator.RenderAsync(MermaidRequest, CancellationToken.None);

        var rendered = Assert.IsType<WebRenderResult.Rendered>(result);
        Assert.Equal("succeeding", rendered.EngineName);
        Assert.Equal("faulting", reportedFailure);
    }

    [Fact]
    public async Task An_out_of_band_dispatcher_fault_with_no_fallback_lands_on_raw_not_a_crash()
    {
        // The exact contract the owner required: WebKitGTK missing/broken must fall back to raw,
        // never take the whole app down with it. Same "Succeed, not HangForever" reasoning as
        // above — the underlying renderer would otherwise happily return a real PNG if the guard
        // were bypassed, which is exactly what MG2 needs to be caught: the guard, not the
        // coordinator's pre-existing exception/timeout handling, is what closes this gap.
        var chain = new[]
        {
            new WebRenderCandidate("faulting", new FixedCapability(true), new ScriptedRenderer(ScriptedRenderer.Behavior.Succeed)),
        };
        var coordinator = Coordinator(renderingEnabled: true, chain, faultGuard: new FaultInjectingGuard());

        var result = await coordinator.RenderAsync(MermaidRequest, CancellationToken.None);

        var raw = Assert.IsType<WebRenderResult.Raw>(result);
        Assert.Equal(MermaidRequest.Code, raw.Source);
    }
}
