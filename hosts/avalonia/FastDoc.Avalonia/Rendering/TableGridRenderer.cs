using System;
using System.Collections.Generic;
using Avalonia;
using Avalonia.Media;
using Avalonia.Media.TextFormatting;
using Avalonia.Utilities;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Printing;

namespace FastDoc.Avalonia.Rendering;

/// <summary>One resolved cell in a <see cref="TableGridModel"/>. The fallback chain the document
/// spec draws — cell's OWN declaration, else the cell's named STYLE, else the table's default — is
/// already collapsed by <see cref="FlowDocumentBuilder"/> at build time, so this renderer only
/// ever resolves ONE further step: cell -&gt; table (never re-walks the wire's three-level chain
/// per frame).</summary>
public sealed class TableGridCell
{
    public required uint Row { get; init; }
    public required uint Column { get; init; }
    public uint RowSpan { get; init; } = 1;
    public uint ColumnSpan { get; init; } = 1;
    public List<FlowBlock> Content { get; init; } = new();
    /// <summary>Cell's own declared/style-named per-edge borders, already collapsed
    /// (direct ?? style) — null means "the cell named none of its own", not "no border".</summary>
    public BorderSetWire? EdgeBorders { get; init; }
    /// <summary>Cell's own declared/style-named uniform border, already collapsed
    /// (direct ?? style).</summary>
    public UniformBorderWire? UniformBorder { get; init; }
    /// <summary>Cell's own declared/style-named shading, already collapsed (direct ?? style).</summary>
    public ColorWire? Shading { get; init; }
    /// <summary>"top" | "middle" | "bottom" — wire::VerticalAlignment; null = natural (top).</summary>
    public string? VerticalAlignment { get; init; }
    /// <summary>wire::TableCell.uniformPaddingPoints — the NON-paged padding declaration
    /// (`OfficeTextBuilder`'s `else` branch, `max(cell.padding ?? floor, floor)`). Carried for
    /// completeness/a future non-paged (flow-mode-only) path; this renderer's own padding
    /// resolution (<see cref="TableGridRenderer.ResolvePaddingEdgePoints"/>) is the PAGED branch
    /// and does NOT consult this field — only <see cref="EdgePadding"/>, matching the Swift
    /// source exactly (verified against `FMD_TABLE_PROBE` real output, 2026-09-05).</summary>
    public double? UniformPaddingPoints { get; init; }
    /// <summary>wire::TableCell.edgePadding — the PAGED per-edge padding declaration this
    /// renderer actually resolves against (cell edge, else the table's own default, else a 7pt
    /// last resort — never floored past a document's own smaller/zero declaration).</summary>
    public OptionalInsetsWire? EdgePadding { get; init; }
    /// <summary>wire::TableCell.declaredHeight — a docx row's own declared height, honoured ONLY
    /// as a decorative-band baseline for a row whose every cell holds no text (invariant 161(a)/
    /// TableBlockBuilder.decorativeBand). `null` = the document declared none.</summary>
    public double? DeclaredHeight { get; init; }
    /// <summary>wire::TableCell.minimumRowHeight — a docx row's declared height, honoured as a
    /// FLOOR under a single-line, unwrapped, non-empty cell (TableBlockBuilder.singleLineRowFloor).
    /// `null` = the document declared none.</summary>
    public double? MinimumRowHeight { get; init; }
}

/// <summary>One row of a <see cref="TableGridModel"/> — a placeholder for cells that begin here
/// (a cell spanning down from an earlier row is NOT repeated in a later row's list; the grid below
/// resolves span occupancy).</summary>
public sealed class TableGridRow
{
    public required uint Row { get; init; }
    public bool Header { get; init; }
    public List<TableGridCell> Cells { get; init; } = new();
}

/// <summary>The resolved grid TableGridRenderer draws — built once by FlowDocumentBuilder from the
/// wire's table/tableRow/tableCell nodes, then measured/drawn many times by the view's
/// virtualized scroll without touching the RenderTree again.</summary>
public sealed class TableGridModel
{
    /// <summary>The document's own column-width RATIOS (wire::Table.gridWidths), one per grid
    /// column. Renormalized (divided by their own sum) at draw time so they always distribute the
    /// full reading-column width regardless of what unit the source authored them in — CLAUDE.md's
    /// "table columns that fill the width by the document's own grid proportions".</summary>
    public List<double> ColumnWidthRatios { get; init; } = new();
    public List<TableGridRow> Rows { get; init; } = new();
    public UniformBorderWire? DefaultUniformBorder { get; init; }
    public ColorWire? DefaultShading { get; init; }
    public BorderSetWire? TableEdgeBorders { get; init; }
    public int ColumnCount { get; init; }
    /// <summary>E2c-2c: wire::TableStyle.defaultPadding — the table's own fallback padding when a
    /// cell states none of its own (one step above <see cref="TableGridRenderer.DefaultCellPaddingPoints"/>'s
    /// 7pt floor, mirroring TableBlockBuilder.defaultCellPadding's cascade).</summary>
    public OptionalInsetsWire? DefaultPadding { get; init; }
    /// <summary>E2c-2c: the document's own default body font size in points (wire's
    /// `defaultFontSize`, threaded in by FlowDocumentBuilder.BuildTable) — an empty cell's line
    /// height is ONE LINE OF ITS OWN SIZE (INVARIANTS.md 169), never a hardcoded 12/14pt guess.</summary>
    public double DefaultBodyFontSizePoints { get; init; } = 12.0;
}

