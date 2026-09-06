using System;
using System.Collections.Generic;
using System.IO;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Media.Immutable;
using Avalonia.Media.TextFormatting;
using Avalonia.Styling;
using Avalonia.Utilities;
using FastDoc.Avalonia.Model;
using FastDoc.Avalonia.Paging;
using FastDoc.Avalonia.Printing;

namespace FastDoc.Avalonia.Rendering;

/// <summary>
/// Flow-mode document view for the Windows/Linux host (ADR 0002 — Avalonia's own TextLayout does
/// line-breaking and pixel placement; the engine gives structure only): real paragraph typography —
/// font/size/weight/style/color/alignment/indent/spacing pulled from the RenderTree via
/// FlowDocumentBuilder, laid out into the reading column and drawn.
///
/// VIRTUALIZATION (required — a real document can be thousands of blocks): every block's height
/// starts as a cheap character-count ESTIMATE, so the initial cumulative-offset table exists
/// without laying out the whole document. Only blocks inside the current viewport (plus one
/// screen of buffer above/below) ever get a real TextLayout built. The first time a block is
/// actually drawn, its true measured height replaces the estimate and the offset table is rebuilt
/// — so each block pays the O(n) rebuild at most once, when it is first revealed, not every frame
/// (front-first: near blocks settle on scroll 1, the estimate elsewhere is corrected lazily).
///
/// Scrolling is a self-owned property (ScrollOffset) rather than an outer ScrollViewer, so a
/// headless caller (the --paint-probe entry point) can move it by code without a live pointer.
///
/// Three more caches exist for reader UX, all invalidated together whenever the layout width or
/// the zoom factor changes (both re-wrap every line, so nothing shaped for the old width/zoom is
/// reusable): a bounded LRU of built TextLayouts for TEXT blocks (a scroll that re-reveals a block
/// it already measured reuses the shaped layout instead of re-shaping it), a per-table row-height
/// cache handed to TableGridRenderer (see that file's own doc for why a table needs one of its
/// own), and the find-in-document match list (a match's block index is only meaningful for the
/// tree that produced it).
/// </summary>
public sealed class FlowDocumentView : Control
{
    private const double PointsToPixels = 96.0 / 72.0;
    private const double LeftMargin = 24;
    private const double RightMargin = 24;
    private const double TopMargin = 12;
    private const double AverageCharsPerLine = 80;
    private const double MinZoom = 0.5;
    private const double MaxZoom = 3.0;
    private const double ZoomStep = 0.1;
    private const int TextLayoutCacheCapacity = 200;

    // Theme-derived brushes, not a fixed Brushes.Black — a fixed foreground on a window that
    // otherwise follows the OS theme (App.axaml's RequestedThemeVariant="Default") reads as
    // near-black text on a near-black FluentTheme dark background. Resolved from the SAME FluentTheme
    // resource dictionary the rest of the app's controls already draw from (see UpdateThemeBrushes),
    // re-resolved whenever ActualThemeVariantChanged fires, and cached as ImmutableSolidColorBrush —
    // SolidColorBrush is Dispatcher-thread-affine (see the comment on BuildTextLayout below) and
    // the background prefetch worker reads this field off the UI thread.
    private const string ForegroundResourceKey = "SystemControlForegroundBaseHighBrush";
    private const string BackgroundResourceKey = "SystemRegionBrush";
    private IBrush _foregroundBrush = new ImmutableSolidColorBrush(Colors.Black);
    private Color _backgroundColor = Colors.White;
    private static readonly Color RuleColor = Color.FromRgb(0xbb, 0xbb, 0xbb);
    private static readonly Typeface DefaultTypeface = new("Inter");
    // S8-D2 (D2-b): theme-resolved (see UpdateThemeBrushes) from App.axaml's own Light/Dark
    // ThemeDictionaries — FluentTheme itself ships no yellow/orange "search highlight" family, so
    // this app defines one. The literals here are ONLY the fallback for a FlowDocumentView built
    // outside a themed Application (never reached in the shipping app; some unit tests construct
    // a bare view with no resource dictionary at all).
    private const string FindMatchResourceKey = "FindMatchHighlightColor";
    private const string FindCurrentMatchResourceKey = "FindCurrentMatchHighlightColor";
    private Color _findMatchHighlightColor = Color.FromArgb(0x90, 0xFF, 0xEB, 0x3B);
    private Color _findCurrentMatchHighlightColor = Color.FromArgb(0xB0, 0xFF, 0x98, 0x00);

    /// <summary>The currently-resolved find-match highlight colour (every match) — exposed the
    /// same way <see cref="ThemeForegroundColor"/> is, so a test can assert it without reflection
    /// and without needing a live DrawingContext.</summary>
    public Color FindMatchHighlightColor => _findMatchHighlightColor;

    /// <summary>The currently-resolved CURRENT find-match highlight colour — see <see
    /// cref="FindMatchHighlightColor"/>'s own doc.</summary>
    public Color FindCurrentMatchHighlightColor => _findCurrentMatchHighlightColor;
    // Theme-resolved (see UpdateThemeBrushes) — a translucent tint of the FluentTheme accent
    // colour, which is itself already defined for both light and dark, so this never hardcodes a
    // colour that only reads correctly in one theme. The literal below is only the fallback for a
    // host resource dictionary that somehow lacks SystemAccentColor entirely.
    private const string SelectionAccentResourceKey = "SystemAccentColor";
    private Color _selectionHighlightColor = Color.FromArgb(0x60, 0x3F, 0x8C, 0xE0);

    // S8-D2 (D2-a): flow-mode text selection. Positions are produced ONLY by hit-testing the SAME
    // cached TextLayout the draw path already built (GetOrBuildTextLayout) — see HitTestPosition's
    // own doc — never a second layout or a re-derived coordinate space.
    private readonly SelectionModel _selection = new();
    private bool _isSelecting;
    private const double EdgeAutoScrollThresholdPx = 24;
    private const double EdgeAutoScrollStepPx = 20;

    /// <summary>The live selection model — read by MainWindow only to decide UI enablement (e.g. a
    /// "Copy" menu item); painting and clipboard both stay entirely inside this view.</summary>
    public SelectionModel Selection => _selection;

    // S8-B4 (D2-c): link click vs. drag disambiguation. A press records where it landed and which
    // link (if any) is under it; the release only navigates when the pointer never moved past
    // LinkClickMovementTolerancePx — a genuine drag has already extended the selection by then
    // (OnPointerMoved), so this never double-acts on one gesture.
    private Point? _pointerDownPoint;
    private string? _pointerDownLink;
    private const double LinkClickMovementTolerancePx = 3;

    /// <summary>Where an external (http/https/mailto) link click is actually sent — injectable so
    /// a test can assert a click WOULD have opened a URL without a real browser launching. Never
    /// used for an internal anchor, which resolves to a NodeId and calls <see cref="ScrollToNodeId"/>
    /// instead.</summary>
    public IExternalLinkLauncher ExternalLinkLauncher { get; set; } = new ProcessExternalLinkLauncher();

    // S8-B4 (④): the link (if any) under the point a right-click landed on — captured at
    // OnPointerPressed time so RebuildContextMenu (which runs later, when the menu actually opens)
    // does not need to re-hit-test against a pointer position it no longer has.
    private string? _lastRightClickLink;
    /// <summary>S9-B3 batch 6: the WHOLE plain text of the code block a right-click landed on, or
    /// null — see <see cref="CodeBlockTextAt"/> and <see cref="RebuildContextMenu"/>'s own doc.</summary>
    private string? _lastRightClickCodeBlockText;

    // S8-B5: the current tree's heading-slug map (see HeadingAnchorResolver's own doc) — rebuilt
    // once per SetTree, alongside the bookmark map NavigateLink already reads straight off _tree.
    private HeadingAnchorResolver _headingAnchorResolver = HeadingAnchorResolver.Empty;

    private List<FlowBlock> _blocks = new();
    private double[] _blockHeights = Array.Empty<double>();
    private bool[] _measured = Array.Empty<bool>();
    private double[] _offsets = Array.Empty<double>(); // length = _blocks.Count + 1; offsets[^1] = total height
    private double _layoutWidth = -1;
    private double _scrollOffset;
    private double _zoomFactor = 1.0;
    private readonly ImageBlockRenderer _imageRenderer = new();

    // S9-V diagnostic: per-frame draw/cull log, gated ENTIRELY by an env var checked ONCE at type
    // load (a static field initializer runs once per process, never per frame) so an unset
    // variable costs exactly one null-check per frame thereafter — no file handle, no lock
    // contention, no string built. Written for the VM-reported flow-mode blank-region bug (S9-C/
    // S9-V): the lead's own headless macOS replay could not reproduce it, so instead of guessing
    // further this lets the VM record its OWN real scroll/cull decisions to a file the lead reads
    // back. Same spirit as this repo's FMD_* corpus probes (see fast-md-reader's own CLAUDE.md) —
    // a real-environment diagnostic gated by an env var, not a permanent UI feature.
    private static readonly string? DrawLogPath = Environment.GetEnvironmentVariable("FASTDOC_DRAW_LOG");
    private static readonly object DrawLogLock = new();
    private static long _drawLogFrameCounter;

    // ---- page mode ------------------------------------------------------------------------------
    private readonly PageModePainter _pageModePainter;
    private RenderTree? _tree;
    private OfficeDocumentHandle? _officeHandle;
    private bool _pageMode;
    private PageGeometry? _pageGeometry;
    private BlockPageMarkers.Markers _pageMarkers;
    private PageLayoutResult? _pageLayout;
    private bool _pageLayoutDirty = true;

    /// <summary>S9-B3 batch 2: mirrors macOS's <c>PageViewOptions.masterPage</c> — whether the
    /// running header/footer band is reserved and drawn at all. This host has not decoded HWP's
    /// 바탕쪽 background artwork (App/MasterPagePainter.swift on macOS), so "furniture" here means
    /// the header/footer band PageBandResolver reserves (<c>headersOn</c>/<c>footersOn</c>) — the
    /// one piece of page furniture this host's engine call already answers for. Defaults to true,
    /// matching <c>PageViewOptions.default</c>.</summary>
    private bool _masterPageFurniture = true;

    /// <summary>S9-B3 batch 2: mirrors macOS's <c>PageViewOptions.splitTables</c> — whether a table
    /// that will not finish on the page it starts on is broken at a row boundary (true, the
    /// document's own behaviour) or carried whole to the next page (false). Fed straight to
    /// <see cref="PageLayout.BuildWithTableSettle"/>'s <c>splitTablesDefault</c> parameter, which
    /// already existed but was hardcoded to <c>true</c> before this batch.</summary>
    private bool _splitTablesAcrossPages = true;

    /// <summary>S9-B3 batch 3: View > Line Numbers — see <see cref="LineNumberModel"/>'s own doc for
    /// what this host numbers (top-level blocks, flow mode only) and why page mode is out of scope
    /// for this batch. OFF by default, mirroring MarginNumberStore.isOn's own default on macOS.</summary>
    private bool _showLineNumbers;
    private static readonly IBrush LineNumberBrush = new SolidColorBrush(Color.FromRgb(0x99, 0x99, 0x99));
    private readonly Typeface LineNumberTypeface = new("Inter");

    // Bounded reuse of built TextLayouts for text blocks, keyed by block index. Cleared
    // wholesale on any width/zoom change (see EnsureEstimates/ApplyZoom) since every layout in it
    // was shaped for the width and font scale that no longer holds.
    private readonly Dictionary<int, TextLayout> _textLayoutCache = new();
    private readonly LinkedList<int> _textLayoutLru = new();
    private readonly Dictionary<int, LinkedListNode<int>> _textLayoutLruNodes = new();

    // Background scroll prefetch. Pure-text documents pay the whole scroll-frame cost in
    // TextLayout construction for the blocks that just entered the viewport (measured: moby-dick.md
    // scroll frames spent ~90-100% of their time in TextLayout construction, 0% in drawing).
    // Avalonia's TextLayout constructor was verified safe to call off the UI thread (a 16-task
    // concurrent build + later UI-thread property access/draw probe produced zero exceptions),
    // so a background worker builds the layouts for the
    // blocks about to be revealed — in the CURRENT scroll direction only, never the opposite one —
    // and stages them here. GetOrBuildTextLayout checks this staging map before paying the build
    // cost itself; a background layout that arrives too late (direction reversed, or the block was
    // evicted) is simply picked up whenever that block is next needed, or never consumed at all.
    private readonly System.Collections.Concurrent.ConcurrentDictionary<int, TextLayout> _prefetchStaging = new();
    private readonly System.Collections.Concurrent.ConcurrentDictionary<int, byte> _prefetchInFlight = new();
    private double _lastScrollOffsetForDirection;
    private int _scrollDirection = 1; // +1 down, -1 up; defaults to down (the common first move)
    private const int PrefetchBlockCount = 24;
    private const int PrefetchStagingCap = 200; // backpressure: stop scheduling once this many wait unconsumed

    // Layout generation — incremented every time ClearCaches runs, i.e. every SetTree (a new
    // document — the S6-A2 BLOCKER this token was written for) AND every width/zoom/theme change
    // (SetZoom, EnsureEstimates on a width change, UpdateThemeBrushes), because ALL FOUR
    // invalidate an in-flight background build the same way: the layout it is building was
    // shaped for a document/width/zoom/brush that this view has already moved past. A
    // SchedulePrefetch task captures the generation that was current when it was SCHEDULED and
    // only writes its finished TextLayout into _prefetchStaging if that generation still matches
    // when the write happens. Without this, a background task still running when ClearCaches
    // fires (SetTree only empties the staging map at the moment of the swap — it cannot stop a
    // task already in flight, and there is no cancellation) lands its stale-shaped TextLayout
    // under the NEW generation's block index once it finishes — e.g. document B briefly shows a
    // line of document A's text, or a block briefly draws at the OLD zoom's font size right after
    // a zoom change. Interlocked/Volatile, not a plain field, because the write races a
    // background thread against the UI thread's own increment.
    private int _documentGeneration;

    // Per-table row-height cache (block index -> row heights from that table's last draw),
    // handed back into TableGridRenderer.Draw so a table already measured at this width/zoom does
    // not rebuild every cell's TextLayout on every scroll frame — see TableGridRenderer's own doc.
    private readonly Dictionary<int, double[]> _tableRowHeightCache = new();

    // Find-in-document. Matches are (blockIndex, char start, char length) against the SAME
    // concatenated-run text DrawTextBlock builds, so a hit-test range lines up with what is drawn.
    private string? _searchQuery;
    private readonly List<(int BlockIndex, int Start, int Length)> _matches = new();
    private int _currentMatchIndex = -1;

