using System;
using System.IO;
using FastDoc.Avalonia.Open;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S9-B3 batch 7 (docs/studio/sprints/S9/s9b1-full-parity.md #30, mirroring ExternalEditor.swift on
/// macOS): File > "Edit in &lt;App&gt;…" for a currently-open read-only office document. Scope
/// disclosed narrower than macOS in Open/ExternalEditorResolver.cs's own doc — a single OS-reported
/// default handler, not a ranked candidate list — so this test file covers the PURE parsing/lookup
/// functions directly (no live registry/xdg-mime call needed) plus the menu wiring by source
/// contract (same rationale every other S9B3 test file states for MainWindow.axaml/.axaml.cs).
/// </summary>
public class S9B3Batch7Tests
{
    // ---- 1. IsOfficeExtension / LinuxMimeType (pure) -----------------------------------------------

    [Theory]
    [InlineData("docx")]
    [InlineData(".docx")]
    [InlineData("DOCX")]
    [InlineData("docm")]
    [InlineData("dotx")]
    [InlineData("dotm")]
    [InlineData("odt")]
    [InlineData("hwp")]
    [InlineData("hwpx")]
    public void IsOfficeExtension_accepts_the_seven_read_only_office_extensions_case_and_dot_insensitively(string ext)
    {
        Assert.True(ExternalEditorResolver.IsOfficeExtension(ext));
    }

    [Theory]
    [InlineData("md")]
    [InlineData("txt")]
    [InlineData("pdf")]
    [InlineData("")]
    public void IsOfficeExtension_rejects_everything_else(string ext)
    {
        Assert.False(ExternalEditorResolver.IsOfficeExtension(ext));
    }

    [Fact]
    public void LinuxMimeType_returns_a_mime_string_for_every_office_extension_and_null_otherwise()
    {
        foreach (var ext in ExternalEditorResolver.OfficeExtensions)
        {
            Assert.False(string.IsNullOrWhiteSpace(ExternalEditorResolver.LinuxMimeType(ext)));
        }
        Assert.Null(ExternalEditorResolver.LinuxMimeType("md"));
    }

    [Fact]
    public void LinuxMimeType_matches_DefaultAppFamilies_own_candidate_list_for_every_office_extension()
    {
        // Guards the "one mapping, not two copies" claim in ExternalEditorResolver's own doc.
        foreach (var ext in ExternalEditorResolver.OfficeExtensions)
        {
            var mime = ExternalEditorResolver.LinuxMimeType(ext);
            Assert.Contains(mime, DefaultAppFamilies.LinuxCandidateMimeTypes);
        }
    }

    // ---- 2. ParseDesktopEntryName (pure) ------------------------------------------------------------

    [Fact]
    public void ParseDesktopEntryName_reads_the_unqualified_Name_line_in_the_Desktop_Entry_section()
    {
        const string desktop = """
        [Desktop Entry]
        Type=Application
        Name=LibreOffice Writer
        Name[ko]=리브레오피스 라이터
        Exec=libreoffice --writer %U
        """;
        Assert.Equal("LibreOffice Writer", ExternalEditorResolver.ParseDesktopEntryName(desktop));
    }

    [Fact]
    public void ParseDesktopEntryName_ignores_Name_lines_outside_the_Desktop_Entry_section()
    {
        const string desktop = """
        [Desktop Action NewWindow]
        Name=New Window

        [Desktop Entry]
        Type=Application
        Name=Real App Name
        """;
        Assert.Equal("Real App Name", ExternalEditorResolver.ParseDesktopEntryName(desktop));
    }

    [Fact]
    public void ParseDesktopEntryName_returns_null_when_there_is_no_Name_line()
    {
        const string desktop = "[Desktop Entry]\nType=Application\n";
        Assert.Null(ExternalEditorResolver.ParseDesktopEntryName(desktop));
    }

    // ---- 3. ParseWindowsCommandExeName (pure) -------------------------------------------------------

    [Theory]
    [InlineData("\"C:\\Program Files\\Microsoft Office\\WINWORD.EXE\" \"%1\"", "WINWORD")]
    [InlineData("\"C:\\Program Files\\LibreOffice\\program\\soffice.exe\" --writer \"%1\"", "soffice")]
    public void ParseWindowsCommandExeName_extracts_the_quoted_exe_names_own_file_name(string command, string expected)
    {
        Assert.Equal(expected, ExternalEditorResolver.ParseWindowsCommandExeName(command));
    }

    [Fact]
    public void ParseWindowsCommandExeName_falls_back_to_the_first_unquoted_token()
    {
        Assert.Equal("notepad", ExternalEditorResolver.ParseWindowsCommandExeName("notepad.exe %1"));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void ParseWindowsCommandExeName_returns_null_for_blank_input(string? command)
    {
        Assert.Null(ExternalEditorResolver.ParseWindowsCommandExeName(command));
    }

    // ---- 4. probe factory picks by OS, never throws -------------------------------------------------

    [Fact]
    public void ExternalEditorProbeFactory_creates_a_probe_matching_the_current_OS_and_it_never_throws()
    {
        var probe = ExternalEditorProbeFactory.Create();
        Assert.NotNull(probe);
        // Never throws even off the OS it targets (e.g. the Linux probe on a machine without
        // xdg-mime installed, or a nonexistent extension) — best-effort per each probe's own doc.
        var name = probe.DefaultAppName("docx");
        _ = name; // may be null; the assertion is "did not throw"
    }

    // ---- 5. menu wiring (source contract, same rationale as every other S9B3 test file) -----------

    [Fact]
    public void MainWindow_axaml_declares_the_Edit_in_App_menu_item()
    {
        var repoRoot = FindRepoRoot();
        var axaml = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia", "MainWindow.axaml"));
        Assert.Contains("EditInAppMenuItem", axaml);
        Assert.Contains("OnEditInAppClicked", axaml);
    }

    [Fact]
    public void MainWindow_cs_enables_Edit_in_App_only_for_office_extensions_and_relabels_it()
    {
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia", "MainWindow.axaml.cs"));
        Assert.Contains("Open.ExternalEditorResolver.IsOfficeExtension(extension)", source);
        Assert.Contains("EditInAppMenuItem.IsEnabled = isOffice;", source);
        Assert.Contains("EditInAppMenuItem.Header = appName is null ? \"Edit in Default App…\" : $\"Edit in {appName}…\";", source);
    }

    [Fact]
    public void MainWindow_cs_launches_via_the_same_IExternalLinkLauncher_seam_link_clicks_use()
    {
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia", "MainWindow.axaml.cs"));
        Assert.Contains("Rendering.IExternalLinkLauncher _externalEditorLauncher = new Rendering.ProcessExternalLinkLauncher();", source);
        Assert.Contains("if (_currentPath is { } path) { _externalEditorLauncher.Open(path); }", source);
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
