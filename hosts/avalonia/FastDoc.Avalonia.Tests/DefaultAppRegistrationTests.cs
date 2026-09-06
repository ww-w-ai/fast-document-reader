using System.Collections.Generic;
using FastDoc.Avalonia.Open;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S8-B2 ②: WindowsDefaultAppRegistrar / LinuxDefaultAppRegistrar against FAKE IRegistryWriter/
/// IProcessRunner/IFileProbe — per this sprint's dispatch instructions ("side effects are
/// injected, tests never touch the real registry"), never Microsoft.Win32.Registry, never a real
/// xdg-mime process, never the real filesystem.
/// </summary>
public class DefaultAppRegistrationTests
{
    private sealed class FakeRegistryWriter : IRegistryWriter
    {
        public readonly Dictionary<(string Key, string? Value), string> Strings = new();
        public readonly List<(string Key, string Value)> BinaryWrites = new();

        public void SetString(string keyPath, string? valueName, string value) => Strings[(keyPath, valueName)] = value;
        public void SetEmptyBinary(string keyPath, string valueName) => BinaryWrites.Add((keyPath, valueName));
    }

    private sealed class FakeProcessRunner : IProcessRunner
    {
        public readonly List<(string FileName, IReadOnlyList<string> Args)> Runs = new();
        public readonly List<string> OpenedUris = new();
        public bool RunResult = true;

        public bool Run(string fileName, IReadOnlyList<string> arguments)
        {
            Runs.Add((fileName, arguments));
            return RunResult;
        }

        public bool OpenUri(string uri)
        {
            OpenedUris.Add(uri);
            return true;
        }
    }

    private sealed class FakeFileProbe : IFileProbe
    {
        public bool Result;
        public bool Exists(string path) => Result;
    }

    [Fact]
    public void Windows_registrar_writes_progid_defaulticon_and_shell_command()
    {
        var registry = new FakeRegistryWriter();
        var process = new FakeProcessRunner();
        var registrar = new WindowsDefaultAppRegistrar(registry, process, @"C:\FastDoc\FastDoc.Avalonia.exe");

        var result = registrar.Register();

        Assert.Equal(DefaultAppOutcome.Registered, result.Outcome);
        Assert.Equal("FastDoc Document", registry.Strings[(@"Software\Classes\FastDoc.Document", null)]);
        Assert.Equal("\"C:\\FastDoc\\FastDoc.Avalonia.exe\",0",
            registry.Strings[(@"Software\Classes\FastDoc.Document\DefaultIcon", null)]);
        Assert.Equal("\"C:\\FastDoc\\FastDoc.Avalonia.exe\" \"%1\"",
            registry.Strings[(@"Software\Classes\FastDoc.Document\shell\open\command", null)]);
    }

    [Fact]
    public void Windows_registrar_registers_every_extension_as_open_with_candidate()
    {
        var registry = new FakeRegistryWriter();
        var registrar = new WindowsDefaultAppRegistrar(registry, new FakeProcessRunner(), @"C:\FastDoc.exe");

        registrar.Register();

        Assert.Equal(DefaultAppFamilies.WindowsOpenWithExtensions.Count, registry.BinaryWrites.Count);
        Assert.Contains((@"Software\Classes\.md\OpenWithProgids", "FastDoc.Document"), registry.BinaryWrites);
        Assert.Contains((@"Software\Classes\.hwp\OpenWithProgids", "FastDoc.Document"), registry.BinaryWrites);
    }

    [Fact]
    public void Windows_registrar_writes_registered_applications_capability_and_opens_settings()
    {
        var registry = new FakeRegistryWriter();
        var process = new FakeProcessRunner();
        var registrar = new WindowsDefaultAppRegistrar(registry, process, @"C:\FastDoc.exe");

        registrar.Register();

        Assert.Equal(@"Software\FastDoc\Capabilities", registry.Strings[(@"Software\RegisteredApplications", "FastDoc")]);
        Assert.Single(process.OpenedUris);
        Assert.Equal("ms-settings:defaultapps", process.OpenedUris[0]);
    }

    [Fact]
    public void Windows_registrar_reports_failure_when_registry_write_throws()
    {
        var registry = new ThrowingRegistryWriter();
        var registrar = new WindowsDefaultAppRegistrar(registry, new FakeProcessRunner(), @"C:\FastDoc.exe");

        var result = registrar.Register();

        Assert.Equal(DefaultAppOutcome.Failed, result.Outcome);
        Assert.Contains("boom", result.Message);
    }

    private sealed class ThrowingRegistryWriter : IRegistryWriter
    {
        public void SetString(string keyPath, string? valueName, string value) => throw new System.InvalidOperationException("boom");
        public void SetEmptyBinary(string keyPath, string valueName) => throw new System.InvalidOperationException("boom");
    }

    [Fact]
    public void Linux_registrar_fails_when_desktop_file_is_not_installed()
    {
        var probe = new FakeFileProbe { Result = false };
        var registrar = new LinuxDefaultAppRegistrar(new FakeProcessRunner(), probe, "/home/user/.local/share/applications/ai.ww-w.fastdoc.desktop");

        var result = registrar.Register();

        Assert.Equal(DefaultAppOutcome.Failed, result.Outcome);
        Assert.Contains("install.sh", result.Message);
    }

    [Fact]
    public void Linux_registrar_runs_xdg_mime_default_with_candidate_mime_types_when_installed()
    {
        var probe = new FakeFileProbe { Result = true };
        var process = new FakeProcessRunner();
        var registrar = new LinuxDefaultAppRegistrar(process, probe, "/home/user/.local/share/applications/ai.ww-w.fastdoc.desktop");

        var result = registrar.Register();

        Assert.Equal(DefaultAppOutcome.Registered, result.Outcome);
        Assert.Single(process.Runs);
        var (fileName, args) = process.Runs[0];
        Assert.Equal("xdg-mime", fileName);
        Assert.Equal("default", args[0]);
        Assert.Equal(LinuxDefaultAppRegistrar.DesktopFileName, args[1]);
        foreach (var mime in DefaultAppFamilies.LinuxCandidateMimeTypes)
        {
            Assert.Contains(mime, args);
        }
    }

    [Fact]
    public void Linux_registrar_reports_failure_when_xdg_mime_exits_nonzero()
    {
        var probe = new FakeFileProbe { Result = true };
        var process = new FakeProcessRunner { RunResult = false };
        var registrar = new LinuxDefaultAppRegistrar(process, probe, "/x/ai.ww-w.fastdoc.desktop");

        var result = registrar.Register();

        Assert.Equal(DefaultAppOutcome.Failed, result.Outcome);
    }

    [Fact]
    public void Unsupported_registrar_reports_unsupported()
    {
        var result = new UnsupportedDefaultAppRegistrar().Register();
        Assert.Equal(DefaultAppOutcome.Unsupported, result.Outcome);
    }
}
