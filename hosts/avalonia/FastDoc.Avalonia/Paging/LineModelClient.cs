using System;
using System.Buffers;
using System.Collections.Generic;
using System.Text.Json;
using FastDoc.Avalonia.Native;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Paging;

/// <summary>One paragraph as this host measured it plus the facts the document declared — the
/// engine's `ParagraphFacts` (`render/office/line_model.rs`). No rule is applied here: the host
/// reports each line's natural box and the engine says what the document's line-height rule, HWP's
/// below-the-glyphs spacing and an empty cell paragraph's size make of it.</summary>
internal sealed class ParagraphFactsIn
{
    public double[] Lines { get; init; } = Array.Empty<double>();
    public bool Blank { get; init; }
    public LineHeightRule Rule { get; init; } = LineHeightRule.Default;
    public bool HasRule { get; init; }
    public double CharSize { get; init; }
    public double SpacingBefore { get; init; }
    public double SpacingAfter { get; init; }
    public bool LineSpacingBelow { get; init; }

    /// <summary>The facts for a text block whose natural line boxes are <paramref name="lines"/>
    /// (one entry for a blank paragraph: the natural box of a line of its own size), in the unit
    /// <paramref name="scale"/> converts the document's points into — 1 for points, `96/72 × zoom` for
    /// the pixels a table cell is measured in. Every length the engine will add to a line box is
    /// scaled with them.</summary>
    public static ParagraphFactsIn From(FlowBlock block, double[] lines, bool blank, double scale = 1.0) => new()
    {
        Lines = lines,
        Blank = blank,
        Rule = block.LineHeight.ScaledBy(scale),
        HasRule = !block.LineHeight.Equals(LineHeightRule.Default),
        CharSize = block.CharSizePoints * scale,
        SpacingBefore = block.SpacingBeforePoints * scale,
        SpacingAfter = block.SpacingAfterPoints * scale,
        LineSpacingBelow = block.LineSpacingBelow,
    };
}

/// <summary>A cell's content, stacked: consecutive paragraphs or a box the host already sized.</summary>
internal sealed class CellItemIn
{
    public List<ParagraphFactsIn>? Paragraphs { get; init; }
    public double FixedHeight { get; init; }
    public bool IsText => Paragraphs is not null;
}

internal sealed class CellFactsIn
{
    public required int Row { get; init; }
    public int RowSpan { get; init; } = 1;
    public double VPadding { get; init; }
    public double? DeclaredHeight { get; init; }
    public double? MinRowHeight { get; init; }
    public List<CellItemIn> Items { get; init; } = new();
}

internal sealed class TableFactsIn
{
    public required int RowCount { get; init; }
    public double EmptyLine { get; init; }
    public double RowPadding { get; init; }
    public bool DropsTrailingGap { get; init; }
    public List<CellFactsIn> Cells { get; init; } = new();
}

internal readonly record struct ParagraphAnswer(double[] Heights, double Trailing);

/// <summary>Where each line of a cell paragraph stands, relative to the cell's content origin.</summary>
internal sealed class ParagraphLayoutOut
{
    public required double[] Tops { get; init; }
    public required double[] Heights { get; init; }
    /// <summary>The part of each line's box that is spacing under the glyphs, which a page may let
    /// hang past its foot (the page plan's cell lines carry it).</summary>
    public double Trailing { get; init; }
}

internal sealed class CellItemLayoutOut
{
    public List<ParagraphLayoutOut>? Paragraphs { get; init; }
    public double Top { get; init; }
    public double Height { get; init; }
}

internal sealed class CellLayoutOut
{
    public required double Height { get; init; }
    public required List<CellItemLayoutOut> Items { get; init; }
}

internal sealed class TableLayoutOut
{
    public required double[] RowHeights { get; init; }
    public required List<CellLayoutOut> Cells { get; init; }
}

/// <summary>S3 of docs/plans/pagination-to-engine.md: the one call that turns the line boxes this
/// host measured into the heights the document asks for (`fastdoc_office_line_model_json`). An engine
/// that refuses the input or is not loaded is a failure to report, not a reason to apply the rules
/// here.</summary>
internal static class LineModelClient
{
    private const int ModelVersion = 1;

    public static (ParagraphAnswer[] Paragraphs, TableLayoutOut[] Tables) Solve(double? gridPitch,
        IReadOnlyList<ParagraphFactsIn> paragraphs, IReadOnlyList<TableFactsIn> tables)
    {
        var input = Encode(gridPitch, paragraphs, tables);
        var reply = FastdocEngine.TakeOwnedString(FastdocEngine.fastdoc_office_line_model_json(input));
        if (reply is null)
        {
            throw new InvalidOperationException("the engine built no line model reply: " + FastdocEngine.TakeLastError());
        }
        return Decode(reply);
    }

    internal static byte[] Encode(double? gridPitch, IReadOnlyList<ParagraphFactsIn> paragraphs, IReadOnlyList<TableFactsIn> tables)
    {
        var buffer = new ArrayBufferWriter<byte>(4096);
        using (var w = new Utf8JsonWriter(buffer))
        {
            w.WriteStartObject();
            w.WriteNumber("version", ModelVersion);
            if (gridPitch is > 0) { w.WriteNumber("gridPitch", gridPitch.Value); }
            w.WriteStartArray("paragraphs");
            foreach (var p in paragraphs) { WriteParagraph(w, p); }
            w.WriteEndArray();
            w.WriteStartArray("tables");
            foreach (var t in tables) { WriteTable(w, t); }
            w.WriteEndArray();
            w.WriteEndObject();
        }
        var bytes = new byte[buffer.WrittenCount + 1]; // NUL-terminated for `const char *`
        buffer.WrittenSpan.CopyTo(bytes);
        return bytes;
    }