    /// <summary>Total content height in pixels, once a layout pass has run — 0 before SetTree.
    /// In page mode, this is the stacked-sheets height (<see cref="PageModePainter"/>)
    /// instead of the flow list's cumulative block offsets.</summary>
    public double ContentHeight
    {
        get
        {
            if (PageModeActive)
            {
                return _pageModePainter.TotalHeightPx(_pageGeometry!, _pageLayout!.PageCount, _zoomFactor);
            }
            return _offsets.Length > 0 ? _offsets[^1] : 0;
        }
    }

    /// <summary>Current font-size multiplier — 1.0 is the document's own declared sizes.
    /// Clamped to [0.5, 3.0] in 10% steps by <see cref="ZoomIn"/>/<see cref="ZoomOut"/>; settable
    /// directly by <see cref="SetZoom"/> for reading-position restore.</summary>
    public double ZoomFactor => _zoomFactor;

    /// <summary>Raised whenever <see cref="ScrollOffset"/> actually changes value (not on a
    /// no-op set that clamped to the same position) — MainWindow debounces this into the
    /// reading-position save.</summary>
    public event Action? ScrollOffsetChanged;

    /// <summary>True once a document has been loaded via <see cref="SetTree"/> with at least one
    /// block — MainWindow uses this to show/hide the empty-state message.</summary>
    public bool HasDocument => _blocks.Count > 0;

    /// <summary>S9-B3 batch 6: passthrough to the SAME decoded bitmap this view already draws
    /// inline for an Image block's resource id — used by <see cref="ImageClicked"/>'s subscriber
    /// (<c>MainWindow</c>) to build the enlarged view without a second decode.</summary>
    public Bitmap? ResolveImageBitmap(ulong resourceId) => _imageRenderer.ResolveBitmap(resourceId);

    /// <summary>The currently-resolved "auto" text colour — what an undeclared run's colour
    /// draws as right now, following <see cref="Visual.ActualThemeVariant"/> (see
    /// <see cref="UpdateThemeBrushes"/>). Exposed so a headless test can assert actual contrast
    /// values against <see cref="ThemeBackgroundColor"/> without reflection.</summary>
    public Color ThemeForegroundColor => (_foregroundBrush as ISolidColorBrush)?.Color ?? Colors.Black;

    /// <summary>The currently-resolved canvas background colour — see
    /// <see cref="ThemeForegroundColor"/>.</summary>
    public Color ThemeBackgroundColor => _backgroundColor;

    /// <summary>Self-owned scroll position (pixels from the document top), clamped to
    /// [0, ContentHeight - viewport height]. Settable from code — the headless paint-probe drives
    /// this directly, with no pointer and no outer ScrollViewer.</summary>
    public double ScrollOffset
    {
        get => _scrollOffset;
        set
        {
            var maxScroll = Math.Max(0, ContentHeight - Bounds.Height);
            var clamped = Math.Clamp(value, 0, maxScroll);
            if (Math.Abs(clamped - _scrollOffset) < 0.01) { return; }
            _scrollOffset = clamped;
            InvalidateVisual();
            ScrollOffsetChanged?.Invoke();
        }
    }

    public FlowDocumentView()
    {
        ClipToBounds = true;
        Focusable = true;
        _pageModePainter = new PageModePainter(_imageRenderer);
        ActualThemeVariantChanged += (_, _) => UpdateThemeBrushes();
        EnsureTextDecorationsOwnedByUiThread();
        // S8-D2 (D2-e): every picture this view draws — flow mode here, and page mode too, since
        // PageModePainter paints through this SAME control's DrawingContext (RenderCore hands it
        // the identical IPageCanvas this view's own Render built) — is now upscaled/downscaled with
        // bilinear filtering instead of Avalonia's nearest-neighbour default, so a photo scaled to
        // fit the reading column no longer shows visible pixel blocking. PdfExporter's own
        // SkiaPageCanvas path draws through raw SkiaSharp calls, not this control's DrawingContext,
        // so it is unaffected by this attached property — see S8D2's report for why that is out of
        // this contract's scope.
        RenderOptions.SetBitmapInterpolationMode(this, BitmapInterpolationMode.HighQuality);

        // S8-B4 (④): rebuilt every time the menu is about to open, from the CURRENT selection/
        // right-click state — never stale, since a document can gain/lose a selection between two
        // right-clicks without this view knowing to invalidate a pre-built menu.
        var contextMenu = new ContextMenu();
        contextMenu.Opening += (_, _) => RebuildContextMenu(contextMenu);
        ContextMenu = contextMenu;
    }

    private static bool s_textDecorationsWarmed;

    /// <summary>Touches (reads a styled property of) every <see cref="TextDecoration"/> in the
    /// shared static <see cref="TextDecorations.Underline"/>/<see cref="TextDecorations.Strikethrough"/>
    /// collections, once, from whichever thread constructs the FIRST FlowDocumentView — which is
    /// always the UI thread, since Avalonia controls are constructed there. Measured (not
    /// theorised): unlike <see cref="Avalonia.Media.Immutable.ImmutableSolidColorBrush"/>,
    /// <see cref="TextDecoration"/> IS an <see cref="AvaloniaObject"/> and has no immutable
    /// counterpart, and its thread affinity is decided by FIRST TOUCH, not by construction site —
    /// a reflection probe confirmed that reading a styled property off ANY thread with no prior
    /// touch anywhere in the process succeeds and silently binds that object to the CALLING
    /// thread, after which every OTHER thread (including the real UI/render thread) throws
    /// "the calling thread cannot access this object because a different thread owns it" the
    /// first time it tries to read the same property — reproduced with
    /// testdocs/mini/s9-picture-crop.hwp, which crashed reliably on the SECOND `--paint-probe`
    /// scroll frame because <see cref="BuildTextLayout"/> had already been built once on a
    /// background thread (PrewarmVisibleRange/SchedulePrefetch) for a run with an underline
    /// before the real UI/render thread ever got a chance to draw one. Calling this HERE, in the
    /// UI-thread constructor, before any background prewarm/prefetch has a chance to run,
    /// pre-claims ownership for the UI thread for the lifetime of the process — a background
    /// thread merely REFERENCING the (now UI-owned) collection while building a TextLayout does
    /// not itself read any styled property (verified: TextLayout construction never touches
    /// TextDecoration.StrokeThickness — only TextDecoration.Draw, called from the render thread,
    /// does), so this single early read is enough.</summary>
    private static void EnsureTextDecorationsOwnedByUiThread()
    {
        if (s_textDecorationsWarmed) { return; }
        foreach (var decoration in TextDecorations.Underline) { _ = decoration.StrokeThickness; }
        foreach (var decoration in TextDecorations.Strikethrough) { _ = decoration.StrokeThickness; }
        s_textDecorationsWarmed = true;
    }

    /// <summary>Test hook — forces an immediate re-resolve of <see cref="ThemeForegroundColor"/>/
    /// <see cref="ThemeBackgroundColor"/>. The app itself never calls this directly (attach and
    /// <see cref="Visual.ActualThemeVariantChanged"/> already do), but a headless test asserting
    /// theme contrast without a live window's own attach timing needs a way to trigger it on demand.</summary>
    public void RefreshThemeBrushes() => UpdateThemeBrushes();

    /// <summary>Re-resolves <see cref="_foregroundBrush"/>/<see cref="_backgroundColor"/>
    /// from the FluentTheme resource dictionary for whatever <see cref="Visual.ActualThemeVariant"/>
    /// this view currently has — called once the view is attached (resources are not resolvable
    /// before that, since resolution walks UP the visual tree to the Window/Application) and again
    /// every time the OS or app theme flips. Every cached TextLayout carries the OLD brush baked
    /// into its run overrides (ImmutableSolidColorBrush has no Dispatcher affinity, which is
    /// exactly why it cannot be swapped in place), so a theme change must drop those caches too, not
    /// just repaint.</summary>
    private void UpdateThemeBrushes()
    {
        // The explicit ThemeVariant overload is required here, not TryFindResource(key, out value)
        // — measured empirically: the single-arg overload resolved BOTH keys to their Light values
        // even inside a Window whose own RequestedThemeVariant was Dark (and whose already-templated
        // controls, e.g. a plain TextBlock's Foreground, correctly showed white-on-black), while
        // passing this.ActualThemeVariant explicitly tracks the SAME variant those templates use.
        var variant = ActualThemeVariant;
        _foregroundBrush = this.TryFindResource(ForegroundResourceKey, variant, out var fg) && fg is ISolidColorBrush fgSolid
            ? new ImmutableSolidColorBrush(fgSolid.Color)
            : new ImmutableSolidColorBrush(Colors.Black);
        _backgroundColor = this.TryFindResource(BackgroundResourceKey, variant, out var bg) && bg is ISolidColorBrush bgSolid
            ? bgSolid.Color
            : Colors.White;
        // S8-D2 (D2-a): SystemAccentColor is a plain Color resource (not a brush) in FluentTheme,
        // already defined for both light and dark — tinted translucent so it sits BEHIND glyphs
        // (painted before DrawTextLayout, see DrawSelectionHighlight) rather than replacing them.
        _selectionHighlightColor = this.TryFindResource(SelectionAccentResourceKey, variant, out var accent) && accent is Color accentColor
            ? Color.FromArgb(0x60, accentColor.R, accentColor.G, accentColor.B)
            : Color.FromArgb(0x60, 0x3F, 0x8C, 0xE0);
        // S8-D2 (D2-b): App.axaml's own Light/Dark ThemeDictionaries — see the field doc above for
        // why this app defines its own resource rather than reusing a FluentTheme one.
        _findMatchHighlightColor = this.TryFindResource(FindMatchResourceKey, variant, out var findColor) && findColor is Color findMatchColor
            ? Color.FromArgb(0x90, findMatchColor.R, findMatchColor.G, findMatchColor.B)
            : Color.FromArgb(0x90, 0xFF, 0xEB, 0x3B);
        _findCurrentMatchHighlightColor = this.TryFindResource(FindCurrentMatchResourceKey, variant, out var findCurrentColor) && findCurrentColor is Color findCurrentMatchColor
            ? Color.FromArgb(0xB0, findCurrentMatchColor.R, findCurrentMatchColor.G, findCurrentMatchColor.B)
            : Color.FromArgb(0xB0, 0xFF, 0x98, 0x00);
        ClearCaches();
        InvalidateVisual();
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        UpdateThemeBrushes();
    }

    /// <summary>True only when the CURRENT document declared its own page geometry
    /// (wire::Document.documentPaper, or a section's own) — a markdown/text document, or an office
    /// document that never stated a page size, has no PageGeometry at all, so <see cref="PageMode"/>
    /// silently has no effect for it (mirrors PageViewOptions.swift's own "no page geometry, no
    /// page toggle" rule) rather than drawing a page shape the document never declared.</summary>
    public bool HasPageGeometry => _pageGeometry is not null;

    /// <summary>Page-mode geometry/count in PIXELS at zoom=1.0, exposed read-only so
    /// <see cref="Printing.PdfExporter"/> can size an offscreen render per page without
    /// duplicating <see cref="Paging.PageModePainter"/>'s own point-to-pixel conversions — the
    /// same painter this view already drives for on-screen page mode also drives PDF export, one
    /// traversal for both outputs. Null (or 0) when <see cref="HasPageGeometry"/> is false, or
    /// before <see cref="EnsurePageLayout"/> has run (call Measure once first — MeasureOverride
    /// runs it for page-mode documents regardless of the size passed in).</summary>
    public double? ExportPageWidthPx => _pageGeometry is null ? null : _pageModePainter.PageWidthPx(_pageGeometry, 1.0);

    /// <summary>See <see cref="ExportPageWidthPx"/> — the page's height counterpart.</summary>
    public double? ExportPageHeightPx => _pageGeometry is null ? null : _pageModePainter.PageHeightPx(_pageGeometry, 1.0);

    /// <summary>See <see cref="ExportPageWidthPx"/> — how many pages the current document paginates
    /// to. 0 before EnsurePageLayout has run or for a document with no page geometry.</summary>
    public int ExportPageCount => _pageLayout?.PageCount ?? 0;

    /// <summary>See <see cref="ExportPageWidthPx"/> — the scroll offset (pixels, zoom=1.0) that
    /// puts <paramref name="pageIndex"/> at the top of the viewport, the same value the interactive
    /// page-mode scroll position uses.</summary>
    public double ExportPageTopPx(int pageIndex) => _pageGeometry is null ? 0 : _pageModePainter.PageTopPx(_pageGeometry, pageIndex, 1.0);

    /// <summary>Flow (default) vs. page mode — Ctrl/Cmd+Shift+P in MainWindow, and the View
    /// menu. Setting this to true for a document with no <see cref="HasPageGeometry"/> is a no-op:
    /// the getter still reports the requested value so a toggle button can show its own state, but
    /// <see cref="Render"/>/<see cref="ContentHeight"/> only ever draw pages when both are true.</summary>
    public bool PageMode
    {
        get => _pageMode;
        set
        {
            if (_pageMode == value) { return; }

            // Capture the reading anchor — a BLOCK (and how far into it), not a pixel offset —
            // in the OUTGOING mode before anything is rebuilt, mirroring the macOS reader's
            // toggle contract (INVARIANTS.md, PageViewOptionsTests
            // .testTheReadingPositionSurvivesAToggleFromDeepInTheDocument). A pixel offset means
            // nothing across modes: flow's _scrollOffset is a height-of-blocks-above sum, while
            // page mode's is stacked-sheet pixels: page count/height, so a naive carry-over lands
            // on an unrelated block. Only meaningful when there is a document and (for the
            // page-mode side) it actually has page geometry — see HasPageGeometry's doc.
            var anchorBlock = 0;
            var anchorFraction = 0.0;
            var haveAnchor = _blocks.Count > 0;
            if (haveAnchor && _pageMode)
            {
                // Leaving page mode: the anchor is the first block placed on the page
                // currently at the top of the viewport.
                if (PageModeActive)
                {
                    var pageIndex = _pageModePainter.PageIndexAt(_pageGeometry!, _scrollOffset, _zoomFactor);
                    anchorBlock = FirstBlockOnPage(pageIndex);
                }
                else
                {
                    haveAnchor = false; // page mode was requested but never had geometry to place blocks on
                }
            }
            else if (haveAnchor)
            {
                // Leaving flow mode: same math GetCurrentPositionForSave/SetZoom already use.
                anchorBlock = Math.Clamp(LowerBound(_offsets, _scrollOffset), 0, _blocks.Count - 1);
                var height = anchorBlock < _blockHeights.Length ? _blockHeights[anchorBlock] : 0;
                anchorFraction = height > 0 ? Math.Clamp((_scrollOffset - _offsets[anchorBlock]) / height, 0, 1) : 0;
            }

            _pageMode = value;
            _pageLayoutDirty = true;
            _scrollOffset = 0;

            if (haveAnchor)
            {
                if (_pageMode)
                {
                    // Entering page mode: the layout must exist before a page index means
                    // anything — EnsurePageLayout is cheap here (a document's PageGeometry never
                    // changes with viewport width, only Master Page Furniture/table-split toggles).
                    EnsurePageLayout();
                    if (PageModeActive)
                    {
                        var pageIndex = PageForBlock(anchorBlock);
                        ScrollOffset = _pageModePainter.PageTopPx(_pageGeometry!, pageIndex, _zoomFactor);
                    }
                }
                else
                {
                    // RestorePosition needs estimated block heights for the new (flow) width —
                    // it calls EnsureEstimates itself, exactly like SetZoom's re-anchor does.
                    RestorePosition(anchorBlock, anchorFraction);
                }
            }

            InvalidateMeasure();
            InvalidateVisual();
        }
    }

