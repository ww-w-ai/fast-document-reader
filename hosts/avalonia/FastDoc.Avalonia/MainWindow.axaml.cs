using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Native;
using FastDoc.Avalonia.Open;
using FastDoc.Avalonia.Panels;
using FastDoc.Avalonia.Printing;
using FastDoc.Avalonia.Reading;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia;

public partial class MainWindow : Window
{
    private const int PositionSaveDebounceMs = 500;

    /// <summary>E2d: the still-open office parse behind the CURRENTLY shown document, if any —
    /// owned here so it can be disposed exactly once, either when LoadPath swaps in a new document
    /// (a stale handle must never answer for the document that replaced it) or when this window
    /// closes. Null for markdown/text documents and for a failed open.</summary>
    private Rendering.OfficeDocumentHandle? _currentHandle;

    /// <summary>The path behind the document Canvas currently shows, or null when the window is
    /// empty (start-up with no PendingDocumentPath, or the last LoadPath failed) — E3's reading
    /// position has nothing to key against without it.</summary>
    private string? _currentPath;

    private DispatcherTimer? _positionSaveTimer;

    /// <summary>S9-B2: the currently-open Keyboard Shortcuts window, if any -- kept so a second "?"
    /// / F1 / menu click FOCUSES the existing window instead of opening a duplicate. Cleared on
    /// Closed so a later reopen after the reader dismissed it builds a fresh window.</summary>
    private Panels.ShortcutGuideWindow? _shortcutGuideWindow;

    /// <summary>The tree behind the CURRENTLY shown document — kept here (not read back off
    /// <see cref="FlowDocumentView"/>, which does not expose it) purely so the S8-B2 Table of
    /// Contents / Comments panels can rebuild from it without a second engine round-trip.</summary>
    private RenderTree? _currentTree;

    public MainWindow()
    {
        InitializeComponent();
        DragDrop.SetAllowDrop(this, true);
        AddHandler(DragDrop.DragOverEvent, OnDragOver);
        AddHandler(DragDrop.DropEvent, OnDrop);
        AddHandler(KeyDownEvent, OnWindowKeyDown, RoutingStrategies.Tunnel);
        Canvas.ScrollOffsetChanged += OnCanvasScrollOffsetChanged;
        Closed += (_, _) =>
        {
            SaveCurrentPosition();
            _currentHandle?.Dispose();
        };
        RebuildOpenRecentMenu();
        UpdateEmptyState();
        UpdateFlowOnlyMenuEnablement();
        ReloadMenuItem.IsEnabled = _currentPath is not null;
        UpdateEditInAppMenuItem();
        Canvas.ImageClicked += OnCanvasImageClicked; // S9-B3 batch 6: click-to-enlarge
        SetDefaultAppMenuItem.IsEnabled = !OperatingSystem.IsMacOS(); // S8-B2 ②: this host does not
        // run there, but the item stays visibly disabled rather than silently doing nothing if it ever did.
        if (Program.PendingDocumentPath is { } path) { LoadPath(path); }
        // Deferred to Opened rather than called here: Window.Show(owner) throws
        // InvalidOperationException("Cannot show window with non-visible owner") when the owner
        // has not itself been shown yet, which this constructor has not -- reproduced by
        // Scripts/host-gate.sh's no-args GUI-entry smoke.
        Opened += (_, _) => ShowFirstRunNoticeIfNeeded();
    }

    // ---- S8-B2 ②: first-run notice ----------------------------------------------------------

    private void ShowFirstRunNoticeIfNeeded()
    {
        if (!FirstRunNotice.ShouldShow(new SystemFileProbe())) { return; }
        var notice = new Panels.FirstRunWindow();
        notice.Show(this); // non-modal: Show, never ShowDialog
    }

    // ---- S9-B2: Keyboard Shortcuts guide + Welcome (Help menu) ------------------------------

    private void OnShowShortcutGuideClicked(object? sender, RoutedEventArgs e) => ShowShortcutGuide();

