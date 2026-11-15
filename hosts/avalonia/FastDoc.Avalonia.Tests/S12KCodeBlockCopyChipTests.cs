using System;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Input;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>S12-K item 46 (gap.md — code-block Copy affordance as a persistent visible chip, not
/// only the pre-existing right-click "Copy Code" menu item, S9-B3 batch 6). Reuses
/// impl-pagination's <see cref="FlowBlock.IsCodeBlock"/> flag for classification (never re-derives
/// it from font family the way the older <c>CodeBlockTextAt</c> hit-test did) and the SAME
/// clipboard path the existing "Copy Code" context-menu item already calls
/// (<c>CopyTextToClipboard(SelectionModel.PlainText(block))</c>) — no second copy mechanism.
///
/// The actual clipboard write is not asserted end-to-end here, for the SAME documented reason
/// <c>S9B3Batch5Tests</c> already gives for its own clipboard-writing pieces: it goes through
/// <c>TopLevel.GetTopLevel(this)?.Clipboard</c>, fired-and-forgotten from a synchronous pointer
/// handler, with no seam this project makes injectable. What IS asserted end-to-end, through the
/// real pointer pipeline: (1) hovering a real code block shows the chip and hovering plain text
/// does not, (2) clicking the chip's rect takes the EARLY-RETURN branch (proven by `_isSelecting`
/// never becoming true) instead of falling through to ordinary text selection, and (3) clicking the
/// SAME code block OUTSIDE the chip's rect still starts an ordinary selection — proving the chip's
/// hit-test is scoped to its own small rect, not the whole block. A source-contract check closes
/// the remaining gap (which clipboard call the chip's branch makes).</summary>
public class S12KCodeBlockCopyChipTests
{
    public S12KCodeBlockCopyChipTests() => AvaloniaHeadlessSetup.EnsureReady();

    private static RenderTree ParagraphThenCodeBlockTree(string paragraph, string codeText)
    {
        var json = $$"""
        {
          "schemaVersion": 1,
          "document": { "rootNodeId": 0, "defaultBodyFontSize": 12.0 },
          "nodes": [
            { "id": 0, "parentId": null, "type": "document", "children": [1, 3], "data": {} },
            { "id": 1, "parentId": 0, "type": "paragraph", "children": [2], "data": { "style": {} } },
            { "id": 2, "parentId": 1, "type": "textRun", "children": [], "data": { "text": {{JsonSerializer.Serialize(paragraph)}}, "style": {} } },
            { "id": 3, "parentId": 0, "type": "codeBlock", "children": [],
              "data": { "language": "c", "text": {{JsonSerializer.Serialize(codeText)}} } }
          ]
        }
        """;
        return JsonSerializer.Deserialize<RenderTree>(json)!;
    }

    private static RenderTree SingleCodeBlockTree(string codeText)
    {
        var json = $$"""
        {
          "schemaVersion": 1,
          "document": { "rootNodeId": 0, "defaultBodyFontSize": 12.0 },
          "nodes": [
            { "id": 0, "parentId": null, "type": "document", "children": [1], "data": {} },
            { "id": 1, "parentId": 0, "type": "codeBlock", "children": [],
              "data": { "language": "c", "text": {{JsonSerializer.Serialize(codeText)}} } }
          ]
        }
        """;
        return JsonSerializer.Deserialize<RenderTree>(json)!;
    }

    private static string ThreeLineCode()
    {
        var sb = new StringBuilder();
        sb.Append("int a = 1;\nint b = 2;\nint c = a + b;");
        return sb.ToString();
    }

    private static T GetPrivateField<T>(object obj, string name)
    {
        var field = typeof(FlowDocumentView).GetField(name, BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new InvalidOperationException($"FlowDocumentView.{name} not found — has it been renamed?");
        return (T)field.GetValue(obj)!;
    }

    private static Rect ChipRect(FlowDocumentView view, int blockIndex)
    {
        var method = typeof(FlowDocumentView).GetMethod("CodeBlockChipRect", BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new InvalidOperationException("FlowDocumentView.CodeBlockChipRect not found — has it been renamed?");
        return (Rect)method.Invoke(view, new object[] { blockIndex })!;
    }

    [Fact]
    public void Hovering_a_real_code_block_shows_the_chip_and_hovering_plain_text_does_not()
    {
        var view = new FlowDocumentView();
        view.SetTree(ParagraphThenCodeBlockTree("an ordinary paragraph of prose", ThreeLineCode()));
        var window = new Window { Width = 500, Height = 400, Content = view };
        window.Show();
        window.CaptureRenderedFrame();

        var offsets = GetPrivateField<double[]>(view, "_offsets");
        var heights = GetPrivateField<double[]>(view, "_blockHeights");
        var paragraphMidY = offsets[0] + heights[0] / 2;
        var codeBlockMidY = offsets[1] + heights[1] / 2;

        window.MouseMove(new Point(60, paragraphMidY));
        Assert.Null(GetPrivateField<int?>(view, "_hoverCodeBlockIndex"));

        window.MouseMove(new Point(60, codeBlockMidY));
        Assert.Equal(1, GetPrivateField<int?>(view, "_hoverCodeBlockIndex"));
    }

    /// <summary>Pins the ROOT WIRING (not clipboard content — see this file's own top-level doc):
    /// if `CodeBlockIndexAt`/`CodeBlockChipRect`'s check in `OnPointerPressed` were ever removed, a
    /// click inside the chip's own rect would fall through to the ordinary text-selection press
    /// logic below it — which sets `_isSelecting = true`. Observing `_isSelecting` stays false
    /// after a chip-rect press is exactly what would go red if that early-return branch regressed.</summary>
    [Fact]
    public void Clicking_inside_the_chips_own_rect_never_starts_a_text_selection()
    {
        var view = new FlowDocumentView();
        view.SetTree(SingleCodeBlockTree(ThreeLineCode()));
        var window = new Window { Width = 500, Height = 400, Content = view };
        window.Show();
        window.CaptureRenderedFrame();

        var chip = ChipRect(view, 0);
        var chipCenter = new Point(chip.X + chip.Width / 2, chip.Y + chip.Height / 2);

        window.MouseDown(chipCenter, MouseButton.Left);
        Assert.False(GetPrivateField<bool>(view, "_isSelecting"));
        window.MouseUp(chipCenter, MouseButton.Left);
        Assert.True(view.Selection.IsEmpty);
    }

    /// <summary>The negative case the previous test's own doc calls out: the SAME code block,
    /// clicked OUTSIDE the chip's small rect, must still behave exactly as before this feature
    /// existed — an ordinary selection starts. Proves the new hit-test in `OnPointerPressed` is
    /// scoped to the chip's own rect and does not swallow the whole code block.</summary>
    [Fact]
    public void Clicking_the_same_code_block_outside_the_chip_still_starts_an_ordinary_selection()
    {
        var view = new FlowDocumentView();
        view.SetTree(SingleCodeBlockTree(ThreeLineCode()));
        var window = new Window { Width = 500, Height = 400, Content = view };
        window.Show();
        window.CaptureRenderedFrame();

        var chip = ChipRect(view, 0);
        // Top-left corner of the block's own text — well clear of the chip, which sits at the
        // block's top-RIGHT.
        var farFromChip = new Point(30, 3);
        Assert.False(chip.Contains(farFromChip), "test point must land outside the chip's own rect");

        window.MouseDown(farFromChip, MouseButton.Left);
        Assert.True(GetPrivateField<bool>(view, "_isSelecting"));
        window.MouseUp(farFromChip, MouseButton.Left);
    }

    [Fact]
    public void FlowDocumentView_source_routes_the_chip_click_to_the_same_clipboard_path_Copy_Code_already_uses()
    {
        var repoRoot = FindRepoRoot();
        var source = File.ReadAllText(Path.Combine(repoRoot, "hosts", "avalonia", "FastDoc.Avalonia",
            "Rendering", "FlowDocumentView.cs"));
        Assert.Contains("CodeBlockChipRect(codeChipBlockIndex).Contains(point.Position)", source);
        Assert.Contains("_ = CopyTextToClipboard(SelectionModel.PlainText(_blocks[codeChipBlockIndex]));", source);
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