    /// <summary>The block whose placement starts nearest the top of <paramref name="pageIndex"/> —
    /// the page-mode half of the toggle-position anchor (see <see cref="PageMode"/>). Must search
    /// BOTH <see cref="PageLayoutResult.Placements"/> (Rule/Image/Table blocks) AND
    /// <see cref="PageLayoutResult.Lines"/> (Text blocks — a paragraph contributes one
    /// <see cref="PagedLine"/> per wrapped line, not a <see cref="PagedBlock"/>): an ordinary
    /// paragraph-only document has an EMPTY Placements list, so reading Placements alone would
    /// always fall back to block 0 and this toggle would look fixed on a table/image-only fixture
    /// while staying broken for the common case. A block can appear more than once on the searched
    /// page (a paragraph or table split across a page break), so this picks the entry with the
    /// smallest LocalTopPoints on that page — the two agree for ordinary flow but only the
    /// top-position one is correct once a block is known to span pages.</summary>
    private int FirstBlockOnPage(int pageIndex)
    {
        if (_pageLayout is null) { return 0; }
        var best = -1;
        var bestTop = double.MaxValue;
        foreach (var placement in _pageLayout.Placements)
        {
            if (placement.PageIndex != pageIndex) { continue; }
            if (best == -1 || placement.LocalTopPoints < bestTop)
            {
                best = placement.BlockIndex;
                bestTop = placement.LocalTopPoints;
            }
        }
        foreach (var line in _pageLayout.Lines)
        {
            if (line.PageIndex != pageIndex) { continue; }
            if (best == -1 || line.LocalTopPoints < bestTop)
            {
                best = line.BlockIndex;
                bestTop = line.LocalTopPoints;
            }
        }
        return best == -1 ? 0 : best;
    }

    /// <summary>The page a block was placed on — the flow-to-page half of the toggle-position
    /// anchor. Searches both Placements and Lines for the same reason <see cref="FirstBlockOnPage"/>
    /// does. When a block spans a page break (a long table, S9-B split-tables, or a paragraph whose
    /// wrapped lines straddle a page boundary), returns the EARLIEST page it appears on, so leaving
    /// flow mid-block lands on the page that shows its start rather than skipping ahead to where it
    /// finishes.</summary>
    private int PageForBlock(int blockIndex)
    {
        if (_pageLayout is null) { return 0; }
        var best = -1;
        foreach (var placement in _pageLayout.Placements)
        {
            if (placement.BlockIndex != blockIndex) { continue; }
            if (best == -1 || placement.PageIndex < best) { best = placement.PageIndex; }
        }
        foreach (var line in _pageLayout.Lines)
        {
            if (line.BlockIndex != blockIndex) { continue; }
            if (best == -1 || line.PageIndex < best) { best = line.PageIndex; }
        }
        return best == -1 ? 0 : best;
    }

    private bool PageModeActive => _pageMode && _pageGeometry is not null && _pageLayout is not null;

    /// <summary>View > Master Page Furniture — see <see cref="_masterPageFurniture"/>'s own doc.
    /// Setting this marks the page layout dirty so the next <see cref="EnsurePageLayout"/> re-asks
    /// the engine for the header/footer band with the new value, exactly like <see cref="PageMode"/>
    /// itself does for its own toggle.</summary>
    public bool MasterPageFurniture
    {
        get => _masterPageFurniture;
        set
        {
            if (_masterPageFurniture == value) { return; }
            _masterPageFurniture = value;
            _pageLayoutDirty = true;
            InvalidateMeasure();
            InvalidateVisual();
        }
    }

    /// <summary>View > Split Tables Across Pages — see <see cref="_splitTablesAcrossPages"/>'s own
    /// doc.</summary>
    public bool SplitTablesAcrossPages
    {
        get => _splitTablesAcrossPages;
        set
        {
            if (_splitTablesAcrossPages == value) { return; }
            _splitTablesAcrossPages = value;
            _pageLayoutDirty = true;
            InvalidateMeasure();
            InvalidateVisual();
        }
    }

    /// <summary>View > Line Numbers — flow mode only (see <see cref="LineNumberModel"/>'s own doc
    /// for why page mode is out of this batch's scope; the menu item disables itself while
    /// <see cref="PageMode"/> is on, same disable rule <c>MainWindow</c> already applies to Master
    /// Page Furniture / Split Tables while there is no page geometry).</summary>
    public bool ShowLineNumbers
    {
        get => _showLineNumbers;
        set
        {
            if (_showLineNumbers == value) { return; }
            _showLineNumbers = value;
            InvalidateVisual();
        }
    }

    /// <summary>1-based line-number upper bound for a "Go to Line…" dialog — 0 when there is
    /// nothing to number (no document, or every block is unnumbered).</summary>
    public int LineNumberCount => LineNumberModel.NumberedCount(_blocks);

    /// <summary>Scrolls to 1-based line number <paramref name="lineNumber"/> (as numbered by
    /// <see cref="LineNumberModel"/>) — the flow-mode half of "Go to Line…". Returns false (a
    /// no-op) for an out-of-range number or while in page mode, mirroring
    /// <see cref="ScrollToNodeId"/>'s own contract.</summary>
    public bool ScrollToLineNumber(int lineNumber)
    {
        if (_pageMode) { return false; }
        var blockIndex = LineNumberModel.BlockIndexForLineNumber(_blocks, lineNumber);
        if (blockIndex is null) { return false; }
        RestorePosition(blockIndex.Value, 0.0);
        return true;
    }

    public void SetTree(RenderTree? tree)
    {
        _tree = tree;
        _blocks = tree is null ? new List<FlowBlock>() : FlowDocumentBuilder.Build(tree);
        _headingAnchorResolver = tree is null ? HeadingAnchorResolver.Empty : HeadingAnchorResolver.Build(CollectHeadingsInDocumentOrder(tree));
        _imageRenderer.Reset(tree); // drop cached bitmaps — resource ids are only unique WITHIN one tree.
                                     // Reset() also clears any handle bound by a previous SetHandle call, so
                                     // a caller MUST call SetHandle again (or not at all) for this tree.
        _layoutWidth = -1; // force EnsureEstimates to rebuild on next measure/render
        _scrollOffset = 0;
        _officeHandle = null;
        _pageGeometry = tree is null ? null : PageGeometry.FromDocument(tree);
        _pageMarkers = tree is null ? default : BlockPageMarkers.Compute(tree);
        _pageLayout = null;
        _pageLayoutDirty = true;
        _pageModePainter.InvalidateTextCache(); // block indices from the OLD tree must never draw against the new one
        ClearCaches();
        ClearSearch();
        InvalidateMeasure();
        InvalidateVisual();
    }

    /// <summary>Rebuilds the page layout (block placement + band via the S5C1-02 engine
    /// call, falling back to host arithmetic) if the tree, handle, or header/footer toggles have
    /// changed since the last build. Cheap to call every Render — it no-ops unless
    /// <see cref="_pageLayoutDirty"/> is set.</summary>
    private void EnsurePageLayout()
    {
        if (_pageGeometry is null) { _pageLayout = null; return; }
        if (!_pageLayoutDirty && _pageLayout is not null) { return; }
        var handle = _officeHandle?.RawHandle ?? IntPtr.Zero;
        // The interactive view settles tables the same way the headless `--sheets` CLI does
        // (PageLayout.BuildWithTableSettle) — headersOn/footersOn/splitTablesDefault come from the
        // View menu's Master Page Furniture / Split Tables Across Pages toggles (S9-B3 batch 2),
        // both true by default, mirroring PageViewOptions.default (Swift).
        (_pageLayout, _, _, _) = PageLayout.BuildWithTableSettle(_blocks, _pageMarkers, _pageGeometry,
            handle, headersOn: _masterPageFurniture, footersOn: _masterPageFurniture,
            splitTablesDefault: _splitTablesAcrossPages, imageRenderer: _imageRenderer);
        _pageLayoutDirty = false;
    }

    /// <summary>Binds the office parse behind the tree SetTree just accepted, so a
    /// reference-only picture (BytesBase64 null, sourceKey present) can be decoded lazily instead
    /// of staying a placeholder forever. Call AFTER SetTree, for the SAME document — SetTree's own
    /// ImageBlockRenderer.Reset already clears any earlier binding, so calling this for a document
    /// that has since been replaced would bind a handle the current tree's resource ids do not
    /// belong to; the caller (not this view) owns handle disposal and must not dispose it before
    /// this document is itself replaced or this view is discarded.</summary>
    public void SetHandle(OfficeDocumentHandle? handle)
    {
        _imageRenderer.SetHandle(handle);
        // The S5C1-02 band query needs this SAME handle (fastdoc_office_band_sides takes
        // the open parse, not raw bytes) — stored here so EnsurePageLayout can pass it without
        // FlowDocumentView owning a second copy of the FFI plumbing ImageBlockRenderer already has.
        _officeHandle = handle;
        _pageLayoutDirty = true;
        InvalidateMeasure();
        InvalidateVisual();
    }

    /// <summary>docx/odt counterpart of <see cref="SetHandle"/>: opens the document's own file as
    /// a zip archive so a reference-only picture in a format with no live-parse handle (docx/odt —
    /// fastdoc_office_image_base64 answers nil for them) can still be found, by the same sourceKey,
    /// from the archive entry it names. Call AFTER SetTree, for the SAME document, same ordering
    /// rule as SetHandle. `extension` decides whether `path` is even worth opening as a zip (hwp is
    /// CFB binary, not a zip, and hwpx's own pictures ship through SetHandle's rhwp path instead).</summary>
    public void SetZipSource(string? path, string? extension)
    {
        _imageRenderer.SetZipSource(path, extension);
        InvalidateVisual();
    }

    /// <summary>How many pictures this view has decoded (eagerly, or lazily via SetHandle) since
    /// the last SetTree — pass-through for a caller (the --paint-probe entry point) that wants to
    /// confirm the lazy fetch actually ran, without reaching into the private image renderer.</summary>
    public int ImageDecodeSuccessCount => _imageRenderer.DecodeSuccessCount;

    /// <summary>How many picture resolutions have fallen back to the placeholder since the last
    /// SetTree — an unknown resource id, a resource with neither eager bytes nor a fetchable
    /// sourceKey, or bytes that failed to decode as an image.</summary>
    public int ImageDecodeFailureCount => _imageRenderer.DecodeFailureCount;

    // ---- zoom -------------------------------------------------------------------------------------

    public void ZoomIn() => SetZoom(_zoomFactor + ZoomStep);

    public void ZoomOut() => SetZoom(_zoomFactor - ZoomStep);

    public void ZoomReset() => SetZoom(1.0);

    /// <summary>Sets the font-size multiplier directly (clamped to [0.5, 3.0]) — used by ZoomIn/
    /// ZoomOut/ZoomReset and by reading-position restore, which needs to land on a SAVED factor
    /// rather than step to it. Re-anchors the scroll so the block that was at the top of the
    /// viewport before the resize stays there after it (CLAUDE.md's zoom contract: font size only,
    /// re-paginate, keep your place) — otherwise every zoom change would silently jump the reader
    /// back to the top of the document.</summary>
    public void SetZoom(double factor)
    {
        var clamped = Math.Round(Math.Clamp(factor, MinZoom, MaxZoom), 3);
        if (Math.Abs(clamped - _zoomFactor) < 0.0001) { return; }

        var width = _layoutWidth > 0 ? _layoutWidth : (Bounds.Width > 0 ? Bounds.Width : 800);
        var anchorBlock = _blocks.Count == 0 ? 0 : LowerBound(_offsets, _scrollOffset);
        var anchorFraction = 0.0;
        if (_blocks.Count > 0 && anchorBlock < _blockHeights.Length && _blockHeights[anchorBlock] > 0)
        {
            anchorFraction = Math.Clamp((_scrollOffset - _offsets[anchorBlock]) / _blockHeights[anchorBlock], 0, 1);
        }

        _zoomFactor = clamped;
        _layoutWidth = -1; // font sizes changed -> every estimate/measurement is stale
        ClearCaches();
        EnsureEstimates(width);
        RestorePosition(anchorBlock, anchorFraction);
        InvalidateMeasure();
        InvalidateVisual();
    }

    /// <summary>Scrolls to block <paramref name="blockIndex"/>, offset <paramref name="fraction"/>
    /// (0..1) into that block's own height — the reading-position restore contract, and also
    /// how SetZoom re-anchors after a re-paginate. Safe to call with an out-of-range index (a saved
    /// position from a document that has since gotten shorter): clamps into range.</summary>
    public void RestorePosition(int blockIndex, double fraction)
    {
        if (_blocks.Count == 0) { return; }
        var width = _layoutWidth > 0 ? _layoutWidth : (Bounds.Width > 0 ? Bounds.Width : 800);
        EnsureEstimates(width);
        var index = Math.Clamp(blockIndex, 0, _blocks.Count - 1);
        var height = index < _blockHeights.Length ? _blockHeights[index] : 0;
        ScrollOffset = _offsets[index] + Math.Clamp(fraction, 0, 1) * height;
    }

    /// <summary>S8-B4 (①): scrolls so the block carrying <paramref name="nodeId"/> has its TOP at
    /// the viewport top — used by a table-of-contents or comment click, and by an internal link's
    /// anchor resolution. Reuses <see cref="RestorePosition"/> (fraction 0) rather than adding a
    /// second scroll path: RestorePosition already IS "this block's top at the viewport top", the
    /// exact contract this method needs, and it is the same mechanism the reading-position
    /// restore and zoom re-anchor already trust.
    ///
    /// Flow mode only: page mode keeps its OWN separate per-page TextLayout cache
    /// (<see cref="PageModePainter"/>) with materially different block placement (a paragraph can
    /// split across a page boundary), so a node's flow-mode block index does not name a
    /// correspondingly meaningful position there — see the S8-B4 report's "페이지 모드" section.
    /// Returns false (a no-op) rather than throwing when <paramref name="nodeId"/> names no block
    /// in the CURRENT tree (a stale id from a document that has since been replaced or edited) or
    /// while in page mode.</summary>
    public bool ScrollToNodeId(ulong nodeId)
    {
        if (_pageMode) { return false; }
        for (var i = 0; i < _blocks.Count; i++)
        {
            if (BlockOrItsCellsCarryNodeId(_blocks[i], nodeId))
            {
                RestorePosition(i, 0.0);
                return true;
            }
        }
        return false;
    }

