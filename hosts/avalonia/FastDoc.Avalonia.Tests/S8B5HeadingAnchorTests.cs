using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Themes.Fluent;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S8-B5: fixes the VM finding that clicking a markdown TOC link (`[Contents](#chapter-1-loomings)`)
/// did nothing because the markdown producer emits no bookmarks and `NavigateLink` fell through to
/// launching the bare fragment as a URL. Covers the new <see cref="HeadingAnchorResolver"/> (a port
/// of `AnchorResolver.swift`'s slug half) directly, and the end-to-end click path through
/// <see cref="FlowDocumentView"/>.
/// </summary>
public class S8B5HeadingAnchorTests
{
    public S8B5HeadingAnchorTests() => AvaloniaHeadlessSetup.EnsureReady();

    // ---- HeadingAnchorResolver / Slugify (pure) --------------------------------------------------

    [Theory]
    [InlineData("CHAPTER 1. Loomings.", "chapter-1-loomings")]
    [InlineData("Hello, World!", "hello-world")]
    [InlineData("  Leading and trailing spaces  ", "--leading-and-trailing-spaces--")]
    public void Slugify_matches_AnchorResolver_swifts_rule(string heading, string expectedSlug)
    {
        Assert.Equal(expectedSlug, HeadingAnchorResolver.Slugify(heading));
    }

    [Fact]
    public void Slugify_keeps_Korean_letters_untouched_and_only_converts_the_space()
    {
        Assert.Equal("소개-인사", HeadingAnchorResolver.Slugify("소개 인사"));
    }

    [Fact]
    public void Resolve_finds_a_headings_node_id_by_its_slug()
    {
        var resolver = HeadingAnchorResolver.Build(new (string, ulong)[]
        {
            ("Getting Started", 10UL),
            ("CHAPTER 1. Loomings.", 20UL),
        });

        Assert.Equal(20UL, resolver.Resolve("chapter-1-loomings"));
        Assert.Equal(20UL, resolver.Resolve("#chapter-1-loomings")); // leading '#' is a no-op under Slugify
        Assert.Equal(10UL, resolver.Resolve("getting-started"));
    }

    [Fact]
    public void Resolve_returns_null_for_a_fragment_no_heading_matches()
    {
        var resolver = HeadingAnchorResolver.Build(new (string, ulong)[] { ("Intro", 1UL) });
        Assert.Null(resolver.Resolve("does-not-exist"));
    }

    [Fact]
    public void A_duplicate_heading_slug_resolves_to_the_FIRST_occurrence_in_document_order()
    {
        // AnchorResolver.swift's own `resolve` has no `-1`/`-2` duplicate-suffix scheme — it is
        // `headings.first { slugify($0.text) == want }`. This proves the C# port matches that
        // EXACT (lack of) behaviour rather than inventing GFM's fuller disambiguation rule.
        var resolver = HeadingAnchorResolver.Build(new (string, ulong)[]
        {
            ("Notes", 1UL),
            ("Notes", 2UL),
        });

        Assert.Equal(1UL, resolver.Resolve("notes"));
    }

    // ---- end-to-end click path through FlowDocumentView -------------------------------------------

    // node ids: 0 document, 1 heading("CHAPTER 1. Loomings."), 2 paragraph(TOC link to it),
    // 3 paragraph(dead-fragment link), 4 paragraph(filler, keeps content taller than the viewport).
    private const string TocLinkTreeJson = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": { "format": "markdown", "rootNodeId": 0, "defaultBodyFontSize": 12 },
        "nodes": [
          { "id": 0, "parentId": null, "children": [2, 3, 1, 4], "type": "document", "data": {} },
          { "id": 2, "parentId": 0, "children": [20], "type": "paragraph", "data": { "style": {} } },
          { "id": 20, "parentId": 2, "children": [], "type": "textRun", "data": { "text": "Contents link text", "style": {}, "link": "#chapter-1-loomings" } },
          { "id": 3, "parentId": 0, "children": [30], "type": "paragraph", "data": { "style": {} } },
          { "id": 30, "parentId": 3, "children": [], "type": "textRun", "data": { "text": "dead link text", "style": {}, "link": "#does-not-exist" } },
          { "id": 1, "parentId": 0, "children": [10], "type": "heading", "data": { "level": 1, "style": {} } },
          { "id": 10, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "CHAPTER 1. Loomings.", "style": {} } },
          { "id": 4, "parentId": 0, "children": [40], "type": "paragraph", "data": { "style": {} } },
          { "id": 40, "parentId": 4, "children": [], "type": "textRun", "data": { "text": "filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler", "style": {} } }
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

