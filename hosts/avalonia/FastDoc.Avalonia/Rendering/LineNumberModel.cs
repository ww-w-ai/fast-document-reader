using System.Collections.Generic;

namespace FastDoc.Avalonia.Rendering;

/// <summary>
/// S9-B3 batch 3 (docs/studio/sprints/S9/s9b1-full-parity.md #23/#24): the FLOW-mode line-number
/// gutter's pure numbering rule, mirroring the intent of macOS's MarginNumbers.swift — "where am I"
/// answered by the document's own unit. macOS numbers every WRAPPED visual line (one number per
/// TextLine inside a paragraph); this host numbers every TOP-LEVEL <see cref="FlowBlock"/> instead
/// (one number per paragraph/table/image/rule) — disclosed here rather than silently claimed as the
/// same thing, because giving each wrapped line its own number safely would mean reading INTO
/// <c>FlowDocumentView.DrawTextBlock</c>'s per-TextLine loop, which belongs to that file's
/// table/measure/draw code; this model stays a pure function of the block list. Page mode is
/// deliberately NOT covered by this model — see FlowDocumentView.ShowLineNumbers' own doc for why.
/// </summary>
public static class LineNumberModel
{
    /// <summary>Which top-level blocks get a number at all — every block except a bare
    /// <see cref="FlowBlockKind.Rule"/> (a horizontal rule has no "line" a reader would count) and a
    /// wholly-empty text block that draws nothing (an intentional visual gap, not a line).</summary>
    public static bool IsNumbered(FlowBlock block)
    {
        if (block.Kind == FlowBlockKind.Rule) { return false; }
        if (block.Kind == FlowBlockKind.Text)
        {
            return block.Runs.Exists(r => r.Text.Length > 0);
        }
        return true; // Image / Table: a real block the reader can point at
    }

    /// <summary>The label to draw beside block <paramref name="blockIndex"/>, or null when that
    /// block is not numbered (<see cref="IsNumbered"/>) — the 1-based COUNT of numbered blocks up
    /// to and including it, not the raw block index (an unnumbered rule/blank between two
    /// paragraphs must not create a gap in the visible sequence 1, 2, 3…).</summary>
    public static string? LabelFor(IReadOnlyList<FlowBlock> blocks, int blockIndex)
    {
        if (blockIndex < 0 || blockIndex >= blocks.Count) { return null; }
        if (!IsNumbered(blocks[blockIndex])) { return null; }
        var count = 0;
        for (var i = 0; i <= blockIndex; i++)
        {
            if (IsNumbered(blocks[i])) { count++; }
        }
        return count.ToString();
    }

    /// <summary>Total numbered-line count — the upper bound a "Go to Line…" dialog should accept.</summary>
    public static int NumberedCount(IReadOnlyList<FlowBlock> blocks)
    {
        var count = 0;
        foreach (var block in blocks)
        {
            if (IsNumbered(block)) { count++; }
        }
        return count;
    }

    /// <summary>The block index that carries 1-based line number <paramref name="lineNumber"/>, or
    /// null when out of range — the inverse of <see cref="LabelFor"/>, used by "Go to Line…".</summary>
    public static int? BlockIndexForLineNumber(IReadOnlyList<FlowBlock> blocks, int lineNumber)
    {
        if (lineNumber < 1) { return null; }
        var count = 0;
        for (var i = 0; i < blocks.Count; i++)
        {
            if (!IsNumbered(blocks[i])) { continue; }
            count++;
            if (count == lineNumber) { return i; }
        }
        return null;
    }
}
