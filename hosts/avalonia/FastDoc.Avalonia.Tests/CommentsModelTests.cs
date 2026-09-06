using System.Text.Json;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Panels;

namespace FastDoc.Avalonia.Tests;

/// <summary>S8-B2 ④: CommentsModel.Build against fixed RenderTree JSON fixtures carrying
/// `annotations.comments` (Model/RenderTreeEnvelope.cs's AnnotationsWire, added in this sprint).</summary>
public class CommentsModelTests
{
    private static RenderTree Tree(string json) => JsonSerializer.Deserialize<RenderTree>(json)!;

    [Fact]
    public void Comments_are_ordered_by_their_document_display_number_not_by_id()
    {
        var tree = Tree("""
        {
          "schemaVersion": 1,
          "document": { "format": "docx", "rootNodeId": 0 },
          "nodes": [ { "id": 0, "parentId": null, "children": [], "type": "document", "data": {} } ],
          "annotations": {
            "comments": [
              { "id": 5, "sourceId": "c2", "author": "Bob", "text": "second", "dateIso": "2026-01-02", "number": 2 },
              { "id": 3, "sourceId": "c1", "author": "Alice", "text": "first", "dateIso": "2026-01-01", "number": 1 }
            ]
          }
        }
        """);

        var comments = CommentsModel.Build(tree);

        Assert.Equal(2, comments.Count);
        Assert.Equal(1, comments[0].Number);
        Assert.Equal("Alice", comments[0].Author);
        Assert.Equal(2, comments[1].Number);
        Assert.Equal("Bob", comments[1].Author);
    }

    [Fact]
    public void A_tree_with_no_annotations_key_returns_an_empty_list()
    {
        var tree = Tree("""
        {
          "schemaVersion": 1,
          "document": { "format": "markdown", "rootNodeId": 0 },
          "nodes": [ { "id": 0, "parentId": null, "children": [], "type": "document", "data": {} } ]
        }
        """);

        Assert.Empty(CommentsModel.Build(tree));
    }

    [Fact]
    public void A_tree_with_an_empty_comments_array_returns_an_empty_list()
    {
        var tree = Tree("""
        {
          "schemaVersion": 1,
          "document": { "format": "odt", "rootNodeId": 0 },
          "nodes": [ { "id": 0, "parentId": null, "children": [], "type": "document", "data": {} } ],
          "annotations": { "comments": [], "bookmarks": [] }
        }
        """);

        Assert.Empty(CommentsModel.Build(tree));
    }
}
