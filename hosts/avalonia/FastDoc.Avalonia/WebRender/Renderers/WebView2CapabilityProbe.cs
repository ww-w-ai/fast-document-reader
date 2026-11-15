using System;
using System.Runtime.Versioning;

namespace FastDoc.Avalonia.WebRender.Renderers;

/// <summary>
/// S12-F Windows path: detects an already-installed Edge WebView2 Runtime by the same registry
/// check Microsoft's own distribution guide documents — the `pv` (product version) value under
/// the WebView2 Runtime's EdgeUpdate client GUID, at BOTH the per-machine and per-user locations
/// (either one present and non-"0.0.0.0" counts as installed).
/// [출처: learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution — see
/// docs/studio/sprints/S12/s12f-scope-v2.md's Windows section for the same citation.]
///
/// UNVERIFIED ON THIS DEVELOPMENT MACHINE (macOS): the registry read only runs under
/// <c>OperatingSystem.IsWindows()</c>, so on every other OS this always reports unavailable —
/// which is also the CORRECT answer there, just not proof the Windows branch itself has been
/// exercised against a real Windows registry.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class WebView2CapabilityProbe : IWebRenderCapability
{
    private const string ClientKeyPath =
        @"SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
    private const string ClientKeyPathUserScope =
        @"SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";

    public bool IsAvailable()
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }
        return IsVersionPresent(Microsoft.Win32.Registry.LocalMachine, ClientKeyPath)
            || IsVersionPresent(Microsoft.Win32.Registry.CurrentUser, ClientKeyPathUserScope);
    }

    [SupportedOSPlatform("windows")]
    private static bool IsVersionPresent(Microsoft.Win32.RegistryKey root, string subKeyPath)
    {
        using var key = root.OpenSubKey(subKeyPath);
        var value = key?.GetValue("pv") as string;
        return !string.IsNullOrEmpty(value) && value != "0.0.0.0";
    }
}
