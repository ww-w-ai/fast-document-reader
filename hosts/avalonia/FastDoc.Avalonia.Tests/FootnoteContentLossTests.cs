using System.Linq;
using System.Text.Json;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Paging;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S12-A regression tests: a footnote's body used to be dropped entirely by both
/// <see cref="FlowDocumentBuilder"/> (flow mode) and <see cref="BlockPageMarkers"/> (page mode) —
/// the "footnote" case in each file's tree walk returned without recursing into the body flow
/// node named by <see cref="FootnotePayload.BodyFlowId"/>, and nothing else ever visited it.
///
/// Fixtures mirror <c>MarkdownSerializerTests.Footnote_reference_becomes_a_markdown_reference_and_
/// the_body_is_appended_at_the_end</c>'s wire shape exactly, so all three consumers of this tree
/// shape (Markdown extract, flow-mode draw, page-mode draw) are pinned against the SAME fixture.
/// </summary>
public class FootnoteContentLossTests
{
    private static RenderTree Parse(string json) =>
        JsonSerializer.Deserialize<RenderTreeEnvelope>(json)!.Ok!.Value.Deserialize<RenderTree>()!;

    private const string OneFootnoteDoc = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": { "format": "docx", "rootNodeId": 0 },
        "nodes": [
          { "id": 0, "parentId": null, "children": [1, 5], "type": "document", "data": {} },
          { "id": 1, "parentId": 0, "children": [2, 3], "type": "paragraph", "data": { "style": {} } },
          { "id": 2, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "See note", "style": {} } },
          { "id": 3, "parentId": 1, "children": [], "type": "textRun",
            "data": { "text": "1)", "style": {}, "footnoteReferenceNumber": 1 } },
          { "id": 5, "parentId": 0, "children": [6], "type": "footnote", "data": { "number": 1, "bodyFlowId": 6 } },
          { "id": 6, "parentId": 5, "children": [7], "type": "flow", "data": {} },
          { "id": 7, "parentId": 6, "children": [8], "type": "paragraph", "data": { "style": {} } },
          { "id": 8, "parentId": 7, "children": [], "type": "textRun", "data": { "text": "The note body.", "style": {} } }
        ]
      }
    }
    """;

    // ---- flow mode (FlowDocumentBuilder) ----

    [Fact]
    public void Flow_mode_no_longer_drops_the_footnote_body_text()
    {
        var blocks = FlowDocumentBuilder.Build(Parse(OneFootnoteDoc));

        var allText = string.Join(" ", blocks
            .Where(b => b.Kind == FlowBlockKind.Text)
            .SelectMany(b => b.Runs)
            .Select(r => r.Text));

        Assert.Contains("The note body.", allText);
    }

    [Fact]
    public void Flow_mode_labels_the_appended_body_with_its_citation_number()
    {
        var blocks = FlowDocumentBuilder.Build(Parse(OneFootnoteDoc));

        var allText = string.Join(" ", blocks
            .Where(b => b.Kind == FlowBlockKind.Text)
            .SelectMany(b => b.Runs)
            .Select(r => r.Text));

        Assert.Contains("[1]", allText);
    }

    [Fact]
    public void Flow_mode_still_renders_the_in_body_paragraph_referencing_the_note()
    {
        var blocks = FlowDocumentBuilder.Build(Parse(OneFootnoteDoc));

        var allText = string.Join(" ", blocks
            .Where(b => b.Kind == FlowBlockKind.Text)
            .SelectMany(b => b.Runs)
            .Select(r => r.Text));

        Assert.Contains("See note", allText);
    }

    [Fact]
    public void Multiple_footnotes_are_appended_in_citation_number_order_regardless_of_node_id_order()
    {
        // Footnote node 9 (number 2) is declared BEFORE node 5 (number 1) in the tree — the
        // append must still read note 1's body before note 2's, matching
        // MarkdownSerializer.AppendFootnotes's own "sorted by number" contract.
        var tree = Parse("""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "docx", "rootNodeId": 0 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1, 9, 5], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [2], "type": "paragraph", "data": { "style": {} } },
              { "id": 2, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "body", "style": {} } },
              { "id": 9, "parentId": 0, "children": [10], "type": "footnote", "data": { "number": 2, "bodyFlowId": 10 } },
              { "id": 10, "parentId": 9, "children": [11], "type": "flow", "data": {} },
              { "id": 11, "parentId": 10, "children": [12], "type": "paragraph", "data": { "style": {} } },
              { "id": 12, "parentId": 11, "children": [], "type": "textRun", "data": { "text": "second note", "style": {} } },
              { "id": 5, "parentId": 0, "children": [6], "type": "footnote", "data": { "number": 1, "bodyFlowId": 6 } },
              { "id": 6, "parentId": 5, "children": [7], "type": "flow", "data": {} },
              { "id": 7, "parentId": 6, "children": [8], "type": "paragraph", "data": { "style": {} } },
              { "id": 8, "parentId": 7, "children": [], "type": "textRun", "data": { "text": "first note", "style": {} } }
            ]
          }
        }
        """);

        var blocks = FlowDocumentBuilder.Build(tree);
        var allText = string.Join(" ", blocks
            .Where(b => b.Kind == FlowBlockKind.Text)
            .SelectMany(b => b.Runs)
            .Select(r => r.Text));

        Assert.Contains("first note", allText);
        Assert.Contains("second note", allText);
        Assert.True(allText.IndexOf("first note") < allText.IndexOf("second note"));
    }

    [Fact]
    public void A_footnote_whose_body_flow_id_does_not_resolve_still_contributes_its_label_without_crashing()
    {
        var tree = Parse("""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "docx", "rootNodeId": 0 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1, 5], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [], "type": "paragraph", "data": { "style": {} } },
              { "id": 5, "parentId": 0, "children": [], "type": "footnote", "data": { "number": 1, "bodyFlowId": 999 } }
            ]
          }
        }
        """);

        var blocks = FlowDocumentBuilder.Build(tree);

        var allText = string.Join(" ", blocks
            .Where(b => b.Kind == FlowBlockKind.Text)
            .SelectMany(b => b.Runs)
            .Select(r => r.Text));
        Assert.Contains("[1]", allText);
    }

    [Fact]
    public void No_footnotes_means_no_extra_blocks_appended()
    {
        var tree = Parse("""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "docx", "rootNodeId": 0 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [2], "type": "paragraph", "data": { "style": {} } },
              { "id": 2, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "plain", "style": {} } }
            ]
          }
        }
        """);

        var blocks = FlowDocumentBuilder.Build(tree);
        Assert.Single(blocks);
        Assert.DoesNotContain(blocks, b => b.Kind == FlowBlockKind.Rule);
    }

    // ---- page mode (BlockPageMarkers) — the index-alignment invariant ----

    [Fact]
    public void Page_mode_marker_count_stays_aligned_with_flow_mode_block_count_when_a_footnote_is_present()
    {
        var tree = Parse(OneFootnoteDoc);
        var blocks = FlowDocumentBuilder.Build(tree);
        var markers = BlockPageMarkers.Compute(tree);

        Assert.Equal(blocks.Count, markers.SectionStart.Length);
        Assert.Equal(blocks.Count, markers.PageBreakBefore.Length);
        Assert.Equal(blocks.Count, markers.TableKeepsWhole.Length);
        Assert.Equal(blocks.Count, markers.TableRepeatsHeader.Length);
    }

    [Fact]
    public void Page_mode_marker_count_stays_aligned_with_flow_mode_block_count_for_multiple_footnotes()
    {
        var tree = Parse("""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "docx", "rootNodeId": 0 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1, 9, 5], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [2], "type": "paragraph", "data": { "style": {} } },
              { "id": 2, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "body", "style": {} } },
              { "id": 9, "parentId": 0, "children": [10], "type": "footnote", "data": { "number": 2, "bodyFlowId": 10 } },
              { "id": 10, "parentId": 9, "children": [11], "type": "flow", "data": {} },
              { "id": 11, "parentId": 10, "children": [12], "type": "paragraph", "data": { "style": {} } },
              { "id": 12, "parentId": 11, "children": [], "type": "textRun", "data": { "text": "second note", "style": {} } },
              { "id": 5, "parentId": 0, "children": [6], "type": "footnote", "data": { "number": 1, "bodyFlowId": 6 } },
              { "id": 6, "parentId": 5, "children": [7], "type": "flow", "data": {} },
              { "id": 7, "parentId": 6, "children": [8], "type": "paragraph", "data": { "style": {} } },
              { "id": 8, "parentId": 7, "children": [], "type": "textRun", "data": { "text": "first note", "style": {} } }
            ]
          }
        }
        """);

        var blocks = FlowDocumentBuilder.Build(tree);
        var markers = BlockPageMarkers.Compute(tree);

        Assert.Equal(blocks.Count, markers.SectionStart.Length);
    }

    [Fact]
    public void Page_mode_markers_correspond_positionally_not_just_by_count_for_out_of_order_footnotes()
    {
        // Guards against the drift a pure length check cannot see: a mutation that reverses ONLY
        // BlockPageMarkers.CollectFootnotes's sort comparator (number ascending -> descending)
        // keeps every array the same LENGTH — footnote 2's body still contributes exactly as many
        // markers as footnote 1's did — so a test that only compares .Length passes it. This test
        // requires >= 2 footnotes declared out of citation order (a single footnote, or an empty
        // list, would make a positional check vacuously true regardless of sort direction) and
        // asserts each marker's NodeId equals the FlowBlock at the SAME index's NodeId.
        var tree = Parse("""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "docx", "rootNodeId": 0 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1, 9, 5], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [2], "type": "paragraph", "data": { "style": {} } },
              { "id": 2, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "body", "style": {} } },
              { "id": 9, "parentId": 0, "children": [10], "type": "footnote", "data": { "number": 2, "bodyFlowId": 10 } },
              { "id": 10, "parentId": 9, "children": [11], "type": "flow", "data": {} },
              { "id": 11, "parentId": 10, "children": [12], "type": "paragraph", "data": { "style": {} } },
              { "id": 12, "parentId": 11, "children": [], "type": "textRun", "data": { "text": "second note", "style": {} } },
              { "id": 5, "parentId": 0, "children": [6], "type": "footnote", "data": { "number": 1, "bodyFlowId": 6 } },
              { "id": 6, "parentId": 5, "children": [7], "type": "flow", "data": {} },
              { "id": 7, "parentId": 6, "children": [8], "type": "paragraph", "data": { "style": {} } },
              { "id": 8, "parentId": 7, "children": [], "type": "textRun", "data": { "text": "first note", "style": {} } }
            ]
          }
        }
        """);

        var blocks = FlowDocumentBuilder.Build(tree);
        var markers = BlockPageMarkers.Compute(tree);

        // Pin the precondition the comment above depends on: >= 2 footnotes, declared out of
        // citation-number order in the tree (node id 9/number 2 appears before node id 5/number 1).
        var footnoteNodes = tree.Nodes.Where(n => n.AsFootnote is not null).ToList();
        Assert.True(footnoteNodes.Count >= 2, "fixture must declare at least two footnotes");
        Assert.True(footnoteNodes[0].AsFootnote!.Number > footnoteNodes[1].AsFootnote!.Number,
            "fixture must declare footnotes out of citation-number order");

        Assert.Equal(blocks.Count, markers.NodeId.Length);
        for (var i = 0; i < blocks.Count; i++)
        {
            Assert.NotNull(blocks[i].NodeId);
            Assert.Equal(blocks[i].NodeId!.Value, markers.NodeId[i]);
        }

        // And confirm the ordering itself is the one under test: the label block for note 1
        // ("[1]") precedes the label block for note 2 ("[2]") in BOTH lists at the same index,
        // not merely somewhere in the output.
        var label1BlockIndex = blocks.FindIndex(b => b.Kind == FlowBlockKind.Text && b.Runs.Any(r => r.Text == "[1]"));
        var label2BlockIndex = blocks.FindIndex(b => b.Kind == FlowBlockKind.Text && b.Runs.Any(r => r.Text == "[2]"));
        Assert.True(label1BlockIndex >= 0 && label2BlockIndex >= 0);
        Assert.True(label1BlockIndex < label2BlockIndex);
        Assert.Equal(blocks[label1BlockIndex].NodeId, markers.NodeId[label1BlockIndex]);
        Assert.Equal(blocks[label2BlockIndex].NodeId, markers.NodeId[label2BlockIndex]);
    }

    [Fact]
    public void Page_mode_marker_count_stays_aligned_when_a_footnote_body_contains_a_table()
    {
        // A footnote body is not always a single paragraph — E2b tables can live inside one too.
        // FlowDocumentBuilder.BuildTable emits exactly ONE block for the whole table (rows/cells
        // are folded into the block's own Table model, never appended to the top-level list);
        // BlockPageMarkers.WalkChildren must emit exactly one marker for it as well, or this test
        // catches the drift before a real document does.
        var tree = Parse("""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "docx", "rootNodeId": 0 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1, 5], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [2], "type": "paragraph", "data": { "style": {} } },
              { "id": 2, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "body", "style": {} } },
              { "id": 5, "parentId": 0, "children": [6], "type": "footnote", "data": { "number": 1, "bodyFlowId": 6 } },
              { "id": 6, "parentId": 5, "children": [7], "type": "flow", "data": {} },
              { "id": 7, "parentId": 6, "children": [10], "type": "table",
                "data": { "gridWidths": [1], "style": {} } },
              { "id": 10, "parentId": 7, "children": [11], "type": "tableRow", "data": { "row": 0, "header": false } },
              { "id": 11, "parentId": 10, "children": [12], "type": "tableCell", "data": { "row": 0, "column": 0 } },
              { "id": 12, "parentId": 11, "children": [13], "type": "paragraph", "data": { "style": {} } },
              { "id": 13, "parentId": 12, "children": [], "type": "textRun", "data": { "text": "cell text", "style": {} } }
            ]
          }
        }
        """);

        var blocks = FlowDocumentBuilder.Build(tree);
        var markers = BlockPageMarkers.Compute(tree);

        Assert.Equal(blocks.Count, markers.SectionStart.Length);
        Assert.Contains(blocks, b => b.Kind == FlowBlockKind.Table);
    }
}
