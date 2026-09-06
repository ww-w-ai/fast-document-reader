using System;
using FastDoc.Avalonia.Open;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// The pure per-OS decision RecentFiles and ReadingPositions both route their path-equality
/// checks through, instead of each hardcoding StringComparison.Ordinal. See
/// RecentFilesTests.RecordOpened_treats_a_case_different_reopen_as_the_same_entry_on_Windows_and_macOS
/// for the end-to-end behavior this enables.
/// </summary>
public class PathComparisonPolicyTests
{
    [Fact]
    public void Two_paths_differing_only_in_case_compare_equal_on_Windows_and_macOS_but_not_Linux()
    {
        const string a = "/Users/x/Report.docx";
        const string b = "/Users/x/report.DOCX";

        var comparison = PathComparisonPolicy.ForPaths();
        var actuallyEqual = string.Equals(a, b, comparison);

        var expectCaseInsensitive = OperatingSystem.IsWindows() || OperatingSystem.IsMacOS();
        Assert.Equal(expectCaseInsensitive, actuallyEqual);
    }

    [Fact]
    public void Two_genuinely_different_paths_never_compare_equal_regardless_of_platform()
    {
        var comparison = PathComparisonPolicy.ForPaths();
        Assert.False(string.Equals("/Users/x/a.docx", "/Users/x/b.docx", comparison));
    }
}
