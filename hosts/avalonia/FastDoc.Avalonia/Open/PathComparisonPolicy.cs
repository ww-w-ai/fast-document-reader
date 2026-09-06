using System;

namespace FastDoc.Avalonia.Open;

/// <summary>The one place that decides whether two file-system path strings should compare equal
/// ignoring case. macOS (APFS, default) and Windows (NTFS) both resolve a path
/// case-insensitively at the OS level, so a document opened once as "Report.docx" and again as
/// "report.docx" is the SAME file there — comparing those two strings with plain
/// <see cref="StringComparison.Ordinal"/> treats them as two different entries, showing the same
/// document twice in <see cref="RecentFiles"/> or <see cref="Reading.ReadingPositions"/>. Linux's
/// common file systems (ext4, btrfs, xfs) are case-sensitive, where two such strings genuinely
/// name different files, so Ordinal stays correct there.</summary>
public static class PathComparisonPolicy
{
    /// <summary>The <see cref="StringComparison"/> to use for comparing two file-system path
    /// strings (or a composite key built from one, e.g. <see cref="Reading.ReadingPositions.MakeKey"/>'s
    /// "path|size|mtime") for equality — <see cref="StringComparison.OrdinalIgnoreCase"/> on
    /// Windows/macOS, <see cref="StringComparison.Ordinal"/> everywhere else.</summary>
    public static StringComparison ForPaths()
        => OperatingSystem.IsWindows() || OperatingSystem.IsMacOS()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
}
