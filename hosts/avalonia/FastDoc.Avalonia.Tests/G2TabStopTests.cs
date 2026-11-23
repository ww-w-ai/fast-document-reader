using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using Avalonia.Media;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// G2 (parity audit): a TAB in an office paragraph resolves to the gap its tab stops ask for — a
/// contents entry's dot leader to its page number, right / centre / decimal columns — instead of the
/// four plain spaces this host used to draw. Widths are measured with the same text engine that draws
/// the result, so "the number lands on the stop" is asserted in points rather than by eye. Every stop
/// is derived from the measured width of the text around it, so the assertions hold with whatever face
/// the machine resolves (a headless run without fonts measures every glyph alike).
/// </summary>
public class G2TabStopTests
{
    public G2TabStopTests() => AvaloniaHeadlessSetup.EnsureReady();

    private static FlowRun Text(string text) => new(text, null, 12, false, false, false, false, Colors.Black);
    private static FlowRun Tab() => new("\t", null, 12, false, false, false, false, Colors.Black, Tab: true);

    private static TabStopWire Stop(double position, string alignment = "left", string leader = "none") =>
        new() { PositionPoints = position, Alignment = alignment, Leader = leader };

    private static double Width(IEnumerable<FlowRun> runs) => TabLayout.Measure(runs.ToList());
    private static double Width(string text) => Width(new[] { Text(text) });

    private static double Unit => Width(".");
    private static double Space => Width(" ");

    /// <summary>How far a result may fall short of its stop: one leader character plus the leading
    /// spaces that pad the remainder, plus the half point kept clear of the column edge.</summary>
    private static double Slack => Unit + Space + 3.5;

    [Fact]
    public void A_right_tab_with_a_dot_leader_lands_the_number_on_the_stop()
    {
        var stop = Width("Chapter One") + Width("12") + 40 * Unit;
        var runs = new List<FlowRun> { Text("Chapter One"), Tab(), Text("12") };
        var resolved = TabLayout.Resolve(runs, new[] { Stop(stop, "right", "dot") }, headIndentPoints: 0);

        Assert.DoesNotContain(resolved, r => r.Tab);
        var filler = resolved[1].Text;
        Assert.True(filler.Count(c => c == '.') >= 35, "a dot leader runs the whole gap, not one character");
        // The whole line ends on the stop, never past it, and short of it by less than one leader dot.
        Assert.InRange(Width(resolved), stop - Slack, stop + 0.01);
    }

    [Fact]
    public void A_left_tab_without_a_leader_fills_with_spaces_up_to_the_stop()
    {
        var stop = Width("Name") + 25 * Space;
        var resolved = TabLayout.Resolve(new List<FlowRun> { Text("Name"), Tab(), Text("Value") },
            new[] { Stop(stop) }, 0);

        Assert.True(string.IsNullOrWhiteSpace(resolved[1].Text));
        Assert.InRange(Width(resolved.Take(2)), stop - Slack, stop + 0.01);
    }

    [Fact]
    public void A_centre_tab_centres_the_following_text_on_the_stop()
    {
        var stop = Width("L") + Width("middle") / 2 + 30 * Unit;
        var resolved = TabLayout.Resolve(new List<FlowRun> { Text("L"), Tab(), Text("middle") },
            new[] { Stop(stop, "center") }, 0);

        var centre = Width(resolved.Take(2)) + Width("middle") / 2;
        Assert.InRange(centre, stop - Slack, stop + 0.01);
    }

    [Fact]
    public void A_decimal_tab_lines_the_point_up_on_the_stop()
    {
        var stop = Width("Total") + Width("12") + 30 * Unit;
        var resolved = TabLayout.Resolve(new List<FlowRun> { Text("Total"), Tab(), Text("12.50") },
            new[] { Stop(stop, "decimal") }, 0);

        var pointAt = Width(resolved.Take(2)) + Width("12");
        Assert.InRange(pointAt, stop - Slack, stop + 0.01);
    }

    [Fact]
    public void A_tab_with_no_stop_falls_to_the_default_grid()
    {
        var resolved = TabLayout.Resolve(new List<FlowRun> { Text("A"), Tab(), Text("B") }, null, 0);

        var before = Width(resolved.Take(2));
        Assert.True(before > Width("A"));
        var steps = before / TabLayout.DefaultTabPoints;
        // On a multiple of the grid, to within the one space the quantisation can lose.
        Assert.InRange(Math.Ceiling(steps) * TabLayout.DefaultTabPoints - before, 0, Slack);
    }

    [Fact]
    public void A_tab_past_the_last_stop_moves_to_the_next_grid_position()
    {
        var text = Width("A long first column");
        var stop = text / 2; // the text already runs past the only stop
        var resolved = TabLayout.Resolve(
            new List<FlowRun> { Text("A long first column"), Tab(), Text("B") }, new[] { Stop(stop) }, 0);
        var before = Width(resolved.Take(2));

        Assert.True(before > text);
        Assert.InRange(Math.Ceiling(before / TabLayout.DefaultTabPoints) * TabLayout.DefaultTabPoints - before, 0, Slack);
    }

