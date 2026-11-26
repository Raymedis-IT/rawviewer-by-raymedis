using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Styling;

namespace Raymedis.RawViewer;

public sealed class App : Application
{
    public override void Initialize()
    {
        RequestedThemeVariant = ThemeVariant.Dark;
        Resources["SystemAccentColor"] = Avalonia.Media.Color.Parse("#F36F21");
        Styles.Add(new Avalonia.Themes.Fluent.FluentTheme());
        Styles.Add(new Avalonia.Styling.Style(x => x.OfType<Avalonia.Controls.Button>())
        {
            Setters =
            {
                new Avalonia.Styling.Setter(Avalonia.Controls.Button.HorizontalContentAlignmentProperty, Avalonia.Layout.HorizontalAlignment.Center),
                new Avalonia.Styling.Setter(Avalonia.Controls.Button.VerticalContentAlignmentProperty, Avalonia.Layout.VerticalAlignment.Center)
            }
        });
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.MainWindow = new MainWindow();
        }
        base.OnFrameworkInitializationCompleted();
    }
}
