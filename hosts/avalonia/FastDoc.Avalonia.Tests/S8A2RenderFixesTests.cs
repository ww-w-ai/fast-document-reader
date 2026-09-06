using System.Collections.Generic;
using System.Text.Json;
using Avalonia;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Media.TextFormatting;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Paging;
using FastDoc.Avalonia.Printing;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>Regression tests for the five S8-A2 Linux-vs-macOS render defect classes (C1-C5) — see
/// docs/studio/sprints/S8/s8a2-render-fixes.md for the catalog findings each one closes.</summary>
public class S8A2RenderFixesTests
{
    public S8A2RenderFixesTests() => AvaloniaHeadlessSetup.EnsureReady();

    /// <summary>A no-op IPageCanvas that only records what DrawRect/DrawImage were called with —
    /// enough to assert ImageBlockRenderer.Draw's geometry without a real Skia/Avalonia surface.</summary>
    private sealed class RecordingCanvas : IPageCanvas
    {
        public Rect? LastRect;
        public bool ImageDrawn;

        public void DrawRect(Rect rect, Color? fill, Color? stroke, double strokeThicknessPx) => LastRect = rect;
        public void DrawLine(Point a, Point b, Color color, double thicknessPx) { }
        public void DrawImage(Bitmap bitmap, byte[]? sourceBytes, string? sourceMimeType, Rect destRect)
        {
            ImageDrawn = true;
            LastRect = destRect;
        }
        public void DrawTextLayout(TextLayout layout, Point origin) { }
        public void DrawTextLine(TextLine line, Point origin) { }
    }

    // ---- C1: an "unsupported" node becomes a placeholder BOX, not a bare text line ----

    [Fact]
    public void Unsupported_node_becomes_an_image_kind_placeholder_with_a_label()
    {
        var tree = new RenderTree
        {
            SchemaVersion = 1,
            Document = new RenderDocument { RootNodeId = 0, DefaultBodyFontSize = 12 },
            Nodes = new List<RenderNode>
            {
                Node(0, "document", new ulong[] { 1 }),
                NodeWithRawData(1, "unsupported", System.Array.Empty<ulong>(),
                    """{"sourceFormatTag":"officeGraphic","reason":"ole","preservedText":null,"intrinsicSize":{"width":300,"height":150}}"""),
            },
        };

        var blocks = FlowDocumentBuilder.Build(tree);

        Assert.Single(blocks);
        Assert.Equal(FlowBlockKind.Image, blocks[0].Kind);
        Assert.Equal("ole", blocks[0].PlaceholderLabel);
        Assert.Equal(300, blocks[0].ImageWidthPoints);
        Assert.Equal(150, blocks[0].ImageHeightPoints);
        // No Runs at all — the old shape emitted a Text-kind FlowRun carrying "[officeGraphic: ole]"
        // as literal text, which is what let two real unsupported objects read as one label printed
        // twice with no space reserved between them (catalog F2).
        Assert.Empty(blocks[0].Runs);
    }

    [Fact]
    public void Two_distinct_unsupported_nodes_produce_two_distinct_reserved_boxes()
    {
        // Mirrors the real hwpx sample's shape: two "unsupported" nodes, DIFFERENT declared sizes,
        // each its own child of the flow — never a DAG (shared) node. Confirms the fix does not
        // collapse or merge them; each keeps its own reserved geometry.
        var tree = new RenderTree
        {
            SchemaVersion = 1,
            Document = new RenderDocument { RootNodeId = 0, DefaultBodyFontSize = 12 },
            Nodes = new List<RenderNode>
            {
                Node(0, "document", new ulong[] { 1, 2 }),
                NodeWithRawData(1, "unsupported", System.Array.Empty<ulong>(),
                    """{"sourceFormatTag":"officeGraphic","reason":"ole","preservedText":null,"intrinsicSize":{"width":482.46,"height":221.15}}"""),
                NodeWithRawData(2, "unsupported", System.Array.Empty<ulong>(),
                    """{"sourceFormatTag":"officeGraphic","reason":"ole","preservedText":null,"intrinsicSize":{"width":482.05,"height":240.25}}"""),
            },
        };

        var blocks = FlowDocumentBuilder.Build(tree);

        Assert.Equal(2, blocks.Count);
        Assert.All(blocks, b => Assert.Equal(FlowBlockKind.Image, b.Kind));
        Assert.NotEqual(blocks[0].ImageHeightPoints, blocks[1].ImageHeightPoints);
    }

    // ---- C2: reserved height and drawn height come from the SAME function ----

