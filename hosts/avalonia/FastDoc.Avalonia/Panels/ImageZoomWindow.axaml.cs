using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media.Imaging;

namespace FastDoc.Avalonia.Panels;

/// <summary>
/// S9-B3 batch 6 (#45, mirrors DiagramZoomWindow.swift on macOS): the enlarged view a click on a
/// diagram/formula/image opens (<c>FlowDocumentView.ImageClicked</c>). Scope disclosed narrower
/// than the macOS window: Ctrl/Cmd +/-/0 zoom and Esc close are implemented; drag-to-pan and a
/// trackpad pinch gesture are NOT (macOS's own pinch is invariant 32's own "not built for this
/// host" case — Avalonia's pointer-gesture API for pinch is the same one that invariant already
/// says is out of scope; drag-to-pan is subsumed by the <see cref="ScrollViewer"/> in the AXAML,
/// which already lets a reader scroll an image bigger than the window with a mouse wheel/scrollbar).
/// Parameterless constructor + <see cref="Configure"/>, matching <see cref="GoToLineWindow"/>'s own
/// AVLN3001 rationale.
/// </summary>
public partial class ImageZoomWindow : Window
{
    private Bitmap? _bitmap;
    private double _zoom = 1.0;

    private const double MinZoom = 0.1;
    private const double MaxZoom = 8.0;
    private const double ZoomStep = 1.25;

    public ImageZoomWindow()
    {
        InitializeComponent();
    }

    /// <summary>Must be called once, immediately after construction, before this window is shown.</summary>
    public void Configure(Bitmap bitmap)
    {
        _bitmap = bitmap;
        ZoomedImage.Source = bitmap;
        ApplyZoom();
    }

    private void ApplyZoom()
    {
        if (_bitmap is null) { return; }
        ZoomedImage.Width = _bitmap.PixelSize.Width * _zoom;
        ZoomedImage.Height = _bitmap.PixelSize.Height * _zoom;
    }

    private void OnWindowKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            e.Handled = true;
            Close();
            return;
        }

        var isAccel = e.KeyModifiers.HasFlag(KeyModifiers.Control) || e.KeyModifiers.HasFlag(KeyModifiers.Meta);
        if (!isAccel) { return; }

        if (e.Key == Key.OemPlus || e.Key == Key.Add)
        {
            e.Handled = true;
            _zoom = System.Math.Min(MaxZoom, _zoom * ZoomStep);
            ApplyZoom();
        }
        else if (e.Key == Key.OemMinus || e.Key == Key.Subtract)
        {
            e.Handled = true;
            _zoom = System.Math.Max(MinZoom, _zoom / ZoomStep);
            ApplyZoom();
        }
        else if (e.Key == Key.D0 || e.Key == Key.NumPad0)
        {
            e.Handled = true;
            _zoom = 1.0;
            ApplyZoom();
        }
    }
}