/// <summary>Draws a <see cref="TableGridModel"/> as a real cell grid: column widths distributed by
/// the document's own proportions, row heights driven by each row's tallest cell (a rowSpan cell's
/// extra height split across the rows it covers), per-edge borders resolved cell -&gt; table -&gt;
/// a sane default line, and cell shading as a filled rectangle behind the text. Nested tables
/// recurse (capped at <see cref="MaxNestingDepth"/> by the builder, not here — this renderer just
/// draws whatever depth of Table blocks the content list already contains).
///
/// Shares FlowDocumentView's own measure-then-correct contract: Measure gives a cheap estimate for
/// virtualization, Draw returns the block's TRUE height so the caller can replace the estimate —
/// this renderer never assumes the estimate was exact.
///
/// ROW-LEVEL CACHING (E3): a table is ONE FlowBlock, so FlowDocumentView's own block virtualization
/// cannot skip it once any part of it is visible — without this, a giant table pays full row-height
/// recomputation (building a TextLayout for every cell of every row) on every single scroll frame,
/// which is the giant-table.odt spike E2b measured. Draw accepts the PREVIOUS call's row-height
/// array back from the caller: when its length matches the row count, row heights are trusted as-is
/// (no cell layout is rebuilt just to re-derive a height that has not changed), and a TextLayout is
/// only ever built for a cell whose rect actually intersects the given viewport. The first draw of a
/// table (no cache yet, or the column width / zoom changed) still pays the full O(rows) layout pass
/// once — a real height needs a real measurement — but every subsequent scroll of that same table at
/// the same width/zoom reuses the cached heights and shapes text for on-screen cells only.</summary>
public static class TableGridRenderer
{
    private const double PointsToPixels = 96.0 / 72.0;
    /// <summary>E2c-2c: the reader's own padding FLOOR, mirroring
    /// `TableBlockBuilder.defaultCellPadding` (Swift, 7pt) — the last step of the cascade a cell's
    /// padding is resolved through: cell's own edge/uniform declaration, else the table's
    /// `TableStyleWire.DefaultPadding`, else this floor. Never itself grown past by a document
    /// declaring less; a document declaring MORE than 7pt keeps its own larger value (see
    /// <see cref="ResolvePaddingEdgePoints"/>).</summary>
    public const double DefaultCellPaddingPoints = 7.0;
    private const double DefaultBorderWidthPx = 0.75;
    private static readonly IBrush DefaultBorderBrush = new SolidColorBrush(Color.FromRgb(0x99, 0x99, 0x99));
    private static readonly Typeface DefaultTypeface = new("Inter");

    /// <summary>One edge of a cell's padding cascade, in POINTS — mirrors `OfficeTextBuilder.
    /// swift`'s PAGED branch exactly (`TableBlockBuilder.resolvedPagedPadding`, verified 2026-09-05
    /// against `FMD_TABLE_PROBE` on the reference manual: real cells there print `pad 0.0/0.0`,
    /// i.e. a document that DECLARES zero padding on an edge is drawn at zero — never floored).
    /// This is a DIFFERENT formula from the non-paged branch (`max(cell.padding ?? floor, floor)`,
    /// which floors even a declared small value and never consults per-edge at all) — this host's
    /// page-mode renderer is always the paged case, so this is the only one of the two it may use.
    /// Order: this cell's own per-edge declaration, else the table's `TableStyleWire.DefaultPadding`
    /// for this edge, else <see cref="DefaultCellPaddingPoints"/> as a last resort when NEITHER
    /// declared anything for this edge — a real declared value (0, or even negative — rhwp really
    /// emits one, invariant-tested on the Rust side) is used AS-IS. `cell.UniformPaddingPoints` is
    /// NOT consulted here — the paged branch never reads it (mirrors the Swift source, which reads
    /// only `cell.edgePadding` in this branch). Floored DOWN to match `.rounded(.down)`.</summary>
    private static double ResolvePaddingEdgePoints(double? cellEdge, double? tableEdge)
    {
        var declared = cellEdge ?? tableEdge ?? DefaultCellPaddingPoints;
        return Math.Floor(declared);
    }

    /// <summary>Top+bottom padding for one cell, in PIXELS (points * <see cref="PointsToPixels"/> —
    /// padding is NOT scaled by fontScale, matching the pre-E2c-2c fixed constant's behaviour, so
    /// zoom multiplies text alone here).</summary>
    private static double VerticalPaddingPx(TableGridCell cell, TableGridModel model)
    {
        var top = ResolvePaddingEdgePoints(cell.EdgePadding?.Top, model.DefaultPadding?.Top);
        var bottom = ResolvePaddingEdgePoints(cell.EdgePadding?.Bottom, model.DefaultPadding?.Bottom);
        return (top + bottom) * PointsToPixels;
    }

    /// <summary>Left+right padding for one cell, in PIXELS — see <see cref="VerticalPaddingPx"/>.</summary>
    private static double HorizontalPaddingPx(TableGridCell cell, TableGridModel model)
    {
        var left = ResolvePaddingEdgePoints(cell.EdgePadding?.Left, model.DefaultPadding?.Left);
        var right = ResolvePaddingEdgePoints(cell.EdgePadding?.Right, model.DefaultPadding?.Right);
        return (left + right) * PointsToPixels;
    }

    /// <summary>Top padding alone, in PIXELS — for the draw-time text origin (only the top edge
    /// offsets where the glyph run starts; the bottom edge only ever affects the row's total
    /// height, via <see cref="VerticalPaddingPx"/>).</summary>
    private static double TopPaddingPx(TableGridCell cell, TableGridModel model) =>
        ResolvePaddingEdgePoints(cell.EdgePadding?.Top, model.DefaultPadding?.Top) * PointsToPixels;

