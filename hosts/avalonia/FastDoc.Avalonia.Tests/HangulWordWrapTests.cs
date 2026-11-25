using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Paging;
using FastDoc.Avalonia.Rendering;
using Xunit;

namespace FastDoc.Avalonia.Tests;

/// <summary>`eastAsianLineBreak = word` keeps a Korean word whole, as macOS's `.hangulWordPriority`
/// does (INVARIANTS 207): a line never ends between two Hangul characters while an earlier break
/// opportunity exists on it, and the layout's character ranges still tile the block's own text.</summary>
public sealed class HangulWordWrapTests
{
    private const string Text = "최종 지원대상 사업계획, 사업비 심의 및 결과 통보를 위한 행정업무운영편람의 문단";

    public HangulWordWrapTests() => AvaloniaHeadlessSetup.EnsureReady();

    private static FlowBlock Block(string? lineBreak)
    {
        var style = lineBreak is null ? "{}" : $$"""{ "eastAsianLineBreak": "{{lineBreak}}" }""";
        var json = $$"""
        { "ok": { "schemaVersion": 1,
          "document": { "format": "hwp", "rootNodeId": 0, "defaultBodyFontSize": 10 },
          "nodes": [
            { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
            { "id": 1, "parentId": 0, "children": [2], "type": "paragraph", "data": { "style": {{style}} } },
            { "id": 2, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "{{Text}}", "style": { "fontSizePoints": 10 } } } ],
          "annotations": { "comments": [], "bookmarks": [] } } }
        """;
        var tree = JsonSerializer.Deserialize<RenderTreeEnvelope>(json)!.Ok!.Value.Deserialize<RenderTree>()!;
        return FlowDocumentBuilder.Build(tree).Single();
    }

    /// <summary>Line ends (exclusive) that split a Korean word although the line had a space to break at.</summary>
    private static List<int> SplitWords(FlowBlock block, double width, out int covered)
    {
        var layout = PageLayout.BuildPointsTextLayout(block, width)!;
        var bad = new List<int>();
        covered = 0;
        foreach (var line in layout.TextLines)
        {
            Assert.Equal(covered, line.FirstTextSourceIndex);
            covered += line.Length;
            var end = line.FirstTextSourceIndex + line.Length;
            var head = Text.Substring(line.FirstTextSourceIndex, line.Length).TrimEnd();
            if (end < Text.Length && HangulWordWrap.IsHangul(Text[end - 1]) && HangulWordWrap.IsHangul(Text[end]) && head.Contains(' '))
            {
                bad.Add(end);
            }
        }
        return bad;
    }

    [Fact]
    public void The_wire_word_setting_reaches_the_block()
    {
        Assert.True(Block("word").HangulWordBreak);
        Assert.False(Block("character").HangulWordBreak);
        Assert.False(Block(null).HangulWordBreak);
    }

    [Fact]
    public void A_word_paragraph_never_breaks_inside_a_Korean_word_and_keeps_its_indices()
    {
        var plainSplits = 0;
        for (var width = 40.0; width <= 200; width += 3)
        {
            plainSplits += SplitWords(Block(null), width, out var plainCovered).Count;
            Assert.Equal(Text.Length, plainCovered);
            Assert.Empty(SplitWords(Block("word"), width, out var covered));
            Assert.Equal(Text.Length, covered);
        }
        // The check is not vacuous: Avalonia's own breaker splits words at these widths.
        Assert.True(plainSplits > 0);
    }
}
