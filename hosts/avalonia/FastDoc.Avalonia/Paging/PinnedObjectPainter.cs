using System;
using System.Collections.Generic;
using Avalonia;
using Avalonia.Media;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Printing;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Paging;

/// <summary>
/// Paints ONE <see cref="PinnedObject"/> on a sheet — the host half of macOS's
/// `MasterPagePainter.draw(_:onSheet:…)`, shared (as there) by a master-page object and an object
/// the document anchored at a place in the text: they differ only in WHICH pages they appear on,
/// never in where they go on a page or how they are drawn.
///
/// The ink is CLIPPED to its own sheet: an object can be larger than the paper it is pinned to (a
/// chapter divider's numeral is 736pt on a 754pt sheet) and a stacked view would otherwise let it
/// run onto the desk and the next page (invariant 81). A text box is built through the same
/// builder the body uses and is NEVER clipped to its own box — the source's rule when its text will
/// not fit is to overflow the box rather than lose a word (invariants 152/153), so the box grows
/// downward from its top.
/// </summary>
public sealed class PinnedObjectPainter
{
    private const double PointsToPixels = 96.0 / 72.0;
    private const double MinimumStrokePoints = 0.25; // a declared rule is never drawn away to nothing

    private readonly ImageBlockRenderer _images;

    public PinnedObjectPainter(ImageBlockRenderer images) => _images = images;

    /// <param name="topPoints">The object's top edge in PAPER points — <see cref="PinnedObject.Y"/>,
    /// or the completed paragraph-anchored value.</param>
    /// <param name="sheetPx">The sheet rectangle in this surface's pixel space.</param>
    /// <param name="shownPage">The number the sheet prints (after any restart); <paramref
    /// name="hidePageNumber"/> blanks it for a page the document vetoed a number on.</param>
    public void Draw(IPageCanvas surface, PinnedObject obj, double topPoints, Rect sheetPx, double zoomFactor,
        int shownPage, int totalPages, bool hidePageNumber, bool clip = true)
    {
        var scale = PointsToPixels * zoomFactor;
        var rect = new Rect(sheetPx.X + obj.X * scale, sheetPx.Y + topPoints * scale,
            Math.Max(0, obj.Width * scale), Math.Max(0, obj.Height * scale));

        // Flow mode has no sheet to clip to (the continuous view IS the desk), so it passes clip: false.
        if (clip) { surface.PushClip(sheetPx); }
        try
        {
            switch (obj.Content)
            {
                case PinnedImage image:
                    _images.DrawResourceInRect(surface, image.ResourceId, rect);
                    break;
                case PinnedVector vector:
                    DrawVector(surface, vector, rect, scale);
                    break;
                case PinnedText text:
                    DrawText(surface, text, rect, scale, shownPage, totalPages, hidePageNumber);
                    break;
            }
        }
        finally
        {
            if (clip) { surface.PopClip(); }
        }
    }

    // ---- vector --------------------------------------------------------------------------------

    private static void DrawVector(IPageCanvas surface, PinnedVector vector, Rect rect, double scale)
    {
        if (rect.Width <= 0 && rect.Height <= 0) { return; }
        var sx = rect.Width / Math.Max(vector.Width, 0.0001);
        var sy = rect.Height / Math.Max(vector.Height, 0.0001);
        if (!double.IsFinite(sx) || sx <= 0) { sx = scale; }
        if (!double.IsFinite(sy) || sy <= 0) { sy = scale; }

        foreach (var path in vector.Paths)
        {
            var segments = new List<VectorSegment>(path.Commands.Count);
            Point? start = null, startDirection = null, end = null, endDirection = null, previous = null;
            foreach (var command in path.Commands)
            {
                var v = command.Values;
                switch (command.Command)
                {
                    case "moveTo" when v.Count == 2:
                    {
                        var p = new Point(rect.X + v[0] * sx, rect.Y + v[1] * sy);
                        segments.Add(new VectorSegment('M', p.X, p.Y));
                        start ??= p;
                        previous = p;
                        break;
                    }
                    case "lineTo" when v.Count == 2:
                    {
                        var p = new Point(rect.X + v[0] * sx, rect.Y + v[1] * sy);
                        segments.Add(new VectorSegment('L', p.X, p.Y));
                        if (startDirection is null && start is { } s0 && s0 != p) { startDirection = p; }
                        endDirection = previous;
                        end = p;
                        previous = p;
                        break;
                    }
                    case "curveTo" when v.Count == 6:
                    {
                        var c1 = new Point(rect.X + v[0] * sx, rect.Y + v[1] * sy);
                        var c2 = new Point(rect.X + v[2] * sx, rect.Y + v[3] * sy);
                        var p = new Point(rect.X + v[4] * sx, rect.Y + v[5] * sy);
                        segments.Add(new VectorSegment('C', c1.X, c1.Y, c2.X, c2.Y, p.X, p.Y));
                        startDirection ??= c1;
                        endDirection = c2;
                        end = p;
                        previous = p;
                        break;
                    }
                    default:
                        segments.Add(new VectorSegment('Z'));
                        break;
                }
            }
            if (segments.Count == 0) { continue; }

            Color? fill = path.Fill is { } f ? ColorOf(f) : null;
            Color? stroke = null;
            var strokeWidth = 0.0;
            var strokeStyle = "solid";
            if (path.Stroke is { } line)
            {
                stroke = line.Color is { } c ? ColorOf(c) : Colors.Black;
                strokeWidth = Math.Max(line.WidthPoints, MinimumStrokePoints) * scale;
                strokeStyle = line.Style;
            }
            surface.DrawVectorPath(segments, fill, stroke, strokeWidth, strokeStyle);

            if (stroke is { } headColor)
            {
                // Arrowheads are the reader's, not the document's: HWP states only WHICH head a
                // line has. Scaled to the rule's own width so a hairline connector carries no
                // glyph-sized barb (HwpShapeRenderer.swift).
                var size = Math.Max(strokeWidth / scale, 0.5) * 6 * scale;
                if (path.ArrowEnd && end is { } tipEnd && endDirection is { } fromEnd)
                {
                    DrawArrowHead(surface, tipEnd, fromEnd, size, headColor);
                }
                if (path.ArrowStart && start is { } tipStart && startDirection is { } fromStart)
                {
                    DrawArrowHead(surface, tipStart, fromStart, size, headColor);
                }
            }
        }
    }

