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
    /// <summary>The block opens a document section: a fact. Whether that opens a sheet is the engine's call.</summary>
    public bool Section { get; init; }
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
    /// <summary>The page this block's first line lands on restarts the counter at this number (HWP's
    /// 새 번호), and the one it lands on prints none (쪽 번호 감추기). Facts the document states; the
    /// engine answers which page shows which number.</summary>
    public long? PageNumberRestart { get; init; }
    public bool HidesPageNumber { get; init; }
    /// <summary>The notes this block cites: the note number and, for a text block, the line holding
    /// its marker.</summary>
    public IReadOnlyList<PlanCiteInput>? Cites { get; init; }
    public double[]? RowHeights { get; init; }
    public bool[]? RowCanBreakAbove { get; init; }
    /// <summary>Per row, the cells that begin in it with the line boxes inside them — what lets the
    /// engine flow a table taller than a page line by line. Null when the host reports none.</summary>
    public PlanCellInput[][]? RowCells { get; init; }
    public bool KeepsWhole { get; init; }
    /// <summary>Table: <see cref="RowHeights"/> are the rows this host's own grid draws, so the engine
    /// keeps them rather than solving them again from the cells (macOS sends the same for every table
    /// outside a columned run).</summary>
    public bool RowsObserved { get; init; }
    /// <summary>The multi-column declaration (an index into <see cref="PlanColumnsInput.Runs"/>) this
    /// block sits under — from one declaration to the next. Null: not in a columned run.</summary>
    public int? ColumnRun { get; init; }
}

/// <summary>One multi-column declaration as the document states it: the count, the spacing and the
/// per-column widths and gaps (points, or shares of the whole when <see cref="Proportional"/>).</summary>
internal sealed class PlanColumnRunInput
{
    public required int Count { get; init; }
    public double Spacing { get; init; }
    public IReadOnlyList<double> Widths { get; init; } = Array.Empty<double>();
    public IReadOnlyList<double> Gaps { get; init; } = Array.Empty<double>();
    public bool Proportional { get; init; }
}

/// <summary>The columns of a document: the width of the page body they are dealt across, and each
/// declaration in document order. The engine decides what columns that makes.</summary>
internal sealed class PlanColumnsInput
{
    public required double BodyWidth { get; init; }
    public required IReadOnlyList<PlanColumnRunInput> Runs { get; init; }
}

/// <summary>One column of a declaration: its left edge from the body's left edge, and its width, in points.</summary>
public readonly record struct PlannedColumn(double X, double Width);

/// <summary>One row of a table in a columned run, as drawn in one column: page-local points.</summary>
internal readonly record struct PlannedColumnRowSegment(int Block, int Row, int Page, int Column, double Top, double Bottom);

/// <summary>One line inside a cell, in POINTS from the cell's content origin.</summary>
internal readonly record struct PlanLineInput(double Top, double Height, double Trailing);

internal sealed class PlanCellInput
{
    public int RowSpan { get; init; } = 1;
    public double PadTop { get; init; }
    public double PadBottom { get; init; }
    public double ContentHeight { get; init; }
    /// <summary>"middle" or "bottom" when the document puts the content there in the cell's box;
    /// null is top. The plan applies it.</summary>
    public string? VerticalAlign { get; init; }
    public required PlanLineInput[] Lines { get; init; }
}

internal readonly record struct PlanCiteInput(long Note, int? Line);

/// <summary>One running head, foot or master page the host holds, as the plan selects among them:
/// when it applies (the wire's "defaultPages"/"firstPage"/"evenPages"/"oddPages") and the one section
/// it belongs to (null: every section).</summary>
public readonly record struct PlanEntryInput(string AppliesTo, long? Section);

/// <summary>One note's height in points, at the width it is drawn at.</summary>
public readonly record struct PlanNoteInput(long Number, double Height);

/// <summary>What a section declared about the rule above its notes; absent sections get the reader's
/// own minimum.</summary>
public readonly record struct PlanSeparatorInput(int Section, long LineType, double LineWidth, double MarginTop,
    double MarginBottom, double NoteSpacing);

