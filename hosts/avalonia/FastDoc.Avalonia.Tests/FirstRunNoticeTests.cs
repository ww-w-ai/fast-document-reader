using FastDoc.Avalonia.Open;

namespace FastDoc.Avalonia.Tests;

/// <summary>S8-B2 ②: FirstRunNotice.ShouldShow against a FAKE IFileProbe — never touches the real
/// flag file under LocalApplicationData.</summary>
public class FirstRunNoticeTests
{
    private sealed class FakeFileProbe : IFileProbe
    {
        public bool Result;
        public string? RequestedPath;
        public bool Exists(string path)
        {
            RequestedPath = path;
            return Result;
        }
    }

    [Fact]
    public void ShouldShow_is_true_when_the_flag_file_is_absent()
    {
        var probe = new FakeFileProbe { Result = false };
        Assert.True(FirstRunNotice.ShouldShow(probe));
    }

    [Fact]
    public void ShouldShow_is_false_when_the_flag_file_exists()
    {
        var probe = new FakeFileProbe { Result = true };
        Assert.False(FirstRunNotice.ShouldShow(probe));
    }

    [Fact]
    public void ShouldShow_checks_the_documented_flag_file_path()
    {
        var probe = new FakeFileProbe { Result = false };
        FirstRunNotice.ShouldShow(probe);
        Assert.Equal(FirstRunNotice.FlagFilePath, probe.RequestedPath);
        Assert.EndsWith("first-run-done", probe.RequestedPath);
    }
}
