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

    // ---- S12-J: HeaderFooterText.ResolveStyled carries the document's own font/size/alignment ----
    // (gap.md "헤더/푸터(러닝 헤더)": "텍스트는 나오되 스타일 없음" — PageModePainter.DrawBandText
    // used to paint every header/footer at a fixed 9pt Inter, always centered, regardless of what
    // the document declared.)

    [Fact]
    public void ResolveStyled_carries_the_paragraphs_own_alignment_and_the_runs_own_font_and_size()
    {
        var byId = new Dictionary<ulong, RenderNode>
        {
            [60] = NodeWithRawData(60, "header", new ulong[] { 61 }, """{"appliesTo":"defaultPages"}"""),
            [61] = NodeWithRawData(61, "paragraph", new ulong[] { 62 }, """{"style":{"alignment":"right"}}"""),
            [62] = NodeWithRawData(62, "textRun", System.Array.Empty<ulong>(),
                """{"text":"Confidential","style":{"bold":true,"fontFamilies":["Georgia"],"fontSizePoints":14.0}}"""),
        };
        var candidates = new List<HeaderFooterText.Candidate> { new(byId[60], "defaultPages", null) };

        var band = HeaderFooterText.ResolveStyled(candidates[0], byId,
            pageNumber: 1, totalPages: 5, defaultFontSize: 12.0);

        Assert.NotNull(band);
        Assert.Equal(TextAlignment.Right, band!.Value.Alignment);
        var run = Assert.Single(band.Value.Runs);
        Assert.Equal("Confidential", run.Text);
        Assert.Equal("Georgia", run.FontFamily);
        Assert.Equal(14.0, run.FontSizePoints);
        Assert.True(run.Bold);
        Assert.False(run.Italic);
    }

    [Fact]
    public void ResolveStyled_falls_back_to_center_and_the_documents_default_size_when_undeclared()
    {
        // No "paragraph" node at all (a header whose textRun is a DIRECT child, the same shape the
        // pre-S12-J fixtures above use) and no fontSizePoints on the run — both must fall back to
        // the band's prior fixed defaults rather than throwing or resolving to zero/garbage.
        var byId = new Dictionary<ulong, RenderNode>
        {
            [70] = NodeWithRawData(70, "header", new ulong[] { 71 }, """{"appliesTo":"defaultPages"}"""),
            [71] = NodeWithRawData(71, "textRun", System.Array.Empty<ulong>(), """{"text":"Plain Header","style":{}}"""),
        };
        var candidates = new List<HeaderFooterText.Candidate> { new(byId[70], "defaultPages", null) };

        var band = HeaderFooterText.ResolveStyled(candidates[0], byId,
            pageNumber: 1, totalPages: 5, defaultFontSize: 11.5);

        Assert.NotNull(band);
        Assert.Equal(TextAlignment.Center, band!.Value.Alignment);
        var run = Assert.Single(band.Value.Runs);
        Assert.Equal("Plain Header", run.Text);
        Assert.Null(run.FontFamily);
        Assert.Equal(11.5, run.FontSizePoints);
        Assert.False(run.Bold);
    }

    [Fact]
    public void ResolveStyled_keeps_a_page_number_fields_own_declared_style_when_substituting_its_text()
    {
        var byId = new Dictionary<ulong, RenderNode>
        {
            [80] = NodeWithRawData(80, "footer", new ulong[] { 81, 82 }, """{"appliesTo":"defaultPages"}"""),
            [81] = NodeWithRawData(81, "textRun", System.Array.Empty<ulong>(), """{"text":"Page ","style":{}}"""),
            [82] = NodeWithRawData(82, "textRun", System.Array.Empty<ulong>(),
                """{"text":"","style":{"bold":true,"fontSizePoints":10.0},"pageNumberField":"page"}"""),
        };
        var candidates = new List<HeaderFooterText.Candidate> { new(byId[80], "defaultPages", null) };

        var band = HeaderFooterText.ResolveStyled(candidates[0], byId,
            pageNumber: 7, totalPages: 42, defaultFontSize: 12.0);

        Assert.NotNull(band);
        Assert.Equal(2, band!.Value.Runs.Count);
        var pageRun = band.Value.Runs[1];
        Assert.Equal("7", pageRun.Text); // substituted, not the empty declared literal
        Assert.True(pageRun.Bold); // the field run's OWN style survives the substitution
        Assert.Equal(10.0, pageRun.FontSizePoints);
    }

    [Fact]
    public void ResolveStyled_returns_null_for_an_entry_with_no_visible_text()
    {
        // A blank first-page header (docx w:titlePg): the plan chose it, and it draws nothing.
        var byId = new Dictionary<ulong, RenderNode>
        {
            [90] = NodeWithRawData(90, "header", System.Array.Empty<ulong>(), """{"appliesTo":"firstPage"}"""),
        };
        var candidates = new List<HeaderFooterText.Candidate> { new(byId[90], "firstPage", null) };

        var band = HeaderFooterText.ResolveStyled(candidates[0], byId,
            pageNumber: 1, totalPages: 5, defaultFontSize: 12.0);

        Assert.Null(band);
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
