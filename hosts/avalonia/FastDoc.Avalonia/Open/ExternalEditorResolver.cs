using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.Versioning;
using System.Text.RegularExpressions;

namespace FastDoc.Avalonia.Open;

/// <summary>
/// S9-B3 batch 7 (docs/studio/sprints/S9/s9b1-full-parity.md #30, mirroring ExternalEditor.swift on
/// macOS): "Edit in &lt;App&gt;" for a currently-open READ-ONLY office document (docx/docm/dotx/
/// dotm/odt/hwp/hwpx — the same family this reader parses but never writes). macOS resolves and
/// LISTS every candidate app that declares it can open the file's type; this host narrows that to
/// the single app the OS reports as the CURRENT DEFAULT for the extension — "list at most what the
/// OS reports", per the dispatch — since neither Windows' nor Linux's default-handler query gives a
/// ranked candidate list the way macOS's Launch Services does. Actually LAUNCHING it reuses
/// <c>Rendering.IExternalLinkLauncher</c> (UseShellExecute already resolves the OS default handler
/// on every platform this targets), so this class's only job is naming that app for the menu label.
/// </summary>
public static class ExternalEditorResolver
{
    /// <summary>The seven read-only office extensions this feature applies to — same family
    /// CLAUDE.md's own "Word `.docx`/`.docm`/`.dotx`/`.dotm`, OpenDocument `.odt`, and Korean HWP
    /// `.hwp`/`.hwpx`" line names, lower-case and without the leading dot.</summary>
    public static readonly IReadOnlySet<string> OfficeExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "docx", "docm", "dotx", "dotm", "odt", "hwp", "hwpx",
    };

    public static bool IsOfficeExtension(string extensionWithOrWithoutDot)
    {
        var ext = extensionWithOrWithoutDot.TrimStart('.');
        return OfficeExtensions.Contains(ext);
    }

    /// <summary>The xdg MIME type <c>xdg-mime query default</c> takes for one of
    /// <see cref="OfficeExtensions"/> — the same strings
    /// <c>DefaultAppFamilies.LinuxCandidateMimeTypes</c> already lists for the SAME seven
    /// extensions' "Set as Default App" path, kept as ONE mapping here rather than a second copy of
    /// the extension-to-MIME association drifting from that one.</summary>
    public static string? LinuxMimeType(string extensionWithOrWithoutDot) => extensionWithOrWithoutDot.TrimStart('.').ToLowerInvariant() switch
    {
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "docm" => "application/vnd.ms-word.document.macroEnabled.12",
        "dotx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.template",
        "dotm" => "application/vnd.ms-word.template.macroEnabled.12",
        "odt" => "application/vnd.oasis.opendocument.text",
        "hwp" => "application/x-hwp",
        "hwpx" => "application/hwp+zip",
        _ => null,
    };

    /// <summary>Pulls the `Name=` line out of a `.desktop` file's `[Desktop Entry]` section — the
    /// display name a Linux default-app menu label should show, e.g. "LibreOffice Writer" rather
    /// than the `.desktop` FILENAME (`libreoffice-writer.desktop`) `xdg-mime query default` itself
    /// returns. A localized `Name[xx]=` line is deliberately ignored (this reader's own menus are
    /// English-only today) in favour of the unqualified `Name=`. Returns null when no
    /// `[Desktop Entry]` section or no `Name=` line is present — a malformed/missing file, not
    /// this reader's problem to fix.</summary>
    public static string? ParseDesktopEntryName(string desktopFileContents)
    {
        var inEntry = false;
        foreach (var rawLine in desktopFileContents.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.StartsWith('[')) { inEntry = line.Equals("[Desktop Entry]", StringComparison.Ordinal); continue; }
            if (!inEntry) { continue; }
            if (line.StartsWith("Name=", StringComparison.Ordinal)) { return line["Name=".Length..].Trim(); }
        }
        return null;
    }

    /// <summary>Extracts the executable's own file name (no directory, no extension) from a Windows
    /// registry `shell\open\command` value — e.g. `"C:\Program Files\Microsoft Office\WINWORD.EXE" "%1"`
    /// → `WINWORD`. A best-effort display name (mac's own candidate list shows real app display
    /// names via `Bundle`'s Info.plist; Windows' registry gives no equivalent short of parsing the
    /// exe's own version resource, which this batch does not add) — disclosed as narrower than the
    /// macOS feature, per this class's own doc. Returns null for a blank/unparseable command value.</summary>
    public static string? ParseWindowsCommandExeName(string? commandValue)
    {
        if (string.IsNullOrWhiteSpace(commandValue)) { return null; }
        var match = Regex.Match(commandValue, "\"([^\"]+\\.exe)\"", RegexOptions.IgnoreCase);
        var path = match.Success ? match.Groups[1].Value : commandValue.Split(' ')[0].Trim('"');
        if (string.IsNullOrWhiteSpace(path)) { return null; }
        // A registry value is always a Windows path (backslash-separated) regardless of which OS
        // this parsing runs on (a Linux/macOS dev machine running this suite never has a real
        // Windows registry to read, but the STRING shape is still Windows') — Path.GetFileName
        // splits on the CURRENT platform's own separator, so a manual split on both slash kinds is
        // used here instead of trusting Path to agree with a Windows string on a non-Windows host.
        var fileName = path.Split('\\', '/')[^1];
        var dot = fileName.LastIndexOf('.');
        return dot > 0 ? fileName[..dot] : fileName;
    }
}