    [Fact]
    public void Picture_geometry_shrinks_to_the_column_preserving_aspect_never_enlarges()
    {
        var (width, height) = PictureGeometry.Measure(declaredWidthPoints: 400, declaredHeightPoints: 200, columnWidthPoints: 200);
        Assert.Equal(200, width, 3);
        Assert.Equal(100, height, 3); // same 2:1 aspect, halved with the width

        var (narrowW, narrowH) = PictureGeometry.Measure(declaredWidthPoints: 100, declaredHeightPoints: 50, columnWidthPoints: 400);
        Assert.Equal(100, narrowW, 3); // narrower than the column -> never scaled UP
        Assert.Equal(50, narrowH, 3);
    }

    [Fact]
    public void NonTextBlockHeightPoints_and_ImageBlockRenderer_Draw_agree_on_a_wide_pictures_height()
    {
        // A picture declared WIDER than its column — the exact shape that overlapped the next
        // block (catalog F3): the old NonTextBlockHeightPoints reserved the raw, unclamped declared
        // height while ImageBlockRenderer.Draw painted a shorter, aspect-clamped one.
        var block = new FlowBlock
        {
            Kind = FlowBlockKind.Image,
            ImageWidthPoints = 600,
            ImageHeightPoints = 300,
            SpacingBeforePoints = 0,
            SpacingAfterPoints = 0,
        };
        const double columnWidthPoints = 300;
        const double pointsToPixels = 96.0 / 72.0;

        var reservedHeightPoints = PageLayout.NonTextBlockHeightPoints(block, columnWidthPoints);

        var canvas = new RecordingCanvas();
        var renderer = new ImageBlockRenderer();
        var drawnHeightPx = renderer.Draw(canvas, block, left: 0, top: 0,
            columnWidth: columnWidthPoints * pointsToPixels, indentPx: 0);

        Assert.Equal(reservedHeightPoints * pointsToPixels, drawnHeightPx, 3);
        // And it really did shrink (300 declared, but wider than the 300pt column at 2:1 aspect ->
        // half the width -> half the height too).
        Assert.True(reservedHeightPoints < 300);
    }

    [Fact]
    public void ImageBlockRenderer_draws_the_placeholder_label_for_an_unsupported_block()
    {
        var block = new FlowBlock
        {
            Kind = FlowBlockKind.Image,
            PlaceholderLabel = "ole",
            ImageWidthPoints = 200,
            ImageHeightPoints = 100,
        };
        var canvas = new RecordingCanvas();
        var renderer = new ImageBlockRenderer();

        renderer.Draw(canvas, block, left: 0, top: 0, columnWidth: 400, indentPx: 0);

        Assert.False(canvas.ImageDrawn); // no resource id -> placeholder rect, not a real bitmap
        Assert.NotNull(canvas.LastRect);
    }

    // ---- C4: TAB / embedded newline / HWP dot-leader never reach TextLayout as a raw code point ----

    [Fact]
    public void Embedded_tab_and_newline_and_dot_leader_are_never_left_in_a_runs_text()
    {
        var tree = new RenderTree
        {
            SchemaVersion = 1,
            Document = new RenderDocument { RootNodeId = 0, DefaultBodyFontSize = 12 },
            Nodes = new List<RenderNode>
            {
                Node(0, "document", new ulong[] { 1 }),
                NodeWithRawData(1, "paragraph", new ulong[] { 2 }, """{"style":{}}"""),
                NodeWithRawData(2, "textRun", System.Array.Empty<ulong>(),
                    // docx cell newline (F7) + hwp TOC leader (F9) + docx tab-separated fields, one run
                    """{"text":"개요\t1\n다음 줄 ․․․ 2","style":{}}"""),
            },
        };

        var blocks = FlowDocumentBuilder.Build(tree);

        Assert.Single(blocks);
        foreach (var run in blocks[0].Runs)
        {
            // A genuine line break is deliberately represented as a whole run whose text IS "\n"
            // (the exact shape a real "lineBreak" node already produces elsewhere in this builder)
            // — that is a real break, not a leaked control character. What must never happen is a
            // TAB, an embedded newline mid-run, or the HWP dot-leader surviving inside otherwise
            // ordinary text.
            if (run.Text == "\n") { continue; }
            foreach (var ch in run.Text)
            {
                Assert.True(ch != '\t' && ch != '\n' && ch != '․',
                    $"control/leader code point U+{(int)ch:X4} leaked into a drawn run's text: \"{run.Text}\"");
            }
        }
        // The visible content survives (a leader dot becomes a full stop, a tab becomes spaces, a
        // newline becomes a real line break) rather than being silently dropped.
        var joined = string.Concat(blocks[0].Runs.ConvertAll(r => r.Text));
        Assert.Contains("개요", joined);
        Assert.Contains("1", joined);
        Assert.Contains("다음 줄", joined);
        Assert.Contains("2", joined);
    }

