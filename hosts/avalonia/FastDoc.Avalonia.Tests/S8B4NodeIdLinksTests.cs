using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Xml;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Input;
using Avalonia.Themes.Fluent;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Panels;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Tests;

/// <summary>
/// S8-B4: NodeId scroll (table of contents + comments), panel/find-bar theme resources, D2-c link
/// hit-testing/navigation, and the right-click context-menu MODEL. One shared fixture tree
/// (<see cref="LinkTreeJson"/>) covers every scenario: a heading (for TOC), a paragraph whose
/// SOLE run carries an external link AND a comment anchor (for D2-c + comment-NodeId), a second
/// paragraph whose sole run carries an internal "#anchor-target" link, and a fourth paragraph that
/// IS the bookmark's target — so a click anywhere in the external/internal-link paragraphs always
/// lands inside their one run (no font-metrics-dependent aiming at a run BOUNDARY, unlike a
/// multi-run block would need).
/// </summary>
public class S8B4NodeIdLinksTests
{
    public S8B4NodeIdLinksTests() => AvaloniaHeadlessSetup.EnsureReady();

    // node ids: 0 document, 1 heading("Section One"), 2 paragraph(external link + comment),
    // 3 paragraph(internal link "#anchor-target"), 4 paragraph(the bookmark's own target).
    // Flow-block indices, in the same order: heading=0, paragraph2=1, paragraph3=2, paragraph4=3.
    private const string LinkTreeJson = """
    {
      "ok": {
        "schemaVersion": 1,
        "document": { "format": "markdown", "rootNodeId": 0, "defaultBodyFontSize": 12 },
        "nodes": [
          { "id": 0, "parentId": null, "children": [1, 2, 3, 4, 5], "type": "document", "data": {} },
          { "id": 1, "parentId": 0, "children": [10], "type": "heading", "data": { "level": 1, "style": {} } },
          { "id": 10, "parentId": 1, "children": [], "type": "textRun", "data": { "text": "Section One", "style": {} } },
          { "id": 2, "parentId": 0, "children": [20], "type": "paragraph", "data": { "style": {} } },
          { "id": 20, "parentId": 2, "children": [], "type": "textRun", "data": { "text": "external link text here", "style": {}, "link": "https://example.com/page", "commentIds": [42] } },
          { "id": 3, "parentId": 0, "children": [30], "type": "paragraph", "data": { "style": {} } },
          { "id": 30, "parentId": 3, "children": [], "type": "textRun", "data": { "text": "internal anchor link text", "style": {}, "link": "#anchor-target" } },
          { "id": 4, "parentId": 0, "children": [40], "type": "paragraph", "data": { "style": {} } },
          { "id": 40, "parentId": 4, "children": [], "type": "textRun", "data": { "text": "the bookmark target paragraph", "style": {} } },
          { "id": 5, "parentId": 0, "children": [50], "type": "paragraph", "data": { "style": {} } },
          { "id": 50, "parentId": 5, "children": [], "type": "textRun", "data": { "text": "filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler filler", "style": {} } }
        ],
        "annotations": {
          "comments": [
            { "id": 42, "sourceId": "c1", "author": "Bob", "text": "a note", "dateIso": null, "number": 1 }
          ],
          "bookmarks": [
            { "id": 1, "name": "anchor-target", "targetNodeId": 4 }
          ]
        }
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
        view.SetTree(LoadTree(LinkTreeJson));
        view.Measure(new Size(500, 400));
        view.Arrange(new Rect(0, 0, 500, 400));
        return view;
    }

    // ---- ① NodeId: FlowBlock carries it, TOC/comments resolve through it ------------------------

    [Fact]
    public void FlowDocumentBuilder_stamps_every_block_with_its_own_source_node_id()
    {
        var tree = LoadTree(LinkTreeJson);
        var blocks = FlowDocumentBuilder.Build(tree);

        Assert.Equal(5, blocks.Count);
        Assert.Equal(1UL, blocks[0].NodeId); // heading
        Assert.Equal(2UL, blocks[1].NodeId); // paragraph (external link)
        Assert.Equal(3UL, blocks[2].NodeId); // paragraph (internal link)
        Assert.Equal(4UL, blocks[3].NodeId); // paragraph (bookmark target)
        Assert.Equal(5UL, blocks[4].NodeId); // filler paragraph (pads content past the viewport height)
    }

    [Fact]
    public void A_TOC_entry_carries_its_headings_own_node_id_and_ScrollToNodeId_resolves_it_to_the_right_block()
    {
        var tree = LoadTree(LinkTreeJson);
        var entries = TableOfContentsModel.Build(tree);
        Assert.Single(entries);
        Assert.Equal(1UL, entries[0].NodeId);

        var view = CreateAttachedView(out _, out _);
        var resolved = view.ScrollToNodeId(entries[0].NodeId);

        Assert.True(resolved);
        Assert.Equal(0, view.GetCurrentPositionForSave().BlockIndex);
    }

    [Fact]
    public void ScrollToNodeId_resolves_a_later_node_to_a_strictly_greater_scroll_offset_than_an_earlier_one()
    {
        // GetCurrentPositionForSave's own block-index readback has an off-by-one AT AN EXACT
        // block-boundary offset (its LowerBound is a "strictly before" search, and RestorePosition
        // lands EXACTLY on a boundary for fraction 0) — that readback contract predates S8-B4 and
        // is out of this unit's scope to touch, so this asserts what ScrollToNodeId itself actually
        // promises (the RAW ScrollOffset a later node resolves to a later position) rather than
        // round-tripping through that reader.
        var view = CreateAttachedView(out _, out _);

        Assert.True(view.ScrollToNodeId(2));
        var earlierOffset = view.ScrollOffset;

        Assert.True(view.ScrollToNodeId(4)); // the bookmark-target paragraph, three blocks later
        var laterOffset = view.ScrollOffset;

        Assert.True(laterOffset > earlierOffset);
    }

    [Fact]
    public void ScrollToNodeId_returns_false_for_a_node_id_the_current_tree_does_not_have()
    {
        var view = CreateAttachedView(out _, out _);
        Assert.False(view.ScrollToNodeId(9999));
    }

    [Fact]
    public void A_comment_anchored_to_a_run_resolves_to_that_runs_enclosing_paragraph_node_id()
    {
        var tree = LoadTree(LinkTreeJson);
        var comments = CommentsModel.Build(tree);

        Assert.Single(comments);
        Assert.Equal(2UL, comments[0].NodeId); // the paragraph enclosing the run that named commentIds:[42]
    }

    [Fact]
    public void An_unanchored_comment_resolves_to_a_null_node_id_rather_than_guessing()
    {
        var tree = LoadTree("""
        {
          "ok": {
            "schemaVersion": 1,
            "document": { "format": "docx", "rootNodeId": 0 },
            "nodes": [ { "id": 0, "parentId": null, "children": [], "type": "document", "data": {} } ],
            "annotations": {
              "comments": [ { "id": 7, "sourceId": "c1", "author": "Bob", "text": "orphan", "dateIso": null, "number": 1 } ]
            }
          }
        }
        """);

        var comments = CommentsModel.Build(tree);
        Assert.Single(comments);
        Assert.Null(comments[0].NodeId);
    }

    // ---- ② theme: the new panel/find-bar resources exist for BOTH variants ----------------------

    [Fact]
    public void App_axaml_declares_the_panel_and_findbar_colours_for_both_Light_and_Dark()
    {
        // S8-B4 report note: the headless test bootstrap does not load the real App class (no
        // Application.Current with these resources merged in), so this asserts against the AXAML
        // SOURCE FILE directly (parsed as XML) rather than a live Application.TryGetResource
        // lookup — the same limitation D2-b's colour-contrast test already disclosed for
        // FindMatchHighlightColor/FindCurrentMatchHighlightColor.
        var appAxamlPath = Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..",
            "FastDoc.Avalonia", "App.axaml");
        appAxamlPath = Path.GetFullPath(appAxamlPath);
        Assert.True(File.Exists(appAxamlPath), $"expected App.axaml at {appAxamlPath}");

        var doc = new XmlDocument();
        doc.Load(appAxamlPath);
        var ns = new XmlNamespaceManager(doc.NameTable);
        ns.AddNamespace("a", "https://github.com/avaloniaui");
        ns.AddNamespace("x", "http://schemas.microsoft.com/winfx/2006/xaml");

        string[] requiredKeys =
        {
            "PanelBackgroundColor", "PanelBorderColor",
            "FindBarBackgroundColor", "FindBarBorderColor", "EmptyStateForegroundColor",
        };

        foreach (var variantKey in new[] { "Light", "Dark" })
        {
            var dict = doc.SelectSingleNode(
                $"//a:ResourceDictionary.ThemeDictionaries/a:ResourceDictionary[@x:Key='{variantKey}']", ns);
            Assert.True(dict is not null, $"no ThemeDictionaries entry for '{variantKey}'");

            foreach (var key in requiredKeys)
            {
                var node = dict!.SelectSingleNode($".//*[@x:Key='{key}']", ns);
                Assert.True(node is not null, $"'{key}' missing from the '{variantKey}' dictionary");
            }
        }
    }

    // ---- ③ D2-c: link threading, click-vs-drag, internal/external navigation, hover cursor ------

    [Fact]
    public void A_textRuns_link_is_carried_onto_its_FlowRun()
    {
        var tree = LoadTree(LinkTreeJson);
        var blocks = FlowDocumentBuilder.Build(tree);

        Assert.Equal("https://example.com/page", blocks[1].Runs[0].LinkTarget);
        Assert.Equal("#anchor-target", blocks[2].Runs[0].LinkTarget);
        Assert.Null(blocks[0].Runs[0].LinkTarget); // the heading run carries no link
    }

    [Fact]
    public void A_click_with_no_movement_on_an_external_link_opens_it_via_the_injected_launcher()
    {
        var view = CreateAttachedView(out var window, out var launcher);
        view.ScrollToNodeId(2); // the external-link paragraph's top is now at the viewport top

        window.MouseDown(new Point(30, 10), MouseButton.Left);
        window.MouseUp(new Point(30, 10), MouseButton.Left);

        Assert.Equal("https://example.com/page", launcher.LastOpened);
    }

    [Fact]
    public void A_drag_that_starts_on_a_link_selects_instead_of_navigating()
    {
        var view = CreateAttachedView(out var window, out var launcher);
        view.ScrollToNodeId(2);

        window.MouseDown(new Point(30, 10), MouseButton.Left);
        window.MouseMove(new Point(200, 10));
        window.MouseUp(new Point(200, 10), MouseButton.Left);

        Assert.Null(launcher.LastOpened);
        Assert.False(view.Selection.IsEmpty);
    }

    [Fact]
    public void A_click_on_an_internal_anchor_link_scrolls_to_the_bookmarks_target_node_instead_of_launching_anything()
    {
        // Expected landing offset from a reference view's own direct ScrollToNodeId(4) — see
        // ScrollToNodeId_resolves_a_later_node_to_a_strictly_greater_scroll_offset_than_an_earlier_one
        // for why this compares raw ScrollOffset rather than GetCurrentPositionForSave's block index.
        var reference = CreateAttachedView(out _, out _);
        reference.ScrollToNodeId(4);
        var expectedOffset = reference.ScrollOffset;

        var view = CreateAttachedView(out var window, out var launcher);
        view.ScrollToNodeId(3); // the internal-link paragraph's top is now at the viewport top

        window.MouseDown(new Point(30, 10), MouseButton.Left);
        window.MouseUp(new Point(30, 10), MouseButton.Left);

        Assert.Null(launcher.LastOpened);
        Assert.Equal(expectedOffset, view.ScrollOffset, 1);
    }

    [Fact]
    public void Hovering_a_link_shows_a_hand_cursor_and_moving_off_it_resets_to_default()
    {
        var view = CreateAttachedView(out var window, out _);

        view.ScrollToNodeId(2);
        window.MouseMove(new Point(30, 10));
        // Cursor exposes no public CursorType getter to assert against directly — instead this
        // checks the SAME thing FlowDocumentView's own hover logic actually branches on: over a
        // link it assigns a freshly constructed `new Cursor(StandardCursorType.Hand)` (never
        // reference-equal to the shared `Cursor.Default` singleton); off a link it assigns that
        // exact singleton back.
        Assert.NotEqual(Cursor.Default, view.Cursor);

        view.ScrollToNodeId(4); // the bookmark-target paragraph carries no link at all
        window.MouseMove(new Point(30, 10));
        Assert.Equal(Cursor.Default, view.Cursor);
    }

    // ---- ④ right-click context menu MODEL (pure — see S8-B4 report for the live ContextMenu note) ----

    [Fact]
    public void Copy_is_the_only_item_with_no_selection_and_no_link_and_it_is_disabled()
    {
        // S9-B3 batch 5 (docs/studio/sprints/S9/s9b1-full-parity.md #40) added an always-present
        // "Select All" item, so a plain right-click (no selection, no link) now shows TWO items,
        // not one — updated here rather than left green-but-stale, since ContextMenuModel.Build's
        // own contract deliberately changed.
        var items = ContextMenuModel.Build(hasSelection: false, onLink: false);
        Assert.Equal(2, items.Count);
        Assert.Equal("Copy", items[0].Header);
        Assert.False(items[0].Enabled);
        Assert.Equal("Select All", items[1].Header);
        Assert.True(items[1].Enabled);
        Assert.True(items[1].IsSelectAll);
    }

    [Fact]
    public void Copy_is_enabled_when_there_is_a_selection()
    {
        var items = ContextMenuModel.Build(hasSelection: true, onLink: false);
        Assert.Equal(2, items.Count); // Copy + Select All (S9-B3 batch 5)
        Assert.True(items[0].Enabled);
    }

    [Fact]
    public void Copy_Link_appears_and_is_enabled_when_the_right_click_landed_on_a_link()
    {
        // S9-B3 batch 5 (#39) inserts "Open" between "Copy" and "Copy Link" when onLink, and
        // "Select All" is now always the last item — see ContextMenuModel.Build's own doc.
        var items = ContextMenuModel.Build(hasSelection: false, onLink: true);
        Assert.Equal(4, items.Count);
        Assert.Equal("Copy", items[0].Header);
        Assert.False(items[0].Enabled);
        Assert.Equal("Open", items[1].Header);
        Assert.True(items[1].Enabled);
        Assert.True(items[1].IsOpen);
        Assert.Equal("Copy Link", items[2].Header);
        Assert.True(items[2].Enabled);
        Assert.True(items[2].IsCopyLink);
        Assert.Equal("Select All", items[3].Header);
        Assert.True(items[3].Enabled);
    }
}
