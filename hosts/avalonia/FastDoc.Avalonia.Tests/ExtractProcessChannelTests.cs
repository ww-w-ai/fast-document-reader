using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S7-G: proves `--extract`'s channel split against the REAL engine dylib, as a real child
/// process (Program is internal, so this is driven the same way
/// <see cref="ProgramEntryConventionTests"/> drives it) — stdout carries ONLY the Markdown body,
/// stderr carries `mode: headless --extract` and the `opened: N nodes, M ms` smoke line the
/// repeat/regression gates (Scripts/host-gate.sh) now parse from there instead of stdout.
/// </summary>
public class ExtractProcessChannelTests
{
    private static readonly string HostAssemblyPath = typeof(RenderTreeLoader).Assembly.Location;

    [Fact]
    public void Docx_extract_prints_markdown_on_stdout_and_the_opened_smoke_line_on_stderr()
    {
        var repoRoot = FindRepoRoot();
        var engineLib = Path.Combine(repoRoot, "rust", "dist", "xplat", "macos-arm64", "libfastdoc_engine_ffi.dylib");
        var docPath = Path.Combine(repoRoot, "testdocs", "tables", "OpenAPI활용가이드_특일정보_v1.4.docx");
        if (!File.Exists(engineLib))
        {
            throw new InvalidOperationException(
                $"engine library not found at {engineLib} — build it with Scripts/build-engine-xplat.sh first.");
        }
        Assert.True(File.Exists(docPath), $"fixture missing: {docPath}");

        var (exitCode, stdout, stderr) = RunHost(
            new[] { "--extract", docPath },
            env: new() { ["FASTDOC_ENGINE_LIB"] = engineLib });

        Assert.Equal(0, exitCode);
        // stdout is the document, never the smoke diagnostic.
        Assert.DoesNotContain("opened:", stdout);
        Assert.Contains("Extracted from", stdout); // the header legend HeadlessExtract.swift's own convention mirrors
        Assert.Contains("#", stdout); // this fixture has at least one heading in real usage
        // stderr carries the mode line and the smoke diagnostic, never the document body.
        Assert.Contains("mode: headless --extract", stderr);
        Assert.Matches(@"opened: \d+ nodes, \d+ ms", stderr);
    }

    [Fact]
    public void Markdown_extract_prints_the_source_file_verbatim_on_stdout()
    {
        var repoRoot = FindRepoRoot();
        var engineLib = Path.Combine(repoRoot, "rust", "dist", "xplat", "macos-arm64", "libfastdoc_engine_ffi.dylib");
        var docPath = Path.Combine(repoRoot, "testdocs", "bulk", "moby-dick.md");
        if (!File.Exists(engineLib))
        {
            throw new InvalidOperationException(
                $"engine library not found at {engineLib} — build it with Scripts/build-engine-xplat.sh first.");
        }
        Assert.True(File.Exists(docPath), $"fixture missing: {docPath}");
        var sourceText = File.ReadAllText(docPath);

        var (exitCode, stdout, stderr) = RunHost(
            new[] { "--extract", docPath },
            env: new() { ["FASTDOC_ENGINE_LIB"] = engineLib });

        Assert.Equal(0, exitCode);
        // Verbatim passthrough carries no "Extracted from ..." legend (macOS doesn't add one for
        // .markdown/.plainText either) -- and Console.WriteLine adds exactly one trailing newline.
        Assert.Equal(sourceText + Environment.NewLine, stdout);
        Assert.Matches(@"opened: \d+ nodes, \d+ ms", stderr);
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
}
