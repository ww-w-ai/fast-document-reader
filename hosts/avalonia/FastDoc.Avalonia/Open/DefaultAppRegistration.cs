using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.Versioning;

namespace FastDoc.Avalonia.Open;

/// <summary>Registry access this host needs for Windows default-app registration, abstracted so a
/// test can supply a fake and never touch the real HKCU — side effects are injected, per this
/// repo's architecture discipline.</summary>
public interface IRegistryWriter
{
    void SetString(string keyPath, string? valueName, string value);
    void SetEmptyBinary(string keyPath, string valueName);
}

/// <summary>Runs an external process (xdg-mime, or opening an OS settings URI) — abstracted so a
/// test can supply a fake and never spawn a real process.</summary>
public interface IProcessRunner
{
    /// <returns>true if the process started and exited 0.</returns>
    bool Run(string fileName, IReadOnlyList<string> arguments);

    /// <returns>true if the shell accepted the request to open <paramref name="uri"/> (does not
    /// wait for whatever it opens — this is fire-and-forget, like opening a Settings page).</returns>
    bool OpenUri(string uri);
}

/// <summary>Whether a path exists — abstracted so <see cref="LinuxDefaultAppRegistrar"/>'s "is the
/// launcher installed" check, and <see cref="FirstRunNotice"/>'s flag-file check, are testable
/// without touching the real filesystem.</summary>
public interface IFileProbe
{
    bool Exists(string path);
}

[SupportedOSPlatform("windows")]
public sealed class Win32RegistryWriter : IRegistryWriter
{
    public void SetString(string keyPath, string? valueName, string value)
    {
        using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(keyPath)
            ?? throw new InvalidOperationException($"could not create registry key HKCU\\{keyPath}");
        key.SetValue(valueName, value, Microsoft.Win32.RegistryValueKind.String);
    }

    public void SetEmptyBinary(string keyPath, string valueName)
    {
        using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(keyPath)
            ?? throw new InvalidOperationException($"could not create registry key HKCU\\{keyPath}");
        key.SetValue(valueName, Array.Empty<byte>(), Microsoft.Win32.RegistryValueKind.Binary);
    }
}

public sealed class SystemProcessRunner : IProcessRunner
{
    public bool Run(string fileName, IReadOnlyList<string> arguments)
    {
        try
        {
            var psi = new ProcessStartInfo(fileName) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var arg in arguments) { psi.ArgumentList.Add(arg); }
            using var process = Process.Start(psi);
            if (process is null) { return false; }
            process.WaitForExit(5000);
            return process.HasExited && process.ExitCode == 0;
        }
        catch
        {
            return false;
        }
    }

    public bool OpenUri(string uri)
    {
        try
        {
            Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true });
            return true;
        }
        catch
        {
            return false;
        }
    }
}

public sealed class SystemFileProbe : IFileProbe
{
    public bool Exists(string path) => File.Exists(path);
}

/// <summary>The candidate file types "Set as Default App…" targets, split the same way the macOS
/// app's <c>DefaultAppClaim</c> splits into four families (Markdown / Word+OpenDocument / HWP /
/// plain text) — the same split docs/studio/sprints/S3/d5-file-assoc-print-dnd.md §3 limits
/// Linux's <c>xdg-mime default</c> to, so claiming the default does not also silently claim every
/// plain-text file on the system.</summary>
public static class DefaultAppFamilies
{
    /// <summary>MIME types <c>xdg-mime default</c> accepts, one entry per family, flattened — the
    /// same set d5-file-assoc-print-dnd.md §3 names as the four DEFAULT-eligible bundles (line
    /// 214's .desktop MimeType list already carries these among more candidates that are
    /// "open with" only, never default).</summary>
    public static readonly IReadOnlyList<string> LinuxCandidateMimeTypes = new[]
    {
        "text/markdown",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.ms-word.document.macroEnabled.12",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.template",
        "application/vnd.ms-word.template.macroEnabled.12",
        "application/vnd.oasis.opendocument.text",
        "application/x-hwp",
        "application/hwp+zip",
        "text/plain",
    };

