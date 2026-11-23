using System;
using System.Collections.Generic;
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
              "placements":[{"block":1,"key":78,"page":1,"top":0.0,"height":50.0,"rowStart":0,"rowCount":2}],
              "lines":[[0,0,0,0.0],[0,1,1,0.0]],
              "splitTableCount":0,"carriedTableCount":1,"droppedBreakCount":3}}
            """;
        var plan = PagePlanClient.Decode(reply);
        Assert.Equal(2, plan.PageCount);
        Assert.Equal(new PlannedPage(1, null), plan.Pages[1]);
        Assert.Equal(new PlannedPlacement(1, 1, 0, 50, 0, 2), plan.Placements[0]);
        Assert.Equal(new PlannedLine(0, 1, 1, 0), plan.Lines[1]);
        Assert.Equal(1, plan.CarriedTableCount);
        Assert.Equal(3, plan.DroppedBreakCount);
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
}
