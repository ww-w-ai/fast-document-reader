using System;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// RenderTreeLoader.Load/LoadWithBreakdown must not leak the native OfficeDocumentHandle a
/// successful fastdoc_office_open returned if the JSON deserialize step after it throws
/// (malformed/truncated envelope JSON, or an "ok" payload that does not decode to RenderTree) — a
/// THROW between "open succeeded" and "JSON decoded" is not one of the explicit success/error
/// return paths that dispose the handle.
///
/// The guarantee lives in RenderTreeLoader.RunDisposingOnThrow&lt;TResult&gt;, a small generic
/// helper both Load and LoadWithBreakdown route their deserialize step through. Testing it here
/// with a plain IDisposable spy (rather than a real OfficeDocumentHandle) avoids needing either a
/// real native handle or a way to make the engine itself hand back malformed JSON — the disposal
/// guarantee is pure C# control flow, independent of what is actually being disposed.
/// </summary>
public class RenderTreeLoaderHandleDisposalTests
{
    private sealed class DisposalSpy : IDisposable
    {
        public int DisposeCount { get; private set; }
        public void Dispose() => DisposeCount++;
    }

    [Fact]
    public void Disposes_the_resource_exactly_once_when_the_body_throws()
    {
        var spy = new DisposalSpy();

        var ex = Assert.Throws<InvalidOperationException>(() =>
            RenderTreeLoader.RunDisposingOnThrow<int>(spy, () =>
                throw new InvalidOperationException("simulated malformed envelope JSON")));

        Assert.Equal("simulated malformed envelope JSON", ex.Message);
        Assert.Equal(1, spy.DisposeCount);
    }

    [Fact]
    public void Does_not_dispose_the_resource_when_the_body_succeeds()
    {
        // The caller (Load/LoadWithBreakdown) owns disposal on the success path — handing the
        // live handle onward to LoadResult.Handle/LoadBreakdown.Handle for E2d's lazy image
        // fetch — so RunDisposingOnThrow itself must stay hands-off when nothing threw.
        var spy = new DisposalSpy();

        var result = RenderTreeLoader.RunDisposingOnThrow(spy, () => 42);

        Assert.Equal(42, result);
        Assert.Equal(0, spy.DisposeCount);
    }

    [Fact]
    public void A_null_resource_is_a_no_op_on_throw_rather_than_a_NullReferenceException()
    {
        // The text-extension path (markdown/plain text) never has a handle at all — Load/
        // LoadWithBreakdown pass `handle` (null in that case) through unconditionally, so a null
        // resource must be tolerated here, not just by callers remembering to null-check first.
        var ex = Assert.Throws<InvalidOperationException>(() =>
            RenderTreeLoader.RunDisposingOnThrow<int>(null, () =>
                throw new InvalidOperationException("no handle to leak")));

        Assert.Equal("no handle to leak", ex.Message);
    }
}
