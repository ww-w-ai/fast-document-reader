using System.Reflection;

namespace FastDoc.Avalonia.Panels;

/// <summary>
/// S9-B3 batch 8 (docs/studio/sprints/S9/s9b1-full-parity.md #1, mirroring
/// AppDelegate.swift:99,337-350's About FastDoc window on macOS): the pure fields
/// <see cref="AboutWindow"/> shows, read from the built assembly's own metadata rather than the
/// csproj text (same discipline VersionFieldsTests already applies) — pulled into a static class so
/// a headless test can assert the values without constructing a Window.
/// </summary>
public static class AboutModel
{
    public const string AppName = "FastDoc";

    /// <summary>Engine version is deliberately NOT shown: this host's Rendering/Native FFI surface
    /// (FastdocEngine.cs) exposes no `fastdoc_engine_version`-shaped export today (grepped,
    /// 2026-09-06) — showing a made-up or build-timestamp stand-in would be worse than omitting it.
    /// A future engine export can fill this in without changing AboutWindow's layout.</summary>
    public const string EngineVersionNote = "Engine version: not exposed by this build";

    public const string LicenceLine = "MIT License — Copyright (c) 2026 DubDubDub Corp.";

    /// <summary>"1.0.0+abcdef1" — the assembly's own InformationalVersion (Version + git SHA,
    /// dotnet's own SourceRevisionId suffix), or just "1.0.0" when the attribute is missing
    /// (a non-git build) or blank.</summary>
    public static string ProductVersion(Assembly assembly)
    {
        var informational = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (!string.IsNullOrWhiteSpace(informational)) { return informational; }
        return assembly.GetName().Version?.ToString(3) ?? "0.0.0";
    }
}
