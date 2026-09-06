using System.Collections.Generic;
using Avalonia.Input;

namespace FastDoc.Avalonia.Panels;

/// <summary>One row of the Keyboard Shortcuts guide — the key combo as this host displays it
/// (platform modifier already resolved to "Ctrl", since Avalonia's HotKey/InputGesture syntax does
/// not remap to "Cmd" on macOS either — see <see cref="ShortcutGuideModel"/>'s own note) and what
/// it does, in the reader's own words rather than the handler method name.</summary>
public sealed record ShortcutEntry(string Keys, string Description);

/// <summary>One named group of <see cref="ShortcutEntry"/> rows, in display order.</summary>
public sealed record ShortcutGroup(string Title, IReadOnlyList<ShortcutEntry> Entries);

/// <summary>
/// S9-B2: the single source both the "?" Keyboard Shortcuts window and (via
/// <see cref="MenuGestureKeys"/>) a test asserting menu/guide agreement draw from — mirrors the
/// macOS app's own Keyboard Shortcuts window (docs/studio/sprints/S9/s9b1-full-parity.md), but
/// lists ONLY what this Avalonia host actually implements today: every entry below has a matching
/// <c>InputGesture</c>/<c>HotKey</c> in MainWindow.axaml or a key branch in
/// <c>MainWindow.OnWindowKeyDown</c> / <c>FlowDocumentView.OnKeyDown</c> — grepped, not guessed, on
/// 2026-09-06. This host has no Cmd key of its own: Avalonia's HotKey/InputGesture strings do not
/// remap "Ctrl" to "Cmd" on macOS (the same reason MainWindow.OnWindowKeyDown checks both
/// KeyModifiers.Control and KeyModifiers.Meta explicitly), so "Ctrl" here is the one label that is
/// already correct on Windows AND Linux AND this host's own macOS build.
/// </summary>
public static class ShortcutGuideModel
{
    public static IReadOnlyList<ShortcutGroup> Build() => new[]
    {
        new ShortcutGroup("File", new[]
        {
            new ShortcutEntry("Ctrl+O", "Open…"),
            new ShortcutEntry("Ctrl+R", "Reload from disk"),
            new ShortcutEntry("Ctrl+P", "Export PDF…"),
        }),
        new ShortcutGroup("Edit", new[]
        {
            new ShortcutEntry("Ctrl+A", "Select all"),
            new ShortcutEntry("Ctrl+C", "Copy selection"),
            new ShortcutEntry("Esc", "Clear selection"),
        }),
        new ShortcutGroup("View", new[]
        {
            new ShortcutEntry("Ctrl+Shift+P", "Toggle Page Mode"),
            new ShortcutEntry("Ctrl+Shift+M", "Toggle Master Page Furniture (page mode only)"),
            new ShortcutEntry("Ctrl+Shift+B", "Toggle Split Tables Across Pages (page mode only)"),
            new ShortcutEntry("Ctrl+Shift+O", "Toggle Table of Contents"),
            new ShortcutEntry("Ctrl+Shift+C", "Toggle Comments"),
            new ShortcutEntry("Ctrl+Shift+L", "Toggle Line Numbers (flow mode only)"),
            new ShortcutEntry("Ctrl+L", "Go to Line… (flow mode only)"),
            new ShortcutEntry("Ctrl++", "Zoom in"),
            new ShortcutEntry("Ctrl+-", "Zoom out"),
            new ShortcutEntry("Ctrl+0", "Reset zoom"),
        }),
        new ShortcutGroup("Navigate", new[]
        {
            new ShortcutEntry("Up / Down", "Scroll one line"),
            new ShortcutEntry("Page Up / Page Down", "Scroll one page"),
            new ShortcutEntry("Home / End", "Jump to document start / end"),
        }),
        new ShortcutGroup("Find", new[]
        {
            new ShortcutEntry("Ctrl+F", "Show the find bar"),
            new ShortcutEntry("Enter", "Find next"),
            new ShortcutEntry("Shift+Enter", "Find previous"),
            new ShortcutEntry("Esc", "Close the find bar"),
        }),
        new ShortcutGroup("Help", new[]
        {
            new ShortcutEntry("? or F1", "Keyboard Shortcuts (this window)"),
        }),
    };

    /// <summary>Every key combo this table carries that also appears as a MenuItem
    /// InputGesture/HotKey in MainWindow.axaml — used by the test that parses the axaml and checks
    /// each gesture string is represented here, so the guide cannot silently fall behind the menu.</summary>
    public static IReadOnlySet<string> MenuGestureKeys { get; } = new HashSet<string>
    {
        "Ctrl+O", "Ctrl+R", "Ctrl+P", "Ctrl+Shift+P", "Ctrl+Shift+M", "Ctrl+Shift+B", "Ctrl+Shift+O", "Ctrl+Shift+C",
        "Ctrl+Shift+L", "Ctrl+L", "F1",
    };

    /// <summary>Pure key-decision behind MainWindow.OnWindowKeyDown's "?"/F1 branch, pulled out so
    /// a headless test can drive every case (OemQuestion, F1, an unrelated key, either key while
    /// the find box has focus) without constructing a real MainWindow/Window -- MainWindow.axaml.cs
    /// calls this directly rather than re-deriving the same two-key check (see
    /// <c>S9B2ShortcutGuideTests.MainWindow_OnWindowKeyDown_actually_calls_ShouldOpenFromKey</c>,
    /// which greps the source to keep the two from drifting apart).
    ///
    /// <paramref name="findTextBoxFocused"/> guards both keys, not just "?": MainWindow's key
    /// handler runs during the Tunnel phase, BEFORE the find box's own KeyDown, so an unguarded F1
    /// there would swallow the keystroke just as an unguarded "?" would -- neither should fire
    /// while the reader is typing into the find bar.</summary>
    public static bool ShouldOpenFromKey(Key key, bool findTextBoxFocused)
    {
        if (findTextBoxFocused) { return false; }
        return key == Key.OemQuestion || key == Key.F1;
    }

    /// <summary>S9-B2 VM follow-up: how tall <see cref="ShortcutGuideWindow"/> is allowed to grow
    /// before its <c>ScrollViewer</c> takes over, as a pure function of the screen's own working
    /// area -- pulled out of the window's constructor so a headless test can drive it directly
    /// (a live <c>Screens.Primary</c> needs a real display, which this test project's headless
    /// platform does not provide). <paramref name="workingAreaHeightPx"/> and
    /// <paramref name="scaling"/> come straight from Avalonia's <c>Screen.WorkingArea.Height</c>
    /// and <c>Screen.Scaling</c> (physical pixels and that screen's own DPI factor); the result is
    /// in the window's own DIPs, which is what <c>Window.MaxHeight</c> expects. A non-positive
    /// scaling (should not happen on a real screen, but guards a malformed test input the same way
    /// a real `Screen.Scaling` of 0 would otherwise divide-by-zero into an unbounded window)
    /// resolves to 1.0 rather than propagating NaN/Infinity into layout.</summary>
    public static double ComputeMaxHeight(double workingAreaHeightPx, double scaling, double fraction = 0.9)
    {
        var safeScaling = scaling > 0 ? scaling : 1.0;
        return workingAreaHeightPx / safeScaling * fraction;
    }
}
