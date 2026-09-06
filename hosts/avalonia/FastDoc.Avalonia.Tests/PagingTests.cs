using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using Avalonia;
using Avalonia.Headless;
using Avalonia.Media;
using Avalonia.Media.TextFormatting;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Native;
using FastDoc.Avalonia.Paging;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// E2c-1 (page mode: measurer, bands, sheets) — pure-managed unit coverage, no FASTDOC_ENGINE_LIB
/// needed. Every test below either builds a RenderTree from a fixed JSON string (the same pattern
/// RenderTreeEnvelopeTests.cs uses) or calls a FFI wrapper with a NULL native handle, which both
/// PageBandResolver and PageSheetsResolver treat as "engine unavailable" and answer from their own
/// host-fallback arithmetic instead — so nothing here touches the native dylib.
///
/// TextLayout-backed assertions (TextMeasurerPort.MeasureManaged, PageLayout.Build) need Avalonia's
/// font manager set up once per test run — <see cref="AvaloniaHeadlessSetup"/>'s static constructor
/// does that the same way Program.RunSheets/RunPaintProbe do for the CLI paths, just without a
/// window.
/// </summary>
internal static class AvaloniaHeadlessSetup
{
    static AvaloniaHeadlessSetup()
    {
        AppBuilder.Configure<Application>()
            .UseHeadless(new AvaloniaHeadlessPlatformOptions())
            .SetupWithoutStarting();
    }

    /// <summary>Touch this from a test's first line to force the static constructor above to have
    /// run — xunit does not otherwise guarantee WHEN a static constructor executes relative to a
    /// specific test method, only that it runs before first use of the type.</summary>
    public static void EnsureReady() { }
}

public class PagingTests
{
    public PagingTests() => AvaloniaHeadlessSetup.EnsureReady();

    // ---- 1. measurer port height matches a directly-built TextLayout --------------------------

    [Fact]
    public void MeasurerPort_height_matches_a_directly_built_TextLayout()
    {
        const string text = "Hello, FastDoc page mode.";
        const double fontSize = 14.0;
        const double width = 300.0;

        var fontNamePtr = Marshal.StringToHGlobalAnsi("Inter");
        var textPtr = Marshal.StringToHGlobalAnsi(text);
        try
        {
            var paragraphs = new[]
            {
                new FastdocEngine.FastdocTextMeasureParagraph
                {
                    Alignment = 0, // left
                    LineHeightMultiple = 1.0,
                    SpacingBefore = 0,
                    SpacingAfter = 0,
                },
            };
            var runs = new[]
            {
                new FastdocEngine.FastdocTextMeasureRun
                {
                    ParagraphIndex = 0,
                    Kind = FastdocEngine.FastdocTextMeasureRunKindText,
                    FontName = fontNamePtr,
                    Size = fontSize,
                    Text = textPtr,
                },
            };

            var portHeight = TextMeasurerPort.MeasureManaged(paragraphs, runs, width);

            // The SAME shape TextMeasurerPort.MeasureParagraph builds for one text run: one
            // TextLayout at (text, typeface, fontSize, alignment, wrap, maxWidth, lineHeight).
            var expectedLayout = new TextLayout(text, new Typeface("Inter"), fontSize, Brushes.Black,
                TextAlignment.Left, TextWrapping.Wrap, maxWidth: width, lineHeight: fontSize * 1.0);

            Assert.Equal(expectedLayout.Height, portHeight, precision: 3);
        }
        finally
        {
            Marshal.FreeHGlobal(fontNamePtr);
            Marshal.FreeHGlobal(textPtr);
        }
    }

