using System;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Media;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>S12-D (gap.md #36 "읽기 커서 밴드(reading-line band)"): mac paints a faint band across
/// the line the reading cursor sits on so a glance finds your place after a scroll
/// (ReaderTextView.swift:28,332-350, <c>drawReadingLine</c>) — the host had no equivalent
/// (grep 0 hits for "ReadingLine"/"reading.line"/"CurrentLineHighlight" per the gap audit).
///
/// The host's keyboard/scroll navigation moves <c>ScrollOffset</c> directly (it has no real text
/// caret the way mac's NSTextView subclass does), so this stands the TOP-OF-VIEWPORT line in for
/// mac's "line the reading cursor sits on" — computed once per frame via the SAME
/// <c>HitTestPosition</c> click-to-position primitive already used for selection (Point(0,0) in
/// surface space becomes "whatever character sits at the current scroll offset"), and hidden
/// whenever a real selection is active, mirroring <c>drawReadingLine</c>'s own
/// <c>selectedRange().length == 0</c> guard.
///
/// This class follows S9CFlowContentTests' own "read the private field back" convention (the
/// field, not pixels, is the assertable contract at this layer — <c>_readingLineAnchor</c> is
/// consumed purely to decide WHICH block/line to band, and the drawn rect's geometry is exactly
/// what <c>PaintHighlightRange</c>'s existing HitTestTextRange-based painting already draws
/// correctly for selection/find, so re-proving THAT geometry mechanism here would be redundant).</summary>
public class S12DReadingLineBandTests
{
    public S12DReadingLineBandTests() => AvaloniaHeadlessSetup.EnsureReady();

    /// <summary>Two ordinary paragraphs, each wrapping into MANY lines (a couple hundred words) so
    /// the document's total height is well over any headless test window's viewport — a short
    /// two-line fixture would let <see cref="FlowDocumentView.ScrollOffset"/>'s own
    /// content-vs-viewport clamp silently cap a "scroll into block 1" attempt back down to
    /// (near-)zero, which is exactly what happened the first time this fixture used two short
    /// sentences (the scroll test read block 0 twice, not because the fix was wrong but because
    /// the fixture never actually had anywhere to scroll TO).</summary>
    private static RenderTree TwoParagraphTree()
    {
        var alpha = string.Join(' ', Enumerable.Repeat("alpha", 300));
        var beta = string.Join(' ', Enumerable.Repeat("beta", 300));
        var json = $$"""
        {
          "schemaVersion": 1,
          "document": { "rootNodeId": 0, "defaultBodyFontSize": 12.0 },
          "nodes": [
            { "id": 0, "parentId": null, "type": "document", "children": [1, 3], "data": {} },
            { "id": 1, "parentId": 0, "type": "paragraph", "children": [2], "data": { "style": {} } },
            { "id": 2, "parentId": 1, "type": "textRun", "children": [],
              "data": { "text": {{JsonSerializer.Serialize(alpha)}}, "style": {} } },
            { "id": 3, "parentId": 0, "type": "paragraph", "children": [4], "data": { "style": {} } },
            { "id": 4, "parentId": 3, "type": "textRun", "children": [],
              "data": { "text": {{JsonSerializer.Serialize(beta)}}, "style": {} } }
          ]
        }
        """;
        return JsonSerializer.Deserialize<RenderTree>(json)!;
    }

    private static T GetPrivateField<T>(object obj, string name)
    {
        var field = typeof(FlowDocumentView).GetField(name, BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new InvalidOperationException($"FlowDocumentView.{name} not found — has it been renamed?");
        return (T)field.GetValue(obj)!;
    }

    [Fact]
    public void At_the_top_of_the_document_the_reading_line_anchor_lands_in_the_first_block()
    {
        var view = new FlowDocumentView();
        view.SetTree(TwoParagraphTree());
        var window = new Window { Width = 300, Height = 200, Content = view };
        window.Show();
        window.CaptureRenderedFrame();

        var anchor = GetPrivateField<TextPosition?>(view, "_readingLineAnchor");
        Assert.NotNull(anchor);
        Assert.Equal(0, anchor!.Value.BlockIndex);
    }

    [Fact]
    public void Scrolling_past_the_first_block_moves_the_reading_line_anchor_to_the_second_one()
    {
        var view = new FlowDocumentView();
        view.SetTree(TwoParagraphTree());
        var window = new Window { Width = 300, Height = 200, Content = view };
        window.Show();
        window.CaptureRenderedFrame(); // settle real heights/offsets first

        var offsets = GetPrivateField<double[]>(view, "_offsets");
        var maxScroll = Math.Max(0, view.ContentHeight - window.Height);
        Assert.True(maxScroll > offsets[1], // guards the fixture itself, not the fix under test
            $"fixture too short to prove scroll-following: maxScroll={maxScroll:F1} must exceed " +
            $"block 1's offset={offsets[1]:F1}, or ScrollOffset's own clamp caps every attempt " +
            "below it and this test can never actually reach block 1");
        // Scroll to just past where block 1 (the second paragraph) begins.
        view.ScrollOffset = offsets[1] + 2;
        window.CaptureRenderedFrame();

        var anchor = GetPrivateField<TextPosition?>(view, "_readingLineAnchor");
        Assert.NotNull(anchor);
        Assert.Equal(1, anchor!.Value.BlockIndex);
    }

    [Fact]
    public void An_active_selection_hides_the_reading_line_band_entirely()
    {
        var view = new FlowDocumentView();
        view.SetTree(TwoParagraphTree());
        var window = new Window { Width = 300, Height = 200, Content = view };
        window.Show();
        window.CaptureRenderedFrame();

        // A real, non-collapsed selection — mirrors drawReadingLine's own
        // `selectedRange().length == 0` guard (a stronger highlight already exists there).
        // SelectionModel is a pure, view-free model (by design — see its own class doc) and does
        // not call InvalidateVisual itself; the real pointer handlers that mutate it do. This test
        // bypasses those handlers, so it must invalidate explicitly or CaptureRenderedFrame has
        // nothing dirty to redraw and simply leaves the PREVIOUS frame's field values in place.
        view.Selection.Begin(new TextPosition(0, 0));
        view.Selection.ExtendTo(new TextPosition(0, 5));
        view.InvalidateVisual();
        window.CaptureRenderedFrame();

        var anchor = GetPrivateField<TextPosition?>(view, "_readingLineAnchor");
        Assert.Null(anchor);
    }

    [Fact]
    public void Clearing_the_selection_brings_the_reading_line_band_back()
    {
        var view = new FlowDocumentView();
        view.SetTree(TwoParagraphTree());
        var window = new Window { Width = 300, Height = 200, Content = view };
        window.Show();
        window.CaptureRenderedFrame();

        view.Selection.Begin(new TextPosition(0, 0));
        view.Selection.ExtendTo(new TextPosition(0, 5));
        view.InvalidateVisual();
        window.CaptureRenderedFrame();
        Assert.Null(GetPrivateField<TextPosition?>(view, "_readingLineAnchor"));

        view.Selection.Clear();
        view.InvalidateVisual();
        window.CaptureRenderedFrame();
        Assert.NotNull(GetPrivateField<TextPosition?>(view, "_readingLineAnchor"));
    }

    [Fact]
    public void The_reading_line_color_differs_between_light_and_dark_theme_and_is_never_fully_opaque()
    {
        var view = new FlowDocumentView();
        view.SetTree(TwoParagraphTree());
        var window = new Window { Width = 300, Height = 200, Content = view };
        window.RequestedThemeVariant = global::Avalonia.Styling.ThemeVariant.Light;
        window.Show();
        window.CaptureRenderedFrame();
        var light = GetPrivateField<Color>(view, "_readingLineColor");

        window.RequestedThemeVariant = global::Avalonia.Styling.ThemeVariant.Dark;
        window.CaptureRenderedFrame();
        var dark = GetPrivateField<Color>(view, "_readingLineColor");

        Assert.NotEqual(light, dark);
        // "Ambient, not a highlight" (ReaderTextView.swift:83) — both must stay faint enough that
        // ordinary text drawn under them stays fully legible.
        Assert.True(light.A < 0x40, $"expected a faint light-theme band, got alpha={light.A}");
        Assert.True(dark.A < 0x40, $"expected a faint dark-theme band, got alpha={dark.A}");
    }
}
