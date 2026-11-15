using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace FastDoc.Avalonia.WebRender;

/// <summary>The persisted state of one JSON field: whether the user opted in to real-browser
/// mermaid/KaTeX rendering. Kept separate from <see cref="RecentFileEntry"/>'s own file (not
/// folded into <c>recent.json</c>) because the two have unrelated lifetimes and a corrupt recents
/// file must not also reset this switch, or the reverse.</summary>
public sealed class WebRenderSettingsData
{
    /// <summary>Default OFF, per the S12-F/bible.md decision this mirrors: a fresh install must
    /// never fetch a browser runtime or show a rendered diagram before the user has explicitly
    /// asked for it — see docs/studio/sprints/S12/s12f-scope-v2.md "기본 상태 재정의".</summary>
    [JsonPropertyName("renderingEnabled")]
    public bool RenderingEnabled { get; set; }
}

/// <summary>Loads/saves <see cref="WebRenderSettingsData"/> at the same OS-standard per-user
/// application-data location <see cref="Open.RecentFiles"/> uses (same three explicit paths, same
/// reasoning about <c>Environment.SpecialFolder.ApplicationData</c>'s unstable Unix mapping — see
/// that file's own doc comment), in a sibling file so the two settings never share a write.</summary>
public static class WebRenderSettings
{
    private const string AppFolderName = "FastDoc.Avalonia";
    private const string FileName = "web-render-settings.json";

    public static string StorePath
    {
        get
        {
            string baseDir;
            if (OperatingSystem.IsMacOS())
            {
                baseDir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    "Library", "Application Support", AppFolderName);
            }
            else if (OperatingSystem.IsWindows())
            {
                var appData = Environment.GetEnvironmentVariable("APPDATA")
                    ?? Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
                baseDir = Path.Combine(appData, AppFolderName);
            }
            else
            {
                var xdgDataHome = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
                baseDir = string.IsNullOrEmpty(xdgDataHome)
                    ? Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                        ".local", "share", AppFolderName)
                    : Path.Combine(xdgDataHome, AppFolderName);
            }
            return Path.Combine(baseDir, FileName);
        }
    }

    /// <summary>A corrupt or unreadable store is not fatal — it degrades to the safe default
    /// (rendering OFF), same policy <see cref="Open.RecentFiles.Load"/> applies to its own file.</summary>
    public static WebRenderSettingsData Load()
    {
        try
        {
            var path = StorePath;
            if (!File.Exists(path)) { return new WebRenderSettingsData(); }
            var json = File.ReadAllText(path);
            return JsonSerializer.Deserialize<WebRenderSettingsData>(json) ?? new WebRenderSettingsData();
        }
        catch
        {
            return new WebRenderSettingsData();
        }
    }

    public static void Save(WebRenderSettingsData data)
    {
        var storePath = StorePath;
        var dir = Path.GetDirectoryName(storePath);
        if (!string.IsNullOrEmpty(dir)) { Directory.CreateDirectory(dir); }
        var json = JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(storePath, json);
    }
}