    /// <summary>Left padding alone, in PIXELS — for the draw-time text origin's x offset (see
    /// <see cref="TopPaddingPx"/>).</summary>
    private static double LeftPaddingPx(TableGridCell cell, TableGridModel model) =>
        ResolvePaddingEdgePoints(cell.EdgePadding?.Left, model.DefaultPadding?.Left) * PointsToPixels;

    /// <summary>The padding pair used where no real cell is available yet (an empty table's zero
    /// early-return) — the table's own default cascaded the same way as a real cell's edge.</summary>
    private static double TablePaddingPx(TableGridModel model)
    {
        var top = ResolvePaddingEdgePoints(null, model.DefaultPadding?.Top);
        var bottom = ResolvePaddingEdgePoints(null, model.DefaultPadding?.Bottom);
        return (top + bottom) * PointsToPixels;
    }

    /// <summary>INVARIANTS.md 169: an empty cell paragraph is a LINE OF ITS OWN CHARACTER SIZE, not
    /// AppKit's/a hardcoded default — the fix there sets `minimumLineHeight = maximumLineHeight =
    /// size` on the paragraph, i.e. the line box is EXACTLY the font size in points, never a
    /// measured-metrics guess or an invented 1.25 ratio. Falls back to the DOCUMENT's own default
    /// body size (never a bare 12/14pt literal) when the cell vouched for none of its own.</summary>
    private static double EmptyCellLineHeightPx(TableGridModel model, double fontScale) =>
        model.DefaultBodyFontSizePoints * fontScale * PointsToPixels;

    /// <summary>E2c-2b: the table's TRUE total height at <paramref name="columnWidth"/>/<paramref
    /// name="fontScale"/> — used by the flow-mode virtualization pre-pass (FlowDocumentView's own
    /// offset table) BEFORE any table is actually drawn. Used to be a character-count-per-cell
    /// GUESS (charsPerLine assumed a fixed Latin-width ratio of 0.55 glyph-widths-per-em, which
    /// under-counts a wider script like Hangul and so over-estimates line count and height —
    /// exactly the systematic error E2c-2's own diagnosis pinned as the leading cause of this
    /// host's HWP/hwpx sheet-count overshoot). Now calls the SAME real per-cell <see
    /// cref="MeasureAllRows"/> pass <see cref="Draw"/> uses on an uncached table — no more
    /// heuristic, no separate formula to keep in sync with the real one. This trades a cheap guess
    /// for the true O(rows) measurement on every table this pre-pass reaches; see measurements.md's
    /// E2c-2b section for the giant-table.odt cost this was measured against.</summary>
    public static double EstimateHeight(TableGridModel model, double columnWidth, double fontScale = 1.0, ImageBlockRenderer? imageRenderer = null)
    {
        if (model.Rows.Count == 0) { return TablePaddingPx(model); }
        var widths = ResolveColumnWidths(model, columnWidth);
        var rowCount = model.Rows.Count;
        var rowIndexByRowNumber = new Dictionary<uint, int>(rowCount);
        for (var i = 0; i < rowCount; i++) { rowIndexByRowNumber[model.Rows[i].Row] = i; }
        var cellLayouts = new Dictionary<TableGridCell, (List<CellSegment> Segments, double Height)>();
        var heights = MeasureAllRows(model, widths, rowIndexByRowNumber, rowCount, fontScale, cellLayouts, imageRenderer);
        double total = 0;
        foreach (var h in heights) { total += h; }
        return total;
    }

