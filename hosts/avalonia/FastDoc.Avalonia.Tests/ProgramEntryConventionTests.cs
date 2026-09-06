using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// Program.Main's entry convention (hosts/avalonia/FastDoc.Avalonia/Program.cs): "--noop" and an
/// unrecognized "--flag" both exit before any GUI or engine call, so they are the two branches
/// this suite can exercise without FASTDOC_ENGINE_LIB. The GUI branch (no args, or a bare
/// document path) and "--extract"/"--paint-probe" all load the engine dylib or start Avalonia's
/// headless platform — that coverage is Scripts/host-gate.sh's job (its headless --extract smoke
/// runs ARE this same entry point, just with the library present), not this unit suite's.
///
/// Program is an internal class (no InternalsVisibleTo added for it — see the return notes for
/// why), so Main is driven the same way an OS file-association launch would: as a real child
/// process, `dotnet exec <built FastDoc.Avalonia.dll> &lt;args&gt;`. The dll path is discovered
/// via reflection off a type this project DOES reference (RenderTreeLoader lives in the same
/// assembly as Program), so this test needs no hardcoded bin/Debug|Release path.
/// </summary>
public class ProgramEntryConventionTests
{
    private static readonly string HostAssemblyPath = typeof(RenderTreeLoader).Assembly.Location;

    [Fact]
    public void Noop_exits_zero_before_loading_the_engine_or_starting_a_gui()
    {
        var (exitCode, stdout, stderr) = RunHost("--noop");

        Assert.Equal(0, exitCode);
        Assert.Contains("noop", stdout);
        Assert.Contains("headless --noop", stderr);
    }

    [Fact]
    public void An_unknown_flag_exits_1_with_an_error_naming_the_flag()
    {
        var (exitCode, stdout, stderr) = RunHost("--this-flag-does-not-exist");

        Assert.Equal(1, exitCode);
        Assert.Contains("unknown flag --this-flag-does-not-exist", stderr);
        Assert.DoesNotContain("mode: gui", stderr); // must not have fallen through to the GUI path
    }

    /// <summary>scenario 3a (docs/studio/sprints/S6/s6e-error-surface.md): a headless door
    /// whose FASTDOC_ENGINE_LIB points nowhere used to crash with an unhandled
    /// InvalidOperationException and a full .NET stack trace before ANY output appeared. It must
    /// now report a one-line, stack-free diagnosis and exit 2 (environment error — reserved for
    /// this case; document/usage failures keep exit 1, matching every pre-existing test in this
    /// file and Scripts/host-gate.sh, which asserts nothing about failure exit codes).</summary>
    [Fact]
    public void Missing_engine_library_exits_2_with_one_stderr_line_and_no_stack_trace()
    {
        var (exitCode, _, stderr) = RunHost(
            new[] { "--extract", "/tmp/does-not-matter.docx" },
            env: new() { ["FASTDOC_ENGINE_LIB"] = "/nonexistent/path/libfastdoc_engine_ffi.dylib" });

        Assert.Equal(2, exitCode);
        Assert.Contains("engine library not found", stderr);
        // A real .NET stack trace line looks like "\n   at Namespace.Type.Method(...)" — checked
        // this way (not "Contains(\" at \")") because the exception's own message legitimately
        // contains the words "points at a file", which is not a stack trace.
        Assert.DoesNotContain("\n   at ", stderr);
    }

    /// <summary>scenario 4: a nonexistent document path used to print the FULL .NET exception
    /// (type name, internal call chain, this machine's absolute paths) on every run. It must now
    /// print one human line by default, with the full detail available ONLY behind
    /// FMD_AVALONIA_DEBUG=1 for a developer who explicitly asked for it.</summary>
    [Fact]
    public void Nonexistent_path_exits_1_with_one_line_and_the_stack_only_under_debug_flag()
    {
        var missingPath = Path.Combine(Path.GetTempPath(), $"fastdoc-missing-{Path.GetRandomFileName()}.docx");
        var engineLib = ResolveMacOsEngineLibPath();

        var (plainExit, plainStdout, _) = RunHost(
            new[] { "--extract", missingPath },
            env: new() { ["FASTDOC_ENGINE_LIB"] = engineLib });
        Assert.Equal(1, plainExit);
        Assert.Contains("file not found", plainStdout);
        Assert.DoesNotContain("\n   at ", plainStdout);

        var (debugExit, debugStdout, _) = RunHost(
            new[] { "--extract", missingPath },
            env: new()
            {
                ["FASTDOC_ENGINE_LIB"] = engineLib,
                ["FMD_AVALONIA_DEBUG"] = "1",
            });
        Assert.Equal(1, debugExit);
        Assert.Contains("file not found", debugStdout);
        Assert.Contains("\n   at ", debugStdout); // the stack trace IS present under the debug flag
    }

    /// <summary>Locates the real engine dylib the same way Scripts/host-gate.sh does, so the
    /// "path exists but the FILE doesn't" test above exercises the actual RenderTreeLoader.Load
    /// path (File.ReadAllBytes throwing) rather than being masked by an engine-missing failure.</summary>
    private static string ResolveMacOsEngineLibPath()
    {
        var repoRoot = FindRepoRoot();
        var path = Path.Combine(repoRoot, "rust", "dist", "xplat", "macos-arm64", "libfastdoc_engine_ffi.dylib");
        if (!File.Exists(path))
        {
            throw new InvalidOperationException(
                $"engine library not found at {path} — build it with Scripts/build-engine-xplat.sh " +
                "before running this test (same fixture host-gate.sh step 3 requires).");
        }
        return path;
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

    private static (int ExitCode, string Stdout, string Stderr) RunHost(
        string[] args, Dictionary<string, string>? env = null)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "dotnet",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        startInfo.ArgumentList.Add("exec");
        startInfo.ArgumentList.Add(HostAssemblyPath);
        foreach (var arg in args)
        {
            startInfo.ArgumentList.Add(arg);
        }
        if (env is not null)
        {
            foreach (var (key, value) in env)
            {
                startInfo.Environment[key] = value;
            }
        }

        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException($"failed to start dotnet exec {HostAssemblyPath}");
        var stdout = process.StandardOutput.ReadToEnd();
        var stderr = process.StandardError.ReadToEnd();
        var exited = process.WaitForExit(TimeSpan.FromSeconds(30));
        if (!exited)
        {
            process.Kill(entireProcessTree: true);
            throw new TimeoutException($"dotnet exec {HostAssemblyPath} {string.Join(' ', args)} did not exit within 30s");
        }
        return (process.ExitCode, stdout, stderr);
    }

    private static (int ExitCode, string Stdout, string Stderr) RunHost(params string[] args) => RunHost(args, env: null);
}