    // ---- C3/C5: header/footer selection is per-page, per-section, with live page numbers ----

    [Fact]
    public void First_page_header_overrides_default_and_an_empty_one_suppresses_the_band()
    {
        var byId = new Dictionary<ulong, RenderNode>
        {
            [10] = NodeWithRawData(10, "header", new ulong[] { 11 }, """{"appliesTo":"defaultPages"}"""),
            [11] = NodeWithRawData(11, "textRun", System.Array.Empty<ulong>(), """{"text":"Default Header","style":{}}"""),
            [20] = NodeWithRawData(20, "header", System.Array.Empty<ulong>(), """{"appliesTo":"firstPage"}"""), // blank titlePg header
        };
        var candidates = new List<HeaderFooterText.Candidate>
        {
            new(byId[10], "defaultPages", null),
            new(byId[20], "firstPage", null),
        };

        var coverText = HeaderFooterText.Resolve(candidates, byId, sectionIndex: 0, isFirstPageOfSection: true, pageNumber: 1, totalPages: 5);
        var laterText = HeaderFooterText.Resolve(candidates, byId, sectionIndex: 0, isFirstPageOfSection: false, pageNumber: 2, totalPages: 5);

        Assert.Null(coverText); // F5: blank first-page header suppresses the band on the cover
        Assert.Equal("Default Header", laterText);
    }

    [Fact]
    public void A_section_scoped_footer_never_leaks_onto_a_DIFFERENT_sections_pages()
    {
        // Mirrors the real HWP manual's shape (wire::HeaderFooter's own doc): the document declares
        // ONE footer, scoped to exactly one section (`section: Some(n)`) — no document-wide
        // ("section": null, "applies to every page") footer node exists alongside it. Before this
        // fix, HeaderFooterText concatenated EVERY footer node in the WHOLE tree onto every page
        // regardless of section, so this section-11-only text would have shown on section 0's
        // pages too — the wrong-section leak `HeaderFooter.section`'s own doc warns against.
        var byId = new Dictionary<ulong, RenderNode>
        {
            [40] = NodeWithRawData(40, "footer", new ulong[] { 41 }, """{"appliesTo":"defaultPages","section":3}"""),
            [41] = NodeWithRawData(41, "textRun", System.Array.Empty<ulong>(), """{"text":"Appendix Footer","style":{}}"""),
        };
        var candidates = new List<HeaderFooterText.Candidate> { new(byId[40], "defaultPages", 3) };

        var section0Text = HeaderFooterText.Resolve(candidates, byId, sectionIndex: 0, isFirstPageOfSection: false, pageNumber: 5, totalPages: 500);
        var section3Text = HeaderFooterText.Resolve(candidates, byId, sectionIndex: 3, isFirstPageOfSection: false, pageNumber: 5, totalPages: 500);

        Assert.Null(section0Text); // no footer at all on a section this footer was never scoped to
        Assert.Equal("Appendix Footer", section3Text);
    }

    [Fact]
    public void A_document_wide_footer_still_combines_with_one_sections_own_extra_footer()
    {
        // `section: None` is documented as "applies to EVERY page" (wire.rs's own words) — a
        // document-wide footer legitimately combines with a MORE SPECIFIC section-scoped one on
        // that section's own pages, rather than the specific one replacing it.
        var byId = new Dictionary<ulong, RenderNode>
        {
            [30] = NodeWithRawData(30, "footer", new ulong[] { 31 }, """{"appliesTo":"defaultPages"}"""),
            [31] = NodeWithRawData(31, "textRun", System.Array.Empty<ulong>(), """{"text":"Doc Footer","style":{}}"""),
            [40] = NodeWithRawData(40, "footer", new ulong[] { 41 }, """{"appliesTo":"defaultPages","section":3}"""),
            [41] = NodeWithRawData(41, "textRun", System.Array.Empty<ulong>(), """{"text":"Appendix Footer","style":{}}"""),
        };
        var candidates = new List<HeaderFooterText.Candidate>
        {
            new(byId[30], "defaultPages", null),
            new(byId[40], "defaultPages", 3),
        };

        var section0Text = HeaderFooterText.Resolve(candidates, byId, sectionIndex: 0, isFirstPageOfSection: false, pageNumber: 5, totalPages: 500);
        var section3Text = HeaderFooterText.Resolve(candidates, byId, sectionIndex: 3, isFirstPageOfSection: false, pageNumber: 5, totalPages: 500);

        Assert.Equal("Doc Footer", section0Text);
        Assert.Contains("Doc Footer", section3Text);
        Assert.Contains("Appendix Footer", section3Text);
    }

