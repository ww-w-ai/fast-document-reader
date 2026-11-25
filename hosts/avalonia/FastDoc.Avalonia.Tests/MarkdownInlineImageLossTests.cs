using System.Linq;
using System.Text.Json;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Paging;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S12-img regression tests: a markdown `![alt](src)` parses as an "image" NODE inside its
/// containing paragraph/listItem/taskListItem's own children
/// (rust/crates/fastdoc-engine/src/render/markdown/blocks.rs's `map_inline_children` ->
/// inline.rs's `build_image`) — never as a standalone top-level "image" block the way an anchored
/// docx/hwp/odt picture is. <see cref="FlowDocumentBuilder"/>'s "paragraph"/"listItem"/
/// "taskListItem" cases used to call <c>CollectRuns</c>, which recognizes only "textRun" and
/// "lineBreak" children — so every markdown image was silently dropped: the paragraph became an
/// empty <see cref="FlowBlockKind.Text"/> block and the picture's resource never reached
/// <see cref="ImageBlockRenderer"/> (100% content loss, no crash, no diagnostic — QA-reported
/// against demo/images.md, all 12 images; docs/studio/sprints/S12/s12-markdown-image-loss.md).
///
/// Fixtures mirror the ACTUAL wire shape a real markdown parse produces (an "image" child of a
/// "paragraph"/"listItem"/"taskListItem" node), not the office shape (a standalone top-level
/// "image" node already covered by other tests) — this is the shape this bug lived in.
/// </summary>
public class MarkdownInlineImageLossTests
{
    private static RenderTree Parse(string json) =>
        JsonSerializer.Deserialize<RenderTreeEnvelope>(json)!.Ok!.Value.Deserialize<RenderTree>()!;

