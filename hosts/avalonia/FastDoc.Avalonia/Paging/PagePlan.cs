using System;
using System.Buffers;
using System.Collections.Generic;
using System.Text.Json;
using FastDoc.Avalonia.Native;

namespace FastDoc.Avalonia.Paging;

/// <summary>One flow block as the page plan wants it: an opaque key (the RenderTree node id), the
/// page flags the document declared, and what THIS host measured — line boxes, a picture's height,
/// table row heights. No decision lives here; every "where does it go" question is the engine's
/// (`fastdoc_office_page_plan_json`).</summary>
internal sealed class PlanBlockInput
{
    public required long Key { get; init; }
    /// <summary>"text", "atomic" or "table" — the engine's `PlanKind`.</summary>
    public required string Kind { get; init; }
    public bool SectionStart { get; init; }
    public bool PageBreakBefore { get; init; }
    public bool KeepWithNext { get; init; }
    public bool Skip { get; init; }
    public bool Empty { get; init; }
    public double SpacingBefore { get; init; }
    public double SpacingAfter { get; init; }
    public double[]? Lines { get; set; }
    /// <summary>Text: the part of the last line box that is spacing under the glyphs (HWP), which a
    /// page may let hang past its foot — decided by the engine's line model (S3).</summary>
    public double Trailing { get; set; }
    public double Height { get; init; }
    public double[]? RowHeights { get; init; }
    public bool[]? RowCanBreakAbove { get; init; }
    public bool KeepsWhole { get; init; }
}

internal readonly record struct PlannedPage(int Section, long? FirstKey);

internal readonly record struct PlannedPlacement(int Block, int Page, double Top, double Height, int? RowStart, int? RowCount);

internal readonly record struct PlannedLine(int Block, int Line, int Page, double Top);

/// <summary>The engine's answer, in this host's terms. Positions are page-local points.</summary>
internal sealed class PagePlanResult
{
    public required int PageCount { get; init; }
    public required IReadOnlyList<PlannedPage> Pages { get; init; }
    public required IReadOnlyList<PlannedPlacement> Placements { get; init; }
    public required IReadOnlyList<PlannedLine> Lines { get; init; }
    public required int SplitTableCount { get; init; }
    public required int CarriedTableCount { get; init; }
    public required int DroppedBreakCount { get; init; }
}

/// <summary>S2 of docs/plans/pagination-to-engine.md: the one call that decides where every whole
/// block of a paged document goes. There is no second configuration — an engine that refuses the
/// input, or is not loaded, is a failure to report, not a reason to paginate here.</summary>
internal static class PagePlanClient
{
    private const int PlanVersion = 1;

    public static PagePlanResult Plan(IntPtr handle, double contentHeightPoints, bool splitTables,
        IReadOnlyDictionary<int, double>? noteBands, IReadOnlyList<PlanBlockInput> blocks)
    {
        var input = Encode(contentHeightPoints, splitTables, noteBands, blocks);
        var reply = FastdocEngine.TakeOwnedString(FastdocEngine.fastdoc_office_page_plan_json(handle, input));
        if (reply is null)
        {
            throw new InvalidOperationException("the engine built no page plan reply: " + FastdocEngine.TakeLastError());
        }
        return Decode(reply);
    }

    internal static byte[] Encode(double contentHeightPoints, bool splitTables,
        IReadOnlyDictionary<int, double>? noteBands, IReadOnlyList<PlanBlockInput> blocks)
    {
        var buffer = new ArrayBufferWriter<byte>(Math.Max(4096, blocks.Count * 96));
        using (var w = new Utf8JsonWriter(buffer))
        {
            w.WriteStartObject();
            w.WriteNumber("planVersion", PlanVersion);
            w.WriteNumber("contentHeight", contentHeightPoints);
            w.WriteBoolean("splitTables", splitTables);
            w.WriteStartArray("noteBands");
            if (noteBands is not null)
            {
                foreach (var (page, height) in noteBands)
                {
                    w.WriteStartObject();
                    w.WriteNumber("page", page);
                    w.WriteNumber("height", height);
                    w.WriteEndObject();
                }
            }
            w.WriteEndArray();
            w.WriteStartArray("blocks");
            foreach (var b in blocks) { WriteBlock(w, b); }
            w.WriteEndArray();
            w.WriteEndObject();
        }
        var bytes = new byte[buffer.WrittenCount + 1]; // NUL-terminated for `const char *`
        buffer.WrittenSpan.CopyTo(bytes);
        return bytes;
    }