    /// <summary>All 70 extensions this app opens — MUST stay identical to
    /// installers/windows/register.ps1's <c>$AllExtensions</c>. Kept as one shared list so the GUI
    /// path and the installer script always register the same "open with" candidates; a drift here
    /// would silently narrow (or widen) what the GUI claims versus what the script claims.</summary>
    public static readonly IReadOnlyList<string> WindowsOpenWithExtensions = new[]
    {
        "md", "markdown",
        "docx", "docm", "dotx", "dotm", "odt", "hwp", "hwpx",
        "txt", "text", "csv", "tsv", "log", "crash", "ips",
        "conf", "cfg", "ini", "env", "vars", "toml", "cnf",
        "yaml", "yml", "json", "xml", "jsonl", "ndjson",
        "tf", "tfvars", "hcl", "sls", "properties", "lock",
        "graphql", "gql", "proto", "thrift", "avsc",
        "xsd", "wsdl", "dtd", "resx", "strings", "po",
        "har", "http", "rest", "sql", "diff", "patch",
        "mk", "gradle", "cmake", "bzl",
        "rst", "adoc", "asciidoc", "org", "tex", "textile", "nfo",
        "vtt", "srt", "smi", "ass", "ssa", "sub", "lrc",
    };
}

public enum DefaultAppOutcome { Registered, Unsupported, Failed }

public sealed record DefaultAppResult(DefaultAppOutcome Outcome, string Message);

public interface IDefaultAppRegistrar
{
    DefaultAppResult Register();
}

/// <summary>Windows: writes exactly what installers/windows/register.ps1 writes under
/// <c>HKCU\Software\Classes</c> — a ProgId, its <c>DefaultIcon</c> ("&lt;exe&gt;,0"), its
/// <c>shell\open\command</c>, an <c>OpenWithProgids</c> entry per extension, and the
/// <c>RegisteredApplications</c> capabilities block — then opens Settings ▸ Default apps.
///
/// Windows 8+ protects <c>HKCU\...\FileExts\.ext\UserChoice</c> with a hash no application can
/// write (register.ps1's own <c>.DESCRIPTION</c>), so this can only offer FastDoc as a candidate;
/// the user finishes the actual pick in that Settings page, which is why this always opens it
/// rather than merely writing registry keys silently.</summary>
public sealed class WindowsDefaultAppRegistrar : IDefaultAppRegistrar
{
    private const string ProgId = "FastDoc.Document";
    private readonly IRegistryWriter _registry;
    private readonly IProcessRunner _process;
    private readonly string _exePath;

    public WindowsDefaultAppRegistrar(IRegistryWriter registry, IProcessRunner process, string exePath)
    {
        _registry = registry;
        _process = process;
        _exePath = exePath;
    }

    public DefaultAppResult Register()
    {
        try
        {
            _registry.SetString($@"Software\Classes\{ProgId}", null, "FastDoc Document");
            _registry.SetString($@"Software\Classes\{ProgId}\DefaultIcon", null, $"\"{_exePath}\",0");
            _registry.SetString($@"Software\Classes\{ProgId}\shell\open\command", null, $"\"{_exePath}\" \"%1\"");

            foreach (var ext in DefaultAppFamilies.WindowsOpenWithExtensions)
            {
                _registry.SetEmptyBinary($@"Software\Classes\.{ext}\OpenWithProgids", ProgId);
            }

            _registry.SetString(@"Software\FastDoc\Capabilities", "ApplicationName", "FastDoc");
            foreach (var ext in DefaultAppFamilies.WindowsOpenWithExtensions)
            {
                _registry.SetString(@"Software\FastDoc\Capabilities\FileAssociations", $".{ext}", ProgId);
            }
            _registry.SetString(@"Software\RegisteredApplications", "FastDoc", @"Software\FastDoc\Capabilities");

            _process.OpenUri("ms-settings:defaultapps");

            return new DefaultAppResult(DefaultAppOutcome.Registered,
                $"Registered as an \"open with\" candidate for {DefaultAppFamilies.WindowsOpenWithExtensions.Count} file types. " +
                "Windows does not let an app set itself as default — finish the pick in Settings > Default apps, which just opened.");
        }
        catch (Exception ex)
        {
            return new DefaultAppResult(DefaultAppOutcome.Failed, $"Registration failed: {ex.Message}");
        }
    }
}

