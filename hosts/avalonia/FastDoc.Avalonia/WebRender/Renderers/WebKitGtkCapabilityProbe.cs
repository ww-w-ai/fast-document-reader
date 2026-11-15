using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace FastDoc.Avalonia.WebRender.Renderers;

/// <summary>
/// S12-F Linux path: is a WebKitGTK shared library actually LOADABLE on this system — not merely
/// present as a file. A file-existence check (this class's own earlier shape) is a false-negative-
/// safe but false-positive-UNSAFE approximation: a library file can exist and still fail to load —
/// a missing transitive dependency, an ABI mismatch, a broken symlink — and only a real load
/// attempt (`dlopen`) tells the two apart. PM judgment (2026-09-07,
/// docs/studio/sprints/S12/s12f-web-render-optin.md §9-4/§9-5): a false positive here is what lets
/// <c>WebKitGtkBlockRenderer</c> attempt to construct a <c>NativeWebView</c> that then crashes the
/// process on an out-of-band exception (see <c>DispatcherFaultGuard</c>) — reducing false positives
/// at THIS gate is the "ideally excluded from candidates before ever trying" half of that fix; the
/// guard is the other half, for whatever a real dlopen probe itself cannot anticipate.
///
/// [verify] the exact set of paths and filenames below on the actual target distributions this
/// app ships to — this list is a reasonable starting set (the two most common WebKitGTK API
/// versions, on the two most common multiarch library directories), not a verified inventory.
/// A false negative here is SAFE (falls through to the on-demand Chromium candidate per PM's
/// S12-F judgment 2).
/// </summary>
public sealed class WebKitGtkCapabilityProbe : IWebRenderCapability
{
    private static readonly string[] LibraryDirectories =
    {
        "/usr/lib/x86_64-linux-gnu",
        "/usr/lib/aarch64-linux-gnu",
        "/usr/lib64",
        "/usr/lib",
    };

    private static readonly string[] LibraryNamePatterns =
    {
        "libwebkit2gtk-4.1.so",
        "libwebkit2gtk-4.0.so",
        "libwebkitgtk-6.0.so",
    };

    private readonly Func<string, bool> _canLoad;

    public WebKitGtkCapabilityProbe() : this(TryDlopen)
    {
    }

    /// <summary>Test seam: injecting the load check lets this probe's SELECTION logic (see
    /// <see cref="AnyLoadable"/>) be pinned on any OS, without a real Linux machine and a real
    /// WebKitGTK install to dlopen — <c>internal</c> rather than <c>public</c> because it exists for
    /// this repo's own tests, not as an API surface for callers.</summary>
    internal WebKitGtkCapabilityProbe(Func<string, bool> canLoad) => _canLoad = canLoad;

    public bool IsAvailable()
    {
        if (!OperatingSystem.IsLinux())
        {
            return false;
        }

        var candidatePaths = LibraryDirectories
            .Where(Directory.Exists)
            .SelectMany(dir => Directory.EnumerateFiles(dir))
            .Where(path =>
            {
                var name = Path.GetFileName(path);
                return name is not null && LibraryNamePatterns.Any(pattern => name.StartsWith(pattern, StringComparison.Ordinal));
            });

        return AnyLoadable(candidatePaths, _canLoad);
    }

    /// <summary>The pure decision this probe makes once it has a list of candidate paths: available
    /// the moment ONE of them actually loads. Kept separate from <see cref="IsAvailable"/> (which
    /// also decides WHICH paths to look at, and gates the whole thing behind
    /// <see cref="OperatingSystem.IsLinux"/>) so this file's own unit tests can exercise the
    /// selection logic directly, on any OS, against an explicit path list.</summary>
    internal static bool AnyLoadable(IEnumerable<string> candidatePaths, Func<string, bool> canLoad) =>
        candidatePaths.Any(canLoad);

    [SupportedOSPlatform("linux")]
    private static bool TryDlopen(string path)
    {
        // RTLD_NOW (2): resolve every symbol immediately, so an ABI mismatch or a missing
        // transitive dependency fails HERE rather than surfacing later as a crash mid-render — the
        // whole point of replacing a file-existence check with this one.
        var handle = dlopen(path, RTLD_NOW);
        if (handle == IntPtr.Zero)
        {
            return false;
        }
        dlclose(handle);
        return true;
    }

    private const int RTLD_NOW = 2;

    [DllImport("libdl.so.2")]
    private static extern IntPtr dlopen(string filename, int flags);

    [DllImport("libdl.so.2")]
    private static extern int dlclose(IntPtr handle);
}
