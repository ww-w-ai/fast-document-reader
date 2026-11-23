using System;
using System.Collections.Generic;
using System.Globalization;
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
/// G3 (parity audit): run and paragraph formatting an office document states beside its text —
/// highlight, super/subscript, caps and small caps, letter spacing, paragraph shading and borders and
/// the hanging / first-line indent of a list item. The tree fixtures carry the engine's own wire
/// shapes; assertions are on the built blocks and on what the painters ask of the surface.
/// </summary>
public class G3FormattingTests
{
    public G3FormattingTests() => AvaloniaHeadlessSetup.EnsureReady();

    private static RenderTree Parse(string json)
    {
        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(json)!;
        return envelope.Ok!.Value.Deserialize<RenderTree>()!;
    }

    /// <summary>A one-paragraph document: <paramref name="paragraphData"/> is the paragraph's `data`
    /// object, <paramref name="runs"/> its `textRun` data objects.</summary>
    private static RenderTree OneParagraph(string paragraphData, params string[] runs)
    {
        var nodes = new List<string>
        {
            """{ "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} }""",
            $$"""{ "id": 1, "parentId": 0, "children": [{{string.Join(",", runs.Select((_, i) => 10 + i))}}], "type": "paragraph", "data": {{paragraphData}} }""",
        };
        for (var i = 0; i < runs.Length; i++)
        {
            nodes.Add($$"""{ "id": {{10 + i}}, "parentId": 1, "children": [], "type": "textRun", "data": {{runs[i]}} }""");
        }
        return Parse($$"""
        { "ok": { "schemaVersion": 1,
          "document": { "format": "docx", "rootNodeId": 0, "defaultBodyFontSize": 12 },
          "nodes": [ {{string.Join(",\n", nodes)}} ],
          "annotations": { "comments": [], "bookmarks": [] } } }
        """);
    }

    private static FlowBlock OneBlock(string paragraphData, params string[] runs) =>
        FlowDocumentBuilder.Build(OneParagraph(paragraphData, runs)).Single();

    // ---- run formatting -----------------------------------------------------------------------

    [Fact]
    public void All_caps_upper_cases_the_drawn_text()
    {
        var block = OneBlock("""{ "style": {} }""", """{ "text": "Hello, World", "style": { "caps": true } }""");
        Assert.Equal("HELLO, WORLD", string.Concat(block.Runs.Select(r => r.Text)));
    }

    [Fact]
    public void Small_caps_draws_lower_case_letters_as_smaller_capitals()
    {
        var block = OneBlock("""{ "style": {} }""", """{ "text": "Hello", "style": { "smallCaps": true, "fontSizePoints": 10 } }""");

        Assert.Equal(new[] { "H", "ELLO" }, block.Runs.Select(r => r.Text).ToArray());
        Assert.Equal(10, block.Runs[0].FontSizePoints);
        Assert.Equal(10 * FlowDocumentBuilder.SmallCapsScale, block.Runs[1].FontSizePoints, 6);
    }

    [Fact]
    public void A_page_number_field_is_never_re_cased()
    {
        var block = OneBlock("""{ "style": {} }""",
            """{ "text": "page", "style": { "caps": true }, "pageNumberField": "page" }""");
        Assert.Equal("page", block.Runs[0].Text);
    }

    [Fact]
    public void Highlight_and_super_subscript_reach_the_run()
    {
        var block = OneBlock("""{ "style": {} }""",
            """{ "text": "marked", "style": { "background": { "red": 1, "green": 1, "blue": 0, "alpha": 1 } } }""",
            """{ "text": "up", "style": { "verticalPosition": "superscript", "fontSizePoints": 12 } }""",
            """{ "text": "down", "style": { "verticalPosition": "subscript", "fontSizePoints": 12 } }""");

        Assert.Equal(Colors.Yellow, block.Runs[0].Background);
        Assert.Equal(1, block.Runs[1].Script);
        Assert.Equal(-1, block.Runs[2].Script);
        Assert.True(block.Runs[1].FontSizePoints < 12);
    }

