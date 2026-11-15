using System.Text;
using System.Diagnostics;
using FastDoc.Avalonia.Rendering;
using FastDoc.Avalonia.Model;

namespace FastDoc.Avalonia.Tests;

public sealed class NativeEngineFactAttribute : FactAttribute
{
    public NativeEngineFactAttribute()
    {
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("FASTDOC_ENGINE_LIB")))
            Skip = "Set FASTDOC_ENGINE_LIB to run native integration tests.";
    }
}

public class NativeOpenAnyFileTests
{
    [NativeEngineFact]
    public void Explicit_files_reach_native_text_decoder()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        var dir = Path.Combine(Path.GetTempPath(), "fastdoc-native-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        try
        {
            var files = new (string Name, byte[] Bytes, string Expected)[]
            {
                ("config", Encoding.UTF8.GetBytes("config-sentinel"), "config-sentinel"),
                (".env", Encoding.UTF8.GetBytes("env-sentinel"), "env-sentinel"),
                ("file.xyz", Encoding.UTF8.GetBytes("unknown-sentinel"), "unknown-sentinel"),
                ("binary.bin", new byte[] { 0xff, 0x00, 0x01, 0xfe }, ""),
                ("legacy.cfg", Encoding.GetEncoding(949).GetBytes("한글 CP949"), "한글 CP949"),
                ("utf16.xyz", Encoding.Unicode.GetPreamble().Concat(Encoding.Unicode.GetBytes("한글 UTF16")).ToArray(), "한글 UTF16"),
            };
            foreach (var file in files)
            {
                var path = Path.Combine(dir, file.Name);
                File.WriteAllBytes(path, file.Bytes);
                foreach (var breakdown in new[] { false, true })
                {
                    var tree = breakdown ? RenderTreeLoader.LoadWithBreakdown(path).Tree : RenderTreeLoader.Load(path).Tree;
                    Assert.NotNull(tree);
                    if (file.Expected.Length > 0)
                        Assert.Contains(file.Expected, string.Join("", tree!.Nodes.Select(n => n.AsTextRun?.Text ?? "")));
                }
            }
        }
        finally { Directory.Delete(dir, recursive: true); }
    }

    [NativeEngineFact]
    public void Headless_extract_uses_decoded_source_and_preserves_line_endings()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        var dir = Path.Combine(Path.GetTempPath(), "fastdoc-extract-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        try
        {
            var entries = new (string Name, byte[] Bytes, string Expected)[]
            {
                ("cp949.cfg", Encoding.GetEncoding(949).GetBytes("한글\\r\\n끝\\r\\n"), "한글\\r\\n끝\\r\\n"),
                ("utf16.cfg", Encoding.Unicode.GetPreamble().Concat(Encoding.Unicode.GetBytes("한글\\r\\n끝")).ToArray(), "한글\\r\\n끝"),
                ("test.md", Encoding.UTF8.GetBytes("# Hi\\r\\n\\r\\nend\\n"), "# Hi\\r\\n\\r\\nend\\n")
            };
            foreach (var entry in entries)
            {
                var path = Path.Combine(dir, entry.Name);
                File.WriteAllBytes(path, entry.Bytes);
                var result = RenderTreeLoader.Load(path);
                Assert.NotNull(result.Tree);
                Assert.Equal(entry.Expected, Program.BuildExtractedMarkdown(path, result.Tree!));
                var start = new ProcessStartInfo(Environment.GetEnvironmentVariable("DOTNET_HOST_PATH") ?? "dotnet")
                {
                    RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false
                };
                start.ArgumentList.Add(typeof(RenderTreeLoader).Assembly.Location);
                start.ArgumentList.Add("--extract");
                start.ArgumentList.Add(path);
                using var process = Process.Start(start)!;
                var output = process.StandardOutput.ReadToEnd();
                var error = process.StandardError.ReadToEnd();
                process.WaitForExit();
                Assert.True(process.ExitCode == 0, error);
                Assert.Equal(entry.Expected, output);
            }
        }
        finally { Directory.Delete(dir, recursive: true); }
    }

    [Fact]
    public void Extract_requires_one_document_declared_decoded_source()
    {
        var tree = new RenderTree { Document = new RenderDocument { SourceIds = new() { 2 } } };
        tree.Sources.Add(new SourceDescriptorWire { Id = 1, Kind = "decodedText", TextContent = "unrelated" });
        Assert.Throws<InvalidOperationException>(() => Program.BuildExtractedMarkdown("test.cfg", tree));
        tree.Sources.Add(new SourceDescriptorWire { Id = 2, Kind = "decodedText", TextContent = "declared" });
        Assert.Equal("declared", Program.BuildExtractedMarkdown("test.cfg", tree));
        tree.Document.SourceIds.Add(3);
        tree.Sources.Add(new SourceDescriptorWire { Id = 3, Kind = "decodedText", TextContent = "ambiguous" });
        Assert.Throws<InvalidOperationException>(() => Program.BuildExtractedMarkdown("test.cfg", tree));
    }
}
