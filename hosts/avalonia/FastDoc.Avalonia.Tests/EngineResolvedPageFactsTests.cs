using System;
using System.Linq;
using System.Text.Json;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Paging;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S1 (docs/plans/pagination-to-engine.md): the page facts the engine already resolves reach the
/// layout instead of values this host used to invent — the document's own body-section paper, the
/// paged "no spacing unless declared" gap, and a blank paragraph's height from its own line rule.
/// Pure managed: a fixed tree JSON and a NULL engine handle (PageBandResolver's host fallback).
/// </summary>
public class EngineResolvedPageFactsTests
{
    public EngineResolvedPageFactsTests() => AvaloniaHeadlessSetup.EnsureReady();

    private static RenderTree TreeOf(string json)
    {
        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(json)!;
        Assert.True(envelope.IsOk);
        return envelope.Ok!.Value.Deserialize<RenderTree>()!;
    }

    private const string PagedSpacingField = "\"pagedBlockSpacingPoints\": 0,";

    /// <summary>Two body paragraphs (one states its own spacing), then a table-free blank anchor.</summary>
    private static string ParagraphsTree(string documentExtras) => """
        {
          "ok": {
            "schemaVersion": 1,
            "document": {
              "format": "hwp",
              "rootNodeId": 0,
              "defaultBodyFontSize": 10,
              __EXTRAS__
              "documentPaper": {
                "widthPoints": 300, "heightPoints": 400,
                "margins": { "top": 30, "right": 30, "bottom": 30, "left": 30 }
              }
            },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1, 2, 3], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [4], "type": "paragraph", "data": { "style": {} } },
              { "id": 2, "parentId": 0, "children": [5], "type": "paragraph",
                "data": { "style": { "spacingBefore": 5, "spacingAfter": 0 } } },
              { "id": 3, "parentId": 0, "children": [], "type": "paragraph",
                "data": { "style": { "spacingBefore": 0, "spacingAfter": 0, "lineHeight": { "value": 0.01, "mode": "exact" } } } },
              { "id": 4, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "one", "style": { "fontSizePoints": 10 } } },
              { "id": 5, "parentId": 2, "children": [], "type": "textRun", "data": { "text": "two", "style": { "fontSizePoints": 10 } } }
            ]
          }
        }
        """.Replace("__EXTRAS__", documentExtras);

    [Fact]
    public void A_paged_document_gives_an_undeclared_gap_the_engines_value_and_keeps_a_declared_one()
    {
        var blocks = FlowDocumentBuilder.Build(TreeOf(ParagraphsTree(PagedSpacingField)));

        Assert.Equal(3, blocks.Count);
        Assert.Equal(0, blocks[0].SpacingBeforePoints);
        Assert.Equal(0, blocks[0].SpacingAfterPoints);
        Assert.Equal(5, blocks[1].SpacingBeforePoints);
        Assert.Equal(0, blocks[1].SpacingAfterPoints);
    }

    [Fact]
    public void A_document_with_no_paged_statement_keeps_the_hosts_own_spacing()
    {
        var blocks = FlowDocumentBuilder.Build(TreeOf(ParagraphsTree("")));

        Assert.Equal(10 * 0.3, blocks[0].SpacingBeforePoints, precision: 6);
        Assert.Equal(10 * 0.3, blocks[0].SpacingAfterPoints, precision: 6);
    }

    [Fact]
    public void A_blank_paragraph_is_as_tall_as_its_own_line_rule_says()
    {
        var tree = TreeOf(ParagraphsTree(PagedSpacingField));
        var blocks = FlowDocumentBuilder.Build(tree);
        var layout = PageLayout.Build(blocks, BlockPageMarkers.Compute(tree), PageGeometry.FromDocument(tree)!,
            IntPtr.Zero, headersOn: false, footersOn: false);

        var blank = layout.Lines.Single(l => l.BlockIndex == 2);
        Assert.Equal(0.01, blank.HeightPoints, precision: 6);
    }

    [Fact]
    public void The_plan_reads_the_paper_band_without_the_desk_gap()
    {
        var geometry = PageGeometry.FromDocument(TreeOf(ParagraphsTree(PagedSpacingField)))!;
        var screen = PageBandResolver.Resolve(IntPtr.Zero, geometry, geometry.ContentWidthPoints,
            headersOn: true, footersOn: true, separatesPages: true, deskGapPoints: null).BandPoints;
        var paper = PageBandResolver.PaperBand(IntPtr.Zero, geometry, geometry.ContentWidthPoints,
            headersOn: true, footersOn: true);

        Assert.Equal(60, paper, precision: 6);
        Assert.Equal(72, screen, precision: 6);
    }

    [Fact]
    public void The_documents_own_paper_wins_over_the_first_sections()
    {
        // Section 0 is a cover with its own margins; the document-level paper is the body section's
        // (invariant 73). A host that laid every page out on the first section took 570 sheets for
        // the 편람 where the reader takes 391.
        const string treeJson = """
        {
          "ok": {
            "schemaVersion": 1,
            "document": {
              "format": "hwp", "rootNodeId": 0, "defaultBodyFontSize": 10,
              "documentPaper": {
                "widthPoints": 300, "heightPoints": 400,
                "margins": { "top": 30, "right": 40, "bottom": 30, "left": 40 }
              }
            },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [], "type": "section",
                "data": { "paper": {
                  "widthPoints": 300, "heightPoints": 400,
                  "margins": { "top": 100, "right": 10, "bottom": 100, "left": 10 } } } }
            ]
          }
        }
        """;

        var geometry = PageGeometry.FromDocument(TreeOf(treeJson))!;

        Assert.Equal(30, geometry.MarginTopPoints);
        Assert.Equal(40, geometry.MarginLeftPoints);
    }
}