    private sealed class FakeExternalLinkLauncher : IExternalLinkLauncher
    {
        public string? LastOpened { get; private set; }
        public void Open(string url) => LastOpened = url;
    }

    private static FlowDocumentView CreateAttachedView(out Window window, out FakeExternalLinkLauncher launcher)
    {
        EnsureFluentThemeLoaded();
        var view = new FlowDocumentView();
        launcher = new FakeExternalLinkLauncher();
        view.ExternalLinkLauncher = launcher;
        window = new Window { Width = 500, Height = 400, Content = view };
        window.Show();
        view.SetTree(LoadTree(TocLinkTreeJson));
        view.Measure(new Size(500, 400));
        view.Arrange(new Rect(0, 0, 500, 400));
        return view;
    }

    [Fact]
    public void A_markdown_TOC_link_scrolls_to_the_heading_its_slug_names_instead_of_launching_a_url()
    {
        // Node order in the document: paragraph2(link) -> block0, paragraph3(dead link) -> block1,
        // heading1 -> block2, paragraph4(filler) -> block3. Reference view scrolls to the heading
        // directly (node 1) to get the expected landing offset — same pattern S8-B4 used for its
        // own internal-anchor test.
        var reference = CreateAttachedView(out _, out _);
        reference.ScrollToNodeId(1);
        var expectedOffset = reference.ScrollOffset;

        var view = CreateAttachedView(out var window, out var launcher);
        // Block 0 (paragraph2, the TOC link) is already at the viewport top after SetTree.
        window.MouseDown(new Point(30, 10), MouseButton.Left);
        window.MouseUp(new Point(30, 10), MouseButton.Left);

        Assert.Null(launcher.LastOpened);
        Assert.Equal(expectedOffset, view.ScrollOffset, 1);
    }

    [Fact]
    public void A_click_on_an_unresolvable_fragment_link_does_nothing_and_never_launches_a_url()
    {
        var view = CreateAttachedView(out var window, out var launcher);
        view.ScrollToNodeId(3); // the dead-fragment-link paragraph's top is now at the viewport top
        var scrollBeforeClick = view.ScrollOffset;

        window.MouseDown(new Point(30, 10), MouseButton.Left);
        window.MouseUp(new Point(30, 10), MouseButton.Left);

        Assert.Null(launcher.LastOpened);
        Assert.Equal(scrollBeforeClick, view.ScrollOffset, 1);
    }

    [Fact]
    public void A_link_runs_FlowRun_carries_the_underline_flag_and_the_link_colour()
    {
        var tree = LoadTree(TocLinkTreeJson);
        var blocks = FlowDocumentBuilder.Build(tree);

        var linkBlock = blocks.Find(b => b.NodeId == 2UL)!;
        var linkRun = linkBlock.Runs[0];

        Assert.True(linkRun.Underline);
        // No themed Application resources are merged in this headless test host (only FluentTheme
        // itself, which declares no "LinkColor" key) — this is the SAME disclosed fallback-only
        // limitation D2-b's colour-contrast test already carries for FindMatchHighlightColor, so
        // this asserts against ResolveLinkColor's own fallback literal (the exact macOS light
        // value, RenderTheme.swift's Palette.link), not a live App.axaml resource lookup.
        Assert.Equal(Color.FromRgb(0x2E, 0x7A, 0xB8), linkRun.Foreground);

        var headingBlock = blocks.Find(b => b.NodeId == 1UL)!;
        Assert.False(headingBlock.Runs[0].Underline); // a plain heading run carries no link styling
    }
}
