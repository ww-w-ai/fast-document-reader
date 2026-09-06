using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S9-V (round 3): the reported VM (Ubuntu Xorg) flow-mode blank-region bug could not be
/// reproduced through this repo's own headless macOS replay across two separate investigation
/// rounds (see docs/studio/sprints/S9/s9c-flow-content.md), even though a direct, isolated call
/// into <see cref="TableGridRenderer.Draw"/> for the exact suspect tables draws real pixels fine.
/// Rather than guess a third time, <see cref="FlowDocumentView.RenderCore"/> now carries an
/// env-var-gated diagnostic (<c>FASTDOC_DRAW_LOG</c>) that lets the VM itself record, per real
/// paint frame, its own scroll offset / viewport-cull bounds / per-block cull verdict / per-cell
/// TextLayout state — so the lead can scroll to the actual blank spot on the actual VM and bring
/// the log back, instead of this reader guessing what a real Linux frame looks like.
///
/// These tests drive the existing headless `--paint-probe` entry point (`Program.RunPaintProbe`,
/// already used by this repo's own paint-latency probes) as a REAL child process, following
/// <see cref="ExtractProcessChannelTests"/>'s own pattern — <c>Program</c> is internal, so a child
/// process is the only way to observe the env var's effect: <c>DrawLogPath</c> is a
/// <c>static readonly</c> field read ONCE at type load specifically so an unset variable costs a
/// single null check per frame in production, which means flipping the env var mid-process inside
/// THIS test process would never be observed — a fresh child process is required either way.
/// </summary>
public class S9DrawLogDiagnosticTests
{
    private static readonly string HostAssemblyPath = typeof(RenderTreeLoader).Assembly.Location;

    [Fact]
    public void With_the_env_var_unset_no_draw_log_file_is_created()
    {
        var repoRoot = FindRepoRoot();
        var engineLib = Path.Combine(repoRoot, "rust", "dist", "xplat", "macos-arm64", "libfastdoc_engine_ffi.dylib");
        Assert.True(File.Exists(engineLib), $"engine library not found at {engineLib} — build it with Scripts/build-engine-xplat.sh first.");
        var docPath = Path.Combine(repoRoot, "testdocs", "mini", "s9-picture-crop.hwp");
        Assert.True(File.Exists(docPath), $"fixture missing: {docPath}");

        var logPath = Path.Combine(Path.GetTempPath(), $"fastdoc-drawlog-unset-{Guid.NewGuid():N}.log");
        try
        {
            // No FASTDOC_DRAW_LOG entry at all — the child process's environment genuinely lacks
            // the variable (not merely set to empty), matching how every real user's machine runs.
            var (exitCode, _, stderr) = RunHost(
                new[] { "--paint-probe", docPath },
                env: new() { ["FASTDOC_ENGINE_LIB"] = engineLib, ["FMD_AVALONIA_REPEAT"] = "1" });

            Assert.Equal(0, exitCode);
            Assert.Contains("mode: headless --paint-probe", stderr);
            Assert.False(File.Exists(logPath), "no FASTDOC_DRAW_LOG file should exist when the env var was never set");
        }
        finally
        {
            if (File.Exists(logPath)) { File.Delete(logPath); }
        }
    }

    [Fact]
    public void With_the_env_var_set_the_log_records_a_frame_header_and_block_lines()
    {
        var repoRoot = FindRepoRoot();
        var engineLib = Path.Combine(repoRoot, "rust", "dist", "xplat", "macos-arm64", "libfastdoc_engine_ffi.dylib");
        Assert.True(File.Exists(engineLib), $"engine library not found at {engineLib} — build it with Scripts/build-engine-xplat.sh first.");
        var docPath = Path.Combine(repoRoot, "testdocs", "mini", "s9-picture-crop.hwp");
        Assert.True(File.Exists(docPath), $"fixture missing: {docPath}");

        var logPath = Path.Combine(Path.GetTempPath(), $"fastdoc-drawlog-set-{Guid.NewGuid():N}.log");
        try
        {
            var (exitCode, _, stderr) = RunHost(
                new[] { "--paint-probe", docPath },
                env: new()
                {
                    ["FASTDOC_ENGINE_LIB"] = engineLib,
                    ["FASTDOC_DRAW_LOG"] = logPath,
                    ["FMD_AVALONIA_REPEAT"] = "1",
                });

            Assert.Equal(0, exitCode);
            Assert.Contains("mode: headless --paint-probe", stderr);
            Assert.True(File.Exists(logPath), $"FASTDOC_DRAW_LOG={logPath} was set but no log file was written");

            var contents = File.ReadAllText(logPath);
            Assert.False(string.IsNullOrWhiteSpace(contents), "the log file exists but is empty");
            Assert.Contains("FRAME 1 scrollOffset=", contents);
            Assert.Contains("localViewTop=", contents);
            Assert.Contains("localViewBottom=", contents);
            Assert.Contains("viewportHeight=", contents);
            Assert.Contains("docTotalHeight=", contents);
            Assert.Contains("BLOCK i=", contents);
            Assert.Contains("verdict=", contents);
            // This document has table cells with real content, so at least one cell-level line
            // (built only when a top-level Table block is actually drawn, not culled) must appear.
            Assert.Contains("cell row=", contents);
        }
        finally
        {
            if (File.Exists(logPath)) { File.Delete(logPath); }
        }
    }

