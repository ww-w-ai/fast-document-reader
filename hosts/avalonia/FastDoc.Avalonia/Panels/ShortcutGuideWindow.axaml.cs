using Avalonia.Controls;
using Avalonia.Input;

namespace FastDoc.Avalonia.Panels;

/// <summary>
/// S9-B2: the "?" Keyboard Shortcuts window — mirrors the macOS app's own Keyboard Shortcuts
/// window (opened by "?", also reachable from the menu). Content comes entirely from
/// <see cref="ShortcutGuideModel.Build"/>; this class only wires the model into an
/// <see cref="ItemsControl"/> and closes on Esc. Non-modal (<c>Show(owner)</c>, never
/// <c>ShowDialog</c>) so the reader keeps using the document underneath while this is open —
/// same choice <see cref="FirstRunWindow"/> made and for the same reason.
/// </summary>
public partial class ShortcutGuideWindow : Window
{
    public ShortcutGuideWindow()
    {
        InitializeComponent();
        GroupsList.ItemsSource = ShortcutGuideModel.Build();

        // S9-B2 VM follow-up: on a short display (measured on Ubuntu/GNOME) every group did not
        // fit inside the old fixed Height="480" and there was nothing to scroll it with. The AXAML
        // now sizes to content instead; this caps that growth at ~90% of the screen's own working
        // area so the ScrollViewer inside takes over rather than the window overrunning the
        // screen. Screens.Primary is null in the headless test platform (no real display), so this
        // is a no-op there -- ShortcutGuideModel.ComputeMaxHeight itself is what a test drives.
        if (Screens?.Primary is { } screen)
        {
            MaxHeight = ShortcutGuideModel.ComputeMaxHeight(screen.WorkingArea.Height, screen.Scaling);
        }
    }

    private void OnWindowKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            e.Handled = true;
            Close();
        }
    }
}