    [Fact]
    public void A_head_indent_shifts_where_the_stops_sit()
    {
        var stop = Width("x") + 200 * Space;
        var runs = new List<FlowRun> { Text("x"), Tab(), Text("y") };
        var plain = TabLayout.Resolve(runs, new[] { Stop(stop) }, 0);
        var indented = TabLayout.Resolve(runs, new[] { Stop(stop) }, headIndentPoints: 40);

        // Stop positions are measured from the paragraph's left margin; the text starts 40pt in.
        Assert.InRange(Width(plain.Take(2)) - Width(indented.Take(2)), 40 - Slack, 40 + Slack);
    }

    [Fact]
    public void Each_line_after_a_line_break_measures_from_its_own_start()
    {
        var second = "a much longer second line";
        var stop = Math.Max(Width("one"), Width(second)) + 30 * Unit;
        var runs = new List<FlowRun> { Text("one"), Tab(), Text("a"), Text("\n"), Text(second), Tab(), Text("b") };
        var resolved = TabLayout.Resolve(runs, new[] { Stop(stop) }, 0);

        var firstLineWidth = Width(resolved.Take(2));
        var secondStart = resolved.FindIndex(r => r.Text == second);
        var secondLineWidth = Width(resolved.Skip(secondStart).Take(2));
        Assert.InRange(firstLineWidth, stop - Slack, stop + 0.01);
        Assert.InRange(secondLineWidth, stop - Slack, stop + 0.01);
    }

    [Fact]
    public void Runs_without_a_tab_come_back_untouched()
    {
        var runs = new List<FlowRun> { Text("no tabs here") };
        Assert.Same(runs, TabLayout.Resolve(runs, new[] { Stop(100) }, 0));
    }

    private static RenderTree Parse(string json)
    {
        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(json)!;
        return envelope.Ok!.Value.Deserialize<RenderTree>()!;
    }

    [Fact]
    public void A_contents_paragraph_in_a_tree_builds_a_leadered_block()
    {
        var stop = Width("Introduction") + Width("7") + 40 * Unit;
        var json = $$"""
        {
          "ok": { "schemaVersion": 1,
            "document": { "format": "hwp", "rootNodeId": 0, "defaultBodyFontSize": 12 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [2], "type": "paragraph",
                "data": { "style": {}, "tabStops": [ { "positionPoints": {{stop.ToString(System.Globalization.CultureInfo.InvariantCulture)}}, "alignment": "right", "leader": "dot" } ] } },
              { "id": 2, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "Introduction\t7", "style": {} } }
            ],
            "annotations": { "comments": [], "bookmarks": [] } }
        }
        """;
        var block = FlowDocumentBuilder.Build(Parse(json)).Single();
        var text = string.Concat(block.Runs.Select(r => r.Text));

        Assert.DoesNotContain('\t', text);
        Assert.StartsWith("Introduction", text);
        Assert.EndsWith("7", text);
        Assert.True(text.Count(c => c == '.') >= 35);
        Assert.InRange(TabLayout.Measure(block.Runs), stop - Slack, stop + 0.01);
    }

    [Fact]
    public void A_table_cell_paragraph_resolves_its_tabs_too()
    {
        var stop = Width("Item") + Width("9") + 30 * Unit;
        var json = $$"""
        {
          "ok": { "schemaVersion": 1,
            "document": { "format": "docx", "rootNodeId": 0, "defaultBodyFontSize": 12 },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
              { "id": 1, "parentId": 0, "children": [2], "type": "table", "data": { "gridWidths": [1.0], "style": {} } },
              { "id": 2, "parentId": 1, "children": [3], "type": "tableRow", "data": { "row": 0, "header": false } },
              { "id": 3, "parentId": 2, "children": [4], "type": "tableCell", "data": { "row": 0, "column": 0 } },
              { "id": 4, "parentId": 3, "children": [5], "type": "paragraph",
                "data": { "style": {}, "tabStops": [ { "positionPoints": {{stop.ToString(System.Globalization.CultureInfo.InvariantCulture)}}, "alignment": "right", "leader": "hyphen" } ] } },
              { "id": 5, "parentId": 4, "children": [], "type": "textRun", "data": { "text": "Item\t9", "style": {} } }
            ],
            "annotations": { "comments": [], "bookmarks": [] } }
        }
        """;
        var table = FlowDocumentBuilder.Build(Parse(json)).Single();
        var inner = table.Table!.Rows[0].Cells[0].Content.Single();
        var text = string.Concat(inner.Runs.Select(r => r.Text));
        Assert.DoesNotContain('\t', text);
        Assert.Contains('-', text);
    }
}
