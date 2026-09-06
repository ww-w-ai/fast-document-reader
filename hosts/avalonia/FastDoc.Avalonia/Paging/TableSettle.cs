using System;
using System.Collections.Generic;
using FastDoc.Avalonia.Native;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Paging;

/// <summary>E2c-2 Part B: one row of a table's CURRENT layout — mirrors `PagePagination.LaidOutRow`
/// / the C ABI's `FastdocLaidOutRow`, in POINTS, keyed by <see cref="FirstChar"/> (see
/// <see cref="TableSettle"/>'s own doc for what that key actually is here).</summary>
public readonly record struct LaidOutRow(long FirstChar, double Top, double Bottom, double FirstLineTop, bool CanBreakAbove);

/// <summary>One table's CURRENT layout — mirrors `PagePagination.LaidOutTable` / `FastdocLaidOutTable`.</summary>
public sealed class LaidOutTable
{
    public required int BlockIndex { get; init; }
    public required long FirstChar { get; init; }
    public required double VisualTop { get; init; }
    public required double Bottom { get; init; }
    public required double FirstLineTop { get; init; }
    public required long LastChar { get; init; }
    public required bool KeepsWhole { get; init; }
    public required IReadOnlyList<LaidOutRow> Rows { get; init; }
}

/// <summary>One settle round's answer — which tables/pieces are pushed or oversized, and whether
/// that differs from what the CALLER already had (the settle loop's own stop condition).</summary>
public readonly record struct TableSettleResult(
    IReadOnlyDictionary<long, (double Height, double TopInset)> Pushed,
    IReadOnlyDictionary<long, long> Oversized,
    bool Changed);

/// <summary>
/// E2c-2 Part B: the `laidOutTables()` mirror and one `fastdoc_office_table_placement` settle
/// round, engine-first with a host fallback approximating `PagePagination.tablesToPush`/
/// `oversizedPieces`' OUTCOME (contract doc §1e/§2.4a).
///
/// KEY SIMPLIFICATION (disclosed): the contract's `first_char`/`last_char` are real document-wide
/// UTF-16 offsets on macOS (NSString positions). This host's <see cref="Rendering.FlowBlock"/> list
/// carries no back-reference to the wire node it was built from, so recovering that real position
/// is out of this unit's reach without touching FlowDocumentBuilder.cs (unowned, see the dispatch
/// note on PageGeometry.cs). Instead every table gets the STABLE, OPAQUE, ORDER-PRESERVING key
/// `(long)BlockIndex * 100_000`, and its row `i` gets `key + i` — sufficient for everything this
/// call actually does with these numbers (echo them back, compare them for identity/ordering across
/// rounds), since footnote citation matching — the one FFI entry point that DOES need a real text
/// position — is a separate call this unit does not touch.
///
/// A second disclosed gap: Swift's `unbreakableGroups` treats a maximal RUN of rows glued by a
/// vertical merge as one indivisible piece; here a "piece" is bounded by <see cref="CanBreakAbove"/>
/// row-by-row, which already refuses to open a boundary a merge crosses — so the OUTCOME (no piece
/// ever splits a merge) matches, but the host fallback's grouping is coarser than Swift's own.
/// </summary>
public static class TableSettle
{
    /// <summary>Mirrors `DocumentWindowController.maxPagedTableSettles` (= `FootnoteBandSettle.
    /// maxRounds`, grepped from FootnoteBandSettle.swift) — the outer settle loop's own round cap.</summary>
    public const int MaxRounds = 8;

    private const long TableKeyStride = 100_000;

