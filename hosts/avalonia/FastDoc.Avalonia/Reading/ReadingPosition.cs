using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using FastDoc.Avalonia.Open;

namespace FastDoc.Avalonia.Reading;

/// <summary>One saved reading position — where the reader was inside one document, and at what
/// zoom, the last time it closed or scrolled to a stop. Keyed by path+size+mtime (see
/// <see cref="ReadingPositions.MakeKey"/>) so a document that was replaced by a same-named but
/// different file does not silently resume at a stranger's scroll offset.</summary>
public sealed class ReadingPositionEntry
{
    [JsonPropertyName("key")]
    public string Key { get; set; } = "";

    /// <summary>Index into FlowDocumentView's block list — cheaper and more robust across reflows
    /// than a raw pixel offset, since a block index survives a width/zoom change (the pixel
    /// offset of that same block does not).</summary>
    [JsonPropertyName("blockIndex")]
    public int BlockIndex { get; set; }

    /// <summary>How far into that block's own height the scroll top sat, 0..1 — restores the
    /// exact line even when the block spans several screens (a long paragraph, a tall table).</summary>
    [JsonPropertyName("fraction")]
    public double Fraction { get; set; }

    [JsonPropertyName("zoom")]
    public double Zoom { get; set; } = 1.0;

    [JsonPropertyName("savedAt")]
    public string SavedAt { get; set; } = "";
}

/// <summary>
/// Per-document reading position (scroll + zoom), persisted as JSON next to
/// <see cref="RecentFiles"/>'s own store (same app-data folder, sibling file) — E3's read half of
/// "close a document, reopen it later, land back where you left off". Trimmed to the same
/// <see cref="MaxEntries"/> discipline RecentFiles uses, oldest dropped first.
/// </summary>
public static class ReadingPositions
{
    private const int MaxEntries = 100;
    private const string FileName = "positions.json";

    /// <summary>Sibling of RecentFiles.StorePath — same app-data directory this host already
    /// resolved per-OS, so a second store does not need to re-derive that platform logic.</summary>
    public static string StorePath
    {
        get
        {
            var recentDir = Path.GetDirectoryName(RecentFiles.StorePath)!;
            return Path.Combine(recentDir, FileName);
        }
    }

    /// <summary>path+size+mtime — a key that changes when the FILE changes, so a document
    /// overwritten by a different one at the same path does not resume at the old file's
    /// position. Falls back to the bare path if the file cannot be stat'd (e.g. already gone).</summary>
    public static string MakeKey(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (info.Exists)
            {
                return $"{path}|{info.Length}|{info.LastWriteTimeUtc:o}";
            }
        }
        catch
        {
            // Fall through to the bare-path key below.
        }
        return path;
    }

    public static ReadingPositionEntry? Find(string key)
        => LoadAll().FirstOrDefault(e => string.Equals(e.Key, key, PathComparisonPolicy.ForPaths()));

    /// Records the reading position for <paramref name="key"/>: moves it to the front if already
    /// present, otherwise inserts it, then trims to <see cref="MaxEntries"/> and writes back out.
    public static void Save(string key, int blockIndex, double fraction, double zoom)
    {
        if (string.IsNullOrEmpty(key)) { return; }
        var entries = LoadAll().ToList();
        entries.RemoveAll(e => string.Equals(e.Key, key, PathComparisonPolicy.ForPaths()));
        entries.Insert(0, new ReadingPositionEntry
        {
            Key = key,
            BlockIndex = Math.Max(0, blockIndex),
            Fraction = Math.Clamp(fraction, 0.0, 1.0),
            Zoom = zoom,
            SavedAt = DateTimeOffset.UtcNow.ToString("o"),
        });
        if (entries.Count > MaxEntries)
        {
            entries.RemoveRange(MaxEntries, entries.Count - MaxEntries);
        }
        WriteAll(entries);
    }

    private static List<ReadingPositionEntry> LoadAll()
    {
        try
        {
            var path = StorePath;
            if (!File.Exists(path)) { return new List<ReadingPositionEntry>(); }
            var json = File.ReadAllText(path);
            var entries = JsonSerializer.Deserialize<List<ReadingPositionEntry>>(json);
            return entries ?? new List<ReadingPositionEntry>();
        }
        catch
        {
            // A corrupt or unreadable store is not fatal to opening documents — treat it as empty,
            // same policy as RecentFiles.Load.
            return new List<ReadingPositionEntry>();
        }
    }

    private static void WriteAll(List<ReadingPositionEntry> entries)
    {
        var storePath = StorePath;
        var dir = Path.GetDirectoryName(storePath);
        if (!string.IsNullOrEmpty(dir)) { Directory.CreateDirectory(dir); }
        var json = JsonSerializer.Serialize(entries, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(storePath, json);
    }
}
