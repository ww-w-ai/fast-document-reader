using System.IO;
using System.Diagnostics;
using System.Reflection;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

public class RenderTreeLoaderExtensionRoutingTests
{
    [Theory]
    [InlineData("unknown")]
    [InlineData("")]
    public void Oversized_plain_file_is_rejected_before_engine(string extension)
    {
        var path = Path.Combine(Path.GetTempPath(), $"fastdoc-{Path.GetRandomFileName()}.{extension}");
        try
        {
            using (var stream = File.Create(path)) stream.SetLength(16 * 1024 * 1024 + 1);
            Assert.Contains("16 MiB", Assert.Throws<IOException>(() => RenderTreeLoader.Load(path)).Message);
            Assert.Contains("16 MiB", Assert.Throws<IOException>(() => RenderTreeLoader.LoadWithBreakdown(path)).Message);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void Unix_regular_file_opens_and_fifo_directory_and_device_are_rejected()
    {
        if (OperatingSystem.IsWindows()) return;
        var directory = Path.Combine(Path.GetTempPath(), "fastdoc-" + Path.GetRandomFileName());
        Directory.CreateDirectory(directory);
        var file = Path.Combine(directory, "regular");
        var fifo = Path.Combine(directory, "fifo");
        File.WriteAllText(file, "regular-sentinel");
        var open = typeof(RenderTreeLoader).GetMethod("OpenRegularFile", BindingFlags.NonPublic | BindingFlags.Static)!;
        try
        {
            using (var regular = (FileStream)open.Invoke(null, new object[] { file })!)
            using (var reader = new StreamReader(regular))
                Assert.Equal("regular-sentinel", reader.ReadToEnd());
            using var process = Process.Start(new ProcessStartInfo("mkfifo", fifo) { UseShellExecute = false })!;
            process.WaitForExit();
            Assert.Equal(0, process.ExitCode);
            foreach (var path in new[] { directory, fifo, "/dev/null" })
                Assert.IsType<IOException>(Assert.Throws<TargetInvocationException>(() => open.Invoke(null, new object[] { path })).InnerException);
            Assert.IsType<FileNotFoundException>(Assert.Throws<TargetInvocationException>(() =>
                open.Invoke(null, new object[] { Path.Combine(directory, "missing") })).InnerException);
        }
        finally { Directory.Delete(directory, recursive: true); }
    }
}
