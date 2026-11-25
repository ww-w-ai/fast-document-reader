using System.Linq;
using System.Text.Json;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Paging;
using FastDoc.Avalonia.Rendering;
using Xunit;

namespace FastDoc.Avalonia.Tests;

/// <summary>장평 scales every glyph by its OWN advance, as macOS's horizontal font scale does
/// (INVARIANTS 207): a space loses its own share, not a syllable's. The old per-paragraph letter
/// spacing took a full-width glyph's share from every character, spaces included.</summary>
public sealed class GlyphWidthScaleTests
{
    public GlyphWidthScaleTests() => AvaloniaHeadlessSetup.EnsureReady();

    private static double Width(string text, string? widthScale)
    {
        var scale = widthScale is null ? "" : $$""", "widthScalePercent": {{widthScale}}""";
        var json = $$"""
        { "ok": { "schemaVersion": 1,
          "document": { "format": "hwp", "rootNodeId": 0, "defaultBodyFontSize": 10 },
          "nodes": [
            { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
            { "id": 1, "parentId": 0, "children": [2], "type": "paragraph", "data": { "style": {} } },
            { "id": 2, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "{{text}}", "style": { "fontSizePoints": 10{{scale}} } } } ],
          "annotations": { "comments": [], "bookmarks": [] } } }
        """;
        var tree = JsonSerializer.Deserialize<RenderTreeEnvelope>(json)!.Ok!.Value.Deserialize<RenderTree>()!;
        var block = FlowDocumentBuilder.Build(tree).Single();
        Assert.Equal(0, block.LetterSpacingPoints, 6);
        return PageLayout.BuildPointsTextLayout(block, 10_000)!.WidthIncludingTrailingWhitespace;
    }

    [Theory]
    [InlineData("한글 사업계획, 사업비")]
    [InlineData("a b c, d")]
    [InlineData("    ")]
    public void Every_glyph_advance_is_scaled_by_the_width_scale(string text)
    {
        var normal = Width(text, null);
        Assert.Equal(normal * 0.91, Width(text, "91.0"), 3);
        Assert.Equal(normal, Width(text, "100.0"), 6);
    }
}
