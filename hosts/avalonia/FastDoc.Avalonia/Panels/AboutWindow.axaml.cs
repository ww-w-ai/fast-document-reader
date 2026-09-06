using System.Reflection;
using Avalonia.Controls;
using Avalonia.Input;

namespace FastDoc.Avalonia.Panels;

/// <summary>
/// S9-B3 batch 8: Help > About FastDoc, mirroring AppDelegate.swift's About window on macOS.
/// Non-modal, same choice every other S9-B* window in this folder made
/// (<see cref="ShortcutGuideWindow"/>, <see cref="FirstRunWindow"/>, <see cref="GoToLineWindow"/>).
/// All the actual field VALUES come from <see cref="AboutModel"/> so a headless test can check them
/// without constructing a Window.
/// </summary>
public partial class AboutWindow : Window
{
    public AboutWindow()
    {
        InitializeComponent();
        var assembly = Assembly.GetExecutingAssembly();
        AppNameText.Text = AboutModel.AppName;
        VersionText.Text = $"Version {AboutModel.ProductVersion(assembly)}";
        EngineVersionText.Text = AboutModel.EngineVersionNote;
        LicenceText.Text = AboutModel.LicenceLine;
    }

    private void OnCloseClicked(object? sender, global::Avalonia.Interactivity.RoutedEventArgs e) => Close();

    private void OnWindowKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            e.Handled = true;
            Close();
        }
    }
}
