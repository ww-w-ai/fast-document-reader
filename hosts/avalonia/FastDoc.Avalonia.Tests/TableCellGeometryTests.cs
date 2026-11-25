using System;
using System.Collections.Generic;
using Avalonia.Media;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Paging;
using FastDoc.Avalonia.Rendering;
using Xunit;

namespace FastDoc.Avalonia.Tests;

/// <summary>A cell's geometry as macOS's `TableBlockBuilder` lays it out (INVARIANTS 207): the rules
/// a cell owns reserve space inside it, a cell of one short token gives right padding back rather
/// than break it, a paged table never stands wider than its authored width, and a hanging
/// paragraph's first line wraps at its own width.</summary>
public sealed class TableCellGeometryTests
{
    public TableCellGeometryTests() => AvaloniaHeadlessSetup.EnsureReady();

    private static FlowBlock TextBlock(string text) => new()
    {
        Kind = FlowBlockKind.Text,
        Runs = new List<FlowRun> { new(text, null, 12, false, false, false, false, Colors.Black) },
    };

    private static TableGridModel Table(IReadOnlyList<string> rows, double? sourceWidth = null, UniformBorderWire? border = null)
    {
        var model = new TableGridModel
        {
            ColumnWidthRatios = new List<double> { 1.0 },
            ColumnCount = 1,
            DefaultBodyFontSizePoints = 12,
            DefaultUniformBorder = border,
            SourceWidthPoints = sourceWidth,
        };
        for (var r = 0; r < rows.Count; r++)
        {
            model.Rows.Add(new TableGridRow
            {
                Row = (uint)r,
                Cells = new List<TableGridCell> { new() { Row = (uint)r, Column = 0, Content = new List<FlowBlock> { TextBlock(rows[r]) } } },
            });
        }
        return model;
    }

    [Fact]
    public void A_cell_reserves_its_owned_rules_the_first_row_its_top_one_too()
    {
        var heights = TableGridRenderer.MeasureRowHeightsPoints(
            Table(new[] { "가", "가" }, border: new UniformBorderWire { WidthPoints = 0.5 }), columnWidthPoints: 300);
        // Each 0.5 pt rule lays out a whole point: the first row owns its top and bottom rule, the
        // second only its bottom one.
        Assert.Equal(heights[1] + 1, heights[0], 3);
    }

    [Fact]
    public void A_cell_of_one_short_token_gives_back_right_padding_rather_than_break_it()
    {
        const string token = "4444.";
        var tokenWidth = PageLayout.BuildPointsTextLayout(TextBlock(token), 1000)!.TextLines[0].Width;
        var oneLine = TableGridRenderer.MeasureRowHeightsPoints(Table(new[] { token }), columnWidthPoints: 300)[0];
        // Paddings 7 + 7 and the 1 pt rule either side leave a content width 3 pt short of the token.
        var column = Math.Ceiling(tokenWidth) + 7 + 7 + 2 - 3;
        var narrow = TableGridRenderer.MeasureRowHeightsPoints(Table(new[] { token }), columnWidthPoints: column)[0];
        Assert.Equal(oneLine, narrow, 3);
    }

    [Fact]
    public void A_table_is_laid_out_no_wider_than_its_authored_width()
    {
        const string text = "a sentence long enough to wrap in a narrow table";
        var full = TableGridRenderer.MeasureRowHeightsPoints(Table(new[] { text }), columnWidthPoints: 400)[0];
        var authored = TableGridRenderer.MeasureRowHeightsPoints(Table(new[] { text }, sourceWidth: 120), columnWidthPoints: 400)[0];
        Assert.True(authored > full, $"authored {authored} vs full {full}");
    }

    [Fact]
    public void A_hanging_first_line_wraps_at_its_own_wider_width()
    {
        const string text = "word word word word word word word word word word";
        var typeface = new Typeface(FontFamily.Default);
        var plain = HangulWordWrap.Create(text, typeface, 12, Brushes.Black, TextAlignment.Left, TextWrapping.Wrap, maxWidth: 120);
        var hanging = HangulWordWrap.Create(text, typeface, 12, Brushes.Black, TextAlignment.Left, TextWrapping.Wrap, maxWidth: 120,
            firstLineExtra: 60);
        Assert.True(hanging.TextLines[0].Length > plain.TextLines[0].Length,
            $"first line {hanging.TextLines[0].Length} vs {plain.TextLines[0].Length}");
        // Every later line still wraps inside the paragraph width.
        for (var i = 1; i < hanging.TextLines.Count; i++) { Assert.True(hanging.TextLines[i].Width <= 120.5); }
    }
}
