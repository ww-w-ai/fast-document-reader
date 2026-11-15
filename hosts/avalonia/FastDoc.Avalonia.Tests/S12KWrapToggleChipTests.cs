using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Input;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>S12-K item 47 (gap.md — a Wrap toggle chip next to item 46's Copy chip): flips this
/// DOCUMENT's whole code-wrap intent (per-block toggling is explicitly out of scope, per pl-plan.md
/// "S12-K 분담"'s own "문서 단위 토글이면 충분" ruling) by rebuilding <c>_blocks</c> from the SAME
/// parsed tree via <c>FlowDocumentBuilder.Build(tree, wrapCodeBlocks)</c> — impl-pagination's own
/// API, which changes ONLY where a TextLayout is allowed to insert a break, never the block's own
/// text (its own doc: substituting NBSP for a code block's real spaces once corrupted the Copy
/// chip's clipboard output, plain-selection copy, find, and `--extract`).
///
/// NoWrap's own horizontal-overflow question (a document-uninvited long code line no longer gets
/// wrapped): this reader draws it un-clipped past the reading column, into whatever space the
/// view's own outer bounds still have — no per-block horizontal scroll was added. A real per-block
/// horizontal scroll would need its own scroll axis, its own input routing distinguishing a
/// horizontal code-block drag from the view's single vertical scroll, and a new clip region — a
/// scope well beyond a "minor tail parity" chip, and this reader has exactly one scroll axis today
/// (INVARIANTS.md's own flow-mode contract). The disclosed limitation: a line wider than the
/// window's own outer edge still clips there (`ClipToBounds = true` on the whole control, pre-dating
/// this change and unrelated to it) — the reachable ceiling is "as wide as the window", not
/// "however wide the source line is".</summary>
public class S12KWrapToggleChipTests
{
    public S12KWrapToggleChipTests() => AvaloniaHeadlessSetup.EnsureReady();

    /// <summary>One long source line, no embedded "\n" — far wider than any reasonable reading
    /// column, so Wrap vs NoWrap produces a measurably different line count/height.</summary>
    private static string LongSingleLine() => string.Join(' ', Enumerable.Repeat("verylongtoken", 60));

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

    private static T GetPrivateField<T>(object obj, string name)
    {
        var field = typeof(FlowDocumentView).GetField(name, BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new InvalidOperationException($"FlowDocumentView.{name} not found — has it been renamed?");
        return (T)field.GetValue(obj)!;
    }

    private static Rect WrapChipRect(FlowDocumentView view, int blockIndex)
    {
        var method = typeof(FlowDocumentView).GetMethod("CodeBlockWrapChipRect", BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new InvalidOperationException("FlowDocumentView.CodeBlockWrapChipRect not found — has it been renamed?");
        return (Rect)method.Invoke(view, new object[] { blockIndex })!;
    }

    /// <summary>Pins the ROOT WIRING: `BuildTextLayout`'s new `block.IsCodeBlock && !block.WrapCode`
    /// check must actually reach `TextWrapping.NoWrap` for a real code block, and the round trip
    /// back to Wrap must measure the same as the original — if the flag were ever ignored (always
    /// Wrap) or inverted, the "shorter after toggle" or "same after toggling twice" assertion
    /// fails.</summary>
    [Fact]
    public void ToggleCodeWrap_shrinks_a_long_wrapped_code_line_to_one_line_and_back()
    {
        var view = new FlowDocumentView();
        view.SetTree(ParagraphThenCodeBlockTree("intro", LongSingleLine()));
        var window = new Window { Width = 300, Height = 200, Content = view }; // narrow -> the long line actually wraps
        window.Show();
        window.CaptureRenderedFrame();

        var wrappedHeight = GetPrivateField<double[]>(view, "_blockHeights")[1];

        view.ToggleCodeWrap();
        window.CaptureRenderedFrame();
        var unwrappedHeight = GetPrivateField<double[]>(view, "_blockHeights")[1];

        Assert.True(unwrappedHeight < wrappedHeight,
            $"expected NoWrap ({unwrappedHeight:F1}) to measure shorter than Wrap ({wrappedHeight:F1}) for the same long single line");

        view.ToggleCodeWrap();
        window.CaptureRenderedFrame();
        var rewrappedHeight = GetPrivateField<double[]>(view, "_blockHeights")[1];
        Assert.Equal(wrappedHeight, rewrappedHeight, 1);
    }

    /// <summary>Locks in the NBSP-substitution regression this flag replaced (pl-plan.md's own
    /// REVISE note): toggling wrap must never change what <see cref="SelectionModel.PlainText"/>
    /// reads back for the block — Copy chip output, plain selection copy, find, and `--extract`
    /// all read through that same helper.</summary>
    [Fact]
    public void ToggleCodeWrap_never_changes_the_blocks_own_text()
    {
        var view = new FlowDocumentView();
        var code = LongSingleLine();
        view.SetTree(ParagraphThenCodeBlockTree("intro", code));
        var window = new Window { Width = 300, Height = 200, Content = view };
        window.Show();
        window.CaptureRenderedFrame();

        var before = SelectionModel.PlainText(GetPrivateField<List<FlowBlock>>(view, "_blocks")[1]);
        view.ToggleCodeWrap();
        var after = SelectionModel.PlainText(GetPrivateField<List<FlowBlock>>(view, "_blocks")[1]);

        Assert.Equal(code, before);
        Assert.Equal(before, after);
    }

    /// <summary>ToggleCodeWrap deliberately does NOT call SetTree (which resets `_scrollOffset` to
    /// 0) — this is the regression a lead mutation routing the toggle through SetTree instead of a
    /// narrow rebuild would produce: the reader loses its place every time it toggles wrap.</summary>
    [Fact]
    public void ToggleCodeWrap_does_not_reset_scroll_to_the_top_like_SetTree_would()
    {
        var view = new FlowDocumentView();
        view.SetTree(ParagraphThenCodeBlockTree("intro", LongSingleLine()));
        var window = new Window { Width = 300, Height = 80, Content = view }; // small viewport -> real scroll room
        window.Show();
        window.CaptureRenderedFrame();

        var maxScroll = Math.Max(0, view.ContentHeight - view.Bounds.Height);
        Assert.True(maxScroll > 10, "fixture must produce real scroll room for this test to mean anything");
        view.ScrollOffset = maxScroll / 2;
        Assert.True(view.ScrollOffset > 0);

        view.ToggleCodeWrap();

        Assert.True(view.ScrollOffset > 0, "ToggleCodeWrap must not reset scroll to zero the way SetTree does");
    }

    /// <summary>End-to-end through the real pointer pipeline: the SAME chip rect
    /// <c>DrawCodeBlockChips</c> paints must be what <c>OnPointerPressed</c> hit-tests, and clicking
    /// it must not fall through to ordinary text selection (mirrors the Copy chip's own test in
    /// S12KCodeBlockCopyChipTests).</summary>
    [Fact]
    public void Clicking_the_wrap_chip_toggles_via_the_real_pointer_pipeline_without_starting_a_selection()
    {
        var view = new FlowDocumentView();
        view.SetTree(ParagraphThenCodeBlockTree("intro", LongSingleLine()));
        var window = new Window { Width = 300, Height = 200, Content = view };
        window.Show();
        window.CaptureRenderedFrame();
        var before = GetPrivateField<bool>(view, "_wrapCodeBlocks");

        var chip = WrapChipRect(view, 1);
        var chipCenter = new Point(chip.X + chip.Width / 2, chip.Y + chip.Height / 2);
        window.MouseDown(chipCenter, MouseButton.Left);
        Assert.False(GetPrivateField<bool>(view, "_isSelecting"));
        window.MouseUp(chipCenter, MouseButton.Left);

        var after = GetPrivateField<bool>(view, "_wrapCodeBlocks");
        Assert.NotEqual(before, after);
    }

    /// <summary>The Wrap chip and the Copy chip must occupy DIFFERENT rects — otherwise one click
    /// could never distinguish "copy" from "toggle wrap".</summary>
    [Fact]
    public void The_wrap_chip_and_the_copy_chip_never_overlap()
    {
        var view = new FlowDocumentView();
        view.SetTree(ParagraphThenCodeBlockTree("intro", LongSingleLine()));
        var window = new Window { Width = 300, Height = 200, Content = view };
        window.Show();
        window.CaptureRenderedFrame();

        var copyRect = (Rect)typeof(FlowDocumentView)
            .GetMethod("CodeBlockChipRect", BindingFlags.NonPublic | BindingFlags.Instance)!
            .Invoke(view, new object[] { 1 })!;
        var wrapRect = WrapChipRect(view, 1);

        Assert.False(copyRect.Intersects(wrapRect), $"copy {copyRect} and wrap {wrapRect} chip rects must not overlap");
    }
}