/// <summary>What the plan needs to answer for the SHEET rather than the flow: the entries to choose
/// among and the sections that veto them (S5 of docs/plans/pagination-to-engine.md), and the notes
/// whose band the plan settles itself.</summary>
public sealed class PlanFurnitureInput
{
    public IReadOnlyList<PlanEntryInput> Headers { get; init; } = Array.Empty<PlanEntryInput>();
    public IReadOnlyList<PlanEntryInput> Footers { get; init; } = Array.Empty<PlanEntryInput>();
    public IReadOnlyList<PlanEntryInput> Masters { get; init; } = Array.Empty<PlanEntryInput>();
    public IReadOnlyCollection<int> SectionsHidingHeader { get; init; } = Array.Empty<int>();
    public IReadOnlyCollection<int> SectionsHidingFooter { get; init; } = Array.Empty<int>();
    public IReadOnlyCollection<int> SectionsHidingMaster { get; init; } = Array.Empty<int>();
    public IReadOnlyList<PlanNoteInput> Notes { get; init; } = Array.Empty<PlanNoteInput>();
    public IReadOnlyList<PlanSeparatorInput> Separators { get; init; } = Array.Empty<PlanSeparatorInput>();
}

/// <summary>One page of the plan: its section, the entries that apply to it (positions in the lists
/// the host passed, null for none) and the number it prints.</summary>
internal readonly record struct PlannedPage(int Section, long? FirstKey, int Number = 0, bool NumberHidden = false,
    int? Header = null, int? Footer = null, int? Master = null);

/// <summary>One row's extent on one page of a flowed table: page-local points.</summary>
internal readonly record struct PlannedRowSegment(int Block, int Row, int Page, double Top, double Bottom);

/// <summary>One cell line of a flowed table: its page and page-local top, in points.</summary>
internal readonly record struct PlannedCellLine(int Block, int Row, int Cell, int Line, int Page, double Top);

internal readonly record struct PlannedPlacement(int Block, int Page, double Top, double Height, int? RowStart, int? RowCount, bool Flowed = false, int? Column = null);

internal readonly record struct PlannedLine(int Block, int Line, int Page, double Top);

/// <summary>The engine's answer, in this host's terms. Positions are page-local points.</summary>
internal sealed class PagePlanResult
{
    public required int PageCount { get; init; }
    public required IReadOnlyList<PlannedPage> Pages { get; init; }
    public required IReadOnlyList<PlannedPlacement> Placements { get; init; }
    public required IReadOnlyList<PlannedLine> Lines { get; init; }
    public required IReadOnlyList<PlannedRowSegment> RowSegments { get; init; }
    public required IReadOnlyList<PlannedCellLine> CellLines { get; init; }
    public required int SplitTableCount { get; init; }
    public required int CarriedTableCount { get; init; }
    public required int DroppedBreakCount { get; init; }
    /// <summary>The footnote bands the plan settled on and the notes each page cites, both by page.</summary>
    public required IReadOnlyDictionary<int, double> NoteBands { get; init; }
    public required IReadOnlyDictionary<int, List<long>> NotesByPage { get; init; }
    /// <summary>The columns of each declared run, in the order the input named them.</summary>
    public IReadOnlyList<IReadOnlyList<PlannedColumn>> ColumnRuns { get; init; } = Array.Empty<IReadOnlyList<PlannedColumn>>();
    /// <summary>The column of each text line of a columned run, by (block, line).</summary>
    public IReadOnlyDictionary<(int Block, int Line), int> ColumnLines { get; init; } = new Dictionary<(int, int), int>();
    /// <summary>The column of each cell line of a table in a columned run, by (block, row, cell, line).</summary>
    public IReadOnlyDictionary<(int Block, int Row, int Cell, int Line), int> ColumnCellLines { get; init; } = new Dictionary<(int, int, int, int), int>();
    public IReadOnlyList<PlannedColumnRowSegment> ColumnRowSegments { get; init; } = Array.Empty<PlannedColumnRowSegment>();
}

/// <summary>S2 of docs/plans/pagination-to-engine.md: the one call that decides where every whole
/// block of a paged document goes. There is no second configuration — an engine that refuses the
/// input, or is not loaded, is a failure to report, not a reason to paginate here.</summary>
internal static class PagePlanClient
{
    private const int PlanVersion = 1;

    /// <summary>Sees every plan request exactly as it is sent, so a test can read what a real
    /// <see cref="PageLayout.Build"/> hands the engine. Null outside tests.</summary>
    [ThreadStatic] internal static Action<byte[]>? RequestSent;

