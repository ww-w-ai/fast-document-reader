using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using global::Avalonia.Headless;
using global::Avalonia.Input;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Panels;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S9-B3 batch 6 (docs/studio/sprints/S9/s9b1-full-parity.md #45/#46): click on an image/diagram
/// opens an enlarged view (FlowDocumentView.ImageClicked), and a right-click on a code block adds a
/// "Copy Code" context-menu item. "Wrap" (macOS's other code-block chip) is deliberately NOT
/// implemented — see ContextMenuModel.Build's own doc: it would require editing
/// FlowDocumentView.DrawTextBlock/BuildTextLayout's TextWrapping construction, which belongs to
/// that file's table/measure/draw code and is left alone here, and drag-to-pan/pinch inside the
/// enlarged view are narrowed to a ScrollViewer + keyboard
/// zoom only — see ImageZoomWindow's own doc.
/// </summary>
public class S9B3Batch6Tests
{
    public S9B3Batch6Tests() => AvaloniaHeadlessSetup.EnsureReady();

    private static RenderTree ImageAndCodeTree()
    {
        const string json = """
        {
          "schemaVersion": 1,
          "document": { "rootNodeId": 0, "defaultBodyFontSize": 12.0 },
          "nodes": [
            { "id": 0, "parentId": null, "type": "document", "children": [1, 2], "data": {} },
            { "id": 1, "parentId": 0, "type": "image", "children": [],
              "data": { "resourceId": 1, "intrinsicSize": { "width": 40, "height": 30 } } },
            { "id": 2, "parentId": 0, "type": "codeBlock", "children": [],
              "data": { "text": "let x = 1;", "language": "js" } }
          ]
        }
        """;
        return JsonSerializer.Deserialize<RenderTree>(json)!;
    }

    // ---- 1. ImageClicked fires with the resource id, only for a real (non-placeholder) image ----

    [Fact]
    public void Click_on_an_image_block_fires_ImageClicked_with_its_resource_id()
    {
        var view = new FlowDocumentView();
        view.SetTree(ImageAndCodeTree());
        var window = new global::Avalonia.Controls.Window { Width = 400, Height = 400, Content = view };
        window.Show();
        window.CaptureRenderedFrame();

        ulong? fired = null;
        view.ImageClicked += id => fired = id;

        // The image is the FIRST block, so it sits at the very top of the flow — well within the
        // text column (x > LeftMargin) and near the top (y small).
        window.MouseDown(new global::Avalonia.Point(60, 5), MouseButton.Left);
        window.MouseUp(new global::Avalonia.Point(60, 5), MouseButton.Left);

        Assert.Equal(1uL, fired);
    }

    [Fact]
    public void Click_in_the_left_gutter_never_fires_ImageClicked_even_at_an_images_y()
    {
        // #44 (gutter click) and #45 (image click) must not both fire for the same click — the
        // gutter check runs FIRST in OnPointerPressed, per that method's own ordering.
        var view = new FlowDocumentView();
        view.SetTree(ImageAndCodeTree());
        var window = new global::Avalonia.Controls.Window { Width = 400, Height = 400, Content = view };
        window.Show();
        window.CaptureRenderedFrame();

        var fired = false;
        view.ImageClicked += _ => fired = true;

        window.MouseDown(new global::Avalonia.Point(5, 5), MouseButton.Left); // x=5 < LeftMargin=24
        window.MouseUp(new global::Avalonia.Point(5, 5), MouseButton.Left);

        Assert.False(fired);
    }

    [Fact]
    public void ResolveImageBitmap_returns_null_for_an_undecoded_resource_id()
    {
        var view = new FlowDocumentView();
        view.SetTree(ImageAndCodeTree());
        // No bytes were ever supplied for resource id 1 (a bare reference in this fixture), so it
        // never decodes — ImageZoomWindow's own MainWindow.OnCanvasImageClicked no-ops on null.
        Assert.Null(view.ResolveImageBitmap(1));
    }

    // ---- 2. ContextMenuModel's "Copy Code" item -----------------------------------------------

    [Fact]
    public void Build_adds_Copy_Code_only_when_onCodeBlock_is_true()
    {
        var withoutCode = ContextMenuModel.Build(hasSelection: false, onLink: false, onCodeBlock: false);
        Assert.DoesNotContain(withoutCode, i => i.Header == "Copy Code");

        var withCode = ContextMenuModel.Build(hasSelection: false, onLink: false, onCodeBlock: true);
        var copyCode = Assert.Single(withCode, i => i.Header == "Copy Code");
        Assert.True(copyCode.Enabled);
        Assert.True(copyCode.IsCopyCode);
    }

    // ---- 3. AboutModel-style source contract for the parts headless clipboard access cannot
    // observe (RebuildContextMenu's Click handlers write through TopLevel.Clipboard, same
    // limitation S9B3Batch5Tests documents) ------------------------------------------------------

    [Fact]
    public void FlowDocumentView_source_captures_the_code_block_at_right_click_press_time()
    {
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia",
            "Rendering", "FlowDocumentView.cs"));
        Assert.Contains("_lastRightClickCodeBlockText = CodeBlockTextAt(point.Position);", source);
        Assert.Contains("private string? CodeBlockTextAt(Point point)", source);
        Assert.Contains("block.Runs[0].FontFamily != FlowDocumentBuilder.CodeFontFamily", source);
    }

    [Fact]
    public void RebuildContextMenu_wires_Copy_Code_to_the_captured_block_text()
    {
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia",
            "Rendering", "FlowDocumentView.cs"));
        Assert.Contains("else if (model.IsCopyCode)", source);
        Assert.Contains("if (codeBlockText is not null) { _ = CopyTextToClipboard(codeBlockText); }", source);
    }

    [Fact]
    public void MainWindow_cs_subscribes_to_ImageClicked_and_opens_ImageZoomWindow_only_for_a_decoded_bitmap()
    {
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia", "MainWindow.axaml.cs"));
        Assert.Contains("Canvas.ImageClicked += OnCanvasImageClicked;", source);
        Assert.Contains("var bitmap = Canvas.ResolveImageBitmap(resourceId);", source);
        Assert.Contains("if (bitmap is null) { return; }", source);
    }

    [Fact]
    public void ImageZoomWindow_has_a_parameterless_constructor_and_a_separate_Configure_method()
    {
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia",
            "Panels", "ImageZoomWindow.axaml.cs"));
        Assert.Contains("public ImageZoomWindow()", source);
        Assert.Contains("public void Configure(Bitmap bitmap)", source);
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
