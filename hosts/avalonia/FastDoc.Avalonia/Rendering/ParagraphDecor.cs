using System;
using Avalonia;
using FastDoc.Avalonia.Printing;

namespace FastDoc.Avalonia.Rendering;

/// <summary>
/// The paragraph-level paint an office document states beside its text: a background fill and a
/// ruled border. Shared by flow mode (one rectangle per block) and page mode (one per page the
/// block's lines land on), so a shaded or boxed paragraph is drawn by one rule in both.
///
/// Geometry follows macOS's `CodeCardLayoutManager` (`paraShading` / `paraBorder*`): the FILL spans
/// the whole column behind the paragraph's own lines (spacing before and after is not painted),
/// while the BORDER box sits at the paragraph's own indent — a border belongs to the paragraph, so an
/// indented one is ruled where its text sits — inset by half the rule's width so a rule never
/// bleeds past the box it bounds, and only the edges the document drew.
/// </summary>
internal static class ParagraphDecor
{
    private const double MinimumRulePoints = 0.25; // a declared rule is never drawn away to nothing

    public static bool HasAny(FlowBlock block) => block.ShadingColor is not null || block.Border is not null;

    /// <param name="columnLeft">The column's left edge on the surface, in pixels.</param>
    /// <param name="top">The first line's top on the surface; <paramref name="height"/> runs to the
    /// last line's bottom.</param>
    /// <param name="scale">Pixels per point (96/72 × zoom).</param>
    public static void Draw(IPageCanvas surface, FlowBlock block, double columnLeft, double columnWidth, double top,
        double height, double scale)
    {
        if (height <= 0 || columnWidth <= 0) { return; }
        if (block.ShadingColor is { A: > 0 } shading)
        {
            surface.DrawRect(new Rect(columnLeft, top, columnWidth, height), shading, null, 0);
        }
        if (block.Border is not { } border) { return; }

        var width = Math.Max(border.WidthPoints, MinimumRulePoints) * scale;
        var left = columnLeft + block.IndentPoints * scale + width / 2;
        var right = columnLeft + columnWidth - width / 2;
        var upper = top + width / 2;
        var lower = top + height - width / 2;
        if (right <= left || lower <= upper) { return; }
        if (border.Top) { surface.DrawLine(new Point(left, upper), new Point(right, upper), border.Color, width); }
        if (border.Bottom) { surface.DrawLine(new Point(left, lower), new Point(right, lower), border.Color, width); }
        if (border.Left) { surface.DrawLine(new Point(left, upper), new Point(left, lower), border.Color, width); }
        if (border.Right) { surface.DrawLine(new Point(right, upper), new Point(right, lower), border.Color, width); }
    }
}
