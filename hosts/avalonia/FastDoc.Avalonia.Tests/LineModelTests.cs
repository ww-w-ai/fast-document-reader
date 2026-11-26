using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using Avalonia.Media;
using FastDoc.Avalonia.Native;
using FastDoc.Avalonia.Paging;
using FastDoc.Avalonia.Rendering;
using Xunit;

namespace FastDoc.Avalonia.Tests;

/// <summary>S3 of docs/plans/pagination-to-engine.md: the line model (the engine decides what the
/// document's rules make of the line boxes this host measures) and the measurement port's second
/// primitive (the line boxes themselves). The port payloads here are the ones
/// RustEngineMeasureLinesTests builds on macOS, so the two hosts are asked the same question.</summary>
public sealed class LineModelTests
{
    public LineModelTests() => AvaloniaHeadlessSetup.EnsureReady();

    private static ParagraphFactsIn Hwp(double[] lines, double floor, double size, bool blank = false) => new()
    {
        Lines = lines, Blank = blank, Rule = new LineHeightRule(LineHeightMode.AtLeast, floor), HasRule = true,
        CharSize = size, LineSpacingBelow = true,
    };

    [Fact]
    public void An_hwp_paragraph_stands_at_its_floor_whatever_the_faces_natural_box_and_hangs_the_gap_past_a_page()
    {
        var (paragraphs, _) = LineModelClient.Solve(null, new[] { Hwp(new[] { 14.5, 14.5 }, 16, 10) }, Array.Empty<TableFactsIn>());
        Assert.Equal(new[] { 16.0, 16.0 }, paragraphs[0].Heights);
        Assert.Equal(6.0, paragraphs[0].Trailing);
    }

    [Fact]
    public void A_plain_floor_still_follows_a_taller_face()
    {
        var plain = new ParagraphFactsIn
        {
            Lines = new[] { 18.0 }, Rule = new LineHeightRule(LineHeightMode.AtLeast, 16), HasRule = true, CharSize = 10,
        };
        var (paragraphs, _) = LineModelClient.Solve(null, new[] { plain }, Array.Empty<TableFactsIn>());
        Assert.Equal(new[] { 18.0 }, paragraphs[0].Heights);
        Assert.Equal(0.0, paragraphs[0].Trailing);
    }

    [Fact]
    public void A_table_row_is_its_cells_lines_under_the_documents_rules_plus_padding()
    {
        var oneLine = new TableFactsIn
        {
            RowCount = 1, EmptyLine = 10, RowPadding = 4,
            Cells = { new CellFactsIn { Row = 0, VPadding = 4, Items = { new CellItemIn { Paragraphs = new() { Hwp(new[] { 14.5 }, 20, 10) } } } } },
        };
        TableFactsIn Two(bool breaks) => new()
        {
            RowCount = 1, EmptyLine = 10, RowPadding = 4, DropsTrailingGap = breaks,
            Cells = { new CellFactsIn { Row = 0, VPadding = 4, Items = { new CellItemIn { Paragraphs = new() { Hwp(new[] { 14.5 }, 20, 10), Hwp(new[] { 14.5 }, 20, 10) } } } } },
        };
        var (_, tables) = LineModelClient.Solve(null, Array.Empty<ParagraphFactsIn>(), new[] { oneLine, Two(true), Two(false) });
        // The cell's only paragraph hands its last gap back: one line of 10, not 20.
        Assert.Equal(new[] { 14.0 }, tables[0].RowHeights);
        // Two paragraphs in a table that breaks across pages: the first keeps its full pitch, the last gives it back.
        Assert.Equal(new[] { 34.0 }, tables[1].RowHeights);
        Assert.Equal(new[] { 0.0, 20.0 }, tables[1].Cells[0].Items[0].Paragraphs![0].Tops.Concat(tables[1].Cells[0].Items[0].Paragraphs![1].Tops).ToArray());
        // In a table that does not, both keep it.
        Assert.Equal(new[] { 44.0 }, tables[2].RowHeights);
    }

