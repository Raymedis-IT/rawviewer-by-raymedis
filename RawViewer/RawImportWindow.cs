using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;

namespace Raymedis.RawViewer;

internal sealed class RawImportWindow : Window
{
    public RawImportWindow(string path)
    {
        var length = new FileInfo(path).Length;
        Title = "Choose RAW image format";
        Width = 540; SizeToContent = SizeToContent.Height; MaxHeight = 620;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var panel = new StackPanel { Margin = new Thickness(24), Spacing = 10 };
        panel.Children.Add(new TextBlock { Text = System.IO.Path.GetFileName(path), FontWeight = FontWeight.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        panel.Children.Add(new TextBlock { Text = $"{length:N0} bytes · This RAW file has no known dimensions. Choose a suggestion or enter its format. Suggestions match the file size; they are not confirmed image dimensions.", TextWrapping = TextWrapping.Wrap });
        var suggestions = new ComboBox { ItemsSource = RawFormat.Suggestions(length), HorizontalAlignment = HorizontalAlignment.Stretch, PlaceholderText = "File-size suggestions" };
        panel.Children.Add(suggestions);
        var width = new TextBox { Name = "ImageWidth", PlaceholderText = "Width in pixels" };
        var height = new TextBox { Name = "ImageHeight", PlaceholderText = "Height in pixels" };
        var depth = new ComboBox { ItemsSource = new[] { "8-bit unsigned", "16-bit unsigned, little endian" }, SelectedIndex = 1, HorizontalAlignment = HorizontalAlignment.Stretch };
        var header = new TextBox { Name = "HeaderBytes", Text = "0" };
        foreach (var (label, control) in new (string, Control)[] { ("Width", width), ("Height", height), ("Pixel format", depth), ("Header bytes to skip", header) })
        {
            panel.Children.Add(new TextBlock { Text = label }); panel.Children.Add(control);
        }
        suggestions.SelectionChanged += (_, _) =>
        {
            if (suggestions.SelectedItem is not RawFormat format) return;
            width.Text = format.Width.ToString(); height.Text = format.Height.ToString();
            depth.SelectedIndex = format.BitDepth == 8 ? 0 : 1; header.Text = format.HeaderBytes.ToString();
        };
        var error = new TextBlock { Foreground = MainWindow.Brush("#FFAD80"), TextWrapping = TextWrapping.Wrap };
        panel.Children.Add(error);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 10 };
        var cancel = new Button { Content = "Cancel", MinWidth = 88 };
        var open = new Button { Content = "Open image", MinWidth = 110, Background = MainWindow.Brush("#F36F21"), Foreground = Brushes.White };
        cancel.Click += (_, _) => Close(null);
        open.Click += (_, _) =>
        {
            if (!int.TryParse(width.Text, out var w) || !int.TryParse(height.Text, out var h) || !int.TryParse(header.Text, out var offset))
            { error.Text = "Enter whole numbers for width, height, and header bytes."; return; }
            var format = new RawFormat(w, h, depth.SelectedIndex == 0 ? 8 : 16, offset);
            if (!format.Matches(length))
            { error.Text = "This format does not match the file size. Check the dimensions, bit depth, and header bytes."; return; }
            Close(format);
        };
        buttons.Children.Add(cancel); buttons.Children.Add(open); panel.Children.Add(buttons);
        Content = new ScrollViewer { Content = panel, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }
}
