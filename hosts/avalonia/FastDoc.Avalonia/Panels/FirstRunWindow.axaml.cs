using Avalonia.Controls;
using Avalonia.Interactivity;
using FastDoc.Avalonia.Open;

namespace FastDoc.Avalonia.Panels;

/// <summary>
/// The first-run guide (S8-B2 item ②): shown once, non-modal, on the first GUI launch — what the
/// app opens, and where "Set as Default App…" lives. Two lines rather than the macOS app's
/// two-STEP wizard (Sources/FastDocReader/App/WelcomeWindow.swift): that app's step split exists
/// because ITS default-app claim is a whole picker UI worth a second screen; this host's default-
/// app action is one menu item, so one screen naming both facts carries the same intent (a reader
/// who has never launched this before does not know to look for either) without the extra step.
///
/// Non-modal by design (<c>Show(owner)</c>, never <c>ShowDialog</c>) — the reader can dismiss it
/// and keep using the window underneath, matching this task's "non-modal panel or dialog" spec.
/// </summary>
public partial class FirstRunWindow : Window
{
    public FirstRunWindow()
    {
        InitializeComponent();
    }

    private void OnCloseClicked(object? sender, RoutedEventArgs e)
    {
        if (DontShowAgainCheckBox.IsChecked == true)
        {
            FirstRunNotice.MarkShown();
        }
        Close();
    }
}