    // A paragraph whose ONLY child is an image — demo/images.md's exact shape
    // (`![alt](assets/x.jpg)` alone on its own line, CommonMark's normal parse for that).
    private const string ImageOnlyParagraphDoc = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": { "format": "markdown", "rootNodeId": 0 },
        "resources": [
          { "id": 1, "mimeType": "text/uri-list", "bytesBase64": "YXNzZXRzL3doYWxlLmpwZw==" }
        ],
        "nodes": [
          { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
          { "id": 1, "parentId": 0, "children": [2], "type": "flow", "data": {} },
          { "id": 2, "parentId": 1, "children": [3], "type": "paragraph", "data": { "style": {} } },
          { "id": 3, "parentId": 2, "children": [], "type": "image",
            "data": { "resourceId": 1, "intrinsicSize": { "width": 0, "height": 0 }, "altText": "a whale" } }
        ]
      }
    }
    """;

    // A paragraph mixing text BEFORE and AFTER the image — "See this ![img](x) whale" shape.
    private const string TextImageTextParagraphDoc = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": { "format": "markdown", "rootNodeId": 0 },
        "resources": [
          { "id": 1, "mimeType": "text/uri-list", "bytesBase64": "eC5qcGc=" }
        ],
        "nodes": [
          { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
          { "id": 1, "parentId": 0, "children": [2], "type": "flow", "data": {} },
          { "id": 2, "parentId": 1, "children": [3, 4, 5], "type": "paragraph", "data": { "style": {} } },
          { "id": 3, "parentId": 2, "children": [], "type": "textRun", "data": { "text": "See this ", "style": {} } },
          { "id": 4, "parentId": 2, "children": [], "type": "image",
            "data": { "resourceId": 1, "intrinsicSize": { "width": 0, "height": 0 } } },
          { "id": 5, "parentId": 2, "children": [], "type": "textRun", "data": { "text": " whale", "style": {} } }
        ]
      }
    }
    """;

    // A tight list item whose only content is an image — comrak hoists the image directly into
    // the listItem's own children for a tight list (blocks.rs's `map_item_child`).
    private const string ImageOnlyListItemDoc = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": { "format": "markdown", "rootNodeId": 0 },
        "resources": [
          { "id": 1, "mimeType": "text/uri-list", "bytesBase64": "eS5qcGc=" }
        ],
        "nodes": [
          { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
          { "id": 1, "parentId": 0, "children": [2], "type": "flow", "data": {} },
          { "id": 2, "parentId": 1, "children": [3], "type": "list", "data": {} },
          { "id": 3, "parentId": 2, "children": [4], "type": "listItem",
            "data": { "level": 0, "ordered": false, "style": {} } },
          { "id": 4, "parentId": 3, "children": [], "type": "image",
            "data": { "resourceId": 1, "intrinsicSize": { "width": 0, "height": 0 } } }
        ]
      }
    }
    """;

    // A paragraph with NO image at all — pins that the non-image path is byte-for-byte unchanged.
    private const string PlainParagraphDoc = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": { "format": "markdown", "rootNodeId": 0 },
        "nodes": [
          { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
          { "id": 1, "parentId": 0, "children": [2], "type": "flow", "data": {} },
          { "id": 2, "parentId": 1, "children": [3], "type": "paragraph", "data": { "style": {} } },
          { "id": 3, "parentId": 2, "children": [], "type": "textRun", "data": { "text": "just text", "style": {} } }
        ]
      }
    }
    """;

    [Fact]
    public void An_image_only_paragraph_produces_an_image_block_not_an_empty_text_block()
    {
        var tree = Parse(ImageOnlyParagraphDoc);
        var blocks = FlowDocumentBuilder.Build(tree);

        Assert.Single(blocks);
        Assert.Equal(FlowBlockKind.Image, blocks[0].Kind);
        Assert.Equal(1UL, blocks[0].ImageResourceId);
        // NodeId is the IMAGE node's own id (3), not the paragraph's (2) — the resource this block
        // draws is owned by the image node, matching the top-level "image" case's own convention.
        Assert.Equal(3UL, blocks[0].NodeId);
    }

    [Fact]
    public void Text_before_and_after_an_inline_image_survives_as_separate_blocks_around_it()
    {
        var tree = Parse(TextImageTextParagraphDoc);
        var blocks = FlowDocumentBuilder.Build(tree);

        Assert.Equal(3, blocks.Count);
        Assert.Equal(FlowBlockKind.Text, blocks[0].Kind);
        Assert.Equal("See this ", string.Concat(blocks[0].Runs.Select(r => r.Text)));
        Assert.Equal(FlowBlockKind.Image, blocks[1].Kind);
        Assert.Equal(1UL, blocks[1].ImageResourceId);
        Assert.Equal(FlowBlockKind.Text, blocks[2].Kind);
        Assert.Equal(" whale", string.Concat(blocks[2].Runs.Select(r => r.Text)));
    }

    [Fact]
    public void An_image_only_tight_list_item_still_shows_its_bullet_ahead_of_the_image()
    {
        var tree = Parse(ImageOnlyListItemDoc);
        var blocks = FlowDocumentBuilder.Build(tree);

        Assert.Equal(2, blocks.Count);
        Assert.Equal(FlowBlockKind.Text, blocks[0].Kind);
        Assert.Contains("•", string.Concat(blocks[0].Runs.Select(r => r.Text)));
        Assert.Equal(FlowBlockKind.Image, blocks[1].Kind);
        Assert.Equal(1UL, blocks[1].ImageResourceId);
    }

    [Fact]
    public void A_paragraph_with_no_image_still_produces_exactly_one_text_block()
    {
        var tree = Parse(PlainParagraphDoc);
        var blocks = FlowDocumentBuilder.Build(tree);

        Assert.Single(blocks);
        Assert.Equal(FlowBlockKind.Text, blocks[0].Kind);
        Assert.Equal("just text", string.Concat(blocks[0].Runs.Select(r => r.Text)));
    }

    [Fact]
    public void Page_mode_markers_stay_positionally_aligned_with_the_split_flow_blocks()
    {
        var tree = Parse(TextImageTextParagraphDoc);
        var blocks = FlowDocumentBuilder.Build(tree);
        var markers = BlockPageMarkers.Compute(tree);

        Assert.Equal(blocks.Count, markers.NodeId.Length);
        for (var i = 0; i < blocks.Count; i++)
        {
            Assert.Equal(blocks[i].NodeId, markers.NodeId[i]);
        }
    }

    // A formula and a diagram, each its own block, then a paragraph that starts a page — the shape
    // of an HWP equation between paragraphs (1790387_prep_final_report.hwpx: 12 formulas shifted
    // every later page break one block early and cost 14 pages).
    private const string FormulaThenBreakDoc = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": { "format": "hwpx", "rootNodeId": 0 },
        "nodes": [
          { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
          { "id": 1, "parentId": 0, "children": [2, 3, 4, 5], "type": "flow", "data": {} },
          { "id": 2, "parentId": 1, "children": [], "type": "formula", "data": { "block": false, "source": "N_{k}" } },
          { "id": 3, "parentId": 1, "children": [], "type": "diagram", "data": { "language": "other", "source": "a" } },
          { "id": 4, "parentId": 1, "children": [6], "type": "paragraph", "data": { "style": {}, "pagination": { "pageBreakBefore": true } } },
          { "id": 6, "parentId": 4, "children": [], "type": "textRun", "data": { "text": "starts a page", "style": {} } },
          { "id": 5, "parentId": 1, "children": [7], "type": "paragraph", "data": { "style": {} } },
          { "id": 7, "parentId": 5, "children": [], "type": "textRun", "data": { "text": "after", "style": {} } }
        ]
      }
    }
    """;

    [Fact]
    public void A_formula_or_diagram_block_keeps_the_page_break_on_the_paragraph_that_declares_it()
    {
        var tree = Parse(FormulaThenBreakDoc);
        var blocks = FlowDocumentBuilder.Build(tree);
        var markers = BlockPageMarkers.Compute(tree);

        Assert.Equal(blocks.Count, markers.NodeId.Length);
        for (var i = 0; i < blocks.Count; i++)
        {
            Assert.Equal(blocks[i].NodeId, markers.NodeId[i]);
        }
        var broken = Enumerable.Range(0, blocks.Count).Where(i => markers.PageBreakBefore[i]).ToArray();
        Assert.Equal(new ulong?[] { 4 }, broken.Select(i => blocks[i].NodeId).ToArray());
    }

    [Fact]
    public void Page_mode_markers_stay_aligned_for_an_image_only_list_item_too()
    {
        var tree = Parse(ImageOnlyListItemDoc);
        var blocks = FlowDocumentBuilder.Build(tree);
        var markers = BlockPageMarkers.Compute(tree);

        Assert.Equal(blocks.Count, markers.NodeId.Length);
        for (var i = 0; i < blocks.Count; i++)
        {
            Assert.Equal(blocks[i].NodeId, markers.NodeId[i]);
        }
    }
}
