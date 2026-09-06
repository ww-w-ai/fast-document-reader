using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace FastDoc.Avalonia.Open;

/// <summary>One entry in the recent-documents list — a path and when it was last opened.</summary>
public sealed class RecentFileEntry
{
    [JsonPropertyName("path")]
    public string Path { get; set; } = "";

    [JsonPropertyName("openedAt")]
    public string OpenedAt { get; set; } = "";
}

/// <summary>
/// The last 10 documents opened through this host, persisted as JSON at the OS-standard
/// per-user application-data location — NOT under <c>Environment.SpecialFolder.ApplicationData</c>,
/// because that constant's mapping on Unix varies by .NET version (it has followed XDG_CONFIG_HOME
/// on some runtimes and the home directory on others); the three paths below are the ones each OS's
/// own guidelines name, built explicitly so the location does not shift under us on a runtime bump.
/// </summary>
public static class RecentFiles
{
    private const int MaxEntries = 10;
    private const string AppFolderName = "FastDoc.Avalonia";
    private const string FileName = "recent.json";

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
                // Linux and other Unix-likes: XDG_DATA_HOME, falling back to ~/.local/share.
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

    public static IReadOnlyList<RecentFileEntry> Load()
    {
        try
        {
            var path = StorePath;
            if (!File.Exists(path)) { return Array.Empty<RecentFileEntry>(); }
            var json = File.ReadAllText(path);
            var entries = JsonSerializer.Deserialize<List<RecentFileEntry>>(json);
            return entries ?? new List<RecentFileEntry>();
        }
        catch
        {
            // A corrupt or unreadable store is not fatal to opening documents — treat it as empty.
            return Array.Empty<RecentFileEntry>();
        }
    }

    /// Records <paramref name="path"/> as just-opened: moves it to the front if already present,
    /// otherwise inserts it, then trims to <see cref="MaxEntries"/> and writes the store back out.
    public static void RecordOpened(string path)
    {
        var entries = Load().ToList();
        entries.RemoveAll(e => string.Equals(e.Path, path, PathComparisonPolicy.ForPaths()));
        entries.Insert(0, new RecentFileEntry
        {
            Path = path,
            OpenedAt = DateTimeOffset.UtcNow.ToString("o"),
        });
        if (entries.Count > MaxEntries)
        {
            entries.RemoveRange(MaxEntries, entries.Count - MaxEntries);
        }
        Save(entries);
    }

    private static void Save(List<RecentFileEntry> entries)
    {
        var storePath = StorePath;
        var dir = Path.GetDirectoryName(storePath);
        if (!string.IsNullOrEmpty(dir)) { Directory.CreateDirectory(dir); }
        var json = JsonSerializer.Serialize(entries, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(storePath, json);
    }
}
