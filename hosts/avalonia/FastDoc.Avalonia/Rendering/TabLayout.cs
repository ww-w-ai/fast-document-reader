using System;
using System.Collections.Generic;
using System.Linq;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Paging;

namespace FastDoc.Avalonia.Rendering;

/// <summary>
/// Turns the TAB characters of a paragraph into the gap a tab stop asks for — a contents entry's
/// dot leader to its page number, a right- or centre-aligned column, a decimal column — in place of
/// the four plain spaces this host used to draw (macOS: `NSTextTab` stops plus the `drawMDDecorations`
/// leader, `OfficeTextBuilder.resolvedTabStops` / `markTabLeaders`).
///
/// Avalonia's <see cref="Avalonia.Media.TextFormatting.TextLayout"/> has no tab-stop concept, so the
/// gap is resolved at BLOCK-BUILD time, in POINTS, by measuring what precedes the tab and what
/// follows it, and the tab run is replaced by a run of leader characters (or spaces) that fills the
/// distance. Resolving once, in points, keeps the result linear in zoom — flow view, page layout and
/// table cells all draw the same string, so a block never wraps differently at two scales. The one
/// thing this cannot know is a line that WRAPS before its tab (the measured x is then the unwrapped
/// x): a contents line is one line, and the gap then collapses to a single space rather than
/// pushing the number onto a line of its own.
///
/// Positions are the document's own, measured from the paragraph's left margin and ignoring the
/// block's indent the same way `NSTextTab` locations ignore it; a tab with no stop to its right
/// falls to the default grid (36pt, Word's half inch), which is also what a paragraph with no stops
/// at all gets.
/// </summary>
internal static class TabLayout
{
    internal const double DefaultTabPoints = 36;
    private const double Epsilon = 0.5;

    /// <summary>How far short of its stop a right / centre / decimal gap stops. A contents line's
    /// right stop sits on the column's own right edge, and a line whose measured width lands within
    /// a pixel of the edge wraps its page number onto a line of its own (measured: 0.5pt was not
    /// enough, the number dropped to a second line on a docx contents page; macOS keeps 12pt for the
    /// same reason — `fillMarginTrailingInset`). Three points reads as flush and never wraps.</summary>
    private const double EdgeMargin = 3.0;
    private const int MaxFillerCharacters = 600;

    /// <summary>Returns <paramref name="runs"/> unchanged when none is a tab; otherwise a new list
    /// with each tab run replaced by its filler. <paramref name="headIndentPoints"/> is the
    /// paragraph's own head indent — a stop at P sits P minus that from where the text starts.</summary>
    public static List<FlowRun> Resolve(List<FlowRun> runs, IReadOnlyList<TabStopWire>? stops, double headIndentPoints)
    {
        if (!runs.Exists(r => r.Tab)) { return runs; }

        var ordered = stops is { Count: > 0 } ? stops.OrderBy(s => s.PositionPoints).ToList() : new List<TabStopWire>();
        // The paragraph is laid out with ONE letter spacing (see FlowBlock.LetterSpacingPoints), so
        // every width below is measured with it — a −5% contents line is shorter than its natural width.
        var spacing = FlowDocumentBuilder.LetterSpacingOf(runs.FindAll(r => !r.Tab));
        var result = new List<FlowRun>(runs.Count + 4);
        var lineStart = 0; // index into result where the current logical line begins

        for (var i = 0; i < runs.Count; i++)
        {
            var run = runs[i];
            if (!run.Tab)
            {
                result.Add(run);
                if (run.Text == "\n") { lineStart = result.Count; }
                continue;
            }

            var x = Measure(result.GetRange(lineStart, result.Count - lineStart), spacing);
            var after = new List<FlowRun>();
            for (var j = i + 1; j < runs.Count && !runs[j].Tab && runs[j].Text != "\n"; j++) { after.Add(runs[j]); }

            var (stopX, alignment, leader) = NextStop(ordered, x, headIndentPoints);
            var gap = alignment switch
            {
                "right" => stopX - x - Measure(after, spacing),
                "center" => stopX - x - Measure(after, spacing) / 2,
                "decimal" => stopX - x - Measure(UpToDecimalPoint(after), spacing),
                _ => stopX - x,
            };
            result.Add(Filler(run, gap, leader, alignment == "left" ? Epsilon : EdgeMargin, spacing));
        }
        return result;
    }

