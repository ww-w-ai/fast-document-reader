using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using FastDoc.Avalonia.Paging;
using Xunit;

namespace FastDoc.Avalonia.Tests;

/// <summary>S2: the host's side of the engine page plan — what it sends (measurements and flags,
/// no decisions) and how it reads the answer. The decisions themselves are the engine's and are
/// pinned in `render/office/page_plan.rs`.</summary>
public class PagePlanClientTests
{
    [Fact]
    public void Encode_carries_measurements_and_flags_keyed_by_the_hosts_key()
    {
        var blocks = new List<PlanBlockInput>
        {
            new() { Key = 77, Kind = "text", PageBreakBefore = true, KeepWithNext = true, SpacingBefore = 6, Lines = new[] { 14.5, 14.5 } },
            new() { Key = 78, Kind = "table", RowHeights = new[] { 20.0, 30.0 }, RowCanBreakAbove = new[] { false, true }, KeepsWhole = true },
            new() { Key = 79, Kind = "atomic", Skip = true, Height = 99 },
        };
        var bytes = PagePlanClient.Encode(500, splitTables: true, new Dictionary<int, double> { [2] = 40 }, blocks);
        Assert.Equal(0, bytes[^1]); // NUL-terminated for `const char *`
        using var doc = JsonDocument.Parse(Encoding.UTF8.GetString(bytes, 0, bytes.Length - 1));
        var root = doc.RootElement;
        Assert.Equal(1, root.GetProperty("planVersion").GetInt32());
        Assert.Equal(500, root.GetProperty("contentHeight").GetDouble());
        Assert.True(root.GetProperty("splitTables").GetBoolean());
        Assert.Equal(40, root.GetProperty("noteBands")[0].GetProperty("height").GetDouble());

        var first = root.GetProperty("blocks")[0];
        Assert.Equal(77, first.GetProperty("key").GetInt64());
        Assert.True(first.GetProperty("pageBreakBefore").GetBoolean());
        Assert.True(first.GetProperty("keepWithNext").GetBoolean());
        Assert.Equal(2, first.GetProperty("lines").GetArrayLength());

        var table = root.GetProperty("blocks")[1];
        Assert.True(table.GetProperty("keepsWhole").GetBoolean());
        Assert.False(table.GetProperty("rows")[0].TryGetProperty("canBreakAbove", out _));
        Assert.True(table.GetProperty("rows")[1].GetProperty("canBreakAbove").GetBoolean());

        // A skipped block carries no measurements at all.
        var skipped = root.GetProperty("blocks")[2];
        Assert.True(skipped.GetProperty("skip").GetBoolean());
        Assert.False(skipped.TryGetProperty("height", out _));
    }

    [Fact]
    public void Decode_reads_the_plan_in_the_hosts_terms()
    {
        const string reply = """
            {"ffiVersion":1,"ok":{"planVersion":1,"pageCount":2,
              "pages":[{"section":0,"firstKey":77},{"section":1}],
              "placements":[{"block":1,"key":78,"page":1,"top":0.0,"height":50.0,"rowStart":0,"rowCount":2},
                            {"block":2,"key":79,"page":1,"top":50.0,"height":30.0,"rowStart":1,"rowCount":1,"flowed":true}],
              "lines":[[0,0,0,0.0],[0,1,1,0.0]],
              "rowSegments":[[2,1,1,50.0,80.0]],
              "cellLines":[[2,1,0,3,1,52.5]],
              "pulledLines":[],
              "splitTableCount":0,"carriedTableCount":1,"droppedBreakCount":3}}
            """;
        var plan = PagePlanClient.Decode(reply);
        Assert.Equal(2, plan.PageCount);
        Assert.Equal(new PlannedPage(1, null), plan.Pages[1]);
        Assert.Equal(new PlannedPlacement(1, 1, 0, 50, 0, 2), plan.Placements[0]);
        Assert.True(plan.Placements[1].Flowed);
        Assert.Equal(new PlannedRowSegment(2, 1, 1, 50, 80), plan.RowSegments[0]);
        Assert.Equal(new PlannedCellLine(2, 1, 0, 3, 1, 52.5), plan.CellLines[0]);
        Assert.Equal(new PlannedLine(0, 1, 1, 0), plan.Lines[1]);
        Assert.Equal(1, plan.CarriedTableCount);
        Assert.Equal(3, plan.DroppedBreakCount);
    }

    [Fact]
    public void A_table_taller_than_a_page_flows_mid_row_through_the_real_engine()
    {
        // One row, one cell of five 40pt lines on a 100pt page (band 20): the cell's lines travel in
        // the row, and the engine answers where each landed — no host decision involved.
        var lines = new PlanLineInput[5];
        for (var i = 0; i < lines.Length; i++) { lines[i] = new PlanLineInput(i * 40.0, 40, 0); }
        var cells = new[] { new[] { new PlanCellInput { ContentHeight = 200, Lines = lines } } };
        var plan = PagePlanClient.Plan(IntPtr.Zero, 100, splitTables: true, null, new List<PlanBlockInput>
        {
            new() { Key = 5, Kind = "table", RowHeights = new[] { 200.0 }, RowCanBreakAbove = new[] { false }, RowCells = cells },
        }, bandPoints: 20);
        Assert.Equal(3, plan.PageCount);
        Assert.All(plan.Placements, p => Assert.True(p.Flowed));
        Assert.Equal(new[] { 0, 0, 1, 1, 2 }, System.Linq.Enumerable.ToArray(System.Linq.Enumerable.Select(plan.CellLines, l => l.Page)));
        Assert.Equal(3, plan.RowSegments.Count);
    }