    [Fact]
    public void An_empty_hwp_cell_paragraph_is_one_line_of_its_own_size()
    {
        var table = new TableFactsIn
        {
            RowCount = 1, EmptyLine = 12, RowPadding = 4,
            Cells = { new CellFactsIn { Row = 0, VPadding = 0, Items = { new CellItemIn { Paragraphs = new() { Hwp(new[] { 17.4 }, 20, 9, blank: true) } } } } },
        };
        var (_, tables) = LineModelClient.Solve(null, Array.Empty<ParagraphFactsIn>(), new[] { table });
        Assert.Equal(new[] { 9.0 }, tables[0].RowHeights);
    }

    [Fact]
    public void The_cell_rules_reach_the_rows_TableGridRenderer_measures()
    {
        // A one-line HWP cell at 200% of a 10pt run: the document asks for a 20pt line, the cell is
        // its only paragraph, so the line is 10pt — and the row is that plus the default 7pt padding
        // on both edges, plus the undeclared 0.75pt rule above and below (a whole point each, as
        // AppKit lays it out). A natural-box measurement (Noto ~14.5pt) would not be 26pt.
        var run = new FlowRun("한글", null, 10, false, false, false, false, Colors.Black);
        var paragraph = new FlowBlock
        {
            Kind = FlowBlockKind.Text, Runs = new() { run },
            LineHeight = new LineHeightRule(LineHeightMode.AtLeast, 20), LineSpacingBelow = true,
        };
        var cell = new TableGridCell { Row = 0, Column = 0, Content = new() { paragraph } };
        var model = new TableGridModel
        {
            ColumnCount = 1, ColumnWidthRatios = new() { 1.0 },
            Rows = new() { new TableGridRow { Row = 0, Cells = new() { cell } } },
        };
        var heights = TableGridRenderer.MeasureRowHeightsPoints(model, 200);
        Assert.Equal(26.0, heights[0], precision: 3);
    }

    private static TableGridModel OneCell(TableGridCell cell, bool breaksBetweenRows = false) => new()
    {
        ColumnCount = 1, ColumnWidthRatios = new() { 1.0 }, LastLineKeepsNoGap = breaksBetweenRows,
        Rows = new() { new TableGridRow { Row = 0, Cells = new() { cell } } },
    };

    private static FlowBlock HwpCellParagraph(string text, double size = 10) => new()
    {
        Kind = FlowBlockKind.Text, Runs = new() { new FlowRun(text, null, size, false, false, false, false, Colors.Black) },
        LineHeight = new LineHeightRule(LineHeightMode.AtLeast, 2 * size), LineSpacingBelow = true,
    };

    [Fact]
    public void A_second_paragraph_in_the_cell_keeps_its_gap_unless_the_table_declares_it_breaks_between_rows()
    {
        // macOS `cellContent(lastLineKeepsNoGap:)`: the TABLE's `pageBreakPolicy == atRowBoundary`
        // decides it — a nested table has its own — never the reader's page-split preference.
        var cell = new TableGridCell { Row = 0, Column = 0, Content = new() { HwpCellParagraph("한"), HwpCellParagraph("글") } };
        Assert.Equal(20 + 20 + 14 + 2, TableGridRenderer.MeasureRowHeightsPoints(OneCell(cell), 200)[0], precision: 3);
        var breaking = new TableGridCell { Row = 0, Column = 0, Content = new() { HwpCellParagraph("한"), HwpCellParagraph("글") } };
        Assert.Equal(20 + 10 + 14 + 2, TableGridRenderer.MeasureRowHeightsPoints(OneCell(breaking, breaksBetweenRows: true), 200)[0], precision: 3);
    }

    [Fact]
    public void A_table_takes_its_last_line_rule_from_its_own_page_break_policy()
    {
        Assert.True(FlowDocumentBuilder.Build(OneTableTree("atRowBoundary"))[0].Table!.LastLineKeepsNoGap);
        Assert.False(FlowDocumentBuilder.Build(OneTableTree("anywhere"))[0].Table!.LastLineKeepsNoGap);
        Assert.False(FlowDocumentBuilder.Build(OneTableTree(null))[0].Table!.LastLineKeepsNoGap);
    }

