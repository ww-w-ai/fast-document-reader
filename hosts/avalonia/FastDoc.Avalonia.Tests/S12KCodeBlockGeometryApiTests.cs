using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Rendering;
using Xunit;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S12-K items 46/47 preflight (docs/studio/sprints/S12/pl-plan.md "S12-K 분담"): the signature
/// `impl-chrome` builds its Copy/Wrap code-block chips against.
///
/// (46) <see cref="FlowBlock.IsCodeBlock"/> — a real fenced code block, distinguished from a
/// "formula"/"diagram" block that happens to borrow the same monospace styling. Combined with the
/// block's own pre-existing <see cref="FlowBlock.NodeId"/> (anchor) and
/// <see cref="FlowBlock.IndentPoints"/> (left-edge offset within the column), this is the boundary
/// metadata this builder owns — assembling it into an on-screen Rect needs the per-block Y-offset
/// and height <see cref="FlowDocumentView"/> already tracks for virtualization/scroll, which stays
/// that file's own job per this file's header note ("actual line-breaking and pixel placement is
/// FlowDocumentView's job").
///
/// (47, REVISE) <see cref="FlowDocumentBuilder.Build"/>'s `wrapCodeBlocks` parameter (default
/// `true`, so the existing no-arg call site needs no change) sets ONLY
/// <see cref="FlowBlock.WrapCode"/> — an intent flag. The run TEXT never changes: an earlier
/// design substituted NBSP for ASCII space to physically prevent wrapping, and the lead rejected
/// it — that mutation corrupts a Copy chip's clipboard output, plain-selection copy, find,
/// `--extract`, and `pdftotext` diffs (all read the same `FlowRun` text). `FlowDocumentView` reads
/// `WrapCode` to choose `TextWrapping.Wrap` vs `NoWrap` when it builds that block's `TextLayout` —
/// this builder decides intent only, never pixels or bytes.
/// </summary>
public class S12KCodeBlockGeometryApiTests
{
    private static RenderTree TreeWithCodeFormulaDiagramAndParagraph()
    {
        var codeData = JsonDocument.Parse("""{ "language": "rust", "fenced": true, "text": "fn main() { let x = 1 + 2; }" }""").RootElement.Clone();
        var formulaData = JsonDocument.Parse("""{ "source": "x^2", "display": true, "alignment": "natural" }""").RootElement.Clone();
        var diagramData = JsonDocument.Parse("""{ "source": "graph TD; A-->B;" }""").RootElement.Clone();
        var paragraphData = JsonDocument.Parse("""{ "style": {} }""").RootElement.Clone();
        var textRunData = JsonDocument.Parse("""{ "text": "hello world", "style": {} }""").RootElement.Clone();

        return new RenderTree
        {
            SchemaVersion = 1,
            Document = new RenderDocument { RootNodeId = 0, DefaultBodyFontSize = 12 },
            Nodes = new List<RenderNode>
            {
                new() { Id = 0, Type = "document", Children = new List<ulong> { 1, 2, 3, 4 }, Data = JsonDocument.Parse("{}").RootElement.Clone() },
                new() { Id = 1, Type = "codeBlock", Children = new List<ulong>(), Data = codeData },
                new() { Id = 2, Type = "formula", Children = new List<ulong>(), Data = formulaData },
                new() { Id = 3, Type = "diagram", Children = new List<ulong>(), Data = diagramData },
                new() { Id = 4, Type = "paragraph", Children = new List<ulong> { 5 }, Data = paragraphData },
                new() { Id = 5, Type = "textRun", Children = new List<ulong>(), Data = textRunData },
            },
        };
    }

    [Fact]
    public void IsCodeBlock_is_true_only_for_a_real_fenced_codeBlock_node()
    {
        var tree = TreeWithCodeFormulaDiagramAndParagraph();
        var blocks = FlowDocumentBuilder.Build(tree);

        Assert.Equal(4, blocks.Count);
        Assert.True(blocks[0].IsCodeBlock, "the codeBlock node's own block");
        Assert.False(blocks[1].IsCodeBlock, "a formula block, despite sharing the code font family");
        Assert.False(blocks[2].IsCodeBlock, "a diagram block, despite sharing the code font family");
        Assert.False(blocks[3].IsCodeBlock, "an ordinary prose paragraph");
    }