    /// <summary>Draws the grid at pixel position (left, top) and returns its TRUE total row-height
    /// array (NOT the total height — see below) — column widths from the document's own ratios,
    /// row heights from real TextLayout of each cell's content (or the incoming cache, see the type
    /// doc above), merged cells spanning their full rect, per-edge borders and shading resolved per
    /// cell. Only cells whose rect intersects [<paramref name="viewportTop"/>, <paramref
    /// name="viewportBottom"/>) get a TextLayout built and drawn; cells outside it contribute their
    /// row's cached or freshly measured height only.
    ///
    /// COORDINATE-SPACE INVARIANT (S9-V, root cause fixed 2026-09-06 — read this before touching
    /// any of the three `top`-shaped parameters below): <paramref name="viewportTop"/>/<paramref
    /// name="viewportBottom"/> MUST be in the exact SAME coordinate space as <paramref name="top"/>
    /// — this method immediately computes `viewportTop - top` (below) to recover a TABLE-LOCAL
    /// offset (0 == this table's own top row, growing downward), so whatever space `top` happens
    /// to be in (document-space, surface/scroll-adjusted space, or a caller's own made-up origin)
    /// cancels out correctly ONLY if `viewportTop`/`viewportBottom` were built by adding that SAME
    /// `top` value to a genuinely table-local number. A caller that instead subtracts SOME OTHER
    /// quantity — even one that looks equivalent, like a block's own on-screen `top` instead of its
    /// document-space offset — leaves a stray, scroll-dependent residue that is invisible at
    /// scroll offset 0 (every space coincides there) and silently culls every row once scrolled.
    /// That exact bug shipped in <see cref="FlowDocumentView.DrawBlock"/>'s Table case: see its
    /// `blockLocalViewTop`/`blockLocalViewBottom` parameter doc and
    /// docs/studio/sprints/S9/s9c-flow-content.md for the VM evidence
    /// (<c>FASTDOC_DRAW_LOG</c>) that caught it. <paramref name="cachedRowHeights"/> is the row
    /// -height array THIS SAME TABLE returned last draw, or null for a first draw (or after a
    /// width/zoom change forces the caller to drop its cache) — passing it back in is what turns an
    /// O(rows) TextLayout rebuild into an O(visible rows) one on every subsequent scroll.</summary>
    public static double Draw(
        IPageCanvas surface,
        TableGridModel model,
        double left,
        double top,
        double columnWidth,
        double fontScale,
        double viewportTop,
        double viewportBottom,
        double[]? cachedRowHeights,
        out double[] rowHeightsOut,
        IReadOnlyList<int>? rowIndicesToDraw = null,
        ImageBlockRenderer? imageRenderer = null,
        // S9-V diagnostic (FASTDOC_DRAW_LOG): when non-null, receives one line per row this call
        // visits ("row=.. y=.. h=.. verdict=drawn|culled") and one line per cell it actually built
        // content for ("cell row=.. col=.. textLayoutNull=.. height=.."). No-op (never even
        // allocates the strings) when null — the caller (FlowDocumentView.RenderCore) only passes
        // a real delegate when the env var is set.
        Action<string>? diagLog = null)
    {
        if (model.Rows.Count == 0)
        {
            rowHeightsOut = Array.Empty<double>();
            return TablePaddingPx(model);
        }

        var widths = ResolveColumnWidths(model, columnWidth);
        var columnX = new double[widths.Length + 1];
        for (var i = 0; i < widths.Length; i++) { columnX[i + 1] = columnX[i] + widths[i]; }

        var rowCount = model.Rows.Count;
        var rowIndexByRowNumber = new Dictionary<uint, int>(rowCount);
        for (var i = 0; i < rowCount; i++) { rowIndexByRowNumber[model.Rows[i].Row] = i; }

        var cellLayouts = new Dictionary<TableGridCell, (List<CellSegment> Segments, double Height)>();
        double[] rowHeights;
        var haveValidCache = cachedRowHeights is not null && cachedRowHeights.Length == rowCount;

        if (haveValidCache)
        {
            // Trust the previous call's measured heights — nothing about this table's content or
            // width changed, so re-deriving them would just rebuild the same TextLayouts for
            // cells the caller may not even ask us to draw this frame.
            rowHeights = (double[])cachedRowHeights!.Clone();
        }
        else
        {
            rowHeights = MeasureAllRows(model, widths, rowIndexByRowNumber, rowCount, fontScale, cellLayouts, imageRenderer);
        }

        // E2c-2b: which REAL row indices to draw, and in what ORDER — defaults to every row, once,
        // in document order (every pre-existing caller, unaffected). PageModePainter passes a
        // SUBSET (one settle-decided piece, optionally with a repeated header row stitched above
        // it) when a table was broken across pages — see PageModePainter's own doc.
        var drawOrder = rowIndicesToDraw ?? DefaultRowOrder(rowCount);
        var segY = new double[drawOrder.Count + 1];
        for (var i = 0; i < drawOrder.Count; i++) { segY[i + 1] = segY[i] + rowHeights[drawOrder[i]]; }
        var totalHeight = segY[drawOrder.Count];

        var positionOfRealRow = new Dictionary<int, int>(drawOrder.Count);
        for (var i = 0; i < drawOrder.Count; i++) { positionOfRealRow[drawOrder[i]] = i; }

        var localViewTop = viewportTop - top;
        var localViewBottom = viewportBottom - top;

        for (var position = 0; position < drawOrder.Count; position++)
        {
            var rowIndex = drawOrder[position];
            if (rowIndex < 0 || rowIndex >= rowCount) { continue; }
            var row = model.Rows[rowIndex];
            foreach (var cell in row.Cells)
            {
                var colIndex = (int)cell.Column;
                if (colIndex < 0 || colIndex >= widths.Length) { continue; }
                var colSpan = Math.Max(1, (int)cell.ColumnSpan);
                var rowSpan = (int)Math.Min(Math.Max(1, cell.RowSpan), rowCount - rowIndex);
                // A merged cell that spans PAST this draw call's own selection (rowSpan reaching a
                // row not in `drawOrder`, or not immediately following in the given order) draws
                // only as tall as the rows actually present here — the settle loop's own
                // `CanBreakAbove` already refuses to open a piece boundary a merge crosses, so this
                // only ever bites the header-repeat scaffold (which stitches non-adjacent rows
                // together on purpose) and never a real body piece.
                var spanEnd = rowIndex + 1;
                while (spanEnd < rowIndex + rowSpan && positionOfRealRow.TryGetValue(spanEnd, out var p)
                       && p == position + (spanEnd - rowIndex))
                {
                    spanEnd++;
                }
                var y = segY[position];
                var h = segY[position + (spanEnd - rowIndex)] - segY[position];

                // Off-screen: contribute nothing to draw, and — the whole point of the cache —
                // never touch TextLayout for it.
                if (y + h < localViewTop || y > localViewBottom)
                {
                    diagLog?.Invoke($"row={rowIndex} col={colIndex} y={y:F1} h={h:F1} verdict=culled");
                    continue;
                }
                diagLog?.Invoke($"row={rowIndex} col={colIndex} y={y:F1} h={h:F1} verdict=drawn");

                var x = left + columnX[colIndex];
                var w = SpanWidth(widths, colIndex, colSpan);
                var rect = new Rect(x, top + y, w, h);

                var shading = ResolveShading(cell, model);
                if (shading is not null)
                {
                    surface.DrawRect(rect, shading.Value, null, 0);
                }

                var cellWidth = Math.Max(10, SpanWidth(widths, colIndex, colSpan) - HorizontalPaddingPx(cell, model));
                if (!cellLayouts.TryGetValue(cell, out var built))
                {
                    built = BuildCellContent(cell, cellWidth, fontScale, model, imageRenderer);
                    cellLayouts[cell] = built;
                }

                var (segments, contentHeight) = built;
                if (diagLog is not null)
                {
                    var hasTextLayout = segments.Exists(s => s.TextLayout is not null);
                    diagLog($"cell row={cell.Row} col={cell.Column} segments={segments.Count} textLayoutNull={!hasTextLayout} height={contentHeight:F1}");
                }
                if (segments.Count > 0)
                {
                    var vAlign = cell.VerticalAlignment;
                    var vPad = VerticalPaddingPx(cell, model);
                    var offsetY = vAlign switch
                    {
                        "middle" => Math.Max(0, (h - vPad - contentHeight) / 2),
                        "bottom" => Math.Max(0, h - vPad - contentHeight),
                        _ => 0,
                    };
                    var segLeft = x + LeftPaddingPx(cell, model);
                    var segCursorY = top + y + TopPaddingPx(cell, model) + offsetY;
                    foreach (var segment in segments)
                    {
                        if (segment.TextLayout is { } textLayout)
                        {
                            surface.DrawTextLayout(textLayout, new Point(segLeft, segCursorY));
                        }
                        else if (segment.NonTextBlock is { } nonTextBlock && imageRenderer is not null)
                        {
                            // S9-C: an image/vector/unsupported-placeholder or a nested table
                            // living INSIDE a table cell used to be silently dropped by
                            // BuildCellLayout (it only ever read Kind == Text out of
                            // cell.Content) — real docx/hwp corpora embed pictures and
                            // sub-tables inside cells routinely (measured: 10 images-in-cells
                            // in one investment-memo docx, 8 nested tables in one hwpx IR form),
                            // so flow mode was missing content in the MIDDLE of the document,
                            // not just clipping its end. Drawn here through the SAME
                            // ImageBlockRenderer.Draw/PictureGeometry.Measure pair the top-level
                            // flow already uses (see BuildCellContent), so reserved and drawn
                            // height can never disagree (invariant 46's own rule, extended into
                            // a cell).
                            if (nonTextBlock.Kind == FlowBlockKind.Image)
                            {
                                imageRenderer.Draw(surface, nonTextBlock, segLeft, segCursorY, cellWidth, indentPx: 0);
                            }
                            else if (nonTextBlock.Kind == FlowBlockKind.Table && nonTextBlock.Table is not null)
                            {
                                Draw(surface, nonTextBlock.Table, segLeft, segCursorY, cellWidth, fontScale,
                                    double.NegativeInfinity, double.PositiveInfinity, cachedRowHeights: null,
                                    out _, rowIndicesToDraw: null, imageRenderer: imageRenderer);
                            }
                        }
                        segCursorY += segment.Height;
                    }
                }

                DrawCellBorders(surface, cell, model, rect);
            }
        }

        rowHeightsOut = rowHeights;
        return totalHeight;
    }

