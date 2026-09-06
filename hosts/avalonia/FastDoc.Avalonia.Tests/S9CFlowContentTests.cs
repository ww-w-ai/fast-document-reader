using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Media.TextFormatting;
using SkiaSharp;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Printing;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>Regression tests for the S9-C flow-mode content-loss bug (owner report: "docx 는 페이지
/// 모두가 아닐 때 콘텐츠가 다 보이질 않는거 같네") — root cause was
/// <c>TableGridRenderer</c>'s cell-content builder silently skipping every non-Text
/// <see cref="FlowBlock"/> (Image/Vector/Unsupported-placeholder, Kind == Image; nested Table)
/// living inside a table cell, both for HEIGHT (so nothing reserved space for it) and for DRAW (so
/// nothing painted it) — measured against this repo's own testdocs/ corpus in
/// docs/studio/sprints/S9/s9c-flow-content.md: real docx/hwp/hwpx documents embed pictures and
/// nested tables inside cells routinely, so this was missing content in the MIDDLE of a document,
/// not merely clipping its end.</summary>
public class S9CFlowContentTests
{
    public S9CFlowContentTests() => AvaloniaHeadlessSetup.EnsureReady();

    private sealed class RecordingCanvas : IPageCanvas
    {
        public int RectCount;
        public int ImageCount;
        public int LineCount;
        public List<Rect> Rects { get; } = new();
        public List<Point> TextOrigins { get; } = new();

        public void DrawRect(Rect rect, Color? fill, Color? stroke, double strokeThicknessPx) { RectCount++; Rects.Add(rect); }
        public void DrawLine(Point a, Point b, Color color, double thicknessPx) { LineCount++; }
        public void DrawImage(Bitmap bitmap, byte[]? sourceBytes, string? sourceMimeType, Rect destRect) { ImageCount++; }
        public void DrawTextLayout(TextLayout layout, Point origin) { TextOrigins.Add(origin); }
        public void DrawTextLine(TextLine line, Point origin) { }
    }

    private static FlowRun Run(string text) => new(text, null, 12, false, false, false, false, Colors.Black);

    private static FlowBlock TextBlock(string text) => new()
    {
        Kind = FlowBlockKind.Text,
        Runs = new List<FlowRun> { Run(text) },
    };

    /// <summary>A one-row, one-column table whose only cell holds <paramref name="cellContent"/> —
    /// the smallest fixture that exercises <c>TableGridRenderer</c>'s per-cell content path without
    /// needing a real document.</summary>
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

    // ---- height: an image inside a cell must be RESERVED when an ImageBlockRenderer is given ----

    [Fact]
    public void Image_inside_a_table_cell_adds_height_when_an_image_renderer_is_supplied()
    {
        var imageOnly = new FlowBlock { Kind = FlowBlockKind.Image, ImageWidthPoints = 300, ImageHeightPoints = 200 };
        var table = OneCellTable(new List<FlowBlock> { imageOnly });
        var renderer = new ImageBlockRenderer();

        var heightWithRenderer = TableGridRenderer.EstimateHeight(table, columnWidth: 400, fontScale: 1.0, imageRenderer: renderer);
        var heightWithoutRenderer = TableGridRenderer.EstimateHeight(table, columnWidth: 400, fontScale: 1.0, imageRenderer: null);

        // 200pt tall at 96dpi is ~267px — a bare empty-cell line is nowhere near that, so this is
        // not a rounding difference: it is the whole picture's height either present or missing.
        Assert.True(heightWithRenderer > heightWithoutRenderer + 100,
            $"expected the image's own height to be reserved; withRenderer={heightWithRenderer} withoutRenderer={heightWithoutRenderer}");
    }

    /// <summary>Documents the DELIBERATE scope limit (see this file's own class doc and
    /// BuildCellContent's doc in TableGridRenderer.cs): a caller that measures a table with NO
    /// ImageBlockRenderer (page-mode settle/pagination, MeasureRowHeightsPoints) keeps the exact
    /// pre-S9-C behaviour — this fix targets flow mode (the reported bug) and does not change page
    /// mode's own pagination numbers in the same change.</summary>
    [Fact]
    public void Image_inside_a_table_cell_is_still_ignored_for_height_with_no_image_renderer()
    {
        var imageOnly = new FlowBlock { Kind = FlowBlockKind.Image, ImageWidthPoints = 300, ImageHeightPoints = 200 };
        var withImage = OneCellTable(new List<FlowBlock> { imageOnly });
        var empty = OneCellTable(new List<FlowBlock>());

        var heightWithImage = TableGridRenderer.EstimateHeight(withImage, columnWidth: 400, fontScale: 1.0, imageRenderer: null);
        var heightEmpty = TableGridRenderer.EstimateHeight(empty, columnWidth: 400, fontScale: 1.0, imageRenderer: null);

        Assert.Equal(heightEmpty, heightWithImage, precision: 3);
    }

    // ---- draw: the image actually paints (or reserves a placeholder rect) inside the cell ----

    [Fact]
    public void Image_inside_a_table_cell_is_drawn_as_a_placeholder_rect_when_no_bitmap_resolves()
    {
        // No ImageResourceId -> ImageBlockRenderer.Resolve finds nothing -> the same placeholder
        // rect path a top-level unsupported/undecoded picture already draws through.
        var imageOnly = new FlowBlock { Kind = FlowBlockKind.Image, ImageWidthPoints = 300, ImageHeightPoints = 200 };
        var table = OneCellTable(new List<FlowBlock> { imageOnly });
        var renderer = new ImageBlockRenderer();
        var canvas = new RecordingCanvas();

        TableGridRenderer.Draw(canvas, table, left: 0, top: 0, columnWidth: 400, fontScale: 1.0,
            viewportTop: double.NegativeInfinity, viewportBottom: double.PositiveInfinity,
            cachedRowHeights: null, out _, rowIndicesToDraw: null, imageRenderer: renderer);

        // One rect for the cell's own shading/no-shading path is optional (no shading here), so
        // the placeholder rect the image draws is the only DrawRect call this fixture can produce.
        Assert.True(canvas.RectCount >= 1, "expected the image's placeholder rect to be drawn inside the cell");
    }

    /// <summary>Mutation-review regression (team-lead finding, 2026-09-06): a prior version of
    /// <c>BuildCellContent</c> summed a LOCAL <c>segmentHeight</c> variable into
    /// <c>EstimateHeight</c>'s total, then passed that same local a second time into
    /// <c>new CellSegment(...)</c> — two independently-written uses of one number. Mutating just
    /// the value STORED ON THE SEGMENT to 0 (what <c>Draw</c>'s paint cursor actually advances by)
    /// left <c>EstimateHeight</c> untouched, so all 8 height/segment-count tests above stayed
    /// green while the DRAW path silently painted the next segment on top of the image instead of
    /// below it — the exact "content not visible" symptom this sprint exists to fix, just moved
    /// one segment later and outside what those tests could see. Asserts the thing those tests
    /// could not: the TEXT segment drawn immediately after an image segment starts at or below the
    /// image's own bottom edge, not on top of it.</summary>
    [Fact]
    public void Text_segment_after_an_image_segment_in_a_cell_starts_below_the_images_true_height()
    {
        var imageThenText = new List<FlowBlock>
        {
            new() { Kind = FlowBlockKind.Image, ImageWidthPoints = 300, ImageHeightPoints = 200 },
            TextBlock("after the image"),
        };
        var table = OneCellTable(imageThenText);
        var renderer = new ImageBlockRenderer();
        var canvas = new RecordingCanvas();

        TableGridRenderer.Draw(canvas, table, left: 0, top: 0, columnWidth: 400, fontScale: 1.0,
            viewportTop: double.NegativeInfinity, viewportBottom: double.PositiveInfinity,
            cachedRowHeights: null, out _, rowIndicesToDraw: null, imageRenderer: renderer);

        Assert.True(canvas.Rects.Count >= 1, "expected the image's placeholder rect to be drawn");
        Assert.True(canvas.TextOrigins.Count >= 1, "expected the trailing text segment to be drawn");
        var imageRect = canvas.Rects[0];
        var textOriginY = canvas.TextOrigins[0].Y;

        // If the image segment's stored Height were 0 (the mutation this test targets), the text
        // would start at ~the image's own TOP edge and overlap it; a correctly-advanced cursor
        // starts at or below the image's BOTTOM edge (a small tolerance covers sub-pixel rounding
        // in TextLayout's own line-height, never the ~267px a 200pt image occupies at 96dpi).
        Assert.True(textOriginY >= imageRect.Bottom - 1.0,
            $"expected trailing text to start at/after the image's bottom edge ({imageRect.Bottom}); it started at {textOriginY}");
    }

    [Fact]
    public void Image_inside_a_table_cell_is_never_drawn_with_no_image_renderer()
    {
        var imageOnly = new FlowBlock { Kind = FlowBlockKind.Image, ImageWidthPoints = 300, ImageHeightPoints = 200 };
        var table = OneCellTable(new List<FlowBlock> { imageOnly });
        var canvas = new RecordingCanvas();

        TableGridRenderer.Draw(canvas, table, left: 0, top: 0, columnWidth: 400, fontScale: 1.0,
            viewportTop: double.NegativeInfinity, viewportBottom: double.PositiveInfinity,
            cachedRowHeights: null, out _, rowIndicesToDraw: null, imageRenderer: null);

        Assert.Equal(0, canvas.RectCount);
        Assert.Equal(0, canvas.ImageCount);
    }

    // ---- height: a nested table inside a cell must be RESERVED when an ImageBlockRenderer is given ----

    [Fact]
    public void Nested_table_inside_a_cell_adds_its_rows_height_when_an_image_renderer_is_supplied()
    {
        var nested = OneCellTable(new List<FlowBlock>
        {
            TextBlock("row one of the nested table"),
        });
        // A second row so the nested table has real height beyond one empty-cell line.
        nested.Rows.Add(new TableGridRow
        {
            Row = 1,
            Cells = new List<TableGridCell> { new() { Row = 1, Column = 0, Content = new List<FlowBlock> { TextBlock("row two") } } },
        });
        var nestedBlock = new FlowBlock { Kind = FlowBlockKind.Table, Table = nested };
        var outer = OneCellTable(new List<FlowBlock> { nestedBlock });
        var empty = OneCellTable(new List<FlowBlock>());
        var renderer = new ImageBlockRenderer();

        var heightWithNested = TableGridRenderer.EstimateHeight(outer, columnWidth: 400, fontScale: 1.0, imageRenderer: renderer);
        var heightWithoutNested = TableGridRenderer.EstimateHeight(empty, columnWidth: 400, fontScale: 1.0, imageRenderer: renderer);

        Assert.True(heightWithNested > heightWithoutNested,
            $"expected the nested table's two rows to add height; withNested={heightWithNested} empty={heightWithoutNested}");
    }

    [Fact]
    public void Nested_table_inside_a_cell_is_drawn_via_the_cells_own_text_layout_and_the_recursive_draw()
    {
        var nested = OneCellTable(new List<FlowBlock> { TextBlock("nested cell text") });
        var nestedBlock = new FlowBlock { Kind = FlowBlockKind.Table, Table = nested };
        var outerCellContent = new List<FlowBlock> { TextBlock("outer text before"), nestedBlock };
        var outer = OneCellTable(outerCellContent);
        var renderer = new ImageBlockRenderer();
        var canvas = new RecordingCanvas();

        TableGridRenderer.Draw(canvas, outer, left: 0, top: 0, columnWidth: 400, fontScale: 1.0,
            viewportTop: double.NegativeInfinity, viewportBottom: double.PositiveInfinity,
            cachedRowHeights: null, out _, rowIndicesToDraw: null, imageRenderer: renderer);

        // Each one-cell table draws its own 4 border edges (DrawCellBorders — a table an author
        // left fully undeclared still reads as a grid). If the nested table's recursive Draw call
        // never ran (the pre-fix behaviour), only the OUTER cell's 4 edges would be drawn; getting
        // both tables' edges (8) proves the recursion actually painted the nested grid, not merely
        // that the outer cell's own text ran.
        Assert.Equal(8, canvas.LineCount);
    }

    // ---- real-corpus regression: FlowDocumentBuilder loses nothing (guards a DIFFERENT part of ----
    // ---- the same reported bug from silently regressing — see s9c-flow-content.md §재현) ----

    private static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "CLAUDE.md")))
        {
            dir = dir.Parent;
        }
        return dir?.FullName ?? throw new InvalidOperationException("could not find repo root (no CLAUDE.md in any parent directory)");
    }

    [Theory]
    [InlineData("everything/GnBS_IM_20260401.docx")] // measured: 10 images embedded in table cells
    [InlineData("mini/s9-picture-crop.hwp")]          // measured: 6 images + 3 nested tables in cells
    public void Real_document_flow_blocks_including_nested_cell_content_account_for_every_body_node(string relPath)
    {
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
            var tree = result.Tree!;

            var byId = new Dictionary<ulong, RenderNode>(tree.Nodes.Count);
            foreach (var n in tree.Nodes) { byId[n.Id] = n; }
            var skip = new HashSet<string> { "footnote", "header", "footer", "masterPage", "masterPageObject", "anchoredObject", "formControl" };
            var bodyBlockTypes = new HashSet<string> { "heading", "paragraph", "listItem", "taskListItem", "codeBlock", "table", "image", "vector", "unsupported", "thematicBreak" };
            var bodyBlockCount = 0;
            void WalkEnvelope(ulong id)
            {
                if (!byId.TryGetValue(id, out var node)) { return; }
                if (skip.Contains(node.Type)) { return; }
                if (bodyBlockTypes.Contains(node.Type)) { bodyBlockCount++; }
                foreach (var c in node.Children) { WalkEnvelope(c); }
            }
            if (tree.Document is not null) { WalkEnvelope(tree.Document.RootNodeId); }

            var blocks = FlowDocumentBuilder.Build(tree);
            var totalFlowBlocks = 0;
            void WalkFlow(List<FlowBlock> list)
            {
                foreach (var b in list)
                {
                    totalFlowBlocks++;
                    if (b.Kind == FlowBlockKind.Table && b.Table is not null)
                    {
                        foreach (var row in b.Table.Rows)
                        {
                            foreach (var cell in row.Cells) { WalkFlow(cell.Content); }
                        }
                    }
                }
            }
            WalkFlow(blocks);

            // The builder itself (FlowDocumentBuilder) already accounted for every body node
            // BEFORE this sprint — the bug was TableGridRenderer dropping the nested ones at
            // measure/draw time, not the builder losing them. This assertion pins that the
            // builder side stays lossless as the corpus/engine evolve.
            Assert.Equal(bodyBlockCount, totalFlowBlocks);
        }
        finally
        {
            result.Handle?.Dispose();
        }
    }

    // ---- S9-V follow-up: VM report of a multi-viewport BLANK stretch in flow mode on --------
    // ---- s9-picture-crop.hwp — see docs/studio/sprints/S9/s9c-flow-content.md §S9-V for the -----
    // ---- full investigation. Summary: an exhaustive headless replay of the SAME document -------
    // ---- (real block heights after a full-document scroll sweep, real per-block LineHeight -----
    // ---- values including every nested table cell) found NO oversized or visually-empty ---------
    // ---- block anywhere in it — total content height (32,263px) is fully accounted for by --------
    // ---- content-dense blocks. The mechanism BELOW is a real, currently-UNUSED amplifier ---------
    // ---- this codebase already has (an `Exact`/`AtLeast` LineHeight bypasses natural text ---------
    // ---- measurement entirely) — not proven to be what the VM saw, but real, un-guarded, ----------
    // ---- and worth a permanent regression test either way. ----------------------------------------

    private static T GetPrivateField<T>(object obj, string name)
    {
        var field = typeof(FlowDocumentView).GetField(name, BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new InvalidOperationException($"FlowDocumentView.{name} not found — has it been renamed?");
        return (T)field.GetValue(obj)!;
    }

    /// <summary>Documents the MECHANISM a future regression in this area would exploit: Avalonia's
    /// <see cref="TextLayout"/> constructor takes an explicit <c>lineHeight</c> and applies it to
    /// EVERY line unconditionally — <see cref="LineHeightRule.Apply"/>'s `Exact` mode passes that
    /// value straight through with no ceiling relative to the text's own natural size. A single
    /// short line of real text, given an absurd declared Exact line height (a wire/engine unit bug
    /// this host cannot see from here — see this file's own class doc), would occupy that many
    /// pixels while only a few of them show any glyph: a "content is there, but padded into a
    /// mostly-blank multi-screen box" shape, which is what a screenshot of it would show. This test
    /// proves the mechanism is real and unguarded today (no clamp exists), so if a future fix adds
    /// one, this test's own assertion direction flips and must be updated alongside it.</summary>
    [Fact]
    public void An_absurd_exact_line_height_on_one_short_text_block_reserves_that_many_pixels_almost_entirely_blank()
    {
        var absurdTree = SingleParagraphTree(lineHeightJson: """{ "value": 3000, "mode": "exact" }""");
        var view = new FlowDocumentView();
        view.SetTree(absurdTree);
        var window = new Window { Width = 900, Height = 900, Content = view };
        window.Show();
        window.CaptureRenderedFrame();
        var absurdHeight = GetPrivateField<double[]>(view, "_blockHeights")[0];

        var normalTree = SingleParagraphTree(lineHeightJson: null);
        var normalView = new FlowDocumentView();
        normalView.SetTree(normalTree);
        var normalWindow = new Window { Width = 900, Height = 900, Content = normalView };
        normalWindow.Show();
        normalWindow.CaptureRenderedFrame();
        var normalHeight = GetPrivateField<double[]>(normalView, "_blockHeights")[0];

        // 3000pt at 96dpi is ~4000px — over four full 900px viewports — versus an ordinary one-line
        // paragraph's actual height (well under 100px). If this ever regresses to near-equal, the
        // mechanism this test warns about has been fixed (good) and the test itself needs updating.
        Assert.True(absurdHeight > normalHeight * 20,
            $"expected the Exact-3000pt block to dwarf an ordinary line; absurd={absurdHeight} normal={normalHeight}");
        Assert.True(absurdHeight > 3000, $"expected roughly the declared 3000pt (~4000px); got {absurdHeight}");
    }

    /// <summary>Builds the smallest RenderTree a single "short line" paragraph needs, directly from
    /// a JSON envelope — mirroring RenderTreeEnvelopeTests' own pattern for constructing a minimal
    /// tree without a real document file. <paramref name="lineHeightJson"/> is spliced in as the
    /// paragraph style's raw `lineHeight` object (e.g. `{"value":3000,"mode":"exact"}`), or omitted
    /// entirely for the control (natural, un-declared line height).</summary>
    private static RenderTree SingleParagraphTree(string? lineHeightJson)
    {
        var styleJson = lineHeightJson is null ? "{}" : $$"""{ "lineHeight": {{lineHeightJson}} }""";
        var json = $$"""
        {
          "schemaVersion": 1,
          "document": { "rootNodeId": 0, "defaultBodyFontSize": 12.0 },
          "nodes": [
            { "id": 0, "parentId": null, "type": "document", "children": [1], "data": {} },
            { "id": 1, "parentId": 0, "type": "paragraph", "children": [2],
              "data": { "style": {{styleJson}} } },
            { "id": 2, "parentId": 1, "type": "textRun", "children": [], "data": { "text": "short line", "style": {} } }
          ]
        }
        """;
        return System.Text.Json.JsonSerializer.Deserialize<RenderTree>(json)!;
    }

    /// <summary>Real-corpus invariant (the lead's ask #3): sweep the WHOLE document the way
    /// repeated PageDown does (see the class doc above), then assert no VISUALLY EMPTY top-level
    /// block — a Text block with zero rendered characters, or an Image block with neither a
    /// resource id nor a placeholder label to draw — ever reserves more than one viewport's worth
    /// of height. This is the invariant that would have failed had the mechanism above been what
    /// the VM saw; today it passes, pinning "no such block exists in this corpus" as a fact this
    /// suite checks going forward rather than assumes.</summary>
    [Fact]
    public void No_visually_empty_top_level_block_in_the_reported_document_exceeds_one_viewport_height()
    {
        var repoRoot = FindRepoRoot();
        var engineLib = Path.Combine(repoRoot, "rust", "dist", "xplat", "macos-arm64", "libfastdoc_engine_ffi.dylib");
        Environment.SetEnvironmentVariable("FASTDOC_ENGINE_LIB", engineLib);
        var path = Path.Combine(repoRoot, "testdocs", "mini", "s9-picture-crop.hwp");
        var result = RenderTreeLoader.Load(path);
        try
        {
            Assert.True(result.IsOk, $"load failed: {result.Error?.Kind} {result.Error?.Message}");

            var view = new FlowDocumentView();
            view.SetTree(result.Tree);
            view.SetHandle(result.Handle);
            const double viewportHeight = 900.0;
            var window = new Window { Width = viewportHeight, Height = viewportHeight, Content = view };
            window.Show();
            window.CaptureRenderedFrame();

            // Sweep forward to the end so every block gets its TRUE (not estimated) height —
            // same discipline as the corpus scan this test's own investigation used.
            var guardSteps = 0;
            while (view.ScrollOffset < view.ContentHeight - viewportHeight && guardSteps < 1000)
            {
                view.ScrollOffset += viewportHeight * 0.8;
                window.CaptureRenderedFrame();
                guardSteps++;
            }
            Assert.True(guardSteps < 1000, "sweep did not converge — ContentHeight may not be settling");

            var blocks = GetPrivateField<List<FlowBlock>>(view, "_blocks");
            var heights = GetPrivateField<double[]>(view, "_blockHeights");
            var offsets = GetPrivateField<double[]>(view, "_offsets");

            // This document routinely uses short blank paragraphs as intentional spacing between
            // bureaucratic bullet points (measured: ~120 of them, each ~14-33px — normal Korean
            // government-document formatting, not a defect), so a document-wide "% blank" budget
            // would either reject THIS document as-is or be set so loose it catches nothing. The
            // invariant that actually matches the VM's report is per-block AND per-RUN: no single
            // visually-empty block, and no CONSECUTIVE run of them, ever reserves more than one
            // viewport's height — a run of many small intentional spacers still sums small; a
            // single oversized one (or the LineHeight mechanism the sibling test above documents)
            // would show up here as a run exceeding the budget.
            var isEmpty = new bool[blocks.Count];
            for (var i = 0; i < blocks.Count; i++)
            {
                var b = blocks[i];
                isEmpty[i] = b.Kind switch
                {
                    FlowBlockKind.Text => b.Runs.TrueForAll(r => r.Text.Length == 0),
                    FlowBlockKind.Image => b.ImageResourceId is null && string.IsNullOrEmpty(b.PlaceholderLabel),
                    _ => false,
                };
                Assert.True(!isEmpty[i] || heights[i] <= viewportHeight,
                    $"block i={i} nodeId={b.NodeId} kind={b.Kind} is visually empty but reserves {heights[i]:F0}px " +
                    $"(> one viewport of {viewportHeight}px) at y={offsets[i]:F0} — this is the shape of the VM's reported blank gap");
            }

            var runStart = -1;
            for (var i = 0; i <= blocks.Count; i++)
            {
                var empty = i < blocks.Count && isEmpty[i];
                if (empty && runStart < 0) { runStart = i; }
                else if (!empty && runStart >= 0)
                {
                    var runHeight = offsets[i] - offsets[runStart];
                    Assert.True(runHeight <= viewportHeight,
                        $"blocks i={runStart}..{i - 1} are a CONSECUTIVE run of visually-empty content " +
                        $"spanning {runHeight:F0}px (> one viewport of {viewportHeight}px) starting at y={offsets[runStart]:F0} " +
                        "— this is exactly the multi-screen blank stretch the VM reported");
                    runStart = -1;
                }
            }
        }
        finally
        {
            result.Handle?.Dispose();
        }
    }

    // --- S9-V (round 2): the reported VM blank region is at a PRECISE spot in
    // testdocs/mini/s9-picture-crop.hwp — the lead identified it via the app's own --extract
    // output (a "구분/사전 지원 제외/사후관리" pair of tables, one with a ~2,115-char cell, one
    // with a ~731-char cell) plus a 1-column/3-row cover-page table that shows a bordered box on
    // macOS but only bare title text on the Linux VM. Both are marked "<raw> [table — not a grid]"
    // by MarkdownSerializer, which only means a merged cell exists somewhere in the table (or a
    // nested table isn't itself simple) — a pure Extract/linearization concept, unrelated to any
    // special RenderTree node kind FlowDocumentBuilder/TableGridRenderer would need to special-case.
    //
    // These tests render the REAL FlowBlocks for exactly those three tables through the REAL
    // TableGridRenderer.Draw path into a genuine Skia bitmap (SkiaPageCanvas over a real SKCanvas —
    // the same harness PageModePainterSinglePageExportTests uses for pixel-level assertions) and
    // COUNT non-transparent pixels, per the lead's explicit instruction that a structural sweep
    // (block/height inspection) is not evidence of what actually got painted.

    private static string CellTextRecursive(TableGridCell cell)
    {
        var parts = new List<string>();
        foreach (var block in cell.Content)
        {
            if (block.Kind == FlowBlockKind.Text) { parts.Add(string.Concat(block.Runs.ConvertAll(r => r.Text))); }
            else if (block.Kind == FlowBlockKind.Table && block.Table is not null)
            {
                foreach (var row in block.Table.Rows)
                foreach (var c in row.Cells) { parts.Add(CellTextRecursive(c)); }
            }
        }
        return string.Concat(parts);
    }

    /// <summary>Every <see cref="TableGridModel"/> reachable from <paramref name="blocks"/>,
    /// including one nested inside another table's cell — a top-level-only scan would miss a
    /// suspect table that turns out to live inside a cell.</summary>
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

    private static int CountNonTransparentPixels(TableGridModel table)
    {
        const double columnWidth = 800;
        using var typeface = SkiaPageCanvas.LoadBundledTypeface();
        var estHeight = TableGridRenderer.EstimateHeight(table, columnWidth, fontScale: 1.0, imageRenderer: new ImageBlockRenderer());
        var bmpWidth = (int)Math.Ceiling(columnWidth) + 20;
        var bmpHeight = Math.Max(40, (int)Math.Ceiling(estHeight) + 40);
        using var bitmap = new SKBitmap(bmpWidth, bmpHeight);
        using var canvas = new SKCanvas(bitmap);
        canvas.Clear(SKColors.Transparent);
        var surface = new SkiaPageCanvas(canvas, typeface) { CurrentPageNumber = 1 };
        TableGridRenderer.Draw(surface, table, left: 10, top: 10, columnWidth: columnWidth, fontScale: 1.0,
            viewportTop: double.NegativeInfinity, viewportBottom: double.PositiveInfinity,
            cachedRowHeights: null, out _, rowIndicesToDraw: null, imageRenderer: new ImageBlockRenderer());

        var nonTransparent = 0;
        for (var y = 0; y < bmpHeight; y++)
        for (var x = 0; x < bmpWidth; x++)
        {
            if (bitmap.GetPixel(x, y).Alpha != 0) { nonTransparent++; }
        }
        return nonTransparent;
    }

    [Fact]
    public void The_two_precise_suspect_tables_and_the_cover_table_draw_real_non_transparent_pixels()
    {
        var repoRoot = FindRepoRoot();
        var engineLib = Path.Combine(repoRoot, "rust", "dist", "xplat", "macos-arm64", "libfastdoc_engine_ffi.dylib");
        Environment.SetEnvironmentVariable("FASTDOC_ENGINE_LIB", engineLib);
        var path = Path.Combine(repoRoot, "testdocs", "mini", "s9-picture-crop.hwp");
        var result = RenderTreeLoader.Load(path);
        try
        {
            Assert.True(result.IsOk, $"load failed: {result.Error?.Kind} {result.Error?.Message}");
            var blocks = FlowDocumentBuilder.Build(result.Tree!);

            var allTables = new List<TableGridModel>();
            CollectAllTables(blocks, allTables);

            // Precise cell-text signatures from the macOS --extract excerpt (docs/studio/sprints/
            // S9/s9c-flow-content.md): table A's body row starts "검토\n기준" and its long cell
            // contains "기업의 부도" (the ~2,115-char cell in the raw document); table B's body row
            // starts "조치" and its cell contains "주관기관" (the ~731-char cell).
            TableGridModel? tableA = null, tableB = null;
            foreach (var t in allTables)
            {
                var allText = string.Join(" || ", t.Rows.SelectMany(r => r.Cells).Select(CellTextRecursive));
                if (tableA is null && allText.Contains("검토") && allText.Contains("기업의 부도")) { tableA = t; }
                if (tableB is null && allText.Contains("조치") && allText.Contains("주관기관")) { tableB = t; }
            }
            Assert.True(tableA is not null, "could not find the '검토/기업의 부도' (~2,115-char cell) table by its exact extract text — the document or the extract excerpt may have drifted");
            Assert.True(tableB is not null, "could not find the '조치/주관기관' (~731-char cell) table by its exact extract text — the document or the extract excerpt may have drifted");

            // Cover-page table: 1 column, 3 rows, appearing near the start of the document.
            var coverTable = allTables.FirstOrDefault(t => t.ColumnCount == 1 && t.Rows.Count == 3);
            Assert.True(coverTable is not null, "could not find a 1-column/3-row cover-page table candidate");

            var pxA = CountNonTransparentPixels(tableA!);
            var pxB = CountNonTransparentPixels(tableB!);
            var pxCover = CountNonTransparentPixels(coverTable!);

            Assert.True(pxA > 0, "the '검토/기업의 부도' table drew ZERO non-transparent pixels — TableGridRenderer.Draw is skipping it");
            Assert.True(pxB > 0, "the '조치/주관기관' table drew ZERO non-transparent pixels — TableGridRenderer.Draw is skipping it");
            Assert.True(pxCover > 0, "the cover-page table drew ZERO non-transparent pixels — TableGridRenderer.Draw is skipping it");
        }
        finally
        {
            result.Handle?.Dispose();
        }
    }
}