    /// <summary>S9-A: a TOC/comment NodeId can name a node FlowDocumentBuilder built INSIDE a
    /// table cell (a title styled inside a title-box table — a common Korean report layout HWP
    /// documents use for chapter headers) rather than a top-level block. `BuildTable` walks cell
    /// content into `TableGridCell.Content`, a list `_blocks`/`_offsets` never flattens, so a plain
    /// `_blocks[i].NodeId == nodeId` scan (this method's ORIGINAL S8-B4 body) silently missed every
    /// such heading — confirmed on a real corpus document (`1790387_prep_final_report.hwpx`) where
    /// EVERY one of its 13 chapter headings lives inside a cell and none matched.
    /// `TableOfContentsModel.Walk` does not skip table/tableRow/tableCell (only footnote/header/
    /// footer/masterPage/anchoredObject/formControl/textRun/lineBreak, S8-B4's own list), so it
    /// already finds and reports these NodeIds; only the scroll-side lookup was too narrow.
    /// There is no independent scroll offset for a cell's own content (only top-level blocks have
    /// one in `_offsets`), so a nested match resolves to the ENCLOSING top-level block (here, the
    /// whole table) — the closest position this reader can name, same as scrolling to a table that
    /// contains the target paragraph would already do for any other in-cell content.
    /// Recurses through nested tables (a cell's content can itself contain a `Kind == Table`
    /// block, up to `MaxTableNestingDepth`), matching `FlowDocumentBuilder.BuildTable`'s own
    /// recursion.</summary>
    private static bool BlockOrItsCellsCarryNodeId(FlowBlock block, ulong nodeId)
    {
        if (block.NodeId == nodeId) { return true; }
        if (block.Kind != FlowBlockKind.Table || block.Table is null) { return false; }
        foreach (var row in block.Table.Rows)
        {
            foreach (var cell in row.Cells)
            {
                foreach (var inner in cell.Content)
                {
                    if (BlockOrItsCellsCarryNodeId(inner, nodeId)) { return true; }
                }
            }
        }
        return false;
    }

    /// <summary>The block index + in-block fraction the CURRENT scroll position sits at — the other
    /// half of the reading-position contract RestorePosition reads back. MainWindow persists this
    /// (with ZoomFactor) on a 0.5s scroll-stop debounce and on document swap/window close.</summary>
    public (int BlockIndex, double Fraction) GetCurrentPositionForSave()
    {
        if (_blocks.Count == 0) { return (0, 0); }
        var index = LowerBound(_offsets, _scrollOffset);
        index = Math.Clamp(index, 0, _blocks.Count - 1);
        var height = index < _blockHeights.Length ? _blockHeights[index] : 0;
        var fraction = height > 0 ? Math.Clamp((_scrollOffset - _offsets[index]) / height, 0, 1) : 0;
        return (index, fraction);
    }

    // ---- find in document ---------------------------------------------------------------------

    /// <summary>Match count for the last <see cref="SetSearchQuery"/> — 0 when there is no query
    /// or no hits.</summary>
    public int MatchCount => _matches.Count;

    /// <summary>1-based index of the current match for display ("n/m"), 0 when there is none.</summary>
    public int CurrentMatchNumber => _currentMatchIndex < 0 ? 0 : _currentMatchIndex + 1;

    /// <summary>S8-D2 (D2-b): every find-match's own (block, start, length) plus whether it is the
    /// CURRENT one — the exact data <see cref="DrawFindHighlights"/> paints from, exposed so a
    /// test can assert highlight ranges and current-match distinction without a live
    /// DrawingContext. Ordered the same as the underlying search walk (document order).</summary>
    public IReadOnlyList<(int BlockIndex, int Start, int Length, bool IsCurrent)> FindMatchRanges
    {
        get
        {
            var result = new List<(int, int, int, bool)>(_matches.Count);
            for (var i = 0; i < _matches.Count; i++)
            {
                var (blockIndex, start, length) = _matches[i];
                result.Add((blockIndex, start, length, i == _currentMatchIndex));
            }
            return result;
        }
    }

    /// <summary>Sets (or replaces) the active search query, case-insensitive, over every text
    /// block's concatenated run text. Jumps to and highlights the first match, if any.</summary>
    public void SetSearchQuery(string? query)
    {
        _searchQuery = string.IsNullOrEmpty(query) ? null : query;
        RebuildMatches();
        _currentMatchIndex = _matches.Count > 0 ? 0 : -1;
        if (_currentMatchIndex >= 0) { ScrollToMatch(_currentMatchIndex); }
        InvalidateVisual();
    }

    public void ClearSearch()
    {
        _searchQuery = null;
        _matches.Clear();
        _currentMatchIndex = -1;
        InvalidateVisual();
    }

    public void FindNext()
    {
        if (_matches.Count == 0) { return; }
        _currentMatchIndex = (_currentMatchIndex + 1) % _matches.Count;
        ScrollToMatch(_currentMatchIndex);
        InvalidateVisual();
    }

    public void FindPrevious()
    {
        if (_matches.Count == 0) { return; }
        _currentMatchIndex = (_currentMatchIndex - 1 + _matches.Count) % _matches.Count;
        ScrollToMatch(_currentMatchIndex);
        InvalidateVisual();
    }

    private void RebuildMatches()
    {
        _matches.Clear();
        if (string.IsNullOrEmpty(_searchQuery)) { return; }
        for (var i = 0; i < _blocks.Count; i++)
        {
            var block = _blocks[i];
            if (block.Kind != FlowBlockKind.Text || block.Runs.Count == 0) { continue; }
            var text = string.Concat(block.Runs.ConvertAll(r => r.Text));
            if (text.Length == 0) { continue; }
            var searchStart = 0;
            while (searchStart <= text.Length)
            {
                var found = text.IndexOf(_searchQuery!, searchStart, StringComparison.OrdinalIgnoreCase);
                if (found < 0) { break; }
                _matches.Add((i, found, _searchQuery!.Length));
                searchStart = found + Math.Max(1, _searchQuery!.Length);
            }
        }
    }

    private void ScrollToMatch(int matchIndex)
    {
        if (matchIndex < 0 || matchIndex >= _matches.Count) { return; }
        var blockIndex = _matches[matchIndex].BlockIndex;
        var width = _layoutWidth > 0 ? _layoutWidth : (Bounds.Width > 0 ? Bounds.Width : 800);
        EnsureEstimates(width);
        if (blockIndex >= _offsets.Length) { return; }
        // A small margin above the match keeps it from sitting flush against the viewport edge.
        ScrollOffset = Math.Max(0, _offsets[blockIndex] - 40);
    }

    // ---- caches ---------------------------------------------------------------------------------

    private void ClearCaches()
    {
        // Bumped FIRST, before anything is cleared: this is the layout generation's single
        // invalidation point (SetTree, SetZoom, a width change, and a theme change all route
        // through here), and every SchedulePrefetch task compares against it before writing into
        // _prefetchStaging (see the field's own doc for why the clear below is not enough by
        // itself — a task still in flight when this runs finds an empty map to write into, not no
        // map at all, and would otherwise repopulate it with a stale-shaped TextLayout).
        System.Threading.Interlocked.Increment(ref _documentGeneration);
        _textLayoutCache.Clear();
        _textLayoutLru.Clear();
        _textLayoutLruNodes.Clear();
        _tableRowHeightCache.Clear();
        // Background builds already in flight are stale the instant width/zoom/document changes
        // (they were shaped for the old width/zoom/tree) — drop the staging map so a task that
        // already finished is discarded rather than corrupting the fresh cache. In-flight tasks
        // still finish (there is no cancellation); the generation check above is what stops a
        // LATE one from writing into this now-fresh map after the clear.
        _prefetchStaging.Clear();
        _prefetchInFlight.Clear();
    }

    private TextLayout GetOrBuildTextLayout(int blockIndex, Func<TextLayout> build)
    {
        if (_textLayoutCache.TryGetValue(blockIndex, out var cached))
        {
            TouchLru(blockIndex);
            return cached;
        }
        if (_prefetchStaging.TryRemove(blockIndex, out var staged))
        {
            InsertIntoCache(blockIndex, staged);
            return staged;
        }
        var layout = build();
        InsertIntoCache(blockIndex, layout);
        return layout;
    }

    private void InsertIntoCache(int blockIndex, TextLayout layout)
    {
        _textLayoutCache[blockIndex] = layout;
        var node = _textLayoutLru.AddFirst(blockIndex);
        _textLayoutLruNodes[blockIndex] = node;
        if (_textLayoutCache.Count > TextLayoutCacheCapacity)
        {
            var lru = _textLayoutLru.Last!;
            _textLayoutLru.RemoveLast();
            _textLayoutLruNodes.Remove(lru.Value);
            _textLayoutCache.Remove(lru.Value);
        }
    }

    private void TouchLru(int blockIndex)
    {
        if (!_textLayoutLruNodes.TryGetValue(blockIndex, out var node)) { return; }
        _textLayoutLru.Remove(node);
        var fresh = _textLayoutLru.AddFirst(blockIndex);
        _textLayoutLruNodes[blockIndex] = fresh;
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        var width = double.IsInfinity(availableSize.Width) ? 800 : availableSize.Width;
        if (_pageMode) { EnsurePageLayout(); }
        else { EnsureEstimates(width); }
        var height = double.IsInfinity(availableSize.Height) ? 600 : availableSize.Height;
        return new Size(width, height);
    }

    protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
    {
        base.OnPointerWheelChanged(e);
        ScrollByPixels(-e.Delta.Y * 48);
        e.Handled = true;
    }

    /// <summary>S8-D2 (D2-a): left-button press starts (single click), extends-by-word (double
    /// click, <see cref="PointerPressedEventArgs.ClickCount"/> == 2) or extends-by-block (triple
    /// click, ClickCount &gt;= 3) the selection, then captures the pointer so
    /// <see cref="OnPointerMoved"/> keeps receiving events even once the cursor leaves this
    /// control's bounds (needed for the edge auto-scroll case below). A point that misses every
    /// text block (page mode, an empty document, or a click on the letterboxed gutter) leaves the
    /// existing selection untouched rather than clearing it — only Escape and a fresh click that
    /// DOES land on text do that.</summary>
    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        var point = e.GetCurrentPoint(this);

        if (point.Properties.IsRightButtonPressed)
        {
            // S8-B4 (④): captured now, at press time, because RebuildContextMenu runs later (when
            // the menu actually opens) with no pointer position of its own to hit-test against.
            _lastRightClickLink = LinkAtPoint(point.Position);
            // S9-B3 batch 6 (#46): same "capture at press" reasoning, for whether the right-click
            // landed on a code block — see RebuildContextMenu's own doc for what this feeds.
            _lastRightClickCodeBlockText = CodeBlockTextAt(point.Position);
            return;
        }

        if (!point.Properties.IsLeftButtonPressed) { return; }

        // S9-B3 batch 5 (#44, mirrors ReaderTextView.swift's left-gutter click): a click landing
        // in the LEFT MARGIN (the same reserved band DrawLineNumberGutter paints into, whether or
        // not Line Numbers is actually on) copies the WHOLE block at that y to the clipboard,
        // instead of starting a text selection — there is no text run under the pointer there for
        // HitTestPosition to hit anyway. Flow mode only, same restriction HitTestPosition itself
        // already has for page mode.
        if (!_pageMode && point.Position.X < LeftMargin)
        {
            CopyLineAtGutterY(point.Position.Y);
            e.Handled = true;
            return;
        }

        // S9-B3 batch 5 (#43, mirrors ReaderTextView.swift:798-800): Ctrl/Cmd-click on an EXISTING,
        // non-empty selection opens it as a link/path — resolved and acted on RIGHT HERE (not
        // deferred to release, unlike #42's link click) because acting on press leaves the
        // selection itself completely untouched; falling through to the ordinary press handling
        // below would immediately call _selection.Begin and destroy the very selection this action
        // is about opening. A disclosed simplification: a Ctrl-drag that HAPPENS to start on a
        // selection is treated the same as a plain Ctrl-click (no "did it move" check like #42's
        // link click has) — acceptable since a reader deliberately holding Ctrl while a selection
        // already exists is not a gesture this reader uses to start a fresh drag-select.
        var isAccelClick = e.KeyModifiers.HasFlag(KeyModifiers.Control) || e.KeyModifiers.HasFlag(KeyModifiers.Meta);
        if (isAccelClick && !_selection.IsEmpty)
        {
            var target = SelectionOpenTarget.Resolve(_selection.SelectedText(_blocks));
            if (target is not null)
            {
                ExternalLinkLauncher.Open(target);
                e.Handled = true;
                return;
            }
        }

        // S9-B3 batch 6 (#45, mirrors DiagramZoomWindow.swift's click-to-enlarge on macOS): a click
        // landing on an IMAGE block (not text — HitTestPosition below only ever resolves against a
        // text block's own TextLayout) fires ImageClicked with its resource id, and does not begin
        // a text selection. Acted on at press, same as the two branches just above, for the same
        // reason (a real drag-to-select gesture never starts on a non-text block anyway).
        if (!_pageMode && ImageClicked is not null)
        {
            var imageBlockIndex = NonTextImageBlockAt(point.Position);
            if (imageBlockIndex is { } idx && _blocks[idx].ImageResourceId is { } resourceId)
            {
                ImageClicked.Invoke(resourceId);
                e.Handled = true;
                return;
            }
        }

        // S8-B4 (D2-c): remembered so OnPointerReleased can tell "this was a click on a link" (no
        // movement in between) from "this was a drag that happens to have started on a link"
        // (which must keep selecting, per the contract, not navigate).
        _pointerDownPoint = point.Position;
        _pointerDownLink = LinkAtPoint(point.Position);

        var position = HitTestPosition(point.Position);
        if (position is null) { return; }

        Focus();
        if (e.ClickCount >= 3) { SelectWholeBlock(position.Value.BlockIndex); }
        else if (e.ClickCount == 2) { SelectWord(position.Value); }
        else { _selection.Begin(position.Value); }

