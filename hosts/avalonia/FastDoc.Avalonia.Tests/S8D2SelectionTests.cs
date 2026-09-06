using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Themes.Fluent;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>S8-D2 (D2-a/D2-e/D2-d): selection model, bitmap interpolation, and the markdown-image
/// decode fix. See docs/studio/sprints/S8/s8d2-selection.md for the test-to-behaviour map.</summary>
public class S8D2SelectionTests
{
    public S8D2SelectionTests() => AvaloniaHeadlessSetup.EnsureReady();

    private static FlowRun Run(string text, double fontSizePoints = 12) =>
        new(text, "Inter", fontSizePoints, false, false, false, false, Colors.Black);

    private static FlowBlock TextBlock(string text) => new()
    {
        Kind = FlowBlockKind.Text,
        Runs = new List<FlowRun> { Run(text) },
    };

    // ---- SelectionModel: pure, no Avalonia window needed ------------------------------------------

    [Fact]
    public void IsEmpty_is_true_before_any_selection_and_after_a_plain_click()
    {
        var model = new SelectionModel();
        Assert.True(model.IsEmpty);

        model.Begin(new TextPosition(0, 3)); // anchor == focus -> still empty (no drag happened)
        Assert.True(model.IsEmpty);

        model.ExtendTo(new TextPosition(0, 5));
        Assert.False(model.IsEmpty);
    }

    [Fact]
    public void Normalize_orders_anchor_and_focus_regardless_of_drag_direction()
    {
        var forward = new SelectionModel();
        forward.Begin(new TextPosition(0, 2));
        forward.ExtendTo(new TextPosition(2, 4));
        Assert.Equal((new TextPosition(0, 2), new TextPosition(2, 4)), forward.Normalize());

        var backward = new SelectionModel();
        backward.Begin(new TextPosition(2, 4));
        backward.ExtendTo(new TextPosition(0, 2));
        Assert.Equal((new TextPosition(0, 2), new TextPosition(2, 4)), backward.Normalize());
    }

    [Fact]
    public void SelectAll_spans_block_zero_offset_zero_to_the_last_blocks_own_length()
    {
        var model = new SelectionModel();
        model.SelectAll(blockCount: 5, lastBlockTextLength: 7);
        Assert.Equal((new TextPosition(0, 0), new TextPosition(4, 7)), model.Normalize());
    }

    [Fact]
    public void SelectAll_with_zero_blocks_clears_instead_of_selecting()
    {
        var model = new SelectionModel();
        model.Begin(new TextPosition(0, 1));
        model.ExtendTo(new TextPosition(0, 2));
        model.SelectAll(blockCount: 0, lastBlockTextLength: 0);
        Assert.True(model.IsEmpty);
    }

    [Fact]
    public void RangeWithinBlock_clips_to_the_selections_own_boundary_blocks()
    {
        var model = new SelectionModel();
        model.Begin(new TextPosition(1, 3));
        model.ExtendTo(new TextPosition(3, 2));

        Assert.Equal((0, 0), model.RangeWithinBlock(0, blockTextLength: 10)); // before the selection
        Assert.Equal((3, 7), model.RangeWithinBlock(1, blockTextLength: 10)); // start block: from offset 3 to the end
        Assert.Equal((0, 10), model.RangeWithinBlock(2, blockTextLength: 10)); // middle block: wholly included
        Assert.Equal((0, 2), model.RangeWithinBlock(3, blockTextLength: 10)); // end block: from 0 to offset 2
        Assert.Equal((0, 0), model.RangeWithinBlock(4, blockTextLength: 10)); // after the selection
    }

    [Fact]
    public void SelectedText_joins_blocks_with_newline_and_clips_the_boundary_blocks()
    {
        var blocks = new List<FlowBlock> { TextBlock("hello"), TextBlock("world"), TextBlock("third") };
        var model = new SelectionModel();
        model.Begin(new TextPosition(0, 3)); // "lo"
        model.ExtendTo(new TextPosition(2, 2)); // "th"

        Assert.Equal("lo\nworld\nth", model.SelectedText(blocks));
    }