    [Fact]
    public void MeasurerPort_adds_spacing_before_and_after_around_the_text_height()
    {
        const string text = "One line.";
        const double fontSize = 12.0;
        const double width = 400.0;
        const double before = 6.0;
        const double after = 8.0;

        var fontNamePtr = Marshal.StringToHGlobalAnsi("Inter");
        var textPtr = Marshal.StringToHGlobalAnsi(text);
        try
        {
            var paragraphs = new[]
            {
                new FastdocEngine.FastdocTextMeasureParagraph
                {
                    LineHeightMultiple = 1.0,
                    SpacingBefore = before,
                    SpacingAfter = after,
                },
            };
            var runs = new[]
            {
                new FastdocEngine.FastdocTextMeasureRun
                {
                    ParagraphIndex = 0,
                    Kind = FastdocEngine.FastdocTextMeasureRunKindText,
                    FontName = fontNamePtr,
                    Size = fontSize,
                    Text = textPtr,
                },
            };

            var withSpacing = TextMeasurerPort.MeasureManaged(paragraphs, runs, width);

            var noSpacingParagraphs = new[]
            {
                new FastdocEngine.FastdocTextMeasureParagraph { LineHeightMultiple = 1.0 },
            };
            var withoutSpacing = TextMeasurerPort.MeasureManaged(noSpacingParagraphs, runs, width);

            Assert.Equal(withoutSpacing + before + after, withSpacing, precision: 3);
        }
        finally
        {
            Marshal.FreeHGlobal(fontNamePtr);
            Marshal.FreeHGlobal(textPtr);
        }
    }

    // ---- 2. sheets fallback arithmetic matches PagePagination.sheets/sheetTop's own formula ----

    [Theory]
    [InlineData(0, 0.0, 100.0, 700.0, 40.0, 0.0)]
    [InlineData(1, 0.0, 100.0, 700.0, 40.0, 0.0)]
    [InlineData(4, 12.0, 90.0, 650.0, 36.0, 24.0)]
    public void Sheets_fallback_matches_sheetTop_formula_when_no_engine_handle(
        int page, double textOriginY, double leadingBand, double pitch, double topMargin, double deskGap)
    {
        var count = page + 1;
        var rects = PageSheetsResolver.Resolve(IntPtr.Zero, count, widthPoints: 500, textOriginY, leadingBand,
            pitch, topMargin, deskGap);

        Assert.Equal(count, rects.Length);
        var expectedTop = textOriginY + leadingBand + page * pitch - topMargin;
        var expectedHeight = Math.Max(1, pitch - deskGap);
        var actual = rects[page];
        Assert.Equal(0, actual.X);
        Assert.Equal(expectedTop, actual.Y, precision: 6);
        Assert.Equal(500, actual.Width);
        Assert.Equal(expectedHeight, actual.Height, precision: 6);
    }

    [Fact]
    public void Sheets_fallback_returns_empty_for_a_non_positive_pitch_or_count()
    {
        Assert.Empty(PageSheetsResolver.Resolve(IntPtr.Zero, count: 0, 100, 0, 0, 500, 0, 0));
        Assert.Empty(PageSheetsResolver.Resolve(IntPtr.Zero, count: 3, 100, 0, 0, pitchPoints: 0, 0, 0));
    }

    // ---- 3. a page-break-before block forces a new page -----------------------------------------

