using System.Collections.Generic;
using System.Text;
using System.Text.Json;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Paging;
using FastDoc.Avalonia.Rendering;
using Avalonia;
using Xunit;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S10-B (docs/studio/sprints/S10/s10b-toggle-position.md): the reading-position toggle contract
/// mirrored from macOS (INVARIANTS.md, PageViewOptionsTests
/// .testTheReadingPositionSurvivesAToggleFromDeepInTheDocument) — pressing Ctrl+Shift+P (View >
/// Page Mode) deep in a document must not snap back to the top; toggling back must not lose the
/// place either. Uses a synthetic multi-page document (same documentPaper/margins shape as
/// S9B3Batch2Tests' fixture) with enough paragraphs to force several pages, so the test can pin an
/// EXACT expected page/block via an independently-built <see cref="PageLayoutResult"/> — the same
/// call FlowDocumentView's own EnsurePageLayout makes (BuildLayout below mirrors
/// S9B3Batch2Tests.BuildLayout) — rather than guessing at pixel tolerances.
/// </summary>
public class S10BTogglePositionTests
{
    public S10BTogglePositionTests() => AvaloniaHeadlessSetup.EnsureReady();

    private const int ParagraphCount = 300;

    /// <summary>A single-section document, small page (300x400pt, 40/20/40/20pt margins — the
    /// same shape as S9B3Batch2Tests' fixture) with <see cref="ParagraphCount"/> one-line
    /// paragraphs, each carrying its own ordinal in its text so a defect would be visible in the
    /// rendered content, not just in an index — small page + many paragraphs forces the several
    /// pages this toggle-position contract needs to be tested against.</summary>
    private static RenderTree ManyParagraphsTree()
    {
        var sb = new StringBuilder();
        sb.Append("""
        {
          "schemaVersion": 1,
          "document": {
            "format": "docx",
            "rootNodeId": 0,
            "defaultBodyFontSize": 12,
            "documentPaper": {
              "widthPoints": 300,
              "heightPoints": 400,
              "margins": { "top": 40, "right": 20, "bottom": 40, "left": 20 }
            }
          },
          "nodes": [
        """);
        sb.Append("""{ "id": 0, "parentId": null, "type": "document", "data": {}, "children": [""");
        for (var i = 0; i < ParagraphCount; i++)
        {
            if (i > 0) { sb.Append(','); }
            sb.Append(1 + i * 2);
        }
        sb.Append("] },");
        for (var i = 0; i < ParagraphCount; i++)
        {
            var paraId = 1 + i * 2;
            var runId = paraId + 1;
            var label = "Paragraph " + i.ToString("000");
            sb.Append("{ \"id\": ").Append(paraId).Append(", \"parentId\": 0, \"type\": \"paragraph\", \"data\": {\"style\": {}}, \"children\": [").Append(runId).Append("] },");
            sb.Append("{ \"id\": ").Append(runId).Append(", \"parentId\": ").Append(paraId)
              .Append(", \"type\": \"textRun\", \"data\": { \"text\": \"").Append(label).Append("\", \"style\": {} }, \"children\": [] }");
            if (i < ParagraphCount - 1) { sb.Append(','); }
        }
        sb.Append("] }");
        return JsonSerializer.Deserialize<RenderTree>(sb.ToString())!;
    }

    /// <summary>The SAME call FlowDocumentView.EnsurePageLayout makes for a view whose
    /// MasterPageFurniture/SplitTablesAcrossPages are at their (true/true) defaults — built
    /// independently here so the test can name an exact expected page/block instead of asserting
    /// against the view's own private state.</summary>
    private static (List<FlowBlock> Blocks, PageGeometry Geometry, PageLayoutResult Layout) BuildLayout(RenderTree tree)
    {
        var blocks = FlowDocumentBuilder.Build(tree);
        var geometry = PageGeometry.FromDocument(tree)!;
        var markers = BlockPageMarkers.Compute(tree);
        var (layout, _, _, _) = PageLayout.BuildWithTableSettle(blocks, markers, geometry,
            System.IntPtr.Zero, headersOn: true, footersOn: true, splitTablesDefault: true);
        return (blocks, geometry, layout);
    }

    /// <summary>The block whose placement starts nearest the top of <paramref name="pageIndex"/> —
    /// mirrors FlowDocumentView's private FirstBlockOnPage exactly, including searching BOTH
    /// Placements (non-text blocks) and Lines (text blocks — this fixture is paragraphs only, so
    /// Placements is always empty and Lines is the only source of truth here).</summary>
    private static int FirstBlockOnPage(PageLayoutResult layout, int pageIndex)
    {
        var best = -1;
        var bestTop = double.MaxValue;
        foreach (var placement in layout.Placements)
        {
            if (placement.PageIndex != pageIndex) { continue; }
            if (best == -1 || placement.LocalTopPoints < bestTop)
            {
                best = placement.BlockIndex;
                bestTop = placement.LocalTopPoints;
            }
        }
        foreach (var line in layout.Lines)
        {
            if (line.PageIndex != pageIndex) { continue; }
            if (best == -1 || line.LocalTopPoints < bestTop)
            {
                best = line.BlockIndex;
                bestTop = line.LocalTopPoints;
            }
        }
        return best;
    }

