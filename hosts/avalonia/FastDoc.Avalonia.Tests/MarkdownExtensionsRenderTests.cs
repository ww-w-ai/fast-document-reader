using System.Linq;
using System.Text.Json;
using Avalonia.Media;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Paging;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// The markdown dialect the canonical producer carries beyond CommonMark+GFM (underline, highlight,
/// super/subscript, alerts, notes, blocks inside list items, ordered start numbers) must reach what
/// the flow view and the page painter draw. Fixtures are the wire shape
/// `render::markdown::produce` emits (see rust/crates/fastdoc-engine/tests/markdown_canonical_extensions.rs).
/// </summary>
public class MarkdownExtensionsRenderTests
{
    private static RenderTree Parse(string nodesJson, string bookmarksJson = "[]") =>
        JsonSerializer.Deserialize<RenderTreeEnvelope>(
            "{ \"ok\": { \"schemaVersion\": 1, \"document\": { \"format\": \"markdown\", \"rootNodeId\": 1 }, " +
            "\"annotations\": { \"bookmarks\": " + bookmarksJson + " }, \"nodes\": [" + nodesJson + "] } }")!
            .Ok!.Value.Deserialize<RenderTree>()!;

    private static string Run(int id, int parent, string text, string style = "{}", string extra = "") =>
        "{ \"id\": " + id + ", \"parentId\": " + parent + ", \"children\": [], \"type\": \"textRun\", " +
        "\"data\": { \"text\": \"" + text + "\", \"style\": " + style + extra + " } }";

    private static string Node(int id, int? parent, string children, string type, string data = "{}") =>
        "{ \"id\": " + id + ", \"parentId\": " + (parent?.ToString() ?? "null") + ", \"children\": [" + children +
        "], \"type\": \"" + type + "\", \"data\": " + data + " }";

    private static FlowRun RunNamed(System.Collections.Generic.IEnumerable<FlowBlock> blocks, string text) =>
        blocks.SelectMany(b => b.Runs).First(r => r.Text.Contains(text));

    [Fact]
    public void Underline_highlight_script_and_code_styles_reach_the_runs()
    {
        var tree = Parse(string.Join(",",
            Node(1, null, "2", "document"),
            Node(2, 1, "3,4,5,6,7", "paragraph", "{ \"style\": {} }"),
            Run(3, 2, "under", "{ \"underline\": \"single\" }"),
            Run(4, 2, "hot", "{ \"background\": { \"red\": 1, \"green\": 0.85, \"blue\": 0.2, \"alpha\": 0.4 } }"),
            Run(5, 2, "sup", "{ \"verticalPosition\": \"superscript\" }"),
            Run(6, 2, "sub", "{ \"verticalPosition\": \"subscript\" }"),
            Run(7, 2, "kbd", "{ \"inlineCode\": true }")));
        var blocks = FlowDocumentBuilder.Build(tree);

        Assert.True(RunNamed(blocks, "under").Underline);
        Assert.NotNull(RunNamed(blocks, "hot").Background);
        Assert.Null(RunNamed(blocks, "under").Background);
        var sup = RunNamed(blocks, "sup");
        Assert.Equal(1, sup.Script);
        Assert.True(sup.FontSizePoints < 12 * 0.8, $"script text is smaller, was {sup.FontSizePoints}");
        Assert.Equal(-1, RunNamed(blocks, "sub").Script);
        Assert.Equal(0, RunNamed(blocks, "under").Script);
        Assert.Equal(FlowDocumentBuilder.CodeFontFamily, RunNamed(blocks, "kbd").FontFamily);
    }

    [Fact]
    public void An_ordered_list_numbers_its_items_from_its_start()
    {
        var tree = Parse(string.Join(",",
            Node(1, null, "2", "document"),
            Node(2, 1, "3,5", "list", "{ \"numbering\": { \"glyphs\": \"decimal\", \"startNumber\": 3 } }"),
            Node(3, 2, "4", "listItem", "{ \"level\": 1, \"ordered\": true, \"style\": {} }"),
            Run(4, 3, "three"),
            Node(5, 2, "6", "listItem", "{ \"level\": 1, \"ordered\": true, \"style\": {} }"),
            Run(6, 5, "four")));
        var texts = FlowDocumentBuilder.Build(tree).Select(b => string.Concat(b.Runs.Select(r => r.Text))).ToList();
        Assert.Equal(new[] { "3. three", "4. four" }, texts);
    }

