using System.Collections.Generic;
using FastDoc.Avalonia.WebRender.Renderers;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// This development/CI machine is macOS, so these probes cannot be exercised against a real
/// Windows registry or a real Linux WebKitGTK install — that is a QA task on the real target OS
/// (see docs/studio/sprints/S12/s12f-web-render-optin.md's "미검증" section). What IS pinned here,
/// safely and deterministically on any OS: each probe's OS guard returns false rather than
/// throwing when run on an OS it does not target, which is also the CORRECT production answer on
/// this exact machine.
/// </summary>
public class WebRenderCapabilityProbeTests
{
    [Fact]
#pragma warning disable CA1416 // the OS guard is inside IsAvailable() itself, at runtime — this
                               // test's whole point is to prove that guard, so it must call the
                               // Windows-only-annotated method unconditionally.
    public void WebView2_probe_reports_unavailable_on_a_non_Windows_OS_without_throwing()
    {
        var probe = new WebView2CapabilityProbe();

        var available = probe.IsAvailable();

        if (!System.OperatingSystem.IsWindows())
        {
            Assert.False(available);
        }
    }
#pragma warning restore CA1416

    [Fact]
    public void WebKitGtk_probe_reports_unavailable_on_a_non_Linux_OS_without_throwing()
    {
        var probe = new WebKitGtkCapabilityProbe();

        var available = probe.IsAvailable();

        if (!System.OperatingSystem.IsLinux())
        {
            Assert.False(available);
        }
    }

    /// <summary>
    /// S12-F PM judgment (2026-09-07): a file-presence check is not enough — a WebKitGTK library
    /// file can exist on disk and still fail to actually load (missing a transitive dependency, an
    /// ABI mismatch, a broken symlink), and only a real load attempt tells the two apart. This pins
    /// the SELECTION logic (any one loadable candidate makes the probe available; none loadable
    /// means unavailable) independent of the real Linux-only dlopen call, so it runs on any OS —
    /// see <see cref="WebKitGtkCapabilityProbe.AnyLoadable"/>'s own doc comment for why the real
    /// `OperatingSystem.IsLinux()` gate in <c>IsAvailable()</c> itself cannot be exercised on this
    /// (macOS) development machine.
    /// </summary>
    [Fact]
    public void AnyLoadable_is_true_when_at_least_one_candidate_path_actually_loads()
    {
        var attempted = new List<string>();
        bool CanLoad(string path)
        {
            attempted.Add(path);
            return path == "/usr/lib/x86_64-linux-gnu/libwebkit2gtk-4.1.so.0";
        }

        var result = WebKitGtkCapabilityProbe.AnyLoadable(
            new[] { "/usr/lib/x86_64-linux-gnu/libwebkit2gtk-4.0.so.37", "/usr/lib/x86_64-linux-gnu/libwebkit2gtk-4.1.so.0" },
            CanLoad);

        Assert.True(result);
    }

    [Fact]
    public void AnyLoadable_is_false_when_a_matching_file_exists_but_fails_to_actually_load()
    {
        // The exact bug this replaces a bare file-existence check for: the path exists (this fake
        // never says otherwise — it is handed the path directly, as if Directory.EnumerateFiles
        // had already found it), but the load attempt itself fails.
        var result = WebKitGtkCapabilityProbe.AnyLoadable(
            new[] { "/usr/lib/x86_64-linux-gnu/libwebkit2gtk-4.1.so.0" },
            _ => false);

        Assert.False(result);
    }

    [Fact]
    public void AnyLoadable_is_false_for_an_empty_candidate_list()
    {
        var result = WebKitGtkCapabilityProbe.AnyLoadable(System.Array.Empty<string>(), _ => true);

        Assert.False(result);
    }
}
