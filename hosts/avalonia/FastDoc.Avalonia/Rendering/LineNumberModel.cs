using System.Collections.Generic;

namespace FastDoc.Avalonia.Rendering;

/// <summary>
/// S9-B3 batch 3 (docs/studio/sprints/S9/s9b1-full-parity.md #23/#24): the FLOW-mode line-number
/// gutter's pure numbering rule — parity with macOS's `MarginNumbers.swift`/`ReaderTextView.
/// drawLineNumbers` (`Sources/FastDocReader/Navigation/ReaderTextView.swift:372`; INVARIANTS.md 71):
/// ONE number per top-level <see cref="FlowBlock"/> (a document's own paragraph/heading/list-item/
/// image/rule), never per wrapped screen line — narrowing the window must not renumber the file
/// underneath the reader. A block inside a TABLE carries no number at all (a cell is a grid
/// position, not a line of prose; see <see cref="IsNumbered"/>). The visible sequence is
/// consecutive (1, 2, 3…) with no gap for an unnumbered block in between — this host's own choice,
/// since macOS's underlying line numbers can skip. Page mode is deliberately NOT covered by this
/// model — see FlowDocumentView.ShowLineNumbers' own doc for why.
/// </summary>
public static class LineNumberModel
{
    /// <summary>Which top-level blocks get a number at all — every block except a bare
    /// <see cref="FlowBlockKind.Rule"/> (a horizontal rule has no "line" a reader would count), a
    /// wholly-empty text block that draws nothing (an intentional visual gap, not a line), and a
    /// <see cref="FlowBlockKind.Table"/> (a cell is a grid position, not a line of prose — macOS
    /// draws no number for table content either).</summary>
    public static bool IsNumbered(FlowBlock block)
    {
        if (block.Kind == FlowBlockKind.Rule) { return false; }
        if (block.Kind == FlowBlockKind.Table) { return false; }
        if (block.Kind == FlowBlockKind.Text)
        {
            return block.Runs.Exists(r => r.Text.Length > 0);
        }
        return true; // Image: a real block the reader can point at
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