    private static readonly Dictionary<int, int[]> DefaultRowOrderCache = new();

    /// <summary>0..rowCount-1 in order — cached per count since it never varies for a given table
    /// (avoids an allocation on every single-table Draw call, the overwhelmingly common case).</summary>
    private static int[] DefaultRowOrder(int rowCount)
    {
        if (DefaultRowOrderCache.TryGetValue(rowCount, out var cached)) { return cached; }
        var order = new int[rowCount];
        for (var i = 0; i < rowCount; i++) { order[i] = i; }
        DefaultRowOrderCache[rowCount] = order;
        return order;
    }

    /// <summary>E2c-2b: the SAME real, per-cell <see cref="TextLayout"/> row-height measurement
    /// <see cref="Draw"/> uses when it has no valid cache — extracted as its own entry point (SLAP:
    /// measurement separated from painting) so pagination (<c>PageLayout</c>) and table settle
    /// (<c>TableSettle</c>) can get the TRUE row heights instead of a character-count guess, and so
    /// all three (layout, settle, draw) can share ONE cache keyed the same way. Returns heights in
    /// POINTS at <paramref name="columnWidthPoints"/> — internally measures in pixels (the unit
    /// every other TextLayout call in this file already uses, including the per-cell padding
    /// resolved by <see cref="VerticalPaddingPx"/>/<see cref="HorizontalPaddingPx"/>, neither of
    /// which is itself scaled by fontScale) and converts back, rather than running the pixel-shaped
    /// formulas at `fontScale = 1/PointsToPixels`, which would have left that padding term in the
    /// wrong unit.</summary>
    public static double[] MeasureRowHeightsPoints(TableGridModel model, double columnWidthPoints, ImageBlockRenderer? imageRenderer = null)
    {
        if (model.Rows.Count == 0) { return Array.Empty<double>(); }
        var widthsPx = ResolveColumnWidths(model, columnWidthPoints * PointsToPixels);
        var rowCount = model.Rows.Count;
        var rowIndexByRowNumber = new Dictionary<uint, int>(rowCount);
        for (var i = 0; i < rowCount; i++) { rowIndexByRowNumber[model.Rows[i].Row] = i; }
        var cellLayouts = new Dictionary<TableGridCell, (List<CellSegment> Segments, double Height)>();
        var heightsPx = MeasureAllRows(model, widthsPx, rowIndexByRowNumber, rowCount, fontScale: 1.0, cellLayouts, imageRenderer);
        var heightsPt = new double[heightsPx.Length];
        for (var i = 0; i < heightsPx.Length; i++) { heightsPt[i] = heightsPx[i] / PointsToPixels; }
        return heightsPt;
    }