    [Fact]
    public void The_codeBlock_carries_its_own_NodeId_and_IndentPoints_as_boundary_anchor_metadata()
    {
        var tree = TreeWithCodeFormulaDiagramAndParagraph();
        var blocks = FlowDocumentBuilder.Build(tree);
        var code = blocks.Single(b => b.IsCodeBlock);

        Assert.Equal(1UL, code.NodeId);
        Assert.True(code.IndentPoints > 0, "a code block indents in from the column's own left edge");
    }

    [Fact]
    public void WrapCode_defaults_to_true_matching_every_block_and_the_pre_existing_behavior()
    {
        var tree = TreeWithCodeFormulaDiagramAndParagraph();
        var defaultCall = FlowDocumentBuilder.Build(tree);
        var explicitTrue = FlowDocumentBuilder.Build(tree, wrapCodeBlocks: true);

        Assert.True(defaultCall.Single(b => b.IsCodeBlock).WrapCode);
        Assert.True(explicitTrue.Single(b => b.IsCodeBlock).WrapCode);
    }

    [Fact]
    public void Wrap_false_flips_only_the_WrapCode_flag_and_never_touches_the_runs_text()
    {
        var tree = TreeWithCodeFormulaDiagramAndParagraph();
        var wrapOn = FlowDocumentBuilder.Build(tree, wrapCodeBlocks: true);
        var wrapOff = FlowDocumentBuilder.Build(tree, wrapCodeBlocks: false);

        var codeOn = wrapOn.Single(b => b.IsCodeBlock);
        var codeOff = wrapOff.Single(b => b.IsCodeBlock);

        Assert.True(codeOn.WrapCode);
        Assert.False(codeOff.WrapCode);

        // The document's own bytes stay literal regardless of wrap intent — a Copy chip, plain
        // selection copy, find, --extract and pdftotext all read this same text.
        var textOn = string.Concat(codeOn.Runs.Select(r => r.Text));
        var textOff = string.Concat(codeOff.Runs.Select(r => r.Text));
        Assert.Equal(textOn, textOff);
        Assert.Equal("fn main() { let x = 1 + 2; }", textOn);
        Assert.Contains(' ', textOff); // ordinary ASCII space, never substituted

        // Scoped to the code block ONLY — a non-code block's WrapCode is untouched by the flag
        // (its default stays true, since nothing here ever reads it for a non-code block).
        var paragraph = wrapOff.First(b => !b.IsCodeBlock && b.Runs.Count > 0 && b.Runs[0].Text.Contains("hello"));
        Assert.True(paragraph.WrapCode);
    }

    [Fact]
    public void Wrap_false_does_not_change_which_role_colours_the_highlighter_applied()
    {
        var codeData = JsonDocument.Parse("""
        {
          "language": "rust",
          "fenced": true,
          "text": "fn main",
          "runs": [ {"start": 0, "end": 2, "role": "keyword"} ]
        }
        """).RootElement.Clone();
        var tree = new RenderTree
        {
            SchemaVersion = 1,
            Document = new RenderDocument { RootNodeId = 0, DefaultBodyFontSize = 12 },
            Nodes = new List<RenderNode>
            {
                new() { Id = 0, Type = "document", Children = new List<ulong> { 1 }, Data = JsonDocument.Parse("{}").RootElement.Clone() },
                new() { Id = 1, Type = "codeBlock", Children = new List<ulong>(), Data = codeData },
            },
        };

        var wrapOn = FlowDocumentBuilder.Build(tree, wrapCodeBlocks: true).Single().Runs;
        var wrapOff = FlowDocumentBuilder.Build(tree, wrapCodeBlocks: false).Single().Runs;

        Assert.Equal(wrapOn.Count, wrapOff.Count);
        for (var i = 0; i < wrapOn.Count; i++)
        {
            Assert.Equal(wrapOn[i].Text, wrapOff[i].Text);
            Assert.Equal(wrapOn[i].Foreground, wrapOff[i].Foreground);
        }
    }
}
