using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Avalonia;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Media.TextFormatting;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Paging;
using FastDoc.Avalonia.Printing;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>Regression tests for S10-A: page mode (<see cref="PageModePainter"/>, via
/// <see cref="TableSettle"/>/<see cref="PageLayout"/>) did not reserve height for, or draw, a
/// picture or a nested table living inside a table cell — S9-C had already fixed the identical gap
/// for FLOW mode but deliberately left page mode on its pre-fix behaviour (see
/// docs/studio/sprints/S9/s9c-flow-content.md's own "의도적으로 범위를 좁힌 부분"). Root cause was
/// two independent gaps on the page-mode side: <see cref="PageModePainter.Draw"/>'s own call into
/// <see cref="TableGridRenderer.Draw"/> never passed an <see cref="ImageBlockRenderer"/> at all, and
/// <see cref="TableGridRenderer.MeasureRowHeightsPoints"/> (the pagination/settle measurement path)
/// had no parameter to accept one even if a caller wanted to supply it. Measured against
/// testdocs/everything/GnBS_IM_20260401.docx: flow mode draws all 6 pictures in its 2x3
/// picture-table, page mode drew two ~10px empty rows.</summary>
public class S10APageCellsTests
{
    public S10APageCellsTests() => AvaloniaHeadlessSetup.EnsureReady();

    private sealed class RecordingCanvas : IPageCanvas
    {
        public int RectCount;
        public int ImageCount;
        public int LineCount;
        public List<Rect> Rects { get; } = new();

        public void DrawRect(Rect rect, Color? fill, Color? stroke, double strokeThicknessPx) { RectCount++; Rects.Add(rect); }
        public void DrawLine(Point a, Point b, Color color, double thicknessPx) { LineCount++; }
        public void DrawImage(Bitmap bitmap, byte[]? sourceBytes, string? sourceMimeType, Rect destRect) { ImageCount++; }
        public void DrawTextLayout(TextLayout layout, Point origin) { }
        public void DrawTextLine(TextLine line, Point origin) { }
    }

    private static FlowRun Run(string text) => new(text, null, 12, false, false, false, false, Colors.Black);

    private static FlowBlock TextBlock(string text) => new()
    {
        Kind = FlowBlockKind.Text,
        Runs = new List<FlowRun> { Run(text) },
    };

    /// <summary>A one-row, one-column table whose only cell holds <paramref name="cellContent"/> —
    /// mirrors S9CFlowContentTests' own fixture so both files exercise the same shape.</summary>
    private static TableGridModel OneCellTable(List<FlowBlock> cellContent) => new()
    {
        ColumnWidthRatios = new List<double> { 1.0 },
        ColumnCount = 1,
        DefaultBodyFontSizePoints = 12,
        Rows = new List<TableGridRow>
        {
            new()
            {
                Row = 0,
                Cells = new List<TableGridCell>
                {
                    new() { Row = 0, Column = 0, Content = cellContent },
                },
            },
        },
    };

    private static BlockPageMarkers.Markers EmptyMarkers() =>
        new(Array.Empty<bool>(), Array.Empty<bool>(), Array.Empty<bool>(), Array.Empty<bool>());

    private static PageGeometry SimpleGeometry(double widthPt = 400, double heightPt = 700, double marginPt = 20) => new()
    {
        PageWidthPoints = widthPt,
        PageHeightPoints = heightPt,
        MarginTopPoints = marginPt,
        MarginBottomPoints = marginPt,
        MarginLeftPoints = marginPt,
        MarginRightPoints = marginPt,
    };

    // ---- (a) MeasureRowHeightsPoints (the pagination/settle measurement) reserves height for a ----
    // ---- cell image only when given a renderer — before this fix it had no parameter at all. -----

    [Fact]
    public void MeasureRowHeightsPoints_with_a_renderer_reserves_more_height_for_a_cell_holding_an_image_than_without()
    {
        var imageOnly = new FlowBlock { Kind = FlowBlockKind.Image, ImageWidthPoints = 300, ImageHeightPoints = 200 };
        var table = OneCellTable(new List<FlowBlock> { imageOnly });
        var renderer = new ImageBlockRenderer();

        var heightsWithRenderer = TableGridRenderer.MeasureRowHeightsPoints(table, columnWidthPoints: 400, imageRenderer: renderer);
        var heightsWithoutRenderer = TableGridRenderer.MeasureRowHeightsPoints(table, columnWidthPoints: 400, imageRenderer: null);

        Assert.Single(heightsWithRenderer);
        Assert.Single(heightsWithoutRenderer);
        // 200pt tall is roughly 200pt in the row's own points (converted back from the 96dpi pixel
        // measurement) — a bare empty-cell line is nowhere near that, so a >100pt gap is the whole
        // picture's height either reserved or missing, not a rounding difference.
        Assert.True(heightsWithRenderer[0] > heightsWithoutRenderer[0] + 100,
            $"expected the image's own height to be reserved in points; withRenderer={heightsWithRenderer[0]} withoutRenderer={heightsWithoutRenderer[0]}");
    }

    // ---- (b) page-mode Draw actually paints the cell image (placeholder rect, since this ----------
    // ---- fixture's image has no resolvable resource — same technique S9CFlowContentTests uses ----
    // ---- to verify flow-mode drawing). --------------------------------------------------------

    [Fact]
    public void Page_mode_draw_paints_a_cell_image_as_a_placeholder_rect_when_no_bitmap_resolves()
    {
        var imageOnly = new FlowBlock { Kind = FlowBlockKind.Image, ImageWidthPoints = 300, ImageHeightPoints = 200 };
        var tableBlock = new FlowBlock { Kind = FlowBlockKind.Table, Table = OneCellTable(new List<FlowBlock> { imageOnly }) };
        var blocks = new List<FlowBlock> { tableBlock };
        var geometry = SimpleGeometry();
        var markers = EmptyMarkers();
        var layout = PageLayout.Build(blocks, markers, geometry, IntPtr.Zero, headersOn: false, footersOn: false,
            imageRenderer: new ImageBlockRenderer());
        Assert.Equal(1, layout.PageCount);

        var renderer = new ImageBlockRenderer();
        var painter = new PageModePainter(renderer);
        var canvas = new RecordingCanvas();
        var tree = new RenderTree();

        painter.Draw(canvas, blocks, tree, layout, geometry, zoomFactor: 1.0,
            viewportWidthPx: painter.PageWidthPx(geometry, 1.0), viewportHeightPx: painter.PageHeightPx(geometry, 1.0),
            scrollOffsetPx: 0, markers, masterPageFurniture: false);

        Assert.True(canvas.RectCount >= 1, "expected the cell image's placeholder rect to be drawn in page mode");
    }

    // ---- (c) a nested table inside a cell is measured (adds height) and drawn (recursive Draw) ---
    // ---- in page mode. -------------------------------------------------------------------------

    [Fact]
    public void MeasureRowHeightsPoints_with_a_renderer_reserves_height_for_a_nested_table_inside_a_cell()
    {
        var nested = OneCellTable(new List<FlowBlock> { TextBlock("row one") });
        nested.Rows.Add(new TableGridRow
        {
            Row = 1,
            Cells = new List<TableGridCell> { new() { Row = 1, Column = 0, Content = new List<FlowBlock> { TextBlock("row two") } } },
        });
        var nestedBlock = new FlowBlock { Kind = FlowBlockKind.Table, Table = nested };
        var outer = OneCellTable(new List<FlowBlock> { nestedBlock });
        var empty = OneCellTable(new List<FlowBlock>());
        var renderer = new ImageBlockRenderer();

        var heightsWithNested = TableGridRenderer.MeasureRowHeightsPoints(outer, columnWidthPoints: 400, imageRenderer: renderer);
        var heightsEmpty = TableGridRenderer.MeasureRowHeightsPoints(empty, columnWidthPoints: 400, imageRenderer: renderer);

        Assert.Single(heightsWithNested);
        Assert.Single(heightsEmpty);
        Assert.True(heightsWithNested[0] > heightsEmpty[0],
            $"expected the nested table's two rows to add height; withNested={heightsWithNested[0]} empty={heightsEmpty[0]}");
    }

    [Fact]
    public void Page_mode_draw_recurses_into_a_nested_table_inside_a_cell()
    {
        var nested = OneCellTable(new List<FlowBlock> { TextBlock("nested cell text") });
        var nestedBlock = new FlowBlock { Kind = FlowBlockKind.Table, Table = nested };
        var outer = OneCellTable(new List<FlowBlock> { TextBlock("outer text before"), nestedBlock });
        var tableBlock = new FlowBlock { Kind = FlowBlockKind.Table, Table = outer };
        var blocks = new List<FlowBlock> { tableBlock };
        var geometry = SimpleGeometry();
        var markers = EmptyMarkers();
        var layout = PageLayout.Build(blocks, markers, geometry, IntPtr.Zero, headersOn: false, footersOn: false,
            imageRenderer: new ImageBlockRenderer());

        var renderer = new ImageBlockRenderer();
        var painter = new PageModePainter(renderer);
        var canvas = new RecordingCanvas();
        var tree = new RenderTree();

        painter.Draw(canvas, blocks, tree, layout, geometry, zoomFactor: 1.0,
            viewportWidthPx: painter.PageWidthPx(geometry, 1.0), viewportHeightPx: painter.PageHeightPx(geometry, 1.0),
            scrollOffsetPx: 0, markers, masterPageFurniture: false);

        // Each one-cell table draws its own 4 border edges (DrawCellBorders). Getting 8 (outer +
        // nested) proves the recursive TableGridRenderer.Draw call actually ran in page mode, not
        // merely that the outer cell's own text was painted — the same proof S9CFlowContentTests
        // uses for the identical shape in flow mode.
        Assert.Equal(8, canvas.LineCount);
    }

    // ---- (d) regression guard: the real GnBS docx's 2x3 picture table reserves real row height ---
    // ---- in the paged measurement, not the empty-row floor. -------------------------------------

    private static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "CLAUDE.md")))
        {
            dir = dir.Parent;
        }
        return dir?.FullName ?? throw new InvalidOperationException("could not find repo root (no CLAUDE.md in any parent directory)");
    }

    private static void CollectAllTables(List<FlowBlock> blocks, List<TableGridModel> outList)
    {
        foreach (var b in blocks)
        {
            if (b.Kind != FlowBlockKind.Table || b.Table is null) { continue; }
            outList.Add(b.Table);
            foreach (var row in b.Table.Rows)
            foreach (var cell in row.Cells) { CollectAllTables(cell.Content, outList); }
        }
    }

    private static int CountCellImages(TableGridModel table) =>
        table.Rows.SelectMany(r => r.Cells).SelectMany(c => c.Content).Count(b => b.Kind == FlowBlockKind.Image);

    private static ImageBlockRenderer BoundRenderer(LoadResult result, string path)
    {
        var renderer = new ImageBlockRenderer();
        renderer.Reset(result.Tree);
        renderer.SetHandle(result.Handle);
        renderer.SetZipSource(path, Path.GetExtension(path));
        return renderer;
    }

    [Fact]
    public void Real_document_2x3_picture_table_row_heights_exceed_the_empty_row_floor_in_the_paged_measurement()
    {
        var repoRoot = FindRepoRoot();
        var engineLib = Path.Combine(repoRoot, "rust", "dist", "xplat", "macos-arm64", "libfastdoc_engine_ffi.dylib");
        if (!File.Exists(engineLib))
        {
            throw new InvalidOperationException($"engine library not found at {engineLib} — build it with Scripts/build-engine-xplat.sh first.");
        }
        Environment.SetEnvironmentVariable("FASTDOC_ENGINE_LIB", engineLib);
        var path = Path.Combine(repoRoot, "testdocs", "everything", "GnBS_IM_20260401.docx");
        Assert.True(File.Exists(path), $"fixture missing: {path}");

        var result = RenderTreeLoader.Load(path);
        try
        {
            Assert.True(result.IsOk, $"load failed: {result.Error?.Kind} {result.Error?.Message}");
            var blocks = FlowDocumentBuilder.Build(result.Tree!);
            var allTables = new List<TableGridModel>();
            CollectAllTables(blocks, allTables);

            // The 2x3 picture table this sprint's owner report names (docs/studio/sprints/S10/
            // s10a-page-cells.md §증상): 2 rows, 3 columns, 6 images spread across its cells.
            var pictureTable = allTables.FirstOrDefault(t => t.Rows.Count == 2 && t.ColumnCount == 3 && CountCellImages(t) == 6);
            Assert.True(pictureTable is not null,
                "could not find the 2-row/3-column, 6-picture table by shape — the document may have drifted");

            const double columnWidthPoints = 460;
            var renderer = BoundRenderer(result, path);
            var heightsWithImages = TableGridRenderer.MeasureRowHeightsPoints(pictureTable!, columnWidthPoints, renderer);

            // Baseline: the SAME table shape with every image cell emptied out, so the comparison
            // isolates the image reservation from this table's own padding/border/font choices
            // rather than comparing against an unrelated one-cell fixture.
            var emptyShape = new TableGridModel
            {
                ColumnWidthRatios = pictureTable!.ColumnWidthRatios,
                ColumnCount = pictureTable.ColumnCount,
                DefaultBodyFontSizePoints = pictureTable.DefaultBodyFontSizePoints,
                Rows = pictureTable.Rows.Select(row => new TableGridRow
                {
                    Row = row.Row,
                    Header = row.Header,
                    Cells = row.Cells.Select(cell => new TableGridCell
                    {
                        Row = cell.Row,
                        Column = cell.Column,
                        RowSpan = cell.RowSpan,
                        ColumnSpan = cell.ColumnSpan,
                        Content = new List<FlowBlock>(),
                    }).ToList(),
                }).ToList(),
            };
            var heightsEmpty = TableGridRenderer.MeasureRowHeightsPoints(emptyShape, columnWidthPoints, renderer);

            Assert.Equal(heightsWithImages.Length, heightsEmpty.Length);
            for (var i = 0; i < heightsWithImages.Length; i++)
            {
                Assert.True(heightsWithImages[i] > heightsEmpty[i],
                    $"row {i}: expected the picture table's real row height ({heightsWithImages[i]:F1}pt) to exceed " +
                    $"the same shape with empty cells ({heightsEmpty[i]:F1}pt) — the pictures are not being reserved");
            }
        }
        finally
        {
            result.Handle?.Dispose();
        }
    }

    // ---- page-count before/after table, for the sprint report ----------------------------------

    private static readonly (string RelPath, string Format)[] PageCountDocs =
    {
        ("everything/GnBS_IM_20260401.docx", "docx"),
        ("mini/s9-picture-crop.hwp", "hwp"),
        ("small/인감_개인신고서_김태형.docx", "docx"),
        ("small/사업계획서_IR참가신청.hwpx", "hwpx"),
        ("everything/1790387_prep_final_report.hwpx", "hwpx"),
    };

    /// <summary>Not a bug-regression guard by itself — it is the sprint report's own before/after
    /// table, pinned as a test so the numbers stay honest if the corpus or the fix changes later.
    /// "Before" re-runs the SAME real document through the SAME paginator with <c>imageRenderer:
    /// null</c> — exactly what every page-mode caller passed before this sprint. A page count is
    /// NOT guaranteed to only grow: <see cref="TableSettle"/>'s push/oversized-row-break loop
    /// re-solves against the new (larger) row heights, and a table that used to be pushed to a
    /// fresh page (or split at different rows) at the OLD heights can settle differently at the
    /// NEW ones — measured here on <c>1790387_prep_final_report.hwpx</c> (208 → 207). That is the
    /// settle algorithm re-converging on a different, still-valid layout, not a defect in the
    /// height reservation itself (§4's per-row assertion is what actually pins the reservation).
    /// This test only pins that pagination still completes with at least one page either way.</summary>
    [Theory]
    [MemberData(nameof(PageCountDocIndexes))]
    public void Page_count_before_and_after_reserving_cell_image_and_nested_table_height(int docIndex)
    {
        var (relPath, _) = PageCountDocs[docIndex];
        var repoRoot = FindRepoRoot();
        var engineLib = Path.Combine(repoRoot, "rust", "dist", "xplat", "macos-arm64", "libfastdoc_engine_ffi.dylib");
        if (!File.Exists(engineLib))
        {
            throw new InvalidOperationException($"engine library not found at {engineLib} — build it with Scripts/build-engine-xplat.sh first.");
        }
        Environment.SetEnvironmentVariable("FASTDOC_ENGINE_LIB", engineLib);
        var path = Path.Combine(repoRoot, "testdocs", relPath);
        Assert.True(File.Exists(path), $"fixture missing: {path}");

        var result = RenderTreeLoader.Load(path);
        try
        {
            Assert.True(result.IsOk, $"load failed: {result.Error?.Kind} {result.Error?.Message}");
            var geometry = PageGeometry.FromDocument(result.Tree!);
            if (geometry is null)
            {
                // No declared page geometry (plain markdown/text shape) — page mode does not apply,
                // nothing for this fix to change.
                return;
            }
            var blocks = FlowDocumentBuilder.Build(result.Tree!);
            var markers = BlockPageMarkers.Compute(result.Tree!);
            var handle = result.Handle?.RawHandle ?? IntPtr.Zero;

            var (before, _, _, _) = PageLayout.BuildWithTableSettle(blocks, markers, geometry, handle,
                headersOn: true, footersOn: true, splitTablesDefault: true, imageRenderer: null);
            var renderer = BoundRenderer(result, path);
            var (after, _, _, _) = PageLayout.BuildWithTableSettle(blocks, markers, geometry, handle,
                headersOn: true, footersOn: true, splitTablesDefault: true, imageRenderer: renderer);

            Console.WriteLine($"S10-A page-count {relPath}: before={before.PageCount} after={after.PageCount}");
            Assert.True(before.PageCount > 0 && after.PageCount > 0,
                $"{relPath}: expected pagination to complete with at least one page both before and after; before={before.PageCount} after={after.PageCount}");
        }
        finally
        {
            result.Handle?.Dispose();
        }
    }

    public static IEnumerable<object[]> PageCountDocIndexes()
    {
        for (var i = 0; i < PageCountDocs.Length; i++) { yield return new object[] { i }; }
    }

    // ---- mutation-review follow-ups (lead, 2026-09-06): the two tests above never exercised -----
    // ---- the WIRING that carries the fix into the real doors — PageLayout.BuildWithTableSettle --
    // ---- (TableSettle.cs's own call into MeasureRowHeightsPoints) and FlowDocumentView's ----------
    // ---- EnsurePageLayout. Mutating either call site's `imageRenderer` argument to `null` left ---
    // ---- every existing test green because the page-count theory above only asserted ">= 1" and -
    // ---- no test drove FlowDocumentView.PageMode against a real document at all. -----------------

    private static string EngineLibOrThrow(string repoRoot)
    {
        var engineLib = Path.Combine(repoRoot, "rust", "dist", "xplat", "macos-arm64", "libfastdoc_engine_ffi.dylib");
        if (!File.Exists(engineLib))
        {
            throw new InvalidOperationException($"engine library not found at {engineLib} — build it with Scripts/build-engine-xplat.sh first.");
        }
        return engineLib;
    }

    /// <summary>The exact pair of real-document page counts §페이지 수 전후 비교 in this sprint's
    /// report measured through <see cref="PageLayout.BuildWithTableSettle"/> — the real pagination
    /// door every page-mode caller (FlowDocumentView, the headless --sheets CLI, --pdf) goes
    /// through, NOT <see cref="TableGridRenderer.MeasureRowHeightsPoints"/> directly (that door is
    /// already covered by the two MeasureRowHeightsPoints facts above). A mutation that dropped
    /// the <c>imageRenderer</c> argument anywhere between BuildWithTableSettle and
    /// MeasureRowHeightsPoints (TableSettle.EstimateRowHeights, TableSettle.BuildLaidOutTables,
    /// PageLayout.Build/NonTextBlockHeightPoints) would collapse BOTH numbers below to the "before"
    /// value, since "after" would then equal "before" byte-for-byte.</summary>
    [Theory]
    [InlineData("everything/GnBS_IM_20260401.docx", 33, 34)]
    [InlineData("small/인감_개인신고서_김태형.docx", 1, 2)]
    public void BuildWithTableSettle_page_count_matches_the_exact_before_and_after_pair(
        string relPath, int expectedBefore, int expectedAfter)
    {
        var repoRoot = FindRepoRoot();
        Environment.SetEnvironmentVariable("FASTDOC_ENGINE_LIB", EngineLibOrThrow(repoRoot));
        var path = Path.Combine(repoRoot, "testdocs", relPath);
        Assert.True(File.Exists(path), $"fixture missing: {path}");

        var result = RenderTreeLoader.Load(path);
        try
        {
            Assert.True(result.IsOk, $"load failed: {result.Error?.Kind} {result.Error?.Message}");
            var geometry = PageGeometry.FromDocument(result.Tree!);
            Assert.True(geometry is not null, $"{relPath}: expected declared page geometry — this fixture must be a paged document");

            var blocks = FlowDocumentBuilder.Build(result.Tree!);
            var allTables = new List<TableGridModel>();
            CollectAllTables(blocks, allTables);
            // Setup sanity: this comparison is meaningless if the document has no cell image or
            // nested table for the fix to reserve height for.
            var hasCellImageOrNestedTable = allTables.Any(t =>
                t.Rows.SelectMany(r => r.Cells).SelectMany(c => c.Content)
                    .Any(b => b.Kind == FlowBlockKind.Image || b.Kind == FlowBlockKind.Table));
            Assert.True(hasCellImageOrNestedTable, $"{relPath}: expected at least one table cell holding an image or a nested table");

            var markers = BlockPageMarkers.Compute(result.Tree!);
            var handle = result.Handle?.RawHandle ?? IntPtr.Zero;

            var (before, _, _, _) = PageLayout.BuildWithTableSettle(blocks, markers, geometry!, handle,
                headersOn: true, footersOn: true, splitTablesDefault: true, imageRenderer: null);
            var renderer = BoundRenderer(result, path);
            var (after, _, _, _) = PageLayout.BuildWithTableSettle(blocks, markers, geometry!, handle,
                headersOn: true, footersOn: true, splitTablesDefault: true, imageRenderer: renderer);

            Assert.Equal(expectedBefore, before.PageCount);
            Assert.Equal(expectedAfter, after.PageCount);
            Assert.NotEqual(before.PageCount, after.PageCount);
        }
        finally
        {
            result.Handle?.Dispose();
        }
    }

    /// <summary>Drives the fix through the ACTUAL GUI/export door — <see
    /// cref="FlowDocumentView.PageMode"/> — rather than calling PageLayout directly, so a mutation
    /// that dropped <c>imageRenderer: _imageRenderer</c> from EnsurePageLayout's own
    /// BuildWithTableSettle call (the exact line this sprint added it to) is caught here even if
    /// every PageLayout-level test still passes. Binds the view's <see cref="ImageBlockRenderer"/>
    /// the same way <see cref="Printing.PdfExporter.ExportPdf"/> does (SetHandle + SetZipSource)
    /// before turning page mode on, so this is the SAME sequence a real GUI open or a --pdf export
    /// runs.</summary>
    [Fact]
    public void FlowDocumentView_page_mode_export_page_count_equals_the_real_renderer_pagination_not_the_null_one()
    {
        var repoRoot = FindRepoRoot();
        Environment.SetEnvironmentVariable("FASTDOC_ENGINE_LIB", EngineLibOrThrow(repoRoot));
        var path = Path.Combine(repoRoot, "testdocs", "everything", "GnBS_IM_20260401.docx");
        Assert.True(File.Exists(path), $"fixture missing: {path}");

        var result = RenderTreeLoader.Load(path);
        try
        {
            Assert.True(result.IsOk, $"load failed: {result.Error?.Kind} {result.Error?.Message}");
            var geometry = PageGeometry.FromDocument(result.Tree!);
            Assert.True(geometry is not null, "expected declared page geometry for this fixture");

            // Independently-computed "after" (real renderer) and "before" (null) page counts,
            // exactly as the pinned-pair test above computes them — the expectation this view-level
            // test checks itself against, not a hardcoded literal repeated in two places.
            var blocks = FlowDocumentBuilder.Build(result.Tree!);
            var markers = BlockPageMarkers.Compute(result.Tree!);
            var handle = result.Handle?.RawHandle ?? IntPtr.Zero;
            var (beforeLayout, _, _, _) = PageLayout.BuildWithTableSettle(blocks, markers, geometry!, handle,
                headersOn: true, footersOn: true, splitTablesDefault: true, imageRenderer: null);
            var expectedNullCount = beforeLayout.PageCount;
            var renderer = BoundRenderer(result, path);
            var (afterLayout, _, _, _) = PageLayout.BuildWithTableSettle(blocks, markers, geometry!, handle,
                headersOn: true, footersOn: true, splitTablesDefault: true, imageRenderer: renderer);
            var expectedRealCount = afterLayout.PageCount;
            Assert.NotEqual(expectedNullCount, expectedRealCount); // setup sanity: this fixture must actually distinguish the two paths

            var view = new FlowDocumentView();
            view.SetTree(result.Tree);
            if (result.Handle is not null) { view.SetHandle(result.Handle); }
            view.SetZipSource(path, Path.GetExtension(path));
            view.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            view.PageMode = true; // EnsurePageLayout runs inside this setter (S10-A wiring under test)

            Assert.True(view.HasPageGeometry);
            Assert.Equal(expectedRealCount, view.ExportPageCount);
            Assert.NotEqual(expectedNullCount, view.ExportPageCount);
        }
        finally
        {
            result.Handle?.Dispose();
        }
    }

    // ---- lead follow-up (2026-09-06): 1790387_prep_final_report.hwpx's --pdf lost the appendix ---
    // ---- questionnaire (A6-A9) after S10-A's own fix, even though its page count only dropped ---
    // ---- 208->207 — NOT a harmless settle re-convergence. Root cause traced (macOS, headless ------
    // ---- PageLayout + a real --pdf export + pdftotext): the appendix's whole survey is ONE ---------
    // ---- table with a SINGLE row whose one cell holds 36 blocks (35 text + 1 nested 1x1 table). ---
    // ---- A single-row table can never be split by TableSettle (CanBreakAbove(0) is always false, ---
    // ---- no boundary exists above the first row), so this cell is placed as ONE atomic block. -----
    // ---- S10-A's fix reserved real height for that nested table, growing the cell from 526pt to ---
    // ---- 683.9pt — just 1.4pt over one full page's content height (694.5pt on this geometry). -----
    // ---- The placement loop's push guard required BOTH "does not fit here" AND "would fit a ------
    // ---- fresh page" before pushing — an item taller than a page failed the second test and so ----
    // ---- was left wherever the cursor happened to be (574.8pt into an already-used page), where ---
    // ---- it needed 695.9pt of the 119.7pt actually left. The printing pipeline draws it there -----
    // ---- as one shot; whatever falls past that PAGE's own bottom edge is not merely clipped, it ---
    // ---- is never emitted to that page's content stream at all (confirmed: pdftotext of the -------
    // ---- exported PDF jumped straight from one paragraph to the NEXT block, mid-sentence, with ----
    // ---- ~85% of the cell's own text gone). Fixed in PageLayout.cs's new shared
    // ---- ShouldPushToFreshPage: push whenever the room left does not fit, EVEN if a full fresh ----
    // ---- page would not fully fit either — pushing only ever REDUCES how much overflows past the -
    // ---- page bottom (by exactly the abandoned cursor's own value), never increases it. This is ---
    // ---- a general placement-loop fix, not specific to this document or to S10-A's own images/ ----
    // ---- nested-tables reservation — the same bug could already fire for an oversized table piece
    // ---- or an oversized text line, so all four push sites in PageLayout.cs share the one fix. ----

    /// <summary>The structural invariant <see cref="PageLayout.ShouldPushToFreshPage"/> exists to
    /// guarantee, checked directly on the layout's own output rather than by re-deriving pixels:
    /// a placement or line that starts PARTWAY into a page (<c>LocalTopPoints &gt; 0</c>) must
    /// still fit within that page's own content height. If it does not, the push guard failed to
    /// fire and the printing pipeline's page-boundary clip (see this section's own class-doc note)
    /// will silently drop whatever falls past the edge — exactly the appendix-questionnaire defect
    /// this test is named for. An item taller than a full page is still allowed to overflow, but
    /// ONLY from a page it already started at the very top of (<c>LocalTopPoints == 0</c>), which
    /// is the best this architecture can do for a block/row that cannot be split further and which
    /// this test does not fault. Runs on all 5 corpus documents, WITH and WITHOUT a real
    /// <see cref="ImageBlockRenderer"/> (the defect this sprint hit was on the WITH-renderer path,
    /// but the invariant itself is unrelated to image/nested-table reservation and must hold either
    /// way).</summary>
    [Theory]
    [MemberData(nameof(PageCountDocIndexes))]
    public void No_placement_or_line_starting_mid_page_overflows_past_that_pages_own_bottom(int docIndex)
    {
        var (relPath, _) = PageCountDocs[docIndex];
        var repoRoot = FindRepoRoot();
        Environment.SetEnvironmentVariable("FASTDOC_ENGINE_LIB", EngineLibOrThrow(repoRoot));
        var path = Path.Combine(repoRoot, "testdocs", relPath);
        Assert.True(File.Exists(path), $"fixture missing: {path}");

        var result = RenderTreeLoader.Load(path);
        try
        {
            Assert.True(result.IsOk, $"load failed: {result.Error?.Kind} {result.Error?.Message}");
            var geometry = PageGeometry.FromDocument(result.Tree!);
            if (geometry is null) { return; } // no declared page geometry — page mode does not apply

            var blocks = FlowDocumentBuilder.Build(result.Tree!);
            var markers = BlockPageMarkers.Compute(result.Tree!);
            var handle = result.Handle?.RawHandle ?? IntPtr.Zero;

            void AssertNoMidPageOverflow(PageLayoutResult layout, string label)
            {
                const double tolerancePoints = 0.5; // sub-pixel rounding slack, matches this file's own +0.01 push epsilon at 96dpi scale
                foreach (var p in layout.Placements)
                {
                    // A table PIECE (RowRangeCount smaller than the table's own row count) went
                    // through PlaceTableRows, not the Build() default branch this sprint's fix
                    // touches — that path's own convergence limits are a SEPARATE, already-documented
                    // gap (TableSettle.cs's own class doc: "the host fallback's grouping is coarser
                    // than Swift's own") and out of S10-A's scope. A WHOLE block (RowRangeCount is
                    // null, or covers every row — the shape Build()'s default branch always
                    // produces) is exactly what this sprint's ShouldPushToFreshPage fix governs, so
                    // it is checked here.
                    var block = blocks[p.BlockIndex];
                    var isTablePiece = block.Kind == FlowBlockKind.Table && block.Table is not null
                        && p.RowRangeCount is { } rc && rc < block.Table.Rows.Count;
                    if (isTablePiece) { continue; }

                    Assert.True(p.LocalTopPoints <= 0.01 || p.LocalTopPoints + p.HeightPoints <= layout.PageContentHeightPoints + tolerancePoints,
                        $"{relPath} [{label}]: block {p.BlockIndex} placement starts mid-page (top={p.LocalTopPoints:F1}) " +
                        $"and overflows past the page's own bottom (top+height={p.LocalTopPoints + p.HeightPoints:F1} > " +
                        $"contentHeight={layout.PageContentHeightPoints:F1}) — content past the page edge is silently dropped by the printing pipeline");
                }
                foreach (var l in layout.Lines)
                {
                    Assert.True(l.LocalTopPoints <= 0.01 || l.LocalTopPoints + l.HeightPoints <= layout.PageContentHeightPoints + tolerancePoints,
                        $"{relPath} [{label}]: block {l.BlockIndex} line {l.LineIndex} starts mid-page (top={l.LocalTopPoints:F1}) " +
                        $"and overflows past the page's own bottom (top+height={l.LocalTopPoints + l.HeightPoints:F1} > " +
                        $"contentHeight={layout.PageContentHeightPoints:F1})");
                }
            }

            var (nullLayout, _, _, _) = PageLayout.BuildWithTableSettle(blocks, markers, geometry, handle,
                headersOn: true, footersOn: true, splitTablesDefault: true, imageRenderer: null);
            AssertNoMidPageOverflow(nullLayout, "imageRenderer: null");

            var renderer = BoundRenderer(result, path);
            var (realLayout, _, _, _) = PageLayout.BuildWithTableSettle(blocks, markers, geometry, handle,
                headersOn: true, footersOn: true, splitTablesDefault: true, imageRenderer: renderer);
            AssertNoMidPageOverflow(realLayout, "real ImageBlockRenderer");

            // The literal shape of the lead's ask: no text block that had at least one line placed
            // WITHOUT the renderer becomes entirely unplaced WITH it (a coarser, block-existence
            // check layered on top of the geometry check above, in case a future regression drops
            // PagedLine entries outright rather than merely mis-placing them).
            var blockIndexesWithLinesBefore = nullLayout.Lines.Select(l => l.BlockIndex).ToHashSet();
            var blockIndexesWithLinesAfter = realLayout.Lines.Select(l => l.BlockIndex).ToHashSet();
            foreach (var idx in blockIndexesWithLinesBefore)
            {
                Assert.True(blockIndexesWithLinesAfter.Contains(idx),
                    $"{relPath}: text block {idx} had lines placed without the renderer but none with it");
            }
        }
        finally
        {
            result.Handle?.Dispose();
        }
    }
}