    /// <summary>laidOutTables() mirror — one <see cref="LaidOutTable"/> per Table-kind block in the
    /// CURRENT placement, built from that placement's page/local-top plus each table's own row
    /// geometry. <paramref name="pitch"/> (= pageContentHeight + band, `PagePagination.pitch`) turns
    /// a (pageIndex, localTop) pair into one continuous "document space" y — the same space
    /// TextKit's own scrolling coordinates already are on macOS, so the push/overrun arithmetic
    /// below can compare positions across a page boundary without special-casing it.</summary>
    public static List<LaidOutTable> BuildLaidOutTables(IReadOnlyList<FlowBlock> blocks,
        IReadOnlyList<PagedBlock> placements, bool[] tableKeepsWhole, double pitch, double columnWidthPoints,
        ImageBlockRenderer? imageRenderer = null)
    {
        var result = new List<LaidOutTable>();
        foreach (var placement in placements)
        {
            if (placement.BlockIndex < 0 || placement.BlockIndex >= blocks.Count) { continue; }
            var block = blocks[placement.BlockIndex];
            if (block.Kind != FlowBlockKind.Table || block.Table is null) { continue; }

            var model = block.Table;
            var rowHeights = EstimateRowHeights(model, columnWidthPoints, imageRenderer);
            var visualTop = placement.PageIndex * pitch + placement.LocalTopPoints;
            var keepsWhole = placement.BlockIndex < tableKeepsWhole.Length && tableKeepsWhole[placement.BlockIndex];
            var tableKey = (long)placement.BlockIndex * TableKeyStride;

            var rows = new List<LaidOutRow>(model.Rows.Count);
            var rowTop = visualTop;
            for (var r = 0; r < model.Rows.Count; r++)
            {
                var h = r < rowHeights.Length ? rowHeights[r] : 0;
                rows.Add(new LaidOutRow(
                    FirstChar: tableKey + r,
                    Top: rowTop,
                    Bottom: rowTop + h,
                    FirstLineTop: rowTop,
                    CanBreakAbove: CanBreakAbove(model, r)));
                rowTop += h;
            }

            result.Add(new LaidOutTable
            {
                BlockIndex = placement.BlockIndex,
                FirstChar = tableKey,
                VisualTop = visualTop,
                Bottom = visualTop + placement.HeightPoints,
                FirstLineTop = visualTop,
                LastChar = tableKey + Math.Max(0, model.Rows.Count - 1) + 1,
                KeepsWhole = keepsWhole,
                Rows = rows,
            });
        }
        return result;
    }

    /// <summary>A boundary above row index <paramref name="rowIndex"/> (0-based within
    /// <c>model.Rows</c>) is safe exactly when no EARLIER row's cell spans across it — mirrors
    /// `PagePagination.LaidOutRow`'s own doc ("no cell spans across that boundary"). Row 0 always
    /// returns false: there is no boundary above the table's own first row.</summary>
    private static bool CanBreakAbove(TableGridModel model, int rowIndex)
    {
        if (rowIndex <= 0 || rowIndex >= model.Rows.Count) { return false; }
        var boundaryRowNumber = model.Rows[rowIndex].Row;
        foreach (var earlier in model.Rows)
        {
            if (earlier.Row >= boundaryRowNumber) { continue; }
            foreach (var cell in earlier.Cells)
            {
                if (cell.Row + cell.RowSpan > boundaryRowNumber) { return false; }
            }
        }
        return true;
    }

    /// <summary>E2c-2b: per-row height, in POINTS — now a thin pass-through to <see
    /// cref="TableGridRenderer.MeasureRowHeightsPoints"/>, the SAME real per-cell TextLayout
    /// measurement <see cref="TableGridRenderer.Draw"/> uses on an uncached table. Replaces this
    /// unit's own character-count-per-cell guess (Latin 0.55 width ratio), which E2c-2's own
    /// diagnosis pinned as the leading cause of the HWP/hwpx sheet-count overshoot — a wider script
    /// like Hangul was under-counted, inflating estimated line count and row height. Kept as its own
    /// method (rather than every caller reaching into TableGridRenderer directly) only so this
    /// file's own doc stays the one place that explains WHY the settle loop's row geometry equals
    /// the table renderer's own.</summary>
    public static double[] EstimateRowHeights(TableGridModel model, double columnWidthPoints,
        ImageBlockRenderer? imageRenderer = null)
        => TableGridRenderer.MeasureRowHeightsPoints(model, columnWidthPoints, imageRenderer);

    /// <summary>Converts one round's pushed/oversized KEYS back into block-index/row-index terms
    /// <see cref="PageLayout.Build"/> understands — <see cref="TableKeyStride"/> is the same stride
    /// <see cref="BuildLaidOutTables"/> used to build them, so this is a pure inverse.</summary>
    public static (ISet<int> ForcePush, IReadOnlyDictionary<int, SortedSet<int>> ForcedBreaks) ExtractBlockOverrides(
        IEnumerable<long> pushedKeys, IReadOnlyDictionary<long, long> oversized)
    {
        var push = new HashSet<int>();
        foreach (var key in pushedKeys) { push.Add((int)(key / TableKeyStride)); }

        var breaks = new Dictionary<int, SortedSet<int>>();
        foreach (var key in oversized.Keys)
        {
            var blockIndex = (int)(key / TableKeyStride);
            var rowIndex = (int)(key % TableKeyStride);
            if (rowIndex <= 0) { continue; } // row 0 is the table's own start, not an internal break
            if (!breaks.TryGetValue(blockIndex, out var set))
            {
                set = new SortedSet<int>();
                breaks[blockIndex] = set;
            }
            set.Add(rowIndex);
        }
        return (push, breaks);
    }

