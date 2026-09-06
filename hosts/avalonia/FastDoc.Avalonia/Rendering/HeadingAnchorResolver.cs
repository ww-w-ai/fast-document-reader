using System.Collections.Generic;
using System.Linq;

namespace FastDoc.Avalonia.Rendering;

/// <summary>
/// S8-B5: resolves a markdown TOC link's fragment (`#chapter-1-loomings`) to the heading NODE it
/// names — the GFM heading-slug half of the SAME two-step resolution
/// `Sources/FastDocReader/Navigation/AnchorResolver.swift` already does on macOS (bookmark exact
/// match first, this second). Pure — no `RenderTree`/view coupling — takes the ordered
/// (heading text, source NodeId) list a caller already has (see
/// <see cref="FlowDocumentView.SetTree"/> for how this host gathers it).
///
/// <see cref="Slugify"/> is a byte-for-byte port of `AnchorResolver.swift`'s own `slugify` — MUST
/// stay identical, since the two sides are resolving the SAME markdown convention (a document
/// opened once in the macOS build and once here must jump to the same heading). It has NO
/// duplicate-heading disambiguation (no `-1`/`-2` suffix): confirmed by reading the Swift source
/// itself, which does `headings.first { slugify($0.text) == want }` — the first heading in
/// document order wins a slug collision, nothing more. (An earlier dispatch for this unit
/// described a `-1`/`-2` suffix scheme; the actual Swift file has none, and per this unit's own
/// instruction to "mirror AnchorResolver.swift's slug algorithm... exactly", the file is the
/// authority here, not that description — see the S8-B5 report.)
/// </summary>
public sealed class HeadingAnchorResolver
{
    private readonly List<(string Slug, ulong NodeId)> _headings;

    private HeadingAnchorResolver(List<(string Slug, ulong NodeId)> headings) => _headings = headings;

    /// <summary>Builds the slug map once — <paramref name="headingsInDocumentOrder"/> must already
    /// be in document order (first-occurrence-wins on a slug collision, matching the Swift side's
    /// own `.first`).</summary>
    public static HeadingAnchorResolver Build(IEnumerable<(string Text, ulong NodeId)> headingsInDocumentOrder) =>
        new(headingsInDocumentOrder.Select(h => (Slugify(h.Text), h.NodeId)).ToList());

    public static readonly HeadingAnchorResolver Empty = new(new List<(string, ulong)>());

    /// <summary>The heading NodeId whose slug matches <paramref name="fragment"/> (with or without
    /// a leading '#' — slugifying it either way is a no-op on '#', since '#' is neither a letter,
    /// digit, '-', '_', space, nor tab, so <see cref="Slugify"/> simply drops it). Null when no
    /// heading matches — the caller does nothing, exactly like a dead cross-reference on macOS
    /// (<see cref="AnchorResolver"/>'s own posture, quoted in this class's own doc).</summary>
    public ulong? Resolve(string fragment)
    {
        var want = Slugify(fragment);
        foreach (var (slug, nodeId) in _headings)
        {
            if (slug == want) { return nodeId; }
        }
        return null;
    }

    /// <summary>GitHub's own slug rule, exactly as `AnchorResolver.swift.slugify` implements it:
    /// lowercase; space/tab become a hyphen; a letter, digit, '-', or '_' passes through; anything
    /// else (punctuation) is dropped. Unicode letters (Hangul included) pass `char.IsLetter` just
    /// as Swift's `Character.isLetter` does, so a Korean heading slugifies the same way on both
    /// sides.</summary>
    public static string Slugify(string s)
    {
        var lowered = s.ToLowerInvariant();
        var sb = new System.Text.StringBuilder(lowered.Length);
        foreach (var ch in lowered)
        {
            if (ch == ' ' || ch == '\t') { sb.Append('-'); }
            else if (ch == '-' || ch == '_' || char.IsLetter(ch) || char.IsDigit(ch)) { sb.Append(ch); }
        }
        return sb.ToString();
    }
}
