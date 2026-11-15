using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Interactivity;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>S12-C (gap.md #31 "Edit in &lt;App&gt;" / #32 "읽기전용 배지(타이틀바)"): mac shows a
/// "read only" pill + an Edit button in a titlebar accessory for office documents
/// (DocumentWindowController.swift:172-179 wires the accessory, :1489-1552 builds it) — the host
/// previously had ONLY the File &gt; "Edit in Default App…" menu item (S9-B3 batch 7), no visible
/// affordance while reading. This adds a bar docked under the menu (Avalonia has no titlebar-
/// accessory API; PM's own brief allows "titlebar OR top bar") that shows the same badge+button
/// whenever a docx/odt/hwp/hwpx document is open, reusing the EXISTING
/// <c>Open.ExternalEditorResolver.IsOfficeExtension</c>/<c>IExternalEditorProbe</c>/
/// <c>IExternalLinkLauncher</c> machinery the menu item already used — no second "is this office"
/// check was introduced.
///
/// REVISE (team-lead, S12 wave-2): the original version of this file pinned the WIRING by reading
/// MainWindow's XAML/C# source as text (matching S9B3Batch7Tests' pre-existing style), because that
/// file's own doc comment says MainWindow's constructor "touches OS-specific machinery... that this
/// suite does not stand up headlessly". A lead mutation proved the cost of that choice: deleting
/// `Click="OnEditInAppClicked"` from the button's markup (so the button silently does nothing) left
/// every one of those tests green, because none of them exercised the actual Click→handler wiring —
/// they only checked that the STRING existed somewhere in the file. Source-string assertions break
/// when code is refactored and stay green when behavior is removed — the opposite of what a
/// regression test needs.
///
/// Re-measured for this revise: `new MainWindow()` DOES construct cleanly under
/// <c>AvaloniaHeadlessSetup</c> — the "no-args GUI-entry smoke" step of <c>Scripts/host-gate.sh</c>
/// already proves this every gate run (it launches the real window and exits 0) — so the earlier
/// "cannot stand up headlessly" premise no longer holds now that this file's own mutation run
/// showed exactly why source-string checks are not a safe fallback for it. The tests below
/// therefore instantiate the real window and observe real behavior: the bar's actual
/// <c>IsVisible</c> value after <see cref="SetCurrentPath"/>, and the button's actual routed
/// <c>Click</c> event — fired via <see cref="Button.RaiseEvent"/>, the SAME event a mouse click
/// raises — reaching a substituted <see cref="IExternalLinkLauncher"/> spy end to end. Both
/// `_currentPath` and `_externalEditorLauncher` are private instance fields with no public seam,
/// so reflection is used the same way <c>GetPrivateField</c> already does throughout this test
/// project — reflection reads/writes ignore C#'s `private`/`readonly` accessibility, which is
/// exactly what makes it usable here where no InternalsVisibleTo grant exists.</summary>
public class S12CTitlebarBadgeEditAffordanceTests
{
    public S12CTitlebarBadgeEditAffordanceTests() => AvaloniaHeadlessSetup.EnsureReady();

    private sealed class RecordingLinkLauncher : IExternalLinkLauncher
    {
        public readonly List<string> OpenedPaths = new();
        public void Open(string url) => OpenedPaths.Add(url);
    }

    private static FieldInfo Field(string name) =>
        typeof(MainWindow).GetField(name, BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new InvalidOperationException($"MainWindow.{name} not found — has it been renamed?");

    /// <summary>Sets the private `_currentPath` field directly rather than routing through
    /// `LoadPath` (which would parse a real document through the engine) — `UpdateEditInAppMenuItem`
    /// only ever reads the path's extension, so this exercises the identical decision the real
    /// LoadPath-driven call makes, without an engine round-trip or a real file on disk.</summary>
    private static void SetCurrentPath(MainWindow window, string? path)
    {
        Field("_currentPath").SetValue(window, path);
        var updateMethod = typeof(MainWindow).GetMethod("UpdateEditInAppMenuItem", BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new InvalidOperationException("MainWindow.UpdateEditInAppMenuItem not found — has it been renamed?");
        updateMethod.Invoke(window, null);
    }

    private static T GetNamedControl<T>(MainWindow window, string name) where T : class =>
        (T)(Field(name).GetValue(window)
            ?? throw new InvalidOperationException($"MainWindow.{name} is null — was it initialized by InitializeComponent?"));

    [Fact]
    public void Loading_an_office_document_shows_the_accessory_bar_and_loading_markdown_hides_it_again()
    {
        var window = new MainWindow();
        var bar = GetNamedControl<Border>(window, "OfficeAccessoryBar");

        Assert.False(bar.IsVisible); // no document open yet — matches mac's hidden-by-default badge

        SetCurrentPath(window, "/fake/path/report.docx");
        Assert.True(bar.IsVisible, "expected the accessory bar to become visible for a .docx document");

        SetCurrentPath(window, "/fake/path/notes.md");
        Assert.False(bar.IsVisible, "expected the accessory bar to hide again for a non-office document");
    }

    /// <summary>The mutation this revise responds to: deleting `Click="OnEditInAppClicked"` from
    /// the button's markup left the ORIGINAL source-string tests green. Firing the button's real
    /// routed Click event (not calling the handler method directly by name) is what actually
    /// exercises the XAML wiring — if that attribute is missing, this event never reaches
    /// `OnEditInAppClicked` and the spy launcher below never records anything.</summary>
    [Fact]
    public void Clicking_the_Edit_button_reaches_the_launcher_through_the_buttons_real_Click_event()
    {
        var window = new MainWindow();
        var spyLauncher = new RecordingLinkLauncher();
        Field("_externalEditorLauncher").SetValue(window, spyLauncher);
        SetCurrentPath(window, "/fake/path/report.docx");

        var button = GetNamedControl<Button>(window, "EditInAppButton");
        button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); // the same event a real mouse click raises

        Assert.Equal(new[] { "/fake/path/report.docx" }, spyLauncher.OpenedPaths);
    }

    [Fact]
    public void The_edit_button_shows_the_full_label_as_a_tooltip_mirroring_macs_short_title_plus_tooltip_split()
    {
        var window = new MainWindow();
        SetCurrentPath(window, "/fake/path/report.docx");
        var button = GetNamedControl<Button>(window, "EditInAppButton");
        var tip = ToolTip.GetTip(button);
        Assert.NotNull(tip);
        Assert.StartsWith("Edit in ", tip!.ToString());
    }

    [Fact]
    public void The_bar_reuses_the_existing_probe_and_launcher_no_second_resolver_is_introduced()
    {
        // Only one IExternalEditorProbe field and one IExternalLinkLauncher field exist on
        // MainWindow — a second copy would mean the bar grew its own resolution logic instead of
        // sharing the menu item's. This is a structural fact about the type, not the source text,
        // so it survives a refactor that changes field order or surrounding code.
        var probeFields = typeof(MainWindow).GetFields(BindingFlags.NonPublic | BindingFlags.Instance);
        var probeCount = 0;
        var launcherCount = 0;
        foreach (var f in probeFields)
        {
            if (f.FieldType.Name == "IExternalEditorProbe") { probeCount++; }
            if (f.FieldType == typeof(IExternalLinkLauncher)) { launcherCount++; }
        }
        Assert.Equal(1, probeCount);
        Assert.Equal(1, launcherCount);
    }
}
