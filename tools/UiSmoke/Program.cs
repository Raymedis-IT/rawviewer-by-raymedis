using System.Reflection;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Controls.Presenters;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Avalonia.VisualTree;
using Raymedis.RawViewer;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        var lifetime = new ClassicDesktopStyleApplicationLifetime();
        AppBuilder.Configure<App>().UsePlatformDetect().WithInterFont().SetupWithLifetime(lifetime);
        Dispatcher.UIThread.Post(async () =>
        {
            try { await Check(lifetime.MainWindow!); lifetime.Shutdown(0); }
            catch (Exception error) { Console.Error.WriteLine(error); lifetime.Shutdown(1); }
        });
        return lifetime.Start(args);
    }

    private static async Task Check(Window window)
    {
        var output = Path.GetFullPath(".build/ui-smoke");
        Directory.CreateDirectory(output);
        var sample = Path.Combine(output, "2500x3052_corrected_very_long_detector_image_filename.raw");
        var pixels = new byte[2500 * 3052];
        for (var x = 0; x < 2500; x++) pixels[x] = (byte)(x * 255 / 2499);
        for (var y = 1; y < 3052; y++) Array.Copy(pixels, 0, pixels, y * 2500, 2500);
        File.WriteAllBytes(sample, pixels);
        window.WindowState = WindowState.Normal;
        window.Position = new PixelPoint(0, 0);
        foreach (var size in new[] { (640, 480), (800, 600), (1024, 768), (1366, 768), (1920, 1080) })
        {
            window.Width = size.Item1;
            window.Height = size.Item2;
            await Task.Delay(300);
            CheckButtons(window);
            window.GetType().GetMethod("SetFiles", BindingFlags.Instance | BindingFlags.NonPublic)!
                .Invoke(window, new object[] { new[] { sample } });
            await Task.Delay(600);
            CheckButtons(window);
            var title = (TextBlock)window.GetType().GetField("_fileTitle", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(window)!;
            var gallery = (StackPanel)window.GetType().GetField("_gallery", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(window)!;
            var name = gallery.GetVisualDescendants().OfType<TextBlock>().First(t => t.Text!.Contains("corrected"));
            if (name.Bounds.Width <= 0 || name.Bounds.Width > gallery.Bounds.Width - 70)
                throw new Exception($"Gallery filename has no bounded text column: {name.Bounds}");
            if (title.Bounds.Width <= 0) throw new Exception("Filename toolbar collapsed.");
            var preview = (Image)window.GetType().GetField("_preview", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(window)!;
            if (preview.Source is null) throw new Exception("Sample RAW did not render.");
            using var bitmap = new RenderTargetBitmap(new PixelSize((int)window.Bounds.Width, (int)window.Bounds.Height));
            bitmap.Render(window);
            bitmap.Save(Path.Combine(output, $"layout-{size.Item1}x{size.Item2}.png"), PngBitmapEncoderOptions.Default);
            Console.WriteLine($"PASS {size.Item1}x{size.Item2}: centered buttons, visible controls, bounded filenames, RAW rendered (client {window.ClientSize}).");
        }
        var unknown = Path.Combine(output, "unknown-size.raw");
        File.WriteAllBytes(unknown, new byte[37 * 19 * 2 + 128]);
        window.GetType().GetMethod("SetFiles", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(window, new object[] { new[] { unknown } });
        await Task.Delay(400);
        var import = ((IClassicDesktopStyleApplicationLifetime)Application.Current!.ApplicationLifetime!).Windows.Single(w => w.Title == "Choose RAW image format");
        var fields = import.GetVisualDescendants().OfType<TextBox>().ToArray();
        fields.Single(f => f.Name == "ImageWidth").Text = "37";
        fields.Single(f => f.Name == "ImageHeight").Text = "19";
        fields.Single(f => f.Name == "HeaderBytes").Text = "128";
        using (var bitmap = new RenderTargetBitmap(new PixelSize((int)import.Bounds.Width, (int)import.Bounds.Height)))
        {
            bitmap.Render(import); bitmap.Save(Path.Combine(output, "RawImportWindow.png"), PngBitmapEncoderOptions.Default);
        }
        import.GetVisualDescendants().OfType<Button>().Single(b => b.Content as string == "Open image")
            .RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        await Task.Delay(400);
        var current = window.GetType().GetField("_current", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(window)!;
        if (current is null || (int)current.GetType().GetProperty("Width")!.GetValue(current)! != 37) throw new Exception("Custom RAW import failed.");
        Console.WriteLine("PASS unknown dimensions: import dialog accepts 37x19, 16-bit, 128-byte header and displays frame.");
        foreach (var typeName in new[] { "Raymedis.RawViewer.ExportSettingsWindow", "Raymedis.RawViewer.RawSettingsWindow" })
        {
            var type = typeof(App).Assembly.GetType(typeName)!;
            var dialog = (Window)Activator.CreateInstance(type, typeName.Contains("RawSettings") ? new object?[] { 2500, 3052, null, null } : Array.Empty<object>())!;
            dialog.Show(window);
            await Task.Delay(300);
            foreach (var button in dialog.GetVisualDescendants().OfType<Button>().Where(b => b.GetType() == typeof(Button) && b.Content is string))
                if (button.HorizontalContentAlignment != Avalonia.Layout.HorizontalAlignment.Center || button.VerticalContentAlignment != Avalonia.Layout.VerticalAlignment.Center)
                    throw new Exception($"Dialog button not centered: {button.Content}");
            using var bitmap = new RenderTargetBitmap(new PixelSize((int)dialog.Bounds.Width, (int)dialog.Bounds.Height));
            bitmap.Render(dialog);
            bitmap.Save(Path.Combine(output, type.Name + ".png"), PngBitmapEncoderOptions.Default);
            Console.WriteLine($"PASS {type.Name}: dialog rendered and button alignment checked.");
            dialog.Close();
        }
    }

    private static void CheckButtons(Window window)
    {
        foreach (var button in window.GetVisualDescendants().OfType<Button>().Where(b => b.IsEffectivelyVisible && b.Content is not null))
        {
            var origin = button.TranslatePoint(default, window)!.Value;
            if (origin.X < -1 || origin.Y < -1 || origin.X + button.Bounds.Width > window.ClientSize.Width + 1 || origin.Y + button.Bounds.Height > window.ClientSize.Height + 1)
                throw new Exception($"Button outside window: {button.Content}, {origin}, {button.Bounds}");
            if (button.Content is Control content)
            {
                var point = content.TranslatePoint(default, button)!.Value;
                if (Math.Abs(point.Y + content.Bounds.Height / 2 - button.Bounds.Height / 2) > 1.5 ||
                    Math.Abs(point.X + content.Bounds.Width / 2 - button.Bounds.Width / 2) > 1.5)
                    throw new Exception($"Button content is not centered: {button.Content}, {point}, {content.Bounds}");
            }
        }
    }
}
