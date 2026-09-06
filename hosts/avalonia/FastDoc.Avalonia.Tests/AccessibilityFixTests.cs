using System;
using System.Linq;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Styling;
using Avalonia.Themes.Fluent;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S6-F: closes the two accessibility blockers S6-D found in
/// docs/studio/sprints/S6/s6d-accessibility.md — keyboard scrolling was entirely absent from
/// FlowDocumentView (wheel-only), and its "auto" text colour was a fixed Brushes.Black regardless
/// of the FluentTheme dark/light variant the rest of the window follows.
///
/// Both assertions run against the SAME live-window setup (Application.Current + a real headless
/// Window hosting the view), because FlowDocumentView.UpdateThemeBrushes only resolves resources
/// once the view is attached to a rooted visual tree — see that method's own doc.
/// </summary>
public class AccessibilityFixTests
{
    public AccessibilityFixTests() => AvaloniaHeadlessSetup.EnsureReady();

    // A two-block markdown-shaped tree with plain text (undeclared colour -> ColorFrom's
    // Colors.Black "auto" default) and enough characters that EnsureEstimates's height guess
    // exceeds the window's viewport, so PageDown/End actually have somewhere to scroll TO.
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

    /// <summary>Ensures the shared headless Application carries a FluentTheme instance — idempotent
    /// across every test method in this class (and safe if some other test class in this same
    /// process already added one), since Application.Current is a process-wide singleton once
    /// AvaloniaHeadlessSetup's static constructor has run.</summary>
    private static void EnsureFluentThemeLoaded()
    {
        var app = Application.Current!;
        if (!app.Styles.OfType<FluentTheme>().Any())
        {
            app.Styles.Add(new FluentTheme());
        }
    }

    /// <summary>Hosts a fresh FlowDocumentView in a real (headless) Window forced to the given
    /// ThemeVariant, and returns it already attached — Window.Content attachment happens
    /// synchronously (a Window is its own root, unlike an ordinary child control), so no Show()
    /// or dispatcher pump is needed for OnAttachedToVisualTree to have already run.</summary>
    private static (Window Window, FlowDocumentView View) CreateAttachedView(ThemeVariant variant)
    {
        EnsureFluentThemeLoaded();
        var view = new FlowDocumentView();
        var window = new Window
        {
            RequestedThemeVariant = variant,
            Width = 400,
            Height = 300,
            Content = view,
        };
        window.Show();
        view.RefreshThemeBrushes();
        return (window, view);
    }

    // ---- 1. dark/light theme contrast ----------------------------------------------------------

    [Fact]
    public void Dark_theme_resolves_a_light_foreground_over_a_dark_background()
    {
        var (window, view) = CreateAttachedView(ThemeVariant.Dark);

        var fg = view.ThemeForegroundColor;
        var bg = view.ThemeBackgroundColor;
        Console.Error.WriteLine($"[S6-F] dark theme: foreground={fg} background={bg}");

        // "Light over dark", not a hardcoded palette match — background luma must sit clearly below
        // foreground luma, which is what a legible dark theme means regardless of the exact hex the
        // installed FluentTheme dark palette happens to use.
        Assert.True(Luma(fg) > Luma(bg), $"expected foreground luma > background luma in dark theme, got fg={fg} bg={bg}");
        Assert.True(Luma(bg) < 128, $"expected a dark background in dark theme, got {bg}");
    }

    [Fact]
    public void Light_theme_resolves_a_dark_foreground_over_a_light_background()
    {
        var (window, view) = CreateAttachedView(ThemeVariant.Light);

        var fg = view.ThemeForegroundColor;
        var bg = view.ThemeBackgroundColor;
        Console.Error.WriteLine($"[S6-F] light theme: foreground={fg} background={bg}");

        Assert.True(Luma(bg) > Luma(fg), $"expected background luma > foreground luma in light theme, got fg={fg} bg={bg}");
        Assert.True(Luma(bg) > 128, $"expected a light background in light theme, got {bg}");
    }

    [Fact]
    public void Dark_and_light_theme_foregrounds_differ_and_so_do_their_backgrounds()
    {
        var (darkWindow, darkView) = CreateAttachedView(ThemeVariant.Dark);
        var (lightWindow, lightView) = CreateAttachedView(ThemeVariant.Light);

        Assert.NotEqual(darkView.ThemeForegroundColor, lightView.ThemeForegroundColor);
        Assert.NotEqual(darkView.ThemeBackgroundColor, lightView.ThemeBackgroundColor);
    }

