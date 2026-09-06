using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Themes.Fluent;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Panels;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S9-A — owner report: "hwp 에서 목차를 눌렀는데 이동이 안돼" (clicking a TOC entry in an HWP
/// document does not scroll to it).
///
/// Root cause, confirmed against a real corpus document
/// (<c>testdocs/everything/1790387_prep_final_report.hwpx</c>, whose 13 chapter headings ALL live
/// inside a title-box table cell — a common Korean report layout — and ALL failed to resolve
/// before this fix): a heading's node can be built INSIDE a table cell.
/// <see cref="FlowDocumentBuilder.Build"/>'s "table" case walks a cell's children into
/// <c>TableGridCell.Content</c> (<c>Rendering/TableGridRenderer.cs</c>), a nested list the
/// top-level <c>_blocks</c>/<c>_offsets</c> FlowDocumentView scrolls against never flattens. S8-B4's
/// original <c>ScrollToNodeId</c> only scanned <c>_blocks[i].NodeId == nodeId</c>, so it silently
/// missed every such heading. <see cref="TableOfContentsModel.Walk"/> does not skip
/// table/tableRow/tableCell (only footnote/header/footer/masterPage/anchoredObject/formControl/
/// textRun/lineBreak — its own <c>SkippedTypes</c>), so it already found and reported these
/// NodeIds; only the scroll-side lookup was too narrow. HWP hits this far more than markdown/docx
/// because Korean report templates commonly style a chapter title inside a shaded title-box table
/// rather than a bare heading paragraph.
///
/// The fix (<c>FlowDocumentView.BlockOrItsCellsCarryNodeId</c>) makes the scan recurse into a
/// <c>Kind == Table</c> block's cells (and, since a cell can itself hold a nested table up to
/// <see cref="FlowDocumentBuilder"/>'s own <c>MaxTableNestingDepth</c>, into nested tables too),
/// resolving a match to the ENCLOSING top-level block — there is no independent scroll offset for
/// a cell's own content, only for a top-level block, so scrolling to the table containing the
/// heading is the closest position this reader can name (matching how it already handles any other
/// content inside a cell).
/// </summary>
public class S9AHwpTocTests
{
    public S9AHwpTocTests() => AvaloniaHeadlessSetup.EnsureReady();

    // node ids: 0 document, 5 filler paragraph (pushes the table off y=0 so the fix is
    // distinguishable from a false-positive "index 0" scroll), 1 table -> 11 tableRow ->
    // 12 tableCell -> 13 heading("Chapter One") -> 130 textRun, 2 trailing paragraph.
    // Flow-block indices: filler=0, table=1, trailing paragraph=2. The heading (13) and its
    // textRun (130) never appear as a TOP-LEVEL block — they live only inside the table's
    // TableGridCell.Content, which is the whole point of this fixture.
    private const string TitleBoxTableJson = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": { "format": "hwp", "rootNodeId": 0, "defaultBodyFontSize": 12 },
        "nodes": [
          { "id": 0, "parentId": null, "children": [5, 1, 2], "type": "document", "data": {} },
          { "id": 5, "parentId": 0, "children": [50], "type": "paragraph", "data": { "style": {} } },
          { "id": 50, "parentId": 5, "children": [], "type": "textRun", "data": { "text": "filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler", "style": {} } },
          { "id": 1, "parentId": 0, "children": [11], "type": "table", "data": { "gridWidths": [1.0], "style": {} } },
          { "id": 11, "parentId": 1, "children": [12], "type": "tableRow", "data": { "row": 0, "header": false } },
          { "id": 12, "parentId": 11, "children": [13], "type": "tableCell", "data": { "row": 0, "column": 0 } },
          { "id": 13, "parentId": 12, "children": [130], "type": "heading", "data": { "level": 1, "style": {} } },
          { "id": 130, "parentId": 13, "children": [], "type": "textRun", "data": { "text": "Chapter One", "style": {} } },
          { "id": 2, "parentId": 0, "children": [20], "type": "paragraph", "data": { "style": {} } },
          { "id": 20, "parentId": 2, "children": [], "type": "textRun", "data": { "text": "after the table", "style": {} } }
        ],
        "annotations": { "comments": [], "bookmarks": [] }
      }
    }
    """;

    // node ids: 0 document, 1 table -> 11 row -> 12 cell -> 2 NESTED table -> 21 row -> 22 cell ->
    // 3 heading("Nested Chapter") -> 30 textRun. Exercises the recursion through a table nested
    // inside a table cell (FlowDocumentBuilder.BuildTable's own recursion, up to MaxTableNestingDepth).
    private const string NestedTitleBoxTableJson = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": { "format": "hwp", "rootNodeId": 0, "defaultBodyFontSize": 12 },
        "nodes": [
          { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
          { "id": 1, "parentId": 0, "children": [11], "type": "table", "data": { "gridWidths": [1.0], "style": {} } },
          { "id": 11, "parentId": 1, "children": [12], "type": "tableRow", "data": { "row": 0, "header": false } },
          { "id": 12, "parentId": 11, "children": [2], "type": "tableCell", "data": { "row": 0, "column": 0 } },
          { "id": 2, "parentId": 12, "children": [21], "type": "table", "data": { "gridWidths": [1.0], "style": {} } },
          { "id": 21, "parentId": 2, "children": [22], "type": "tableRow", "data": { "row": 0, "header": false } },
          { "id": 22, "parentId": 21, "children": [3], "type": "tableCell", "data": { "row": 0, "column": 0 } },
          { "id": 3, "parentId": 22, "children": [30], "type": "heading", "data": { "level": 1, "style": {} } },
          { "id": 30, "parentId": 3, "children": [], "type": "textRun", "data": { "text": "Nested Chapter", "style": {} } }
        ],
        "annotations": { "comments": [], "bookmarks": [] }
      }
    }
    """;

    private static RenderTree LoadTree(string json)
    {
        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(json)!;
        Assert.True(envelope.IsOk);
        return envelope.Ok!.Value.Deserialize<RenderTree>()!;
    }

    private static void EnsureFluentThemeLoaded()
    {
        if (Application.Current is null) { return; }
        if (Application.Current.Styles.Count == 0) { Application.Current.Styles.Add(new FluentTheme()); }
    }

    private static FlowDocumentView CreateAttachedView(string json, out Window window)
    {
        EnsureFluentThemeLoaded();
        var view = new FlowDocumentView();
        window = new Window { Width = 500, Height = 400, Content = view };
        window.Show();
        view.SetTree(LoadTree(json));
        view.Measure(new Size(500, 400));
        view.Arrange(new Rect(0, 0, 500, 400));
        return view;
    }

    [Fact]
    public void FlowDocumentBuilder_never_promotes_a_table_cells_heading_to_a_top_level_block()
    {
        var tree = LoadTree(TitleBoxTableJson);
        var blocks = FlowDocumentBuilder.Build(tree);

        // filler(5), table(1), trailing paragraph(2) — exactly three top-level blocks. The
        // heading (13) and its textRun (130) are NOT among them; they live only inside the
        // table's own TableGridCell.Content. This is the documented cause, not a defect to fix
        // in the builder — the fix is that the SCROLL lookup must look inside the table too.
        Assert.Equal(3, blocks.Count);
        Assert.Equal(5UL, blocks[0].NodeId);
        Assert.Equal(1UL, blocks[1].NodeId);
        Assert.Equal(2UL, blocks[2].NodeId);
        Assert.DoesNotContain(blocks, b => b.NodeId == 13UL);
    }

    [Fact]
    public void TableOfContentsModel_finds_a_heading_that_lives_inside_a_table_cell()
    {
        var tree = LoadTree(TitleBoxTableJson);
        var entries = TableOfContentsModel.Build(tree);

        var entry = Assert.Single(entries);
        Assert.Equal(1, entry.Level);
        Assert.Equal("Chapter One", entry.Text);
        Assert.Equal(13UL, entry.NodeId); // the heading's OWN node id, same as any other heading
    }

    [Fact]
    public void ScrollToNodeId_resolves_a_table_cell_headings_NodeId_to_the_enclosing_table_block()
    {
        var view = CreateAttachedView(TitleBoxTableJson, out _);

        // Before the fix this returned false: the S8-B4 scan only checked
        // _blocks[i].NodeId == nodeId, and node 13 (the heading) is never a top-level block.
        var resolved = view.ScrollToNodeId(13);

        Assert.True(resolved);
    }

    [Fact]
    public void A_table_cell_headings_scroll_lands_at_the_tables_own_top_level_offset_not_at_zero()
    {
        var view = CreateAttachedView(TitleBoxTableJson, out _);

        // Scrolling to the filler paragraph (block 0) names offset 0. Scrolling to the heading
        // INSIDE the table (block 1's cell) must land at the TABLE's own offset — strictly past
        // the filler's — proving the match resolved to the enclosing block rather than either
        // silently landing at 0 (the old false-negative's effective behaviour, since ScrollToNodeId
        // returning false leaves the scroll position untouched) or some other wrong index.
        view.ScrollToNodeId(5);
        var fillerOffset = view.ScrollOffset;

        view.ScrollToNodeId(13);
        var tableHeadingOffset = view.ScrollOffset;

        Assert.True(tableHeadingOffset > fillerOffset);
    }

    [Fact]
    public void ScrollToNodeId_still_resolves_an_ordinary_top_level_heading_directly()
    {
        var view = CreateAttachedView(TitleBoxTableJson, out _);

        // Regression guard: the fix must not disturb the S8-B4 direct top-level match path.
        // Node 2 (the trailing paragraph after the table) is a plain top-level block.
        Assert.True(view.ScrollToNodeId(2));
    }

    [Fact]
    public void ScrollToNodeId_recurses_through_a_table_nested_inside_a_table_cell()
    {
        var view = CreateAttachedView(NestedTitleBoxTableJson, out _);

        // Node 3 is a heading two table-nesting levels deep (a table inside a table cell) —
        // FlowDocumentBuilder.BuildTable's own recursion (up to MaxTableNestingDepth) means the
        // scroll-side lookup must recurse the same way.
        Assert.True(view.ScrollToNodeId(3));
    }

    [Fact]
    public void ScrollToNodeId_still_returns_false_for_a_node_id_absent_from_the_whole_tree()
    {
        var view = CreateAttachedView(TitleBoxTableJson, out _);

        Assert.False(view.ScrollToNodeId(9999));
    }

    [Fact]
    public void ScrollToNodeId_for_a_table_cell_heading_still_returns_false_in_page_mode()
    {
        var view = CreateAttachedView(TitleBoxTableJson, out _);

        // S8-B4's page-mode boundary is unchanged by this fix — flow-mode block indices (table
        // cell content included) still do not name a meaningful position in PageModePainter's
        // separate per-page layout.
        view.PageMode = false; // this fixture's tree declares no page geometry, so PageMode setter
                                // is a no-op either way; the guard is the leading `if (_pageMode)`
                                // check itself, exercised directly below.
        Assert.False(InvokeWhilePageModeForced(view, 13));
    }

    /// <summary>Forces the private `_pageMode` flag via the public setter's guarded path is not
    /// possible when the tree has no page geometry (the setter no-ops), so this calls
    /// ScrollToNodeId through reflection on the backing field to exercise the `if (_pageMode)`
    /// early-return specifically — the same boundary S8-B4's own tests already established for
    /// the non-table case; this test only confirms the table-cell recursion added here sits
    /// BEHIND that guard, not in front of it.</summary>
    private static bool InvokeWhilePageModeForced(FlowDocumentView view, ulong nodeId)
    {
        var field = typeof(FlowDocumentView).GetField("_pageMode",
            System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!;
        field.SetValue(view, true);
        try
        {
            return view.ScrollToNodeId(nodeId);
        }
        finally
        {
            field.SetValue(view, false);
        }
    }
}