    private static Model.RenderTree OneTableTree(string? policy)
    {
        var style = policy is null ? "{}" : $"{{ \"pageBreakPolicy\": \"{policy}\" }}";
        var json = $$"""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "hwp", "rootNodeId": 0 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [2], "type": "table", "data": { "gridWidths": [1], "style": {{style}} } },
              { "id": 2, "parentId": 1, "children": [3], "type": "tableRow", "data": { "row": 0 } },
              { "id": 3, "parentId": 2, "children": [4], "type": "tableCell", "data": { "row": 0, "column": 0, "rowSpan": 1, "columnSpan": 1 } },
              { "id": 4, "parentId": 3, "children": [5], "type": "paragraph", "data": { "style": {} } },
              { "id": 5, "parentId": 4, "children": [], "type": "textRun", "data": { "text": "셀", "style": {} } }
            ]
          }
        }
        """;
        return Parse(json);
    }

    private static Model.RenderTree Parse(string json) =>
        JsonSerializer.Deserialize<Model.RenderTreeEnvelope>(json)!.Ok!.Value.Deserialize<Model.RenderTree>()!;

    [Fact]
    public void A_list_item_in_a_cell_takes_none_of_its_paragraph_format()
    {
        // macOS `cellContent` appends a cell's list item with no format: no declared line height,
        // spacing or indents, so no cell line model — only where it may break a Korean line. The same
        // item at the top of the document keeps its format.
        const string item = """{ "level": 0, "ordered": false, "marker": "-", "style": { "lineHeight": { "mode": "atLeast", "value": 20.8 }, "lineSpacingBelow": true, "spacingBefore": 4, "spacingAfter": 6, "headIndent": 12, "tailIndent": 9, "eastAsianLineBreak": "word" } }""";
        var tree = Parse($$"""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "hwp", "rootNodeId": 0 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1, 7], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [2], "type": "table", "data": { "gridWidths": [1], "style": {} } },
              { "id": 2, "parentId": 1, "children": [3], "type": "tableRow", "data": { "row": 0 } },
              { "id": 3, "parentId": 2, "children": [4], "type": "tableCell", "data": { "row": 0, "column": 0, "rowSpan": 1, "columnSpan": 1 } },
              { "id": 4, "parentId": 3, "children": [5], "type": "listItem", "data": {{item}} },
              { "id": 5, "parentId": 4, "children": [], "type": "textRun", "data": { "text": "셀 항목", "style": {} } },
              { "id": 7, "parentId": 0, "children": [8], "type": "listItem", "data": {{item}} },
              { "id": 8, "parentId": 7, "children": [], "type": "textRun", "data": { "text": "본문 항목", "style": {} } }
            ]
          }
        }
        """);
        var blocks = FlowDocumentBuilder.Build(tree);
        var inCell = blocks[0].Table!.Rows[0].Cells[0].Content.Single(b => b.Kind == FlowBlockKind.Text);
        Assert.Equal(LineHeightRule.Default, inCell.LineHeight);
        Assert.False(inCell.LineSpacingBelow);
        Assert.Equal(0, inCell.SpacingBeforePoints);
        Assert.Equal(0, inCell.SpacingAfterPoints);
        Assert.Equal(0, inCell.TailIndentPoints);
        Assert.True(inCell.HangulWordBreak);
        var body = blocks.Last(b => b.Kind == FlowBlockKind.Text);
        Assert.True(body.LineSpacingBelow);
        Assert.Equal(9, body.TailIndentPoints);
        Assert.Equal(6, body.SpacingAfterPoints);
    }

    [Fact]
    public void A_text_less_run_does_not_size_the_paragraph_it_sits_in()
    {
        // macOS `applyLineModel` reads the fonts of the paragraph's CHARACTERS: an empty 24pt run in
        // front of 12pt text leaves the paragraph a 12pt one, so its 15.6pt floor is HWP's pitch
        // (a one-line cell hands the gap back: a 12pt line), not a floor under a 24pt line.
        var mixed = new FlowBlock
        {
            Kind = FlowBlockKind.Text,
            Runs = new() { new FlowRun("", null, 24, false, false, false, false, Colors.Black), new FlowRun("ㅇ", null, 12, false, false, false, false, Colors.Black) },
            LineHeight = new LineHeightRule(LineHeightMode.AtLeast, 15.6), LineSpacingBelow = true,
        };
        Assert.Equal(12.0, mixed.CharSizePoints);
        var cell = new TableGridCell { Row = 0, Column = 0, Content = new() { mixed } };
        Assert.Equal(12 + 14 + 2, TableGridRenderer.MeasureRowHeightsPoints(OneCell(cell), 200)[0], precision: 3);
        // A blank paragraph still takes its largest run's size.
        var blank = new FlowBlock { Kind = FlowBlockKind.Text, Runs = new() { new FlowRun("", null, 24, false, false, false, false, Colors.Black) } };
        Assert.Equal(24.0, blank.CharSizePoints);
    }

