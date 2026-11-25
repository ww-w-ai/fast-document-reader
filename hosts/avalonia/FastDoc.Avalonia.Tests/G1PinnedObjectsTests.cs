using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using Avalonia;
using Avalonia.Headless;
using Avalonia.Media;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Paging;
using FastDoc.Avalonia.Printing;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// G1 (parity audit): the elements that used to VANISH on the Windows/Linux host — objects the
/// document anchors off the flow (seals, stamps, text boxes), the 바탕쪽 master page with its pinned
/// page number, read-only form controls, and the page-number restart / hide a document states per
/// paragraph. The tree fixtures here are the engine's own wire shapes (a vector, a flow text box
/// and a master page), asserted through the same builder / painter pair a real document goes
/// through, so a regression in either half reddens by name.
/// </summary>
public class G1PinnedObjectsTests
{
    public G1PinnedObjectsTests() => AvaloniaHeadlessSetup.EnsureReady();

    /// <summary>Records what a pinned painter asked of the surface, in order.</summary>
    private sealed class RecordingCanvas : IPageCanvas
    {
        public readonly List<string> Calls = new();
        public readonly List<Rect> Clips = new();
        public readonly List<(IReadOnlyList<VectorSegment> Segments, Color? Fill, Color? Stroke, double Width)> Paths = new();
        public readonly List<Rect> Rects = new();
        public readonly List<string> Texts = new();

        public void DrawRect(Rect rect, Color? fill, Color? stroke, double strokeThicknessPx) { Calls.Add("rect"); Rects.Add(rect); }
        public void DrawLine(Point a, Point b, Color color, double thicknessPx) => Calls.Add("line");
        public void DrawImage(global::Avalonia.Media.Imaging.Bitmap bitmap, byte[]? sourceBytes, string? sourceMimeType, Rect destRect) => Calls.Add("image");
        public void DrawTextLayout(global::Avalonia.Media.TextFormatting.TextLayout layout, Point origin) => Calls.Add("layout");
        public void DrawTextLine(global::Avalonia.Media.TextFormatting.TextLine line, Point origin)
        {
            Calls.Add("textline");
            Texts.Add(string.Concat(line.TextRuns.Select(r => r.Text.ToString())));
        }
        public void PushClip(Rect rect) { Calls.Add("push"); Clips.Add(rect); }
        public void PopClip() => Calls.Add("pop");
        public void DrawVectorPath(IReadOnlyList<VectorSegment> segments, Color? fill, Color? stroke, double strokeWidthPx, string strokeStyle)
        {
            Calls.Add("path");
            Paths.Add((segments, fill, stroke, strokeWidthPx));
        }
    }