    /// <summary>The first stop strictly to the right of <paramref name="x"/> (text-start
    /// coordinates), else the next default-grid position.</summary>
    private static (double StopX, string Alignment, string Leader) NextStop(List<TabStopWire> ordered, double x,
        double headIndentPoints)
    {
        foreach (var stop in ordered)
        {
            var stopX = stop.PositionPoints - headIndentPoints;
            if (stopX > x + Epsilon) { return (stopX, stop.Alignment, stop.Leader); }
        }
        var column = x + headIndentPoints;
        var next = (Math.Floor(column / DefaultTabPoints) + 1) * DefaultTabPoints;
        return (next - headIndentPoints, "left", "none");
    }

    private static List<FlowRun> UpToDecimalPoint(List<FlowRun> after)
    {
        var text = string.Concat(after.Select(r => r.Text));
        var dot = text.IndexOf('.');
        if (dot < 0) { return after; }
        var kept = new List<FlowRun>();
        var remaining = dot;
        foreach (var run in after)
        {
            if (remaining <= 0) { break; }
            kept.Add(remaining >= run.Text.Length ? run : run with { Text = run.Text[..remaining] });
            remaining -= run.Text.Length;
        }
        return kept;
    }

    /// <summary>The run that stands in for one tab: leader characters flush right with at most one
    /// space of slack in front, or plain spaces when the stop carries no leader.</summary>
    private static FlowRun Filler(FlowRun tab, double gapPoints, string leader, double margin, double spacing)
    {
        var proto = tab with { Text = "", Tab = false, LinkTarget = null, Underline = false, Strike = false, Background = null };
        var spaceWidth = Math.Max(0.5, Measure(new List<FlowRun> { proto with { Text = " " } }, spacing));
        // A margin short of the stop, so a stop at the very edge of the column never wraps its own number.
        var room = gapPoints - margin;
        if (room < spaceWidth * 0.5) { return proto with { Text = " " }; }

        var leaderChar = leader switch { "dot" => '.', "hyphen" => '-', "underscore" => '_', _ => ' ' };
        if (leaderChar == ' ')
        {
            var spaces = Math.Clamp((int)Math.Round(room / spaceWidth), 1, MaxFillerCharacters);
            return proto with { Text = new string(' ', spaces) };
        }

        var unitWidth = Math.Max(0.5, Measure(new List<FlowRun> { proto with { Text = leaderChar.ToString() } }, spacing));
        var count = Math.Clamp((int)Math.Floor(room / unitWidth), 1, MaxFillerCharacters);
        var rest = room - count * unitWidth;
        var lead = rest > 0 ? Math.Clamp((int)Math.Round(rest / spaceWidth), 0, 4) : 0;
        return proto with { Text = new string(' ', lead) + new string(leaderChar, count) };
    }

    /// <summary>The unwrapped width, in points, of <paramref name="runs"/> laid out as one line.</summary>
    internal static double Measure(List<FlowRun> runs, double letterSpacingPoints = 0)
    {
        if (runs.Count == 0 || runs.TrueForAll(r => r.Text.Length == 0)) { return 0; }
        var layout = PageLayout.BuildTextLayout(
            new FlowBlock { Kind = FlowBlockKind.Text, Runs = runs, LetterSpacingPoints = letterSpacingPoints }, 1_000_000, 1.0);
        return layout?.WidthIncludingTrailingWhitespace ?? 0;
    }
}
