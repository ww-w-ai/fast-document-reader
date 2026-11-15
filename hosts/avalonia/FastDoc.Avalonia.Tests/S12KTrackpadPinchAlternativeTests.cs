using System.Reflection;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Input;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>S12-K item 18 (gap.md — trackpad pinch has no direct gesture API in Avalonia 12 on this
/// platform; PM's own brief accepts "the best available within the framework's gesture API limits").
/// The fix (FlowDocumentView.OnPointerWheelChanged) reuses the EXISTING ZoomIn/ZoomOut/ZoomReset
/// path (the same one Ctrl+=/Ctrl+-/Ctrl+0 already call) for a Ctrl(or Cmd)+wheel gesture — no new
/// zoom mechanism, only a second input path into the one that already exists.</summary>
public class S12KTrackpadPinchAlternativeTests
{
    public S12KTrackpadPinchAlternativeTests() => AvaloniaHeadlessSetup.EnsureReady();

    private static RenderTree OneParagraphTree(string text)
    {
        var json = $$"""
        {
          "schemaVersion": 1,
          "document": { "rootNodeId": 0, "defaultBodyFontSize": 12.0 },
          "nodes": [
            { "id": 0, "parentId": null, "type": "document", "children": [1], "data": {} },
            { "id": 1, "parentId": 0, "type": "paragraph", "children": [2], "data": { "style": {} } },
            { "id": 2, "parentId": 1, "type": "textRun", "children": [], "data": { "text": {{JsonSerializer.Serialize(text)}}, "style": {} } }
          ]
        }
        """;
        return JsonSerializer.Deserialize<RenderTree>(json)!;
    }

    private static double ZoomFactor(FlowDocumentView view)
    {
        var field = typeof(FlowDocumentView).GetField("_zoomFactor", BindingFlags.NonPublic | BindingFlags.Instance)!;
        return (double)field.GetValue(view)!;
    }

    /// <summary>Pins the ROOT WIRING (not a re-test of ZoomIn/ZoomOut's own math, which S9's own
    /// zoom tests already cover): a Ctrl+wheel notch must move the zoom factor by exactly ONE
    /// ZoomStep in the direction Delta.Y points, through the SAME SetZoom path Ctrl+= uses — if the
    /// Control-modifier check in OnPointerWheelChanged were ever removed or its sign flipped, this
    /// is what would go red (a Ctrl+wheel notch producing no zoom change, or scrolling instead).</summary>
    [Fact]
    public void CtrlPlusWheelUp_zooms_in_by_one_step_instead_of_scrolling()
    {
        var view = new FlowDocumentView();
        view.SetTree(OneParagraphTree("some reading text"));
        var window = new Window { Width = 400, Height = 200, Content = view };
        window.Show();
        window.CaptureRenderedFrame();

        var before = ZoomFactor(view);
        var scrollBefore = view.ScrollOffset;
        window.MouseWheel(new Point(50, 50), new Vector(0, 1), RawInputModifiers.Control);
        var after = ZoomFactor(view);

        Assert.Equal(before + 0.1, after, 3);
        Assert.Equal(scrollBefore, view.ScrollOffset); // did not ALSO scroll
    }

    [Fact]
    public void CtrlPlusWheelDown_zooms_out_by_one_step()
    {
        var view = new FlowDocumentView();
        view.SetTree(OneParagraphTree("some reading text"));
        var window = new Window { Width = 400, Height = 200, Content = view };
        window.Show();
        window.CaptureRenderedFrame();

        var before = ZoomFactor(view);
        window.MouseWheel(new Point(50, 50), new Vector(0, -1), RawInputModifiers.Control);
        var after = ZoomFactor(view);

        Assert.Equal(before - 0.1, after, 3);
    }

    /// <summary>The negative case: an ORDINARY wheel notch (no Ctrl/Cmd) must still scroll, exactly
    /// as before this change — proving the Ctrl-gate does not accidentally swallow plain scrolling.</summary>
    [Fact]
    public void PlainWheel_without_a_modifier_scrolls_and_does_not_change_zoom()
    {
        var view = new FlowDocumentView();
        // A long document so there is real scroll room for the assertion to be meaningful.
        view.SetTree(OneParagraphTree(string.Join(' ', System.Linq.Enumerable.Repeat("alpha", 400))));
        var window = new Window { Width = 400, Height = 150, Content = view };
        window.Show();
        window.CaptureRenderedFrame();

        var before = ZoomFactor(view);
        var scrollBefore = view.ScrollOffset;
        window.MouseWheel(new Point(50, 50), new Vector(0, -1), RawInputModifiers.None); // wheel "down" scrolls forward
        var after = ZoomFactor(view);

        Assert.Equal(before, after, 3); // zoom untouched
        Assert.True(view.ScrollOffset > scrollBefore, "expected a plain wheel notch to scroll the document");
    }
}