    private static void WriteParagraph(Utf8JsonWriter w, ParagraphFactsIn p)
    {
        w.WriteStartObject();
        w.WriteStartArray("lines");
        foreach (var h in p.Lines) { w.WriteNumberValue(h); }
        w.WriteEndArray();
        if (p.Blank) { w.WriteBoolean("blank", true); }
        if (p.HasRule)
        {
            w.WriteStartObject("rule");
            w.WriteString("mode", p.Rule.Mode switch
            {
                LineHeightMode.Exact => "exact",
                LineHeightMode.AtLeast => "atLeast",
                _ => "multiple",
            });
            w.WriteNumber("value", p.Rule.Value);
            w.WriteEndObject();
        }
        if (p.CharSize != 0) { w.WriteNumber("charSize", p.CharSize); }
        if (p.SpacingBefore != 0) { w.WriteNumber("spacingBefore", p.SpacingBefore); }
        if (p.SpacingAfter != 0) { w.WriteNumber("spacingAfter", p.SpacingAfter); }
        if (p.LineSpacingBelow) { w.WriteBoolean("lineSpacingBelow", true); }
        w.WriteEndObject();
    }

    private static void WriteTable(Utf8JsonWriter w, TableFactsIn t)
    {
        w.WriteStartObject();
        w.WriteNumber("rowCount", t.RowCount);
        w.WriteNumber("emptyLine", t.EmptyLine);
        w.WriteNumber("rowPadding", t.RowPadding);
        if (t.DropsTrailingGap) { w.WriteBoolean("dropsTrailingGap", true); }
        w.WriteStartArray("cells");
        foreach (var cell in t.Cells)
        {
            w.WriteStartObject();
            w.WriteNumber("row", cell.Row);
            if (cell.RowSpan != 1) { w.WriteNumber("rowSpan", cell.RowSpan); }
            w.WriteNumber("vPadding", cell.VPadding);
            if (cell.DeclaredHeight is { } declared) { w.WriteNumber("declaredHeight", declared); }
            if (cell.MinRowHeight is { } minimum) { w.WriteNumber("minRowHeight", minimum); }
            w.WriteStartArray("items");
            foreach (var item in cell.Items)
            {
                w.WriteStartObject();
                if (item.IsText)
                {
                    w.WriteString("kind", "text");
                    w.WriteStartArray("paragraphs");
                    foreach (var p in item.Paragraphs!) { WriteParagraph(w, p); }
                    w.WriteEndArray();
                }
                else
                {
                    w.WriteString("kind", "fixed");
                    w.WriteNumber("height", item.FixedHeight);
                }
                w.WriteEndObject();
            }
            w.WriteEndArray();
            w.WriteEndObject();
        }
        w.WriteEndArray();
        w.WriteEndObject();
    }

    internal static (ParagraphAnswer[] Paragraphs, TableLayoutOut[] Tables) Decode(string reply)
    {
        using var doc = JsonDocument.Parse(reply);
        var root = doc.RootElement;
        if (root.TryGetProperty("error", out var error))
        {
            var kind = error.TryGetProperty("kind", out var k) ? k.GetString() : "unknown";
            var message = error.TryGetProperty("message", out var m) ? m.GetString() : "";
            throw new InvalidOperationException($"the engine refused the line model input ({kind}): {message}");
        }
        var ok = root.GetProperty("ok");
        var paragraphs = new List<ParagraphAnswer>();
        foreach (var p in ok.GetProperty("paragraphs").EnumerateArray())
        {
            paragraphs.Add(new ParagraphAnswer(Doubles(p.GetProperty("heights")), p.GetProperty("trailing").GetDouble()));
        }
        var tables = new List<TableLayoutOut>();
        foreach (var t in ok.GetProperty("tables").EnumerateArray())
        {
            var cells = new List<CellLayoutOut>();
            foreach (var c in t.GetProperty("cells").EnumerateArray())
            {
                var items = new List<CellItemLayoutOut>();
                foreach (var item in c.GetProperty("items").EnumerateArray())
                {
                    if (item.GetProperty("kind").GetString() == "text")
                    {
                        var laid = new List<ParagraphLayoutOut>();
                        foreach (var p in item.GetProperty("paragraphs").EnumerateArray())
                        {
                            laid.Add(new ParagraphLayoutOut
                            {
                                Tops = Doubles(p.GetProperty("tops")),
                                Heights = Doubles(p.GetProperty("heights")),
                                Trailing = p.GetProperty("trailing").GetDouble(),
                            });
                        }
                        items.Add(new CellItemLayoutOut { Paragraphs = laid });
                    }
                    else
                    {
                        items.Add(new CellItemLayoutOut { Top = item.GetProperty("top").GetDouble(), Height = item.GetProperty("height").GetDouble() });
                    }
                }
                cells.Add(new CellLayoutOut { Height = c.GetProperty("height").GetDouble(), Items = items });
            }
            tables.Add(new TableLayoutOut { RowHeights = Doubles(t.GetProperty("rowHeights")), Cells = cells });
        }
        return (paragraphs.ToArray(), tables.ToArray());
    }

    private static double[] Doubles(JsonElement array)
    {
        var result = new double[array.GetArrayLength()];
        var i = 0;
        foreach (var e in array.EnumerateArray()) { result[i++] = e.GetDouble(); }
        return result;
    }
}
