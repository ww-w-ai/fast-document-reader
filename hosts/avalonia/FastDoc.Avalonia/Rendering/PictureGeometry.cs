using System;

namespace FastDoc.Avalonia.Rendering;

/// <summary>S8-A2 (C2): the ONE function that decides a picture's reserved/drawn size, in POINTS —
/// CLAUDE.md invariant 46, "a graphic is scaled by the reading column over the DOCUMENT's own page
/// width... and is re-solved on every reflow", never from decoded pixel dimensions (which would
/// let a bitmap's own aspect drift from what the document declared, and would compound rounding
/// across repeated reflows the way invariant 46's own doc warns against).
///
/// Both a layout pass that only needs a HEIGHT to reserve space (<see
/// cref="Paging.PageLayout.NonTextBlockHeightPoints"/>, <see cref="FlowDocumentView"/>'s own
/// EstimateHeight) and the pass that actually PAINTS the picture (<see
/// cref="ImageBlockRenderer.Draw"/>) call this same method with the same column width — so the
/// space a picture reserves and the box it is drawn into can never disagree. Before this existed,
/// EstimateHeight/NonTextBlockHeightPoints used the block's raw declared height with no clamp at
/// all while ImageBlockRenderer.Draw independently clamped to the column (and, worse, sometimes
/// substituted the DECODED bitmap's own aspect ratio) — an anchored picture wider than its column
/// was drawn shorter than the space reserved for it, so the next block's text overlapped its
/// bottom edge (S8-A1 catalog finding F3/C2).</summary>
public static class PictureGeometry
{
    private const double DefaultWidthPoints = 200;
    private const double DefaultHeightPoints = 120;

    /// <summary>The picture's declared (authored) width/height, clamped to
    /// <paramref name="columnWidthPoints"/> — shrunk (never enlarged) preserving aspect ratio, the
    /// same rule <c>OfficeTextBuilder.graphicSize</c> applies on macOS. A block with no declared
    /// size at all falls back to a fixed placeholder box, matching this reader's pre-E2b default.</summary>
    public static (double WidthPoints, double HeightPoints) Measure(FlowBlock block, double columnWidthPoints)
    {
        var declaredWidth = block.ImageWidthPoints is > 0 ? block.ImageWidthPoints.Value : DefaultWidthPoints;
        var declaredHeight = block.ImageHeightPoints is > 0 ? block.ImageHeightPoints.Value : DefaultHeightPoints;
        return Measure(declaredWidth, declaredHeight, columnWidthPoints);
    }

    /// <summary>Same clamp, for a caller that already has the declared size as plain numbers
    /// (e.g. an "unsupported" placeholder's own <c>IntrinsicSize</c>, which is not a FlowBlock's
    /// Image/Vector payload — see FlowDocumentBuilder's "unsupported" case).</summary>
    public static (double WidthPoints, double HeightPoints) Measure(double declaredWidthPoints, double declaredHeightPoints, double columnWidthPoints)
    {
        var width = declaredWidthPoints > 0 ? declaredWidthPoints : DefaultWidthPoints;
        var height = declaredHeightPoints > 0 ? declaredHeightPoints : DefaultHeightPoints;
        var maxWidth = Math.Max(1, columnWidthPoints);
        if (width > maxWidth)
        {
            var scale = maxWidth / width;
            width *= scale;
            height *= scale;
        }
        return (Math.Max(1, width), Math.Max(1, height));
    }
}
