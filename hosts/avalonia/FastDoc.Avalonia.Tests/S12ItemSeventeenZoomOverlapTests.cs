using System;
using System.Collections.Generic;
using System.Reflection;
using System.Text;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Media.TextFormatting;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Printing;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>S12 item-17 (studio-pm's baseline-regression report, s12b): "줄인 1회만 해도 헤딩과
/// 인접 코드블록 텍스트가 서로 겹쳐 그려진다" — reproduced on a real Ubuntu VM with
/// <c>demo/code-blocks.md</c> (heading immediately above/below a code fence), Ctrl+= once, and did
/// NOT self-heal on Ctrl+0 or after a 1s wait with no further interaction.
///
/// Root cause: a code block with no per-token highlighter runs becomes ONE <see cref="FlowRun"/>
/// whose <c>Text</c> carries the source's own embedded "\n" characters verbatim (see
/// <c>FlowDocumentBuilder.BuildCodeRuns</c>'s null-<c>cb.Runs</c> branch) — Avalonia's
/// <c>TextLayout</c> honours those as real forced line breaks. <see
/// cref="FlowDocumentView.EstimateHeight"/>'s character-count guess (`charCount / charsPerLine`)
/// has no way to see them: it estimates line count from TOTAL characters divided by an assumed
/// wrap width, so a 20-line code block whose lines are each far shorter than that assumed width
/// estimates as roughly ONE line. Right after a width/zoom change every block's `_measured` flag
/// is reset (see <c>EnsureEstimates</c>), so the OLD code drew the very next frame using this
/// badly-undersized estimate for the code block's reserved height, then drew whatever followed it
/// (here, a heading) starting at the offset the estimate implied — overlapping the code block's
/// real (much taller) content. Because <c>SetZoom</c> (Ctrl+=/Ctrl+0) fires exactly one
/// <c>InvalidateVisual()</c> and nothing else re-invalidates without a scroll, that one wrong frame
/// was also the LAST one drawn — matching the VM's "does not clear on Ctrl+0, does not clear after
/// waiting" report exactly.</summary>
public class S12ItemSeventeenZoomOverlapTests
{
    public S12ItemSeventeenZoomOverlapTests() => AvaloniaHeadlessSetup.EnsureReady();

    /// <summary>Heading ("C++") directly above a 24-line code block, directly above another
    /// heading ("Rust") — the exact adjacency <c>demo/code-blocks.md</c> has at every language
    /// switch, and the one the VM screenshots showed overlapping.</summary>
    private static RenderTree HeadingCodeHeadingTree()
    {
        var codeLines = new StringBuilder();
        for (var i = 1; i <= 24; i++)
        {
            if (i > 1) { codeLines.Append('\n'); }
            codeLines.Append("int line_").Append(i).Append(" = 0;"); // short — far under any wrap width
        }
        var codeJson = JsonSerializer.Serialize(codeLines.ToString());

        var json = $$"""
        {
          "schemaVersion": 1,
          "document": { "rootNodeId": 0, "defaultBodyFontSize": 12.0 },
          "nodes": [
            { "id": 0, "parentId": null, "type": "document", "children": [1, 3, 4], "data": {} },
            { "id": 1, "parentId": 0, "type": "heading", "children": [2],
              "data": { "level": 1, "style": {} } },
            { "id": 2, "parentId": 1, "type": "textRun", "children": [], "data": { "text": "C++", "style": {} } },
            { "id": 3, "parentId": 0, "type": "codeBlock", "children": [],
              "data": { "language": "c", "text": {{codeJson}} } },
            { "id": 4, "parentId": 0, "type": "heading", "children": [5],
              "data": { "level": 1, "style": {} } },
            { "id": 5, "parentId": 4, "type": "textRun", "children": [], "data": { "text": "Rust", "style": {} } }
          ]
        }
        """;
        return JsonSerializer.Deserialize<RenderTree>(json)!;
    }

    private static T GetPrivateField<T>(object obj, string name)
    {
        var field = typeof(FlowDocumentView).GetField(name, BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new InvalidOperationException($"FlowDocumentView.{name} not found — has it been renamed?");
        return (T)field.GetValue(obj)!;
    }

    /// <summary>REVISE (team-lead, S12 wave-2): the two geometry tests below used to read
    /// <c>_offsets</c>/<c>_blockHeights</c> AFTER <c>window.CaptureRenderedFrame()</c> returned —
    /// but <see cref="FlowDocumentView.RenderCore"/>'s PRE-EXISTING post-draw correction (the
    /// `if (!_measured[i] || ...) { _blockHeights[i] = actualHeight; ...offsetsDirty = true; }`
    /// loop that already ran before this fix existed, then `RebuildOffsets()` once more at the very
    /// end of the same call) rewrites both arrays to the REAL geometry by the time RenderCore
    /// returns — regardless of whether the S12 item-17 pre-measure pass ran at all. A lead mutation
    /// (inverting the pre-measure loop's `FlowBlockKind.Text` guard so it does nothing) proved this:
    /// all three original tests stayed green with the fix fully disabled. Reading post-frame state
    /// can only ever see what the LAST correction in the call left behind, never what the FRAME
    /// actually painted while it ran.
    ///
    /// The bug was never about the final state of those arrays — the post-draw correction already
    /// fixed them every time, before AND after this sprint's change. The bug was that the draw
    /// LOOP itself, mid-frame, positions block i+1 using `_offsets[i+1]` READ BEFORE block i's own
    /// post-draw correction has run (that correction and the offset rebuild happen only once, AFTER
    /// the whole loop finishes) — so the heading gets PAINTED at a Y coordinate computed from the
    /// still-stale, under-estimated code-block height. The pre-measure pass fixes this by rebuilding
    /// `_offsets` from REAL heights before the draw loop starts at all, so every block's `_offsets[i]`
    /// is already correct by the time the loop reaches it.
    ///
    /// To pin that, these tests now call the SAME internal <c>RenderCore</c> the real
    /// <c>Render(DrawingContext)</c> calls (via reflection — no InternalsVisibleTo grant exists to
    /// this project, matching every other file's documented reason for not calling it directly) with
    /// a recording <see cref="IPageCanvas"/> instead of <c>window.CaptureRenderedFrame()</c>'s real
    /// AvaloniaPageCanvas, and assert on the (origin, layout) pairs it actually received for that
    /// ONE frame — the exact values a real screen would have painted — rather than on state read
    /// after the call returns.</summary>
    private sealed class RecordingPageCanvas : IPageCanvas
    {
        public readonly List<(Point Origin, TextLayout Layout)> TextLayoutCalls = new();
        public void DrawRect(Rect rect, Color? fill, Color? stroke, double strokeThicknessPx) { }
        public void DrawLine(Point a, Point b, Color color, double thicknessPx) { }
        public void DrawImage(Bitmap bitmap, byte[]? sourceBytes, string? sourceMimeType, Rect destRect) { }
        public void DrawTextLayout(TextLayout layout, Point origin) => TextLayoutCalls.Add((origin, layout));
        public void DrawTextLine(TextLine line, Point origin) { }
    }

    /// <summary>Invokes the real, private draw path with a recording canvas — same method the
    /// real <c>Render(DrawingContext)</c> calls, same state mutations, same order; only the
    /// destination (a list instead of pixels) differs.</summary>
    private static List<(Point Origin, TextLayout Layout)> CaptureOneFrameTextDraws(FlowDocumentView view)
    {
        var renderCore = typeof(FlowDocumentView).GetMethod("RenderCore", BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new InvalidOperationException("FlowDocumentView.RenderCore not found — has it been renamed?");
        var spy = new RecordingPageCanvas();
        renderCore.Invoke(view, new object[] { spy });
        return spy.TextLayoutCalls;
    }

    /// <summary>Pins the ROOT CAUSE (not the symptom): right after SetZoom, before a single pixel
    /// of the next frame is drawn, <see cref="FlowDocumentView.EstimateHeight"/>'s guess for the
    /// 24-line code block must already be far short of what real text-shaping will measure — this
    /// is what a screen-space overlap test could only show indirectly. If this ever stops being
    /// true (e.g. EstimateHeight learns to count embedded newlines), the mechanism this bug relied
    /// on is gone and this test's own assumption needs revisiting alongside it.</summary>
    [Fact]
    public void Right_after_zoom_the_character_count_estimate_for_a_multiline_code_block_is_far_short_of_its_real_height()
    {
        var tree = HeadingCodeHeadingTree();
        var view = new FlowDocumentView();
        view.SetTree(tree);
        var window = new Window { Width = 700, Height = 700, Content = view };
        window.Show();
        window.CaptureRenderedFrame(); // settle once at zoom=1.0, matching a document that was already open

        view.ZoomIn(); // one Ctrl+= — SetZoom resets _measured and rebuilds _offsets from ESTIMATES only
        var estimateRightAfterZoom = GetPrivateField<double[]>(view, "_blockHeights")[1]; // codeBlock is block index 1

        window.CaptureRenderedFrame(); // the one real frame the VM's screenshot captured
        var realHeightAfterOneFrame = GetPrivateField<double[]>(view, "_blockHeights")[1];

        // 24 short lines at zoom 1.1 is nowhere near one line's height — if the estimate were even
        // roughly right, this ratio would be close to 1, not a small fraction of it.
        Assert.True(estimateRightAfterZoom < realHeightAfterOneFrame * 0.5,
            $"expected the pre-render character-count estimate ({estimateRightAfterZoom:F1}) to be far " +
            $"below the real 24-line height ({realHeightAfterOneFrame:F1}) — if they're close, the " +
            $"estimate is no longer the blind spot this test exists to pin.");
    }

    /// <summary>The regression itself, stated as the geometry a real screen would show: after
    /// exactly ONE zoom step, the ONE frame the real <c>Render(DrawingContext)</c> would paint next
    /// — captured directly via <see cref="CaptureOneFrameTextDraws"/>, not read back afterward —
    /// must not place the code block's own text and the following heading's text at overlapping Y
    /// ranges. Before the S12 item-17 fix this failed: the draw loop positioned the heading using
    /// `_offsets[2]`, which at that point in the SAME frame's loop still held the stale,
    /// under-estimated offset — the post-draw correction that fixes `_offsets` for good does not run
    /// until the whole loop has finished.</summary>
    [Fact]
    public void One_zoom_step_paints_the_heading_after_the_code_blocks_real_text_never_inside_it()
    {
        var tree = HeadingCodeHeadingTree();
        var view = new FlowDocumentView();
        view.SetTree(tree);
        var window = new Window { Width = 700, Height = 700, Content = view };
        window.Show();
        window.CaptureRenderedFrame(); // settle once at zoom=1.0

        view.ZoomIn(); // exactly one Ctrl+=
        var draws = CaptureOneFrameTextDraws(view); // the exact frame the VM's screenshot showed

        // Three text blocks in document order: heading "C++" (0), the 24-line code block (1), and
        // heading "Rust" (2). DrawBlock/DrawTextBlock call DrawTextLayout exactly once per text
        // block, in block order, so the calls line up positionally.
        Assert.True(draws.Count >= 3, $"expected at least 3 DrawTextLayout calls (got {draws.Count})");
        var codeBlockDraw = draws[1];
        var headingAfterDraw = draws[2];
        var codeBlockRealBottom = codeBlockDraw.Origin.Y + codeBlockDraw.Layout.Height;

        Assert.True(codeBlockDraw.Layout.Height > 40,
            $"the code block's own layout must actually measure as several lines tall (got " +
            $"{codeBlockDraw.Layout.Height:F1}px for 24 lines) — a single-line measurement means this " +
            $"test isn't exercising the multi-line blind spot it exists to catch.");
        Assert.True(headingAfterDraw.Origin.Y >= codeBlockRealBottom - 0.5,
            $"the heading was painted at y={headingAfterDraw.Origin.Y:F1}, before the code block's own " +
            $"real text ends at y={codeBlockRealBottom:F1} (top={codeBlockDraw.Origin.Y:F1} + " +
            $"height={codeBlockDraw.Layout.Height:F1}) — this IS the reported overlap: the heading is " +
            $"painted on top of the code block's own text in this exact frame.");
    }

    /// <summary>Same check after Ctrl+0 (ZoomReset) — the VM report explicitly noted the overlap
    /// "does not clear on reset either", so the fix must hold for SetZoom generally, not only
    /// ZoomIn.</summary>
    [Fact]
    public void Zoom_reset_after_zooming_in_also_paints_with_no_overlap()
    {
        var tree = HeadingCodeHeadingTree();
        var view = new FlowDocumentView();
        view.SetTree(tree);
        var window = new Window { Width = 700, Height = 700, Content = view };
        window.Show();
        window.CaptureRenderedFrame();

        view.ZoomIn();
        window.CaptureRenderedFrame();
        view.ZoomIn();
        window.CaptureRenderedFrame();
        view.ZoomReset(); // Ctrl+0
        var draws = CaptureOneFrameTextDraws(view); // the one frame after reset the VM screenshotted

        Assert.True(draws.Count >= 3, $"expected at least 3 DrawTextLayout calls (got {draws.Count})");
        var codeBlockDraw = draws[1];
        var headingAfterDraw = draws[2];
        var codeBlockRealBottom = codeBlockDraw.Origin.Y + codeBlockDraw.Layout.Height;

        Assert.True(headingAfterDraw.Origin.Y >= codeBlockRealBottom - 0.5,
            $"after Ctrl+0, the heading is still painted at y={headingAfterDraw.Origin.Y:F1}, before the " +
            $"code block's real text ends at y={codeBlockRealBottom:F1} — reset alone must not be required " +
            $"to clear the overlap; the very first post-reset frame must already be correct.");
    }
}
