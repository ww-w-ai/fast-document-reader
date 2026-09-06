using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using global::Avalonia;
using global::Avalonia.Headless;
using global::Avalonia.Media;
using global::Avalonia.Media.Imaging;
using global::Avalonia.Media.TextFormatting;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Paging;
using FastDoc.Avalonia.Printing;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S9-B3 batch 2 (docs/studio/sprints/S9/s9b1-full-parity.md #21/#22): the View menu's
/// Master Page Furniture / Split Tables Across Pages toggles, mirroring
/// App/PageViewOptions.swift's masterPage/splitTables fields (macOS). This host has no 바탕쪽
/// background-artwork decode (see FlowDocumentView's own doc on <c>_masterPageFurniture</c>), so
/// "furniture" here is the running header/footer band PageBandResolver already reserves —
/// asserted below with branch-entry evidence at the PageModePainter level (a real header/footer is
/// drawn with the toggle on, and NOT drawn with it off), not merely "no exception". FlowDocumentView
/// itself is exercised through its public properties/HasPageGeometry only, since RenderCore is
/// internal and this test project carries no InternalsVisibleTo grant.
/// </summary>
public class S9B3Batch2Tests
{
    public S9B3Batch2Tests() => AvaloniaHeadlessSetup.EnsureReady();

    private sealed class RecordingCanvas : IPageCanvas
    {
        public int TextLayoutCount;
        public void DrawRect(Rect rect, Color? fill, Color? stroke, double strokeThicknessPx) { }
        public void DrawLine(Point a, Point b, Color color, double thicknessPx) { }
        public void DrawImage(Bitmap bitmap, byte[]? sourceBytes, string? sourceMimeType, Rect destRect) { }
        public void DrawTextLayout(TextLayout layout, Point origin) => TextLayoutCount++;
        public void DrawTextLine(TextLine line, Point origin) { }
    }

    /// <summary>A one-page document with a real header AND footer node, plus one body paragraph —
    /// small enough to hand-author, big enough that PageModePainter has real band text to draw.</summary>
    private static RenderTree TreeWithHeaderFooter()
    {
        const string json = """
        {
          "schemaVersion": 1,
          "document": {
            "format": "docx",
            "rootNodeId": 0,
            "defaultBodyFontSize": 12,
            "documentPaper": {
              "widthPoints": 300,
              "heightPoints": 400,
              "margins": { "top": 40, "right": 20, "bottom": 40, "left": 20 }
            }
          },
          "nodes": [
            { "id": 0, "parentId": null, "children": [1, 2, 3], "type": "document", "data": {} },
            { "id": 1, "parentId": 0, "children": [10], "type": "header", "data": { "appliesTo": "defaultPages" } },
            { "id": 10, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "Running Header", "style": {} } },
            { "id": 2, "parentId": 0, "children": [11], "type": "footer", "data": { "appliesTo": "defaultPages" } },
            { "id": 11, "parentId": 2, "children": [], "type": "textRun", "data": { "text": "Running Footer", "style": {} } },
            { "id": 3, "parentId": 0, "children": [12], "type": "paragraph", "data": { "style": {} } },
            { "id": 12, "parentId": 3, "children": [], "type": "textRun", "data": { "text": "body text", "style": {} } }
          ]
        }
        """;
        return JsonSerializer.Deserialize<RenderTree>(json)!;
    }

    private static (System.Collections.Generic.List<FlowBlock> Blocks, PageGeometry Geometry,
        BlockPageMarkers.Markers Markers, PageLayoutResult Layout) BuildLayout(RenderTree tree, bool furniture)
    {
        var blocks = FlowDocumentBuilder.Build(tree);
        var geometry = PageGeometry.FromDocument(tree)!;
        var markers = BlockPageMarkers.Compute(tree);
        var (layout, _, _, _) = PageLayout.BuildWithTableSettle(blocks, markers, geometry,
            IntPtr.Zero, headersOn: furniture, footersOn: furniture, splitTablesDefault: true);
        return (blocks, geometry, markers, layout);
    }

    // ---- 1. PageModePainter actually gates header/footer drawing on the new parameter ------------

    [Fact]
    public void PageModePainter_draws_header_and_footer_text_when_furniture_is_on()
    {
        var tree = TreeWithHeaderFooter();
        var (blocks, geometry, markers, layout) = BuildLayout(tree, furniture: true);
        var painter = new PageModePainter(new ImageBlockRenderer());
        var canvas = new RecordingCanvas();

        painter.Draw(canvas, blocks, tree, layout, geometry, 1.0, 500, 500, 0, markers, masterPageFurniture: true);

        Assert.True(canvas.TextLayoutCount > 0, "expected header/footer band text to draw with furniture ON");
    }

    [Fact]
    public void PageModePainter_draws_no_header_or_footer_text_when_furniture_is_off()
    {
        var tree = TreeWithHeaderFooter();
        var (blocks, geometry, markers, layout) = BuildLayout(tree, furniture: false);
        var painter = new PageModePainter(new ImageBlockRenderer());
        var canvas = new RecordingCanvas();

        painter.Draw(canvas, blocks, tree, layout, geometry, 1.0, 500, 500, 0, markers, masterPageFurniture: false);

        Assert.Equal(0, canvas.TextLayoutCount);
    }

    [Fact]
    public void PageModePainter_Draw_defaults_masterPageFurniture_to_true_for_older_call_sites()
    {
        var tree = TreeWithHeaderFooter();
        var (blocks, geometry, markers, layout) = BuildLayout(tree, furniture: true);
        var painter = new PageModePainter(new ImageBlockRenderer());
        var canvas = new RecordingCanvas();

        // No masterPageFurniture argument at all — exercises the optional parameter's default.
        painter.Draw(canvas, blocks, tree, layout, geometry, 1.0, 500, 500, 0, markers);

        Assert.True(canvas.TextLayoutCount > 0);
    }

    // ---- 2. FlowDocumentView's public surface: defaults, setters, and the source-level wiring
    // that actually reaches PageLayout.BuildWithTableSettle / PageModePainter.Draw (RenderCore/
    // EnsurePageLayout are internal/private with no InternalsVisibleTo grant to this project, so
    // the source-contract check below is this project's only way to pin that the LIVE field —
    // not a hardcoded constant — reaches those calls; #1 above proves the painter honours the
    // value once it arrives). ------------------------------------------------------------------

    [Fact]
    public void FlowDocumentView_MasterPageFurniture_and_SplitTables_default_true_and_are_settable()
    {
        var view = new FlowDocumentView();
        Assert.True(view.MasterPageFurniture);
        Assert.True(view.SplitTablesAcrossPages);

        view.MasterPageFurniture = false;
        Assert.False(view.MasterPageFurniture);
        view.MasterPageFurniture = true;
        Assert.True(view.MasterPageFurniture);

        view.SplitTablesAcrossPages = false;
        Assert.False(view.SplitTablesAcrossPages);
        view.SplitTablesAcrossPages = true;
        Assert.True(view.SplitTablesAcrossPages);
    }

    [Fact]
    public void FlowDocumentView_MasterPageFurniture_setter_is_a_noop_when_value_unchanged()
    {
        var view = new FlowDocumentView();
        view.SetTree(TreeWithHeaderFooter());
        Assert.True(view.HasPageGeometry);
        Assert.True(view.MasterPageFurniture);
        view.MasterPageFurniture = true; // already true — must not throw
        Assert.True(view.MasterPageFurniture);
    }

    [Fact]
    public void EnsurePageLayout_source_passes_the_live_fields_not_a_hardcoded_constant()
    {
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia",
            "Rendering", "FlowDocumentView.cs"));
        Assert.Contains("splitTablesDefault: _splitTablesAcrossPages", source);
        Assert.Contains("headersOn: _masterPageFurniture, footersOn: _masterPageFurniture", source);
        Assert.DoesNotContain("splitTablesDefault: true);", source);
        Assert.Contains("_pageModePainter.Draw(surface, _blocks, _tree!, _pageLayout!, _pageGeometry!, _zoomFactor,\n                    width, Math.Max(0, Bounds.Height), _scrollOffset, _pageMarkers, _masterPageFurniture);",
            source);
    }

    // ---- 3. menu wiring (source contract — see other S9B* test files for why this pattern is used
    // for MainWindow.axaml/.axaml.cs: constructing a real MainWindow needs Program.PendingDocumentPath
    // / StorageProvider plumbing this test project does not set up) --------------------------------

    [Fact]
    public void MainWindow_axaml_declares_both_toggles_with_distinct_shortcuts_and_default_checked()
    {
        var repoRoot = FindRepoRoot();
        var axaml = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia", "MainWindow.axaml"));

        Assert.Contains("MasterPageFurnitureMenuItem", axaml);
        Assert.Contains("InputGesture=\"Ctrl+Shift+M\"", axaml);
        Assert.Contains("SplitTablesMenuItem", axaml);
        Assert.Contains("InputGesture=\"Ctrl+Shift+B\"", axaml);
        Assert.Contains("OnMasterPageFurnitureToggleClicked", axaml);
        Assert.Contains("OnSplitTablesToggleClicked", axaml);
    }

    [Fact]
    public void MainWindow_cs_wires_both_click_handlers_to_the_Canvas_properties_and_enables_with_page_geometry()
    {
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia", "MainWindow.axaml.cs"));

        Assert.Contains("Canvas.MasterPageFurniture = !Canvas.MasterPageFurniture;", source);
        Assert.Contains("Canvas.SplitTablesAcrossPages = !Canvas.SplitTablesAcrossPages;", source);
        Assert.Contains("MasterPageFurnitureMenuItem.IsEnabled = Canvas.HasPageGeometry;", source);
        Assert.Contains("SplitTablesMenuItem.IsEnabled = Canvas.HasPageGeometry;", source);
    }

    [Fact]
    public void ShortcutGuideModel_lists_both_new_shortcuts_and_they_are_in_MenuGestureKeys()
    {
        var groups = Panels.ShortcutGuideModel.Build();
        var view = groups.Single(g => g.Title == "View");
        Assert.Contains(view.Entries, e => e.Keys == "Ctrl+Shift+M");
        Assert.Contains(view.Entries, e => e.Keys == "Ctrl+Shift+B");
        Assert.Contains("Ctrl+Shift+M", Panels.ShortcutGuideModel.MenuGestureKeys);
        Assert.Contains("Ctrl+Shift+B", Panels.ShortcutGuideModel.MenuGestureKeys);
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