    /// <summary>The full two-pass measurement this renderer always did before E3's row cache: every
    /// cell gets a real TextLayout so its true height is known, rowSpan==1 cells set their row's
    /// height directly (pass 1), then a rowSpan&gt;1 cell that needs more room than the rows it
    /// covers already have gets the excess split evenly across those rows (pass 2). Runs exactly
    /// once per table per width/zoom — its result is what the caller caches and passes back in.</summary>
    private static double[] MeasureAllRows(
        TableGridModel model,
        double[] widths,
        Dictionary<uint, int> rowIndexByRowNumber,
        int rowCount,
        double fontScale,
        Dictionary<TableGridCell, (List<CellSegment> Segments, double Height)> cellLayouts,
        ImageBlockRenderer? imageRenderer = null)
    {
        var rowHeights = new double[rowCount];

        foreach (var row in model.Rows)
        {
            if (!rowIndexByRowNumber.TryGetValue(row.Row, out var rowIndex)) { continue; }
            foreach (var cell in row.Cells)
            {
                var cellWidth = Math.Max(10, SpanWidth(widths, (int)cell.Column, (int)cell.ColumnSpan) - HorizontalPaddingPx(cell, model));
                var (segments, height) = BuildCellContent(cell, cellWidth, fontScale, model, imageRenderer);
                cellLayouts[cell] = (segments, height);
                if (cell.RowSpan <= 1)
                {
                    double need;
                    if (segments.Count == 0 && cell.DeclaredHeight is > 0)
                    {
                        // TableBlockBuilder.decorativeBand (invariants 161(a)/94-97): an EMPTY cell
                        // whose row declares a height IS that height outright — the declaration
                        // already accounts for both paddings and the line, so it replaces the
                        // padding+line sum rather than adding to it (a band drawn as a thin colour
                        // rule stays that thin instead of gaining two more 7pt paddings).
                        need = cell.DeclaredHeight.Value * PointsToPixels;
                    }
                    else
                    {
                        need = height + VerticalPaddingPx(cell, model);
                        // TableBlockBuilder.singleLineRowFloor (invariant 166): a NON-empty,
                        // UNWRAPPED single-line cell in a row that declares a height (docx
                        // `w:trHeight`) is held to at least that height — never HWP's per-cell
                        // height, which this wire never carries as `minimumRowHeight` for HWP.
                        // S9-C: only when the cell's WHOLE content is that one text segment (a
                        // cell that also carries an image/nested-table segment is no longer the
                        // single-line case this floor exists for).
                        var singleTextSegment = segments.Count == 1 && segments[0].TextLayout is { TextLines.Count: <= 1 };
                        if (singleTextSegment && cell.MinimumRowHeight is > 0)
                        {
                            need = Math.Max(need, cell.MinimumRowHeight.Value * PointsToPixels);
                        }
                    }
                    if (need > rowHeights[rowIndex]) { rowHeights[rowIndex] = need; }
                }
            }
        }
        // A row with literally no cells at all (a gap in the grid, not a document-declared empty
        // cell — those are handled above via DeclaredHeight) still needs to exist: one line of the
        // document's own default body size (invariant 169), never a hardcoded 14pt guess.
        var baseRowHeight = EmptyCellLineHeightPx(model, fontScale) + TablePaddingPx(model);
        for (var i = 0; i < rowCount; i++)
        {
            if (rowHeights[i] <= 0) { rowHeights[i] = baseRowHeight; }
        }

        foreach (var row in model.Rows)
        {
            if (!rowIndexByRowNumber.TryGetValue(row.Row, out var rowIndex)) { continue; }
            foreach (var cell in row.Cells)
            {
                if (cell.RowSpan <= 1) { continue; }
                var span = (int)Math.Min(cell.RowSpan, rowCount - rowIndex);
                if (span <= 0) { continue; }
                var covered = 0.0;
                for (var r = rowIndex; r < rowIndex + span; r++) { covered += rowHeights[r]; }
                var need = cellLayouts[cell].Height + VerticalPaddingPx(cell, model);
                if (need > covered)
                {
                    var extra = (need - covered) / span;
                    for (var r = rowIndex; r < rowIndex + span; r++) { rowHeights[r] += extra; }
                }
            }
        }

        return rowHeights;
    }

    /// <summary>One vertically-stacked piece of a cell's content — either a built
    /// <see cref="TextLayout"/> spanning one contiguous run of Text-kind <see cref="FlowBlock"/>s,
    /// or a reference to a non-text <see cref="FlowBlock"/> (Image/Vector/Unsupported-placeholder,
    /// Kind == Image; or a nested Table) drawn separately — see <see cref="BuildCellContent"/>'s
    /// own doc for why this split exists.</summary>
    private readonly record struct CellSegment(TextLayout? TextLayout, double Height, FlowBlock? NonTextBlock);