    [Fact]
    public void PageLayout_starts_a_new_page_at_a_pageBreakBefore_paragraph()
    {
        const string treeJson = """
        {
          "ok": {
            "schemaVersion": 1,
            "document": {
              "format": "docx",
              "rootNodeId": 0,
              "defaultBodyFontSize": 12,
              "documentPaper": {
                "widthPoints": 200,
                "heightPoints": 260,
                "margins": { "top": 20, "right": 20, "bottom": 20, "left": 20 }
              }
            },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1, 2], "type": "document", "data": {} },
              {
                "id": 1, "parentId": 0, "children": [],
                "type": "paragraph",
                "data": { "text": "first", "style": {}, "pagination": { "keepWithNext": false, "pageBreakBefore": false, "hidesPageNumber": false } }
              },
              {
                "id": 2, "parentId": 0, "children": [],
                "type": "paragraph",
                "data": { "text": "second", "style": {}, "pagination": { "keepWithNext": false, "pageBreakBefore": true, "hidesPageNumber": false } }
              }
            ]
          }
        }
        """;

        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(treeJson)!;
        Assert.True(envelope.IsOk);
        var tree = envelope.Ok!.Value.Deserialize<RenderTree>()!;

        var geometry = PageGeometry.FromDocument(tree);
        Assert.NotNull(geometry);

        var blocks = FlowDocumentBuilder.Build(tree);
        Assert.Equal(2, blocks.Count); // two paragraphs -> two top-level FlowBlocks

        var markers = BlockPageMarkers.Compute(tree);
        Assert.Equal(2, markers.PageBreakBefore.Length);
        Assert.False(markers.PageBreakBefore[0]);
        Assert.True(markers.PageBreakBefore[1]);

        // handle = IntPtr.Zero -> PageBandResolver's own host fallback (no native call).
        var layout = PageLayout.Build(blocks, markers, geometry!, IntPtr.Zero, headersOn: true, footersOn: true);

        Assert.Equal(2, layout.PageCount);
        // E2c-1b: text blocks land in layout.Lines (one entry per TextLine), not layout.Placements
        // (Rule/Image/Table only) — each of these two one-line paragraphs contributes exactly one.
        var firstBlockLines = layout.Lines.Where(l => l.BlockIndex == 0).ToList();
        var secondBlockLines = layout.Lines.Where(l => l.BlockIndex == 1).ToList();
        Assert.Single(firstBlockLines);
        Assert.Single(secondBlockLines);
        Assert.Equal(0, firstBlockLines[0].PageIndex);
        Assert.Equal(1, secondBlockLines[0].PageIndex);
        Assert.Equal(0, secondBlockLines[0].LocalTopPoints); // starts at the top of its own new page
    }

    // ---- 4. a long paragraph is split at the TextLine boundary across a page break ---------------

    [Fact]
    public void PageLayout_splits_a_long_paragraph_at_a_TextLine_boundary_across_a_page_break()
    {
        // A narrow page (content height ~60pt at 12pt body text -> a handful of lines per page) and
        // one long paragraph, repeated words so it wraps into many lines — enough that it must cross
        // at least one page boundary MID-PARAGRAPH, which is exactly what block-level pagination
        // (E2c-1) could never produce.
        var longText = string.Join(" ", Enumerable.Repeat("word", 200));
        const string treeJsonTemplate = """
        {
          "ok": {
            "schemaVersion": 1,
            "document": {
              "format": "docx",
              "rootNodeId": 0,
              "defaultBodyFontSize": 12,
              "documentPaper": {
                "widthPoints": 150,
                "heightPoints": 100,
                "margins": { "top": 10, "right": 10, "bottom": 10, "left": 10 }
              }
            },
            "nodes": [
              { "id": 0, "parentId": null, "children": [1], "type": "document", "data": {} },
              {
                "id": 1, "parentId": 0, "children": [2],
                "type": "paragraph",
                "data": { "style": {}, "pagination": { "keepWithNext": false, "pageBreakBefore": false, "hidesPageNumber": false } }
              },
              {
                "id": 2, "parentId": 1, "children": [],
                "type": "textRun",
                "data": { "text": "__TEXT__", "style": { "fontSizePoints": 12 } }
              }
            ]
          }
        }
        """;
        var treeJson = treeJsonTemplate.Replace("__TEXT__", longText);

        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(treeJson)!;
        Assert.True(envelope.IsOk);
        var tree = envelope.Ok!.Value.Deserialize<RenderTree>()!;
        var geometry = PageGeometry.FromDocument(tree)!;
        var blocks = FlowDocumentBuilder.Build(tree);
        Assert.Single(blocks); // one paragraph -> one FlowBlock, however many lines it wraps into
        var markers = BlockPageMarkers.Compute(tree);

        var layout = PageLayout.Build(blocks, markers, geometry, IntPtr.Zero, headersOn: false, footersOn: false);

        var blockLines = layout.Lines.Where(l => l.BlockIndex == 0).OrderBy(l => l.LineIndex).ToList();
        Assert.True(blockLines.Count > 5, "expected the long paragraph to wrap into several lines");

        var pagesSeen = blockLines.Select(l => l.PageIndex).Distinct().ToList();
        Assert.True(pagesSeen.Count > 1,
            "expected this ONE paragraph's lines to span more than one page (line-level split)");
        Assert.True(layout.PageCount > 1);

        // Every line after a page transition starts flush at the top of its new page (no leftover
        // spacing carried across the split) — the same "shift the whole line, never partway" rule
        // PageBandLayoutDelegate.swift states.
        for (var i = 1; i < blockLines.Count; i++)
        {
            if (blockLines[i].PageIndex != blockLines[i - 1].PageIndex)
            {
                Assert.Equal(0, blockLines[i].LocalTopPoints);
            }
        }
    }