    /// <summary>Opening twice focuses the existing window rather than creating a second one --
    /// same idempotence the task asked for, achieved the same way <see cref="_currentHandle"/>
    /// pattern elsewhere in this file guards a single owned resource.</summary>
    private void ShowShortcutGuide()
    {
        if (_shortcutGuideWindow is { } existing)
        {
            existing.Activate();
            return;
        }
        _shortcutGuideWindow = new Panels.ShortcutGuideWindow();
        _shortcutGuideWindow.Closed += (_, _) => _shortcutGuideWindow = null;
        _shortcutGuideWindow.Show(this); // non-modal: Show, never ShowDialog
    }

    private void OnShowWelcomeClicked(object? sender, RoutedEventArgs e)
    {
        var notice = new Panels.FirstRunWindow();
        notice.Show(this); // non-modal, mirrors ShowFirstRunNoticeIfNeeded -- re-opening does not
        // touch FirstRunNotice's "seen" flag, only the box the reader ticks inside it does.
    }

    // ---- S9-B3 batch 6: click-to-enlarge an image/diagram ------------------------------------

    private void OnCanvasImageClicked(ulong resourceId)
    {
        var bitmap = Canvas.ResolveImageBitmap(resourceId);
        if (bitmap is null) { return; } // not (yet) decoded — a lazy docx/odt picture, or a genuine decode failure
        var window = new Panels.ImageZoomWindow();
        window.Configure(bitmap);
        window.Show(this); // non-modal, same choice every other S9-B* window in this file makes
    }

    // ---- S9-B3 batch 8: About FastDoc --------------------------------------------------------

    private Panels.AboutWindow? _aboutWindow;

    private void OnShowAboutClicked(object? sender, RoutedEventArgs e)
    {
        if (_aboutWindow is { } existing)
        {
            existing.Activate();
            return;
        }
        _aboutWindow = new Panels.AboutWindow();
        _aboutWindow.Closed += (_, _) => _aboutWindow = null;
        _aboutWindow.Show(this); // non-modal, same idempotence pattern as ShowShortcutGuide
    }

    private async void OnOpenClicked(object? sender, RoutedEventArgs e)
    {
        var path = await OpenService.PickFileAsync(StorageProvider);
        if (path is null) { return; }
        LoadPath(path);
    }

    // ---- S9-B3 batch 7: Edit in <App> --------------------------------------------------------
    // File > "Edit in Default App…", mirroring ExternalEditor.swift on macOS (docs/studio/sprints/
    // S9/s9b1-full-parity.md #30) — narrowed to the single OS-reported default handler rather than
    // mac's full candidate list (see Open/ExternalEditorResolver.cs's own doc for why). Actually
    // LAUNCHING it reuses the SAME Rendering.IExternalLinkLauncher seam NavigateLink already uses
    // (UseShellExecute resolves the OS default handler on every platform), so this is not a third
    // process-launch mechanism.

    private readonly Open.IExternalEditorProbe _externalEditorProbe = Open.ExternalEditorProbeFactory.Create();
    private readonly Rendering.IExternalLinkLauncher _externalEditorLauncher = new Rendering.ProcessExternalLinkLauncher();

    private void OnEditInAppClicked(object? sender, RoutedEventArgs e)
    {
        if (_currentPath is { } path) { _externalEditorLauncher.Open(path); }
    }

    /// <summary>Relabels/(en/dis)ables EditInAppMenuItem for the document CURRENTLY loaded —
    /// called from the same places <see cref="UpdateFlowOnlyMenuEnablement"/> is (end of
    /// <see cref="LoadPath"/>), since both depend on "what document is open now".</summary>
    private void UpdateEditInAppMenuItem()
    {
        var extension = _currentPath is null ? null : System.IO.Path.GetExtension(_currentPath);
        var isOffice = extension is not null && Open.ExternalEditorResolver.IsOfficeExtension(extension);
        EditInAppMenuItem.IsEnabled = isOffice;
        if (!isOffice)
        {
            EditInAppMenuItem.Header = "Edit in Default App…";
            return;
        }
        var appName = _externalEditorProbe.DefaultAppName(extension!);
        EditInAppMenuItem.Header = appName is null ? "Edit in Default App…" : $"Edit in {appName}…";
    }