    private static void WriteBlock(Utf8JsonWriter w, PlanBlockInput b)
    {
        w.WriteStartObject();
        w.WriteNumber("key", b.Key);
        w.WriteString("kind", b.Kind);
        if (b.SectionStart) { w.WriteBoolean("sectionStart", true); }
        if (b.PageBreakBefore) { w.WriteBoolean("pageBreakBefore", true); }
        if (b.KeepWithNext) { w.WriteBoolean("keepWithNext", true); }
        if (b.Skip) { w.WriteBoolean("skip", true); }
        if (b.Empty) { w.WriteBoolean("empty", true); }
        if (!b.Skip)
        {
            if (b.SpacingBefore != 0) { w.WriteNumber("spacingBefore", b.SpacingBefore); }
            if (b.SpacingAfter != 0) { w.WriteNumber("spacingAfter", b.SpacingAfter); }
            if (b.Lines is { } lines)
            {
                w.WriteStartArray("lines");
                foreach (var h in lines) { w.WriteNumberValue(h); }
                w.WriteEndArray();
            }
            if (b.Trailing != 0) { w.WriteNumber("trailing", b.Trailing); }
            if (b.Height != 0) { w.WriteNumber("height", b.Height); }
            if (b.RowHeights is { } rows)
            {
                w.WriteStartArray("rows");
                for (var r = 0; r < rows.Length; r++)
                {
                    w.WriteStartObject();
                    w.WriteNumber("height", rows[r]);
                    if (b.RowCanBreakAbove is { } breaks && r < breaks.Length && breaks[r])
                    {
                        w.WriteBoolean("canBreakAbove", true);
                    }
                    w.WriteEndObject();
                }
                w.WriteEndArray();
            }
            if (b.KeepsWhole) { w.WriteBoolean("keepsWhole", true); }
        }
        w.WriteEndObject();
    }

    internal static PagePlanResult Decode(string reply)
    {
        using var doc = JsonDocument.Parse(reply);
        var root = doc.RootElement;
        if (root.TryGetProperty("error", out var error))
        {
            var kind = error.TryGetProperty("kind", out var k) ? k.GetString() : "unknown";
            var message = error.TryGetProperty("message", out var m) ? m.GetString() : "";
            throw new InvalidOperationException($"the engine refused the page plan input ({kind}): {message}");
        }
        var plan = root.GetProperty("ok");

        var pages = new List<PlannedPage>();
        foreach (var p in plan.GetProperty("pages").EnumerateArray())
        {
            pages.Add(new PlannedPage(p.GetProperty("section").GetInt32(),
                p.TryGetProperty("firstKey", out var key) ? key.GetInt64() : null));
        }
        var placements = new List<PlannedPlacement>();
        foreach (var p in plan.GetProperty("placements").EnumerateArray())
        {
            placements.Add(new PlannedPlacement(p.GetProperty("block").GetInt32(), p.GetProperty("page").GetInt32(),
                p.GetProperty("top").GetDouble(), p.GetProperty("height").GetDouble(),
                p.TryGetProperty("rowStart", out var rs) ? rs.GetInt32() : null,
                p.TryGetProperty("rowCount", out var rc) ? rc.GetInt32() : null));
        }
        var lineArray = plan.GetProperty("lines");
        var lines = new List<PlannedLine>(lineArray.GetArrayLength());
        foreach (var l in lineArray.EnumerateArray())
        {
            lines.Add(new PlannedLine(l[0].GetInt32(), l[1].GetInt32(), l[2].GetInt32(), l[3].GetDouble()));
        }
        return new PagePlanResult
        {
            PageCount = plan.GetProperty("pageCount").GetInt32(),
            Pages = pages,
            Placements = placements,
            Lines = lines,
            SplitTableCount = plan.GetProperty("splitTableCount").GetInt32(),
            CarriedTableCount = plan.GetProperty("carriedTableCount").GetInt32(),
            DroppedBreakCount = plan.GetProperty("droppedBreakCount").GetInt32(),
        };
    }
}