    [Fact]
    public void Toggling_to_page_mode_from_deep_in_flow_lands_on_the_page_containing_that_block()
    {
        var tree = ManyParagraphsTree();
        var (_, _, layout) = BuildLayout(tree);

        // Setup sanity: this fixture must actually paginate to more than a couple of pages, or
        // the assertions below would pass vacuously (page 0 looks the same whether the fix works
        // or not).
        Assert.True(layout.PageCount > 3, $"fixture only produced {layout.PageCount} pages — not deep enough to test");

        var targetPage = layout.PageCount / 2;
        var targetBlock = FirstBlockOnPage(layout, targetPage);
        Assert.True(targetBlock > 0, "the target page's first block should not be block 0 (that would not be 'deep')");

        var view = new FlowDocumentView();
        view.SetTree(tree);
        view.Measure(new Size(600, 800));

        // Scroll deep in FLOW mode, to the exact top of the block that (independently computed
        // above) starts targetPage.
        // A small nonzero fraction, not exactly 0 — an offset sitting EXACTLY on a block's top
        // boundary resolves to the PRECEDING block index (FlowDocumentView.LowerBound treats the
        // boundary value as still inside the earlier block), which is a pre-existing, consistent
        // quirk of that lookup (SetZoom's own re-anchor has the same edge behaviour) and not
        // something this toggle-position fix changes.
        view.RestorePosition(targetBlock, 0.05);
        var (blockBefore, _) = view.GetCurrentPositionForSave();
        Assert.Equal(targetBlock, blockBefore); // setup got exactly where intended, before toggling

        view.PageMode = true;

        Assert.True(view.HasPageGeometry);
        Assert.Equal(layout.PageCount, view.ExportPageCount);

        var expectedTop = view.ExportPageTopPx(targetPage);
        Assert.True(expectedTop > 0, "target page should not be page 0 — otherwise a reset-to-top bug looks identical to a fix");
        Assert.Equal(expectedTop, view.ScrollOffset, precision: 2);
    }

    [Fact]
    public void Toggling_page_mode_off_again_restores_the_flow_offset_within_one_block()
    {
        var tree = ManyParagraphsTree();
        var (_, _, layout) = BuildLayout(tree);
        Assert.True(layout.PageCount > 3, $"fixture only produced {layout.PageCount} pages — not deep enough to test");

        var targetPage = layout.PageCount - 1; // last page — as deep as this document goes
        var targetBlock = FirstBlockOnPage(layout, targetPage);
        Assert.True(targetBlock > ParagraphCount / 2, "the last page's first block should be well past the document's midpoint");

        var view = new FlowDocumentView();
        view.SetTree(tree);
        view.Measure(new Size(600, 800));
        // A small nonzero fraction, not exactly 0 — an offset sitting EXACTLY on a block's top
        // boundary resolves to the PRECEDING block index (FlowDocumentView.LowerBound treats the
        // boundary value as still inside the earlier block), which is a pre-existing, consistent
        // quirk of that lookup (SetZoom's own re-anchor has the same edge behaviour) and not
        // something this toggle-position fix changes.
        view.RestorePosition(targetBlock, 0.05);

        // Round trip: flow -> page -> flow.
        view.PageMode = true;
        Assert.True(view.ScrollOffset > 0, "entering page mode deep in the document should not land on page 0");

        view.PageMode = false;

        var (blockAfter, fractionAfter) = view.GetCurrentPositionForSave();
        Assert.InRange(blockAfter, targetBlock - 1, targetBlock + 1); // tolerance = one block
        if (blockAfter == targetBlock)
        {
            Assert.True(fractionAfter < 0.15, $"expected to land back near the TOP of block {targetBlock}, got fraction {fractionAfter}");
        }
    }

    [Fact]
    public void Toggling_page_mode_on_a_document_with_no_page_geometry_still_resets_to_top_safely()
    {
        // Regression guard for the "silently has no effect" contract (HasPageGeometry's own doc):
        // a document that never declared page geometry (a bare markdown/text tree) must not throw
        // when PageMode flips, and must not attempt to compute a page anchor that cannot exist.
        const string json = """
        {
          "schemaVersion": 1,
          "document": { "format": "markdown", "rootNodeId": 0, "defaultBodyFontSize": 12 },
          "nodes": [
            { "id": 0, "parentId": null, "type": "document", "data": {}, "children": [1, 3] },
            { "id": 1, "parentId": 0, "type": "paragraph", "data": {"style": {}}, "children": [2] },
            { "id": 2, "parentId": 1, "type": "textRun", "data": { "text": "first", "style": {} }, "children": [] },
            { "id": 3, "parentId": 0, "type": "paragraph", "data": {"style": {}}, "children": [4] },
            { "id": 4, "parentId": 3, "type": "textRun", "data": { "text": "second", "style": {} }, "children": [] }
          ]
        }
        """;
        var tree = JsonSerializer.Deserialize<RenderTree>(json)!;

        var view = new FlowDocumentView();
        view.SetTree(tree);
        view.Measure(new Size(600, 800));

        Assert.False(view.HasPageGeometry);

        view.PageMode = true;
        Assert.True(view.PageMode); // the getter still reports the requested value (HasPageGeometry's doc)
        view.PageMode = false;
    }
}