    // ---- S9-B3 batch 4: Reload --------------------------------------------------------------
    // File > Reload (Ctrl+R), mirroring AppDelegate.swift:221 — re-reads the SAME path from disk
    // through the ordinary LoadPath door (the same one Open… and a recent-file click use), so a
    // document edited externally since it was opened is picked up. ReloadMenuItem's enablement is
    // kept in UpdateFlowOnlyMenuEnablement's caller sites via _currentPath directly (a document
    // need not be flow-mode/no-page-geometry to reload, unlike Line Numbers/Go to Line).

    private void OnReloadClicked(object? sender, RoutedEventArgs e)
    {
        if (_currentPath is { } path) { LoadPath(path); }
    }

    // ---- E6: PDF export ---------------------------------------------------------------------

    // File > Export PDF... (Ctrl/Cmd+P) -- the GUI's own door onto PdfExporter.ExportPdf, the SAME
    // function the headless `--pdf` CLI path calls (Program.RunPdf), mirroring the macOS app's
    // "GUI print and headless --pdf share one function" contract (INVARIANTS.md 66) even though
    // this host writes the PDF directly rather than going through a print dialog -- Avalonia 12
    // has no print API to route through (see hosts/avalonia/README.md's printing note).
    private async void OnExportPdfClicked(object? sender, RoutedEventArgs e)
    {
        if (_currentPath is null) { return; }
        var suggestedName = System.IO.Path.GetFileNameWithoutExtension(_currentPath) + ".pdf";
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Export PDF",
            SuggestedFileName = suggestedName,
            DefaultExtension = "pdf",
            FileTypeChoices = new[] { new FilePickerFileType("PDF") { Patterns = new[] { "*.pdf" } } },
        });
        var outPath = file?.Path.LocalPath;
        if (outPath is null) { return; }

        try
        {
            var result = PdfExporter.ExportPdf(_currentPath, outPath);
            StatusText.Text = $"Exported {result.PageCount} page(s) to {outPath}";
            OpenWithDefaultHandler(outPath);
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Export PDF failed: {ex.Message}";
        }
    }

    /// <summary>Best-effort "open the file I just wrote" via the OS's own default handler -- never
    /// throws past this method, since a missing/failed viewer must not make the export itself look
    /// like it failed (the PDF is already written by the time this runs).</summary>
    private static void OpenWithDefaultHandler(string path)
    {
        try
        {
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        catch
        {
            // Deliberately swallowed -- see this method's own doc.
        }
    }

    // ---- S8-B2 ①: extract to Markdown ---------------------------------------------------------

    // File > "Extract to Markdown…" -- the GUI's own door onto Program.BuildExtractedMarkdown, the
    // SAME code the headless `--extract` CLI path prints to stdout (mirrors the Export PDF handler
    // just above, and the macOS app's own "GUI action and headless flag share one function" rule,
    // INVARIANTS.md 40/66). Reopens the document by path rather than reading Canvas's already-
    // loaded tree, matching how OnExportPdfClicked/PdfExporter.ExportPdf do it -- one document-open
    // convention for every export door, not two.
    private async void OnExtractClicked(object? sender, RoutedEventArgs e)
    {
        if (_currentPath is null) { return; }
        var suggestedName = System.IO.Path.GetFileNameWithoutExtension(_currentPath) + ".md";
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Extract to Markdown",
            SuggestedFileName = suggestedName,
            DefaultExtension = "md",
            FileTypeChoices = new[] { new FilePickerFileType("Markdown") { Patterns = new[] { "*.md" } } },
        });
        var outPath = file?.Path.LocalPath;
        if (outPath is null) { return; }

        try
        {
            var result = RenderTreeLoader.Load(_currentPath);
            using var _ = result.Handle;
            if (!result.IsOk)
            {
                var extension = System.IO.Path.GetExtension(_currentPath).TrimStart('.');
                StatusText.Text = $"Extract failed: {EngineErrorText.Humanize(result.Error?.Kind, result.Error?.Message, extension)}";
                return;
            }
            var markdown = Program.BuildExtractedMarkdown(_currentPath, result.Tree!);
            System.IO.File.WriteAllText(outPath, markdown);
            StatusText.Text = $"Extracted to {outPath}";
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Extract failed: {ex.Message}";
        }
    }

    // ---- S8-B2 ②: set as default app -------------------------------------------------------

    private void OnSetDefaultAppClicked(object? sender, RoutedEventArgs e)
    {
        var result = DefaultAppRegistrarFactory.Create().Register();
        StatusText.Text = result.Message;
    }

    // Cmd+O/F on macOS, Ctrl+ +/-/0 zoom, Ctrl/Cmd+F find-bar toggle, Esc closes the find bar: the
    // "_Open…" menu item's HotKey="Ctrl+O" covers Windows/Linux, where Ctrl is the platform's own
    // accelerator modifier — Avalonia's HotKey does not remap Ctrl to Cmd on macOS, so every one of
    // these accelerators is handled here explicitly (macOS Meta, everyone else Control) rather than
    // relying on per-platform XAML gestures for each.
    private void OnWindowKeyDown(object? sender, KeyEventArgs e)
    {
        var isMeta = e.KeyModifiers.HasFlag(KeyModifiers.Meta);
        var isCtrl = e.KeyModifiers.HasFlag(KeyModifiers.Control);
        var isAccel = isMeta || isCtrl;

        if (isAccel && e.Key == Key.O)
        {
            e.Handled = true;
            OnOpenClicked(sender, new RoutedEventArgs());
            return;
        }

        if (isAccel && e.Key == Key.F)
        {
            e.Handled = true;
            ShowFindBar();
            return;
        }

        // S9-B3 batch 4: Ctrl/Cmd+R reloads the current document from disk.
        if (isAccel && e.Key == Key.R)
        {
            e.Handled = true;
            OnReloadClicked(sender, new RoutedEventArgs());
            return;
        }

        // "+" usually arrives as OemPlus (US layout, shares the key with "="); numpad Add is its
        // own key. "-" is OemMinus / numpad Subtract. "0" is the top-row digit or numpad 0.
        if (isAccel && (e.Key == Key.OemPlus || e.Key == Key.Add))
        {
            e.Handled = true;
            Canvas.ZoomIn();
            return;
        }
        if (isAccel && (e.Key == Key.OemMinus || e.Key == Key.Subtract))
        {
            e.Handled = true;
            Canvas.ZoomOut();
            return;
        }
        if (isAccel && (e.Key == Key.D0 || e.Key == Key.NumPad0))
        {
            e.Handled = true;
            Canvas.ZoomReset();
            return;
        }

        // E2c-1: Ctrl/Cmd+Shift+P toggles flow <-> page mode — mirrors the MenuItem's own HotKey
        // so the accelerator works even when this window's menu has not been opened yet.
        if (isAccel && e.KeyModifiers.HasFlag(KeyModifiers.Shift) && e.Key == Key.P)
        {
            e.Handled = true;
            TogglePageMode();
            return;
        }

        // S9-B3 batch 2: Ctrl/Cmd+Shift+M / +B — same Meta/Control-explicit pattern as
        // Page Mode's own Ctrl+Shift+P branch just above, for the same reason (HotKey does not
        // remap Ctrl to Cmd on macOS).
        if (isAccel && e.KeyModifiers.HasFlag(KeyModifiers.Shift) && e.Key == Key.M && Canvas.HasPageGeometry)
        {
            e.Handled = true;
            OnMasterPageFurnitureToggleClicked(sender, new RoutedEventArgs());
            return;
        }
        if (isAccel && e.KeyModifiers.HasFlag(KeyModifiers.Shift) && e.Key == Key.B && Canvas.HasPageGeometry)
        {
            e.Handled = true;
            OnSplitTablesToggleClicked(sender, new RoutedEventArgs());
            return;
        }

        // S9-B3 batch 3: Ctrl/Cmd+Shift+L toggles Line Numbers, Ctrl/Cmd+L opens Go to Line… —
        // same Meta/Control-explicit pattern as the toggles just above.
        if (isAccel && e.KeyModifiers.HasFlag(KeyModifiers.Shift) && e.Key == Key.L)
        {
            e.Handled = true;
            OnLineNumbersToggleClicked(sender, new RoutedEventArgs());
            return;
        }
        if (isAccel && !e.KeyModifiers.HasFlag(KeyModifiers.Shift) && e.Key == Key.L)
        {
            e.Handled = true;
            OnGoToLineClicked(sender, new RoutedEventArgs());
            return;
        }

        if (e.Key == Key.Escape && FindBar.IsVisible)
        {
            e.Handled = true;
            HideFindBar();
        }

        // S9-B2: "?" (Shift+/ on a US layout -- Key.OemQuestion regardless of Shift, so a layout
        // that puts "?" on the unshifted key still opens the guide) and F1, mirroring the Help
        // menu's own HotKey="F1". The key decision itself lives in
        // Panels.ShortcutGuideModel.ShouldOpenFromKey (a pure function a headless test can drive
        // directly) rather than being re-derived here as an inline condition.
        if (Panels.ShortcutGuideModel.ShouldOpenFromKey(e.Key, FindTextBox.IsFocused))
        {
            e.Handled = true;
            ShowShortcutGuide();
        }
    }

    // ---- find bar -------------------------------------------------------------------------------

    private void ShowFindBar()
    {
        FindBar.IsVisible = true;
        FindTextBox.Focus();
        FindTextBox.SelectAll();
        if (!string.IsNullOrEmpty(FindTextBox.Text))
        {
            Canvas.SetSearchQuery(FindTextBox.Text);
            UpdateFindCount();
        }
    }

    private void HideFindBar()
    {
        FindBar.IsVisible = false;
        Canvas.ClearSearch();
        UpdateFindCount();
        Canvas.Focus();
    }

    private void OnFindCloseClicked(object? sender, RoutedEventArgs e) => HideFindBar();

    private void OnFindTextChanged(object? sender, TextChangedEventArgs e)
    {
        Canvas.SetSearchQuery(FindTextBox.Text);
        UpdateFindCount();
    }

    private void OnFindNextClicked(object? sender, RoutedEventArgs e)
    {
        Canvas.FindNext();
        UpdateFindCount();
    }

    private void OnFindPrevClicked(object? sender, RoutedEventArgs e)
    {
        Canvas.FindPrevious();
        UpdateFindCount();
    }

    private void OnFindTextBoxKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            e.Handled = true;
            if (e.KeyModifiers.HasFlag(KeyModifiers.Shift)) { Canvas.FindPrevious(); }
            else { Canvas.FindNext(); }
            UpdateFindCount();
        }
        else if (e.Key == Key.Escape)
        {
            e.Handled = true;
            HideFindBar();
        }
    }

    private void UpdateFindCount()
    {
        FindCountText.Text = $"{Canvas.CurrentMatchNumber}/{Canvas.MatchCount}";
    }

    // ---- drag/drop --------------------------------------------------------------------------------

    private void OnDragOver(object? sender, DragEventArgs e)
    {
        e.DragEffects = e.DataTransfer.Contains(DataFormat.File)
            ? DragDropEffects.Copy
            : DragDropEffects.None;
    }

    private void OnDrop(object? sender, DragEventArgs e)
    {
        var items = e.DataTransfer.TryGetFiles();
        var path = items?
            .Select(item => item.TryGetLocalPath())
            .FirstOrDefault(p => p is not null && DocumentExtensions.IsSupported(System.IO.Path.GetExtension(p)));
        if (path is null) { return; }
        LoadPath(path);
    }

    // ---- opening a document -----------------------------------------------------------------------

    public void LoadPath(string path)
    {
        // E3: persist wherever the OUTGOING document was before it is replaced — a debounce timer
        // pending from the last scroll would otherwise fire after Canvas.SetTree already moved on.
        SaveCurrentPosition();
        StopPositionSaveTimer();

        // E2d: close the PREVIOUS document's handle before this one replaces it in _currentHandle
        // — one owner, one close, same rule OfficeDocumentHandle states for itself. A load that
        // throws below still leaves the old handle disposed and _currentHandle null, matching
        // Canvas.SetTree(null) on that path: no handle survives for a document no longer shown.
        _currentHandle?.Dispose();
        _currentHandle = null;
        try
        {
            var result = RenderTreeLoader.Load(path);
            if (result.IsOk)
            {
                Canvas.SetTree(result.Tree);
                _currentHandle = result.Handle;
                Canvas.SetHandle(_currentHandle); // must follow SetTree — see FlowDocumentView.SetHandle's own doc
                Canvas.SetZipSource(result.DocumentPath, System.IO.Path.GetExtension(path)); // docx/odt lazy pictures
                _currentPath = path;
                Title = System.IO.Path.GetFileName(path);

                // E6: office documents open in FLOW mode by default now — page mode's sheet
                // count is still short of Word's own pagination (see hosts/avalonia/README.md,
                // "Sprint 5"), so it is a View-menu opt-in rather than the default. The menu item
                // stays enabled whenever the document HAS page geometry to toggle into.
                // MUST run before the saved-position restore below — PageMode's own setter resets
                // scroll to 0, which would otherwise wipe out RestorePosition's answer.
                PageModeMenuItem.IsEnabled = Canvas.HasPageGeometry;
                Canvas.PageMode = false;
                PageModeMenuItem.IsChecked = Canvas.PageMode;
                // S9-B3 batch 2: same enablement rule as Page Mode itself — both toggles are about
                // a PAGE, so with no page geometry there is nothing for them to be about. Unlike
                // PageMode they are NOT reset per document: mirrors PageViewOptions.swift's own
                // "seeded from the last choice" rule (this host has no per-document preference
                // store yet, so "last choice" here is simply "whatever the reader last set").
                MasterPageFurnitureMenuItem.IsEnabled = Canvas.HasPageGeometry;
                SplitTablesMenuItem.IsEnabled = Canvas.HasPageGeometry;
                MasterPageFurnitureMenuItem.IsChecked = Canvas.MasterPageFurniture;
                SplitTablesMenuItem.IsChecked = Canvas.SplitTablesAcrossPages;

                var positionKey = ReadingPositions.MakeKey(path);
                var saved = ReadingPositions.Find(positionKey);
                if (saved is not null)
                {
                    Canvas.SetZoom(saved.Zoom);
                    Canvas.RestorePosition(saved.BlockIndex, saved.Fraction);
                }

                var count = result.Tree!.Nodes.Count;
                StatusText.Text = $"{path}: opened {count} nodes, {result.ElapsedMs} ms";
                RecentFiles.RecordOpened(path);
                RebuildOpenRecentMenu();
                Canvas.Focus(); // S6-F: keyboard scroll only works once the view actually holds focus

                _currentTree = result.Tree; // S8-B2: Table of Contents / Comments panels rebuild from this
                RebuildTocList();
                RebuildCommentsList();
            }
            else
            {
                Canvas.SetTree(null);
                _currentPath = null;
                Title = "FastDoc";
                var extension = System.IO.Path.GetExtension(path).TrimStart('.');
                StatusText.Text = $"{path}: {EngineErrorText.Humanize(result.Error?.Kind, result.Error?.Message, extension)}";
                _currentTree = null;
                RebuildTocList();
                RebuildCommentsList();
            }
        }
        catch (Exception ex)
        {
            Canvas.SetTree(null);
            _currentPath = null;
            Title = "FastDoc";
            StatusText.Text = $"{path}: {ex.Message}";
            _currentTree = null;
            RebuildTocList();
            RebuildCommentsList();
        }
        UpdateEmptyState();
        UpdateFlowOnlyMenuEnablement(); // S9-B3 batch 3: Line Numbers/Go to Line need a document, not page mode
        ReloadMenuItem.IsEnabled = _currentPath is not null; // S9-B3 batch 4: reload needs SOME path, page mode or not
        UpdateEditInAppMenuItem(); // S9-B3 batch 7: office-document-only, relabelled to the current default app
    }

    // ---- E2c-1: page mode --------------------------------------------------------------------

    private void OnPageModeToggleClicked(object? sender, RoutedEventArgs e) => TogglePageMode();

    private void TogglePageMode()
    {
        if (!Canvas.HasPageGeometry) { return; } // md/txt, or an office doc with no declared paper
        Canvas.PageMode = !Canvas.PageMode;
        PageModeMenuItem.IsChecked = Canvas.PageMode;
        UpdateFlowOnlyMenuEnablement();
    }

    // ---- S9-B3 batch 2: Master Page Furniture / Split Tables Across Pages --------------------

    private void OnMasterPageFurnitureToggleClicked(object? sender, RoutedEventArgs e)
    {
        Canvas.MasterPageFurniture = !Canvas.MasterPageFurniture;
        MasterPageFurnitureMenuItem.IsChecked = Canvas.MasterPageFurniture;
    }

    private void OnSplitTablesToggleClicked(object? sender, RoutedEventArgs e)
    {
        Canvas.SplitTablesAcrossPages = !Canvas.SplitTablesAcrossPages;
        SplitTablesMenuItem.IsChecked = Canvas.SplitTablesAcrossPages;
    }

    // ---- S9-B3 batch 3: Line Numbers / Go to Line… -------------------------------------------
    // Flow mode only (LineNumberModel's own doc explains why page mode is out of this batch's
    // scope) — both menu items disable themselves while Canvas.PageMode is on, re-checked every
    // time page mode itself is toggled (TogglePageMode) and on document load (LoadPath).

    private void OnLineNumbersToggleClicked(object? sender, RoutedEventArgs e)
    {
        Canvas.ShowLineNumbers = !Canvas.ShowLineNumbers;
        LineNumbersMenuItem.IsChecked = Canvas.ShowLineNumbers;
    }

    private void OnGoToLineClicked(object? sender, RoutedEventArgs e)
    {
        if (Canvas.PageMode || !Canvas.HasDocument) { return; }
        var dialog = new Panels.GoToLineWindow();
        dialog.Configure(Canvas);
        dialog.Show(this); // non-modal, mirrors ShowShortcutGuide/OnShowWelcomeClicked
    }

    private void UpdateFlowOnlyMenuEnablement()
    {
        var enabled = Canvas.HasDocument && !Canvas.PageMode;
        LineNumbersMenuItem.IsEnabled = enabled;
        GoToLineMenuItem.IsEnabled = enabled;
    }

    private void UpdateEmptyState()
    {
        EmptyStateText.IsVisible = !Canvas.HasDocument;
    }

    // ---- S8-B2 ③: Table of Contents ------------------------------------------------------

    private const double TocPanelWidth = 220;

    private void OnTocToggleClicked(object? sender, RoutedEventArgs e)
    {
        var column = ContentGrid.ColumnDefinitions[0];
        var showing = column.Width.Value == 0;
        column.Width = new GridLength(showing ? TocPanelWidth : 0);
        TocPanel.IsVisible = showing;
        TocMenuItem.IsChecked = showing;
    }

    private void RebuildTocList()
    {
        TocListBox.ItemsSource = _currentTree is null
            ? Array.Empty<TocListItem>()
            : TableOfContentsModel.Build(_currentTree).Select(TocListItem.From).ToList();
    }

    private void OnTocSelectionChanged(object? sender, SelectionChangedEventArgs e)
    {
        if (TocListBox.SelectedItem is TocListItem item)
        {
            Canvas.ScrollToNodeId(item.NodeId);
            Canvas.Focus();
        }
    }

    /// <summary>ListBox display item for one <see cref="TocEntry"/> — <see cref="IndentMargin"/>
    /// turns the heading LEVEL into a left indent so nested headings read as a tree.</summary>
    private sealed class TocListItem
    {
        public string Text { get; init; } = "";
        public ulong NodeId { get; init; }
        public Thickness IndentMargin { get; init; }

        public static TocListItem From(TocEntry entry) => new()
        {
            Text = entry.Text,
            NodeId = entry.NodeId,
            IndentMargin = new Thickness(Math.Max(0, entry.Level - 1) * 12, 2, 4, 2),
        };
    }

    // ---- S8-B2 ④: Comments -----------------------------------------------------------------

    private const double CommentsPanelWidth = 260;

    private void OnCommentsToggleClicked(object? sender, RoutedEventArgs e)
    {
        var column = ContentGrid.ColumnDefinitions[2];
        var showing = column.Width.Value == 0;
        column.Width = new GridLength(showing ? CommentsPanelWidth : 0);
        CommentsPanel.IsVisible = showing;
        CommentsMenuItem.IsChecked = showing;
    }

    private void RebuildCommentsList()
    {
        CommentsListBox.ItemsSource = _currentTree is null
            ? Array.Empty<CommentListItem>()
            : CommentsModel.Build(_currentTree).Select(CommentListItem.From).ToList();
    }

    /// <summary>S8-B4: clicking a comment scrolls to the run it is anchored to, mirroring
    /// <see cref="OnTocSelectionChanged"/> exactly — the panel differs only in that a comment can
    /// come back with no resolvable anchor (see <see cref="CommentEntry.NodeId"/>'s own doc), in
    /// which case this is a no-op rather than a crash or a scroll to nowhere.</summary>
    private void OnCommentsSelectionChanged(object? sender, SelectionChangedEventArgs e)
    {
        if (CommentsListBox.SelectedItem is CommentListItem { NodeId: { } nodeId })
        {
            Canvas.ScrollToNodeId(nodeId);
            Canvas.Focus();
        }
    }

    /// <summary>ListBox display item for one <see cref="CommentEntry"/> — <see cref="Header"/>
    /// pre-formats "Comment N — author (date)" so the XAML template stays a plain binding.</summary>
    private sealed class CommentListItem
    {
        public string Header { get; init; } = "";
        public string Text { get; init; } = "";
        public ulong? NodeId { get; init; }

        public static CommentListItem From(CommentEntry entry) => new()
        {
            Header = entry.DateIso is { Length: > 0 }
                ? $"Comment {entry.Number} — {entry.Author} ({entry.DateIso})"
                : $"Comment {entry.Number} — {entry.Author}",
            Text = entry.Text,
            NodeId = entry.NodeId,
        };
    }

    // ---- reading position (E3) --------------------------------------------------------------------

    private void OnCanvasScrollOffsetChanged()
    {
        StopPositionSaveTimer();
        _positionSaveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(PositionSaveDebounceMs) };
        _positionSaveTimer.Tick += (_, _) =>
        {
            StopPositionSaveTimer();
            SaveCurrentPosition();
        };
        _positionSaveTimer.Start();
    }

    private void StopPositionSaveTimer()
    {
        _positionSaveTimer?.Stop();
        _positionSaveTimer = null;
    }

    private void SaveCurrentPosition()
    {
        if (_currentPath is null || !Canvas.HasDocument) { return; }
        var (blockIndex, fraction) = Canvas.GetCurrentPositionForSave();
        ReadingPositions.Save(ReadingPositions.MakeKey(_currentPath), blockIndex, fraction, Canvas.ZoomFactor);
    }

    private void RebuildOpenRecentMenu()
    {
        var entries = RecentFiles.Load();
        OpenRecentMenu.Items.Clear();
        if (entries.Count == 0)
        {
            OpenRecentMenu.Items.Add(new MenuItem { Header = "(empty)", IsEnabled = false });
            return;
        }
        foreach (var entry in entries)
        {
            var item = new MenuItem { Header = entry.Path };
            item.Click += (_, _) => LoadPath(entry.Path);
            OpenRecentMenu.Items.Add(item);
        }
    }
}