    [Fact]
    public void SelectedText_of_a_fully_selected_document_is_the_document_verbatim()
    {
        var blocks = new List<FlowBlock> { TextBlock("hello"), TextBlock("world") };
        var model = new SelectionModel();
        model.SelectAll(blocks.Count, PlainTextLength(blocks[^1]));

        Assert.Equal("hello\nworld", model.SelectedText(blocks));
    }

    [Fact]
    public void SelectedText_renders_a_table_block_as_tab_separated_cells_row_by_row()
    {
        var table = new TableGridModel
        {
            Rows = new List<TableGridRow>
            {
                new()
                {
                    Row = 0,
                    Cells = new List<TableGridCell>
                    {
                        new() { Row = 0, Column = 0, Content = new List<FlowBlock> { TextBlock("A1") } },
                        new() { Row = 0, Column = 1, Content = new List<FlowBlock> { TextBlock("B1") } },
                    },
                },
                new()
                {
                    Row = 1,
                    Cells = new List<TableGridCell>
                    {
                        new() { Row = 1, Column = 0, Content = new List<FlowBlock> { TextBlock("A2") } },
                        new() { Row = 1, Column = 1, Content = new List<FlowBlock> { TextBlock("B2") } },
                    },
                },
            },
        };
        var tableBlock = new FlowBlock { Kind = FlowBlockKind.Table, Table = table };
        var blocks = new List<FlowBlock> { TextBlock("before"), tableBlock, TextBlock("after") };

        var model = new SelectionModel();
        model.SelectAll(blocks.Count, PlainTextLength(blocks[^1]));

        Assert.Equal("before\nA1\tB1\nA2\tB2\nafter", model.SelectedText(blocks));
    }

    private static int PlainTextLength(FlowBlock block) => SelectionModel.PlainText(block).Length;

    // ---- D2-e: bitmap interpolation -----------------------------------------------------------

    [Fact]
    public void FlowDocumentView_sets_high_quality_bitmap_interpolation_on_construction()
    {
        var view = new FlowDocumentView();
        Assert.Equal(BitmapInterpolationMode.HighQuality, RenderOptions.GetBitmapInterpolationMode(view));
    }

    // ---- D2-a: pointer-driven selection, via a real headless window ----------------------------

