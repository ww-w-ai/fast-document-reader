using System;

namespace FastDoc.Avalonia.Rendering;

/// <summary>What the window's vertical <c>ScrollBar</c> shows, in document pixels. Avalonia sizes
/// the thumb as <c>ViewportSize / (Maximum + ViewportSize)</c>, so <c>Maximum = extent - viewport</c>
/// with <c>ViewportSize = viewport</c> makes the thumb exactly <c>viewport / extent</c>.</summary>
internal readonly record struct ScrollBarMetrics(
    double Maximum, double ViewportSize, double Value, double SmallChange, double LargeChange);

/// <summary>Maps <see cref="FlowDocumentView"/>'s self-owned scroll state (ContentHeight,
/// Bounds.Height, ScrollOffset) onto a <c>ScrollBar</c>, and back for user input. Pure — no Avalonia
/// types — so the mapping is unit-tested without a window.
/// The view's extent is an estimate corrected lazily as blocks are measured (flow mode), so it moves
/// while the reader scrolls. While the thumb is DRAGGED the model therefore holds the metrics it had
/// at drag start: an extent that grows under the pointer would otherwise slide the thumb away from
/// the cursor. It re-syncs with the live numbers when the drag ends.</summary>
internal sealed class ScrollBarModel
{
    /// <summary>A line of body text at zoom 1.0, in pixels — the arrow buttons' step.</summary>
    internal const double LineHeightPx = 24;

    /// <summary>Share of the viewport a track click scrolls — leaves a little overlap for context.</summary>
    internal const double PageFraction = 0.9;

    private ScrollBarMetrics _current;

    public ScrollBarMetrics Current => _current;

    public bool IsDragging { get; private set; }

    /// <summary>Metrics for a view state; <paramref name="zoom"/> scales the line step because
    /// the document's line height scales with it.</summary>
    public static ScrollBarMetrics Compute(double extent, double viewport, double offset, double zoom)
    {
        viewport = Math.Max(0, viewport);
        extent = Math.Max(0, extent);
        var maximum = Math.Max(0, extent - viewport);
        var small = LineHeightPx * Math.Max(0.1, zoom);
        var large = Math.Max(small, viewport * PageFraction);
        return new ScrollBarMetrics(maximum, viewport, Math.Clamp(offset, 0, maximum), small, large);
    }

    /// <summary>Takes the view's live state. Ignored while dragging (see the type comment).
    /// Returns the metrics to show, or null when nothing should change.</summary>
    public ScrollBarMetrics? Sync(double extent, double viewport, double offset, double zoom)
    {
        if (IsDragging) { return null; }
        var next = Compute(extent, viewport, offset, zoom);
        if (next == _current) { return null; }
        _current = next;
        return next;
    }

    public void BeginDrag() => IsDragging = true;

    /// <summary>Ends a drag and returns the live metrics (always, so the bar resets to truth).</summary>
    public ScrollBarMetrics EndDrag(double extent, double viewport, double offset, double zoom)
    {
        IsDragging = false;
        _current = Compute(extent, viewport, offset, zoom);
        return _current;
    }

    /// <summary>The document offset a user-driven bar value means, within the metrics currently
    /// shown. Also remembers it as the shown value so a following <see cref="Sync"/> that reports
    /// the same position is a no-op.</summary>
    public double OffsetForUserValue(double value)
    {
        var clamped = Math.Clamp(value, 0, _current.Maximum);
        _current = _current with { Value = clamped };
        return clamped;
    }
}
