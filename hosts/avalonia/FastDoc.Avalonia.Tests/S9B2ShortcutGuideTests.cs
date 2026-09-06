using System;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using Avalonia.Input;
using FastDoc.Avalonia.Panels;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S9-B2: the "?" / F1 Keyboard Shortcuts window and its Help-menu mirror
/// (docs/studio/sprints/S9/s9b2-help.md). Three things are checked: the model has real
/// branch-entry evidence (not an empty shell), every InputGesture MainWindow.axaml actually
/// declares is represented in the guide (so the two cannot drift apart), and the "?" key branch
/// resolves to the same open-guide path the menu item's Click handler does.
/// </summary>
public class S9B2ShortcutGuideTests
{
    // ---- 1. model has real content -------------------------------------------------------------

    [Fact]
    public void Model_has_at_least_five_groups_and_every_group_has_entries()
    {
        var groups = ShortcutGuideModel.Build();
        Assert.True(groups.Count >= 5, $"expected >= 5 groups, got {groups.Count}");
        foreach (var group in groups)
        {
            Assert.False(string.IsNullOrWhiteSpace(group.Title));
            Assert.NotEmpty(group.Entries);
            foreach (var entry in group.Entries)
            {
                Assert.False(string.IsNullOrWhiteSpace(entry.Keys));
                Assert.False(string.IsNullOrWhiteSpace(entry.Description));
            }
        }
    }

    [Fact]
    public void Model_has_a_Help_group_documenting_the_guide_itself()
    {
        var groups = ShortcutGuideModel.Build();
        var help = groups.SingleOrDefault(g => g.Title == "Help");
        Assert.NotNull(help);
        Assert.Contains(help!.Entries, e => e.Keys.Contains("F1") && e.Keys.Contains("?"));
    }

    // ---- 2. every menu InputGesture/HotKey in MainWindow.axaml appears in the guide -------------

