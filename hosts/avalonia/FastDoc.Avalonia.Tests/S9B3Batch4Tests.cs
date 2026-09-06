using System;
using System.IO;
using System.Linq;
using FastDoc.Avalonia.Panels;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S9-B3 batch 4 (docs/studio/sprints/S9/s9b1-full-parity.md #25/#29): File > Reload (mirrors
/// AppDelegate.swift:221) and Help > Welcome to FastDoc's re-open. Welcome to FastDoc was already
/// implemented in batch 1/S9-B2 (MainWindow.axaml's Help menu already carries
/// "_Welcome to FastDoc" / OnShowWelcomeClicked, asserted by S9B2ShortcutGuideTests) — this batch's
/// remaining scope is Reload only, checked here by source contract for the reasons every other
/// S9B3 test file states (constructing a real MainWindow needs Program.PendingDocumentPath /
/// StorageProvider plumbing this test project does not set up).
/// </summary>
public class S9B3Batch4Tests
{
    [Fact]
    public void MainWindow_axaml_declares_a_Reload_menu_item_with_Ctrl_R()
    {
        var repoRoot = FindRepoRoot();
        var axaml = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia", "MainWindow.axaml"));

        Assert.Contains("ReloadMenuItem", axaml);
        Assert.Contains("InputGesture=\"Ctrl+R\"", axaml);
        Assert.Contains("OnReloadClicked", axaml);
    }

    [Fact]
    public void MainWindow_axaml_still_declares_the_Welcome_menu_item_batch4_must_not_remove()
    {
        var repoRoot = FindRepoRoot();
        var axaml = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia", "MainWindow.axaml"));
        Assert.Contains("Header=\"_Welcome to FastDoc\"", axaml);
        Assert.Contains("OnShowWelcomeClicked", axaml);
    }

    [Fact]
    public void MainWindow_cs_OnReloadClicked_calls_LoadPath_with_the_current_path()
    {
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia", "MainWindow.axaml.cs"));

        Assert.Contains("private void OnReloadClicked(object? sender, RoutedEventArgs e)", source);
        Assert.Contains("if (_currentPath is { } path) { LoadPath(path); }", source);
    }

    [Fact]
    public void MainWindow_cs_enables_Reload_only_when_a_document_path_is_loaded()
    {
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia", "MainWindow.axaml.cs"));
        Assert.Contains("ReloadMenuItem.IsEnabled = _currentPath is not null;", source);
    }

    [Fact]
    public void MainWindow_cs_wires_Ctrl_R_as_a_window_level_accelerator_too()
    {
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia", "MainWindow.axaml.cs"));
        Assert.Contains("isAccel && e.Key == Key.R", source);
    }

    [Fact]
    public void ShortcutGuideModel_lists_Reload_and_it_is_in_MenuGestureKeys()
    {
        var groups = ShortcutGuideModel.Build();
        var file = groups.Single(g => g.Title == "File");
        Assert.Contains(file.Entries, e => e.Keys == "Ctrl+R" && e.Description.Contains("Reload"));
        Assert.Contains("Ctrl+R", ShortcutGuideModel.MenuGestureKeys);
    }

    private static string FindRepoRoot()
    {
        var dir = AppContext.BaseDirectory;
        while (dir is not null && !Directory.Exists(Path.Combine(dir, ".git")))
        {
            dir = Directory.GetParent(dir)?.FullName;
        }
        return dir ?? throw new InvalidOperationException("repo root not found");
    }
}