    [Fact]
    public void A_page_number_field_renders_the_current_page_not_a_frozen_value()
    {
        var byId = new Dictionary<ulong, RenderNode>
        {
            [50] = NodeWithRawData(50, "footer", new ulong[] { 51, 52 }, """{"appliesTo":"defaultPages"}"""),
            [51] = NodeWithRawData(51, "textRun", System.Array.Empty<ulong>(), """{"text":"- ","style":{}}"""),
            [52] = NodeWithRawData(52, "textRun", System.Array.Empty<ulong>(), """{"text":"","style":{},"pageNumberField":"page"}"""),
        };
        var candidates = new List<HeaderFooterText.Candidate> { new(byId[50], "defaultPages", null) };

        var page1 = HeaderFooterText.Resolve(candidates, byId, sectionIndex: 0, isFirstPageOfSection: true, pageNumber: 1, totalPages: 10);
        var page10 = HeaderFooterText.Resolve(candidates, byId, sectionIndex: 0, isFirstPageOfSection: false, pageNumber: 10, totalPages: 10);

        Assert.Contains("1", page1);
        Assert.Contains("10", page10);
        Assert.NotEqual(page1, page10); // catalog F6: this used to be the SAME literal text on every page
    }

    [Fact]
    public void PageLayout_assigns_the_correct_section_index_per_page()
    {
        // Three sections, each one page (a section start forces a fresh page — PageLayout.Build's
        // own rule): section 0 = page 0, section 1 = page 1, section 2 = pages 2-3 (its one
        // paragraph is tall enough to spill onto a second page without a THIRD section starting).
        var tree = BuildThreeSectionTree();
        var geometry = PageGeometry.FromDocument(tree)!;
        var blocks = FlowDocumentBuilder.Build(tree);
        var markers = BlockPageMarkers.Compute(tree);

        var layout = PageLayout.Build(blocks, markers, geometry, System.IntPtr.Zero, headersOn: false, footersOn: false);

        Assert.True(layout.PageCount >= 3);
        Assert.Equal(0, layout.PageSectionIndex[0]);
        Assert.Equal(1, layout.PageSectionIndex[1]);
        Assert.Equal(2, layout.PageSectionIndex[2]);
    }

    private static RenderTree BuildThreeSectionTree()
    {
        const string json = """
        {
          "ok": {
            "schemaVersion": 1,
            "document": {
              "format": "docx", "rootNodeId": 0, "defaultBodyFontSize": 12,
              "documentPaper": { "widthPoints": 200, "heightPoints": 200, "margins": { "top": 20, "right": 20, "bottom": 20, "left": 20 } }
            },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1, 3, 5], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [2], "type": "section", "data": { "paperIsDeclared": false, "lineGridIsDeclared": false, "hidesHeader": false, "hidesFooter": false } },
              { "id": 2, "parentId": 1, "children": [], "type": "paragraph", "data": { "text": "section one", "style": {}, "pagination": { "keepWithNext": false, "pageBreakBefore": false, "hidesPageNumber": false } } },
              { "id": 3, "parentId": 0, "children": [4], "type": "section", "data": { "paperIsDeclared": false, "lineGridIsDeclared": false, "hidesHeader": false, "hidesFooter": false } },
              { "id": 4, "parentId": 3, "children": [], "type": "paragraph", "data": { "text": "section two", "style": {}, "pagination": { "keepWithNext": false, "pageBreakBefore": false, "hidesPageNumber": false } } },
              { "id": 5, "parentId": 0, "children": [6], "type": "section", "data": { "paperIsDeclared": false, "lineGridIsDeclared": false, "hidesHeader": false, "hidesFooter": false } },
              { "id": 6, "parentId": 5, "children": [], "type": "paragraph", "data": { "text": "section three", "style": {}, "pagination": { "keepWithNext": false, "pageBreakBefore": false, "hidesPageNumber": false } } }
            ]
          }
        }
        """;
        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(json)!;
        return envelope.Ok!.Value.Deserialize<RenderTree>()!;
    }

    private static RenderNode Node(ulong id, string type, ulong[] children) =>
        NodeWithRawData(id, type, children, "{}");

    private static RenderNode NodeWithRawData(ulong id, string type, ulong[] children, string rawJsonData)
    {
        using var doc = JsonDocument.Parse(rawJsonData);
        return new RenderNode
        {
            Id = id,
            Type = type,
            Children = new List<ulong>(children),
            Data = doc.RootElement.Clone(),
        };
    }
}