/// <summary>The live half — actually asks the OS. Kept separate from
/// <see cref="ExternalEditorResolver"/>'s pure parsing functions so a test can drive the parsing
/// without a registry/xdg-mime call, matching the split <c>DefaultAppRegistration.cs</c> already
/// uses between its pure <c>DefaultAppFamilies</c> data and its live <c>IDefaultAppRegistrar</c>
/// implementations.</summary>
public interface IExternalEditorProbe
{
    /// <summary>The current default app's display name for <paramref name="extensionWithOrWithoutDot"/>,
    /// or null when none could be determined — never throws.</summary>
    string? DefaultAppName(string extensionWithOrWithoutDot);
}

[SupportedOSPlatform("windows")]
public sealed class WindowsExternalEditorProbe : IExternalEditorProbe
{
    public string? DefaultAppName(string extensionWithOrWithoutDot)
    {
        var ext = "." + extensionWithOrWithoutDot.TrimStart('.').ToLowerInvariant();
        try
        {
            using var extKey = Microsoft.Win32.Registry.ClassesRoot.OpenSubKey(ext);
            var progId = extKey?.GetValue(null) as string;
            if (string.IsNullOrWhiteSpace(progId)) { return null; }
            using var commandKey = Microsoft.Win32.Registry.ClassesRoot.OpenSubKey($@"{progId}\shell\open\command");
            var command = commandKey?.GetValue(null) as string;
            return ExternalEditorResolver.ParseWindowsCommandExeName(command);
        }
        catch
        {
            return null; // best-effort — never blocks the menu from opening over a registry read failure
        }
    }
}

/// <summary>Linux: `xdg-mime query default <mime>` (a synchronous child process, matching the
/// pattern <c>DefaultAppRegistration.cs</c>'s own <c>SystemProcessRunner</c> already uses for
/// `xdg-mime default`) names a `.desktop` FILE; that file is then found under the standard
/// `applications/` search path and its `Name=` parsed via
/// <see cref="ExternalEditorResolver.ParseDesktopEntryName"/>.</summary>
public sealed class LinuxExternalEditorProbe : IExternalEditorProbe
{
    /// <summary>XDG's own search order (freedesktop.org Base Directory spec) — user overrides
    /// first, then the system-wide locations `apt`/`dnf`/Flatpak/Snap packages install into.</summary>
    private static IEnumerable<string> ApplicationDirectories()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        yield return Path.Combine(home, ".local", "share", "applications");
        yield return "/usr/share/applications";
        yield return "/usr/local/share/applications";
        yield return "/var/lib/flatpak/exports/share/applications";
        yield return Path.Combine(home, ".local", "share", "flatpak", "exports", "share", "applications");
    }

    public string? DefaultAppName(string extensionWithOrWithoutDot)
    {
        var mime = ExternalEditorResolver.LinuxMimeType(extensionWithOrWithoutDot);
        if (mime is null) { return null; }
        try
        {
            var desktopFile = RunAndReadStdout("xdg-mime", $"query default {mime}")?.Trim();
            if (string.IsNullOrWhiteSpace(desktopFile)) { return null; }
            foreach (var dir in ApplicationDirectories())
            {
                var candidate = Path.Combine(dir, desktopFile);
                if (File.Exists(candidate))
                {
                    return ExternalEditorResolver.ParseDesktopEntryName(File.ReadAllText(candidate)) ?? desktopFile;
                }
            }
            return desktopFile; // found a name but not the file itself — still better than nothing
        }
        catch
        {
            return null; // best-effort — no xdg-mime on this system, or it failed
        }
    }

    private static string? RunAndReadStdout(string fileName, string arguments)
    {
        using var process = Process.Start(new ProcessStartInfo(fileName, arguments)
        {
            RedirectStandardOutput = true,
            UseShellExecute = false,
        });
        if (process is null) { return null; }
        var output = process.StandardOutput.ReadToEnd();
        process.WaitForExit(2000);
        return output;
    }
}

/// <summary>macOS/unsupported: no probe implemented — this host does not run there today
/// (SetDefaultAppMenuItem's own comment states the same for that feature), so returning null here
/// simply means the menu item falls back to a generic "Edit in Default App" label rather than
/// throwing.</summary>
public sealed class UnsupportedExternalEditorProbe : IExternalEditorProbe
{
    public string? DefaultAppName(string extensionWithOrWithoutDot) => null;
}

public static class ExternalEditorProbeFactory
{
    public static IExternalEditorProbe Create()
    {
        if (OperatingSystem.IsWindows()) { return new WindowsExternalEditorProbe(); }
        if (OperatingSystem.IsLinux()) { return new LinuxExternalEditorProbe(); }
        return new UnsupportedExternalEditorProbe();
    }
}