    [Fact]
    public void A_cell_paragraph_wraps_short_of_its_tail_indent_unless_head_and_tail_leave_no_width()
    {
        // TextKit's negative `tailIndent` narrows a cell line (the 편람's 「국세청」 seal: 58pt cell,
        // 5 + 5pt indents, three 16.3pt syllables wrap). An indent pair wider than the cell is not the
        // cell's (macOS `TableBlockBuilder.build` drops it): the text lays out at the full width.
        FlowBlock Indented(double head, double tail) => new()
        {
            Kind = FlowBlockKind.Text, Runs = new() { new FlowRun("한글한글한글한글", null, 10, false, false, false, false, Colors.Black) },
            LineHeight = new LineHeightRule(LineHeightMode.AtLeast, 20), LineSpacingBelow = true,
            IndentPoints = head, TailIndentPoints = tail,
        };
        double Lines(FlowBlock block) =>
            TableGridRenderer.FlowFacts(OneCell(new TableGridCell { Row = 0, Column = 0, Content = new() { block } }), 200, null)[0][0].Lines.Length;
        var natural = Lines(Indented(0, 0));
        var tailed = Lines(Indented(0, 150));
        Assert.True(tailed > natural, $"a 150pt tail indent wraps more ({tailed} vs {natural})");
        Assert.Equal(natural, Lines(Indented(100, 150)));
    }

    [Fact]
    public void A_cell_paragraphs_own_spacing_lies_inside_the_row_in_the_unit_the_cell_is_measured_in()
    {
        // 10pt HWP line, the cell's only paragraph (its gap is handed back): 10 + 5 before + 3 after
        // + 7pt padding and a 1pt rule on both edges. A spacing left in points while the cell is measured in pixels
        // would not add up to a whole 34pt.
        var paragraph = new FlowBlock
        {
            Kind = FlowBlockKind.Text, Runs = new() { new FlowRun("한글", null, 10, false, false, false, false, Colors.Black) },
            LineHeight = new LineHeightRule(LineHeightMode.AtLeast, 20), LineSpacingBelow = true,
            SpacingBeforePoints = 5, SpacingAfterPoints = 3,
        };
        var model = new TableGridModel
        {
            ColumnCount = 1, ColumnWidthRatios = new() { 1.0 },
            Rows = new() { new TableGridRow { Row = 0, Cells = new() { new TableGridCell { Row = 0, Column = 0, Content = new() { paragraph } } } } },
        };
        Assert.Equal(34.0, TableGridRenderer.MeasureRowHeightsPoints(model, 200)[0], precision: 3);
    }

    [Fact]
    public void Paragraph_spacing_opens_and_closes_a_paragraph_in_the_ports_column()
    {
        var owned = new List<IntPtr>();
        try
        {
            var (paragraphs, runs) = Payload(owned, ("a", 12, 20, 20, 0), ("b", 12, 20, 20, 0));
            paragraphs[0].SpacingBefore = 6;
            paragraphs[0].SpacingAfter = 4;
            paragraphs[1].SpacingBefore = 5;
            var lines = TextMeasurerPort.MeasureLinesManaged(paragraphs, runs, 300);
            Assert.Equal(6.0, lines[0].Top, precision: 6);
            // 6 + 20 (the line) + 4 (after) + 5 (before the next paragraph)
            Assert.Equal(35.0, lines[1].Top, precision: 6);
        }
        finally { foreach (var p in owned) { Marshal.FreeCoTaskMem(p); } }
    }