    private const string ItemWithBlocks =
        // list > item( text, codeBlock, quote(text), nested list > item(text) ) and a loose item
        // with two paragraphs.
        "{ \"id\": 1, \"parentId\": null, \"children\": [2], \"type\": \"document\", \"data\": {} }," +
        "{ \"id\": 2, \"parentId\": 1, \"children\": [3, 20], \"type\": \"list\", \"data\": { \"numbering\": { \"glyphs\": \"decimal\" } } }," +
        "{ \"id\": 3, \"parentId\": 2, \"children\": [4, 5, 6, 8], \"type\": \"listItem\", \"data\": { \"level\": 1, \"ordered\": false, \"style\": {} } }," +
        "{ \"id\": 4, \"parentId\": 3, \"children\": [], \"type\": \"textRun\", \"data\": { \"text\": \"item\", \"style\": {} } }," +
        "{ \"id\": 5, \"parentId\": 3, \"children\": [], \"type\": \"codeBlock\", \"data\": { \"fenced\": true, \"text\": \"code line\" } }," +
        "{ \"id\": 6, \"parentId\": 3, \"children\": [11], \"type\": \"blockQuote\", \"data\": {} }," +
        "{ \"id\": 11, \"parentId\": 6, \"children\": [7], \"type\": \"paragraph\", \"data\": { \"style\": {} } }," +
        "{ \"id\": 7, \"parentId\": 11, \"children\": [], \"type\": \"textRun\", \"data\": { \"text\": \"quoted\", \"style\": {} } }," +
        "{ \"id\": 8, \"parentId\": 3, \"children\": [9], \"type\": \"list\", \"data\": { \"numbering\": { \"glyphs\": \"decimal\" } } }," +
        "{ \"id\": 9, \"parentId\": 8, \"children\": [10], \"type\": \"listItem\", \"data\": { \"level\": 2, \"ordered\": false, \"style\": {} } }," +
        "{ \"id\": 10, \"parentId\": 9, \"children\": [], \"type\": \"textRun\", \"data\": { \"text\": \"nested\", \"style\": {} } }," +
        "{ \"id\": 20, \"parentId\": 2, \"children\": [21, 23], \"type\": \"listItem\", \"data\": { \"level\": 1, \"ordered\": false, \"style\": {} } }," +
        "{ \"id\": 21, \"parentId\": 20, \"children\": [22], \"type\": \"paragraph\", \"data\": { \"style\": {} } }," +
        "{ \"id\": 22, \"parentId\": 21, \"children\": [], \"type\": \"textRun\", \"data\": { \"text\": \"loose one\", \"style\": {} } }," +
        "{ \"id\": 23, \"parentId\": 20, \"children\": [24], \"type\": \"paragraph\", \"data\": { \"style\": {} } }," +
        "{ \"id\": 24, \"parentId\": 23, \"children\": [], \"type\": \"textRun\", \"data\": { \"text\": \"loose two\", \"style\": {} } }";

    [Fact]
    public void A_list_item_keeps_its_blocks_in_order_under_its_marker_line()
    {
        var blocks = FlowDocumentBuilder.Build(Parse(ItemWithBlocks));
        var shape = blocks.Select(b => b.IsCodeBlock ? "code" : string.Concat(b.Runs.Select(r => r.Text))).ToList();
        Assert.Equal(new[] { "• item", "code", "quoted", "• nested", "• loose one", "loose two" }, shape);
        // The nested item sits deeper than its parent; the quote and code sit under the item's text.
        Assert.True(blocks[3].IndentPoints > blocks[0].IndentPoints);
        Assert.True(blocks[1].IndentPoints > 0 && blocks[2].IndentPoints > blocks[0].IndentPoints);
    }

    [Fact]
    public void Page_markers_stay_index_aligned_with_a_list_items_blocks()
    {
        var tree = Parse(ItemWithBlocks);
        var blocks = FlowDocumentBuilder.Build(tree);
        var markers = BlockPageMarkers.Compute(tree);
        Assert.Equal(blocks.Count, markers.NodeId.Length);
        for (var i = 0; i < blocks.Count; i++)
        {
            Assert.Equal(blocks[i].NodeId, markers.NodeId[i]);
        }
    }

