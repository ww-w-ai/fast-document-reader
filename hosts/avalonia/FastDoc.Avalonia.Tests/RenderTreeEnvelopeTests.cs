using System.Linq;
using System.Text.Json;
using FastDoc.Avalonia.Model;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// Deserialization of the RenderTree wire envelope (Model/RenderTreeEnvelope.cs) against FIXED
/// JSON string fixtures — no FFI, no engine dylib. Proves the envelope is forward-compatible
/// (an unknown field does not break decode) and that RenderNode.Text reads only the "text" key
/// out of the untyped payload, per that file's own doc comment.
/// </summary>
public class RenderTreeEnvelopeTests
{
    private const string OkEnvelopeJson = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": { "format": "markdown", "rootNodeId": 0 },
        "nodes": [
          {
            "id": 0,
            "parentId": null,
            "children": [1],
            "type": "document",
            "data": {}
          },
          {
            "id": 1,
            "parentId": 0,
            "children": [],
            "type": "paragraph",
            "data": { "text": "hello world" }
          }
        ]
      }
    }
    """;

    private const string ErrorEnvelopeJson = """
    {
      "error": { "kind": "parseFailure", "message": "unexpected token", "location": "line 3" }
    }
    """;

    // A field this host does not model at all ("unknownTopLevelField") plus an extra key inside
    // a node's data payload ("futureField") — the doc comment on RenderTreeEnvelope promises both
    // are simply left unread, not a decode failure.
    private const string OkEnvelopeWithUnknownFieldsJson = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": { "format": "docx", "rootNodeId": 0 },
        "unknownTopLevelField": { "anything": true },
        "nodes": [
          {
            "id": 0,
            "parentId": null,
            "children": [],
            "type": "table",
            "data": { "rows": 3, "futureField": "not modelled yet" }
          }
        ]
      }
    }
    """;

    [Fact]
    public void OkEnvelope_decodes_schema_document_and_nodes()
    {
        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(OkEnvelopeJson)!;

        Assert.True(envelope.IsOk);
        Assert.Null(envelope.Error);

        var tree = envelope.Ok!.Value.Deserialize<RenderTree>()!;
        Assert.Equal(1u, tree.SchemaVersion);
        Assert.Equal("markdown", tree.Document!.Format);
        Assert.Equal(0ul, tree.Document.RootNodeId);
        Assert.Equal(2, tree.Nodes.Count);
    }

    [Fact]
    public void ErrorEnvelope_decodes_kind_message_and_location_and_IsOk_is_false()
    {
        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(ErrorEnvelopeJson)!;

        Assert.False(envelope.IsOk);
        Assert.NotNull(envelope.Error);
        Assert.Equal("parseFailure", envelope.Error!.Kind);
        Assert.Equal("unexpected token", envelope.Error.Message);
        Assert.Equal("line 3", envelope.Error.Location);
    }

    [Fact]
    public void Unknown_fields_at_top_level_and_inside_node_data_are_ignored_not_fatal()
    {
        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(OkEnvelopeWithUnknownFieldsJson)!;

        Assert.True(envelope.IsOk);
        var tree = envelope.Ok!.Value.Deserialize<RenderTree>()!;
        Assert.Equal("docx", tree.Document!.Format);
        Assert.Single(tree.Nodes);
        // The node's own "data" JsonElement is preserved raw (unread by this host) — the extra
        // "futureField" key inside it did not throw or get dropped from the underlying element.
        Assert.True(tree.Nodes[0].Data.TryGetProperty("futureField", out _));
    }

    [Fact]
    public void RenderNode_Text_reads_the_text_key_when_present_and_is_null_otherwise()
    {
        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(OkEnvelopeJson)!;
        var tree = envelope.Ok!.Value.Deserialize<RenderTree>()!;

        var documentNode = tree.Nodes.Single(n => n.Type == "document");
        var paragraphNode = tree.Nodes.Single(n => n.Type == "paragraph");

        Assert.Null(documentNode.Text); // data = {} has no "text" key
        Assert.Equal("hello world", paragraphNode.Text);
    }
}