    [Fact]
    public void PageGeometry_returns_null_for_a_document_with_no_declared_paper()
    {
        const string treeJson = """
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "markdown", "rootNodeId": 0, "defaultBodyFontSize": 12 },
            "nodes": [ { "id": 0, "parentId": null, "children": [], "type": "document", "data": {} } ]
          }
        }
        """;
        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(treeJson)!;
        var tree = envelope.Ok!.Value.Deserialize<RenderTree>()!;

        Assert.Null(PageGeometry.FromDocument(tree));
    }

    /// <summary>Builds a bare TableGridModel with <paramref name="rowCount"/> empty rows (no cells
    /// at all — a gap in the grid, not a document-declared empty CELL — so the REAL measurement
    /// TableSettle.EstimateRowHeights now delegates to falls back to
    /// TableGridRenderer.MeasureAllRows's own baseline for a row with no cells: one line at the
    /// model's own default body size (12pt, TableGridModel's own default when the model does not
    /// set one) plus the reader's 7pt-padding floor on both edges = 26pt per row — deterministic,
    /// no TextLayout content to depend on, and no hardcoded 14pt/4pt from before E2c-2c) and a
    /// matching FlowBlock.</summary>
    private static FlowBlock EmptyTableBlock(int rowCount, double spacingBeforePoints = 0)
    {
        var rows = new System.Collections.Generic.List<TableGridRow>();
        for (var r = 0; r < rowCount; r++)
        {
            rows.Add(new TableGridRow { Row = (uint)r, Cells = new System.Collections.Generic.List<TableGridCell>() });
        }
        var model = new TableGridModel { ColumnCount = 1, ColumnWidthRatios = new() { 1.0 }, Rows = rows };
        return new FlowBlock { Kind = FlowBlockKind.Table, Table = model, SpacingBeforePoints = spacingBeforePoints };
    }

    private static PageGeometry SimpleGeometry(double contentWidth = 100, double contentHeight = 100) => new()
    {
        PageWidthPoints = contentWidth,
        PageHeightPoints = contentHeight,
        MarginTopPoints = 0,
        MarginRightPoints = 0,
        MarginBottomPoints = 0,
        MarginLeftPoints = 0,
    };

    private static BlockPageMarkers.Markers FlatMarkers(int blockCount) => new(
        new bool[blockCount], new bool[blockCount], new bool[blockCount], new bool[blockCount]);

    [Fact]
    public void A_table_that_does_not_fit_the_end_of_a_page_moves_whole_to_the_next_page()
    {
        // A Rule block (deterministic height = spacingBefore + 1 + spacingAfter, no font metrics)
        // pushes the cursor to 71pt on a 100pt-tall page, then a 3-row table (26pt/row = 78pt,
        // well under the 100pt page, so it fits a FRESH page) cannot fit the 29pt left here.
        var ruleBlock = new FlowBlock { Kind = FlowBlockKind.Rule, SpacingBeforePoints = 70 };
        var tableBlock = EmptyTableBlock(rowCount: 3);
        var blocks = new System.Collections.Generic.List<FlowBlock> { ruleBlock, tableBlock };
        var markers = FlatMarkers(2);
        var geometry = SimpleGeometry();

        // Note: the ORDINARY per-block placement loop (Build's own non-text fallback, present
        // since E2c-1) already pushes any block — table included — that overruns a page it would
        // otherwise fit whole, so this simple single-page-overrun case is already resolved before
        // TableSettle's own round ever runs (its `pushed` counter can legitimately read 0 here —
        // nothing was left for it to change). What this test actually pins is the OUTCOME the
        // dispatch asked for: the table lands WHOLE, flush at a later page's top.
        var (layout, _, _, _) = PageLayout.BuildWithTableSettle(
            blocks, markers, geometry, IntPtr.Zero, headersOn: false, footersOn: false, splitTablesDefault: true);

        var tablePlacements = layout.Placements.Where(p => p.BlockIndex == 1).ToList();
        Assert.Single(tablePlacements); // pushed WHOLE — never split into pieces
        Assert.True(tablePlacements[0].PageIndex > 0, "expected the table to move off the page the rule left it on");
        Assert.Equal(0, tablePlacements[0].LocalTopPoints); // lands flush at the top of its new page
        Assert.Equal(78, tablePlacements[0].HeightPoints, precision: 3); // 3 rows * 26pt, whole
    }

