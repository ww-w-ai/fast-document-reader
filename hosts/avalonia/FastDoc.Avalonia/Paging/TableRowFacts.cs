using System;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Paging;

/// <summary>
/// What this host contributes to the engine's page plan about a table: the height of each row, as
/// <see cref="TableGridRenderer"/> would draw it, and which row boundaries a merged cell crosses.
/// Where the table goes — carried whole, split at a boundary, or broken because it fits no page —
/// is the plan's decision (`render/office/page_plan.rs`).
/// </summary>
public static class TableRowFacts
{
    /// <summary>Per-row height, in POINTS — a pass-through to <see cref="TableGridRenderer.
    /// MeasureRowHeightsPoints"/>, the SAME real per-cell TextLayout measurement
    /// <see cref="TableGridRenderer.Draw"/> uses on an uncached table, so the height the plan places
    /// is the height that is drawn.</summary>
    public static double[] EstimateRowHeights(TableGridModel model, double columnWidthPoints,
        ImageBlockRenderer? imageRenderer = null)
        => TableGridRenderer.MeasureRowHeightsPoints(model, columnWidthPoints, imageRenderer);

    /// <summary>Per row of <c>model.Rows</c>: is a boundary above it safe? Safe exactly when no
    /// EARLIER row's cell spans across it — mirrors `PagePagination.LaidOutRow`'s own doc. Row 0 is
    /// always false: there is no boundary above the table's own first row. One pass, because a
    /// thousand-row table asked row by row re-reads every earlier cell each time.</summary>
    public static bool[] RowsThatCanBreakAbove(TableGridModel model)
    {
        var flags = new bool[model.Rows.Count];
        long reach = 0;      // the furthest row number any already-seen row's cell extends to
        var seen = 0;        // rows [0, seen) are folded into `reach`
        for (var r = 1; r < model.Rows.Count; r++)
        {
            var boundary = model.Rows[r].Row;
            for (; seen < model.Rows.Count && model.Rows[seen].Row < boundary; seen++)
            {
                foreach (var cell in model.Rows[seen].Cells) { reach = Math.Max(reach, cell.Row + cell.RowSpan); }
            }
            flags[r] = reach <= boundary;
        }
        return flags;
    }
}
