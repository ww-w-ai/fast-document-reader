using System.Text.Json;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Panels;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S8-B2 ③ / S8-B4 ①: TableOfContentsModel.Build against fixed RenderTree JSON fixtures — no
/// engine, no FlowDocumentBuilder. Since S8-B4, each entry carries the heading NODE's own id
/// (`RenderNode.Id`) rather than a re-derived flow-block index, so these assertions check that id
/// directly against the fixture's own node ids.
/// </summary>
public class TableOfContentsModelTests
{
    private static RenderTree Tree(string json) => JsonSerializer.Deserialize<RenderTree>(json)!;

    [Fact]
    public void Two_headings_with_a_paragraph_between_them_carry_their_own_node_ids()
    {
        // document(0) -> heading(1, level 1, "Intro") -> paragraph(2, "body text")
        //             -> heading(3, level 2, "Details")
        var tree = Tree("""
        {
          "schemaVersion": 1,
          "document": { "format": "markdown", "rootNodeId": 0 },
          "nodes": [
            { "id": 0, "parentId": null, "children": [1, 2, 3], "type": "document", "data": {} },
            { "id": 1, "parentId": 0, "children": [10], "type": "heading", "data": { "level": 1 } },
            { "id": 10, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "Intro" } },
            { "id": 2, "parentId": 0, "children": [], "type": "paragraph", "data": { "text": "body text" } },
            { "id": 3, "parentId": 0, "children": [11], "type": "heading", "data": { "level": 2 } },
            { "id": 11, "parentId": 3, "children": [], "type": "textRun", "data": { "text": "Details" } }
          ]
        }
        """);

        var entries = TableOfContentsModel.Build(tree);

        Assert.Equal(2, entries.Count);
        Assert.Equal(new TocEntry(1, "Intro", 1UL), entries[0]);
        Assert.Equal(new TocEntry(2, "Details", 3UL), entries[1]);
    }

    [Fact]
    public void A_section_wrapper_is_transparent_and_does_not_consume_a_block_index()
    {
        // document(0) -> section(1) -> heading(2)
        var tree = Tree("""
        {
          "schemaVersion": 1,
          "document": { "format": "docx", "rootNodeId": 0 },
          "nodes": [
            { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
            { "id": 1, "parentId": 0, "children": [2], "type": "section", "data": {} },
            { "id": 2, "parentId": 1, "children": [], "type": "heading", "data": { "level": 1, "text": "Only heading" } }
          ]
        }
        """);

        var entries = TableOfContentsModel.Build(tree);

        Assert.Single(entries);
        Assert.Equal(2UL, entries[0].NodeId);
    }

    [Fact]
    public void A_heading_with_no_text_produces_no_entry()
    {
        var tree = Tree("""
        {
          "schemaVersion": 1,
          "document": { "format": "markdown", "rootNodeId": 0 },
          "nodes": [
            { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
            { "id": 1, "parentId": 0, "children": [], "type": "heading", "data": { "level": 1, "text": "" } }
          ]
        }
        """);

        Assert.Empty(TableOfContentsModel.Build(tree));
    }

    [Fact]
    public void A_document_with_no_headings_returns_an_empty_list()
    {
        var tree = Tree("""
        {
          "schemaVersion": 1,
          "document": { "format": "markdown", "rootNodeId": 0 },
          "nodes": [
            { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
            { "id": 1, "parentId": 0, "children": [], "type": "paragraph", "data": { "text": "no headings here" } }
          ]
        }
        """);

        Assert.Empty(TableOfContentsModel.Build(tree));
    }
}
