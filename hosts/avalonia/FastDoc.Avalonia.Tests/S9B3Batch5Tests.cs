using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using global::Avalonia.Headless;
using global::Avalonia.Input;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S9-B3 batch 5 (docs/studio/sprints/S9/s9b1-full-parity.md #39/#40/#43/#44): right-click Open…/
/// Select All, Ctrl/Cmd-click on a selection opens it as a link/path, and left-gutter click copies
/// the whole line.
/// </summary>
public class S9B3Batch5Tests
{
    public S9B3Batch5Tests() => AvaloniaHeadlessSetup.EnsureReady();

    // ---- 1. SelectionOpenTarget (pure) -------------------------------------------------------------

    [Theory]
    [InlineData("https://example.com/page", "https://example.com/page")]
    [InlineData("http://example.com", "http://example.com")]
    [InlineData("mailto:person@example.com", "mailto:person@example.com")]
    [InlineData("  https://example.com/trimmed  ", "https://example.com/trimmed")]
    public void Resolve_accepts_absolute_http_https_and_mailto_uris(string input, string expected)
    {
        Assert.Equal(expected, SelectionOpenTarget.Resolve(input));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("just some ordinary prose")]
    [InlineData("ftp://not-in-the-allowlist.example.com")]
    public void Resolve_returns_null_for_blank_prose_and_disallowed_schemes(string? input)
    {
        Assert.Null(SelectionOpenTarget.Resolve(input));
    }

    [Fact]
    public void Resolve_accepts_a_path_that_exists_on_disk()
    {
        var tempFile = Path.GetTempFileName();
        try
        {
            Assert.Equal(tempFile, SelectionOpenTarget.Resolve(tempFile));
        }
        finally
        {
            File.Delete(tempFile);
        }
    }

    [Fact]
    public void Resolve_returns_null_for_a_path_that_does_not_exist()
    {
        var missing = Path.Combine(Path.GetTempPath(), "fastdoc-s9b3-does-not-exist-" + Guid.NewGuid());
        Assert.Null(SelectionOpenTarget.Resolve(missing));
    }

    // ---- 2. ContextMenuModel (already covered in depth by S8B4NodeIdLinksTests's own updated
    // assertions — this file adds only the IsOpen/IsSelectAll discriminator checks that test file's
    // scope does not otherwise need) ------------------------------------------------------------

    [Fact]
    public void Build_marks_the_Open_item_with_IsOpen_and_the_Select_All_item_with_IsSelectAll()
    {
        var items = ContextMenuModel.Build(hasSelection: false, onLink: true);
        var open = Assert.Single(items, i => i.Header == "Open");
        Assert.True(open.IsOpen);
        Assert.False(open.IsCopyLink);
        var selectAll = Assert.Single(items, i => i.Header == "Select All");
        Assert.True(selectAll.IsSelectAll);
    }

    [Fact]
    public void Build_never_shows_Open_when_the_click_did_not_land_on_a_link()
    {
        var items = ContextMenuModel.Build(hasSelection: true, onLink: false);
        Assert.DoesNotContain(items, i => i.Header == "Open");
    }

    // ---- 3. FlowDocumentView's Ctrl-click-opens-selection and gutter-click-copies-line, exercised
    // through the real pointer pipeline via Avalonia's headless input helpers ---------------------

    private static RenderTree TwoParagraphTree(string first, string second)
    {
        var json = $$"""
        {
          "schemaVersion": 1,
          "document": { "rootNodeId": 0, "defaultBodyFontSize": 12.0 },
          "nodes": [
            { "id": 0, "parentId": null, "type": "document", "children": [1, 2], "data": {} },
            { "id": 1, "parentId": 0, "type": "paragraph", "children": [10], "data": { "style": {} } },
            { "id": 10, "parentId": 1, "type": "textRun", "children": [], "data": { "text": {{JsonSerializer.Serialize(first)}}, "style": {} } },
            { "id": 2, "parentId": 0, "type": "paragraph", "children": [11], "data": { "style": {} } },
            { "id": 11, "parentId": 2, "type": "textRun", "children": [], "data": { "text": {{JsonSerializer.Serialize(second)}}, "style": {} } }
          ]
        }
        """;
        return JsonSerializer.Deserialize<RenderTree>(json)!;
    }

    /// <summary>A launcher that records every URL handed to it instead of actually shelling out —
    /// the same seam ExternalLinkLauncher's own doc says exists for exactly this kind of test.</summary>
    private sealed class RecordingLauncher : IExternalLinkLauncher
    {
        public List<string> Opened { get; } = new();
        public void Open(string url) => Opened.Add(url);
    }

    [Fact]
    public void CtrlClick_on_a_selected_path_opens_it_and_leaves_the_selection_untouched()
    {
        var tempFile = Path.GetTempFileName();
        try
        {
            var view = new FlowDocumentView();
            var launcher = new RecordingLauncher();
            view.ExternalLinkLauncher = launcher;
            view.SetTree(TwoParagraphTree(tempFile, "second line"));
            var window = new global::Avalonia.Controls.Window { Width = 400, Height = 200, Content = view };
            window.Show();
            window.CaptureRenderedFrame();

            // Selects exactly the first block's full text (the temp file path) directly through
            // SelectionModel's own public Begin/ExtendTo — driving a real pointer drag to select an
            // EXACT known substring is brittle (it depends on where a wrapped line breaks), while
            // the thing this test actually exercises is what a Ctrl-click does ONCE a selection
            // already exists, not how the selection got there.
            var selection = GetPrivateField<SelectionModel>(view, "_selection");
            selection.Begin(new TextPosition(0, 0));
            selection.ExtendTo(new TextPosition(0, tempFile.Length));
            Assert.False(view.Selection.IsEmpty);
            var blocks = GetPrivateField<List<FlowBlock>>(view, "_blocks");
            var before = view.Selection.SelectedText(blocks);
            Assert.Equal(tempFile, before);

            // A Ctrl-click anywhere in the view while a selection exists opens that selection's
            // text (batch 5's own disclosed simplification — no drag/no-drag distinction for this
            // gesture) rather than starting a fresh selection.
            window.MouseDown(new global::Avalonia.Point(50, 5), MouseButton.Left, RawInputModifiers.Control);
            window.MouseUp(new global::Avalonia.Point(50, 5), MouseButton.Left, RawInputModifiers.Control);

            Assert.Single(launcher.Opened);
            Assert.Equal(tempFile, launcher.Opened[0]);
            Assert.Equal(before, view.Selection.SelectedText(blocks)); // untouched
        }
        finally
        {
            File.Delete(tempFile);
        }
    }

    private static T GetPrivateField<T>(object obj, string name)
    {
        var field = typeof(FlowDocumentView).GetField(name, System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)
            ?? throw new InvalidOperationException($"FlowDocumentView.{name} not found — has it been renamed?");
        return (T)field.GetValue(obj)!;
    }

    [Fact]
    public void LeftGutterClick_copies_the_whole_line_at_that_y_without_starting_a_selection()
    {
        var view = new FlowDocumentView();
        view.SetTree(TwoParagraphTree("first line text", "second line text"));
        var window = new global::Avalonia.Controls.Window { Width = 400, Height = 200, Content = view };
        window.Show();
        window.CaptureRenderedFrame();

        Assert.True(view.Selection.IsEmpty);
        // x = 5 is inside the reserved left margin (LeftMargin = 24px) — a gutter click, not a
        // click on the text column itself.
        window.MouseDown(new global::Avalonia.Point(5, 5), MouseButton.Left);
        window.MouseUp(new global::Avalonia.Point(5, 5), MouseButton.Left);

        // A gutter click must never start a text selection — it copies instead.
        Assert.True(view.Selection.IsEmpty);
    }

    // ---- 4. source-contract checks for pieces this test file's headless input cannot directly
    // observe (clipboard writes go through TopLevel.GetTopLevel(this)?.Clipboard, which the
    // headless platform does not back with an inspectable OS clipboard) ---------------------------

    [Fact]
    public void FlowDocumentView_source_wires_gutter_click_to_CopyLineAtGutterY_before_selection_logic()
    {
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia",
            "Rendering", "FlowDocumentView.cs"));
        Assert.Contains("point.Position.X < LeftMargin", source);
        Assert.Contains("CopyLineAtGutterY(point.Position.Y);", source);
        Assert.Contains("private void CopyLineAtGutterY(double localY)", source);
    }

    [Fact]
    public void FlowDocumentView_source_resolves_ctrl_click_via_SelectionOpenTarget_before_falling_through_to_Begin()
    {
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia",
            "Rendering", "FlowDocumentView.cs"));
        Assert.Contains("SelectionOpenTarget.Resolve(_selection.SelectedText(_blocks))", source);
        Assert.Contains("ExternalLinkLauncher.Open(target);", source);
    }

    [Fact]
    public void RebuildContextMenu_wires_Open_to_NavigateLink_and_SelectAll_to_SelectAllText()
    {
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia",
            "Rendering", "FlowDocumentView.cs"));
        Assert.Contains("if (model.IsOpen)", source);
        Assert.Contains("if (link is not null) { NavigateLink(link); }", source);
        Assert.Contains("else if (model.IsSelectAll)", source);
        Assert.Contains("menuItem.Click += (_, _) => SelectAllText();", source);
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