    [Fact]
    public void Letter_spacing_is_the_character_weighted_mean_of_the_runs()
    {
        var block = OneBlock("""{ "style": {} }""",
            """{ "text": "aaaaaaaaaa", "style": { "letterSpacingPercent": -5, "fontSizePoints": 12 } }""",
            """{ "text": "bbbbbbbbbb", "style": { "fontSizePoints": 12 } }""");

        // Ten characters at -5% of 12pt (-0.6pt) and ten at none: -0.3pt per character on average.
        Assert.Equal(-0.3, block.LetterSpacingPoints, 6);
    }

    [Fact]
    public void A_condensed_paragraph_lays_out_narrower_than_the_same_text_without_spacing()
    {
        const string text = "A condensed paragraph of ordinary running text";
        var plain = OneBlock("""{ "style": {} }""", $$"""{ "text": "{{text}}", "style": { "fontSizePoints": 12 } }""");
        var tight = OneBlock("""{ "style": {} }""", $$"""{ "text": "{{text}}", "style": { "fontSizePoints": 12, "letterSpacingPercent": -10 } }""");

        var plainWidth = PageLayout.BuildPointsTextLayout(plain, 10_000)!.WidthIncludingTrailingWhitespace;
        var tightWidth = PageLayout.BuildPointsTextLayout(tight, 10_000)!.WidthIncludingTrailingWhitespace;
        Assert.True(tightWidth < plainWidth - text.Length * 0.5,
            $"expected about {text.Length * 1.2:F0}pt narrower; plain={plainWidth:F1} tight={tightWidth:F1}");
    }

    // ---- paragraph formatting -----------------------------------------------------------------

    [Fact]
    public void Paragraph_borders_keep_only_the_drawn_edges_in_the_first_drawn_edges_rule()
    {
        var block = OneBlock("""
            { "style": { "borders": {
                "top":    { "kind": "drawn", "value": { "widthPoints": 1.5, "color": { "red": 1, "green": 0, "blue": 0, "alpha": 1 }, "style": "solid" } },
                "bottom": { "kind": "drawn", "value": { "widthPoints": 3, "color": { "red": 0, "green": 0, "blue": 1, "alpha": 1 }, "style": "solid" } },
                "left":   { "kind": "suppressed" } } } }
            """, """{ "text": "boxed", "style": {} }""");

        var border = block.Border!;
        Assert.True(border.Top);
        Assert.True(border.Bottom);
        Assert.False(border.Left);   // suppressed is not drawn
        Assert.False(border.Right);  // unmentioned is not drawn
        Assert.Equal(Colors.Red, border.Color); // the first drawn edge sets the rule, as on macOS
        Assert.Equal(1.5, border.WidthPoints);
    }

    [Fact]
    public void A_paragraph_with_no_drawn_edge_has_no_border()
    {
        var block = OneBlock("""{ "style": { "borders": { "left": { "kind": "suppressed" } } } }""",
            """{ "text": "plain", "style": {} }""");
        Assert.Null(block.Border);
    }

    [Fact]
    public void Paragraph_shading_becomes_the_blocks_fill()
    {
        var block = OneBlock("""{ "style": { "shading": { "red": 0.8, "green": 0.9, "blue": 1, "alpha": 1 } } }""",
            """{ "text": "tinted", "style": {} }""");
        Assert.Equal(Color.FromRgb(204, 229, 255), block.ShadingColor);
    }

    [Fact]
    public void A_hanging_indent_outdents_the_first_line_and_a_first_line_indent_pushes_it_in()
    {
        var hanging = OneBlock("""{ "style": { "headIndent": 36, "hangingIndent": 18 } }""", """{ "text": "item", "style": {} }""");
        Assert.Equal(36, hanging.IndentPoints);
        Assert.Equal(-18, hanging.FirstLineOffsetPoints);

        var indented = OneBlock("""{ "style": { "firstLineIndent": 10 } }""", """{ "text": "para", "style": {} }""");
        Assert.Equal(10, indented.FirstLineOffsetPoints);

        // An outdent never passes the column's own left edge.
        var clamped = OneBlock("""{ "style": { "headIndent": 6, "hangingIndent": 40 } }""", """{ "text": "item", "style": {} }""");
        Assert.Equal(-6, clamped.FirstLineOffsetPoints);
    }

    // ---- painting -----------------------------------------------------------------------------