    /// <summary>Walks <paramref name="cell"/>'s content in DOCUMENT ORDER, building one
    /// <see cref="TextLayout"/> per contiguous run of Text-kind blocks and, when <paramref
    /// name="imageRenderer"/> is supplied, a separate measured <see cref="CellSegment"/> for every
    /// Image/Vector/Unsupported-placeholder or nested-Table block found in between — a cell's
    /// pictures and nested tables are ordinary content, not a special case, and both flow mode
    /// (<see cref="FlowDocumentView"/>) and page mode (<see cref="Paging.PageModePainter"/>, via
    /// <see cref="Paging.TableSettle"/>/<see cref="Paging.PageLayout"/>) pass their own
    /// <see cref="ImageBlockRenderer"/> here so a picture or sub-table nested in a cell reserves
    /// height and draws identically in either mode. <paramref name="imageRenderer"/> stays an
    /// OPTIONAL parameter only so a caller that genuinely wants text-only measurement (a probe, a
    /// test fixture with no renderer to hand) can still ask for one — passing null there returns a
    /// segment list that ignores image/nested-table content entirely, both for height and for draw.
    /// Returns an empty segment list (with <see cref="EmptyCellLineHeightPx"/> as height) only when
    /// the cell has NO content of any kind — a cell holding an image or nested table is never
    /// "empty" even though it has no text.</summary>
    private static (List<CellSegment> Segments, double Height) BuildCellContent(
        TableGridCell cell, double width, double fontScale, TableGridModel model, ImageBlockRenderer? imageRenderer)
    {
        var segments = new List<CellSegment>();
        double totalHeight = 0;

        // S9-C mutation-review fix: the only place totalHeight advances is here, reading the
        // segment's OWN stored Height back out after adding it — so a bug that stores the wrong
        // Height on the segment (what Draw's cursor actually walks by) necessarily also breaks
        // this cell's measured height, instead of a local variable happening to agree with two
        // independently-written call sites. A prior version summed a local `segmentHeight`
        // variable directly and passed it to `new CellSegment(...)` a second time — mutating just
        // the CellSegment's stored Height to 0 left EstimateHeight's total untouched, and no test
        // caught it: the cell measured correctly while Draw's cursor no longer advanced, so the
        // NEXT segment painted on top of this one instead of below it (exactly the "content
        // invisible" symptom this sprint exists to fix, just relocated one segment later).
        void AddSegment(CellSegment segment)
        {
            segments.Add(segment);
            totalHeight += segment.Height;
        }

        var text = new System.Text.StringBuilder();
        var overrides = new List<ValueSpan<TextRunProperties>>();
        var cursor = 0;
        // Bootstrap only — every run below overwrites this with its OWN declared size the moment
        // one exists; a cell with no runs at all returns before this value is ever used to lay
        // anything out. The document's own default body size, never a bare "12".
        var maxFontSizePx = model.DefaultBodyFontSizePoints * PointsToPixels * fontScale;
        var alignment = TextAlignment.Left;
        var firstText = true;

        void FlushTextRun()
        {
            if (text.Length == 0) { return; }
            var content = text.ToString();
            if (content.EndsWith('\n')) { content = content[..^1]; }
            if (content.Length > 0)
            {
                var layout = new TextLayout(content, DefaultTypeface, maxFontSizePx, Brushes.Black, alignment,
                    TextWrapping.Wrap, maxWidth: Math.Max(10, width), textStyleOverrides: overrides);
                AddSegment(new CellSegment(layout, layout.Height, null));
            }
            text.Clear();
            overrides = new List<ValueSpan<TextRunProperties>>();
            cursor = 0;
            firstText = true;
        }

        foreach (var block in cell.Content)
        {
            if (block.Kind == FlowBlockKind.Text)
            {
                if (firstText) { alignment = block.Alignment; firstText = false; }
                foreach (var run in block.Runs)
                {
                    if (run.Text.Length == 0) { continue; }
                    text.Append(run.Text);
                    var fontSizePx = run.FontSizePoints * fontScale * PointsToPixels;
                    if (fontSizePx > maxFontSizePx) { maxFontSizePx = fontSizePx; }
                    var typeface = new Typeface(run.FontFamily ?? "Inter",
                        run.Italic ? FontStyle.Italic : FontStyle.Normal,
                        run.Bold ? FontWeight.Bold : FontWeight.Normal);
                    TextDecorationCollection? decorations = null;
                    if (run.Underline) { decorations = TextDecorations.Underline; }
                    else if (run.Strike) { decorations = TextDecorations.Strikethrough; }
                    var props = new GenericTextRunProperties(typeface, fontSizePx,
                        textDecorations: decorations, foregroundBrush: new SolidColorBrush(run.Foreground));
                    overrides.Add(new ValueSpan<TextRunProperties>(cursor, run.Text.Length, props));
                    cursor += run.Text.Length;
                }
                text.Append('\n');
                cursor += 1;
                continue;
            }

            if (imageRenderer is null) { continue; } // caller only needs a height — see this method's own doc.

            if (block.Kind == FlowBlockKind.Image)
            {
                FlushTextRun();
                var maxWidthPoints = width / PointsToPixels;
                var (declaredWidthPoints, declaredHeightPoints) = imageRenderer.EffectiveDeclaredSize(block);
                var (_, imageHeightPoints) = PictureGeometry.Measure(declaredWidthPoints, declaredHeightPoints, maxWidthPoints);
                var segmentHeight = imageHeightPoints * PointsToPixels
                    + (block.SpacingBeforePoints + block.SpacingAfterPoints) * PointsToPixels;
                AddSegment(new CellSegment(null, segmentHeight, block));
            }
            else if (block.Kind == FlowBlockKind.Table && block.Table is not null)
            {
                FlushTextRun();
                var segmentHeight = EstimateHeight(block.Table, width, fontScale, imageRenderer)
                    + (block.SpacingBeforePoints + block.SpacingAfterPoints) * PointsToPixels;
                AddSegment(new CellSegment(null, segmentHeight, block));
            }
            // Rule/other rare kinds inside a cell: no reserved role today, same as before this fix.
        }
        FlushTextRun();

        if (segments.Count == 0) { return (segments, EmptyCellLineHeightPx(model, fontScale)); }
        return (segments, totalHeight);
    }