    /// <summary>One settle round: engine-first (`fastdoc_office_table_placement`), host fallback on
    /// refusal or no handle.</summary>
    public static TableSettleResult Resolve(IntPtr engineHandle, IReadOnlyList<LaidOutTable> tables,
        double pageContentHeight, double band, double leadingBand, bool splitTables,
        IReadOnlyDictionary<long, (double Height, double TopInset)> alreadyPushed,
        IReadOnlyDictionary<long, long> alreadyOversized)
    {
        if (engineHandle != IntPtr.Zero)
        {
            var engineResult = ResolveViaEngine(engineHandle, tables, pageContentHeight, band, leadingBand,
                splitTables, alreadyPushed, alreadyOversized);
            if (engineResult is { } r) { return r; }
        }
        return ResolveViaHost(tables, pageContentHeight, band, leadingBand, splitTables, alreadyPushed, alreadyOversized);
    }

    private static TableSettleResult? ResolveViaEngine(IntPtr handle, IReadOnlyList<LaidOutTable> tables,
        double pageContentHeight, double band, double leadingBand, bool splitTables,
        IReadOnlyDictionary<long, (double Height, double TopInset)> alreadyPushed,
        IReadOnlyDictionary<long, long> alreadyOversized)
    {
        var flatRows = new List<FastdocEngine.FastdocLaidOutRow>();
        var wireTables = new FastdocEngine.FastdocLaidOutTable[tables.Count];
        for (var i = 0; i < tables.Count; i++)
        {
            var t = tables[i];
            var offset = (nuint)flatRows.Count;
            foreach (var row in t.Rows)
            {
                flatRows.Add(new FastdocEngine.FastdocLaidOutRow
                {
                    FirstChar = row.FirstChar,
                    Top = row.Top,
                    Bottom = row.Bottom,
                    FirstLineTop = row.FirstLineTop,
                    CanBreakAbove = row.CanBreakAbove,
                });
            }
            wireTables[i] = new FastdocEngine.FastdocLaidOutTable
            {
                FirstChar = t.FirstChar,
                VisualTop = t.VisualTop,
                Bottom = t.Bottom,
                FirstLineTop = t.FirstLineTop,
                LastChar = t.LastChar,
                RowOffset = offset,
                RowCount = (nuint)t.Rows.Count,
                KeepsWhole = t.KeepsWhole,
            };
        }

        var pushedIn = new FastdocEngine.FastdocTableMetricsEntry[alreadyPushed.Count];
        {
            var i = 0;
            foreach (var kv in alreadyPushed)
            {
                pushedIn[i++] = new FastdocEngine.FastdocTableMetricsEntry
                { Key = kv.Key, Height = kv.Value.Height, TopInset = kv.Value.TopInset };
            }
        }
        var oversizedIn = new FastdocEngine.FastdocI64Entry[alreadyOversized.Count];
        {
            var i = 0;
            foreach (var kv in alreadyOversized)
            {
                oversizedIn[i++] = new FastdocEngine.FastdocI64Entry { Key = kv.Key, Value = kv.Value };
            }
        }

        var capacity = (nuint)(wireTables.Length + flatRows.Count + 1);
        var outPush = new FastdocEngine.FastdocTableMetricsEntry[capacity];
        var outOversized = new FastdocEngine.FastdocI64Entry[capacity];

        bool ok;
        try
        {
            ok = FastdocEngine.fastdoc_office_table_placement(
                handle, wireTables, (nuint)wireTables.Length, flatRows.ToArray(), (nuint)flatRows.Count,
                pageContentHeight, band, leadingBand, splitTables,
                pushedIn, (nuint)pushedIn.Length, Array.Empty<FastdocEngine.FastdocNoteBandEntry>(), 0,
                oversizedIn, (nuint)oversizedIn.Length,
                outPush, capacity, out var outPushCount, outOversized, capacity, out var outOversizedCount);
            if (!ok) { return null; }

            var pushed = new Dictionary<long, (double, double)>();
            for (var i = 0; i < (int)outPushCount; i++)
            {
                pushed[outPush[i].Key] = (outPush[i].Height, outPush[i].TopInset);
            }
            var oversized = new Dictionary<long, long>();
            for (var i = 0; i < (int)outOversizedCount; i++)
            {
                oversized[outOversized[i].Key] = outOversized[i].Value;
            }

            var changed = !DictionariesEqual(pushed, alreadyPushed) || !DictionariesEqual(oversized, alreadyOversized);
            return new TableSettleResult(pushed, oversized, changed);
        }
        catch (Exception)
        {
            // A refused/unavailable native entry point (older dylib, missing symbol) falls back to
            // the host arithmetic below rather than crashing page mode outright.
            return null;
        }
    }