    public static PagePlanResult Plan(IntPtr handle, double contentHeightPoints, bool splitTables,
        IReadOnlyDictionary<int, double>? noteBands, IReadOnlyList<PlanBlockInput> blocks, double bandPoints = 0,
        PlanFurnitureInput? furniture = null, PlanColumnsInput? columns = null)
    {
        var input = Encode(contentHeightPoints, splitTables, noteBands, blocks, bandPoints, furniture, columns);
        RequestSent?.Invoke(input);
        var reply = FastdocEngine.TakeOwnedString(FastdocEngine.fastdoc_office_page_plan_json(handle, input));
        if (reply is null)
        {
            throw new InvalidOperationException("the engine built no page plan reply: " + FastdocEngine.TakeLastError());
        }
        return Decode(reply);
    }

    internal static byte[] Encode(double contentHeightPoints, bool splitTables,
        IReadOnlyDictionary<int, double>? noteBands, IReadOnlyList<PlanBlockInput> blocks, double bandPoints = 0,
        PlanFurnitureInput? furniture = null, PlanColumnsInput? columns = null)
    {
        var buffer = new ArrayBufferWriter<byte>(Math.Max(4096, blocks.Count * 96));
        using (var w = new Utf8JsonWriter(buffer))
        {
            w.WriteStartObject();
            w.WriteNumber("planVersion", PlanVersion);
            w.WriteNumber("contentHeight", contentHeightPoints);
            w.WriteBoolean("splitTables", splitTables);
            if (bandPoints > 0) { w.WriteNumber("band", bandPoints); }
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
            if (furniture is not null) { WriteFurniture(w, furniture); }
            if (columns is not null) { WriteColumns(w, columns); }
            w.WriteStartArray("blocks");
            foreach (var b in blocks) { WriteBlock(w, b); }
            w.WriteEndArray();
            w.WriteEndObject();
        }
        var bytes = new byte[buffer.WrittenCount + 1]; // NUL-terminated for `const char *`
        buffer.WrittenSpan.CopyTo(bytes);
        return bytes;
    }

    private static void WriteEntries(Utf8JsonWriter w, string name, IReadOnlyList<PlanEntryInput> entries)
    {
        if (entries.Count == 0) { return; }
        w.WriteStartArray(name);
        foreach (var e in entries)
        {
            w.WriteStartObject();
            w.WriteString("appliesTo", e.AppliesTo);
            if (e.Section is { } section) { w.WriteNumber("section", section); }
            w.WriteEndObject();
        }
        w.WriteEndArray();
    }

    private static void WriteSections(Utf8JsonWriter w, string name, IReadOnlyCollection<int> sections)
    {
        if (sections.Count == 0) { return; }
        w.WriteStartArray(name);
        foreach (var s in sections) { w.WriteNumberValue(s); }
        w.WriteEndArray();
    }

    private static void WriteFurniture(Utf8JsonWriter w, PlanFurnitureInput f)
    {
        WriteEntries(w, "headers", f.Headers);
        WriteEntries(w, "footers", f.Footers);
        WriteEntries(w, "masters", f.Masters);
        WriteSections(w, "sectionsHidingHeader", f.SectionsHidingHeader);
        WriteSections(w, "sectionsHidingFooter", f.SectionsHidingFooter);
        WriteSections(w, "sectionsHidingMaster", f.SectionsHidingMaster);
        if (f.Notes.Count > 0)
        {
            w.WriteStartArray("notes");
            foreach (var n in f.Notes)
            {
                w.WriteStartObject();
                w.WriteNumber("number", n.Number);
                w.WriteNumber("height", n.Height);
                w.WriteEndObject();
            }
            w.WriteEndArray();
        }
        if (f.Separators.Count > 0)
        {
            w.WriteStartArray("separators");
            foreach (var s in f.Separators)
            {
                w.WriteStartObject();
                w.WriteNumber("section", s.Section);
                w.WriteNumber("lineType", s.LineType);
                w.WriteNumber("lineWidth", s.LineWidth);
                w.WriteNumber("marginTop", s.MarginTop);
                w.WriteNumber("marginBottom", s.MarginBottom);
                w.WriteNumber("noteSpacing", s.NoteSpacing);
                w.WriteEndObject();
            }
            w.WriteEndArray();
        }
    }

