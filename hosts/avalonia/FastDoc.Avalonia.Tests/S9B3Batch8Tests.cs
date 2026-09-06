using System;
using System.IO;
using System.Reflection;
using FastDoc.Avalonia.Panels;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S9-B3 batch 8 (docs/studio/sprints/S9/s9b1-full-parity.md #1): Help > About FastDoc, mirroring
/// AppDelegate.swift:99,337-350. <see cref="AboutModel"/> carries every displayed value so this test
/// can assert them directly (branch-entry evidence: engine version is a KNOWN, documented omission,
/// not an accidental blank).
/// </summary>
public class S9B3Batch8Tests
{
    [Fact]
    public void ProductVersion_reads_the_built_assemblys_own_InformationalVersion()
    {
        var assembly = typeof(RenderTreeLoader).Assembly; // same assembly VersionFieldsTests checks
        var version = AboutModel.ProductVersion(assembly);
        Assert.StartsWith(VersionFieldsTests.MacAppShortVersion(), version);
    }

    [Fact]
    public void ProductVersion_falls_back_to_AssemblyVersion_when_informational_is_absent()
    {
        // The test assembly itself carries no AssemblyInformationalVersionAttribute (or an empty
        // one) in most build configs — this proves the fallback path does not throw and returns
        // SOMETHING version-shaped rather than null/blank.
        var assembly = typeof(S9B3Batch8Tests).Assembly;
        var version = AboutModel.ProductVersion(assembly);
        Assert.False(string.IsNullOrWhiteSpace(version));
    }

    [Fact]
    public void AppName_and_LicenceLine_are_non_blank_and_LicenceLine_names_the_MIT_license()
    {
        Assert.Equal("FastDoc", AboutModel.AppName);
        Assert.Contains("MIT", AboutModel.LicenceLine);
        Assert.Contains("DubDubDub", AboutModel.LicenceLine);
    }

    [Fact]
    public void EngineVersionNote_documents_the_omission_rather_than_faking_a_value()
    {
        // Branch-entry evidence for the dispatch's own instruction: "If an item genuinely needs
        // engine data the host does not decode, stop that item, record why". This asserts the
        // documented reason string exists and does NOT contain a fabricated version number shape
        // (no digit.digit.digit pattern), so a future edit cannot quietly swap in a guessed value.
        Assert.Contains("not exposed", AboutModel.EngineVersionNote, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotMatch(@"\d+\.\d+\.\d+", AboutModel.EngineVersionNote);
    }

    [Fact]
    public void FastdocEngine_native_bindings_genuinely_expose_no_version_export()
    {
        // Guards AboutModel.EngineVersionNote's own claim against drift: if a future engine adds a
        // version export, this test starts failing and both AboutModel and this note must be updated.
        var repoRoot = FindRepoRoot();
        var nativeDir = Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia", "Native");
        var hits = 0;
        foreach (var file in Directory.GetFiles(nativeDir, "*.cs"))
        {
            var text = File.ReadAllText(file);
            if (text.Contains("version", StringComparison.OrdinalIgnoreCase)) { hits++; }
        }
        Assert.Equal(0, hits);
    }

    [Fact]
    public void MainWindow_axaml_declares_an_About_menu_item_in_the_Help_menu()
    {
        var repoRoot = FindRepoRoot();
        var axaml = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia", "MainWindow.axaml"));
        Assert.Contains("AboutMenuItem", axaml);
        Assert.Contains("Header=\"_About FastDoc\"", axaml);
        Assert.Contains("OnShowAboutClicked", axaml);
    }

    [Fact]
    public void MainWindow_cs_tracks_one_About_window_and_focuses_it_on_a_second_open()
    {
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia", "MainWindow.axaml.cs"));
        Assert.Contains("_aboutWindow", source);
        Assert.Contains("existing.Activate()", source);
        Assert.Contains("_aboutWindow = null", source);
    }

    [Fact]
    public void AboutWindow_has_a_parameterless_constructor()
    {
        // Same AVLN3001 rationale as GoToLineWindow's own test.
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia",
            "Panels", "AboutWindow.axaml.cs"));
        Assert.Contains("public AboutWindow()", source);
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