    private sealed class Recorder : IPageCanvas
    {
        public readonly List<(Rect Rect, Color? Fill)> Rects = new();
        public readonly List<(Point A, Point B, Color Color, double Width)> Lines = new();
        public readonly List<Point> TextLineOrigins = new();
        public void DrawRect(Rect rect, Color? fill, Color? stroke, double strokeThicknessPx) => Rects.Add((rect, fill));
        public void DrawLine(Point a, Point b, Color color, double thicknessPx) => Lines.Add((a, b, color, thicknessPx));
        public void DrawImage(global::Avalonia.Media.Imaging.Bitmap bitmap, byte[]? sourceBytes, string? sourceMimeType, Rect destRect) { }
        public void DrawTextLayout(global::Avalonia.Media.TextFormatting.TextLayout layout, Point origin) { }
        public void DrawTextLine(global::Avalonia.Media.TextFormatting.TextLine line, Point origin) => TextLineOrigins.Add(origin);
    }

    [Fact]
    public void The_decor_fills_the_whole_column_and_rules_only_the_drawn_edges_at_the_paragraphs_indent()
    {
        var block = new FlowBlock
        {
            Kind = FlowBlockKind.Text,
            IndentPoints = 30,
            ShadingColor = Colors.LightYellow,
            Border = new ParagraphBorder(Colors.Red, 2, Top: true, Right: false, Bottom: true, Left: false),
        };
        var canvas = new Recorder();
        const double scale = 96.0 / 72.0;

        ParagraphDecor.Draw(canvas, block, columnLeft: 24, columnWidth: 600, top: 100, height: 50, scale);

        var fill = Assert.Single(canvas.Rects);
        Assert.Equal(new Rect(24, 100, 600, 50), fill.Rect);
        Assert.Equal(Colors.LightYellow, fill.Fill);
        Assert.Equal(2, canvas.Lines.Count); // top and bottom only
        Assert.All(canvas.Lines, l => Assert.Equal(Colors.Red, l.Color));
        // The box starts at the paragraph's indent (24 + 30pt), not at the column edge.
        Assert.Equal(24 + 30 * scale + 2 * scale / 2, canvas.Lines[0].A.X, 3);
    }

    private const string FlowTree = """
        { "ok": { "schemaVersion": 1,
          "document": { "format": "docx", "rootNodeId": 0, "defaultBodyFontSize": 12 },
          "nodes": [
            { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
            { "id": 1, "parentId": 0, "children": [2], "type": "paragraph",
              "data": { "style": { "headIndent": 36, "hangingIndent": 24,
                                   "shading": { "red": 1, "green": 0.9, "blue": 0.6, "alpha": 1 },
                                   "borders": { "bottom": { "kind": "drawn", "value": { "widthPoints": 1, "style": "solid" } } } } } },
            { "id": 2, "parentId": 1, "children": [], "type": "textRun",
              "data": { "text": "A hanging list entry whose text is long enough to wrap onto several lines in a narrow window, so that the first line can start further left than the lines under it.", "style": { "fontSizePoints": 12 } } }
          ],
          "annotations": { "comments": [], "bookmarks": [] } } }
        """;

    [Fact]
    public void Flow_mode_paints_the_fill_and_rule_and_moves_only_the_first_line()
    {
        var view = new FlowDocumentView();
        view.SetTree(Parse(FlowTree));
        var window = new global::Avalonia.Controls.Window { Width = 360, Height = 600, Content = view };
        window.Show();
        window.CaptureRenderedFrame();

        var renderCore = typeof(FlowDocumentView).GetMethod("RenderCore",
            System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!;
        var canvas = new Recorder();
        renderCore.Invoke(view, new object[] { canvas });

        Assert.Contains(canvas.Rects, r => r.Fill == Color.FromRgb(255, 229, 153));
        Assert.Contains(canvas.Lines, l => l.A.Y == l.B.Y && l.A.Y > 0); // the bottom rule
        Assert.True(canvas.TextLineOrigins.Count >= 3, "the paragraph wraps onto several lines");
        var first = canvas.TextLineOrigins[0].X;
        var second = canvas.TextLineOrigins[1].X;
        Assert.Equal(24 * 96.0 / 72.0, second - first, 2); // the first line is outdented by the hanging indent
    }
}
