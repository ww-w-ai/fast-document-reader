using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Rendering;
using FastDoc.Avalonia.WebRender;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S12-F regression tests: a markdown ```mermaid fence decodes to a "diagram" node
/// (<see cref="DiagramPayload"/>), NOT a "codeBlock" — see that payload's own doc comment in
/// RenderTreeEnvelope.cs. Before <c>FlowDocumentBuilder</c> grew a "diagram" case, that node fell
/// to the default branch's <c>WalkChildren</c>, which visits zero children (this node has none) —
/// so every mermaid diagram vanished with no visible trace, silently, in BOTH the raw-fallback and
/// the web-rendered path, since <c>FlowWebRenderPass</c>'s own candidate scan was ALSO looking at
/// the wrong accessor (`AsCodeBlock` instead of `AsDiagram`). Found visually on a real Linux VM on
/// 2026-09-07 while confirming S12-F's switch-off raw fallback — see
/// docs/studio/sprints/S12/s12f-web-render-optin.md.
/// </summary>
public class DiagramContentLossTests
{
    private static RenderTree Parse(string json) =>
        JsonSerializer.Deserialize<RenderTreeEnvelope>(json)!.Ok!.Value.Deserialize<RenderTree>()!;

    private const string OneDiagramDoc = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": { "format": "markdown", "rootNodeId": 0 },
        "nodes": [
          { "id": 0, "parentId": null, "children": [1, 2], "type": "document", "data": {} },
          { "id": 1, "parentId": 0, "children": [], "type": "paragraph", "data": { "style": {} } },
          { "id": 2, "parentId": 0, "children": [], "type": "diagram",
            "data": { "language": "mermaid", "source": "graph LR\n  A --> B", "renderedResourceId": null } }
        ]
      }
    }
    """;

    [Fact]
    public void Flow_mode_no_longer_drops_the_diagram_source_text()
    {
        var blocks = FlowDocumentBuilder.Build(Parse(OneDiagramDoc));

        var allText = string.Join(" ", blocks
            .Where(b => b.Kind == FlowBlockKind.Text)
            .SelectMany(b => b.Runs)
            .Select(r => r.Text));

        Assert.Contains("graph LR", allText);
    }

    [Fact]
    public void Diagram_produces_exactly_one_flow_block_carrying_the_full_source_as_one_run()
    {
        var blocks = FlowDocumentBuilder.Build(Parse(OneDiagramDoc));

        var diagramBlocks = blocks.Where(b => b.NodeId == 2).ToList();

        Assert.Single(diagramBlocks);
        Assert.Equal(FlowBlockKind.Text, diagramBlocks[0].Kind);
        var run = Assert.Single(diagramBlocks[0].Runs);
        Assert.Equal("graph LR\n  A --> B", run.Text);
    }

    [Fact]
    public void Diagram_is_styled_as_code_not_as_prose()
    {
        var blocks = FlowDocumentBuilder.Build(Parse(OneDiagramDoc));
        var run = blocks.Single(b => b.NodeId == 2).Runs.Single();

        // Same fixed-width family the "codeBlock"/"formula" cases use (FlowDocumentBuilder.
        // CodeFontFamily is `internal`, not visible to this test project — pinned by value).
        Assert.Equal("Menlo, Consolas, monospace", run.FontFamily);
    }

    [Fact]
    public void FlowWebRenderPass_finds_a_mermaid_diagram_candidate_via_AsDiagram_not_AsCodeBlock()
    {
        // Pins the OTHER half of this same bug: the candidate scan itself was checking the wrong
        // wire shape, so even with the switch on, a mermaid diagram was never handed to the
        // coordinator at all. A prior version of this test only asserted "Apply doesn't throw and
        // the block stays raw" with an empty candidate chain — that observes nothing, since an
        // empty chain and a chain that never matched look identical from the outside (lead's
        // mutation MD2, renaming the language comparison to "mermaid-mut", passed this test 4/4
        // while genuinely breaking candidate detection). This version injects a chain with ONE
        // recording renderer and asserts it was actually invoked, with the actual engine and
        // source text — so a broken match (wrong accessor, wrong language string) shows up as
        // zero invocations, not as "didn't throw".
        var tree = Parse(OneDiagramDoc);
        var blocks = FlowDocumentBuilder.Build(tree);
        var imageRenderer = new ImageBlockRenderer();
        imageRenderer.Reset(tree);
        var recorder = new RecordingRenderer();
        var chain = new[] { new WebRenderCandidate("recording-fake", new AlwaysAvailableCapability(), recorder) };
        var coordinator = new WebRenderCoordinator(
            new AlwaysEnabledSettingsSource(), chain, System.TimeSpan.FromSeconds(1));

        FlowWebRenderPass.Apply(blocks, tree, imageRenderer, coordinator);

        var invocation = Assert.Single(recorder.Invocations);
        Assert.Equal(WebBlockEngine.Mermaid, invocation.Engine);
        Assert.Equal("graph LR\n  A --> B", invocation.Code);

        // The recorder throws (see below) so the coordinator falls through to raw — this pass
        // never removes a block FlowDocumentBuilder already produced, only upgrades it.
        var diagramBlock = Assert.Single(blocks, b => b.NodeId == 2);
        Assert.Equal(FlowBlockKind.Text, diagramBlock.Kind);
    }

    private sealed class AlwaysEnabledSettingsSource : IWebRenderSettingsSource
    {
        public bool RenderingEnabled => true;
    }

    /// <summary>Records every request it is handed and always fails — per this test project's own
    /// rule (see WebRenderCoordinatorTests.cs's class-level comment), it must never genuinely
    /// await, so the failure is a synchronously-completed faulted Task, not a thrown exception nor
    /// a real async delay.</summary>
    private sealed class RecordingRenderer : IWebBlockRenderer
    {
        public List<WebBlockRequest> Invocations { get; } = new();

        public Task<WebBlockImage> RenderAsync(WebBlockRequest request, CancellationToken cancellationToken)
        {
            Invocations.Add(request);
            return Task.FromException<WebBlockImage>(new System.InvalidOperationException("test probe - not rendered"));
        }
    }
}
