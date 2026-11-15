using System;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Styling;
using Avalonia.Themes.Fluent;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Panels;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>S12-I (gap.md #37 "키보드 내비게이션 … 문단/문서 단위 이동 … 대응 없음"): mac reaches
/// paragraph-unit movement with ⌥↑/⌥↓ and document-start/end with ⌘↑/⌘↓ (also fn⌘↑/fn⌘↓) — this
/// host had Up/Down/PageUp/PageDown/Home/End (line/page/document) but nothing at PARAGRAPH
/// granularity. Since this view has no real text caret (Navigation/TextNavigator.swift walks a
/// flattened NSString on mac; this host only has a scroll offset — see FlowDocumentView.OnKeyDown's
/// own S12-I comment), "paragraph" here means the nearest top-level FlowBlock boundary. Ctrl+Up/
/// Ctrl+Down do that; Ctrl+Home/Ctrl+End alias the existing bare Home/End (document start/end) for
/// users reaching for the Windows/Linux "Ctrl+arrow" convention.
///
/// Mirrors AccessibilityFixTests' own "2. keyboard scroll" fixture (same 10-short-paragraph tree,
/// same CreateScrollableView/PressKey shape) rather than inventing a third — this IS the same
/// feature area (FlowDocumentView.OnKeyDown), just testing the NEW branches it grew.</summary>
public class S12IKeyboardNavExtendedTests
{
    public S12IKeyboardNavExtendedTests() => AvaloniaHeadlessSetup.EnsureReady();

    private const string TreeJson = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": { "format": "markdown", "rootNodeId": 0, "defaultBodyFontSize": 12 },
        "nodes": [
          { "id": 0, "parentId": null, "children": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], "type": "document", "data": {} },
          { "id": 1, "parentId": 0, "children": [], "type": "paragraph", "data": { "text": "Line one of a long reading test document that needs real scroll room to move through.", "style": {} } },
          { "id": 2, "parentId": 0, "children": [], "type": "paragraph", "data": { "text": "Line two of a long reading test document that needs real scroll room to move through.", "style": {} } },
          { "id": 3, "parentId": 0, "children": [], "type": "paragraph", "data": { "text": "Line three of a long reading test document that needs real scroll room to move through.", "style": {} } },
          { "id": 4, "parentId": 0, "children": [], "type": "paragraph", "data": { "text": "Line four of a long reading test document that needs real scroll room to move through.", "style": {} } },
          { "id": 5, "parentId": 0, "children": [], "type": "paragraph", "data": { "text": "Line five of a long reading test document that needs real scroll room to move through.", "style": {} } },
          { "id": 6, "parentId": 0, "children": [], "type": "paragraph", "data": { "text": "Line six of a long reading test document that needs real scroll room to move through.", "style": {} } },
          { "id": 7, "parentId": 0, "children": [], "type": "paragraph", "data": { "text": "Line seven of a long reading test document that needs real scroll room to move through.", "style": {} } },
          { "id": 8, "parentId": 0, "children": [], "type": "paragraph", "data": { "text": "Line eight of a long reading test document that needs real scroll room to move through.", "style": {} } },
          { "id": 9, "parentId": 0, "children": [], "type": "paragraph", "data": { "text": "Line nine of a long reading test document that needs real scroll room to move through.", "style": {} } },
          { "id": 10, "parentId": 0, "children": [], "type": "paragraph", "data": { "text": "Line ten of a long reading test document that needs real scroll room to move through.", "style": {} } }
        ]
      }
    }
    """;

    private static RenderTree LoadTree()
    {
        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(TreeJson)!;
        Assert.True(envelope.IsOk);
        return envelope.Ok!.Value.Deserialize<RenderTree>()!;
    }

    private static void EnsureFluentThemeLoaded()
    {
        var app = Application.Current!;
        if (!app.Styles.OfType<FluentTheme>().Any())
        {
            app.Styles.Add(new FluentTheme());
        }
    }

    private static FlowDocumentView CreateScrollableView()
    {
        EnsureFluentThemeLoaded();
        var view = new FlowDocumentView();
        var window = new Window { Width = 400, Height = 120, Content = view }; // short viewport: 10 lines exceed it
        window.Show();
        view.SetTree(LoadTree());
        view.Measure(new Size(400, 120));
        view.Arrange(new Rect(0, 0, 400, 120));
        window.CaptureRenderedFrame(); // settles _offsets against real measured heights
        return view;
    }

    private static void PressKey(FlowDocumentView view, Key key, KeyModifiers modifiers = KeyModifiers.None)
    {
        view.RaiseEvent(new KeyEventArgs { RoutedEvent = InputElement.KeyDownEvent, Key = key, KeyModifiers = modifiers });
    }

    private static double[] Offsets(FlowDocumentView view)
    {
        var field = typeof(FlowDocumentView).GetField("_offsets", BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new InvalidOperationException("FlowDocumentView._offsets not found — has it been renamed?");
        return (double[])field.GetValue(view)!;
    }

    [Fact]
    public void CtrlDown_from_the_top_jumps_to_the_second_paragraphs_own_start()
    {
        var view = CreateScrollableView();
        var offsets = Offsets(view);
        Assert.Equal(0, view.ScrollOffset);

        PressKey(view, Key.Down, KeyModifiers.Control);

        Assert.Equal(offsets[1], view.ScrollOffset, 1);
    }

    [Fact]
    public void Repeated_CtrlDown_walks_forward_one_paragraph_boundary_per_press()
    {
        var view = CreateScrollableView();
        var offsets = Offsets(view);

        PressKey(view, Key.Down, KeyModifiers.Control);
        PressKey(view, Key.Down, KeyModifiers.Control);
        PressKey(view, Key.Down, KeyModifiers.Control);

        Assert.Equal(offsets[3], view.ScrollOffset, 1);
    }

    [Fact]
    public void CtrlUp_from_exactly_a_paragraphs_start_jumps_to_the_PREVIOUS_paragraphs_start()
    {
        // Mirrors TextNavigator.previousLineBoundary's own "already at the boundary -> go one
        // further" idiom, at block granularity — landing exactly on block 3's start and pressing
        // Ctrl+Up again must land on block 2's start, not re-land on block 3's own start.
        var view = CreateScrollableView();
        var offsets = Offsets(view);
        view.ScrollOffset = offsets[3];

        PressKey(view, Key.Up, KeyModifiers.Control);

        Assert.Equal(offsets[2], view.ScrollOffset, 1);
    }

    [Fact]
    public void CtrlUp_from_the_MIDDLE_of_a_paragraph_jumps_to_that_SAME_paragraphs_own_start()
    {
        var view = CreateScrollableView();
        var offsets = Offsets(view);
        // A point strictly inside block 3's own span, not at its start.
        view.ScrollOffset = offsets[3] + Math.Max(1.0, (offsets[4] - offsets[3]) / 2);

        PressKey(view, Key.Up, KeyModifiers.Control);

        Assert.Equal(offsets[3], view.ScrollOffset, 1);
    }

    [Fact]
    public void CtrlDown_at_the_last_paragraph_stays_there_instead_of_running_off_the_end()
    {
        var view = CreateScrollableView();
        // offsets[^2] (the last block's own start) sits ABOVE this short viewport's own maxScroll
        // (ScrollOffset's clamp: ContentHeight - Bounds.Height) — the fixture cannot actually
        // reach it, so anchor on the reachable ceiling instead, exactly the way End's own
        // clamp-parity test (AccessibilityFixTests.End_jumps_to_the_bottom…) does.
        var maxScroll = Math.Max(0, view.ContentHeight - view.Bounds.Height);
        view.ScrollOffset = maxScroll;

        PressKey(view, Key.Down, KeyModifiers.Control);
        PressKey(view, Key.Down, KeyModifiers.Control); // a second press must not creep further either

        Assert.Equal(maxScroll, view.ScrollOffset, 1);
    }

    [Fact]
    public void CtrlEnd_jumps_to_the_bottom_and_CtrlHome_returns_to_zero_same_as_plain_Home_End()
    {
        var view = CreateScrollableView();

        PressKey(view, Key.End, KeyModifiers.Control);
        var maxScroll = Math.Max(0, view.ContentHeight - view.Bounds.Height);
        Assert.Equal(maxScroll, view.ScrollOffset, 3);

        PressKey(view, Key.Home, KeyModifiers.Control);
        Assert.Equal(0, view.ScrollOffset);
    }

    [Fact]
    public void The_shortcut_guide_lists_the_new_paragraph_and_document_jump_combos()
    {
        var navigate = ShortcutGuideModel.Build().Single(g => g.Title == "Navigate");
        Assert.Contains(navigate.Entries, e => e.Keys == "Ctrl+Up / Ctrl+Down");
        Assert.Contains(navigate.Entries, e => e.Keys == "Ctrl+Home / Ctrl+End");
    }
}