    // node 0 document -> 1 section -> [2 flow(3 paragraph 4 run), 5 anchoredObject -> content 6 vector,
    // 7 anchoredObject -> content 8 flow(9 paragraph 10 run "stamp"), 11 masterPage -> object 12 -> content 13 flow(14 paragraph
    // 15 run page-number field), 16 masterPage]. The anchored objects ride carrier paragraph 3.
    private const string Tree = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": { "format": "hwp", "rootNodeId": 0, "defaultBodyFontSize": 12,
          "documentPaper": { "widthPoints": 600, "heightPoints": 800,
            "margins": { "top": 50, "right": 50, "bottom": 50, "left": 50 } } },
        "nodes": [
          { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
          { "id": 1, "parentId": 0, "children": [2, 5, 7, 11, 16], "type": "section", "data": { "hidesMasterPage": false } },
          { "id": 2, "parentId": 1, "children": [3], "type": "flow", "data": {} },
          { "id": 3, "parentId": 2, "children": [4], "type": "paragraph", "data": { "style": {} } },
          { "id": 4, "parentId": 3, "children": [], "type": "textRun", "data": { "text": "carrier", "style": {} } },
          { "id": 5, "parentId": 1, "children": [6], "type": "anchoredObject",
            "data": { "x": 100, "y": 200, "width": 40, "height": 20, "anchoredToId": 3, "contentId": 6 } },
          { "id": 6, "parentId": 5, "children": [], "type": "vector",
            "data": { "intrinsicSize": { "width": 40, "height": 20 }, "paths": [ { "commands": [
              { "command": "moveTo", "values": [0, 0] }, { "command": "lineTo", "values": [40, 0] },
              { "command": "lineTo", "values": [40, 20] }, { "command": "close", "values": [] } ],
              "stroke": { "widthPoints": 1, "color": { "red": 1, "green": 0, "blue": 0, "alpha": 1 }, "style": "solid" },
              "fill": null, "arrowStart": false, "arrowEnd": true } ] } },
          { "id": 7, "parentId": 1, "children": [8], "type": "anchoredObject",
            "data": { "x": 60, "width": 80, "height": 30, "paragraphAnchor": { "align": "top", "offset": 5 },
                      "anchoredToId": 3, "contentId": 8 } },
          { "id": 8, "parentId": 7, "children": [9], "type": "flow", "data": {} },
          { "id": 9, "parentId": 8, "children": [10], "type": "paragraph", "data": { "style": {} } },
          { "id": 10, "parentId": 9, "children": [], "type": "textRun", "data": { "text": "stamp", "style": {} } },
          { "id": 11, "parentId": 1, "children": [12], "type": "masterPage", "data": { "appliesTo": "defaultPages", "objectIds": [12] } },
          { "id": 12, "parentId": 11, "children": [13], "type": "masterPageObject",
            "data": { "x": 500, "y": 740, "width": 40, "height": 20, "contentId": 13 } },
          { "id": 13, "parentId": 12, "children": [14], "type": "flow", "data": {} },
          { "id": 14, "parentId": 13, "children": [15], "type": "paragraph", "data": { "style": { "alignment": "right" } } },
          { "id": 15, "parentId": 14, "children": [], "type": "textRun", "data": { "text": "1", "style": {}, "pageNumberField": "page" } },
          { "id": 16, "parentId": 1, "children": [], "type": "masterPage", "data": { "appliesTo": "evenPages", "objectIds": [] } }
        ],
        "annotations": { "comments": [], "bookmarks": [] }
      }
    }
    """;

    private static RenderTree Parse(string json)
    {
        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(json)!;
        return envelope.Ok!.Value.Deserialize<RenderTree>()!;
    }

    [Fact]
    public void Anchored_objects_and_master_pages_are_read_off_the_section()
    {
        var tree = Parse(Tree);
        var blocks = FlowDocumentBuilder.Build(tree);
        var set = PinnedObjectSet.Build(tree, blocks);

        Assert.Equal(2, set.Anchored.Count);
        Assert.All(set.Anchored, o => Assert.Equal(0, o.AnchorBlockIndex)); // both ride carrier paragraph 3
        Assert.IsType<PinnedVector>(set.Anchored[0].Content);
        Assert.IsType<PinnedText>(set.Anchored[1].Content);
        Assert.Equal(200, set.Anchored[0].Y);
        Assert.NotNull(set.Anchored[1].Anchor);

        Assert.Equal(2, set.Masters.Count);
        Assert.Equal("defaultPages", set.Masters[0].AppliesTo);
        Assert.Single(set.Masters[0].Objects);
        Assert.Equal(-1, set.Masters[0].Objects[0].AnchorBlockIndex);
    }

    [Fact]
    public void The_anchored_content_flow_does_not_leak_into_the_body_flow()
    {
        var tree = Parse(Tree);
        var blocks = FlowDocumentBuilder.Build(tree);
        // Only the carrier paragraph is a body block — the seal's text and the page-number box live in pinned objects.
        Assert.Single(blocks);
        Assert.Equal("carrier", string.Concat(blocks[0].Runs.Select(r => r.Text)));
    }

    [Fact]
    public void A_page_number_field_run_is_marked_as_a_live_field()
    {
        var tree = Parse(Tree);
        var set = PinnedObjectSet.Build(tree, FlowDocumentBuilder.Build(tree));
        var text = Assert.IsType<PinnedText>(set.Masters[0].Objects[0].Content);
        Assert.Equal(1, text.Blocks[0].Runs[0].PageField);
    }

    [Fact]
    public void The_painter_draws_a_vector_clipped_to_its_sheet_with_an_arrow_head()
    {
        var tree = Parse(Tree);
        var set = PinnedObjectSet.Build(tree, FlowDocumentBuilder.Build(tree));
        var painter = new PinnedObjectPainter(new ImageBlockRenderer());
        var canvas = new RecordingCanvas();
        var sheet = new Rect(10, 20, 800, 1066.67);

        painter.Draw(canvas, set.Anchored[0], topPoints: 200, sheet, zoomFactor: 1.0, shownPage: 1, totalPages: 1, hidePageNumber: false);

        Assert.Equal(new[] { "push", "path", "path", "pop" }, canvas.Calls); // body path, then the arrow head
        Assert.Equal(sheet, canvas.Clips[0]);
        var body = canvas.Paths[0];
        // object x 100pt, top 200pt at 96/72 px per point, from the sheet's own origin.
        var first = body.Segments[0];
        Assert.Equal('M', first.Op);
        Assert.Equal(10 + 100 * 96.0 / 72.0, first.X1, 3);
        Assert.Equal(20 + 200 * 96.0 / 72.0, first.Y1, 3);
        Assert.Equal(Colors.Red, body.Stroke);
        Assert.Null(body.Fill);
        Assert.Equal(Colors.Red, canvas.Paths[1].Fill); // the arrow head is filled in the stroke's colour
    }

    [Fact]
    public void The_painter_substitutes_this_sheets_page_number_and_blanks_a_vetoed_one()
    {
        var tree = Parse(Tree);
        var set = PinnedObjectSet.Build(tree, FlowDocumentBuilder.Build(tree));
        var painter = new PinnedObjectPainter(new ImageBlockRenderer());
        var number = set.Masters[0].Objects[0];

        var shown = new RecordingCanvas();
        painter.Draw(shown, number, number.Y, new Rect(0, 0, 800, 1066), 1.0, shownPage: 7, totalPages: 12, hidePageNumber: false);
        Assert.Contains("7", shown.Texts);

        var vetoed = new RecordingCanvas();
        painter.Draw(vetoed, number, number.Y, new Rect(0, 0, 800, 1066), 1.0, shownPage: 7, totalPages: 12, hidePageNumber: true);
        Assert.DoesNotContain("7", vetoed.Texts);
        Assert.DoesNotContain("1", vetoed.Texts); // the field's parse-time literal never shows either
    }

    [Fact]
    public void Flow_mode_draws_an_anchored_drawing_beside_its_carrier_block()
    {
        var tree = Parse(Tree);
        var view = new FlowDocumentView();
        view.SetTree(tree);
        var window = new global::Avalonia.Controls.Window { Width = 800, Height = 700, Content = view };
        window.Show();
        window.CaptureRenderedFrame(); // settle once

        var renderCore = typeof(FlowDocumentView).GetMethod("RenderCore",
            System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!;
        var canvas = new RecordingCanvas();
        renderCore.Invoke(view, new object[] { canvas });

        // The vector (stroked red, arrow head) and the stamp's text box are both drawn; the master
        // page's number box is NOT (flow mode has no sheet for a master page to be pinned to).
        Assert.Equal(2, canvas.Paths.Count);
        Assert.Contains("stamp", canvas.Texts);
        Assert.DoesNotContain("1", canvas.Texts);
        // Flow mode has no sheet to clip to.
        Assert.DoesNotContain("push", canvas.Calls);
    }

    [Fact]
    public void The_pdf_surface_strokes_fills_and_clips_a_vector_path()
    {
        using var bitmap = new SkiaSharp.SKBitmap(200, 200);
        using var skCanvas = new SkiaSharp.SKCanvas(bitmap);
        skCanvas.Clear(SkiaSharp.SKColors.White);
        var surface = new SkiaPageCanvas(skCanvas, SkiaSharp.SKTypeface.Default); // scales px -> pt by 72/96
        var square = new[]
        {
            new VectorSegment('M', 40, 40), new VectorSegment('L', 160, 40), new VectorSegment('L', 160, 160),
            new VectorSegment('L', 40, 160), new VectorSegment('Z'),
        };
        surface.DrawVectorPath(square, Colors.Blue, Colors.Red, 8, "solid");
        // Canvas units are points: 96px design -> *0.75. The fill covers the middle, the stroke the edge.
        Assert.Equal(SkiaSharp.SKColors.Blue, bitmap.GetPixel(75, 75));
        Assert.Equal(SkiaSharp.SKColors.Red, bitmap.GetPixel(30, 75));

        surface.PushClip(new Rect(0, 0, 50, 50));
        surface.DrawVectorPath(square, Colors.Green, null, 0, "solid");
        surface.PopClip();
        Assert.Equal(SkiaSharp.SKColors.Blue, bitmap.GetPixel(75, 75)); // the clip kept the green out of the centre
    }

    [Fact]
    public void A_paragraph_anchor_measures_from_the_edge_the_document_named()
    {
        var top = new ParagraphAnchorWire { Align = "top", Offset = 5 };
        var center = new ParagraphAnchorWire { Align = "center", Offset = 5 };
        var bottom = new ParagraphAnchorWire { Align = "bottom", Offset = 5 };
        Assert.Equal(105, top.Top(lineTop: 100, lineHeight: 20, objectHeight: 10));
        Assert.Equal(110, center.Top(lineTop: 100, lineHeight: 20, objectHeight: 10));
        Assert.Equal(105, bottom.Top(lineTop: 100, lineHeight: 20, objectHeight: 10));
    }

    [Fact]
    public void Page_number_markers_are_read_from_the_paragraph_pagination_wire()
    {
        const string json = """
        {
          "ok": { "schemaVersion": 1,
            "document": { "format": "hwp", "rootNodeId": 0, "defaultBodyFontSize": 12 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1, 2], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [], "type": "paragraph",
                "data": { "style": {}, "pagination": { "hidesPageNumber": true } } },
              { "id": 2, "parentId": 0, "children": [], "type": "paragraph",
                "data": { "style": {}, "pagination": { "pageNumberRestart": 7 } } }
            ],
            "annotations": { "comments": [], "bookmarks": [] } }
        }
        """;
        var markers = BlockPageMarkers.Compute(Parse(json));
        Assert.Equal(new[] { true, false }, markers.HidesPageNumber);
        Assert.Equal(new long?[] { null, 7 }, markers.PageNumberRestart);
    }

    [Fact]
    public void A_standalone_form_control_node_shows_its_state_and_caption()
    {
        const string json = """
        {
          "ok": { "schemaVersion": 1,
            "document": { "format": "hwp", "rootNodeId": 0, "defaultBodyFontSize": 12 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1, 2], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [], "type": "formControl",
                "data": { "kind": "checkBox", "caption": "Agree", "text": "", "value": 1, "enabled": true } },
              { "id": 2, "parentId": 0, "children": [], "type": "formControl",
                "data": { "kind": "radioButton", "caption": "Option", "text": "", "value": 0, "enabled": true } }
            ],
            "annotations": { "comments": [], "bookmarks": [] } }
        }
        """;
        var tree = Parse(json);
        var blocks = FlowDocumentBuilder.Build(tree);
        Assert.Equal(2, blocks.Count);
        Assert.Equal("[x] Agree", blocks[0].Runs[0].Text);
        Assert.Equal("( ) Option", blocks[1].Runs[0].Text);
        // The page-geometry marker walk emits the same two blocks, or PageLayout's indices drift.
        Assert.Equal(2, BlockPageMarkers.Compute(tree).NodeId.Length);
    }

    [Fact]
    public void An_inline_form_control_run_keeps_the_text_the_engine_gave_it()
    {
        const string json = """
        {
          "ok": { "schemaVersion": 1,
            "document": { "format": "hwp", "rootNodeId": 0, "defaultBodyFontSize": 12 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [2], "type": "paragraph", "data": { "style": {} } },
              { "id": 2, "parentId": 1, "children": [], "type": "textRun",
                "data": { "text": "[x] Box", "style": {},
                          "formControl": { "kind": "checkBox", "caption": "Box", "text": "", "value": 1, "enabled": true } } }
            ],
            "annotations": { "comments": [], "bookmarks": [] } }
        }
        """;
        var tree = Parse(json);
        Assert.Equal("[x] Box", FlowDocumentBuilder.Build(tree)[0].Runs[0].Text);
        Assert.Equal("checkBox", tree.Nodes[2].AsTextRun!.FormControl!.Kind);
    }
}