    private static double[] ResolveColumnWidths(TableGridModel model, double columnWidth)
    {
        var count = Math.Max(1, model.ColumnCount);
        var widths = new double[count];
        var ratios = model.ColumnWidthRatios;
        if (ratios.Count == count)
        {
            double sum = 0;
            foreach (var r in ratios) { sum += Math.Max(0, r); }
            if (sum > 0)
            {
                for (var i = 0; i < count; i++) { widths[i] = Math.Max(0, ratios[i]) / sum * columnWidth; }
                return widths;
            }
        }
        var equal = columnWidth / count;
        for (var i = 0; i < count; i++) { widths[i] = equal; }
        return widths;
    }

    private static double SpanWidth(double[] widths, int startColumn, int span)
    {
        double w = 0;
        var end = Math.Min(widths.Length, startColumn + Math.Max(1, span));
        for (var i = Math.Max(0, startColumn); i < end; i++) { w += widths[i]; }
        return w;
    }

    private static Color? ResolveShading(TableGridCell cell, TableGridModel model)
    {
        var wire = cell.Shading ?? model.DefaultShading;
        if (wire is null) { return null; }
        return ColorFrom(wire);
    }

    private static Color ColorFrom(ColorWire wire)
    {
        byte Clamp(double v) => (byte)Math.Clamp(v * 255.0, 0, 255);
        return Color.FromArgb(Clamp(wire.Alpha), Clamp(wire.Red), Clamp(wire.Green), Clamp(wire.Blue));
    }

    private static void DrawCellBorders(IPageCanvas surface, TableGridCell cell, TableGridModel model, Rect rect)
    {
        DrawEdge(surface, rect, Edge.Top, ResolveEdge(cell, model, e => e.Top));
        DrawEdge(surface, rect, Edge.Right, ResolveEdge(cell, model, e => e.Right));
        DrawEdge(surface, rect, Edge.Bottom, ResolveEdge(cell, model, e => e.Bottom));
        DrawEdge(surface, rect, Edge.Left, ResolveEdge(cell, model, e => e.Left));
    }

    private enum Edge { Top, Right, Bottom, Left }

    /// <summary>Resolves ONE edge's line: the cell's own per-edge declaration (Suppressed draws
    /// nothing at all — a document that silenced this edge is told apart from one that never
    /// mentioned it, INVARIANTS.md 47), else the cell's uniform border, else the table's per-edge
    /// declaration, else the table's default uniform border, else a sane default line so a table
    /// the document left fully undeclared still reads as a grid.</summary>
    private static (bool Draw, double WidthPx, Color Color, string Style)? ResolveEdge(
        TableGridCell cell, TableGridModel model, Func<BorderSetWire, BorderDeclarationWire?> pick)
    {
        var cellEdge = cell.EdgeBorders is null ? null : pick(cell.EdgeBorders);
        if (cellEdge is not null)
        {
            if (cellEdge.IsSuppressed) { return null; }
            return FromDrawn(cellEdge.Value);
        }
        if (cell.UniformBorder is not null)
        {
            return FromUniform(cell.UniformBorder);
        }
        var tableEdge = model.TableEdgeBorders is null ? null : pick(model.TableEdgeBorders);
        if (tableEdge is not null)
        {
            if (tableEdge.IsSuppressed) { return null; }
            return FromDrawn(tableEdge.Value);
        }
        if (model.DefaultUniformBorder is not null)
        {
            return FromUniform(model.DefaultUniformBorder);
        }
        return (true, DefaultBorderWidthPx, ((SolidColorBrush)DefaultBorderBrush).Color, "solid");
    }

    private static (bool, double, Color, string)? FromDrawn(DrawnBorderWire? drawn)
    {
        if (drawn is null) { return null; }
        var color = drawn.Color is null ? ((SolidColorBrush)DefaultBorderBrush).Color : ColorFrom(drawn.Color);
        var widthPx = Math.Max(0.5, drawn.WidthPoints * PointsToPixels);
        return (true, widthPx, color, drawn.Style);
    }

    private static (bool, double, Color, string)? FromUniform(UniformBorderWire uniform)
    {
        var color = uniform.Color is null ? ((SolidColorBrush)DefaultBorderBrush).Color : ColorFrom(uniform.Color);
        var widthPx = Math.Max(0.5, (uniform.WidthPoints ?? 0.75) * PointsToPixels);
        return (true, widthPx, color, "solid");
    }

    private static void DrawEdge(IPageCanvas surface, Rect rect, Edge edge, (bool Draw, double WidthPx, Color Color, string Style)? resolved)
    {
        if (resolved is null || !resolved.Value.Draw) { return; }
        var (p1, p2) = edge switch
        {
            Edge.Top => (rect.TopLeft, rect.TopRight),
            Edge.Right => (rect.TopRight, rect.BottomRight),
            Edge.Bottom => (rect.BottomLeft, rect.BottomRight),
            _ => (rect.TopLeft, rect.BottomLeft),
        };
        surface.DrawLine(p1, p2, resolved.Value.Color, resolved.Value.WidthPx);
    }
}