    private static void DrawArrowHead(IPageCanvas surface, Point tip, Point from, double size, Color color)
    {
        var dx = tip.X - from.X;
        var dy = tip.Y - from.Y;
        var length = Math.Sqrt(dx * dx + dy * dy);
        if (length < 0.01) { return; }
        var ux = dx / length;
        var uy = dy / length;
        var spread = size * 0.38; // a 30-degree barb: narrow enough that two meeting arrows are not a solid wedge
        var bx = tip.X - ux * size;
        var by = tip.Y - uy * size;
        var segments = new[]
        {
            new VectorSegment('M', tip.X, tip.Y),
            new VectorSegment('L', bx - uy * spread, by + ux * spread),
            new VectorSegment('L', bx + uy * spread, by - ux * spread),
            new VectorSegment('Z'),
        };
        surface.DrawVectorPath(segments, color, null, 0, "solid");
    }

    private static Color ColorOf(ColorWire c)
    {
        static byte Channel(double v) => (byte)Math.Clamp(v * 255.0, 0, 255);
        return Color.FromArgb(Channel(c.Alpha), Channel(c.Red), Channel(c.Green), Channel(c.Blue));
    }

    // ---- text box ------------------------------------------------------------------------------

    private static void DrawText(IPageCanvas surface, PinnedText text, Rect rect, double scale,
        int shownPage, int totalPages, bool hidePageNumber)
    {
        DrawBlocks(surface, text.Blocks, rect, scale, b => WithPageFields(b, shownPage, totalPages, hidePageNumber));
    }

    /// <summary>Stacks <paramref name="blocks"/>' text from <paramref name="rect"/>'s top, never clipped to
    /// its height (a box grows downward rather than lose a word) — shared by a pinned text box and a
    /// footnote's body. Returns the y just below the last block.</summary>
    internal static double DrawBlocks(IPageCanvas surface, IReadOnlyList<FlowBlock> blocks, Rect rect, double scale,
        Func<FlowBlock, FlowBlock>? map = null)
    {
        var y = rect.Y;
        foreach (var source in blocks)
        {
            if (source.Kind != FlowBlockKind.Text) { continue; }
            var block = map is null ? source : map(source);
            var indent = block.IndentPoints * scale;
            y += block.SpacingBeforePoints * scale;
            var layout = PageLayout.BuildTextLayout(block, Math.Max(1, rect.Width - indent), scale);
            if (layout is null)
            {
                y += (block.SpacingAfterPoints + PageLayout.BlankLineHeightPoints(block, null)) * scale;
                continue;
            }
            var rule = block.LineHeight.ScaledBy(scale);
            foreach (var line in layout.TextLines)
            {
                surface.DrawTextLine(line, new Point(rect.X + indent, y));
                y += rule.Apply(line.Height);
            }
            y += block.SpacingAfterPoints * scale;
        }
        return y;
    }

    /// <summary>The block with each live page-number run replaced by THIS sheet's number — the
    /// box holds an ordinary field run (the same one a running header carries), so there is no
    /// second field mechanism. A vetoed page blanks the PAGE field only; a page COUNT stays.</summary>
    internal static FlowBlock WithPageFields(FlowBlock block, int shownPage, int totalPages, bool hidePageNumber)
    {
        if (!block.Runs.Exists(r => r.PageField != 0)) { return block; }
        var runs = new List<FlowRun>(block.Runs.Count);
        foreach (var run in block.Runs)
        {
            runs.Add(run.PageField switch
            {
                1 => run with { Text = hidePageNumber ? "" : shownPage.ToString() },
                2 => run with { Text = totalPages.ToString() },
                _ => run,
            });
        }
        return block.WithRuns(runs);
    }
}
