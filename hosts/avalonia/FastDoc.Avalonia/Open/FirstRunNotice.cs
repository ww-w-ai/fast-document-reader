using System;
using System.IO;

namespace FastDoc.Avalonia.Open;

/// <summary>
/// Whether the first-run notice still wants to appear — mirrors the macOS app's <c>WelcomeStore</c>
/// (Sources/FastDocReader/App/WelcomeWindow.swift): a flag FILE rather than a settings key (this
/// host has no settings store of its own yet), under the OS's standard per-user local-data folder.
/// Absent means SHOW; only an explicit "don't show again" tick calls <see cref="MarkShown"/>. A
/// closed window that never ticked the box does NOT count as shown — same rule the macOS guide
/// states for itself, so the notice comes back next launch until the reader has actually seen it.
/// </summary>
public static class FirstRunNotice
{
    private const string AppFolderName = "FastDoc";
    private const string FlagFileName = "first-run-done";

    public static string FlagFilePath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppFolderName, FlagFileName);

    public static bool ShouldShow(IFileProbe fileProbe) => !fileProbe.Exists(FlagFilePath);

    public static void MarkShown()
    {
        var path = FlagFilePath;
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) { Directory.CreateDirectory(dir); }
        File.WriteAllText(path, DateTimeOffset.UtcNow.ToString("o"));
    }
}
