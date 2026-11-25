using System.Collections.Generic;
using Avalonia.Media;
using FastDoc.Avalonia.Rendering;
using Xunit;

namespace FastDoc.Avalonia.Tests;

/// <summary>A list marker is measured at its item's size, as AppKit draws it on the other host
/// (INVARIANTS 207): a "•" at the document's 10pt default stood every line of an 8pt item at 10pt.</summary>
public sealed class ListMarkerSizeTests
{
    [Fact]
    public void A_list_marker_takes_its_items_size()
    {
        var marker = new FlowRun("• ", null, 10, false, false, false, false, Colors.Black);
        var runs = new List<FlowRun> { marker, new FlowRun("항목", "Helvetica", 8, false, false, false, false, Colors.Black) };
        Assert.Equal(8, FlowDocumentBuilder.MarkerAtItemSize(runs, marker)[0].FontSizePoints);
    }

    [Fact]
    public void An_item_with_no_text_keeps_its_marker_as_it_was()
    {
        var marker = new FlowRun("• ", null, 10, false, false, false, false, Colors.Black);
        Assert.Equal(10, FlowDocumentBuilder.MarkerAtItemSize(new List<FlowRun> { marker }, marker)[0].FontSizePoints);
    }
}