    [Fact]
    public void A_table_taller_than_one_page_splits_at_a_row_boundary()
    {
        // 10 rows * 26pt = 260pt on a 100pt-tall page — no single page can hold it, so it MUST be
        // broken (invariant 64: always broken regardless of splitTables/keepsWhole once taller than
        // a whole page), one CanBreakAbove-safe row boundary at a time.
        var tableBlock = EmptyTableBlock(rowCount: 10);
        var blocks = new System.Collections.Generic.List<FlowBlock> { tableBlock };
        var markers = FlatMarkers(1);
        var geometry = SimpleGeometry();

        var (layout, _, _, oversized) = PageLayout.BuildWithTableSettle(
            blocks, markers, geometry, IntPtr.Zero, headersOn: false, footersOn: false, splitTablesDefault: true);

        var tablePlacements = layout.Placements.Where(p => p.BlockIndex == 0).OrderBy(p => p.PageIndex).ToList();
        Assert.True(oversized > 0, "expected at least one row-boundary break to be registered");
        Assert.True(tablePlacements.Count > 1, "expected the table to be broken into more than one piece");
        Assert.True(layout.PageCount > 1, "expected the pieces to actually span more than one page");
        foreach (var piece in tablePlacements)
        {
            Assert.True(piece.HeightPoints <= 100.001, "no single piece should itself exceed the page body");
        }
    }

    [Fact]
    public void Table_settle_row_heights_match_the_real_cell_TextLayout_measurement()
    {
        // A cell with enough text to wrap across several lines at a NARROW column width — a
        // character-count heuristic (the one E2c-2b removed) and a real per-cell TextLayout
        // disagree sharply here, so this is exactly the case that would have caught the old bug.
        var longRun = new FlowRun(
            string.Concat(System.Linq.Enumerable.Repeat("wrap ", 40)), null, 12, false, false, false, false, Colors.Black);
        var cellContent = new FlowBlock { Kind = FlowBlockKind.Text, Runs = new() { longRun } };
        var cell = new TableGridCell { Row = 0, Column = 0, Content = new() { cellContent } };
        var row = new TableGridRow { Row = 0, Cells = new() { cell } };
        var model = new TableGridModel { ColumnCount = 1, ColumnWidthRatios = new() { 1.0 }, Rows = new() { row } };
        const double columnWidthPoints = 80;

        // TableSettle's own row-height entry point (what the settle loop and pagination now use)...
        var settleHeights = TableSettle.EstimateRowHeights(model, columnWidthPoints);

        // ...must equal TableGridRenderer's OWN "no cache yet" total for a one-row table — both
        // now resolve to the SAME MeasureAllRows call, which is what "shares one cache/measurement
        // across layout, settle and draw" (the dispatch's own ask) means in practice.
        var rendererTotalPx = TableGridRenderer.EstimateHeight(model, columnWidthPoints * 96.0 / 72.0);
        var rendererTotalPoints = rendererTotalPx * 72.0 / 96.0;

        Assert.Single(settleHeights);
        Assert.Equal(rendererTotalPoints, settleHeights[0], precision: 2);
        // A heuristic 0.55-Latin-width guess for 200 characters at this width would have landed
        // near 1-2 "lines" worth of height; real Hangul-width-aware wrapping of this much text at
        // an 80pt column needs noticeably more room — a floor that also rules out "it silently
        // returned the old baseline and never actually measured".
        Assert.True(settleHeights[0] > 40, "expected a real multi-line measurement, not a single baseline row");
    }
}

