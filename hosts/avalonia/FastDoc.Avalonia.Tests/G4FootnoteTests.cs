using System.Collections.Generic;
using System.Linq;
using FastDoc.Avalonia.Paging;

namespace FastDoc.Avalonia.Tests;

/// <summary>G4 (parity audit): the footnote band's stopping rule and arithmetic (invariant 98).</summary>
public class G4FootnoteTests
{
    private static Dictionary<int, double> Bands(params (int Page, double Band)[] pairs) =>
        pairs.ToDictionary(p => p.Page, p => p.Band);

    [Fact]
    public void A_proposal_equal_to_the_last_round_stops()
    {
        var history = new List<Dictionary<int, double>> { Bands((0, 50)) };
        var (stop, bands) = FootnoteLayout.ManagedStep(Bands((0, 50)), history, 8);
        Assert.True(stop);
        Assert.Equal(50, bands[0]);
    }

    [Fact]
    public void A_changed_proposal_retries()
    {
        var history = new List<Dictionary<int, double>> { Bands((0, 50)) };
        var (stop, bands) = FootnoteLayout.ManagedStep(Bands((0, 80)), history, 8);
        Assert.False(stop);
        Assert.Equal(80, bands[0]);
    }

    [Fact]
    public void A_cycle_stops_on_the_pointwise_maximum_the_tall_half()
    {
        // A -> B -> A: a 2-cycle. The safe ruling reserves the larger band on every page.
        var a = Bands((0, 40), (1, 90));
        var b = Bands((0, 70), (1, 20));
        var history = new List<Dictionary<int, double>> { a, b };
        var (stop, bands) = FootnoteLayout.ManagedStep(a, history, 8);
        Assert.True(stop);
        Assert.Equal(70, bands[0]);
        Assert.Equal(90, bands[1]);
    }

    [Fact]
    public void The_round_cap_stops()
    {
        var history = Enumerable.Range(1, 7).Select(i => Bands((0, i * 10.0))).ToList();
        var (stop, _) = FootnoteLayout.ManagedStep(Bands((0, 999)), history, 8);
        Assert.True(stop);
    }

    [Fact]
    public void A_band_is_clamped_so_the_body_keeps_a_quarter_of_the_page()
    {
        Assert.Equal(75, FootnoteLayout.Clamp(500, 100));
        Assert.Equal(30, FootnoteLayout.Clamp(30, 100));
        Assert.Equal(0, FootnoteLayout.Clamp(0, 100));
    }

    [Fact]
    public void The_separator_allowance_is_the_rule_and_its_margins_or_the_readers_minimum()
    {
        Assert.Equal(8, FootnoteLayout.SeparatorAllowance(null));
        Assert.Equal(8, FootnoteLayout.SeparatorAllowance(new FootnoteSeparatorSpec(false, 1, 1, null, null, 5, 5, 0)));
        Assert.Equal(5 + 0.5 + 3, FootnoteLayout.SeparatorAllowance(new FootnoteSeparatorSpec(true, 1, 0.2, null, null, 5, 3, 0)));
        // A declared line type of 0 is "no rule": only the margins.
        Assert.Equal(5 + 3, FootnoteLayout.SeparatorAllowance(new FootnoteSeparatorSpec(true, 0, 1, null, null, 5, 3, 0)));
    }
}
