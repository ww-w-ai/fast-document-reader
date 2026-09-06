using System.Collections.Generic;
using System.Text.Json;
using Avalonia;
using Avalonia.Media;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Rendering;
using Xunit;

namespace FastDoc.Avalonia.Tests;

/// <summary>S8-B3: `wire::CodeBlock.runs` -> `FlowDocumentBuilder`'s per-role coloured
/// `FlowRun` split. `AvaloniaHeadlessSetup` (see PagingTests.cs) configures a bare `Application`
/// that never loads FastDoc.Avalonia's own App.axaml, so the "expected role colour" assertion
/// below installs its own flat resource entries rather than depending on the real theme file —
/// the same fallback-literal limitation `S8D2SelectionTests` already documents for
/// FlowDocumentView's theme brushes.</summary>
public class S8B3CodeHighlightTests
{
    public S8B3CodeHighlightTests() => AvaloniaHeadlessSetup.EnsureReady();

    private static RenderTree TreeWithOneCodeBlock(string dataJson)
    {
        using var doc = JsonDocument.Parse(dataJson);
        return new RenderTree
        {
            SchemaVersion = 1,
            Document = new RenderDocument { RootNodeId = 0, DefaultBodyFontSize = 12 },
            Nodes = new List<RenderNode>
            {
                new() { Id = 0, Type = "document", Children = new List<ulong> { 1 }, Data = JsonDocument.Parse("{}").RootElement.Clone() },
                new() { Id = 1, Type = "codeBlock", Children = new List<ulong>(), Data = doc.RootElement.Clone() },
            },
        };
    }

    [Fact]
    public void A_known_role_run_splits_the_text_and_colours_from_the_installed_theme_resource()
    {
        // "fn main" — "fn" (0..2) coloured keyword, a gap ("  ", 2..3 — a space) stays default,
        // "main" (3..7) coloured type.
        var tree = TreeWithOneCodeBlock("""
        {
          "language": "rust",
          "fenced": true,
          "text": "fn main",
          "runs": [
            {"start": 0, "end": 2, "role": "keyword"},
            {"start": 3, "end": 7, "role": "type"}
          ]
        }
        """);

        var expectedKeyword = Color.FromRgb(0x11, 0x22, 0x33);
        var expectedType = Color.FromRgb(0x44, 0x55, 0x66);
        Application.Current!.Resources["CodeRoleKeywordColor"] = expectedKeyword;
        Application.Current!.Resources["CodeRoleTypeColor"] = expectedType;
        try
        {
            var blocks = FlowDocumentBuilder.Build(tree);

            Assert.Single(blocks);
            var runs = blocks[0].Runs;
            Assert.Equal(3, runs.Count);
            Assert.Equal("fn", runs[0].Text);
            Assert.Equal(expectedKeyword, runs[0].Foreground);
            Assert.Equal(" ", runs[1].Text);
            Assert.Equal("main", runs[2].Text);
            Assert.Equal(expectedType, runs[2].Foreground);
            // The gap run and the keyword/type runs must NOT share a colour with each other —
            // otherwise this test could pass by accident with every run painted the same.
            Assert.NotEqual(runs[0].Foreground, runs[1].Foreground);
            Assert.NotEqual(runs[2].Foreground, runs[1].Foreground);
        }
        finally
        {
            Application.Current!.Resources.Remove("CodeRoleKeywordColor");
            Application.Current!.Resources.Remove("CodeRoleTypeColor");
        }
    }

    [Fact]
    public void An_unrecognised_role_string_is_ignored_rather_than_thrown()
    {
        var tree = TreeWithOneCodeBlock("""
        {
          "language": "future-lang",
          "fenced": true,
          "text": "abcdef",
          "runs": [
            {"start": 0, "end": 3, "role": "some-future-role-this-host-does-not-know"}
          ]
        }
        """);

        var blocks = FlowDocumentBuilder.Build(tree);

        Assert.Single(blocks);
        var runs = blocks[0].Runs;
        // The token boundary still splits the text (structurally forward-compatible), but an
        // unrecognised role paints no differently from the untouched tail — same colour, no crash.
        Assert.Equal(2, runs.Count);
        Assert.Equal("abc", runs[0].Text);
        Assert.Equal("def", runs[1].Text);
        Assert.Equal(runs[0].Foreground, runs[1].Foreground);
    }

    [Fact]
    public void No_runs_at_all_paints_the_whole_block_as_one_uncoloured_run()
    {
        var tree = TreeWithOneCodeBlock("""
        {"language": null, "fenced": false, "text": "plain text, no fence language"}
        """);

        var blocks = FlowDocumentBuilder.Build(tree);

        Assert.Single(blocks);
        Assert.Single(blocks[0].Runs);
        Assert.Equal("plain text, no fence language", blocks[0].Runs[0].Text);
    }
}
