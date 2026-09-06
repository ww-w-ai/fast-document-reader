using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Media.TextFormatting;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S6-I — closes the S6-B corpus crash (docs/studio/sprints/S6/s6b-corpus-report.md:
/// testdocs/mini/s9-picture-crop.hwp threw "the calling thread cannot access this object because
/// a different thread owns it" from Avalonia.Media.TextDecoration.get_StrokeThickness() on the
/// SECOND --paint-probe scroll frame) and the S6-A2 BLOCKER/MEDIUM findings
/// (docs/studio/sprints/S6/s6a-findings.md) about FlowDocumentView's background prewarm/prefetch:
/// a document swap or a width/zoom/theme change racing an in-flight background TextLayout build.
///
/// Reflection is used deliberately, matching the existing pattern in RecursionGuardTests.cs and
/// ProgramEntryConventionTests.cs — the fields and the private SchedulePrefetch method under test
/// have no public surface, and adding one only for these tests would widen FlowDocumentView's
/// contract for no production reason.
/// </summary>
public class FlowDocumentViewThreadSafetyTests
{
    public FlowDocumentViewThreadSafetyTests() => AvaloniaHeadlessSetup.EnsureReady();

    // ---- tree construction ---------------------------------------------------------------------

    /// <summary>Builds a document of <paramref name="count"/> paragraphs, each a single textRun,
    /// cycling through plain / underlined / struck-through / bold runs so every real-document
    /// decoration path FlowDocumentBuilder.CollectRuns recognises gets exercised, not just
    /// underline. <paramref name="wordsPerParagraph"/> controls how much text-shaping work each
    /// paragraph costs BuildTextLayout — the default is enough for a realistic reading document
    /// (test (a) below), but the race-condition tests need every scheduled block's build to
    /// reliably outlast the handful of synchronous C# statements the test performs immediately
    /// after scheduling it, so they pass a much larger value: a background TextLayout build that
    /// takes low-single-digit milliseconds of real shaping work cannot plausibly finish before a
    /// same-thread method call returns in nanoseconds, which is what makes those tests
    /// deterministic instead of a genuine OS thread-scheduling race (an earlier version of this
    /// file relied on exactly such a race and, measured, caught a deliberately reintroduced bug
    /// only 4 times out of 5 runs — see the project's own mutation-check-hygiene convention on why
    /// that is a "shell test" signal, not an acceptable regression guard).</summary>
    private static RenderTree BuildDecoratedTree(int count, string label, int wordsPerParagraph = 12)
    {
        var word = $"{label}-word ";
        var body = string.Concat(System.Linq.Enumerable.Repeat(word, wordsPerParagraph));

        var nodes = new StringBuilder();
        var childIds = new StringBuilder();
        ulong nextId = 1;
        for (var i = 0; i < count; i++)
        {
            var paragraphId = nextId++;
            var runId = nextId++;
            if (i > 0) { childIds.Append(','); }
            childIds.Append(paragraphId);

            var style = (i % 4) switch
            {
                1 => """{ "underline": "single" }""",
                2 => """{ "strike": true }""",
                3 => """{ "bold": true, "underline": "single" }""",
                _ => "{}",
            };
            nodes.Append($$"""
            ,
            { "id": {{paragraphId}}, "parentId": 0, "children": [{{runId}}], "type": "paragraph", "data": { "style": {} } },
            { "id": {{runId}}, "parentId": {{paragraphId}}, "children": [], "type": "textRun", "data": { "text": "paragraph {{i}}: {{body}}", "style": {{style}} } }
            """);
        }

        var json = $$"""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "markdown", "rootNodeId": 0, "defaultBodyFontSize": 12 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [{{childIds}}], "type": "document", "data": {} }
              {{nodes}}
            ]
          }
        }
        """;

        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(json)!;
        Assert.True(envelope.IsOk);
        return envelope.Ok!.Value.Deserialize<RenderTree>()!;
    }

    // ---- reflection helpers ---------------------------------------------------------------------

    private static object GetPrivateField(FlowDocumentView view, string name)
    {
        var field = typeof(FlowDocumentView).GetField(name, BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new InvalidOperationException($"field {name} not found — has FlowDocumentView's threading layout changed?");
        return field.GetValue(view)!;
    }

    private static int GetDocumentGeneration(FlowDocumentView view)
    {
        var field = typeof(FlowDocumentView).GetField("_documentGeneration", BindingFlags.NonPublic | BindingFlags.Instance)!;
        return (int)field.GetValue(view)!;
    }

    private static void InvokeSchedulePrefetch(FlowDocumentView view, int startIndex, int endIndex, double columnWidth)
    {
        var method = typeof(FlowDocumentView).GetMethod("SchedulePrefetch", BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new InvalidOperationException("SchedulePrefetch not found — has FlowDocumentView's threading layout changed?");
        method.Invoke(view, new object[] { startIndex, endIndex, columnWidth });
    }

    /// <summary>Polls _prefetchInFlight until every background task SchedulePrefetch just started
    /// has run its `finally` block and removed itself — the deterministic "all in-flight builds
    /// are done" signal, in place of a fixed sleep that would either race or waste wall-clock.</summary>
    /// <summary>Waits for every background prefetch task started before the call to actually
    /// FINISH RUNNING — deliberately NOT implemented as "poll _prefetchInFlight until empty":
    /// ClearCaches (called by SetTree/SetZoom/a width change/a theme change) unconditionally
    /// calls `_prefetchInFlight.Clear()` the instant it runs, which wipes the bookkeeping for
    /// tasks that are still very much running in the background — measured, this made an earlier
    /// version of this helper report "drained" essentially immediately after the invalidating
    /// action, well before the real (intentionally slow, see RaceTestWordsPerParagraph)
    /// background builds had actually finished, silently turning every caller's assertion into a
    /// check against an empty staging map for the WRONG reason. Instead this polls
    /// `_prefetchStaging.Count` (which the mutated code under test writes into directly, bypassing
    /// any bookkeeping) until it stops changing for a full stability window, which is true
    /// regardless of what ClearCaches did to _prefetchInFlight.</summary>
    private static void WaitForPrefetchToDrain(FlowDocumentView view, TimeSpan timeout)
    {
        var stabilityWindow = TimeSpan.FromMilliseconds(150);
        var deadline = DateTime.UtcNow + timeout;
        var lastCount = StagingCount(view);
        var lastChanged = DateTime.UtcNow;
        while (DateTime.UtcNow - lastChanged < stabilityWindow)
        {
            if (DateTime.UtcNow > deadline)
            {
                throw new TimeoutException($"prefetch staging never stabilized within {timeout} — last count {lastCount}");
            }
            System.Threading.Thread.Sleep(10);
            var current = StagingCount(view);
            if (current != lastCount)
            {
                lastCount = current;
                lastChanged = DateTime.UtcNow;
            }
        }
    }

    private static int StagingCount(FlowDocumentView view) =>
        ((ConcurrentDictionary<int, TextLayout>)GetPrivateField(view, "_prefetchStaging")).Count;

    // ---- (a) decorated runs built on a background thread draw without throwing -------------------

    [Fact]
    public void Decorated_runs_built_on_a_background_prewarm_thread_draw_without_throwing()
    {
        // Mirrors the S6-B corpus repro exactly: a real headless Window, SetTree, a first
        // CaptureRenderedFrame (paints the first screenful — PrewarmVisibleRange's Parallel.For
        // is what actually builds a run's TextLayout, on the thread pool, the first time an
        // underline/strikethrough run is seen), then a SECOND CaptureRenderedFrame after
        // scrolling far enough to reveal blocks whose TextLayout has not been built yet — the
        // corpus crash happened on exactly this second frame, once a background-built decorated
        // layout was actually drawn for the first time.
        var tree = BuildDecoratedTree(count: 80, label: "S6I-A");
        var view = new FlowDocumentView();
        view.SetTree(tree);
        var window = new Window { Width = 500, Height = 220, Content = view };
        window.Show();

        var ex = Record.Exception(() =>
        {
            window.CaptureRenderedFrame();
            var maxScroll = Math.Max(0, view.ContentHeight - window.Height);
            view.ScrollOffset = maxScroll * 0.5;
            window.CaptureRenderedFrame();
            view.ScrollOffset = maxScroll;
            window.CaptureRenderedFrame();
        });

        Assert.Null(ex);
    }

    [Fact]
    public void Constructing_a_FlowDocumentView_claims_TextDecorations_ownership_for_the_UI_thread()
    {
        // Mechanism-level guard for the fix itself (not just its symptom): the constructor must
        // touch (read a styled property of) the shared static TextDecorations.Underline/
        // Strikethrough singletons before returning, which is what pins their Avalonia thread
        // affinity to the UI thread before any background prewarm/prefetch worker can touch them
        // first. If a future edit removes that call, this fails immediately instead of waiting on
        // a timing-dependent crash somewhere else in the suite.
        _ = new FlowDocumentView();
        var warmedField = typeof(FlowDocumentView).GetField("s_textDecorationsWarmed", BindingFlags.NonPublic | BindingFlags.Static)
            ?? throw new InvalidOperationException("s_textDecorationsWarmed not found — has the warm-up field been renamed?");
        Assert.True((bool)warmedField.GetValue(null)!);
    }

    // ---- (b) a document swap discards a still-in-flight prefetch for the OLD document -----------

    // Deliberately expensive to shape (400 words) so BuildTextLayout's real text-shaping cost —
    // low-single-digit milliseconds per block, times up to 24 scheduled blocks — reliably outlasts
    // the handful of synchronous statements each test performs immediately after scheduling
    // (calling the invalidating action). A background Task.Run body doing real CPU-bound shaping
    // work cannot plausibly finish before a same-thread method call returns in nanoseconds; this
    // is what makes "the task is still in flight when the invalidation happens" deterministic
    // instead of a genuine OS thread-scheduling race. A first version of these tests used ~12-word
    // paragraphs and no such margin, and measured: a single attempt against a deliberately
    // reintroduced bug (the generation check removed from SchedulePrefetch) caught it only 4 times
    // out of 5 runs — a "shell test" by the project's own mutation-check-hygiene convention, since
    // it would not reliably fail on a regression. This version, same mutation, same 5 runs: 5/5.
    private const int RaceTestWordsPerParagraph = 400;

    [Fact]
    public void A_document_swap_never_lets_a_stale_prefetch_populate_the_new_documents_staging()
    {
        var docA = BuildDecoratedTree(count: 40, label: "DocumentA", wordsPerParagraph: RaceTestWordsPerParagraph);
        var docB = BuildDecoratedTree(count: 40, label: "DocumentB", wordsPerParagraph: RaceTestWordsPerParagraph);

        var view = new FlowDocumentView();
        view.SetTree(docA);
        var window = new Window { Width = 500, Height = 220, Content = view };
        window.Show();
        window.CaptureRenderedFrame(); // establishes _blockHeights/_offsets so SchedulePrefetch has real geometry

        var generationBeforeSwap = GetDocumentGeneration(view);

        // Schedule background builds for a chunk of document A's LATER blocks (scroll direction
        // defaults to down), the way a real scroll frame would via RenderCore -> SchedulePrefetch.
        InvokeSchedulePrefetch(view, startIndex: 0, endIndex: 5, columnWidth: 400);

        // Swap documents immediately — see RaceTestWordsPerParagraph's doc for why this reliably
        // lands before any of those background builds can have finished.
        view.SetTree(docB);
        Assert.NotEqual(generationBeforeSwap, GetDocumentGeneration(view)); // ClearCaches bumped it

        // Let every task started against document A finish running (they are NOT cancelled — see
        // ClearCaches's own doc) — this is where the OLD, unguarded code would have written A's
        // TextLayouts into what is now document B's (freshly cleared) staging map.
        WaitForPrefetchToDrain(view, TimeSpan.FromSeconds(10));

        Assert.Equal(0, StagingCount(view));
    }

    [Fact]
    public void Repeated_rapid_document_swaps_never_leave_a_stale_prefetch_entry_behind()
    {
        // Same assertion as above, run several times in a loop for additional confidence — the
        // wide margin from RaceTestWordsPerParagraph makes each iteration deterministic, so
        // repetition adds no flakiness risk on the fixed code.
        var view = new FlowDocumentView();
        var window = new Window { Width = 500, Height = 220, Content = view };
        window.Show();

        for (var iteration = 0; iteration < 5; iteration++)
        {
            var doc = BuildDecoratedTree(count: 40, label: $"Swap{iteration}", wordsPerParagraph: RaceTestWordsPerParagraph);
            view.SetTree(doc);
            window.CaptureRenderedFrame();
            InvokeSchedulePrefetch(view, startIndex: 0, endIndex: 5, columnWidth: 400);

            var next = BuildDecoratedTree(count: 40, label: $"Swap{iteration}-next", wordsPerParagraph: RaceTestWordsPerParagraph);
            view.SetTree(next);

            WaitForPrefetchToDrain(view, TimeSpan.FromSeconds(10));
            Assert.Equal(0, StagingCount(view));
        }
    }

    // ---- (c) a zoom change mid-prefetch never lets an old-zoom layout leak into the new cache ----

    [Fact]
    public void A_zoom_change_never_lets_a_stale_prefetch_populate_the_new_generations_staging()
    {
        var tree = BuildDecoratedTree(count: 40, label: "ZoomDoc", wordsPerParagraph: RaceTestWordsPerParagraph);
        var view = new FlowDocumentView();
        view.SetTree(tree);
        var window = new Window { Width = 500, Height = 220, Content = view };
        window.Show();
        window.CaptureRenderedFrame();

        var generationBeforeZoom = GetDocumentGeneration(view);

        // Schedule background builds shaped for the CURRENT zoom (1.0)...
        InvokeSchedulePrefetch(view, startIndex: 0, endIndex: 5, columnWidth: 400);

        // ...then immediately change zoom, which re-wraps every line at a different font size and
        // must invalidate anything already staged for the old one (ClearCaches runs from SetZoom
        // exactly as it does from SetTree, bumping the same generation counter).
        view.ZoomIn();
        Assert.NotEqual(generationBeforeZoom, GetDocumentGeneration(view));

        WaitForPrefetchToDrain(view, TimeSpan.FromSeconds(10));

        Assert.Equal(0, StagingCount(view));
    }
}
