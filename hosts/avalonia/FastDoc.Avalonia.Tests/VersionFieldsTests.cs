using System.Reflection;
using System.Text.RegularExpressions;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// The Avalonia host carries the SAME version number as the macOS app: one product, one number on
/// the GitHub Release page, three hosts. The macOS app's number lives in Resources/Info.plist
/// (CFBundleShortVersionString); the host's in hosts/avalonia/FastDoc.Avalonia/FastDoc.Avalonia.csproj
/// (Version / AssemblyVersion / FileVersion / InformationalVersion). Nothing generates one from the
/// other, so this test is the drift guard: it reads the plist and the BUILT assembly's own metadata
/// (not the csproj text — an edit that does not reach the compiled DLL must fail too).
/// </summary>
public class VersionFieldsTests
{
    /// <summary>CFBundleShortVersionString from the macOS app's Info.plist, e.g. "1.4.2".</summary>
    public static string MacAppShortVersion()
    {
        var plist = Path.Combine(FindRepoRoot(), "Resources", "Info.plist");
        var text = File.ReadAllText(plist);
        var match = Regex.Match(text, @"<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>");
        Assert.True(match.Success, "CFBundleShortVersionString not found in " + plist);
        return match.Groups[1].Value;
    }

    [Fact]
    public void Built_assembly_carries_the_macOS_apps_version_number()
    {
        var expected = MacAppShortVersion();
        Assert.Matches(@"^\d+\.\d+\.\d+$", expected); // the plist itself must be well-formed for this to mean anything

        var assembly = typeof(RenderTreeLoader).Assembly;
        Assert.Equal(System.Version.Parse(expected + ".0"), assembly.GetName().Version);

        // dotnet appends "+<git sha>" (SourceRevisionId) to InformationalVersion by default when
        // building inside a git repo, so this checks the declared prefix rather than equality.
        var informational = assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()
            ?.InformationalVersion;
        Assert.StartsWith(expected, informational);
    }

    private static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "CLAUDE.md")))
        {
            dir = dir.Parent;
        }
        return dir?.FullName
            ?? throw new InvalidOperationException("could not find repo root (no CLAUDE.md in any parent directory)");
    }
}
