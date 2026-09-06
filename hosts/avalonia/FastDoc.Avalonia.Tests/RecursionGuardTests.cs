using System.Collections.Generic;
using System.Text.Json;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Paging;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// BlockPageMarkers.Walk (PageGeometry.cs) and HeaderFooterText.CollectText
/// (PageModePainter.cs) both walk a RenderTree by following child ids through a
/// Dictionary&lt;ulong, RenderNode&gt;. A normally-parsed document cannot contain a cycle, but an
/// engine parsing bug or a hand-crafted document that makes a node its own (or an ancestor's)
/// child would recurse until the process stack overflows, a crash no managed catch block can
/// intercept — both walks thread a HashSet&lt;ulong&gt; of nodes on the current root-to-here path,
/// cutting a cycle the instant it repeats an id already on that path.
///
/// A genuine cycle causing a real StackOverflowException would simply kill the test process, so
/// these tests prove the guard the only way that is possible: the call returns normally (this
/// method does not hang or crash) with the deterministic result a cut cycle produces (no blocks
/// counted past the self-referencing node; no text collected past it).
/// </summary>
public class RecursionGuardTests
{
    [Fact]
    public void BlockPageMarkers_Compute_does_not_stack_overflow_on_a_self_referencing_node()
    {
        const string treeJson = """
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "docx", "rootNodeId": 0, "defaultBodyFontSize": 12 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [1], "type": "list", "data": {} }
            ]
          }
        }
        """;
        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(treeJson)!;
        Assert.True(envelope.IsOk);
        var tree = envelope.Ok!.Value.Deserialize<RenderTree>()!;

        // Node 1 lists ITSELF as its only child, so without the visited-set guard Walk ->
        // WalkChildren -> Walk -> ... never terminates. Returning at all (regardless of the exact
        // marker counts) is the proof; the zero-blocks result below is what a cut-on-first-repeat
        // cycle produces (node 1 is visited exactly once, emits nothing itself since "list" only
        // walks children).
        var markers = BlockPageMarkers.Compute(tree);

        Assert.Empty(markers.SectionStart);
        Assert.Empty(markers.PageBreakBefore);
    }

    [Fact]
    public void HeaderFooterText_Extract_does_not_stack_overflow_on_a_self_referencing_header_node()
    {
        const string treeJson = """
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "docx", "rootNodeId": 0, "defaultBodyFontSize": 12 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [1], "type": "header", "data": {} }
            ]
          }
        }
        """;
        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(treeJson)!;
        Assert.True(envelope.IsOk);
        var tree = envelope.Ok!.Value.Deserialize<RenderTree>()!;

        // S8-A2: HeaderFooterText is now public (Resolve/CollectCandidates are called directly
        // from S8A2RenderFixesTests too), so this no longer needs reflection — the recursion guard
        // it exercises (CollectText's HashSet<ulong> visited-set) is unchanged.
        var byId = new Dictionary<ulong, RenderNode>();
        foreach (var node in tree.Nodes) { byId[node.Id] = node; }
        var candidates = HeaderFooterText.CollectCandidates(tree, "header");

        // Node 1 (a "header") lists ITSELF as its only child, so without the visited-set guard
        // CollectText -> CollectText -> ... never terminates. Returning null (no text ever
        // collected, since the self-referencing node has no textRun content) is what a
        // cut-on-first-repeat cycle produces; returning at all is the proof.
        var result = HeaderFooterText.Resolve(candidates, byId, sectionIndex: 0, isFirstPageOfSection: true,
            pageNumber: 1, totalPages: 1);

        Assert.Null(result);
    }
}