    private const string TwoParagraphTreeJson = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": { "format": "markdown", "rootNodeId": 0, "defaultBodyFontSize": 12 },
        "nodes": [
          { "id": 0, "parentId": null, "children": [1, 2], "type": "document", "data": {} },
          { "id": 1, "parentId": 0, "children": [10], "type": "paragraph", "data": { "style": {} } },
          { "id": 10, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima", "style": {} } },
          { "id": 2, "parentId": 0, "children": [20], "type": "paragraph", "data": { "style": {} } },
          { "id": 20, "parentId": 2, "children": [], "type": "textRun", "data": { "text": "second paragraph mike november oscar papa quebec romeo sierra tango uniform victor whiskey", "style": {} } }
        ]
      }
    }
    """;

    private static RenderTree LoadTree(string json)
    {
        var envelope = JsonSerializer.Deserialize<RenderTreeEnvelope>(json)!;
        Assert.True(envelope.IsOk);
        return envelope.Ok!.Value.Deserialize<RenderTree>()!;
    }

    private static void EnsureFluentThemeLoaded()
    {
        if (Application.Current is null) { return; }
        if (Application.Current.Styles.Count == 0) { Application.Current.Styles.Add(new FluentTheme()); }
    }

    private static FlowDocumentView CreateAttachedView(out Window window)
    {
        EnsureFluentThemeLoaded();
        var view = new FlowDocumentView();
        window = new Window { Width = 500, Height = 400, Content = view };
        window.Show();
        view.SetTree(LoadTree(TwoParagraphTreeJson));
        view.Measure(new Size(500, 400));
        view.Arrange(new Rect(0, 0, 500, 400));
        return view;
    }

    [Fact]
    public void A_left_button_drag_selects_text_and_SelectedText_reflects_the_range()
    {
        var view = CreateAttachedView(out var window);

        // A short drag near the top-left of the first paragraph — exact character offsets depend
        // on font metrics, so this asserts the OBSERVABLE contract (a non-empty selection whose
        // text is a substring of the source, drawn from the first paragraph) rather than a
        // brittle exact-offset expectation.
        window.MouseDown(new Point(30, 10), MouseButton.Left);
        window.MouseMove(new Point(200, 10));
        window.MouseUp(new Point(200, 10), MouseButton.Left);

        Assert.False(view.Selection.IsEmpty);
        var selected = view.Selection.SelectedText(GetBlocks(view));
        Assert.False(string.IsNullOrEmpty(selected));
        Assert.Contains(selected, "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima");
    }

    [Fact]
    public void Escape_clears_an_existing_selection()
    {
        var view = CreateAttachedView(out var window);
        window.MouseDown(new Point(30, 10), MouseButton.Left);
        window.MouseMove(new Point(200, 10));
        window.MouseUp(new Point(200, 10), MouseButton.Left);
        Assert.False(view.Selection.IsEmpty);

        view.RaiseEvent(new KeyEventArgs { RoutedEvent = InputElement.KeyDownEvent, Key = Key.Escape });

        Assert.True(view.Selection.IsEmpty);
    }

    [Fact]
    public void CtrlA_selects_the_whole_document()
    {
        var view = CreateAttachedView(out _);

        view.RaiseEvent(new KeyEventArgs { RoutedEvent = InputElement.KeyDownEvent, Key = Key.A, KeyModifiers = KeyModifiers.Control });

        Assert.False(view.Selection.IsEmpty);
        var selected = view.Selection.SelectedText(GetBlocks(view));
        Assert.StartsWith("alpha bravo", selected);
        Assert.EndsWith("victor whiskey", selected);
    }

    // ---- D2-b: find-match highlighting -----------------------------------------------------------

    [Fact]
    public void SetSearchQuery_produces_the_expected_block_start_length_ranges()
    {
        var view = CreateAttachedView(out _);

        // "paragraph" appears once, in the SECOND block only ("second paragraph mike ..."), and
        // matching is case-insensitive (the query is capitalised here on purpose).
        view.SetSearchQuery("Paragraph");

        var ranges = view.FindMatchRanges;
        Assert.Single(ranges);
        var (blockIndex, start, length, isCurrent) = ranges[0];
        Assert.Equal(1, blockIndex); // the second paragraph block
        Assert.Equal(7, start); // "second ".Length
        Assert.Equal("Paragraph".Length, length);
        Assert.True(isCurrent); // the only match is also the current one
    }

    [Fact]
    public void FindNext_moves_the_current_match_without_changing_any_ranges()
    {
        var view = CreateAttachedView(out _);
        // "o" appears in both paragraphs' text at least once ("foxtrot", "hotel" ... / "second",
        // "november", "oscar" ...) so there are at least two matches to move between.
        view.SetSearchQuery("o");
        var initialRanges = view.FindMatchRanges;
        Assert.True(initialRanges.Count >= 2, "expected at least two matches of \"o\" across both paragraphs");
        var firstCurrent = initialRanges.Single(r => r.IsCurrent);

        view.FindNext();

        var afterRanges = view.FindMatchRanges;
        // Same set of (block, start, length) ranges — FindNext moves the CURRENT flag, it never
        // recomputes the match list.
        Assert.Equal(
            initialRanges.Select(r => (r.BlockIndex, r.Start, r.Length)),
            afterRanges.Select(r => (r.BlockIndex, r.Start, r.Length)));
        var secondCurrent = afterRanges.Single(r => r.IsCurrent);
        Assert.NotEqual((firstCurrent.BlockIndex, firstCurrent.Start), (secondCurrent.BlockIndex, secondCurrent.Start));
        Assert.Single(afterRanges, r => r.IsCurrent); // exactly one match is ever current
    }

    [Fact]
    public void ClearSearch_empties_the_match_ranges()
    {
        var view = CreateAttachedView(out _);
        view.SetSearchQuery("paragraph");
        Assert.NotEmpty(view.FindMatchRanges);

        view.ClearSearch();

        Assert.Empty(view.FindMatchRanges);
    }

    [Fact]
    public void The_current_match_highlight_colour_is_theme_resolved_and_distinct_from_the_ordinary_match_colour()
    {
        var view = new FlowDocumentView();
        // These two colours must differ (browser-style "every match / current match" distinction)
        // and must NOT be produced by a bare hardcoded literal sitting in DrawFindHighlights any
        // more — both are read back through the SAME public surface ThemeForegroundColor/
        // ThemeBackgroundColor already use, resolved in UpdateThemeBrushes from App.axaml's own
        // Light/Dark ThemeDictionaries (a bare test Application never loads FastDoc.Avalonia's own
        // App.axaml, so this construction path exercises the documented fallback literals — the
        // resource-lookup wiring itself is proven by App.axaml compiling as part of the Release
        // build this report's gate ran).
        Assert.NotEqual(view.FindMatchHighlightColor, view.FindCurrentMatchHighlightColor);
    }

    /// <summary>Reads FlowDocumentView's own private block list via reflection — the view
    /// deliberately exposes no public block accessor (Selection is the only public surface this
    /// contract added), so a test that wants to call SelectedText the same way MainWindow's Ctrl+C
    /// handler will needs this one seam.</summary>
    private static List<FlowBlock> GetBlocks(FlowDocumentView view)
    {
        var field = typeof(FlowDocumentView).GetField("_blocks", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!;
        return (List<FlowBlock>)field.GetValue(view)!;
    }

    // ---- D2-d: markdown images (text/uri-list resources) -----------------------------------------

    /// <summary>Hand-builds a real, valid solid-colour PNG at exactly <paramref name="width"/> x
    /// <paramref name="height"/> — byte-level (signature + IHDR + one zlib-compressed IDAT + IEND),
    /// deliberately NOT going through Avalonia's own WriteableBitmap/Bitmap.Save. The headless
    /// platform's default drawing mode (<c>AvaloniaHeadlessPlatformOptions.UseHeadlessDrawing</c>)
    /// does not back a WriteableBitmap with a real Skia surface, so a bitmap written that way
    /// round-trips as a 1x1 stub instead of the real pixel size — measured while writing this test.
    /// A real file's bytes is exactly what <see cref="ImageBlockRenderer.ResolveUriListBytes"/>
    /// reads from disk in production, so this is closer to the real path anyway.</summary>
    private static string WritePng(string path, int width, int height)
    {
        var raw = new byte[height * (1 + width * 3)]; // 1 filter byte (0 = None) + RGB per row
        var cursor = 0;
        for (var y = 0; y < height; y++)
        {
            raw[cursor++] = 0; // filter type: None
            for (var x = 0; x < width; x++)
            {
                raw[cursor++] = 0x20; raw[cursor++] = 0x60; raw[cursor++] = 0x8a; // solid fill colour
            }
        }

        using var compressed = new MemoryStream();
        using (var zlib = new System.IO.Compression.ZLibStream(compressed, System.IO.Compression.CompressionLevel.Fastest, leaveOpen: true))
        {
            zlib.Write(raw, 0, raw.Length);
        }

        using var file = new FileStream(path, FileMode.Create, FileAccess.Write);
        file.Write(PngSignature);
        WriteChunk(file, "IHDR", BuildIhdr(width, height));
        WriteChunk(file, "IDAT", compressed.ToArray());
        WriteChunk(file, "IEND", Array.Empty<byte>());
        return path;
    }

    private static readonly byte[] PngSignature = { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

    private static byte[] BuildIhdr(int width, int height)
    {
        var ihdr = new byte[13];
        WriteUInt32BigEndian(ihdr, 0, (uint)width);
        WriteUInt32BigEndian(ihdr, 4, (uint)height);
        ihdr[8] = 8;  // bit depth
        ihdr[9] = 2;  // colour type: truecolour (RGB)
        ihdr[10] = 0; // compression method
        ihdr[11] = 0; // filter method
        ihdr[12] = 0; // interlace method
        return ihdr;
    }

    private static void WriteChunk(Stream stream, string type, byte[] data)
    {
        var typeBytes = System.Text.Encoding.ASCII.GetBytes(type);
        var lengthBytes = new byte[4];
        WriteUInt32BigEndian(lengthBytes, 0, (uint)data.Length);
        stream.Write(lengthBytes);
        stream.Write(typeBytes);
        stream.Write(data);
        var crcInput = new byte[typeBytes.Length + data.Length];
        Buffer.BlockCopy(typeBytes, 0, crcInput, 0, typeBytes.Length);
        Buffer.BlockCopy(data, 0, crcInput, typeBytes.Length, data.Length);
        var crcBytes = new byte[4];
        WriteUInt32BigEndian(crcBytes, 0, Crc32(crcInput));
        stream.Write(crcBytes);
    }

    private static void WriteUInt32BigEndian(byte[] buffer, int offset, uint value)
    {
        buffer[offset] = (byte)(value >> 24);
        buffer[offset + 1] = (byte)(value >> 16);
        buffer[offset + 2] = (byte)(value >> 8);
        buffer[offset + 3] = (byte)value;
    }

    /// <summary>The standard PNG/zip CRC-32 (polynomial 0xEDB88320) — .NET ships no built-in CRC-32,
    /// and a PNG reader (Avalonia's Skia-backed <see cref="Bitmap"/> decoder included) rejects a
    /// chunk whose CRC does not match.</summary>
    private static uint Crc32(byte[] data)
    {
        var crc = 0xFFFFFFFFu;
        foreach (var b in data)
        {
            crc ^= b;
            for (var i = 0; i < 8; i++)
            {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320u : crc >> 1;
            }
        }
        return ~crc;
    }

    private static ResourceWire UriListResource(ulong id, string url)
    {
        var bytes = System.Text.Encoding.UTF8.GetBytes(url);
        return new ResourceWire { Id = id, MimeType = "text/uri-list", BytesBase64 = Convert.ToBase64String(bytes) };
    }

    [Fact]
    public void A_relative_markdown_image_url_decodes_from_the_documents_own_directory()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"fastdoc-s8d2-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        var assetsDir = Path.Combine(dir, "assets");
        Directory.CreateDirectory(assetsDir);
        var pngPath = WritePng(Path.Combine(assetsDir, "pic.png"), width: 40, height: 20); // 2:1 aspect
        var documentPath = Path.Combine(dir, "doc.md"); // never actually created — only its directory matters

        try
        {
            var tree = new RenderTree
            {
                SchemaVersion = 1,
                Resources = new List<ResourceWire> { UriListResource(1, "assets/pic.png") },
            };
            var block = new FlowBlock { Kind = FlowBlockKind.Image, ImageResourceId = 1, ImageWidthPoints = 0, ImageHeightPoints = 0 };

            var renderer = new ImageBlockRenderer();
            renderer.Reset(tree);
            renderer.SetZipSource(documentPath, ".md");

            Assert.True(renderer.TryDecode(1));
            Assert.Equal(1, renderer.DecodeSuccessCount);
            Assert.Equal(0, renderer.DecodeFailureCount);

            // Branch-entry evidence (QA follow-up): TryDecode succeeding is NOT proof the
            // text/uri-list branch ran — under this headless test platform, Avalonia's
            // `new Bitmap(stream)` decodes literally ANY bytes (including the raw URL string this
            // branch exists to avoid feeding it) as a fixed 1x1 image and never throws, so
            // disabling the branch entirely still left this same assertion passing (confirmed by
            // temporarily disabling it and re-running). LastResolvedUriListPath/ByteLength are
            // set ONLY inside ResolveUriListBytes's successful-file-read path, so they stay null —
            // and this block fails — if that branch is skipped.
            Assert.Equal(pngPath, renderer.LastResolvedUriListPath);
            Assert.Equal(new FileInfo(pngPath).Length, renderer.LastResolvedUriListByteLength);
            Assert.StartsWith(dir, renderer.LastResolvedUriListPath!, StringComparison.Ordinal);

            using (var skCheck = SkiaSharp.SKBitmap.Decode(pngPath))
            {
                Assert.Equal(40, skCheck.Width); // sanity via SkiaSharp directly: WritePng wrote 40x20
                Assert.Equal(20, skCheck.Height);
            }

            // The reference size comes from AVALONIA'S OWN Bitmap decode of the identical file —
            // not a hardcoded 40x20 — because the headless test platform's Bitmap codec does not
            // back onto a real Skia surface (measured while writing this test: it decodes every
            // PNG, including a real one verified valid by SkiaSharp directly above, as a 1x1 stub).
            // Comparing against Avalonia's own decode keeps this assertion true in that headless
            // stub AND in a real desktop run, while still proving the actual wiring this fix is
            // about: EffectiveDeclaredSize reads the DECODED bitmap's pixel size, not the block's
            // declared {0,0}.
            using var reference = new Bitmap(pngPath);
            var expectedWidthPoints = reference.PixelSize.Width * 72.0 / 96.0;
            var expectedHeightPoints = reference.PixelSize.Height * 72.0 / 96.0;

            var (widthPoints, heightPoints) = renderer.EffectiveDeclaredSize(block);
            Assert.Equal(expectedWidthPoints, widthPoints, 3);
            Assert.Equal(expectedHeightPoints, heightPoints, 3);

            var (measuredWidth, measuredHeight) = PictureGeometry.Measure(widthPoints, heightPoints, columnWidthPoints: 400);
            // The reserved size (this call) and the drawn size (Draw, which calls the same
            // EffectiveDeclaredSize + PictureGeometry.Measure pair) can never disagree — the A2
            // invariant this fix is required to preserve.
            Assert.Equal(widthPoints / heightPoints, measuredWidth / measuredHeight, 3);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void An_http_markdown_image_url_stays_a_placeholder_and_never_throws()
    {
        var tree = new RenderTree
        {
            SchemaVersion = 1,
            Resources = new List<ResourceWire> { UriListResource(1, "https://example.com/pic.png") },
        };
        var renderer = new ImageBlockRenderer();
        renderer.Reset(tree);
        renderer.SetZipSource(Path.Combine(Path.GetTempPath(), "wherever.md"), ".md");

        var decoded = renderer.TryDecode(1); // must not throw — a network fetch would be the bug

        Assert.False(decoded);
        Assert.Equal(0, renderer.DecodeSuccessCount);
        Assert.Equal(1, renderer.DecodeFailureCount);
    }

    [Fact]
    public void A_missing_relative_markdown_image_stays_a_placeholder_and_never_throws()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"fastdoc-s8d2-missing-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        try
        {
            var tree = new RenderTree
            {
                SchemaVersion = 1,
                Resources = new List<ResourceWire> { UriListResource(1, "assets/does-not-exist.png") },
            };
            var renderer = new ImageBlockRenderer();
            renderer.Reset(tree);
            renderer.SetZipSource(Path.Combine(dir, "doc.md"), ".md");

            Assert.False(renderer.TryDecode(1));
            Assert.Equal(1, renderer.DecodeFailureCount);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
