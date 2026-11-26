using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>The offset/extent/viewport to ScrollBar mapping behind the window's vertical bar
/// (FlowDocumentView owns its scrolling, so nothing else draws one).</summary>
public class ScrollBarModelTests
{
    [Fact]
    public void Maximum_is_extent_minus_viewport_and_thumb_ratio_is_viewport_over_extent()
    {
        var m = ScrollBarModel.Compute(extent: 4000, viewport: 800, offset: 1000, zoom: 1);
        Assert.Equal(3200, m.Maximum);
        Assert.Equal(800, m.ViewportSize);
        Assert.Equal(1000, m.Value);
        // Avalonia thumb ratio = ViewportSize / (Maximum + ViewportSize)
        Assert.Equal(800.0 / 4000.0, m.ViewportSize / (m.Maximum + m.ViewportSize), 6);
    }

    [Fact]
    public void Large_change_is_about_one_page_and_small_change_one_line_scaled_by_zoom()
    {
        var m = ScrollBarModel.Compute(4000, 800, 0, zoom: 1);
        Assert.Equal(800 * ScrollBarModel.PageFraction, m.LargeChange, 6);
        Assert.Equal(ScrollBarModel.LineHeightPx, m.SmallChange, 6);
        var z = ScrollBarModel.Compute(4000, 800, 0, zoom: 2);
        Assert.Equal(ScrollBarModel.LineHeightPx * 2, z.SmallChange, 6);
    }

    [Fact]
    public void Document_shorter_than_viewport_has_no_range_and_value_zero()
    {
        var m = ScrollBarModel.Compute(300, 800, 50, 1);
        Assert.Equal(0, m.Maximum);
        Assert.Equal(0, m.Value);
    }

    [Fact]
    public void Extent_change_keeps_value_clamped_to_the_new_range()
    {
        var model = new ScrollBarModel();
        model.Sync(4000, 800, 3200, 1);
        var shrunk = model.Sync(2000, 800, 3200, 1);
        Assert.NotNull(shrunk);
        Assert.Equal(1200, shrunk!.Value.Maximum);
        Assert.Equal(1200, shrunk.Value.Value);
    }

    [Fact]
    public void Zoom_change_moves_extent_and_small_change_in_one_sync()
    {
        var model = new ScrollBarModel();
        model.Sync(4000, 800, 1000, 1);
        var zoomed = model.Sync(8000, 800, 2000, 2)!.Value;
        Assert.Equal(7200, zoomed.Maximum);
        Assert.Equal(2000, zoomed.Value);
        Assert.Equal(ScrollBarModel.LineHeightPx * 2, zoomed.SmallChange, 6);
    }

    [Fact]
    public void Page_mode_extent_is_just_another_extent()
    {
        var model = new ScrollBarModel();
        model.Sync(4000, 800, 500, 1);
        var paged = model.Sync(extent: 12 * 1123 + 40, viewport: 800, offset: 2246, zoom: 1)!.Value;
        Assert.Equal(12 * 1123 + 40 - 800, paged.Maximum);
        Assert.Equal(2246, paged.Value);
    }

    [Fact]
    public void Unchanged_state_reports_nothing_to_apply()
    {
        var model = new ScrollBarModel();
        Assert.NotNull(model.Sync(4000, 800, 100, 1));
        Assert.Null(model.Sync(4000, 800, 100, 1));
    }

    [Fact]
    public void Window_resize_changes_viewport_and_range()
    {
        var model = new ScrollBarModel();
        model.Sync(4000, 800, 0, 1);
        var r = model.Sync(4000, 1000, 0, 1)!.Value;
        Assert.Equal(1000, r.ViewportSize);
        Assert.Equal(3000, r.Maximum);
    }

    [Fact]
    public void User_value_maps_to_offset_and_is_clamped_to_the_range()
    {
        var model = new ScrollBarModel();
        model.Sync(4000, 800, 0, 1);
        Assert.Equal(1234, model.OffsetForUserValue(1234));
        Assert.Equal(3200, model.OffsetForUserValue(99999));
        Assert.Equal(0, model.OffsetForUserValue(-5));
    }

    [Fact]
    public void User_value_then_matching_view_offset_is_a_no_op_sync()
    {
        var model = new ScrollBarModel();
        model.Sync(4000, 800, 0, 1);
        model.OffsetForUserValue(700);
        Assert.Null(model.Sync(4000, 800, 700, 1));
    }

    [Fact]
    public void Drag_freezes_metrics_while_the_extent_grows_under_the_pointer()
    {
        var model = new ScrollBarModel();
        model.Sync(4000, 800, 0, 1);
        model.BeginDrag();
        model.OffsetForUserValue(1600); // thumb halfway
        // blocks get measured: extent grows, view reports a different offset after its own clamp
        Assert.Null(model.Sync(6000, 800, 1500, 1));
        Assert.Equal(3200, model.Current.Maximum);
        Assert.Equal(1600, model.Current.Value);
        Assert.Equal(1600, model.OffsetForUserValue(1600));
    }

    [Fact]
    public void Drag_end_resyncs_to_the_live_numbers()
    {
        var model = new ScrollBarModel();
        model.Sync(4000, 800, 0, 1);
        model.BeginDrag();
        model.OffsetForUserValue(1600);
        model.Sync(6000, 800, 1600, 1);
        var end = model.EndDrag(6000, 800, 1600, 1);
        Assert.False(model.IsDragging);
        Assert.Equal(5200, end.Maximum);
        Assert.Equal(1600, end.Value);
        // and later syncs flow again
        Assert.NotNull(model.Sync(6000, 800, 2000, 1));
    }
}
