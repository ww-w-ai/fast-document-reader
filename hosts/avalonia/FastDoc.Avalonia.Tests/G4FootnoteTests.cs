using System.Collections.Generic;
using System.Linq;
using FastDoc.Avalonia.Paging;

namespace FastDoc.Avalonia.Tests;

/// <summary>G4 (parity audit): the footnote band's arithmetic (invariant 98). The stopping rule, the
/// clamp and the proposal are the engine's and run inside the page-plan call; their tests are
/// `plan_footnotes.rs` and `page_plan.rs`. What this host still owns is the figure the painter draws
/// the separator with, and the wire it hands the notes over on.</summary>
public class G4FootnoteTests
{
    [Fact]
    public void The_separator_allowance_is_the_rule_and_its_margins_or_the_readers_minimum()
    {
        Assert.Equal(8, FootnoteLayout.SeparatorAllowance(null));
        Assert.Equal(8, FootnoteLayout.SeparatorAllowance(new FootnoteSeparatorSpec(false, 1, 1, null, null, 5, 5, 0)));
        Assert.Equal(5 + 0.5 + 3, FootnoteLayout.SeparatorAllowance(new FootnoteSeparatorSpec(true, 1, 0.2, null, null, 5, 3, 0)));
        // A declared line type of 0 is "no rule": only the margins.
        Assert.Equal(5 + 3, FootnoteLayout.SeparatorAllowance(new FootnoteSeparatorSpec(true, 0, 1, null, null, 5, 3, 0)));
    }

    [Fact]
    public void The_notes_and_what_each_block_cites_cross_to_the_engine_and_its_bands_come_back()
    {
        // 100pt body, four 30pt lines, the first citing a 40pt note: page 0 reserves 8 + 40 and keeps
        // room for one line. Exercises the real engine through the plan client.
        var block = new PlanBlockInput
        {
            Key = 1, Kind = "text", Lines = new[] { 30.0, 30.0, 30.0, 30.0 },
            Cites = new List<PlanCiteInput> { new(1, 0) },
        };
        var furniture = new PlanFurnitureInput { Notes = new[] { new PlanNoteInput(1, 40) } };
        var plan = PagePlanClient.Plan(System.IntPtr.Zero, 100, splitTables: true, null, new List<PlanBlockInput> { block },
            furniture: furniture);
        Assert.Equal(48, plan.NoteBands[0]);
        Assert.Equal(new List<long> { 1 }, plan.NotesByPage[0]);
        Assert.Equal(new[] { 0, 1, 1, 1 }, plan.Lines.Select(l => l.Page).ToArray());
    }

    [Fact]
    public void A_page_names_the_head_foot_and_master_that_apply_and_the_number_it_prints()
    {
        var blocks = new List<PlanBlockInput>
        {
            new() { Key = 1, Kind = "text", Lines = new[] { 60.0 } },
            new() { Key = 2, Kind = "text", Lines = new[] { 60.0 }, PageNumberRestart = 1 },
            new() { Key = 3, Kind = "text", Lines = new[] { 60.0 }, HidesPageNumber = true },
        };
        var furniture = new PlanFurnitureInput
        {
            Headers = new[] { new PlanEntryInput("defaultPages", null), new PlanEntryInput("firstPage", null) },
            Footers = new[] { new PlanEntryInput("defaultPages", null) },
            SectionsHidingFooter = new[] { 7 },
            Masters = new[] { new PlanEntryInput("defaultPages", 0) },
        };
        var plan = PagePlanClient.Plan(System.IntPtr.Zero, 100, splitTables: true, null, blocks, furniture: furniture);
        Assert.Equal(3, plan.PageCount);
        Assert.Equal(new int?[] { 1, 0, 0 }, plan.Pages.Select(p => p.Header).ToArray());
        Assert.Equal(new int?[] { 0, 0, 0 }, plan.Pages.Select(p => p.Footer).ToArray());
        Assert.Equal(new int[] { 1, 1, 2 }, plan.Pages.Select(p => p.Number).ToArray());
        Assert.Equal(new[] { false, false, true }, plan.Pages.Select(p => p.NumberHidden).ToArray());
    }
}