/// <summary>Linux: points an ALREADY-INSTALLED launcher's default at itself via <c>xdg-mime
/// default</c> for the candidate MIME types <see cref="DefaultAppFamilies.LinuxCandidateMimeTypes"/>
/// names (the same four bundles installers/linux/install.sh's own printed instructions name).
/// This class never writes the <c>.desktop</c> file itself — installers/linux/install.sh owns
/// that — it only checks the file exists and, if so, runs the one command install.sh's final step
/// prints as a suggestion instead of running.</summary>
public sealed class LinuxDefaultAppRegistrar : IDefaultAppRegistrar
{
    public const string DesktopFileName = "ai.ww-w.fastdoc.desktop";

    private readonly IProcessRunner _process;
    private readonly IFileProbe _fileProbe;
    private readonly string _desktopFilePath;

    public LinuxDefaultAppRegistrar(IProcessRunner process, IFileProbe fileProbe, string desktopFilePath)
    {
        _process = process;
        _fileProbe = fileProbe;
        _desktopFilePath = desktopFilePath;
    }

    public DefaultAppResult Register()
    {
        if (!_fileProbe.Exists(_desktopFilePath))
        {
            return new DefaultAppResult(DefaultAppOutcome.Failed,
                $"No installed launcher found at {_desktopFilePath} — run installers/linux/install.sh first.");
        }

        var args = new List<string> { "default", DesktopFileName };
        args.AddRange(DefaultAppFamilies.LinuxCandidateMimeTypes);
        var ok = _process.Run("xdg-mime", args);

        return ok
            ? new DefaultAppResult(DefaultAppOutcome.Registered,
                $"Set as default for {DefaultAppFamilies.LinuxCandidateMimeTypes.Count} file types (Markdown, Word/OpenDocument, HWP, plain text).")
            : new DefaultAppResult(DefaultAppOutcome.Failed, "xdg-mime default failed — is xdg-utils installed?");
    }
}

/// <summary>macOS: this host's own build does not ship a menu item that reaches this — File ▸
/// "Set as Default App…" stays disabled there (MainWindow.axaml.cs checks
/// <c>OperatingSystem.IsMacOS()</c>) since the native FastDocReader app owns default-app claiming
/// on that platform (App/DefaultAppClaim.swift). This class exists only so the factory below has a
/// value to return rather than throwing on an unexpected platform.</summary>
public sealed class UnsupportedDefaultAppRegistrar : IDefaultAppRegistrar
{
    public DefaultAppResult Register() =>
        new DefaultAppResult(DefaultAppOutcome.Unsupported, "Set as Default App is not available on this platform.");
}

/// <summary>Picks the real registrar for the platform this process is running on — the one place
/// that constructs the real <see cref="IRegistryWriter"/>/<see cref="IProcessRunner"/>/<see
/// cref="IFileProbe"/> side effects; everything above takes them injected so tests never touch a
/// real registry, process, or filesystem.</summary>
public static class DefaultAppRegistrarFactory
{
    public static IDefaultAppRegistrar Create()
    {
        if (OperatingSystem.IsWindows())
        {
            var exePath = Environment.ProcessPath
                ?? Process.GetCurrentProcess().MainModule?.FileName
                ?? "FastDoc.Avalonia.exe";
            return new WindowsDefaultAppRegistrar(new Win32RegistryWriter(), new SystemProcessRunner(), exePath);
        }
        if (OperatingSystem.IsLinux())
        {
            var desktopPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".local", "share", "applications", LinuxDefaultAppRegistrar.DesktopFileName);
            return new LinuxDefaultAppRegistrar(new SystemProcessRunner(), new SystemFileProbe(), desktopPath);
        }
        return new UnsupportedDefaultAppRegistrar();
    }
}
