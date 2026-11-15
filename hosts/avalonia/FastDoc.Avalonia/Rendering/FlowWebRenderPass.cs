using System;
using System.Collections.Generic;
using System.Threading;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.WebRender;

namespace FastDoc.Avalonia.Rendering;

/// <summary>
/// S12-F: the ONE place that turns a mermaid codeBlock or a formula node into a real on-screen
/// picture when the opt-in switch is on. Runs AFTER <see cref="FlowDocumentBuilder.Build"/> has
/// already produced every block as raw text (the switch-off default, and also this pass's own
/// fallback on any failure) — this pass only ever UPGRADES a block from raw text to Image, never
/// the reverse, and never removes a block FlowDocumentBuilder already produced.
///
/// Calls <see cref="WebRenderCoordinator.RenderAsync"/> SYNCHRONOUSLY per candidate block — see
/// <see cref="WebRenderCoordinatorFactory.DefaultPerCandidateTimeout"/>'s own doc comment for why
/// that is an accepted, documented shortcut for this sprint rather than the final shape.
///
/// Only a <see cref="WebImageFormat.Png"/> result is drawable today — Linux's WebKitGTK path
/// (<see cref="Renderers.WebKitGtkBlockRenderer"/>) hands back a PDF (see that class's own doc
/// comment for why), and this reader has no PDF-page rasterizer wired to a picture block yet.
/// A PDF result therefore leaves the block as raw text, same as every other kind of failure —
/// this is a known, flagged gap, not a silent one.
/// </summary>
public static class FlowWebRenderPass
{
    public static void Apply(List<FlowBlock> blocks, RenderTree tree, ImageBlockRenderer imageRenderer,
        WebRenderCoordinator coordinator)
    {
        var requestsByNodeId = CollectCandidates(tree);
        if (requestsByNodeId.Count == 0) { return; }

        for (var i = 0; i < blocks.Count; i++)
        {
            var block = blocks[i];
            if (block.NodeId is not { } nodeId || !requestsByNodeId.TryGetValue(nodeId, out var request))
            {
                continue;
            }

            var upgraded = TryUpgradeToImage(block, nodeId, request, imageRenderer, coordinator);
            if (upgraded is not null)
            {
                blocks[i] = upgraded;
            }
        }
    }

    /// <summary>Every "formula" node (KaTeX) and every "diagram" node whose language is "mermaid" —
    /// the two shapes <see cref="FlowDocumentBuilder"/>'s own "formula" and "diagram" cases already
    /// recognize and render as raw text. A markdown ```mermaid fence is a "diagram" node on the
    /// wire, NOT a "codeBlock" (see <c>DiagramPayload</c>'s own doc comment in
    /// RenderTreeEnvelope.cs) — checking `AsCodeBlock` here, as an earlier version of this method
    /// did, meant mermaid candidates were never actually found; this was root-caused visually on a
    /// real Linux VM on 2026-09-07.</summary>
    private static Dictionary<ulong, WebBlockRequest> CollectCandidates(RenderTree tree)
    {
        var result = new Dictionary<ulong, WebBlockRequest>();
        foreach (var node in tree.Nodes)
        {
            if (node.AsFormula is { } formula && formula.Source.Length > 0)
            {
                result[node.Id] = new WebBlockRequest(WebBlockEngine.Math, formula.Source);
                continue;
            }
            if (node.AsDiagram is { } diagram
                && string.Equals(diagram.Language, "mermaid", StringComparison.OrdinalIgnoreCase)
                && diagram.Source.Length > 0)
            {
                result[node.Id] = new WebBlockRequest(WebBlockEngine.Mermaid, diagram.Source);
            }
        }
        return result;
    }

    /// <summary>Returns the replacement block on success, or null to leave <paramref name="block"/>
    /// exactly as <see cref="FlowDocumentBuilder"/> already produced it (raw text) — a coordinator
    /// exception, a timeout, a non-PNG result, or a PNG that fails to decode are all the SAME
    /// outcome from this pass's point of view: stay raw. Never throws — a defensive catch-all
    /// guards document loading from any unexpected renderer failure.</summary>
    private static FlowBlock? TryUpgradeToImage(FlowBlock block, ulong nodeId, WebBlockRequest request,
        ImageBlockRenderer imageRenderer, WebRenderCoordinator coordinator)
    {
        try
        {
            using var cts = new CancellationTokenSource(WebRenderCoordinatorFactory.DefaultPerCandidateTimeout
                + TimeSpan.FromSeconds(1)); // a hair past the coordinator's own per-candidate budget,
                                             // so ITS timeout fires first and this is only a backstop.
            var result = coordinator.RenderAsync(request, cts.Token).GetAwaiter().GetResult();
            if (result is not WebRenderResult.Rendered { Image.Format: WebImageFormat.Png } rendered)
            {
                return null;
            }

            var resourceId = ImageBlockRenderer.SyntheticResourceId(nodeId);
            if (!imageRenderer.TryInjectPng(resourceId, rendered.Image.Bytes))
            {
                return null;
            }

            return new FlowBlock
            {
                Kind = FlowBlockKind.Image,
                NodeId = block.NodeId,
                Alignment = block.Alignment,
                IndentPoints = block.IndentPoints,
                SpacingBeforePoints = block.SpacingBeforePoints,
                SpacingAfterPoints = block.SpacingAfterPoints,
                ImageResourceId = resourceId,
            };
        }
        catch
        {
            return null;
        }
    }
}