    private static void WriteColumns(Utf8JsonWriter w, PlanColumnsInput columns)
    {
        w.WriteNumber("bodyWidth", columns.BodyWidth);
        w.WriteStartArray("columnRuns");
        foreach (var run in columns.Runs)
        {
            w.WriteStartObject();
            w.WriteNumber("count", run.Count);
            w.WriteNumber("spacing", run.Spacing);
            w.WriteStartArray("widths");
            foreach (var v in run.Widths) { w.WriteNumberValue(v); }
            w.WriteEndArray();
            w.WriteStartArray("gaps");
            foreach (var v in run.Gaps) { w.WriteNumberValue(v); }
            w.WriteEndArray();
            w.WriteBoolean("proportional", run.Proportional);
            w.WriteEndObject();
        }
        w.WriteEndArray();
    }

    private static void WriteBlock(Utf8JsonWriter w, PlanBlockInput b)
    {
        w.WriteStartObject();
        w.WriteNumber("key", b.Key);
        w.WriteString("kind", b.Kind);
        if (b.ColumnRun is { } run) { w.WriteNumber("columnRun", run); }
        if (b.PageNumberRestart is { } restart) { w.WriteNumber("pageNumberRestart", restart); }
        if (b.HidesPageNumber) { w.WriteBoolean("hidesPageNumber", true); }
        if (b.Cites is { Count: > 0 } cites)
        {
            w.WriteStartArray("cites");
            foreach (var cite in cites)
            {
                w.WriteStartObject();
                w.WriteNumber("note", cite.Note);
                if (cite.Line is { } line) { w.WriteNumber("line", line); }
                w.WriteEndObject();
            }
            w.WriteEndArray();
        }
        if (b.Section) { w.WriteBoolean("section", true); }
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
                    if (b.RowCells is { } rowCells && r < rowCells.Length && rowCells[r].Length > 0)
                    {
                        WriteCells(w, rowCells[r]);
                    }
                    w.WriteEndObject();
                }
                w.WriteEndArray();
            }
            if (b.KeepsWhole) { w.WriteBoolean("keepsWhole", true); }
            if (b.RowsObserved) { w.WriteBoolean("rowsObserved", true); }
        }
        w.WriteEndObject();
    }

    private static void WriteCells(Utf8JsonWriter w, PlanCellInput[] cells)
    {
        w.WriteStartArray("cells");
        foreach (var cell in cells)
        {
            w.WriteStartObject();
            if (cell.RowSpan != 1) { w.WriteNumber("rowSpan", cell.RowSpan); }
            if (cell.VerticalAlign is { } align) { w.WriteString("verticalAlign", align); }
            w.WriteNumber("padTop", cell.PadTop);
            w.WriteNumber("padBottom", cell.PadBottom);
            w.WriteNumber("contentHeight", cell.ContentHeight);
            w.WriteStartArray("lines");
            foreach (var line in cell.Lines)
            {
                w.WriteStartObject();
                w.WriteNumber("top", line.Top);
                w.WriteNumber("height", line.Height);
                if (line.Trailing != 0) { w.WriteNumber("trailing", line.Trailing); }
                w.WriteEndObject();
            }
            w.WriteEndArray();
            w.WriteEndObject();
        }
        w.WriteEndArray();
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
            int? Index(string name) => p.TryGetProperty(name, out var v) ? v.GetInt32() : null;
            pages.Add(new PlannedPage(p.GetProperty("section").GetInt32(),
                p.TryGetProperty("firstKey", out var key) ? key.GetInt64() : null,
                p.TryGetProperty("number", out var number) ? (int)number.GetInt64() : 0,
                p.TryGetProperty("numberHidden", out var hidden) && hidden.GetBoolean(),
                Index("header"), Index("footer"), Index("master")));
        }
        var noteBands = new Dictionary<int, double>();
        if (plan.TryGetProperty("noteBands", out var bandArray))
        {
            foreach (var b in bandArray.EnumerateArray()) { noteBands[b[0].GetInt32()] = b[1].GetDouble(); }
        }
        var notesByPage = new Dictionary<int, List<long>>();
        if (plan.TryGetProperty("notesByPage", out var notesArray))
        {
            foreach (var entry in notesArray.EnumerateArray())
            {
                var list = new List<long>();
                foreach (var n in entry[1].EnumerateArray()) { list.Add(n.GetInt64()); }
                notesByPage[entry[0].GetInt32()] = list;
            }
        }
        var placements = new List<PlannedPlacement>();
        foreach (var p in plan.GetProperty("placements").EnumerateArray())
        {
            placements.Add(new PlannedPlacement(p.GetProperty("block").GetInt32(), p.GetProperty("page").GetInt32(),
                p.GetProperty("top").GetDouble(), p.GetProperty("height").GetDouble(),
                p.TryGetProperty("rowStart", out var rs) ? rs.GetInt32() : null,
                p.TryGetProperty("rowCount", out var rc) ? rc.GetInt32() : null,
                p.TryGetProperty("flowed", out var flowed) && flowed.GetBoolean(),
                p.TryGetProperty("column", out var column) ? column.GetInt32() : null));
        }
        var lineArray = plan.GetProperty("lines");
        var lines = new List<PlannedLine>(lineArray.GetArrayLength());
        foreach (var l in lineArray.EnumerateArray())
        {
            lines.Add(new PlannedLine(l[0].GetInt32(), l[1].GetInt32(), l[2].GetInt32(), l[3].GetDouble()));
        }
        var segments = new List<PlannedRowSegment>();
        foreach (var s in plan.GetProperty("rowSegments").EnumerateArray())
        {
            segments.Add(new PlannedRowSegment(s[0].GetInt32(), s[1].GetInt32(), s[2].GetInt32(), s[3].GetDouble(), s[4].GetDouble()));
        }
        var cellLines = new List<PlannedCellLine>();
        foreach (var l in plan.GetProperty("cellLines").EnumerateArray())
        {
            cellLines.Add(new PlannedCellLine(l[0].GetInt32(), l[1].GetInt32(), l[2].GetInt32(), l[3].GetInt32(), l[4].GetInt32(), l[5].GetDouble()));
        }
        var columnRuns = new List<IReadOnlyList<PlannedColumn>>();
        if (plan.TryGetProperty("columnRuns", out var runArray))
        {
            foreach (var run in runArray.EnumerateArray())
            {
                var columns = new List<PlannedColumn>(run.GetArrayLength());
                foreach (var c in run.EnumerateArray()) { columns.Add(new PlannedColumn(c.GetProperty("x").GetDouble(), c.GetProperty("width").GetDouble())); }
                columnRuns.Add(columns);
            }
        }
        var columnLines = new Dictionary<(int, int), int>();
        if (plan.TryGetProperty("columnLines", out var columnLineArray))
        {
            foreach (var l in columnLineArray.EnumerateArray()) { columnLines[(l[0].GetInt32(), l[1].GetInt32())] = l[2].GetInt32(); }
        }
        var columnCellLines = new Dictionary<(int, int, int, int), int>();
        if (plan.TryGetProperty("columnCellLines", out var columnCellArray))
        {
            foreach (var l in columnCellArray.EnumerateArray()) { columnCellLines[(l[0].GetInt32(), l[1].GetInt32(), l[2].GetInt32(), l[3].GetInt32())] = l[4].GetInt32(); }
        }
        var columnSegments = new List<PlannedColumnRowSegment>();
        if (plan.TryGetProperty("columnRowSegments", out var columnSegmentArray))
        {
            foreach (var s in columnSegmentArray.EnumerateArray())
            {
                columnSegments.Add(new PlannedColumnRowSegment(s[0].GetInt32(), s[1].GetInt32(), s[2].GetInt32(), s[3].GetInt32(),
                    s[4].GetDouble(), s[5].GetDouble()));
            }
        }
        return new PagePlanResult
        {
            ColumnRuns = columnRuns,
            ColumnLines = columnLines,
            ColumnCellLines = columnCellLines,
            ColumnRowSegments = columnSegments,
            RowSegments = segments,
            CellLines = cellLines,
            PageCount = plan.GetProperty("pageCount").GetInt32(),
            Pages = pages,
            Placements = placements,
            Lines = lines,
            SplitTableCount = plan.GetProperty("splitTableCount").GetInt32(),
            CarriedTableCount = plan.GetProperty("carriedTableCount").GetInt32(),
            DroppedBreakCount = plan.GetProperty("droppedBreakCount").GetInt32(),
            NoteBands = noteBands,
            NotesByPage = notesByPage,
        };
    }
}