    private static double Luma(Color c) => 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B;

    // ---- 2. keyboard scroll ----------------------------------------------------------------------

    private static FlowDocumentView CreateScrollableView(out Window window)
    {
        EnsureFluentThemeLoaded();
        var view = new FlowDocumentView();
        window = new Window { Width = 400, Height = 120, Content = view }; // short viewport: 10 lines exceed it
        window.Show();
        view.SetTree(LoadTree());
        view.Measure(new Size(400, 120));
        view.Arrange(new Rect(0, 0, 400, 120));
        return view;
    }

    private static void PressKey(FlowDocumentView view, Key key, KeyModifiers modifiers = KeyModifiers.None)
    {
        var args = new KeyEventArgs
        {
            RoutedEvent = InputElement.KeyDownEvent,
            Key = key,
            KeyModifiers = modifiers,
        };
        view.RaiseEvent(args);
    }

    [Fact]
    public void PageDown_increases_scroll_offset()
    {
        var view = CreateScrollableView(out var window);
        Assert.Equal(0, view.ScrollOffset);

        PressKey(view, Key.PageDown);

        Assert.True(view.ScrollOffset > 0, $"expected ScrollOffset > 0 after PageDown, got {view.ScrollOffset}");
    }

    [Fact]
    public void PageUp_after_PageDown_returns_toward_the_top()
    {
        var view = CreateScrollableView(out var window);

        PressKey(view, Key.PageDown);
        PressKey(view, Key.PageDown);
        var afterTwoPageDowns = view.ScrollOffset;
        Assert.True(afterTwoPageDowns > 0);

        PressKey(view, Key.PageUp);

        Assert.True(view.ScrollOffset < afterTwoPageDowns,
            $"expected ScrollOffset to decrease after PageUp, was {afterTwoPageDowns} now {view.ScrollOffset}");
    }

    [Fact]
    public void Down_arrow_scrolls_by_a_small_line_step_less_than_PageDown()
    {
        var view = CreateScrollableView(out var window);

        PressKey(view, Key.Down);
        var afterArrow = view.ScrollOffset;
        Assert.True(afterArrow > 0, "Down arrow should move the scroll offset at all");

        view.ScrollOffset = 0;
        PressKey(view, Key.PageDown);
        var afterPage = view.ScrollOffset;

        Assert.True(afterArrow < afterPage,
            $"expected a single Down arrow step ({afterArrow}) to be smaller than a PageDown step ({afterPage})");
    }

    [Fact]
    public void End_jumps_to_the_bottom_and_Home_returns_to_zero()
    {
        var view = CreateScrollableView(out var window);

        PressKey(view, Key.End);
        var maxScroll = Math.Max(0, view.ContentHeight - view.Bounds.Height);
        Assert.True(view.ScrollOffset > 0, "End should move off the top for a document taller than the viewport");
        Assert.Equal(maxScroll, view.ScrollOffset, 3);

        PressKey(view, Key.Home);
        Assert.Equal(0, view.ScrollOffset);
    }

    [Fact]
    public void ShiftSpace_scrolls_up_and_plain_Space_scrolls_down()
    {
        var view = CreateScrollableView(out var window);

        PressKey(view, Key.Space);
        var afterSpace = view.ScrollOffset;
        Assert.True(afterSpace > 0);

        PressKey(view, Key.Space, KeyModifiers.Shift);
        Assert.True(view.ScrollOffset < afterSpace,
            $"expected Shift+Space to scroll back up from {afterSpace}, got {view.ScrollOffset}");
    }

    [Fact]
    public void Keyboard_scroll_reuses_the_same_ScrollOffset_property_the_wheel_handler_clamps()
    {
        // Regression guard for "no second scroll implementation": End must land EXACTLY where
        // directly setting ScrollOffset to a huge value would land (the property's own clamp),
        // proving OnKeyDown does not carry its own separate min/max logic.
        var view = CreateScrollableView(out var window);

        PressKey(view, Key.End);
        var viaKeyboard = view.ScrollOffset;

        view.ScrollOffset = 0;
        view.ScrollOffset = 999_999; // property itself clamps to ContentHeight - Bounds.Height
        var viaDirectClamp = view.ScrollOffset;

        Assert.Equal(viaDirectClamp, viaKeyboard, 3);
    }
}


