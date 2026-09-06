using System.IO;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// RenderTreeLoader (Rendering/RenderTreeLoader.cs) picks one of three doors by file extension:
/// text tree (md/txt/...), office tree (docx/odt/hwp/...), or an immediate "unsupportedExtension"
/// error for anything else. The text and office doors both end in a native P/Invoke call
/// (fastdoc_read_text_tree / fastdoc_office_open), so exercising THEM here would make this a
/// FASTDOC_ENGINE_LIB integration test rather than a unit test — that coverage belongs to
/// Scripts/host-gate.sh's headless --extract smoke runs (moby-dick.md / the docx / the hwpx),
/// which already prove both doors end-to-end against the real engine.
///
/// What IS a pure unit here: the "no reader for this extension" branch returns its error WITHOUT
/// ever reaching FastdocEngine, so it needs no native library loaded — it fails on classification
/// alone. Asserting on it is what proves the classification runs before the native call, not
/// after a caught exception from one.
/// </summary>
public class RenderTreeLoaderExtensionRoutingTests
{
    [Fact]
    public void Unsupported_extension_returns_unsupportedExtension_error_without_touching_the_engine()
    {
        var path = Path.Combine(Path.GetTempPath(), $"fastdoc-loader-test-{Path.GetRandomFileName()}.zzzz");
        File.WriteAllBytes(path, new byte[] { 1, 2, 3 });
        try
        {
            var result = RenderTreeLoader.Load(path);

            Assert.False(result.IsOk);
            Assert.NotNull(result.Error);
            Assert.Equal("unsupportedExtension", result.Error!.Kind);
            Assert.Contains(".zzzz", result.Error.Message);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void Unsupported_extension_is_case_insensitive_like_the_supported_sets()
    {
        // TextExtensions/OfficeExtensions both use OrdinalIgnoreCase; the fallback branch should
        // reject an unknown extension the same way regardless of case, not just lower-case.
        var path = Path.Combine(Path.GetTempPath(), $"fastdoc-loader-test-{Path.GetRandomFileName()}.ZZZZ");
        File.WriteAllBytes(path, new byte[] { 1 });
        try
        {
            var result = RenderTreeLoader.Load(path);
            Assert.False(result.IsOk);
            Assert.Equal("unsupportedExtension", result.Error!.Kind);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void LoadWithBreakdown_reports_the_same_unsupportedExtension_error_as_Load()
    {
        // LoadWithBreakdown duplicates Load's classification (see the file's own comment on why
        // it is a second copy, not a shared helper) — this pins that the two stay in agreement
        // for the one branch this test can reach without the engine.
        var path = Path.Combine(Path.GetTempPath(), $"fastdoc-loader-test-{Path.GetRandomFileName()}.unknown");
        File.WriteAllBytes(path, new byte[] { 1 });
        try
        {
            var breakdown = RenderTreeLoader.LoadWithBreakdown(path);
            Assert.False(breakdown.IsOk);
            Assert.Equal("unsupportedExtension", breakdown.Error!.Kind);
            Assert.Equal(0, breakdown.DeserializeMs);
        }
        finally
        {
            File.Delete(path);
        }
    }
}