    [Fact]
    public void Decode_turns_an_error_envelope_into_a_failure_that_names_the_kind()
    {
        const string reply = """{"ffiVersion":1,"error":{"kind":"invalidArgument","message":"unsupported planVersion 2"}}""";
        var failure = Assert.Throws<InvalidOperationException>(() => PagePlanClient.Decode(reply));
        Assert.Contains("invalidArgument", failure.Message);
        Assert.Contains("unsupported planVersion 2", failure.Message);
    }

    [Fact]
    public void Plan_round_trips_through_the_real_engine_for_non_text_blocks()
    {
        // Atomic blocks need no font metrics: 60pt + 60pt on a 100pt page is two pages, and the
        // second block is the first on page 1.
        var plan = PagePlanClient.Plan(IntPtr.Zero, 100, splitTables: false, null, new List<PlanBlockInput>
        {
            new() { Key = 1, Kind = "atomic", Height = 60 },
            new() { Key = 2, Kind = "atomic", Height = 60 },
        });
        Assert.Equal(2, plan.PageCount);
        Assert.Equal(2, plan.Pages[1].FirstKey);
        Assert.Equal(1, plan.Placements[1].Page);
    }

    [Fact]
    public void Encode_carries_the_column_declarations_and_the_run_a_block_sits_under()
    {
        var columns = new PlanColumnsInput
        {
            BodyWidth = 300,
            Runs = new[] { new PlanColumnRunInput { Count = 2, Spacing = 10, Widths = new[] { 100.0, 190.0 }, Gaps = new[] { 10.0, 0.0 }, Proportional = true } },
        };
        var bytes = PagePlanClient.Encode(100, splitTables: false, null,
            new List<PlanBlockInput> { new() { Key = 1, Kind = "text", Lines = new[] { 10.0 }, ColumnRun = 0 } }, columns: columns);
        using var doc = JsonDocument.Parse(Encoding.UTF8.GetString(bytes, 0, bytes.Length - 1));
        var root = doc.RootElement;
        Assert.Equal(300, root.GetProperty("bodyWidth").GetDouble());
        var run = root.GetProperty("columnRuns")[0];
        Assert.Equal(2, run.GetProperty("count").GetInt32());
        Assert.Equal(190, run.GetProperty("widths")[1].GetDouble());
        Assert.True(run.GetProperty("proportional").GetBoolean());
        Assert.Equal(0, root.GetProperty("blocks")[0].GetProperty("columnRun").GetInt32());
    }

    [Fact]
    public void A_columned_run_is_dealt_into_columns_by_the_real_engine()
    {
        // Ten 10pt lines on a 50pt body in two equal columns of a 300pt body: five a column.
        var columns = new PlanColumnsInput
        {
            BodyWidth = 300,
            Runs = new[] { new PlanColumnRunInput { Count = 2, Spacing = 20 } },
        };
        var plan = PagePlanClient.Plan(IntPtr.Zero, 50, splitTables: false, null,
            new List<PlanBlockInput> { new() { Key = 1, Kind = "text", Lines = new double[10].Select(_ => 10.0).ToArray(), ColumnRun = 0 } },
            columns: columns);
        Assert.Equal(1, plan.PageCount);
        Assert.Equal(2, plan.ColumnRuns[0].Count);
        Assert.Equal(0, plan.ColumnRuns[0][0].X);
        Assert.Equal(140, plan.ColumnRuns[0][0].Width);
        Assert.Equal(160, plan.ColumnRuns[0][1].X);
        Assert.Equal(0, plan.ColumnLines[(0, 4)]);
        Assert.Equal(1, plan.ColumnLines[(0, 5)]);
        Assert.Equal(0, plan.Lines[5].Top);
    }

    [Fact]
    public void Decode_reads_column_answers_in_the_hosts_terms()
    {
        const string reply = """
            {"ffiVersion":1,"ok":{"planVersion":1,"pageCount":1,"pages":[{"section":0}],
              "placements":[{"block":0,"key":1,"page":0,"top":0.0,"height":10.0,"column":1}],
              "lines":[],"rowSegments":[],"cellLines":[],"pulledLines":[],
              "splitTableCount":0,"carriedTableCount":0,"droppedBreakCount":0,
              "columnLines":[[2,3,1]],"columnCellLines":[[4,0,1,2,1]],
              "columnRowSegments":[[4,0,0,1,10.0,25.5]],
              "columnRuns":[[{"x":0.0,"width":140.0},{"x":160.0,"width":140.0}]]}}
            """;
        var plan = PagePlanClient.Decode(reply);
        Assert.Equal(1, plan.Placements[0].Column);
        Assert.Equal(1, plan.ColumnLines[(2, 3)]);
        Assert.Equal(1, plan.ColumnCellLines[(4, 0, 1, 2)]);
        Assert.Equal(new PlannedColumnRowSegment(4, 0, 0, 1, 10, 25.5), plan.ColumnRowSegments[0]);
        Assert.Equal(new PlannedColumn(160, 140), plan.ColumnRuns[0][1]);
    }
}
