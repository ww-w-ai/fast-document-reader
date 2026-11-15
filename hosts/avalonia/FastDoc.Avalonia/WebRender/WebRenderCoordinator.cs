using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace FastDoc.Avalonia.WebRender;

/// <summary>
/// The pure decision logic behind the S12-F opt-in switch — no platform code lives here, only the
/// state machine: switch off → always raw; switch on → try each candidate in order, skipping one
/// whose capability gate fails, falling through to the next on an exception OR a timeout, and
/// landing on raw if every candidate is exhausted. This is what makes the design honest: raw is
/// never a silent failure state, it is the value this state machine always terminates at when
/// nothing else worked (see docs/studio/sprints/S12/s12f-scope-v2.md "기본 상태 재정의").
///
/// Every dependency is injected (<see cref="IWebRenderSettingsSource"/>, each candidate's
/// <see cref="IWebRenderCapability"/>/<see cref="IWebBlockRenderer"/>) so this class is testable
/// with fakes — no real WebView2/WebKitGTK/Chromium process ever runs in a unit test. The actual
/// platform renderers (WebRender/Renderers/) are exercised only by this coordinator at runtime and
/// are NOT covered by this repo's test suite: this development machine is macOS and cannot launch
/// a Windows WebView2 control, drive Linux WebKitGTK, or verify a PuppeteerSharp Chromium capture
/// end-to-end. Real-engine verification is a QA task on the actual target OS.
/// </summary>
public sealed class WebRenderCoordinator
{
    private readonly IWebRenderSettingsSource _settings;
    private readonly IReadOnlyList<WebRenderCandidate> _chain;
    private readonly TimeSpan _perCandidateTimeout;
    private readonly Action<string, Exception>? _onCandidateFailed;
    private readonly IWebRenderFaultGuard _faultGuard;

    public WebRenderCoordinator(
        IWebRenderSettingsSource settings,
        IReadOnlyList<WebRenderCandidate> chain,
        TimeSpan perCandidateTimeout,
        Action<string, Exception>? onCandidateFailed = null,
        IWebRenderFaultGuard? faultGuard = null)
    {
        _settings = settings;
        _chain = chain;
        _perCandidateTimeout = perCandidateTimeout;
        _onCandidateFailed = onCandidateFailed;
        _faultGuard = faultGuard ?? new NoOpFaultGuard();
    }

    public async Task<WebRenderResult> RenderAsync(WebBlockRequest request, CancellationToken cancellationToken)
    {
        if (!_settings.RenderingEnabled)
        {
            return WebRenderResult.AsRaw(request.Code);
        }

        foreach (var candidate in _chain)
        {
            if (!candidate.Capability.IsAvailable())
            {
                continue;
            }

            try
            {
                var image = await RunWithTimeoutAsync(candidate, request, cancellationToken).ConfigureAwait(false);
                if (image.Format != WebImageFormat.Png)
                {
                    // S12-F PM judgment (2026-09-07): "no exception" is not "success". Linux's
                    // WebKitGTK candidate hands back a PDF (see WebBlockImage's own doc comment) —
                    // this reader has no PDF-page rasterizer wired to a picture block, so a non-PNG
                    // result must fall through exactly like any other candidate failure, never be
                    // reported as AsRendered. Without this check, a working WebKitGTK install meant
                    // Linux could structurally never reach the PNG-capable on-demand-Chromium
                    // fallback that follows it in the real chain.
                    _onCandidateFailed?.Invoke(candidate.Name,
                        new NotSupportedException($"candidate '{candidate.Name}' produced {image.Format}, not a drawable Png"));
                    continue;
                }
                return WebRenderResult.AsRendered(image, candidate.Name);
            }
            catch (Exception ex) when (!(ex is OperationCanceledException) || !cancellationToken.IsCancellationRequested)
            {
                // A per-candidate timeout also lands here (as a TimeoutException from
                // RunWithTimeoutAsync, or an OperationCanceledException the RENDERER itself threw
                // that is NOT the caller's own cancellation) — both mean "this engine didn't work
                // this time", never "give up on the whole request".
                _onCandidateFailed?.Invoke(candidate.Name, ex);
                continue;
            }
        }

        return WebRenderResult.AsRaw(request.Code);
    }

    private async Task<WebBlockImage> RunWithTimeoutAsync(WebRenderCandidate candidate, WebBlockRequest request,
        CancellationToken callerToken)
    {
        using var timeoutCts = new CancellationTokenSource(_perCandidateTimeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(callerToken, timeoutCts.Token);

        // Wrapped in the fault guard so a platform failure that never flows back through this task
        // (see IWebRenderFaultGuard's own doc comment) is treated exactly like one that does.
        var renderTask = _faultGuard.Guard(() => candidate.Renderer.RenderAsync(request, linked.Token));
        var timeoutTask = Task.Delay(Timeout.InfiniteTimeSpan, timeoutCts.Token);

        var completed = await Task.WhenAny(renderTask, timeoutTask).ConfigureAwait(false);
        if (completed == renderTask)
        {
            // Awaiting the already-completed task rethrows its exception (if any) with its
            // original stack trace, exactly as `await candidate.Renderer.RenderAsync(...)`
            // would have — Task.WhenAny does not do that unwrapping for us.
            return await renderTask.ConfigureAwait(false);
        }

        callerToken.ThrowIfCancellationRequested();
        throw new TimeoutException(
            $"WebRender candidate '{candidate.Name}' did not complete within {_perCandidateTimeout}.");
    }
}