        _isSelecting = true;
        e.Pointer.Capture(this);
        InvalidateVisual();
        e.Handled = true;
    }

    /// <summary>Extends the selection's FOCUS end to wherever the pointer is now — only while
    /// <see cref="_isSelecting"/> (a left-button drag started by <see cref="OnPointerPressed"/>),
    /// so an ordinary hover never touches the selection. Also drives the edge auto-scroll: a drag
    /// held near the top/bottom of the viewport nudges <see cref="ScrollOffset"/> by a fixed step
    /// every time the pointer moves (see <see cref="MaybeAutoScroll"/>'s own doc for why this is
    /// move-triggered rather than a continuously-ticking timer).</summary>
    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        var position = e.GetCurrentPoint(this).Position;

        if (!_isSelecting)
        {
            // S8-B4 (D2-c): hover-only cursor feedback — a live drag keeps whatever cursor it
            // already has rather than flickering to a Hand mid-selection.
            Cursor = LinkAtPoint(position) is not null ? new Cursor(StandardCursorType.Hand) : Cursor.Default;
            return;
        }

        MaybeAutoScroll(position);
        var hit = HitTestPosition(position);
        if (hit is not null)
        {
            _selection.ExtendTo(hit.Value);
            InvalidateVisual();
        }
        e.Handled = true;
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);

        // S8-B4 (D2-c): a link click navigates ONLY on press+release with no movement — a drag
        // that started on a link has already been extending the selection (OnPointerMoved above),
        // and must keep doing exactly that, per the contract.
        if (_pointerDownLink is { } link && _pointerDownPoint is { } downPoint)
        {
            var released = e.GetCurrentPoint(this).Position;
            var moved = Math.Abs(released.X - downPoint.X) > LinkClickMovementTolerancePx
                || Math.Abs(released.Y - downPoint.Y) > LinkClickMovementTolerancePx;
            if (!moved) { NavigateLink(link); }
        }
        _pointerDownPoint = null;
        _pointerDownLink = null;

        if (!_isSelecting) { return; }
        _isSelecting = false;
        e.Pointer.Capture(null);
        e.Handled = true;
    }

    /// <summary>Nudges <see cref="ScrollOffset"/> by a fixed step whenever a drag's pointer sits
    /// within <see cref="EdgeAutoScrollThresholdPx"/> of the top or bottom edge — triggered from
    /// <see cref="OnPointerMoved"/> rather than a <c>DispatcherTimer</c> ticking while the pointer
    /// sits still. A held-stationary drag at the very edge therefore auto-scrolls only as long as
    /// the OS keeps delivering move events for it (which it normally does for a live drag); this
    /// is a deliberate, disclosed simplification over a timer-driven "continues while motionless"
    /// auto-scroll — see the S8-D2 report for why (testability without a live Dispatcher pump).</summary>
    private void MaybeAutoScroll(Point pointerPosition)
    {
        var height = Bounds.Height;
        if (height <= 0) { return; }
        if (pointerPosition.Y < EdgeAutoScrollThresholdPx) { ScrollByPixels(-EdgeAutoScrollStepPx); }
        else if (pointerPosition.Y > height - EdgeAutoScrollThresholdPx) { ScrollByPixels(EdgeAutoScrollStepPx); }
    }

    /// <summary>Extends the selection to the whole WORD (whitespace-delimited) under
    /// <paramref name="position"/> — double-click. Only ever called with a position
    /// <see cref="HitTestPosition"/> produced, which always names a Text-kind block, so
    /// <see cref="SelectionModel.PlainText"/> here is always that block's own run text.</summary>
    private void SelectWord(TextPosition position)
    {
        var block = _blocks[position.BlockIndex];
        var text = SelectionModel.PlainText(block);
        if (text.Length == 0) { _selection.Begin(position); return; }
        var index = Math.Clamp(position.Offset, 0, text.Length - 1);
        var start = index;
        while (start > 0 && !char.IsWhiteSpace(text[start - 1])) { start--; }
        var end = index;
        while (end < text.Length && !char.IsWhiteSpace(text[end])) { end++; }
        _selection.Begin(new TextPosition(position.BlockIndex, start));
        _selection.ExtendTo(new TextPosition(position.BlockIndex, end));
    }

    /// <summary>Extends the selection to the WHOLE block at <paramref name="blockIndex"/> —
    /// triple-click.</summary>
    private void SelectWholeBlock(int blockIndex)
    {
        var length = SelectionModel.PlainText(_blocks[blockIndex]).Length;
        _selection.Begin(new TextPosition(blockIndex, 0));
        _selection.ExtendTo(new TextPosition(blockIndex, length));
    }

    /// <summary>Ctrl/Cmd+A — selects the entire document. The last block's own text length is the
    /// only per-block length <see cref="SelectionModel.SelectAll"/> needs (every block strictly
    /// between the first and last is included WHOLLY by <see cref="SelectionModel.SelectedText"/>
    /// regardless of its own length) — computed via the SAME <see cref="SelectionModel.PlainText"/>
    /// a Table block uses, so a document that ends in a table still selects that table's full
    /// content instead of silently truncating it to zero.</summary>
    private void SelectAllText()
    {
        if (_blocks.Count == 0) { return; }
        var lastBlockLength = SelectionModel.PlainText(_blocks[^1]).Length;
        _selection.SelectAll(_blocks.Count, lastBlockLength);
        InvalidateVisual();
    }

    /// <summary>Ctrl/Cmd+C — copies the current selection to the OS clipboard as plain text, via
    /// this control's own <see cref="TopLevel"/> (Avalonia's clipboard is reached through the
    /// window/top-level a control is attached to, not a static/global service). A no-op — never an
    /// exception — for an empty selection or a view not yet attached to a TopLevel.</summary>
    private void CopySelectionToClipboard()
    {
        if (_selection.IsEmpty) { return; }
        var text = _selection.SelectedText(_blocks);
        if (text.Length > 0) { _ = CopyTextToClipboard(text); }
    }

    /// <summary>S9-B3 batch 5 (#44): copies the WHOLE plain text of the block at viewport-local y
    /// <paramref name="localY"/> to the clipboard — the left-gutter-click action. Reuses
    /// <see cref="LowerBound"/> over the already-current <see cref="_offsets"/> table (the same
    /// lookup <see cref="GetCurrentPositionForSave"/> uses) rather than a fresh hit-test, and
    /// <see cref="SelectionModel.PlainText"/> (the same extraction <see cref="SelectAllText"/>'s
    /// own last-block length already relies on) so a table/image block copies whatever plain-text
    /// representation that helper already gives it rather than this method inventing a second one.</summary>
    private void CopyLineAtGutterY(double localY)
    {
        if (_blocks.Count == 0) { return; }
        var index = Math.Clamp(LowerBound(_offsets, _scrollOffset + localY), 0, _blocks.Count - 1);
        var text = SelectionModel.PlainText(_blocks[index]);
        if (text.Length > 0) { _ = CopyTextToClipboard(text); }
    }

    /// <summary>S9-B3 batch 6: fired when a click (not a drag, no modifier) lands on an
    /// <see cref="FlowBlockKind.Image"/> block that has a real, resolvable
    /// <see cref="FlowBlock.ImageResourceId"/> — a diagram/formula rendered through Word's
    /// legacy-picture fallback or an ordinary embedded picture, but never a bare placeholder box
    /// (<see cref="FlowBlock.PlaceholderLabel"/> with no resource id — nothing to enlarge there).
    /// <see cref="MainWindow"/> owns turning this into a real window (<c>Panels.ImageZoomWindow</c>),
    /// same separation <see cref="ShortcutGuideModel"/>'s own doc keeps between this Rendering-layer
    /// class and the Panels windows built on top of it.</summary>
    public event Action<ulong>? ImageClicked;

    /// <summary>Which top-level block index (if any) is an Image block at viewport-local point
    /// <paramref name="point"/> — the y half reuses the SAME <see cref="LowerBound"/> lookup
    /// <see cref="CopyLineAtGutterY"/> and <see cref="GetCurrentPositionForSave"/> already use; the
    /// x half is a coarse column-bounds check (not a true image-rectangle hit test, since this view
    /// does not keep a per-block drawn-rect table) — a disclosed simplification: a click inside the
    /// text column's width, at the y an Image block occupies, counts as a hit on it.</summary>
    private int? NonTextImageBlockAt(Point point)
    {
        if (_blocks.Count == 0) { return null; }
        var columnWidth = Math.Max(40, Bounds.Width - LeftMargin - RightMargin);
        if (point.X < LeftMargin || point.X > LeftMargin + columnWidth) { return null; }
        var index = Math.Clamp(LowerBound(_offsets, _scrollOffset + point.Y), 0, _blocks.Count - 1);
        return _blocks[index].Kind == FlowBlockKind.Image ? index : null;
    }

    /// <summary>The one place that actually reaches the OS clipboard — shared by Ctrl+C/"Copy"
    /// (<see cref="CopySelectionToClipboard"/>) and the context menu's "Copy Link" (S8-B4 ④),
    /// so both go through the identical <see cref="TopLevel.GetTopLevel"/> + best-effort-swallow
    /// path rather than two slightly different clipboard calls.</summary>
    private async System.Threading.Tasks.Task CopyTextToClipboard(string text)
    {
        var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
        if (clipboard is null) { return; }
        try { await clipboard.SetTextAsync(text); }
        catch { /* best-effort — a clipboard failure never crashes the reader */ }
    }

    /// <summary>S8-B4 (④), extended S9-B3 batch 5 (#39/#40): rebuilds this view's context-menu
    /// ITEMS right before the menu opens (<see cref="ContextMenu.Opening"/>), from
    /// <see cref="ContextMenuModel.Build"/> — the pure function a test exercises directly. This
    /// method is the thin, deliberately untested (per the S8-B4 contract's own allowance) live
    /// wiring on top of it: one <see cref="MenuItem"/> per model item — "Copy" reusing the exact
    /// same clipboard path Ctrl+C uses, "Copy Link" copying <see cref="_lastRightClickLink"/>
    /// itself, "Open" calling <see cref="NavigateLink"/> with that same link (mirroring
    /// ReaderTextView.swift's own Open item — this host has no separate "selection as path" case
    /// for the right-click menu the way #43's Ctrl-click does, since a right-click's link is
    /// already resolved at press time), and "Select All" reusing <see cref="SelectAllText"/>.</summary>
    private void RebuildContextMenu(ContextMenu menu)
    {
        var link = _lastRightClickLink;
        var codeBlockText = _lastRightClickCodeBlockText;
        var models = ContextMenuModel.Build(!_selection.IsEmpty, link is not null, codeBlockText is not null);
        var items = new List<Control>(models.Count);
        foreach (var model in models)
        {
            var menuItem = new MenuItem { Header = model.Header, IsEnabled = model.Enabled };
            if (model.IsOpen)
            {
                menuItem.Click += (_, _) => { if (link is not null) { NavigateLink(link); } };
            }
            else if (model.IsCopyLink)
            {
                menuItem.Click += (_, _) => { if (link is not null) { _ = CopyTextToClipboard(link); } };
            }
            else if (model.IsCopyCode)
            {
                menuItem.Click += (_, _) => { if (codeBlockText is not null) { _ = CopyTextToClipboard(codeBlockText); } };
            }
            else if (model.IsSelectAll)
            {
                menuItem.Click += (_, _) => SelectAllText();
            }
            else
            {
                menuItem.Click += (_, _) => CopySelectionToClipboard();
            }
            items.Add(menuItem);
        }
        menu.ItemsSource = items;
    }

    /// <summary>S8-D2 (D2-a): the ONE hit-test entry point for selection — turns a pointer point
    /// (this control's own local coordinate space, the same space <see cref="RenderCore"/> draws
    /// in) into a <see cref="TextPosition"/> by reading the SAME cached <see cref="TextLayout"/>
    /// <see cref="DrawTextBlock"/> paints with (<see cref="GetOrBuildTextLayout"/>) — never a
    /// second layout or an independently recomputed coordinate space, per the S8-D2 contract.
    ///
    /// A point over a NON-text block (Image/Table/Rule — none of which keep a per-block TextLayout
    /// in this view's own cache; a Table's cells have their OWN separate TextLayouts inside
    /// TableGridRenderer) clamps to the nearest TEXT block's start or end, per the contract's own
    /// "a point outside any text block clamps to the nearest block's start/end" rule — implemented
    /// here as a forward-then-backward scan from the struck block rather than a true nearest-by-
    /// pixel-distance search, a disclosed simplification (see the S8-D2 report).
    ///
    /// Returns null in page mode (a materially different per-page/per-line TextLayout cache lives
    /// in <see cref="PageModePainter"/>, not here — see the report for why page-mode selection was
    /// not built) and for an empty document or zero-width viewport.</summary>
    private TextPosition? HitTestPosition(Point point)
    {
        if (_pageMode || _blocks.Count == 0) { return null; }
        var width = Bounds.Width;
        if (width <= 0) { return null; }
        EnsureEstimates(width);

        var documentY = point.Y + _scrollOffset;
        var rawIndex = Math.Clamp(LowerBound(_offsets, documentY), 0, _blocks.Count - 1);
        var textIndex = NearestTextBlockIndex(rawIndex);
        if (textIndex is null) { return null; }

        if (textIndex.Value != rawIndex)
        {
            // The struck block itself carries no per-block TextLayout — land on the near TEXT
            // block's start (it sits BELOW the struck point) or end (it sits ABOVE it).
            var boundaryText = SelectionModel.PlainText(_blocks[textIndex.Value]);
            var boundaryOffset = textIndex.Value > rawIndex ? 0 : boundaryText.Length;
            return new TextPosition(textIndex.Value, boundaryOffset);
        }

        var block = _blocks[textIndex.Value];
        if (block.Runs.Count == 0 || block.Runs.TrueForAll(r => r.Text.Length == 0))
        {
            return new TextPosition(textIndex.Value, 0);
        }

        var columnWidth = Math.Max(40, width - LeftMargin - RightMargin);
        var indentPx = block.IndentPoints * PointsToPixels;
        var spacingBeforePx = block.SpacingBeforePoints * PointsToPixels;
        var maxWidth = Math.Max(20, columnWidth - indentPx);
        var top = _offsets[textIndex.Value] - _scrollOffset;
        var originX = LeftMargin + indentPx;
        var originY = top + spacingBeforePx;

        var layout = GetOrBuildTextLayout(textIndex.Value, () => BuildTextLayout(block, maxWidth, _zoomFactor, _foregroundBrush));
        var local = new Point(point.X - originX, point.Y - originY);
        var hitResult = layout.HitTestPoint(local);
        var offset = hitResult.IsTrailing ? hitResult.TextPosition + 1 : hitResult.TextPosition;
        var length = SelectionModel.PlainText(block).Length;
        return new TextPosition(textIndex.Value, Math.Clamp(offset, 0, length));
    }

    /// <summary>Scans forward, then backward, from <paramref name="fromIndex"/> for the nearest
    /// Text-kind block — see <see cref="HitTestPosition"/>'s own doc for why this (not a strict
    /// pixel-distance search) is the clamp rule this contract's dispatch implements. Null only for
    /// a document with no Text blocks at all (an all-image/all-table document).</summary>
    private int? NearestTextBlockIndex(int fromIndex)
    {
        for (var i = fromIndex; i < _blocks.Count; i++)
        {
            if (_blocks[i].Kind == FlowBlockKind.Text) { return i; }
        }
        for (var i = fromIndex - 1; i >= 0; i--)
        {
            if (_blocks[i].Kind == FlowBlockKind.Text) { return i; }
        }
        return null;
    }

    /// <summary>S8-B4 (D2-c): the link (if any) covering the character at <paramref name="position"/>
    /// — walks <see cref="FlowBlock.Runs"/> summing each run's own text length (the SAME
    /// concatenation <see cref="SelectionModel.PlainText"/> builds for a Text block) until the one
    /// containing that offset is found, then returns ITS <see cref="FlowRun.LinkTarget"/>. Null for
    /// a Table/Image/Rule block (no Runs), an out-of-range block index, or a run with no link.</summary>
    private string? LinkAt(TextPosition position)
    {
        if (position.BlockIndex < 0 || position.BlockIndex >= _blocks.Count) { return null; }
        var block = _blocks[position.BlockIndex];
        if (block.Kind != FlowBlockKind.Text) { return null; }
        var cursor = 0;
        foreach (var run in block.Runs)
        {
            var end = cursor + run.Text.Length;
            if (position.Offset >= cursor && position.Offset < end) { return run.LinkTarget; }
            cursor = end;
        }
        return null;
    }

    /// <summary>Convenience wrapper combining <see cref="HitTestPosition"/> and <see cref="LinkAt"/>
    /// for a raw pointer point — used by both the hover-cursor logic and the press/release click
    /// disambiguation, so the two never risk hit-testing differently.</summary>
    private string? LinkAtPoint(Point point) => HitTestPosition(point) is { } pos ? LinkAt(pos) : null;

    /// <summary>S9-B3 batch 6 (#46): the whole plain text of the code block at pointer point
    /// <paramref name="point"/>, or null when that point is not a code block at all. A block counts
    /// as "code" when its FIRST run uses <see cref="FlowDocumentBuilder.CodeFontFamily"/> — the
    /// exact literal <c>FlowDocumentBuilder.BuildCodeRuns</c> (S8-B3) already tags every code
    /// token run with, so this needs no second classification of what counts as a code block.</summary>
    private string? CodeBlockTextAt(Point point)
    {
        if (HitTestPosition(point) is not { } pos) { return null; }
        if (pos.BlockIndex < 0 || pos.BlockIndex >= _blocks.Count) { return null; }
        var block = _blocks[pos.BlockIndex];
        if (block.Kind != FlowBlockKind.Text || block.Runs.Count == 0) { return null; }
        if (block.Runs[0].FontFamily != FlowDocumentBuilder.CodeFontFamily) { return null; }
        return SelectionModel.PlainText(block);
    }

    /// <summary>S8-B4/B5 (D2-c): follows one link. A FRAGMENT ('#…') is resolved entirely
    /// in-document, mirroring `AnchorResolver.swift.resolve`'s own two-step order exactly: (1) an
    /// EXACT bookmark-name match (<see cref="Model.BookmarkWire.Name"/> — office documents' opaque
    /// ids like `_Toc123`, never slugified) then (2) a GFM heading-slug match (<see
    /// cref="_headingAnchorResolver"/> — markdown TOC links). A fragment matching NEITHER is a dead
    /// cross-reference — this does nothing, exactly like the Swift side's own posture, and
    /// CRITICALLY never falls through to <see cref="ExternalLinkLauncher"/> (S8-B5: handing a bare
    /// fragment like "#chapter-1-loomings" to an OS URL opener was the original bug this unit
    /// fixes). Anything that is NOT a fragment (an http(s):// URL, a mailto:, any other scheme) goes
    /// to <see cref="ExternalLinkLauncher"/> unconditionally — the OS's own registered handler
    /// decides what it means, exactly as clicking it in any other application would.</summary>
    private void NavigateLink(string link)
    {
        if (!link.StartsWith('#'))
        {
            ExternalLinkLauncher.Open(link);
            return;
        }

        var anchorName = link[1..];
        var bookmarks = _tree?.Annotations?.Bookmarks;
        if (bookmarks is not null)
        {
            foreach (var bookmark in bookmarks)
            {
                if (string.Equals(bookmark.Name, anchorName, StringComparison.Ordinal))
                {
                    ScrollToNodeId(bookmark.TargetNodeId);
                    return;
                }
            }
        }

        if (_headingAnchorResolver.Resolve(anchorName) is { } headingNodeId)
        {
            ScrollToNodeId(headingNodeId);
        }
        // else: a dead fragment — do nothing (S8-B5 contract item 2).
    }

    /// <summary>S8-B5: gathers every "heading" node's own (trimmed, un-slugified) text and node id,
    /// in document order — the input <see cref="HeadingAnchorResolver.Build"/> needs. A DELIBERATE,
    /// SMALL duplicate of the walk `Panels.TableOfContentsModel.Build` already does (same
    /// SkippedTypes set, same "heading node -> collect its text, don't recurse further" rule) —
    /// importing Panels/ from Rendering/ would invert this app's two independent, sibling UI
    /// concerns (see <see cref="Panels.CommentsModel"/>'s own doc, which took the identical
    /// tradeoff in the other direction for the exact same reason, in S8-B4).</summary>
    private static List<(string Text, ulong NodeId)> CollectHeadingsInDocumentOrder(RenderTree tree)
    {
        var result = new List<(string, ulong)>();
        if (tree.Document is null) { return result; }
        var byId = new Dictionary<ulong, RenderNode>(tree.Nodes.Count);
        foreach (var node in tree.Nodes) { byId[node.Id] = node; }
        if (!byId.TryGetValue(tree.Document.RootNodeId, out var root)) { return result; }
        WalkForHeadings(root, byId, result);
        return result;
    }

    private static readonly HashSet<string> HeadingWalkSkippedTypes = new()
    {
        "footnote", "header", "footer", "masterPage", "masterPageObject",
        "anchoredObject", "formControl", "textRun", "lineBreak",
    };

    private static void WalkForHeadings(RenderNode node, Dictionary<ulong, RenderNode> byId, List<(string, ulong)> result)
    {
        if (HeadingWalkSkippedTypes.Contains(node.Type)) { return; }

        if (node.Type == "heading")
        {
            if (node.AsHeading is null) { return; }
            var text = HeadingText(node, byId).Trim();
            if (text.Length > 0) { result.Add((text, node.Id)); }
            return;
        }

        foreach (var childId in node.Children)
        {
            if (byId.TryGetValue(childId, out var child)) { WalkForHeadings(child, byId, result); }
        }
    }

    private static string HeadingText(RenderNode node, Dictionary<ulong, RenderNode> byId)
    {
        var sb = new System.Text.StringBuilder();
        if (node.Text is { } t) { sb.Append(t); }
        foreach (var childId in node.Children)
        {
            if (byId.TryGetValue(childId, out var child)) { sb.Append(HeadingText(child, byId)); }
        }
        return sb.ToString();
    }

    /// <summary>The ONE place that moves <see cref="ScrollOffset"/> by a relative amount — the
    /// wheel handler above and <see cref="OnKeyDown"/> below both go through this rather than each
    /// reimplementing "add, let the property clamp".</summary>
    private void ScrollByPixels(double deltaPx) => ScrollOffset += deltaPx;

    /// <summary>The reader's own guess at one line's height in pixels at the CURRENT zoom —
    /// same formula <see cref="BuildTextLayout"/> uses for its line-height fallback (12pt default
    /// font size * 1.25 natural leading), so an arrow-key step tracks zoom the same way the text
    /// it is scrolling past does.</summary>
    private double DefaultLineHeightPx => 12.0 * _zoomFactor * PointsToPixels * 1.25;

    /// <summary>Keyboard scrolling — closes the accessibility gap the S6 accessibility review found
    /// (docs/studio/sprints/S6/s6d-accessibility.md: "문서 스크롤이 키보드로 전혀 불가능하다"). Up/Down move one line (x3, so a single press is
    /// felt); PageUp/PageDown and Space/Shift+Space move a viewport minus one line of overlap (so
    /// the reader keeps a line of continuity across the jump, matching the usual reader convention);
    /// Home/End jump to the document's start/end. Reuses <see cref="ScrollByPixels"/> — the SAME
    /// method the wheel handler uses — rather than a second scroll implementation. The find bar's
    /// TextBox is a SIBLING of this view in MainWindow.axaml, not an ancestor/descendant, so while
    /// it holds focus these KeyDown events never reach this override at all (Avalonia's bubble
    /// routing only visits ancestors of the focused element) — no explicit "is the find box focused"
    /// guard is needed here.</summary>
    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.Handled) { return; }

        // S8-D2 (D2-a): Ctrl+A / Ctrl+C (Cmd on macOS, via KeyModifiers.Meta) / Escape, ahead of
        // the scroll-key switch below so they never fall through to it.
        var isCommandModifier = e.KeyModifiers.HasFlag(KeyModifiers.Control) || e.KeyModifiers.HasFlag(KeyModifiers.Meta);
        if (isCommandModifier && e.Key == Key.A)
        {
            SelectAllText();
            e.Handled = true;
            return;
        }
        if (isCommandModifier && e.Key == Key.C)
        {
            CopySelectionToClipboard();
            e.Handled = true;
            return;
        }
        if (e.Key == Key.Escape && !_selection.IsEmpty)
        {
            _selection.Clear();
            InvalidateVisual();
            e.Handled = true;
            return;
        }

        var lineStep = DefaultLineHeightPx * 3;
        var pageStep = Math.Max(lineStep, Math.Max(0, Bounds.Height) - DefaultLineHeightPx);

        switch (e.Key)
        {
            case Key.Down:
                ScrollByPixels(lineStep);
                break;
            case Key.Up:
                ScrollByPixels(-lineStep);
                break;
            case Key.PageDown:
                ScrollByPixels(pageStep);
                break;
            case Key.PageUp:
                ScrollByPixels(-pageStep);
                break;
            case Key.Space when e.KeyModifiers.HasFlag(KeyModifiers.Shift):
                ScrollByPixels(-pageStep);
                break;
            case Key.Space:
                ScrollByPixels(pageStep);
                break;
            case Key.Home:
                ScrollOffset = 0;
                break;
            case Key.End:
                ScrollOffset = ContentHeight;
                break;
            default:
                return;
        }

        e.Handled = true;
    }

    /// <summary>Builds the cumulative-offset table from character-count ESTIMATES the first time a
    /// width is seen (or the tree/zoom changes). A width change invalidates every estimate — text
    /// wraps differently — so this is also called from Render when Bounds.Width has moved.</summary>
    private void EnsureEstimates(double width)
    {
        if (_layoutWidth == width && _blockHeights.Length == _blocks.Count) { return; }

        // A width change re-wraps every line (and re-flows every table column), so a cache keyed
        // by block index from the OLD width would hand back layouts of the wrong size — a plain
        // window resize must invalidate the same caches SetZoom does, not just a zoom change.
        if (_layoutWidth >= 0 && _layoutWidth != width)
        {
            ClearCaches();
        }
        _layoutWidth = width;
        var columnWidth = Math.Max(40, width - LeftMargin - RightMargin);
        _blockHeights = new double[_blocks.Count];
        _measured = new bool[_blocks.Count];
        _offsets = new double[_blocks.Count + 1];

        var y = TopMargin;
        for (var i = 0; i < _blocks.Count; i++)
        {
            _offsets[i] = y;
            var estimate = EstimateHeight(_blocks[i], columnWidth, _zoomFactor);
            _blockHeights[i] = estimate;
            y += estimate;
        }
        _offsets[_blocks.Count] = y;
    }

    private double EstimateHeight(FlowBlock block, double columnWidth, double fontScale)
    {
        switch (block.Kind)
        {
            case FlowBlockKind.Rule:
                return block.SpacingBeforePoints * PointsToPixels + 1 + block.SpacingAfterPoints * PointsToPixels;
            case FlowBlockKind.Image:
                // S8-A2 (C2): same clamp-to-column function ImageBlockRenderer.Draw uses for the
                // actual paint — columnWidth here is NOT zoom-scaled (invariant 46: only the
                // window's own width resizes a picture, never the text zoom), matching Draw's own
                // columnWidth parameter, so converting it straight to points and back is exact.
                // S8-D2 (D2-d): goes through the SAME EffectiveDeclaredSize() Draw uses — for a
                // markdown image (declared {0,0}) that decodes the resource here, once, so this
                // reservation pass and the later paint pass can never disagree (see that method's
                // own doc). Every other format still measures from its own real declared size and
                // never touches the decoder from this path.
                var maxWidthPoints = columnWidth / PointsToPixels;
                var (declaredWidthPoints, declaredHeightPoints) = _imageRenderer.EffectiveDeclaredSize(block);
                var (_, imageHeightPoints) = PictureGeometry.Measure(declaredWidthPoints, declaredHeightPoints, maxWidthPoints);
                var h = imageHeightPoints * PointsToPixels;
                return h + (block.SpacingBeforePoints + block.SpacingAfterPoints) * PointsToPixels;
            case FlowBlockKind.Table:
                return (block.Table is null ? 0 : TableGridRenderer.EstimateHeight(block.Table, columnWidth, fontScale, _imageRenderer))
                    + (block.SpacingBeforePoints + block.SpacingAfterPoints) * PointsToPixels;
            default:
                var charCount = 0;
                var maxFontSize = 12.0;
                foreach (var run in block.Runs)
                {
                    charCount += run.Text.Length;
                    if (run.FontSizePoints > maxFontSize) { maxFontSize = run.FontSizePoints; }
                }
                maxFontSize *= fontScale;
                if (charCount == 0)
                {
                    return (block.SpacingBeforePoints + block.SpacingAfterPoints) * PointsToPixels + maxFontSize * PointsToPixels;
                }
                var indented = Math.Max(40, columnWidth - block.IndentPoints * PointsToPixels);
                var charsPerLine = Math.Max(AverageCharsPerLine * 0.25, indented / (maxFontSize * PointsToPixels * 0.55));
                var lines = Math.Max(1, Math.Ceiling(charCount / charsPerLine));
                // Applies the document's own line-height RULE (mode + value), not just a
                // `.multiple` ratio for `.exact`/`.atLeast` too — `ScaledBy`
                // converts a POINT `Exact`/`AtLeast` value into this method's own pixel space.
                var naturalGuess = maxFontSize * PointsToPixels * 1.25;
                var lineBoxPixels = block.LineHeight.ScaledBy(PointsToPixels).Apply(naturalGuess);
                return lines * lineBoxPixels + (block.SpacingBeforePoints + block.SpacingAfterPoints) * PointsToPixels;
        }
    }

    public override void Render(DrawingContext context)
    {
        base.Render(context);
        RenderCore(new AvaloniaPageCanvas(context));
    }

    /// <summary>The actual paint traversal, extracted from <see cref="Render"/> so
    /// <see cref="Printing.PdfExporter"/> can drive it straight into an
    /// <see cref="Printing.SkiaPageCanvas"/> — no offscreen Window, no captured frame, no
    /// compositor involved. The screen path calls <see cref="Render"/>, which still calls
    /// <c>base.Render(context)</c> first and then this, through an
    /// <see cref="Printing.AvaloniaPageCanvas"/> wrapping that SAME context.</summary>
    internal void RenderCore(IPageCanvas surface)
    {
        // Fills the WHOLE control before anything else — an empty document (early return
        // right below) and the letterboxed margin around a page-mode sheet would otherwise fall
        // through to whatever the host window drew, which does not track this view's own theme
        // resolution. Page mode's own sheets are opaque and painted on top of this, so the paper
        // stays paper-coloured; only the surrounding gutter and the flow-mode canvas pick this up.
        // Excludes SkiaPageCanvas deliberately: PdfExporter drives RenderCore through THAT surface
        // (see its own doc comment), and an exported PDF must stay paper-white regardless of the
        // exporting machine's OS theme — a printed page has no "dark mode".
        if (surface is not Printing.SkiaPageCanvas && Bounds.Width > 0 && Bounds.Height > 0)
        {
            surface.DrawRect(new Rect(0, 0, Bounds.Width, Bounds.Height), _backgroundColor, null, 0);
        }

        if (_blocks.Count == 0) { return; }

        var width = Bounds.Width;
        if (width <= 0) { return; }

        if (_pageMode)
        {
            EnsurePageLayout();
            if (PageModeActive)
            {
                _pageModePainter.Draw(surface, _blocks, _tree!, _pageLayout!, _pageGeometry!, _zoomFactor,
                    width, Math.Max(0, Bounds.Height), _scrollOffset, _pageMarkers, _masterPageFurniture);
                return;
            }
            // No page geometry for this document — fall through to the ordinary flow render below
            // rather than draw nothing, matching PageMode's own "silently has no effect" contract.
        }

        EnsureEstimates(width);

        var viewportHeight = Math.Max(0, Bounds.Height);
        var buffer = Math.Max(200, viewportHeight);
        var visibleTop = _scrollOffset - buffer;
        var visibleBottom = _scrollOffset + viewportHeight + buffer;

        var startIndex = LowerBound(_offsets, visibleTop);
        var endIndex = LowerBound(_offsets, visibleBottom);
        endIndex = Math.Min(endIndex + 1, _blocks.Count);

        var columnWidth = Math.Max(40, width - LeftMargin - RightMargin);
        var offsetsDirty = false;

        // S9-V diagnostic (FASTDOC_DRAW_LOG): null on every real user machine unless the env var
        // is set, so this whole block is a single field read + null check per frame. See the
        // DrawLogPath field doc for why this exists.
        List<string>? drawLog = null;
        long drawLogFrameNo = 0;
        if (DrawLogPath is not null)
        {
            drawLogFrameNo = System.Threading.Interlocked.Increment(ref _drawLogFrameCounter);
            var docTotalHeight = _offsets.Length > 0 ? _offsets[^1] : 0;
            drawLog = new List<string>
            {
                $"FRAME {drawLogFrameNo} scrollOffset={_scrollOffset:F1} localViewTop={visibleTop:F1} " +
                $"localViewBottom={visibleBottom:F1} viewportHeight={viewportHeight:F1} docTotalHeight={docTotalHeight:F1} " +
                $"startIndex={startIndex} endIndex={endIndex} blockCount={_blocks.Count}"
            };
            // Blocks entirely outside [startIndex, endIndex) never reach DrawBlock at all — this
            // IS the top-level cull the lead asked to see, using each block's last-known geometry
            // (already current: EnsureEstimates/RebuildOffsets ran above/below every frame).
            for (var i = 0; i < startIndex; i++)
            {
                var b = _blocks[i];
                drawLog.Add($"BLOCK i={i} nodeId={b.NodeId} kind={b.Kind} y={_offsets[i]:F1} height={_blockHeights[i]:F1} verdict=culled-above");
            }
            for (var i = endIndex; i < _blocks.Count; i++)
            {
                var b = _blocks[i];
                drawLog.Add($"BLOCK i={i} nodeId={b.NodeId} kind={b.Kind} y={_offsets[i]:F1} height={_blockHeights[i]:F1} verdict=culled-below");
            }
        }

        // A scroll jump (large document, keyboard PageDown, or the --paint-probe sweep itself) can
        // reveal many never-before-drawn text blocks in one frame, each paying its own TextLayout
        // construction — measured as ~90-100% of a moby-dick.md scroll frame's cost. Building them
        // one at a time on the UI thread serializes work that has no dependency between blocks, so
        // build every MISSING
        // block for this frame's range in parallel first (verified safe: a 16-task concurrent
        // TextLayout-construction probe produced zero exceptions and the results drew correctly),
        // then run the ordinary draw loop below where every one of them is now a cache hit.
        PrewarmVisibleRange(startIndex, endIndex, columnWidth);

        for (var i = startIndex; i < endIndex; i++)
        {
            var block = _blocks[i];
            var top = _offsets[i] - _scrollOffset;
            // S9-V: these two MUST be computed against the block's DOCUMENT-space top
            // (_offsets[i]), never against `top` (SURFACE-space — already had _scrollOffset
            // subtracted). `visibleTop`/`visibleBottom` are document-space; subtracting a
            // surface-space `top` from them left a stray +_scrollOffset term in the result, which
            // is invisible at scrollOffset=0 (the cover-page table drew fine) and grows with every
            // scroll — root cause of the VM's reported blank region (see FASTDOC_DRAW_LOG evidence
            // in docs/studio/sprints/S9/s9c-flow-content.md). Both values that reach DrawBlock/
            // TableGridRenderer.Draw are BLOCK-LOCAL: 0 == this block's own top edge, growing
            // downward — never surface pixels, never absolute document coordinates.
            var blockLocalViewTop = visibleTop - _offsets[i];
            var blockLocalViewBottom = visibleBottom - _offsets[i];
            List<string>? subLines = null;
            Action<string>? cellDiag = drawLog is null ? null : line => (subLines ??= new List<string>()).Add(line);
            var actualHeight = DrawBlock(surface, block, i, top, columnWidth, blockLocalViewTop, blockLocalViewBottom, cellDiag);
            if (!_measured[i] || Math.Abs(actualHeight - _blockHeights[i]) > 0.5)
            {
                _blockHeights[i] = actualHeight;
                _measured[i] = true;
                offsetsDirty = true;
            }
            if (drawLog is not null)
            {
                var drawnRowIndices = new HashSet<string>();
                var cellsSeen = 0;
                if (subLines is not null)
                {
                    foreach (var l in subLines)
                    {
                        if (l.StartsWith("row=") && l.EndsWith("verdict=drawn"))
                        {
                            var rowToken = l[..l.IndexOf(' ')]; // "row=<n>"
                            drawnRowIndices.Add(rowToken);
                        }
                        else if (l.StartsWith("cell ")) { cellsSeen++; }
                    }
                }
                drawLog.Add($"BLOCK i={i} nodeId={block.NodeId} kind={block.Kind} y={_offsets[i]:F1} height={actualHeight:F1} " +
                    $"verdict=drawn rowsDrawn={drawnRowIndices.Count} cellsSeen={cellsSeen}");
                if (subLines is not null) { foreach (var line in subLines) { drawLog.Add("  " + line); } }
            }
        }

        if (drawLog is not null)
        {
            var text = string.Join(Environment.NewLine, drawLog) + Environment.NewLine;
            lock (DrawLogLock)
            {
                File.AppendAllText(DrawLogPath!, text);
            }
        }

        if (offsetsDirty)
        {
            RebuildOffsets();
        }

        // S9-B3 batch 3: additive overlay, drawn AFTER the block loop above and reading only its
        // already-computed _offsets/_blockHeights — never touches DrawBlock/DrawTextBlock or any
        // measure path, so it cannot disturb table/column geometry.
        if (_showLineNumbers)
        {
            DrawLineNumberGutter(surface, startIndex, endIndex);
        }

        UpdateScrollDirection();
        SchedulePrefetch(startIndex, endIndex, columnWidth);
    }

    /// <summary>Draws a right-aligned line-number label in the left margin beside every numbered
    /// top-level block currently on screen — see <see cref="LineNumberModel"/> for the numbering
    /// rule. Deliberately reads only <see cref="_offsets"/>/<see cref="_blockHeights"/> (already
    /// current by the time this runs, from the loop just above) rather than re-measuring anything.</summary>
    private void DrawLineNumberGutter(IPageCanvas surface, int startIndex, int endIndex)
    {
        for (var i = startIndex; i < endIndex; i++)
        {
            var label = LineNumberModel.LabelFor(_blocks, i);
            if (label is null) { continue; }
            var top = _offsets[i] - _scrollOffset;
            var gutterLayout = new TextLayout(label, LineNumberTypeface, 10 * _zoomFactor, LineNumberBrush,
                TextAlignment.Right, TextWrapping.NoWrap, maxWidth: LeftMargin - 4);
            surface.DrawTextLayout(gutterLayout, new Point(2, top));
        }
    }

    /// <summary>Tracks whether the last observed scroll move was downward or upward, so
    /// <see cref="SchedulePrefetch"/> only ever warms the direction the reader is actually moving
    /// toward. Defaults to "down" until the first real move (the common first scroll).</summary>
    private void UpdateScrollDirection()
    {
        if (_scrollOffset > _lastScrollOffsetForDirection) { _scrollDirection = 1; }
        else if (_scrollOffset < _lastScrollOffsetForDirection) { _scrollDirection = -1; }
        _lastScrollOffsetForDirection = _scrollOffset;
    }

    /// <summary>Builds every not-yet-cached text block in <paramref name="startIndex"/>..
    /// <paramref name="endIndex"/> concurrently (<see cref="System.Threading.Tasks.Parallel.For"/>
    /// over the thread pool) and inserts them into <see cref="_textLayoutCache"/> before the
    /// caller's own draw loop runs — so a scroll jump that reveals many blocks at once pays
    /// wall-clock roughly (work / core count) instead of the full serial sum. Blocking (the caller
    /// needs these laid out before it can draw this frame), unlike <see cref="SchedulePrefetch"/>
    /// which is fire-and-forget for blocks beyond the current frame's own needs.</summary>
    private void PrewarmVisibleRange(int startIndex, int endIndex, double columnWidth)
    {
        List<(int Index, FlowBlock Block, double MaxWidth)>? missing = null;
        for (var i = startIndex; i < endIndex; i++)
        {
            var block = _blocks[i];
            if (block.Kind != FlowBlockKind.Text) { continue; }
            if (block.Runs.Count == 0 || block.Runs.TrueForAll(r => r.Text.Length == 0)) { continue; }
            if (_textLayoutCache.ContainsKey(i)) { continue; }
            missing ??= new List<(int, FlowBlock, double)>();
            var indentPx = block.IndentPoints * PointsToPixels;
            missing.Add((i, block, Math.Max(20, columnWidth - indentPx)));
        }
        if (missing is null || missing.Count < 2) { return; } // not worth thread-pool overhead for 0-1 blocks

        // Snapshot ONCE, here on the UI thread, before any Parallel.For worker thread can read
        // these fields — UpdateThemeBrushes/SetZoom reassign them from the UI thread with no lock,
        // so a worker reading the FIELD directly could observe a value mid-reassignment relative
        // to the frame it was scheduled for (S6-A2 MEDIUM finding). columnWidth/maxWidth already
        // follow this pattern; this extends it to the other two frame-scoped inputs.
        var zoomSnapshot = _zoomFactor;
        var foregroundSnapshot = _foregroundBrush;

        var built = new TextLayout[missing.Count];
        System.Threading.Tasks.Parallel.For(0, missing.Count, k =>
        {
            built[k] = BuildTextLayout(missing[k].Block, missing[k].MaxWidth, zoomSnapshot, foregroundSnapshot);
        });
        for (var k = 0; k < missing.Count; k++)
        {
            InsertIntoCache(missing[k].Index, built[k]);
        }
    }

    /// <summary>Fires off background <see cref="TextLayout"/> builds for the text blocks
    /// just past the current viewport, in the scroll direction only, so by the time they are
    /// actually revealed <see cref="GetOrBuildTextLayout"/> finds them already staged instead of
    /// paying the build cost on the UI thread during a paint. Never blocks the caller — every
    /// build runs on a thread-pool task and lands in <see cref="_prefetchStaging"/>, a
    /// <see cref="System.Collections.Concurrent.ConcurrentDictionary{TKey,TValue}"/> safe for a
    /// background writer and a UI-thread reader to share without locking.</summary>
    private void SchedulePrefetch(int startIndex, int endIndex, double columnWidth)
    {
        if (_prefetchStaging.Count >= PrefetchStagingCap) { return; } // backpressure: nothing is consuming fast enough

        int rangeStart, rangeEnd;
        if (_scrollDirection >= 0)
        {
            rangeStart = endIndex;
            rangeEnd = Math.Min(_blocks.Count, endIndex + PrefetchBlockCount);
        }
        else
        {
            rangeStart = Math.Max(0, startIndex - PrefetchBlockCount);
            rangeEnd = startIndex;
        }

        // Snapshot ONCE per call — see PrewarmVisibleRange's identical comment. The generation is
        // read the same way: every task launched from THIS call carries the document identity it
        // was scheduled against, checked again (via a fresh Volatile.Read) right before the write.
        var zoomSnapshot = _zoomFactor;
        var foregroundSnapshot = _foregroundBrush;
        var generation = System.Threading.Volatile.Read(ref _documentGeneration);

        for (var i = rangeStart; i < rangeEnd; i++)
        {
            // Re-check the cap on every iteration, not just once before the loop — a burst that
            // starts under the cap could otherwise schedule up to PrefetchBlockCount (24) more
            // before the next frame's check, quietly exceeding it (S6-A2 LOW finding).
            if (_prefetchStaging.Count >= PrefetchStagingCap) { break; }

            var block = _blocks[i];
            if (block.Kind != FlowBlockKind.Text) { continue; } // tables/images have their own caches
            if (block.Runs.Count == 0 || block.Runs.TrueForAll(r => r.Text.Length == 0)) { continue; }
            if (_textLayoutCache.ContainsKey(i) || _prefetchStaging.ContainsKey(i)) { continue; }
            if (!_prefetchInFlight.TryAdd(i, 0)) { continue; } // already being built by a prior frame's task

            var indentPx = block.IndentPoints * PointsToPixels;
            var maxWidth = Math.Max(20, columnWidth - indentPx);
            var captured = block;
            var index = i;
            System.Threading.Tasks.Task.Run(() =>
            {
                try
                {
                    var layout = BuildTextLayout(captured, maxWidth, zoomSnapshot, foregroundSnapshot);
                    // Always land in staging, never touch _textLayoutCache from this thread — that
                    // Dictionary is UI-thread-owned (read AND written during Render/GetOrBuildText-
                    // Layout) and is not safe for a background reader/writer to race against. If the
                    // UI thread already built this block itself in the meantime, GetOrBuildTextLayout
                    // finds its own cache entry first and this staged copy is simply never consumed
                    // (bounded leftover, capped by PrefetchStagingCap, cleared on width/zoom change).
                    //
                    // The generation check guards a DIFFERENT race than that one: the document
                    // itself may have been replaced (SetTree) while this task was still running.
                    // ClearCaches already emptied _prefetchStaging at that moment, but this task
                    // has no cancellation and keeps running — without this check it would write a
                    // TextLayout built from the OLD document's text into the NEW document's staging
                    // map under an index that means something entirely different now.
                    if (System.Threading.Volatile.Read(ref _documentGeneration) == generation)
                    {
                        _prefetchStaging[index] = layout;
                    }
                }
                finally
                {
                    _prefetchInFlight.TryRemove(index, out _);
                }
            });
        }
    }

    private void RebuildOffsets()
    {
        var y = TopMargin;
        for (var i = 0; i < _blocks.Count; i++)
        {
            _offsets[i] = y;
            y += _blockHeights[i];
        }
        _offsets[_blocks.Count] = y;
    }

    /// <summary>Draws one block at pixel Y `top` (already scroll-adjusted) and returns its true
    /// rendered height in pixels, so the caller can correct the offset table. <paramref
    /// name="localViewTop"/>/<paramref name="localViewBottom"/> are the visible window in the
    /// SAME coordinate space as `top` (i.e. relative to this block's own top-left) — only a Table
    /// block uses them today, to skip TextLayout work for off-screen rows.</summary>
    private double DrawBlock(IPageCanvas surface, FlowBlock block, int blockIndex, double top, double columnWidth,
        // S9-V (root cause fixed 2026-09-06): these two are BLOCK-LOCAL — 0 is this block's own
        // top edge, growing downward, completely independent of scroll offset or surface pixels.
        // The caller (RenderCore) computes them as `visibleTop/Bottom(document-space) -
        // _offsets[blockIndex](document-space)` — NEVER against `top` (surface-space, already
        // scroll-subtracted). Mixing document-space and surface-space here was the exact bug: it
        // is invisible at scrollOffset=0 (both spaces coincide there) and produces a growing
        // phantom offset at any other scroll position, which culled an entire table's rows on a
        // real VM even though the table sat inside the padded viewport (see FASTDOC_DRAW_LOG
        // evidence in docs/studio/sprints/S9/s9c-flow-content.md). If you add a new block kind
        // that culls sub-content by position, add it against THESE block-local values, never
        // re-derive from `top`.
        double blockLocalViewTop, double blockLocalViewBottom, Action<string>? diagLog = null)
    {
        var indentPx = block.IndentPoints * PointsToPixels;
        var spacingBeforePx = block.SpacingBeforePoints * PointsToPixels;
        var spacingAfterPx = block.SpacingAfterPoints * PointsToPixels;

        switch (block.Kind)
        {
            case FlowBlockKind.Rule:
            {
                var y = top + spacingBeforePx;
                surface.DrawLine(new Point(LeftMargin, y), new Point(LeftMargin + columnWidth, y), RuleColor, 1);
                return spacingBeforePx + 1 + spacingAfterPx;
            }

            case FlowBlockKind.Image:
            {
                var drawnHeight = _imageRenderer.Draw(surface, block, LeftMargin, top + spacingBeforePx, columnWidth, indentPx);
                diagLog?.Invoke($"image resourceId={(block.ImageResourceId?.ToString() ?? "(null)")} placeholder={block.PlaceholderLabel ?? "(null)"} drawnHeight={drawnHeight:F1}");
                return spacingBeforePx + drawnHeight + spacingAfterPx;
            }

            case FlowBlockKind.Table:
            {
                if (block.Table is null) { return spacingBeforePx + spacingAfterPx; }
                _tableRowHeightCache.TryGetValue(blockIndex, out var cachedRows);
                var tableTop = top + spacingBeforePx;
                // TableGridRenderer.Draw's own `viewportTop`/`viewportBottom` parameters are
                // whatever coordinate space its `top` parameter (here, `tableTop` — SURFACE-space)
                // is in, because it immediately does `viewportTop - top` internally to recover a
                // TABLE-local value — adding `tableTop` here and subtracting the SAME `tableTop`
                // there cancels exactly, regardless of which space `tableTop` happens to be in, as
                // long as `blockLocalViewTop`/`blockLocalViewBottom` themselves are correct
                // block-local values (see this method's parameter doc).
                var tableHeight = TableGridRenderer.Draw(
                    surface, block.Table, LeftMargin + indentPx, tableTop,
                    Math.Max(40, columnWidth - indentPx), _zoomFactor,
                    tableTop + blockLocalViewTop, tableTop + blockLocalViewBottom,
                    cachedRows, out var rowHeights, rowIndicesToDraw: null, imageRenderer: _imageRenderer,
                    diagLog: diagLog);
                _tableRowHeightCache[blockIndex] = rowHeights;
                return spacingBeforePx + tableHeight + spacingAfterPx;
            }

            default:
                return DrawTextBlock(surface, block, blockIndex, top, columnWidth, indentPx, spacingBeforePx, spacingAfterPx, diagLog);
        }
    }

    private double DrawTextBlock(IPageCanvas surface, FlowBlock block, int blockIndex, double top, double columnWidth,
        double indentPx, double spacingBeforePx, double spacingAfterPx, Action<string>? diagLog = null)
    {
        if (block.Runs.Count == 0 || block.Runs.TrueForAll(r => r.Text.Length == 0))
        {
            diagLog?.Invoke("text emptyRuns=true textLayoutNull=true height=14.0");
            return spacingBeforePx + 14 + spacingAfterPx;
        }

        var maxWidth = Math.Max(20, columnWidth - indentPx);
        // Reading _zoomFactor/_foregroundBrush directly here is safe — DrawTextBlock only ever
        // runs synchronously on the UI thread inside RenderCore, the same thread that writes
        // both fields (UpdateThemeBrushes/SetZoom). Only the two background paths (PrewarmVisible-
        // Range/SchedulePrefetch) need the snapshot-and-pass pattern; see their own comments.
        var layout = GetOrBuildTextLayout(blockIndex, () => BuildTextLayout(block, maxWidth, _zoomFactor, _foregroundBrush));
        diagLog?.Invoke($"text textLayoutNull=false height={layout.Height:F1}");

        // Highlights paint BEFORE the text (S8-D2 contract) — selection first, find on top of it,
        // both through the SAME PaintHighlightRange primitive so D2-b's find-visibility fix reuses
        // this rather than adding a third highlight painter.
        DrawSelectionHighlight(surface, blockIndex, block, layout, LeftMargin + indentPx, top + spacingBeforePx);
        DrawFindHighlights(surface, blockIndex, layout, LeftMargin + indentPx, top + spacingBeforePx);
        surface.DrawTextLayout(layout, new Point(LeftMargin + indentPx, top + spacingBeforePx));
        return spacingBeforePx + layout.Height + spacingAfterPx;
    }

    /// <summary><paramref name="zoomFactor"/>/<paramref name="foregroundBrush"/> are passed in
    /// rather than read off <see cref="_zoomFactor"/>/<see cref="_foregroundBrush"/> directly
    /// because this method also runs on a Parallel.For/Task.Run worker thread (see
    /// PrewarmVisibleRange/SchedulePrefetch) — both fields are reassigned from the UI thread with
    /// no lock (UpdateThemeBrushes/SetZoom), so a worker reading them live could observe a value
    /// mid-reassignment relative to the frame it was scheduled for (S6-A2 MEDIUM finding). Every
    /// caller snapshots both once before starting background work; DrawTextBlock, which always
    /// runs on the UI thread, just passes the current field values straight through.</summary>
    private TextLayout BuildTextLayout(FlowBlock block, double maxWidth, double zoomFactor, IBrush foregroundBrush)
    {
        // SelectionModel.PlainText is the SAME concatenation for a Text-kind block (it is also
        // what HitTestPosition/DrawSelectionHighlight measure offsets against) — one source of
        // truth for "what string does this block's TextLayout actually contain".
        var text = SelectionModel.PlainText(block);
        var overrides = new List<ValueSpan<TextRunProperties>>(block.Runs.Count);
        var cursor = 0;
        var maxFontSizePx = 12.0 * zoomFactor * PointsToPixels;
        foreach (var run in block.Runs)
        {
            var length = run.Text.Length;
            if (length > 0)
            {
                var fontSizePx = run.FontSizePoints * zoomFactor * PointsToPixels;
                if (fontSizePx > maxFontSizePx) { maxFontSizePx = fontSizePx; }
                var typeface = new Typeface(
                    run.FontFamily ?? "Inter",
                    run.Italic ? FontStyle.Italic : FontStyle.Normal,
                    run.Bold ? FontWeight.Bold : FontWeight.Normal);
                TextDecorationCollection? decorations = null;
                if (run.Underline) { decorations = TextDecorations.Underline; }
                else if (run.Strike) { decorations = TextDecorations.Strikethrough; }
                var props = new GenericTextRunProperties(
                    typeface,
                    fontSizePx,
                    textDecorations: decorations,
                    // ImmutableSolidColorBrush, NOT SolidColorBrush — SolidColorBrush is an
                    // AvaloniaObject (styled properties, Dispatcher-thread-affine). Building one on
                    // a background thread (PrewarmVisibleRange/SchedulePrefetch) throws
                    // "the calling thread cannot access this object because a different thread owns
                    // it" the first time the compositor references it while drawing — measured: this
                    // exact exception, thrown from Brush.OnReferencedFromCompositor via
                    // TextLine.Draw, the first time a background-built layout was drawn.
                    // ImmutableSolidColorBrush carries no Dispatcher affinity, so it is safe to
                    // construct off the UI thread and hand to the compositor from any thread.
                    //
                    // Opaque black is what FlowDocumentBuilder.ColorFrom emits for a run that
                    // never declared a colour at all (wire is null -> Colors.Black — the document's
                    // "auto" colour), and that value is indistinguishable at this layer from a run
                    // that explicitly asked for pure black; the wire already collapsed that
                    // distinction before it reached this view. Given that, opaque black is treated as
                    // "follow the theme" and remapped to the (snapshotted) foreground brush parameter
                    // (near-white in dark mode); any OTHER declared colour is a genuine authorial
                    // choice and is left exactly as the document stated it, in either theme.
                    foregroundBrush: IsAutoForeground(run.Foreground) ? foregroundBrush : new ImmutableSolidColorBrush(run.Foreground));
                overrides.Add(new ValueSpan<TextRunProperties>(cursor, length, props));
            }
            cursor += length;
        }

        // Same rule as the estimate above — `.exact`/`.atLeast` apply their own point value
        // (scaled to pixels) rather than being treated as `.multiple(1.0)`. `.multiple` stays
        // `naturalGuess * ratio` — there is no rendering assertion here to catch a flow-mode
        // regression if that ratio's meaning changed.
        var naturalGuessPx = maxFontSizePx * 1.25;
        var lineHeightPx = block.LineHeight.ScaledBy(PointsToPixels).Apply(naturalGuessPx);
        return new TextLayout(
            text,
            DefaultTypeface,
            maxFontSizePx,
            foregroundBrush,
            block.Alignment,
            TextWrapping.Wrap,
            maxWidth: maxWidth,
            lineHeight: lineHeightPx,
            textStyleOverrides: overrides);
    }

    /// <summary>Draws a highlight rectangle behind every find-match that lands in this block, using
    /// the SAME TextLayout the text itself will be drawn with — HitTestTextRange returns rects in
    /// the layout's own local space, so they are offset by exactly the same (originX, originY) the
    /// text draw call uses, or a highlight would drift from the glyphs it is supposed to sit under.
    /// The current match gets a stronger color so "n/m" and the highlighted glyph agree.</summary>
    private void DrawFindHighlights(IPageCanvas surface, int blockIndex, TextLayout layout, double originX, double originY)
    {
        if (_matches.Count == 0) { return; }
        for (var m = 0; m < _matches.Count; m++)
        {
            var (matchBlock, start, length) = _matches[m];
            if (matchBlock != blockIndex || length <= 0) { continue; }
            var color = m == _currentMatchIndex ? _findCurrentMatchHighlightColor : _findMatchHighlightColor;
            PaintHighlightRange(surface, layout, start, length, originX, originY, color);
        }
    }

    /// <summary>S8-D2 (D2-a): the current text selection's own portion of this block, painted the
    /// SAME way <see cref="DrawFindHighlights"/> paints a match — via <see
    /// cref="PaintHighlightRange"/>, so both highlight kinds (and D2-b's find-visibility fix, which
    /// reuses this same primitive) share one rectangle-painting path.</summary>
    private void DrawSelectionHighlight(IPageCanvas surface, int blockIndex, FlowBlock block, TextLayout layout, double originX, double originY)
    {
        if (_selection.IsEmpty) { return; }
        var blockTextLength = SelectionModel.PlainText(block).Length;
        var (start, length) = _selection.RangeWithinBlock(blockIndex, blockTextLength);
        if (length <= 0) { return; }
        PaintHighlightRange(surface, layout, start, length, originX, originY, _selectionHighlightColor);
    }

    /// <summary>Paints one highlight rectangle per line for the character range
    /// [<paramref name="start"/>, <paramref name="start"/> + <paramref name="length"/>) of
    /// <paramref name="layout"/> — the ONE shared primitive behind both find-match highlighting
    /// and text-selection highlighting (S8-D2's contract asks D2-b's find-visibility fix to reuse
    /// this rather than adding a third rectangle painter). <c>HitTestTextRange</c> returns rects in
    /// the layout's own local space, so the caller's (originX, originY) must be the SAME point the
    /// text itself is about to be drawn at, or the highlight drifts from the glyphs under it.</summary>
    private static void PaintHighlightRange(IPageCanvas surface, TextLayout layout, int start, int length, double originX, double originY, Color color)
    {
        if (length <= 0) { return; }
        foreach (var rect in layout.HitTestTextRange(start, length))
        {
            var placed = new Rect(rect.X + originX, rect.Y + originY, rect.Width, rect.Height);
            surface.DrawRect(placed, color, null, 0);
        }
    }

    /// <summary>First index i in a sorted array such that array[i] &gt;= value — binary search over
    /// the offset table, so scrolling a document with thousands of blocks never scans them all.</summary>
    /// <summary>True for the exact opaque-black value <see cref="FlowDocumentBuilder"/>'s
    /// ColorFrom emits when a run's wire colour was null — see the comment on
    /// <see cref="BuildTextLayout"/> for why this is a heuristic, not a real "was it declared" flag.</summary>
    private static bool IsAutoForeground(Color c) => c == Colors.Black;

    private static int LowerBound(double[] sortedOffsets, double value)
    {
        var lo = 0;
        var hi = sortedOffsets.Length;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (sortedOffsets[mid] < value) { lo = mid + 1; }
            else { hi = mid; }
        }
        return Math.Max(0, lo - 1);
    }
}