    [Fact]
    public void Every_MainWindow_axaml_InputGesture_is_represented_in_the_shortcut_guide()
    {
        var mainWindowAxamlPath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,
            "..", "..", "..", "..", "FastDoc.Avalonia", "MainWindow.axaml"));
        Assert.True(File.Exists(mainWindowAxamlPath), $"expected MainWindow.axaml at {mainWindowAxamlPath}");

        var axamlText = File.ReadAllText(mainWindowAxamlPath);
        var gestures = Regex.Matches(axamlText, "InputGesture=\"([^\"]+)\"")
            .Select(m => m.Groups[1].Value)
            .Distinct()
            .ToList();

        // Sanity: the parse actually found the gestures this test knows the menu declares --
        // guards against a silently-broken regex reporting a vacuous pass.
        Assert.True(gestures.Count >= 6, $"expected >= 6 InputGesture declarations, parsed {gestures.Count}");

        var groups = ShortcutGuideModel.Build();
        var allKeyLabels = groups.SelectMany(g => g.Entries).Select(e => e.Keys).ToList();

        foreach (var gesture in gestures)
        {
            Assert.True(ShortcutGuideModel.MenuGestureKeys.Contains(gesture),
                $"'{gesture}' is declared as an InputGesture in MainWindow.axaml but is not in " +
                $"ShortcutGuideModel.MenuGestureKeys — the guide's coverage list has fallen behind the menu.");
            Assert.True(allKeyLabels.Any(label => label.Contains(gesture)),
                $"'{gesture}' is in MenuGestureKeys but no ShortcutGuideModel entry's Keys field " +
                "contains it — the guide would not actually show this shortcut to the reader.");
        }
    }

    [Fact]
    public void MainWindow_axaml_declares_a_Help_menu_with_the_shortcut_guide_and_welcome_items()
    {
        var mainWindowAxamlPath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,
            "..", "..", "..", "..", "FastDoc.Avalonia", "MainWindow.axaml"));
        var axamlText = File.ReadAllText(mainWindowAxamlPath);

        Assert.Contains("Header=\"_Help\"", axamlText);
        Assert.Contains("OnShowShortcutGuideClicked", axamlText);
        Assert.Contains("OnShowWelcomeClicked", axamlText);
    }

    // ---- 3. the "?" key maps to Key.OemQuestion, the branch MainWindow.OnWindowKeyDown checks ----

    [Fact]
    public void The_question_mark_key_is_OemQuestion_and_distinct_from_F1()
    {
        // Avalonia has no separate "?" key constant -- "?" is Shift+/ on a US layout, and
        // Key.OemQuestion is the physical key both cases share. This asserts the enum member
        // ShortcutGuideModel.ShouldOpenFromKey depends on actually exists and is distinct from F1,
        // so a future Avalonia upgrade that renamed/removed it would fail loudly here rather than
        // only at a reader's keyboard.
        Assert.True(Enum.IsDefined(typeof(Key), Key.OemQuestion));
        Assert.NotEqual(Key.OemQuestion, Key.F1);
    }

    // ---- 3b. the actual key-decision predicate, driven directly (headless-Window-free) -----------
    // Root cause of the gap this batch closes: MainWindow.OnWindowKeyDown used to inline
    // "e.Key == Key.OemQuestion || e.Key == Key.F1" and nothing here called that branch, so a
    // mutation collapsing OemQuestion into F1 left all prior tests green. ShouldOpenFromKey is the
    // SAME condition, pulled out so it is callable -- and therefore mutation-testable -- without a
    // live Window.

    [Theory]
    [InlineData(Key.OemQuestion, false, true)]
    [InlineData(Key.F1, false, true)]
    [InlineData(Key.OemQuestion, true, false)]
    [InlineData(Key.F1, true, false)]
    [InlineData(Key.A, false, false)]
    [InlineData(Key.Enter, false, false)]
    public void ShouldOpenFromKey_matches_key_and_find_focus_state(Key key, bool findFocused, bool expected)
    {
        Assert.Equal(expected, ShortcutGuideModel.ShouldOpenFromKey(key, findFocused));
    }

    [Fact]
    public void MainWindow_OnWindowKeyDown_actually_calls_ShouldOpenFromKey()
    {
        // The Theory above proves the PREDICATE is correct; this proves MainWindow's real key
        // handler actually consults it (rather than, say, retaining a separate inline condition
        // alongside an unused predicate) -- source contract, matching this file's other
        // MainWindow.axaml.cs checks, since driving MainWindow's real OnWindowKeyDown needs a full
        // constructed window (see the report's note on why those other checks are source-level too).
        var mainWindowCsPath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,
            "..", "..", "..", "..", "FastDoc.Avalonia", "MainWindow.axaml.cs"));
        Assert.True(File.Exists(mainWindowCsPath), $"expected MainWindow.axaml.cs at {mainWindowCsPath}");
        var source = File.ReadAllText(mainWindowCsPath);

        Assert.Contains("ShortcutGuideModel.ShouldOpenFromKey(e.Key, FindTextBox.IsFocused)", source);
        Assert.Contains("ShowShortcutGuide()", source);
        // The old inline condition must be GONE, not merely supplemented -- otherwise the source
        // could call ShouldOpenFromKey and still branch on a stale duplicate underneath it.
        Assert.DoesNotContain("e.Key == Key.OemQuestion", source);
    }

    // ---- 4. opening twice is idempotent (focuses the existing window) ----------------------------

    [Fact]
    public void MainWindow_tracks_one_shortcut_guide_window_field_and_clears_it_on_Closed()
    {
        // A live two-Window open/focus/close cycle needs a full headless Application + top-level
        // Window (MainWindow's own constructor touches Program.PendingDocumentPath, StorageProvider
        // etc. that this test file does not set up) -- so, matching this test file's other source-
        // level checks, this asserts the idempotence MECHANISM (a single tracked field, checked
        // before construction, cleared on Closed) is actually present in MainWindow's source,
        // rather than re-deriving a fixture the other three tests here do not need either.
        var mainWindowCsPath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,
            "..", "..", "..", "..", "FastDoc.Avalonia", "MainWindow.axaml.cs"));
        var source = File.ReadAllText(mainWindowCsPath);

        Assert.Contains("_shortcutGuideWindow", source);
        Assert.Contains("existing.Activate()", source);
        Assert.Contains("_shortcutGuideWindow = null", source);
    }

    // ---- 5. VM follow-up: the window fits a short display (S9-B2 VM report) ---------------------
    // The Ubuntu/GNOME VM showed the guide clipped at "Home / End" with the Find and Help groups
    // unreachable (a fixed Height="480" with no room to grow) and with no titlebar/close button.
    // The fix moved to SizeToContent="Height" (open-ended growth) capped by a MaxHeight computed
    // from the screen's own working area, plus an explicit WindowDecorations="Full". This section
    // covers the pure cap arithmetic directly and the two XAML/constructor wirings by source
    // contract -- a live too-short screen cannot be constructed in the headless test platform.

    [Theory]
    [InlineData(1080.0, 1.0, 972.0)] // 1080p, 100% scaling: 1080 * 0.9
    [InlineData(2160.0, 2.0, 972.0)] // same physical screen at 200% scaling -> same DIP result
    [InlineData(768.0, 1.0, 691.2)] // a short 1366x768 laptop panel
    public void ComputeMaxHeight_caps_at_90_percent_of_the_screens_working_area_in_DIPs(
        double workingAreaHeightPx, double scaling, double expected)
    {
        Assert.Equal(expected, ShortcutGuideModel.ComputeMaxHeight(workingAreaHeightPx, scaling), precision: 6);
    }

    [Fact]
    public void ComputeMaxHeight_treats_a_non_positive_scaling_as_1_rather_than_dividing_by_zero()
    {
        Assert.Equal(900.0, ShortcutGuideModel.ComputeMaxHeight(1000.0, 0.0), precision: 6);
        Assert.False(double.IsInfinity(ShortcutGuideModel.ComputeMaxHeight(1000.0, -1.0)));
    }

    [Fact]
    public void ShortcutGuideWindow_axaml_sizes_to_content_height_and_declares_full_window_decorations()
    {
        var axamlPath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,
            "..", "..", "..", "..", "FastDoc.Avalonia", "Panels", "ShortcutGuideWindow.axaml"));
        Assert.True(File.Exists(axamlPath), $"expected ShortcutGuideWindow.axaml at {axamlPath}");
        var axamlText = File.ReadAllText(axamlPath);

        Assert.Contains("SizeToContent=\"Height\"", axamlText);
        // A fixed pixel Height (the VM-reported clipping cause) must not be back -- distinct from
        // the ItemsControl/Grid template's own internal Height-less rows, so this checks the
        // Window's own opening attribute block specifically.
        Assert.DoesNotContain("Height=\"480\"", axamlText);
        Assert.Contains("WindowDecorations=\"Full\"", axamlText);
        Assert.Contains("VerticalScrollBarVisibility=\"Auto\"", axamlText);
    }

    [Fact]
    public void ShortcutGuideWindow_constructor_actually_computes_and_applies_MaxHeight()
    {
        var csPath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,
            "..", "..", "..", "..", "FastDoc.Avalonia", "Panels", "ShortcutGuideWindow.axaml.cs"));
        Assert.True(File.Exists(csPath), $"expected ShortcutGuideWindow.axaml.cs at {csPath}");
        var source = File.ReadAllText(csPath);

        Assert.Contains("ShortcutGuideModel.ComputeMaxHeight(", source);
        Assert.Contains("MaxHeight =", source);
        // Reads from the SAME screen the window is about to appear on, not a hardcoded guess.
        Assert.Contains("Screens", source);
        Assert.Contains(".WorkingArea.Height", source);
        Assert.Contains(".Scaling", source);
    }
}
