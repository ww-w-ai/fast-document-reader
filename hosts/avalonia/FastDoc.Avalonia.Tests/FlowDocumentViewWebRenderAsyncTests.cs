using System.Reflection;
using System.Text.Json;
using Avalonia.Headless;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Rendering;
using FastDoc.Avalonia.WebRender;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S12-F2 (PM 2026-09-07): pins <c>FlowDocumentView.ScheduleWebRenderPass</c>'s swap-and-discard
/// contract — the mechanism that lets <c>SetTree</c> move the (possibly seconds-long) web-render
/// pass off the UI thread without a document reload racing a stale result into the wrong tree's
/// blocks. Uses <see cref="ImmediateWebRenderScheduler"/> throughout (see that class's own doc
/// comment) so every assertion here runs on the calling thread with no genuine await — matching
/// this whole test suite's rule (WebRenderCoordinatorTests.cs's class-level comment).
///
/// Reflection reaches `_blocks`/`_treeGeneration`/`ScheduleWebRenderPass` deliberately, matching
/// the existing pattern in FlowDocumentViewThreadSafetyTests.cs — these have no public surface,
/// and adding one only for these tests would widen FlowDocumentView's contract for no production
/// reason.
/// </summary>
public class FlowDocumentViewWebRenderAsyncTests
{
    public FlowDocumentViewWebRenderAsyncTests() => AvaloniaHeadlessSetup.EnsureReady();

    private const string OneParagraphDoc = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": { "format": "markdown", "rootNodeId": 0 },
        "nodes": [
          { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
          { "id": 1, "parentId": 0, "children": [], "type": "paragraph", "data": { "style": {} } }
        ]
      }
    }
    """;

    private static RenderTree ParseTree() =>
        JsonSerializer.Deserialize<RenderTreeEnvelope>(OneParagraphDoc)!.Ok!.Value.Deserialize<RenderTree>()!;

    private static FieldInfo Field(string name) =>
        typeof(FlowDocumentView).GetField(name, BindingFlags.NonPublic | BindingFlags.Instance)!;

    private static MethodInfo ScheduleWebRenderPassMethod() =>
        typeof(FlowDocumentView).GetMethod("ScheduleWebRenderPass", BindingFlags.NonPublic | BindingFlags.Instance)!;

    [Fact]
    public void A_matching_generation_swaps_the_background_pass_result_into_blocks()
    {
        var view = new FlowDocumentView(new ImmediateWebRenderScheduler());
        var tree = ParseTree();
        view.SetTree(tree);
        var blocksField = Field("_blocks");
        var originalBlocks = blocksField.GetValue(view);
        var currentGeneration = (int)Field("_treeGeneration").GetValue(view)!;

        ScheduleWebRenderPassMethod().Invoke(view, new object[] { tree, currentGeneration });

        var blocksAfter = blocksField.GetValue(view);
        // With ImmediateWebRenderScheduler the whole background+UI-thread hop runs inline, so by
        // the time Invoke returns the swap has already happened — the field now holds the SNAPSHOT
        // ScheduleWebRenderPass built and swapped in, a DIFFERENT List<FlowBlock> instance than the
        // one SetTree originally produced (even though its contents are equivalent, since this
        // fixture has no formula/diagram node for FlowWebRenderPass.Apply to change).
        Assert.NotSame(originalBlocks, blocksAfter);
    }

    [Fact]
    public void A_stale_generation_is_discarded_and_never_overwrites_the_newer_document()
    {
        var view = new FlowDocumentView(new ImmediateWebRenderScheduler());
        var firstTree = ParseTree();
        view.SetTree(firstTree); // generation 1
        var staleGeneration = (int)Field("_treeGeneration").GetValue(view)!;

        view.SetTree(ParseTree()); // generation 2 — supersedes the first before its pass "completes"
        var blocksField = Field("_blocks");
        var blocksAfterSecondSetTree = blocksField.GetValue(view);

        // Simulates the first SetTree's background pass finishing LATE, after the user already
        // moved on to a second document — exactly the race this generation token exists to catch.
        ScheduleWebRenderPassMethod().Invoke(view, new object[] { firstTree, staleGeneration });

        Assert.Same(blocksAfterSecondSetTree, blocksField.GetValue(view));
    }
}
