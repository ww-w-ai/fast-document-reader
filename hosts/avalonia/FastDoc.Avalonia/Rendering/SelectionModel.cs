using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace FastDoc.Avalonia.Rendering;

/// <summary>S8-D2 (D2-a): one caret/selection endpoint in flow mode — a top-level block index plus
/// a UTF-16 offset into that block's OWN plain text (the same string <see
/// cref="SelectionModel.PlainText"/> and <see cref="FlowDocumentView"/>'s BuildTextLayout both
/// derive a block's runs into). Comparable so two positions can be ordered into a
/// (start, end) range regardless of which one the pointer/keyboard produced first.</summary>
public readonly record struct TextPosition(int BlockIndex, int Offset) : IComparable<TextPosition>
{
    public int CompareTo(TextPosition other)
    {
        var blockCompare = BlockIndex.CompareTo(other.BlockIndex);
        return blockCompare != 0 ? blockCompare : Offset.CompareTo(other.Offset);
    }
}

/// <summary>Pure, view-free selection state for flow-mode text — deliberately holds no Avalonia
/// Control/DrawingContext/TextLayout reference so it is testable with plain FlowBlock lists. <see
/// cref="FlowDocumentView"/> owns the ONE instance for a document, feeds it positions produced by
/// hit-testing its own cached <c>TextLayout</c>s (never a second layout — ADR 0002/S8-D2 contract),
/// and reads it back to paint highlights and to answer Ctrl+C.
///
/// A selection is an (anchor, focus) pair — anchor is where the drag/click started, focus is where
/// the pointer/keyboard currently is; <see cref="Normalize"/> is what most callers actually want
/// (the pair in document order, regardless of drag direction).</summary>
public sealed class SelectionModel
{
    public TextPosition? Anchor { get; private set; }
    public TextPosition? Focus { get; private set; }

    /// <summary>True when there is no selection at all (never started, or explicitly cleared) OR
    /// the anchor and focus have collapsed onto the exact same position (a plain click with no
    /// drag) — both read as "nothing to highlight, nothing to copy" to every caller.</summary>
    public bool IsEmpty => Anchor is null || Focus is null || Anchor.Value.Equals(Focus.Value);

    /// <summary>Starts a new selection at <paramref name="position"/> — anchor and focus both land
    /// there, so the very next <see cref="ExtendTo"/> (a drag) grows the range from this point.</summary>
    public void Begin(TextPosition position)
    {
        Anchor = position;
        Focus = position;
    }

    /// <summary>Moves the FOCUS end only, leaving the anchor where <see cref="Begin"/> (or a prior
    /// <see cref="SelectAll"/>) put it — the drag/shift-click case. Starts a selection at
    /// <paramref name="position"/> if none exists yet, so a caller can skip a redundant Begin.</summary>
    public void ExtendTo(TextPosition position)
    {
        Anchor ??= position;
        Focus = position;
    }

    public void Clear()
    {
        Anchor = null;
        Focus = null;
    }

    /// <summary>Selects the whole document: block 0 offset 0 through the LAST block's own full
    /// text length. Only the last block's length is needed — every block in between is included
    /// wholly by <see cref="SelectedText"/> regardless of its own length.</summary>
    public void SelectAll(int blockCount, int lastBlockTextLength)
    {
        if (blockCount <= 0)
        {
            Clear();
            return;
        }
        Anchor = new TextPosition(0, 0);
        Focus = new TextPosition(blockCount - 1, Math.Max(0, lastBlockTextLength));
    }

    /// <summary>Anchor/Focus in document order — (start, end) — regardless of which direction the
    /// drag or Shift-click actually ran. Both are <c>default</c> (block 0, offset 0) when <see
    /// cref="IsEmpty"/> is true; callers must check IsEmpty first, exactly like every other caller
    /// in this file does, rather than trusting a meaningless zero range.</summary>
    public (TextPosition Start, TextPosition End) Normalize()
    {
        if (Anchor is null || Focus is null) { return (default, default); }
        var a = Anchor.Value;
        var f = Focus.Value;
        return a.CompareTo(f) <= 0 ? (a, f) : (f, a);
    }

    /// <summary>The portion of ONE block's own plain text this selection covers, clipped to
    /// [0, blockTextLength] — used by <see cref="FlowDocumentView"/>'s highlight painter, which
    /// already knows the block's rendered text length from its own TextLayout/plain-text call and
    /// hands it in rather than this pure class re-deriving it from a FlowBlock. Returns (0, 0) for
    /// a block entirely outside the selection, or the empty selection.</summary>
    public (int Start, int Length) RangeWithinBlock(int blockIndex, int blockTextLength)
    {
        if (IsEmpty) { return (0, 0); }
        var (start, end) = Normalize();
        if (blockIndex < start.BlockIndex || blockIndex > end.BlockIndex) { return (0, 0); }
        var from = blockIndex == start.BlockIndex ? Math.Clamp(start.Offset, 0, blockTextLength) : 0;
        var to = blockIndex == end.BlockIndex ? Math.Clamp(end.Offset, 0, blockTextLength) : blockTextLength;
        return (from, Math.Max(0, to - from));
    }

    /// <summary>One block's own plain text — a Text/Rule/Image block is its runs concatenated
    /// (the SAME string <see cref="FlowDocumentView"/>'s BuildTextLayout shapes into a TextLayout,
    /// so an offset means the same character in both places); a Table block is its cells, in row
    /// order, joined by a TAB within a row and a NEWLINE between rows (recursing into a cell's own
    /// nested blocks — invariant 168's nested grids — the same way a spreadsheet paste would read).
    /// A block with no text at all (an Image with no OCR/alt text carried into a run) contributes
    /// an empty string, never null.</summary>
    public static string PlainText(FlowBlock block)
    {
        if (block.Kind == FlowBlockKind.Table && block.Table is not null)
        {
            var rows = block.Table.Rows.Select(row =>
                string.Join("\t", row.Cells.Select(cell =>
                    string.Join(" ", cell.Content.Select(PlainText)).Trim())));
            return string.Join("\n", rows);
        }
        return string.Concat(block.Runs.Select(r => r.Text));
    }

    /// <summary>The selected text, ready for the clipboard — blocks joined by a NEWLINE, each
    /// block's own content produced by <see cref="PlainText"/> (so a selected table renders as
    /// tab/newline-separated cells, not dropped). <paramref name="blocks"/> is the SAME top-level
    /// list <see cref="FlowDocumentView"/> is showing; an out-of-range block index (a document that
    /// shrank after the selection was made) is clamped away rather than throwing.</summary>
    public string SelectedText(IReadOnlyList<FlowBlock> blocks)
    {
        if (IsEmpty) { return string.Empty; }
        var (start, end) = Normalize();
        var sb = new StringBuilder();
        var lastIndex = Math.Min(end.BlockIndex, blocks.Count - 1);
        for (var i = Math.Max(0, start.BlockIndex); i <= lastIndex; i++)
        {
            var text = PlainText(blocks[i]);
            var from = i == start.BlockIndex ? Math.Clamp(start.Offset, 0, text.Length) : 0;
            var to = i == end.BlockIndex ? Math.Clamp(end.Offset, 0, text.Length) : text.Length;
            if (to > from) { sb.Append(text, from, to - from); }
            if (i < lastIndex) { sb.Append('\n'); }
        }
        return sb.ToString();
    }
}
