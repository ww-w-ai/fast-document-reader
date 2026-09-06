using System.Collections.Generic;

namespace FastDoc.Avalonia.Rendering;

/// <summary>S8-B4 (④): one right-click context menu item, as a pure value — <see
/// cref="ContextMenuModel.Build"/>'s own doc explains why this is kept separate from the live
/// Avalonia <c>ContextMenu</c> control it feeds. <see cref="IsCopyLink"/>/<see cref="IsOpen"/>/
/// <see cref="IsSelectAll"/> distinguish the items this contract asks for without a string
/// comparison on <see cref="Header"/> (<see cref="IsOpen"/>/<see cref="IsSelectAll"/> added S9-B3
/// batch 5 for #39/#40 in docs/studio/sprints/S9/s9b1-full-parity.md).</summary>
public sealed record ContextMenuItemModel(string Header, bool Enabled, bool IsCopyLink = false,
    bool IsOpen = false, bool IsSelectAll = false, bool IsCopyCode = false);

/// <summary>Decides WHICH items a right-click on <see cref="FlowDocumentView"/> shows, and whether
/// each is enabled — kept as a pure function of two booleans (rather than inline in the view's
/// pointer-event handler) so a test can assert the menu's shape without opening a live
/// <c>ContextMenu</c> control, which the S8-B4 contract itself anticipates a headless test harness
/// may not be able to do (see the S8-B4 report for whether that turned out to be true here).</summary>
public static class ContextMenuModel
{
    /// <summary>"Copy" always appears, enabled only when there is a selection to copy (the same
    /// condition Ctrl+C already checks). "Open" (S9-B3 batch 5, #39 — mirrors ReaderTextView.swift's
    /// own Open item) appears ONLY when the right-click landed on a link run, enabled whenever it
    /// appears — same visibility rule "Copy Link" already uses, since both need the same fact (a
    /// resolvable link/path under the pointer). "Select All" (#40) always appears, always enabled —
    /// this host already has the keyboard shortcut (Ctrl/Cmd+A); this only adds the menu item macOS
    /// carries in its own right-click menu. "Copy Code" (S9-B3 batch 6, #46 — the narrower half of
    /// macOS's code-block Wrap/Copy chips this host implements; see FlowDocumentView's own doc for
    /// why "Wrap" itself is out of this batch's scope) appears ONLY when the right-click landed on
    /// a code block, and copies that block's WHOLE text rather than just the current selection.</summary>
    public static List<ContextMenuItemModel> Build(bool hasSelection, bool onLink, bool onCodeBlock = false)
    {
        var items = new List<ContextMenuItemModel> { new("Copy", hasSelection) };
        if (onLink)
        {
            items.Add(new("Open", true, IsOpen: true));
            items.Add(new("Copy Link", true, IsCopyLink: true));
        }
        if (onCodeBlock) { items.Add(new("Copy Code", true, IsCopyCode: true)); }
        items.Add(new("Select All", true, IsSelectAll: true));
        return items;
    }
}