    private static RenderTree QuoteTree(string alert) => Parse(string.Join(",",
        Node(1, null, "2,5", "document"),
        Node(2, 1, "3,4", "blockQuote", alert is null ? "{}" : "{ \"alert\": \"" + alert + "\" }"),
        Node(3, 2, "6", "paragraph", "{ \"style\": {} }"),
        Node(4, 2, "7", "paragraph", "{ \"style\": {} }"),
        Node(5, 1, "8", "paragraph", "{ \"style\": {} }"),
        Run(6, 3, "Warning", "{ \"bold\": true }"),
        Run(7, 4, "body"),
        Run(8, 5, "after")));

    [Fact]
    public void A_quote_draws_a_bar_and_an_alert_colours_it_by_kind()
    {
        var plain = FlowDocumentBuilder.Build(QuoteTree(null));
        var alert = FlowDocumentBuilder.Build(QuoteTree("warning"));
        var caution = FlowDocumentBuilder.Build(QuoteTree("caution"));

        Assert.NotNull(plain[0].QuoteBarColor);
        Assert.NotNull(plain[1].QuoteBarColor);
        Assert.Null(plain[2].QuoteBarColor); // the paragraph after the quote has no bar
        Assert.NotEqual(plain[0].QuoteBarColor, alert[0].QuoteBarColor);
        Assert.NotEqual(alert[0].QuoteBarColor, caution[0].QuoteBarColor);
        Assert.Equal(alert[0].QuoteBarColor, alert[1].QuoteBarColor);
        Assert.True(alert[0].IndentPoints > plain[2].IndentPoints);
    }

    [Fact]
    public void A_footnote_reference_links_to_a_bookmarked_note_and_the_note_links_back()
    {
        var tree = Parse(string.Join(",",
            Node(1, null, "2,4,5", "document"),
            Node(2, 1, "3,10", "paragraph", "{ \"style\": {} }"),
            Run(3, 2, "1", "{ \"verticalPosition\": \"superscript\" }", ", \"link\": \"#fn:a\""),
            Node(4, 1, "", "thematicBreak"),
            Node(5, 1, "6", "list", "{ \"numbering\": { \"glyphs\": \"decimal\", \"startNumber\": 1 } }"),
            Node(6, 5, "7,8", "listItem", "{ \"level\": 1, \"ordered\": true, \"marker\": \"1.\", \"style\": {} }"),
            Run(7, 6, "The note."),
            Run(8, 6, " back", "{}", ", \"link\": \"#fnref:a\""),
            Run(10, 2, " tail")),
            "[ { \"id\": 1, \"name\": \"fn:a\", \"targetNodeId\": 6 }, { \"id\": 2, \"name\": \"fnref:a\", \"targetNodeId\": 2 } ]");
        var blocks = FlowDocumentBuilder.Build(tree);

        Assert.Equal("#fn:a", RunNamed(blocks, "1").LinkTarget);
        Assert.Equal(1, RunNamed(blocks, "1").Script);
        Assert.Equal("#fnref:a", RunNamed(blocks, "back").LinkTarget);
        var note = blocks.First(b => b.NodeId == 6);
        Assert.StartsWith("1. The note.", string.Concat(note.Runs.Select(r => r.Text)));
        Assert.Contains(tree.Annotations!.Bookmarks, b => b.Name == "fn:a" && b.TargetNodeId == 6);
        Assert.Contains(blocks, b => b.Kind == FlowBlockKind.Rule);
    }

    [Fact]
    public void A_markdown_run_wash_reaches_the_text_properties()
    {
        var run = new FlowRun("hot", null, 12, false, false, false, false, Colors.Black, null, Colors.Yellow, 0);
        var props = FlowRun.PropertiesFor(run, 16, Brushes.Black);
        Assert.NotNull(props.BackgroundBrush);
        var sup = FlowRun.PropertiesFor(run with { Script = 1, Background = null }, 16, Brushes.Black);
        Assert.Null(sup.BackgroundBrush);
        Assert.Equal(global::Avalonia.Media.BaselineAlignment.Superscript, sup.BaselineAlignment);
    }
}
