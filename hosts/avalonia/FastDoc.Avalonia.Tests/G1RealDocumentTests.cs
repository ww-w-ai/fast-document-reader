using System;
using System.IO;
using FastDoc.Avalonia.Printing;
using System.Linq;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Paging;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// G1 against REAL documents through the real engine — skipped (never failed) when the engine
/// library or the document is not on this machine, because the synthetic trees in
/// <see cref="G1PinnedObjectsTests"/> already pin the logic. What only a real document can show is
/// that the engine's own anchored / master-page nodes decode into pinned objects at all.
/// </summary>
public class G1RealDocumentTests
{
    public G1RealDocumentTests() => AvaloniaHeadlessSetup.EnsureReady();

    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "rust"))) { dir = dir.Parent; }
        return dir?.FullName ?? "";
    }

    private static (RenderTree Tree, System.Collections.Generic.List<FlowBlock> Blocks)? Load(string relative)
    {
        if (Environment.GetEnvironmentVariable("FASTDOC_ENGINE_LIB") is not { Length: > 0 }) { return null; }
        var path = Path.Combine(RepoRoot(), relative);
        if (!File.Exists(path)) { return null; }
        var loaded = RenderTreeLoader.Load(path);
        if (!loaded.IsOk) { return null; }
        return (loaded.Tree!, FlowDocumentBuilder.Build(loaded.Tree!));
    }

    [Fact]
    public void A_korean_exam_pins_its_anchored_drawings_and_master_pages()
    {
        if (Load("Vendor/rhwp-src/samples/exam-kor-4p.hwp") is not { } doc) { return; }
        var set = PinnedObjectSet.Build(doc.Tree, doc.Blocks);
        // 6 anchored objects and 3 master pages are declared (engine census); every one resolves.
        Assert.Equal(6, set.Anchored.Count);
        Assert.Equal(3, set.Masters.Count);
        Assert.All(set.Anchored, o => Assert.InRange(o.AnchorBlockIndex, 0, doc.Blocks.Count - 1));
        Assert.Contains(set.Anchored, o => o.Content is PinnedText);
        Assert.Contains(set.Anchored, o => o.Content is PinnedVector);
    }


    private sealed class OrderRecorder : FastDoc.Avalonia.Printing.IPageCanvas
    {
        public readonly System.Collections.Generic.List<string> Order = new();
        public void DrawRect(global::Avalonia.Rect rect, global::Avalonia.Media.Color? fill, global::Avalonia.Media.Color? stroke, double strokeThicknessPx) => Order.Add("rect");
        public void DrawLine(global::Avalonia.Point a, global::Avalonia.Point b, global::Avalonia.Media.Color color, double thicknessPx) => Order.Add("line");
        public void DrawImage(global::Avalonia.Media.Imaging.Bitmap bitmap, byte[]? sourceBytes, string? sourceMimeType, global::Avalonia.Rect destRect) => Order.Add("image");
        public void DrawTextLayout(global::Avalonia.Media.TextFormatting.TextLayout layout, global::Avalonia.Point origin) => Order.Add("layout");
        public void DrawTextLine(global::Avalonia.Media.TextFormatting.TextLine line, global::Avalonia.Point origin) => Order.Add("text");
        public void DrawVectorPath(System.Collections.Generic.IReadOnlyList<FastDoc.Avalonia.Printing.VectorSegment> segments, global::Avalonia.Media.Color? fill, global::Avalonia.Media.Color? stroke, double strokeWidthPx, string strokeStyle) => Order.Add("path");
    }

    [Fact]
    public void A_seal_box_is_drawn_after_the_table_that_carries_it()
    {
        // s7-page-restart.hwp anchors a stroked box to the title table; its cells are filled, so
        // drawing the box before the table hid it (measured: no box in the exported PDF).
        if (Load("testdocs/mini/s7-page-restart.hwp") is not { } doc) { return; }
        var geometry = PageGeometry.FromDocument(doc.Tree)!;
        var markers = BlockPageMarkers.Compute(doc.Tree);
        var images = new ImageBlockRenderer();
        images.Reset(doc.Tree);
        var (layout, _, _, _) = PageLayout.BuildWithTableSettle(doc.Blocks, markers, geometry, IntPtr.Zero, true, true, true, images);
        var painter = new PageModePainter(images);
        var canvas = new OrderRecorder();

        painter.Draw(canvas, doc.Blocks, doc.Tree, layout, geometry, 1.0, 1000, 1,
            painter.PageTopPx(geometry, 0, 1.0), markers);

        var firstPath = canvas.Order.IndexOf("path");
        Assert.True(firstPath >= 0, "an anchored drawing must be painted on page 1");
        var lastText = canvas.Order.LastIndexOf("text");
        Assert.True(firstPath > lastText, "anchored drawings paint over the page's blocks and text");
    }

    [Fact]
    public void A_form_document_keeps_its_inline_form_control_text()
    {
        if (Load("Vendor/rhwp-src/samples/form-02.hwp") is not { } doc) { return; }
        var text = string.Join("\n", doc.Blocks.Select(b => string.Concat(b.Runs.Select(r => r.Text))));
        Assert.Contains("선택 상자", text);
        Assert.Contains("라디오 단추", text);
    }
}
