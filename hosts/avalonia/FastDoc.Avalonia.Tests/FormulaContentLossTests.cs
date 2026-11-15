using System.Linq;
using System.Text.Json;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S12-F regression tests: a "formula" node (<see cref="FormulaPayload"/>) carries only
/// <c>Source</c> (raw LaTeX/tex text) and has no children. Before <c>FlowDocumentBuilder</c> grew
/// a "formula" case, that node fell to the default branch's <c>WalkChildren</c>, which visits zero
/// children — so every markdown <c>$$...$$</c> equation and every office-document formula vanished
/// with no visible trace, silently, the same class of bug S12-A fixed for footnotes
/// (<see cref="FootnoteContentLossTests"/>).
///
/// This host does not (yet) typeset the LaTeX into an image — see
/// docs/studio/sprints/S12/s12e-web-render-decision.md and s12f-scope-v2.md for why that needs an
/// opt-in real browser engine. The fix pinned here is narrower and unconditional: the raw source
/// text must always be VISIBLE, which is also the S12-F "opt-in off" default state by design.
/// </summary>
public class FormulaContentLossTests
{
    private static RenderTree Parse(string json) =>
        JsonSerializer.Deserialize<RenderTreeEnvelope>(json)!.Ok!.Value.Deserialize<RenderTree>()!;

    private const string OneFormulaDoc = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": { "format": "markdown", "rootNodeId": 0 },
        "nodes": [
          { "id": 0, "parentId": null, "children": [1, 2], "type": "document", "data": {} },
          { "id": 1, "parentId": 0, "children": [], "type": "paragraph", "data": { "style": {} } },
          { "id": 2, "parentId": 0, "children": [], "type": "formula",
            "data": { "block": true, "source": "E = mc^2" } }
        ]
      }
    }
    """;

    [Fact]
    public void Flow_mode_no_longer_drops_the_formula_source_text()
    {
        var blocks = FlowDocumentBuilder.Build(Parse(OneFormulaDoc));

        var allText = string.Join(" ", blocks
            .Where(b => b.Kind == FlowBlockKind.Text)
            .SelectMany(b => b.Runs)
            .Select(r => r.Text));

        Assert.Contains("E = mc^2", allText);
    }

    [Fact]
    public void Formula_produces_exactly_one_flow_block_carrying_the_full_source_as_one_run()
    {
        var blocks = FlowDocumentBuilder.Build(Parse(OneFormulaDoc));

        var formulaBlocks = blocks.Where(b => b.NodeId == 2).ToList();

        Assert.Single(formulaBlocks);
        Assert.Equal(FlowBlockKind.Text, formulaBlocks[0].Kind);
        var run = Assert.Single(formulaBlocks[0].Runs);
        Assert.Equal("E = mc^2", run.Text);
    }

    [Fact]
    public void Formula_is_styled_as_code_not_as_prose()
    {
        // The default-branch bug this pins would never reach a run at all; this assertion also
        // guards against a future "quick fix" that renders the formula with the surrounding
        // paragraph's font instead of the fixed-width code font (which would read as a rendering
        // choice, not the honest "this is markup" signal the S12-F default depends on).
        var blocks = FlowDocumentBuilder.Build(Parse(OneFormulaDoc));
        var run = blocks.Single(b => b.NodeId == 2).Runs.Single();

        // Same fixed-width family the "codeBlock" case uses (FlowDocumentBuilder.CodeFontFamily is
        // `internal`, not visible to this test project — pinned by value instead).
        Assert.Equal("Menlo, Consolas, monospace", run.FontFamily);
    }

    [Fact]
    public void An_empty_formula_source_still_produces_a_block_rather_than_throwing()
    {
        const string emptyFormulaDoc = """
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "markdown", "rootNodeId": 0 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [], "type": "formula", "data": { "block": true, "source": "" } }
            ]
          }
        }
        """;

        var blocks = FlowDocumentBuilder.Build(Parse(emptyFormulaDoc));

        var formulaBlock = Assert.Single(blocks, b => b.NodeId == 1);
        Assert.Equal("", Assert.Single(formulaBlock.Runs).Text);
    }
}
