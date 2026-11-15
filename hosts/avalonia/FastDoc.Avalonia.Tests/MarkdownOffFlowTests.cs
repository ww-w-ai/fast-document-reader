using System.Text.Json;
using FastDoc.Avalonia.Extract;
using FastDoc.Avalonia.Model;

namespace FastDoc.Avalonia.Tests;

public class MarkdownOffFlowTests
{
    [Fact]
    public void Emits_payload_linked_content_and_annotations_without_deduplicating_equal_text()
    {
        var tree = JsonSerializer.Deserialize<RenderTree>("""
        {
          "document":{"format":"hwp","rootNodeId":0},
          "nodes":[
            {"id":0,"type":"document","children":[1,5,8],"data":{}},
            {"id":1,"type":"header","children":[2],"data":{}},
            {"id":2,"type":"paragraph","children":[3],"data":{}},
            {"id":3,"type":"textRun","children":[],"data":{"text":"header-sentinel","style":{}}},
            {"id":5,"type":"anchoredObject","children":[],"data":{"contentId":6}},
            {"id":6,"type":"paragraph","children":[7],"data":{}},
            {"id":7,"type":"textRun","children":[],"data":{"text":"same-sentinel","style":{}}},
            {"id":8,"type":"masterPage","children":[],"data":{"objectIds":[9]}},
            {"id":9,"type":"masterPageObject","children":[],"data":{"contentId":10}},
            {"id":10,"type":"paragraph","children":[11],"data":{}},
            {"id":11,"type":"textRun","children":[],"data":{"text":"same-sentinel","style":{}}},
            {"id":12,"type":"footer","children":[13],"data":{}},
            {"id":13,"type":"paragraph","children":[14],"data":{}},
            {"id":14,"type":"textRun","children":[],"data":{"text":"footer-sentinel","style":{}}},
            {"id":15,"type":"formControl","children":[],"data":{"kind":"button","caption":"caption-sentinel","text":"value-sentinel","value":1}},
            {"id":16,"type":"unsupported","children":[],"data":{"reason":"object","preservedText":"preserved-sentinel"}}
          ],
          "annotations":{"comments":[{"id":1,"number":1,"author":"Author","text":"comment-sentinel"}]}
        }
        """)!;
        tree.Nodes[0].Children.Add(16);
        var text = MarkdownSerializer.Serialize(tree);
        foreach (var sentinel in new[] { "header-sentinel", "footer-sentinel", "caption-sentinel", "value-sentinel", "preserved-sentinel", "comment-sentinel" })
            Assert.Contains(sentinel, text);
        Assert.Equal(2, text.Split("same-sentinel").Length - 1);
    }

    [Fact]
    public void Inline_and_table_preserved_text_survives()
    {
        var tree = JsonSerializer.Deserialize<RenderTree>("""
        {"document":{"format":"docx","rootNodeId":0},"nodes":[
          {"id":0,"type":"document","children":[1,4],"data":{}},
          {"id":1,"type":"paragraph","children":[2],"data":{}},
          {"id":2,"type":"unsupported","children":[],"data":{"reason":"field","preservedText":"inline-sentinel"}},
          {"id":4,"type":"table","children":[5],"data":{}},
          {"id":5,"type":"tableRow","children":[6],"data":{}},
          {"id":6,"type":"tableCell","children":[7],"data":{"rowSpan":1,"columnSpan":1}},
          {"id":7,"type":"paragraph","children":[8],"data":{}},
          {"id":8,"type":"unsupported","children":[],"data":{"reason":"field","preservedText":"table-sentinel"}}
        ]}
        """)!;
        var text = MarkdownSerializer.Serialize(tree);
        Assert.Contains("[field] inline-sentinel", text);
        Assert.Equal(1, text.Split("inline-sentinel").Length - 1);
        Assert.Contains("[field] table-sentinel", text);
        Assert.Equal(1, text.Split("table-sentinel").Length - 1);
    }

    [Fact]
    public void Large_body_keeps_last_paragraph()
    {
        var nodes = new System.Collections.Generic.List<RenderNode>();
        var root = new RenderNode { Id = 0, Type = "document" };
        nodes.Add(root);
        for (ulong i = 1; i <= 10000; i++)
        {
            var runId = i + 10000;
            root.Children.Add(i);
            nodes.Add(new RenderNode { Id = i, Type = "paragraph", Children = new() { runId }, Data = JsonSerializer.SerializeToElement(new { }) });
            nodes.Add(new RenderNode { Id = runId, Type = "textRun", Data = JsonSerializer.SerializeToElement(new { text = i == 10000 ? "last-sentinel" : "body", style = new { } }) });
        }
        var tree = new RenderTree { Document = new RenderDocument { RootNodeId = 0 }, Nodes = nodes };
        Assert.EndsWith("last-sentinel", MarkdownSerializer.Serialize(tree));
    }
}
