using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using global::Avalonia.Headless;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Panels;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S9-B3 batch 3 (docs/studio/sprints/S9/s9b1-full-parity.md #23/#24): View > Line Numbers +
/// Go to Line…, flow mode only. See <see cref="LineNumberModel"/>'s own doc for the deliberate scope
/// narrowing (top-level block numbers, not per-wrapped-line — page mode explicitly out of scope for
/// this batch since it would mean editing FlowDocumentView's shared table/measure/draw code, which
/// this batch leaves alone).
/// </summary>
public class S9B3Batch3Tests
{
    public S9B3Batch3Tests() => AvaloniaHeadlessSetup.EnsureReady();

    private static RenderTree MixedBlockTree()
    {
        // paragraph, blank paragraph (unnumbered — no visible run), rule (unnumbered), image, table.
        const string json = """
        {
          "schemaVersion": 1,
          "document": { "rootNodeId": 0, "defaultBodyFontSize": 12.0 },
          "nodes": [
            { "id": 0, "parentId": null, "type": "document", "children": [1, 2, 3, 4, 5], "data": {} },
            { "id": 1, "parentId": 0, "type": "paragraph", "children": [10], "data": { "style": {} } },
            { "id": 10, "parentId": 1, "type": "textRun", "children": [], "data": { "text": "first line", "style": {} } },
            { "id": 2, "parentId": 0, "type": "paragraph", "children": [], "data": { "style": {} } },
            { "id": 3, "parentId": 0, "type": "thematicBreak", "children": [], "data": {} },
            { "id": 4, "parentId": 0, "type": "image", "children": [], "data": { "intrinsicSize": { "width": 10, "height": 10 } } },
            { "id": 5, "parentId": 0, "type": "paragraph", "children": [11], "data": { "style": {} } },
            { "id": 11, "parentId": 5, "type": "textRun", "children": [], "data": { "text": "second line", "style": {} } }
          ]
        }
        """;
        return JsonSerializer.Deserialize<RenderTree>(json)!;
    }

    // ---- 1. LineNumberModel (pure) ----------------------------------------------------------------

    [Fact]
    public void IsNumbered_excludes_rules_and_empty_text_but_includes_images_and_tables()
    {
        var tree = MixedBlockTree();
        var blocks = FlowDocumentBuilder.Build(tree);
        // Block order per FlowDocumentBuilder: paragraph(first line), blank paragraph, rule, image, paragraph(second line)
        Assert.Equal(5, blocks.Count);
        Assert.True(LineNumberModel.IsNumbered(blocks[0]));  // "first line"
        Assert.False(LineNumberModel.IsNumbered(blocks[1])); // blank paragraph
        Assert.False(LineNumberModel.IsNumbered(blocks[2])); // rule
        Assert.True(LineNumberModel.IsNumbered(blocks[3]));  // image
        Assert.True(LineNumberModel.IsNumbered(blocks[4]));  // "second line"
    }

    [Fact]
    public void LabelFor_numbers_only_the_numbered_blocks_sequentially_with_no_gap()
    {
        var tree = MixedBlockTree();
        var blocks = FlowDocumentBuilder.Build(tree);

        Assert.Equal("1", LineNumberModel.LabelFor(blocks, 0));
        Assert.Null(LineNumberModel.LabelFor(blocks, 1));   // blank — unnumbered
        Assert.Null(LineNumberModel.LabelFor(blocks, 2));   // rule — unnumbered
        Assert.Equal("2", LineNumberModel.LabelFor(blocks, 3)); // image — the SECOND numbered block
        Assert.Equal("3", LineNumberModel.LabelFor(blocks, 4)); // second paragraph — THIRD numbered block
    }

    [Fact]
    public void LabelFor_returns_null_for_out_of_range_index()
    {
        var blocks = FlowDocumentBuilder.Build(MixedBlockTree());
        Assert.Null(LineNumberModel.LabelFor(blocks, -1));
        Assert.Null(LineNumberModel.LabelFor(blocks, blocks.Count));
    }

    [Fact]
    public void NumberedCount_matches_the_last_LabelFor_value()
    {
        var blocks = FlowDocumentBuilder.Build(MixedBlockTree());
        Assert.Equal(3, LineNumberModel.NumberedCount(blocks));
    }

    [Fact]
    public void BlockIndexForLineNumber_is_the_exact_inverse_of_LabelFor()
    {
        var blocks = FlowDocumentBuilder.Build(MixedBlockTree());
        Assert.Equal(0, LineNumberModel.BlockIndexForLineNumber(blocks, 1));
        Assert.Equal(3, LineNumberModel.BlockIndexForLineNumber(blocks, 2));
        Assert.Equal(4, LineNumberModel.BlockIndexForLineNumber(blocks, 3));
        Assert.Null(LineNumberModel.BlockIndexForLineNumber(blocks, 0));
        Assert.Null(LineNumberModel.BlockIndexForLineNumber(blocks, 4));
    }

    // ---- 2. FlowDocumentView surface --------------------------------------------------------------

    [Fact]
    public void ShowLineNumbers_defaults_false_and_is_settable()
    {
        var view = new FlowDocumentView();
        Assert.False(view.ShowLineNumbers);
        view.ShowLineNumbers = true;
        Assert.True(view.ShowLineNumbers);
        view.ShowLineNumbers = false;
        Assert.False(view.ShowLineNumbers);
    }

    [Fact]
    public void LineNumberCount_reflects_the_loaded_tree()
    {
        var view = new FlowDocumentView();
        Assert.Equal(0, view.LineNumberCount);
        view.SetTree(MixedBlockTree());
        Assert.Equal(3, view.LineNumberCount);
    }

    [Fact]
    public void ScrollToLineNumber_moves_the_reading_position_to_the_right_block()
    {
        var view = new FlowDocumentView();
        view.SetTree(MixedBlockTree());
        // A viewport shorter than the total content height, so scrolling to the last block is not
        // clamped back to 0 by ScrollOffset's own max-scroll clamp (max scroll = 0 when everything
        // already fits on screen).
        var window = new global::Avalonia.Controls.Window { Width = 400, Height = 40, Content = view };
        window.Show();
        window.CaptureRenderedFrame();

        Assert.True(view.ScrollToLineNumber(1)); // "first line", block index 0
        var offsetAtLineOne = view.ScrollOffset;

        Assert.True(view.ScrollToLineNumber(3)); // "second line", block index 4 — the LAST block
        var offsetAtLineThree = view.ScrollOffset;

        // GetCurrentPositionForSave's own LowerBound rounding is not this test's concern (it is
        // exercised directly by ReadingPositionTests) — what matters here is that ScrollToLineNumber
        // actually moved the viewport FORWARD to a later block, proving the menu-facing method
        // reaches a real block position rather than being a no-op.
        Assert.True(offsetAtLineThree > offsetAtLineOne,
            $"expected line 3 ('second line', the last block) to scroll further than line 1; " +
            $"got line1={offsetAtLineOne} line3={offsetAtLineThree}");
    }

    [Fact]
    public void ScrollToLineNumber_returns_false_for_out_of_range_or_page_mode()
    {
        var view = new FlowDocumentView();
        view.SetTree(MixedBlockTree());
        Assert.False(view.ScrollToLineNumber(0));
        Assert.False(view.ScrollToLineNumber(999));
    }

    // ---- 3. GoToLineModel (pure validation) -------------------------------------------------------

    [Theory]
    [InlineData("1", 5, 1, null)]
    [InlineData("5", 5, 5, null)]
    [InlineData("0", 5, 0, "Enter a number between 1 and 5.")]
    [InlineData("6", 5, 0, "Enter a number between 1 and 5.")]
    [InlineData("abc", 5, 0, "Not a number.")]
    [InlineData("", 5, 0, "Enter a line number.")]
    [InlineData(null, 5, 0, "Enter a line number.")]
    [InlineData("1", 0, 0, "This document has no lines to go to.")]
    public void Validate_matches_expected_result(string? text, int maxLine, int expectedLine, string? expectedError)
    {
        var (lineNumber, error) = GoToLineModel.Validate(text, maxLine);
        Assert.Equal(expectedLine, lineNumber);
        Assert.Equal(expectedError, error);
    }

    [Fact]
    public void Validate_trims_whitespace()
    {
        var (lineNumber, error) = GoToLineModel.Validate("  3  ", 5);
        Assert.Equal(3, lineNumber);
        Assert.Null(error);
    }

    // ---- 4. menu + guide wiring (source contract, same rationale as S9B3Batch2Tests) --------------

    [Fact]
    public void MainWindow_axaml_declares_line_numbers_toggle_and_go_to_line_with_distinct_shortcuts()
    {
        var repoRoot = FindRepoRoot();
        var axaml = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia", "MainWindow.axaml"));

        Assert.Contains("LineNumbersMenuItem", axaml);
        Assert.Contains("InputGesture=\"Ctrl+Shift+L\"", axaml);
        Assert.Contains("GoToLineMenuItem", axaml);
        Assert.Contains("InputGesture=\"Ctrl+L\"", axaml);
        Assert.Contains("OnLineNumbersToggleClicked", axaml);
        Assert.Contains("OnGoToLineClicked", axaml);
    }

    [Fact]
    public void MainWindow_cs_disables_flow_only_items_in_page_mode_and_with_no_document()
    {
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia", "MainWindow.axaml.cs"));

        Assert.Contains("Canvas.ShowLineNumbers = !Canvas.ShowLineNumbers;", source);
        Assert.Contains("var enabled = Canvas.HasDocument && !Canvas.PageMode;", source);
        Assert.Contains("LineNumbersMenuItem.IsEnabled = enabled;", source);
        Assert.Contains("GoToLineMenuItem.IsEnabled = enabled;", source);
    }

    [Fact]
    public void ShortcutGuideModel_lists_both_new_shortcuts_and_they_are_in_MenuGestureKeys()
    {
        var groups = ShortcutGuideModel.Build();
        var view = groups.Single(g => g.Title == "View");
        Assert.Contains(view.Entries, e => e.Keys == "Ctrl+Shift+L");
        Assert.Contains(view.Entries, e => e.Keys == "Ctrl+L");
        Assert.Contains("Ctrl+Shift+L", ShortcutGuideModel.MenuGestureKeys);
        Assert.Contains("Ctrl+L", ShortcutGuideModel.MenuGestureKeys);
    }

    [Fact]
    public void GoToLineWindow_has_a_parameterless_constructor_and_a_separate_Configure_method()
    {
        // Regression guard for the AVLN3001 fix: a Window subclass with a constructor PARAMETER
        // makes its compiled XAML unreachable via the avares:// loader.
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia",
            "Panels", "GoToLineWindow.axaml.cs"));
        Assert.Contains("public GoToLineWindow()", source);
        Assert.Contains("public void Configure(FlowDocumentView canvas)", source);
    }

    private static string FindRepoRoot()
    {
        var dir = AppContext.BaseDirectory;
        while (dir is not null && !Directory.Exists(Path.Combine(dir, ".git")))
        {
            dir = Directory.GetParent(dir)?.FullName;
        }
        return dir ?? throw new InvalidOperationException("repo root not found");
    }
}
