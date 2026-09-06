using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Layout;
using Avalonia.Markup.Xaml;
using Avalonia.Media;

namespace FastDoc.Avalonia;

public partial class App : Application
{
    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            // Program.EngineMissingDetail is set only when FastdocEngine.EnsureLoadable
            // already failed before this point — MainWindow's very first engine call would fault
            // immediately, so this shows a plain error window naming the paths tried instead
            // (docs/studio/sprints/S6/s6e-error-surface.md scenarios 3a/3b: previously an
            // unhandled exception with no window at all).
            desktop.MainWindow = Program.EngineMissingDetail is { } detail
                ? BuildEngineMissingWindow(detail)
                : new MainWindow();
        }

        base.OnFrameworkInitializationCompleted();
    }

    private static Window BuildEngineMissingWindow(string detail)
    {
        var closeButton = new Button { Content = "Close", HorizontalAlignment = HorizontalAlignment.Right };
        var window = new Window
        {
            Title = "FastDoc",
            Width = 520,
            Height = 260,
            CanResize = false,
            Content = new StackPanel
            {
                Margin = new Thickness(20),
                Spacing = 16,
                Children =
                {
                    new TextBlock
                    {
                        TextWrapping = TextWrapping.Wrap,
                        Text = "FastDoc could not find a required component (the engine library) " +
                            "and cannot continue.\n\n" + detail + "\n\nPlease reinstall the application.",
                    },
                    closeButton,
                },
            },
        };
        closeButton.Click += (_, _) => window.Close();
        return window;
    }
}