    [Fact]
    public void The_engine_refuses_input_it_cannot_answer_instead_of_guessing()
    {
        var bad = new TableFactsIn
        {
            RowCount = 1, EmptyLine = 10,
            Cells = { new CellFactsIn { Row = 5, Items = { } } },
        };
        var failure = Assert.Throws<InvalidOperationException>(() =>
            LineModelClient.Solve(null, Array.Empty<ParagraphFactsIn>(), new[] { bad }));
        Assert.Contains("row 5", failure.Message);
    }

    // ---- the port's line primitive ---------------------------------------------------------

    private static IntPtr Utf8(string text, List<IntPtr> owned)
    {
        var p = Marshal.StringToCoTaskMemUTF8(text);
        owned.Add(p);
        return p;
    }

    private static (FastdocEngine.FastdocTextMeasureParagraph[] Paragraphs, FastdocEngine.FastdocTextMeasureRun[] Runs) Payload(
        List<IntPtr> owned, params (string Text, double Size, double Min, double Max, double Spacing)[] paragraphs)
    {
        var ps = new List<FastdocEngine.FastdocTextMeasureParagraph>();
        var rs = new List<FastdocEngine.FastdocTextMeasureRun>();
        for (var i = 0; i < paragraphs.Length; i++)
        {
            var (text, size, min, max, spacing) = paragraphs[i];
            ps.Add(new FastdocEngine.FastdocTextMeasureParagraph
            {
                MinimumLineHeight = min, MaximumLineHeight = max, LineSpacing = spacing,
            });
            if (text.Length > 0)
            {
                rs.Add(new FastdocEngine.FastdocTextMeasureRun
                {
                    ParagraphIndex = (nuint)i, Kind = FastdocEngine.FastdocTextMeasureRunKindText,
                    FontName = Utf8("Inter", owned), Size = size, Text = Utf8(text, owned),
                });
            }
        }
        return (ps.ToArray(), rs.ToArray());
    }

    [Fact]
    public void Measure_lines_reports_the_layout_behind_a_height_paragraph_by_paragraph()
    {
        var owned = new List<IntPtr>();
        try
        {
            const string text = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda";
            var (paragraphs, runs) = Payload(owned, (text, 12, 0, 0, 0), ("short", 12, 0, 0, 0));
            var lines = TextMeasurerPort.MeasureLinesManaged(paragraphs, runs, 90);
            Assert.True(lines.Count(l => l.Paragraph == 0) > 1, "the long paragraph wraps");
            Assert.Single(lines, l => l.Paragraph == 1);
            for (var i = 1; i < lines.Length; i++)
            {
                Assert.Equal(lines[i - 1].Top + lines[i - 1].Height, lines[i].Top, precision: 3);
            }
            Assert.Equal(text.Length, lines.Where(l => l.Paragraph == 0).Last().CharEnd);
            Assert.Equal(5, lines.Last().CharEnd);
            Assert.All(lines, l => Assert.InRange(l.Baseline, 0.001, l.Height));
        }
        finally { foreach (var p in owned) { Marshal.FreeCoTaskMem(p); } }
    }

    [Fact]
    public void The_paragraph_style_the_engine_resolved_governs_the_box_and_an_empty_paragraph_still_stands_one_line()
    {
        var owned = new List<IntPtr>();
        try
        {
            var (paragraphs, runs) = Payload(owned, ("one line", 12, 30, 30, 0), ("", 12, 0, 0, 0), ("x", 12, 0, 0, 4));
            var lines = TextMeasurerPort.MeasureLinesManaged(paragraphs, runs, 300);
            Assert.Equal(new[] { 0, 1, 2 }, lines.Select(l => l.Paragraph).ToArray());
            Assert.Equal(30.0, lines[0].Height, precision: 6);
            Assert.Equal(0, lines[1].CharEnd);
            // Line spacing sits under the line, inside its box.
            var plain = TextMeasurerPort.MeasureLinesManaged(
                Payload(owned, ("x", 12, 0, 0, 0)).Paragraphs, Payload(owned, ("x", 12, 0, 0, 0)).Runs, 300)[0].Height;
            Assert.Equal(plain + 4, lines[2].Height, precision: 6);
        }
        finally { foreach (var p in owned) { Marshal.FreeCoTaskMem(p); } }
    }
}
