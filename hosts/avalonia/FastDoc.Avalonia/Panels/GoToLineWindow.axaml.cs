using Avalonia.Controls;
using Avalonia.Input;
using FastDoc.Avalonia.Rendering;

namespace FastDoc.Avalonia.Panels;

/// <summary>
/// S9-B3 batch 3: View > "Go to Line…" (Ctrl+L), mirroring DocumentWindowController.swift's Go to
/// Line dialog on macOS (flow mode only — see <see cref="LineNumberModel"/>'s own doc for why page
/// mode is out of this batch's scope). Non-modal like <see cref="ShortcutGuideWindow"/> and
/// <see cref="FirstRunWindow"/> — the reader keeps the document visible underneath while typing.
/// All the validation logic lives in <see cref="GoToLineModel.Validate"/> so it is testable without
/// a live window; this class only wires that result into the TextBox/error label and, on success,
/// calls <see cref="FlowDocumentView.ScrollToLineNumber"/> and closes itself.
///
/// Parameterless constructor + <see cref="Configure"/>, matching <see cref="ShortcutGuideWindow"/>/
/// <see cref="FirstRunWindow"/>'s own shape (a Window subclass with a constructor PARAMETER makes
/// the compiled XAML unreachable via the avares:// loader — AVLN3001 — since that loader always
/// calls the default constructor).
/// </summary>
public partial class GoToLineWindow : Window
{
    private FlowDocumentView? _canvas;

    public GoToLineWindow()
    {
        InitializeComponent();
    }

    /// <summary>Must be called once, immediately after construction, before this window is shown.</summary>
    public void Configure(FlowDocumentView canvas)
    {
        _canvas = canvas;
        var maxLine = canvas.LineNumberCount;
        PromptText.Text = $"Line number (1-{maxLine}):";
        LineNumberBox.PlaceholderText = maxLine > 0 ? maxLine.ToString() : "1";
    }

    private void OnCancelClicked(object? sender, global::Avalonia.Interactivity.RoutedEventArgs e) => Close();

    private void OnGoClicked(object? sender, global::Avalonia.Interactivity.RoutedEventArgs e) => TryGo();

    private void TryGo()
    {
        if (_canvas is null) { return; } // Configure() was not called — see this class's own doc
        var (lineNumber, error) = GoToLineModel.Validate(LineNumberBox.Text, _canvas.LineNumberCount);
        if (error is not null)
        {
            ErrorText.Text = error;
            ErrorText.IsVisible = true;
            return;
        }
        _canvas.ScrollToLineNumber(lineNumber);
        _canvas.Focus();
        Close();
    }

    private void OnWindowKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            e.Handled = true;
            Close();
        }
        else if (e.Key == Key.Enter)
        {
            e.Handled = true;
            TryGo();
        }
    }
}