    /// <summary>S9-V (root cause): the actual VM-reported bug — a table sitting INSIDE a scrolled
    /// viewport still drew every row as culled, because <c>FlowDocumentView.DrawBlock</c>'s Table
    /// case computed its block-local view bounds against the block's SURFACE-space `top`
    /// (scroll-subtracted) instead of its DOCUMENT-space <c>_offsets[i]</c> — invisible at
    /// scrollOffset=0 (the two spaces coincide there), silently culling every row once scrolled
    /// (see the fixed `blockLocalViewTop`/`blockLocalViewBottom` parameter doc on `DrawBlock` and
    /// `TableGridRenderer.Draw`'s coordinate-space invariant doc for the fix itself).
    ///
    /// Why the EARLIER pixel-level regression test in S9CFlowContentTests.cs did not catch this:
    /// that test calls <c>TableGridRenderer.Draw</c> DIRECTLY with
    /// <c>viewportTop: double.NegativeInfinity, viewportBottom: double.PositiveInfinity</c> — an
    /// isolated call that never exercises ANY row culling at all, let alone the specific
    /// scroll-dependent coordinate bug in the CALLER (<c>FlowDocumentView.DrawBlock</c>) that
    /// composes those bounds. A structural sweep of block heights (the S9-V round-1 investigation)
    /// also could not see it: `_blockHeights`/`_offsets` are unaffected — the table's RESERVED
    /// height is correct even when every row inside it gets culled from drawing, so nothing in the
    /// document's geometry looks wrong from the outside. Only a log of the ACTUAL per-row cull
    /// verdict, taken from a REAL scrolled `RenderCore` frame, exposes it — which is exactly what
    /// `FASTDOC_DRAW_LOG` is for, and exactly how the VM's own copy of this log caught it.</summary>
    [Fact]
    public void A_table_inside_a_scrolled_viewport_still_draws_its_rows_not_zero()
    {
        var repoRoot = FindRepoRoot();
        var engineLib = Path.Combine(repoRoot, "rust", "dist", "xplat", "macos-arm64", "libfastdoc_engine_ffi.dylib");
        Assert.True(File.Exists(engineLib), $"engine library not found at {engineLib} — build it with Scripts/build-engine-xplat.sh first.");
        var docPath = Path.Combine(repoRoot, "testdocs", "mini", "s9-picture-crop.hwp");
        Assert.True(File.Exists(docPath), $"fixture missing: {docPath}");

        var logPath = Path.Combine(Path.GetTempPath(), $"fastdoc-drawlog-scroll-{Guid.NewGuid():N}.log");
        try
        {
            // --paint-probe drives FIVE real scroll stops (0/25/50/75/100% of document height)
            // through the SAME FlowDocumentView.RenderCore the GUI uses — this is what puts a real,
            // non-zero _scrollOffset through the exact code path the bug lived in.
            var (exitCode, _, stderr) = RunHost(
                new[] { "--paint-probe", docPath },
                env: new()
                {
                    ["FASTDOC_ENGINE_LIB"] = engineLib,
                    ["FASTDOC_DRAW_LOG"] = logPath,
                    ["FMD_AVALONIA_REPEAT"] = "1",
                });
            Assert.Equal(0, exitCode);
            Assert.Contains("mode: headless --paint-probe", stderr);
            Assert.True(File.Exists(logPath), $"FASTDOC_DRAW_LOG={logPath} was set but no log file was written");

            var lines = File.ReadAllLines(logPath);
            var frameHeaderRe = new Regex(@"^FRAME \d+ scrollOffset=(?<scroll>[\d.]+)");
            var tableBlockRe = new Regex(@"^BLOCK i=\d+ nodeId=\d+ kind=Table .* verdict=drawn rowsDrawn=(?<rows>\d+) cellsSeen=(?<cells>\d+)");

            double currentScroll = 0;
            var scrolledTableBlocksSeen = 0;
            var zeroRowTableBlocks = new List<string>();
            foreach (var line in lines)
            {
                var headerMatch = frameHeaderRe.Match(line);
                if (headerMatch.Success)
                {
                    currentScroll = double.Parse(headerMatch.Groups["scroll"].Value);
                    continue;
                }
                if (currentScroll <= 0) { continue; } // only frames with a REAL scroll offset matter for this bug
                var blockMatch = tableBlockRe.Match(line);
                if (!blockMatch.Success) { continue; }
                scrolledTableBlocksSeen++;
                var rowsDrawn = int.Parse(blockMatch.Groups["rows"].Value);
                if (rowsDrawn == 0) { zeroRowTableBlocks.Add(line); }
            }

            Assert.True(scrolledTableBlocksSeen > 0,
                "no drawn Table block appeared in any scrolled-viewport frame — the probe's scroll " +
                "stops may need adjusting for this fixture, or the log format drifted");
            Assert.True(zeroRowTableBlocks.Count == 0,
                "a table block reported inside a scrolled viewport (verdict=drawn) drew ZERO rows " +
                "— this is the exact VM-reported bug (viewport-cull coordinate mismatch):\n" +
                string.Join("\n", zeroRowTableBlocks));
        }
        finally
        {
            if (File.Exists(logPath)) { File.Delete(logPath); }
        }
    }

    private static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "CLAUDE.md"))) { dir = dir.Parent; }
        return dir?.FullName ?? throw new InvalidOperationException("no repo root");
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
        var exited = process.WaitForExit(TimeSpan.FromSeconds(60));
        if (!exited)
        {
            process.Kill(entireProcessTree: true);
            throw new TimeoutException($"dotnet exec {HostAssemblyPath} {string.Join(' ', args)} did not exit within 60s");
        }
        return (process.ExitCode, stdout, stderr);
    }
}