    /// <summary>Host fallback — approximates `PagePagination.tablesToPush`/`oversizedPieces`'
    /// OUTCOME (see this file's own top-level doc for the disclosed grouping gap): a table that
    /// overruns its page and would fit a fresh one is pushed WHOLE; one taller than a page — or one
    /// the document allows to split and does not fit — is broken at every `CanBreakAbove` row
    /// boundary. No note bands in this unit (empty in every call), so `bodyHeight`/`textBottom`
    /// collapse to `pageContentHeight` exactly.</summary>
    private static TableSettleResult ResolveViaHost(IReadOnlyList<LaidOutTable> tables,
        double pageContentHeight, double band, double leadingBand, bool splitTables,
        IReadOnlyDictionary<long, (double Height, double TopInset)> alreadyPushed,
        IReadOnlyDictionary<long, long> alreadyOversized)
    {
        var pitch = pageContentHeight + band;
        var pushed = new Dictionary<long, (double, double)>(alreadyPushed);
        var oversized = new Dictionary<long, long>(alreadyOversized);
        if (pitch <= 0 || pageContentHeight <= 0)
        {
            return new TableSettleResult(pushed, oversized, false);
        }

        double PageOf(double top) => Math.Floor(((top - leadingBand) / pitch) + 1e-6);
        // textBottom(page) with an empty noteBands map is exactly `page * pitch + pageContentHeight`
        // — the same identity `(page + 1) * pitch - band` reduces to (pitch - band == pageContentHeight).
        bool Overruns(double top, double bottom) => (bottom - leadingBand) > (PageOf(top) + 1) * pitch - band + 0.01;

        foreach (var t in tables)
        {
            var height = t.Bottom - t.VisualTop;
            var known = pushed.ContainsKey(t.FirstChar) || oversized.ContainsKey(t.FirstChar);
            if (!known && !Overruns(t.VisualTop, t.Bottom)) { continue; }

            // Invariant 64: a table taller than a whole page is ALWAYS broken where it stands,
            // regardless of splitTables/keepsWhole — there is no fresh page it could move to that
            // would fit it either. `splitTables`/`keepsWhole` govern only whether a table that WOULD
            // fit a fresh page also gets carried there whole (the branch below) — this unit only
            // ever pushes whole (never splits a table that fits a fresh page), which is the coarser,
            // disclosed half of Swift's own richer per-group registration (see this file's top doc).
            if (height > pageContentHeight)
            {
                var pieceStart = 0;
                for (var r = 1; r <= t.Rows.Count; r++)
                {
                    var atBoundary = r == t.Rows.Count || t.Rows[r].CanBreakAbove;
                    if (!atBoundary) { continue; }
                    var pieceTop = t.Rows[pieceStart].Top;
                    var pieceBottom = t.Rows[r - 1].Bottom;
                    if (pieceBottom - pieceTop > pageContentHeight || Overruns(pieceTop, pieceBottom))
                    {
                        oversized[t.Rows[pieceStart].FirstChar] =
                            r < t.Rows.Count ? t.Rows[r].FirstChar : t.LastChar;
                    }
                    pieceStart = r;
                }
                continue;
            }

            pushed[t.FirstChar] = (height, t.FirstLineTop - t.VisualTop);
        }

        var changed = !DictionariesEqual(pushed, alreadyPushed) || !DictionariesEqual(oversized, alreadyOversized);
        return new TableSettleResult(pushed, oversized, changed);
    }

    private static bool DictionariesEqual<TV>(IReadOnlyDictionary<long, TV> a, IReadOnlyDictionary<long, TV> b)
    {
        if (a.Count != b.Count) { return false; }
        foreach (var kv in a)
        {
            if (!b.TryGetValue(kv.Key, out var v) || !Equals(kv.Value, v)) { return false; }
        }
        return true;
    }
}
