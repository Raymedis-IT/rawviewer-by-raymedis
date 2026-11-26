using System.Globalization;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Platform.Storage;
using Avalonia.Threading;

namespace Raymedis.RawViewer;

internal sealed class MainWindow : Window
{
    private static readonly Color Orange = Color.Parse("#F36F21");
    private static readonly Color Panel = Color.Parse("#242424");
    private static readonly Color Raised = Color.Parse("#303030");
    private static readonly Color Muted = Color.Parse("#A7A7A7");
    private readonly Grid _root = new();
    private Grid _body = null!, _header = null!, _toolbar = null!;
    private Control _headerActions = null!, _toolbarActions = null!, _brand = null!, _details = null!;
    private readonly StackPanel _gallery = new();
    private readonly TextBlock _galleryCount = new();
    private readonly TextBlock _fileTitle = new();
    private readonly TextBlock _fileInfo = new();
    private readonly TextBlock _status = new();
    private readonly TextBlock _zoomText = new();
    private readonly StackPanel _emptyPanel = new() { HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center,
        VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center, Spacing = 12 };
    private readonly Image _preview = new() { Stretch = Stretch.Uniform, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center,
        VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center, RenderTransformOrigin = RelativePoint.Center };
    private readonly ScaleTransform _scale = new(1, 1);
    private readonly Slider _level = new() { Minimum = 0, Maximum = 65535 };
    private readonly Slider _width = new() { Minimum = 1, Maximum = 65535, Value = 65535 };
    private readonly TextBlock _levelValue = new();
    private readonly TextBlock _widthValue = new();
    private readonly List<string> _files = new();
    private readonly List<Border> _cards = new();
    private int _selected = -1;
    private int _imageWidth;
    private int _imageHeight;
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string, RawFormat> _formats = new(StringComparer.OrdinalIgnoreCase);
    private int? _bitDepth;
    private int? _headerBytes;
    private int _generation;
    private int _renderGeneration;
    private CancellationTokenSource? _renderCancellation;
    private RawImage? _current;
    private double _center = 32768;
    private double _windowWidth = 65535;
    private bool _inverted;
    private double _zoom = 1;
    private bool _updatingSliders;

    public MainWindow()
    {
        Title = "RAW Viewer by Raymedis";
        using (var iconStream = AssetLoader.Open(new Uri("avares://RAW Viewer by Raymedis/Assets/Raymedis.ico")))
            Icon = new WindowIcon(iconStream);
        Width = 1440;
        Height = 900;
        MinWidth = 640;
        MinHeight = 480;
        WindowState = WindowState.Maximized;
        Background = Brush("#111111");
        Foreground = Brushes.White;
        FontFamily = new FontFamily("Inter, Segoe UI, Arial");
        Content = BuildLayout();
        SizeChanged += (_, _) => UpdateResponsiveLayout();
        UpdateResponsiveLayout();
        KeyDown += HandleKey;
        _preview.RenderTransform = _scale;
        _level.ValueChanged += (_, _) => SliderChanged(true);
        _width.ValueChanged += (_, _) => SliderChanged(false);
        RefreshInfo();
    }

    private Control BuildLayout()
    {
        _root.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
        _root.RowDefinitions.Add(new RowDefinition(1, GridUnitType.Star));
        _root.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
        _root.Children.Add(BuildHeader());
        var body = _body = new Grid { ColumnDefinitions = new ColumnDefinitions("280, *"), ClipToBounds = true };
        body.Children.Add(BuildGallery());
        var viewer = BuildViewer();
        Grid.SetColumn(viewer, 1);
        body.Children.Add(viewer);
        Grid.SetRow(body, 1);
        _root.Children.Add(body);
        _status.TextTrimming = TextTrimming.CharacterEllipsis;
        ToolTip.SetTip(_status, new TextBlock { [!TextBlock.TextProperty] = _status[!TextBlock.TextProperty], MaxWidth = 520, TextWrapping = TextWrapping.Wrap });
        var statusBar = new Border { Background = Brush("#191919"), Padding = new Thickness(18, 7), Child = _status };
        Grid.SetRow(statusBar, 2);
        _root.Children.Add(statusBar);
        return _root;
    }

    private Control BuildHeader()
    {
        var bar = _header = new Grid { ColumnDefinitions = new ColumnDefinitions("*, Auto"), RowDefinitions = new RowDefinitions("Auto, Auto"), Background = Brush("#171717"), MinHeight = 72 };
        var brand = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 14, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
            Margin = new Thickness(22, 12) };
        try
        {
            using var stream = AssetLoader.Open(new Uri("avares://RAW Viewer by Raymedis/Assets/RaymedisLogo.png"));
            brand.Children.Add(new Image { Source = new Bitmap(stream), Width = 146, Height = 38, Stretch = Stretch.Uniform, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center });
        }
        catch { brand.Children.Add(new TextBlock { Text = "Raymedis", FontSize = 21, FontWeight = FontWeight.Bold, Foreground = Brush("#F36F21") }); }
        brand.Children.Add(new Border { Width = 1, Height = 32, Background = Brush("#404040"), Margin = new Thickness(2, 0) });
        brand.Children.Add(new StackPanel { VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center, Spacing = 1, Children =
        {
            new TextBlock { Text = "RAW VIEWER", FontSize = 14, FontWeight = FontWeight.Bold },
            new TextBlock { Text = "Detector image tools", FontSize = 12, Foreground = Brush("#A7A7A7") }
        }});
        bar.Children.Add(brand);
        _brand = brand;

        var actions = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 9, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
            Margin = new Thickness(10, 12, 18, 12) };
        actions.Children.Add(ActionButton("Open files", OpenFiles, "Choose one or more RAW images"));
        actions.Children.Add(ActionButton("Open folder", OpenFolder, "Browse a folder as a gallery"));
        actions.Children.Add(ActionButton("⚙", ShowSettings, "RAW dimensions and storage format"));
        actions.Children.Add(ActionButton("Export", Export, "Export the current image or the gallery", true));
        Grid.SetColumn(actions, 1);
        _headerActions = actions;
        bar.Children.Add(actions);
        return bar;
    }

    private Control BuildGallery()
    {
        var side = new Border { Background = Brush("#232323"), BorderBrush = Brush("#343434"), BorderThickness = new Thickness(0, 0, 1, 0) };
        var layout = new Grid { RowDefinitions = new RowDefinitions("Auto, *") };
        var heading = new Grid { ColumnDefinitions = new ColumnDefinitions("*, Auto"), Margin = new Thickness(16, 15, 16, 10) };
        heading.Children.Add(new TextBlock { Text = "IMAGES", FontSize = 12, FontWeight = FontWeight.Bold, Foreground = Brush("#B4B4B4"), VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center });
        _galleryCount.Text = "0";
        _galleryCount.Foreground = Brush("#A7A7A7");
        Grid.SetColumn(_galleryCount, 1); heading.Children.Add(_galleryCount);
        layout.Children.Add(heading);
        var scroller = new ScrollViewer { Content = _gallery, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(10, 0, 10, 12) };
        Grid.SetRow(scroller, 1); layout.Children.Add(scroller);
        side.Child = layout;
        return side;
    }

    private Control BuildViewer()
    {
        var view = new Grid { RowDefinitions = new RowDefinitions("Auto, *, Auto") };
        view.Children.Add(BuildImageToolbar());
        var imageSurface = new Border { Background = Brush("#070707"), Padding = new Thickness(18), ClipToBounds = true };
        _preview.HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Stretch;
        _preview.VerticalAlignment = Avalonia.Layout.VerticalAlignment.Stretch;
        var stage = new Grid();
        stage.Children.Add(_preview);
        _emptyPanel.Children.Add(new TextBlock { Text = "Open RAW images", FontSize = 22, FontWeight = FontWeight.SemiBold,
            HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center });
        _emptyPanel.Children.Add(new TextBlock { Text = "Choose files or a folder to browse and export.", Foreground = Brush("#A7A7A7"),
            HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center, FontSize = 13 });
        var emptyActions = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 9,
            HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center };
        emptyActions.Children.Add(ActionButton("Open files", OpenFiles, "Choose RAW files"));
        emptyActions.Children.Add(ActionButton("Open folder", OpenFolder, "Browse a RAW folder"));
        _emptyPanel.Children.Add(emptyActions);
        stage.Children.Add(_emptyPanel);
        imageSurface.Child = stage;
        Grid.SetRow(imageSurface, 1); view.Children.Add(imageSurface);
        var controls = BuildWindowControls();
        Grid.SetRow(controls, 2); view.Children.Add(controls);
        return view;
    }

    private Control BuildImageToolbar()
    {
        var bar = _toolbar = new Grid { ColumnDefinitions = new ColumnDefinitions("*, Auto"), RowDefinitions = new RowDefinitions("Auto, Auto"), Background = Brush("#252525"), MinHeight = 66 };
        var details = new StackPanel { Margin = new Thickness(18, 9), VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center, Spacing = 4 };
        _fileTitle.Text = "Open a RAW image or folder";
        _fileTitle.FontWeight = FontWeight.SemiBold;
        _fileTitle.TextTrimming = TextTrimming.CharacterEllipsis;
        _fileInfo.TextTrimming = TextTrimming.CharacterEllipsis;
        ToolTip.SetTip(_fileTitle, new TextBlock { [!TextBlock.TextProperty] = _fileTitle[!TextBlock.TextProperty], MaxWidth = 520, TextWrapping = TextWrapping.Wrap });
        _fileInfo.Text = "2500 × 3052   ·   8 / 16-bit   ·   Up/Down to browse";
        _fileInfo.Foreground = Brush("#ADADAD"); _fileInfo.FontSize = 12;
        details.Children.Add(_fileTitle); details.Children.Add(_fileInfo); bar.Children.Add(details);
        _details = details;
        var controls = new WrapPanel { Orientation = Avalonia.Layout.Orientation.Horizontal,
            VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center, Margin = new Thickness(6, 8, 13, 8) };
        controls.Children.Add(CompactButton("⤢", Fit, "Fit image to viewer"));
        controls.Children.Add(CompactButton("−", () => SetZoom(_zoom / 1.2), "Zoom out"));
        _zoomText.Text = "100%"; _zoomText.Width = 54; _zoomText.Height = 40; _zoomText.Padding = new Thickness(0, 11, 0, 0); _zoomText.TextAlignment = TextAlignment.Center;
        _zoomText.VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center; _zoomText.Foreground = Brush("#E0E0E0");
        controls.Children.Add(_zoomText);
        controls.Children.Add(CompactButton("+", () => SetZoom(_zoom * 1.2), "Zoom in"));
        controls.Children.Add(CompactButton("◐", ToggleInvert, "Invert grayscale"));
        controls.Children.Add(CompactButton("↻", ResetImage, "Reset window, zoom, and invert"));
        controls.Children.Add(CompactButton("↑", Previous, "Previous image (Up or Left)"));
        controls.Children.Add(CompactButton("↓", Next, "Next image (Down or Right)"));
        Grid.SetColumn(controls, 1); bar.Children.Add(controls);
        _toolbarActions = controls;
        return new Border { Background = Brush("#252525"), BorderBrush = Brush("#373737"),
            BorderThickness = new Thickness(0, 0, 0, 1), Child = bar };
    }

    private Control BuildWindowControls()
    {
        var panel = new Grid { RowDefinitions = new RowDefinitions("Auto, Auto"), Background = Brush("#262626") };
        AddSliderRow(panel, 0, "LEVEL", _level, _levelValue);
        AddSliderRow(panel, 1, "WIDTH", _width, _widthValue);
        _status.Text = "Ready · 8-bit and 16-bit RAW · arrows browse images, Shift + arrows adjust window";
        _status.Foreground = Brush("#A7A7A7"); _status.FontSize = 11;
        return new Border { Background = Brush("#262626"), Padding = new Thickness(19, 8, 19, 6), Child = panel };
    }

    private static void AddSliderRow(Grid parent, int row, string title, Slider slider, TextBlock value)
    {
        var line = new Grid { ColumnDefinitions = new ColumnDefinitions("60, *, 62"), MinHeight = 28 };
        var label = new TextBlock { Text = title, FontSize = 11, FontWeight = FontWeight.Bold, Foreground = Brush("#B7B7B7"),
            VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
        line.Children.Add(label);
        slider.Margin = new Thickness(8, 0);
        slider.VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center;
        Grid.SetColumn(slider, 1); line.Children.Add(slider);
        value.Text = "—"; value.TextAlignment = TextAlignment.Right; value.Foreground = Brush("#C6C6C6");
        value.VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center; value.FontSize = 12;
        Grid.SetColumn(value, 2); line.Children.Add(value);
        Grid.SetRow(line, row); parent.Children.Add(line);
    }

    private async void OpenFiles()
    {
        var options = new FilePickerOpenOptions { Title = "Open RAW images", AllowMultiple = true,
            FileTypeFilter = new[] { new FilePickerFileType("RAW images") { Patterns = new[] { "*.raw", "*.RAW" } }, FilePickerFileTypes.All } };
        var picked = await StorageProvider.OpenFilePickerAsync(options);
        SetFiles(picked.Select(file => file.Path.LocalPath));
    }

    private async void OpenFolder()
    {
        var picked = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = "Open a folder of RAW images", AllowMultiple = false });
        if (picked.Count == 0) return;
        var paths = await Task.Run(() => Directory.EnumerateFiles(picked[0].Path.LocalPath)
            .Where(path => Path.GetExtension(path).Equals(".raw", StringComparison.OrdinalIgnoreCase))
            .OrderBy(path => Path.GetFileName(path), StringComparer.OrdinalIgnoreCase).ToArray());
        SetFiles(paths);
    }

    private void SetFiles(IEnumerable<string> paths)
    {
        _files.Clear(); _files.AddRange(paths.Where(path => Path.GetExtension(path).Equals(".raw", StringComparison.OrdinalIgnoreCase))
            .OrderBy(path => Path.GetFileName(path), StringComparer.OrdinalIgnoreCase));
        _selected = -1; _current = null; _preview.Source = null; _gallery.Children.Clear(); _cards.Clear();
        _galleryCount.Text = _files.Count.ToString(CultureInfo.InvariantCulture);
        if (_files.Count == 0)
        {
            _emptyPanel.IsVisible = true;
            _fileTitle.Text = "Open a RAW image or folder";
            _fileInfo.Text = "Choose files or a folder to browse and export.";
            _status.Text = "No RAW images loaded."; RefreshInfo(); return;
        }
        _emptyPanel.IsVisible = false;
        for (var i = 0; i < _files.Count; i++) AddGalleryCard(i);
        Select(0);
        for (var i = 0; i < _files.Count; i++)
        {
            var index = i; var path = _files[i];
            _ = Task.Run(() =>
            {
                try
                {
                    var raw = ReadFrame(path);
                    var gray = raw.Thumbnail(raw.InitialCenter, raw.InitialWidth);
                    var (w, h) = ThumbnailSize(raw.Width, raw.Height, 144);
                    var bitmap = MakeBitmap(w, h, gray);
                    Dispatcher.UIThread.Post(() => { if (index < _cards.Count && _files[index] == path) FindThumb(_cards[index])!.Source = bitmap; });
                }
                catch { }
            });
        }
    }

    private void AddGalleryCard(int index)
    {
        var thumb = new Image { Width = 62, Height = 78, Stretch = Stretch.Uniform };
        var text = new TextBlock { Text = Path.GetFileNameWithoutExtension(_files[index]), FontSize = 12, FontWeight = FontWeight.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
        var order = new TextBlock { Text = (index + 1).ToString("00", CultureInfo.InvariantCulture), FontSize = 11, Foreground = Brush("#A8A8A8") };
        var labels = new StackPanel { Spacing = 6, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
        labels.Children.Add(text); labels.Children.Add(order);
        var content = new Grid { ColumnDefinitions = new ColumnDefinitions("62, *"), ClipToBounds = true };
        labels.Margin = new Thickness(11, 0, 0, 0);
        Grid.SetColumn(labels, 1);
        content.Children.Add(thumb); content.Children.Add(labels);
        var card = new Border { Padding = new Thickness(8), Margin = new Thickness(0, 4), CornerRadius = new CornerRadius(9),
            Background = Brush("#292929"), BorderBrush = Brush("#292929"), BorderThickness = new Thickness(1), Child = content,
            Cursor = new Cursor(StandardCursorType.Hand), ClipToBounds = true };
        ToolTip.SetTip(card, Path.GetFileName(_files[index]));
        card.PointerPressed += (_, _) => Select(index);
        _gallery.Children.Add(card); _cards.Add(card);
        if (index == _selected) StyleSelectedCard(index);
    }

    private async void Select(int index)
    {
        if (index < 0 || index >= _files.Count) return;
        _renderCancellation?.Cancel();
        _selected = index; _current = null; _preview.Source = null; _generation++;
        _emptyPanel.IsVisible = false;
        var generation = _generation; var path = _files[index];
        StyleSelectedCard(index);
        _fileTitle.Text = Path.GetFileName(path); _fileInfo.Text = "Loading RAW frame…";
        _status.Text = "Loading image…";
        try
        {
            var frame = await LoadFrame(path);
            if (generation != _generation) return;
            if (frame is null)
            {
                _fileInfo.Text = "Image format not selected";
                _status.Text = "Select this image again to choose its RAW format.";
                return;
            }
            _current = frame; _center = _current.InitialCenter; _windowWidth = _current.InitialWidth;
            var (w, h) = ThumbnailSize(frame.Width, frame.Height, 144);
            FindThumb(_cards[index])!.Source = MakeBitmap(w, h, frame.Thumbnail(frame.InitialCenter, frame.InitialWidth));
            _inverted = false; Fit(); UpdateSliders(); RenderPreview(); RefreshInfo();
            _status.Text = $"Loaded {_current.Name} · {_current.Width:N0} × {_current.Height:N0} · {_current.BitDepth}-bit";
        }
        catch (Exception error)
        {
            if (generation != _generation) return;
            _fileInfo.Text = "RAW format could not be read";
            _status.Text = error.Message;
        }
    }

    private RawImage ReadFrame(string path)
    {
        if (_formats.TryGetValue(path, out var format))
            return RawImage.Read(path, format.Width, format.Height, format.BitDepth, format.HeaderBytes);
        return RawImage.Read(path, _imageWidth, _imageHeight, _bitDepth, _headerBytes);
    }

    private async Task<RawImage?> LoadFrame(string path)
    {
        try { return await Task.Run(() => ReadFrame(path)); }
        catch (InvalidDataException) { }
        catch (RawFormatRequiredException) { }
        var format = await new RawImportWindow(path).ShowDialog<RawFormat?>(this);
        if (format is null) return null;
        _formats[path] = format;
        return await Task.Run(() => ReadFrame(path));
    }

    private void StyleSelectedCard(int selected)
    {
        for (var i = 0; i < _cards.Count; i++)
        {
            _cards[i].Background = Brush(i == selected ? "#483326" : "#292929");
            _cards[i].BorderBrush = Brush(i == selected ? "#F36F21" : "#292929");
            _cards[i].BorderThickness = new Thickness(i == selected ? 2 : 1);
        }
    }

    private static Image? FindThumb(Border card) => (card.Child as Grid)?.Children.OfType<Image>().FirstOrDefault();

    private void RenderPreview()
    {
        if (_current is null) return;
        var generation = _generation;
        var renderGeneration = ++_renderGeneration;
        var center = _center; var width = _windowWidth; var inverted = _inverted;
        _status.Text = "Rendering…";
        var current = _current;
        _renderCancellation?.Cancel();
        _renderCancellation?.Dispose();
        _renderCancellation = new CancellationTokenSource();
        var token = _renderCancellation.Token;
        _ = Task.Run(async () =>
        {
            await Task.Delay(45, token);
            token.ThrowIfCancellationRequested();
            return MakeBitmap(current.Width, current.Height, current.ToGray(center, width, inverted));
        }, token)
            .ContinueWith(task => Dispatcher.UIThread.Post(() =>
            {
                if (generation != _generation || renderGeneration != _renderGeneration || task.IsFaulted || task.IsCanceled) return;
                _preview.Source = task.Result;
                if (_current is not null) _status.Text = $"{_current.Name} · {_current.BitDepth}-bit";
            }));
    }

    private void SliderChanged(bool isLevel)
    {
        if (_updatingSliders || _current is null) return;
        if (isLevel) _center = _level.Value; else _windowWidth = Math.Max(1, _width.Value);
        _levelValue.Text = Math.Round(_center).ToString("N0", CultureInfo.InvariantCulture);
        _widthValue.Text = Math.Round(_windowWidth).ToString("N0", CultureInfo.InvariantCulture);
        RenderPreview();
    }

    private void UpdateSliders()
    {
        if (_current is null) return;
        _updatingSliders = true;
        _level.Maximum = _current.MaxSample; _width.Maximum = _current.MaxSample;
        _level.Value = Math.Clamp(_center, 0, _current.MaxSample); _width.Value = Math.Clamp(_windowWidth, 1, _current.MaxSample);
        _levelValue.Text = Math.Round(_center).ToString("N0", CultureInfo.InvariantCulture);
        _widthValue.Text = Math.Round(_windowWidth).ToString("N0", CultureInfo.InvariantCulture);
        _updatingSliders = false;
    }

    private void ToggleInvert() { _inverted = !_inverted; RenderPreview(); }
    private void ResetImage()
    {
        if (_current is not null) { _center = _current.InitialCenter; _windowWidth = _current.InitialWidth; UpdateSliders(); }
        _inverted = false; Fit(); RenderPreview();
    }
    private void Fit() { SetZoom(1); }
    private void SetZoom(double zoom) { _zoom = Math.Clamp(zoom, 0.1, 6); _scale.ScaleX = _scale.ScaleY = _zoom; _zoomText.Text = $"{_zoom * 100:0}%"; }
    private void Previous() => Select(_selected - 1);
    private void Next() => Select(_selected + 1);

    private void HandleKey(object? sender, KeyEventArgs e)
    {
        var shift = e.KeyModifiers.HasFlag(KeyModifiers.Shift);
        if (shift)
        {
            var amount = Math.Max(1, (_current?.MaxSample ?? 65535) * 0.02);
            if (e.Key == Key.Left) { _center = Math.Max(0, _center - amount); UpdateSliders(); RenderPreview(); e.Handled = true; }
            else if (e.Key == Key.Right) { _center = Math.Min(_current?.MaxSample ?? 65535, _center + amount); UpdateSliders(); RenderPreview(); e.Handled = true; }
            else if (e.Key == Key.Up) { _windowWidth = Math.Max(1, _windowWidth - amount); UpdateSliders(); RenderPreview(); e.Handled = true; }
            else if (e.Key == Key.Down) { _windowWidth = Math.Min(_current?.MaxSample ?? 65535, _windowWidth + amount); UpdateSliders(); RenderPreview(); e.Handled = true; }
        }
        else if (e.Key is Key.Up or Key.Left) { Previous(); e.Handled = true; }
        else if (e.Key is Key.Down or Key.Right) { Next(); e.Handled = true; }
        else if (e.Key == Key.F) { Fit(); e.Handled = true; }
        else if (e.Key is Key.Add or Key.OemPlus) { SetZoom(_zoom * 1.2); e.Handled = true; }
        else if (e.Key is Key.Subtract or Key.OemMinus) { SetZoom(_zoom / 1.2); e.Handled = true; }
    }

    private async void ShowSettings()
    {
        var dialog = new RawSettingsWindow(_imageWidth, _imageHeight, _bitDepth, _headerBytes);
        var result = await dialog.ShowDialog<RawSettingsResult?>(this);
        if (result is null) return;
        _formats.Clear();
        _imageWidth = result.Width; _imageHeight = result.Height; _bitDepth = result.BitDepth; _headerBytes = result.HeaderBytes;
        if (_files.Count > 0) SetFiles(_files.ToArray());
    }

    private async void Export()
    {
        if (_files.Count == 0) { _status.Text = "Open RAW images before exporting."; return; }
        var options = await new ExportSettingsWindow().ShowDialog<ExportSettings?>(this);
        if (options is null) return;
        var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = "Choose export destination", AllowMultiple = false });
        if (folders.Count == 0) return;
        var folder = folders[0].Path.LocalPath;
        var targets = options.All ? _files.ToArray() : new[] { _files[_selected] };
        var currentCenter = _center; var currentWidth = _windowWidth; var inverted = _inverted;
        // Resolve every frame before writing output, including mixed-size folders.
        var exportFormats = new Dictionary<string, RawFormat>();
        try
        {
            foreach (var path in targets)
            {
                var frame = await LoadFrame(path);
                if (frame is null) { _status.Text = "Export canceled: image format was not selected."; return; }
                exportFormats[path] = new RawFormat(frame.Width, frame.Height, frame.BitDepth,
                    checked((int)(new FileInfo(path).Length - frame.Samples.Length)));
            }
        }
        catch (Exception error) { _status.Text = "Export failed · " + error.Message; return; }
        _status.Text = $"Exporting 0 of {targets.Length}…";
        _ = Task.Run(() =>
        {
            var study = NewUid(); var series = NewUid();
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            for (var i = 0; i < targets.Length; i++)
            {
                var format = exportFormats[targets[i]];
                var frame = RawImage.Read(targets[i], format.Width, format.Height, format.BitDepth, format.HeaderBytes);
                var center = options.All ? frame.InitialCenter : currentCenter;
                var windowWidth = options.All ? frame.InitialWidth : currentWidth;
                var extension = options.Format == "DICOM" ? ".dcm" : options.Format == "JPEG" ? ".jpg" : ".png";
                var baseName = Path.GetFileNameWithoutExtension(targets[i]);
                var candidate = baseName + extension;
                for (var suffix = 2; File.Exists(Path.Combine(folder, candidate)) || !names.Add(candidate); suffix++)
                    candidate = $"{baseName}_{suffix}{extension}";
                var destination = Path.Combine(folder, candidate);
                if (options.Format == "DICOM") frame.ExportDicom(destination, center, windowWidth, inverted, study, series, i + 1);
                else frame.ExportImage(destination, options.Format, center, windowWidth, inverted);
                var saved = i + 1;
                Dispatcher.UIThread.Post(() => _status.Text = $"Exporting {saved} of {targets.Length}…");
            }
            Dispatcher.UIThread.Post(() => _status.Text = $"Export complete · {targets.Length} file{(targets.Length == 1 ? "" : "s")} saved to {folder}");
        }).ContinueWith(task =>
        {
            if (!task.IsFaulted) return;
            Dispatcher.UIThread.Post(() => _status.Text = "Export failed · " + task.Exception?.GetBaseException().Message);
        });
    }

    private void RefreshInfo()
    {
        if (_current is null)
        {
            if (_selected < 0) { _fileTitle.Text = "Open a RAW image or folder"; _fileInfo.Text = _imageWidth == 0 ? "Automatic / per-image dimensions · 8 / 16-bit RAW" : $"{_imageWidth} × {_imageHeight}   ·   8 / 16-bit auto detect"; }
            return;
        }
        _fileTitle.Text = _current.Name;
        _fileInfo.Text = $"{_current.Width:N0} × {_current.Height:N0}   ·   {_current.BitDepth}-bit   ·   {_selected + 1} of {_files.Count}";
    }

    private static Button ActionButton(string title, Action action, string tip, bool primary = false)
    {
        var content = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 8,
            VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
        content.Children.Add(ToolIcon(title));
        if (title != "⚙") content.Children.Add(new TextBlock { Text = title, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center });
        var button = new Button { Content = content, MinWidth = title == "⚙" ? 40 : 112, Height = 40, Padding = new Thickness(title == "⚙" ? 10 : 12, 0),
            Background = Brush(primary ? "#F36F21" : "#323232"), Foreground = Brushes.White, BorderBrush = Brush(primary ? "#F36F21" : "#484848"),
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(9), FontWeight = FontWeight.SemiBold,
            HorizontalContentAlignment = Avalonia.Layout.HorizontalAlignment.Center,
            VerticalContentAlignment = Avalonia.Layout.VerticalAlignment.Center };
        Avalonia.Automation.AutomationProperties.SetName(button, title == "⚙" ? "RAW format settings" : title);
        ToolTip.SetTip(button, tip); button.Click += (_, _) => action(); return button;
    }

    private static Button CompactButton(string text, Action action, string tip)
    {
        var button = new Button { Content = ToolIcon(text), Width = 36, Height = 36, Padding = new Thickness(0), Margin = new Thickness(0, 2, 6, 2),
            Background = Brush("#363636"), Foreground = Brushes.White, BorderBrush = Brush("#484848"),
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), FontWeight = FontWeight.SemiBold,
            FontSize = 15, HorizontalContentAlignment = Avalonia.Layout.HorizontalAlignment.Center,
            VerticalContentAlignment = Avalonia.Layout.VerticalAlignment.Center };
        Avalonia.Automation.AutomationProperties.SetName(button, tip);
        ToolTip.SetTip(button, tip); button.Click += (_, _) => action(); return button;
    }

    internal static SolidColorBrush Brush(string hex) => new(Color.Parse(hex));

    // Fixed 24-unit vector viewports avoid OS/font-dependent glyph baselines.
    private static Control ToolIcon(string name)
    {
        var geometry = name switch
        {
            "Open files" => "M14,3 L6,3 L6,21 L18,21 L18,7 Z M14,3 L14,7 L18,7 M9,13 L15,13 M12,10 L12,16",
            "Open folder" => "M3,7 L3,20 L21,20 L21,7 Z M3,7 L3,4 L10,4 L13,7",
            "Export" => "M5,13 L5,21 L19,21 L19,13 M12,16 L12,3 M7,8 L12,3 L17,8",
            "⚙" => "M3,6 L8,6 M12,6 L21,6 M3,12 L14,12 M18,12 L21,12 M3,18 L6,18 M10,18 L21,18 M8,3 L12,3 L12,9 L8,9 Z M14,9 L18,9 L18,15 L14,15 Z M6,15 L10,15 L10,21 L6,21 Z",
            "⤢" => "M9,3 L3,3 L3,9 M3,3 L9,9 M15,21 L21,21 L21,15 M21,21 L15,15 M15,3 L21,3 L21,9 M21,3 L15,9 M9,21 L3,21 L3,15 M3,21 L9,15",
            "−" => "M5,12 L19,12",
            "+" => "M5,12 L19,12 M12,5 L12,19",
            "◐" => "M12,3 A9,9 0 1 1 12,21 A9,9 0 1 1 12,3 M12,3 L12,21 M15,5 L15,19 M18,7 L18,17",
            "↻" => "M20,10 A8,8 0 1 0 19,17 M20,3 L20,10 L13,10",
            "↑" => "M15,5 L8,12 L15,19",
            "↓" => "M9,5 L16,12 L9,19",
            _ => "M5,12 L19,12"
        };
        var canvas = new Canvas { Width = 24, Height = 24 };
        canvas.Children.Add(new Avalonia.Controls.Shapes.Path { Data = Geometry.Parse(geometry),
            Stroke = Brushes.White, StrokeThickness = 1.7, StrokeLineCap = PenLineCap.Round, StrokeJoin = PenLineJoin.Round });
        return new Viewbox { Width = 18, Height = 18, Child = canvas,
            HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
    }

    private void UpdateResponsiveLayout()
    {
        if (_body is null || _headerActions is null || _toolbarActions is null) return;
        var width = ClientSize.Width > 0 ? ClientSize.Width : Width;
        _body.ColumnDefinitions[0].Width = new GridLength(width < 800 ? 180 : width < 1100 ? 230 : 280);
        Reflow(_header, _brand, _headerActions, width < 950);
        Reflow(_toolbar, _details, _toolbarActions, width < 1200);
        _headerActions.HorizontalAlignment = width < 950 ? Avalonia.Layout.HorizontalAlignment.Left : Avalonia.Layout.HorizontalAlignment.Right;
        _toolbarActions.HorizontalAlignment = width < 1200 ? Avalonia.Layout.HorizontalAlignment.Left : Avalonia.Layout.HorizontalAlignment.Right;
    }

    private static void Reflow(Grid grid, Control leading, Control trailing, bool stacked)
    {
        grid.ColumnDefinitions[1].Width = stacked ? new GridLength(0) : GridLength.Auto;
        Grid.SetColumnSpan(leading, stacked ? 2 : 1);
        Grid.SetColumn(trailing, stacked ? 0 : 1);
        Grid.SetRow(trailing, stacked ? 1 : 0);
        Grid.SetColumnSpan(trailing, stacked ? 2 : 1);
    }

    private static (int Width, int Height) ThumbnailSize(int width, int height, int max)
    {
        var scale = Math.Min(1, max / (double)Math.Max(width, height));
        return (Math.Max(1, (int)Math.Round(width * scale)), Math.Max(1, (int)Math.Round(height * scale)));
    }

    private static WriteableBitmap MakeBitmap(int width, int height, byte[] grayscale)
    {
        var bitmap = new WriteableBitmap(new PixelSize(width, height), new Vector(96, 96), PixelFormat.Bgra8888, AlphaFormat.Opaque);
        var row = new byte[width * 4];
        using var locked = bitmap.Lock();
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var gray = grayscale[y * width + x]; var offset = x * 4;
                row[offset] = gray; row[offset + 1] = gray; row[offset + 2] = gray; row[offset + 3] = 255;
            }
            Marshal.Copy(row, 0, IntPtr.Add(locked.Address, y * locked.RowBytes), row.Length);
        }
        return bitmap;
    }

    private static string NewUid() => "2.25." + System.Numerics.BigInteger.Abs(new System.Numerics.BigInteger(Guid.NewGuid().ToByteArray())).ToString(CultureInfo.InvariantCulture);
}

internal sealed record ExportSettings(string Format, bool All);

internal sealed class ExportSettingsWindow : Window
{
    private readonly ComboBox _format = new() { ItemsSource = new[] { "PNG", "JPEG", "DICOM" }, SelectedIndex = 0, MinWidth = 180 };
    private readonly CheckBox _all = new() { Content = "Export all images in the gallery", IsChecked = true };
    public ExportSettingsWindow()
    {
        Title = "Export images"; Width = 390; SizeToContent = SizeToContent.Height; MaxHeight = 440; CanResize = false; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var panel = new StackPanel { Margin = new Thickness(24), Spacing = 14 };
        panel.Children.Add(new TextBlock { Text = "Export format", FontWeight = FontWeight.SemiBold });
        panel.Children.Add(_format);
        panel.Children.Add(_all);
        panel.Children.Add(new TextBlock { Text = "Choose a destination folder in the next step.", Foreground = MainWindow.Brush("#A7A7A7"), FontSize = 12 });
        var buttons = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right, Spacing = 9 };
        var cancel = new Button { Content = "Cancel", MinWidth = 88 }; cancel.Click += (_, _) => Close(null);
        var export = new Button { Content = "Continue", MinWidth = 96, Background = MainWindow.Brush("#F36F21"), Foreground = Brushes.White };
        export.Click += (_, _) => Close(new ExportSettings(_format.SelectedItem?.ToString() ?? "PNG", _all.IsChecked == true));
        buttons.Children.Add(cancel); buttons.Children.Add(export); panel.Children.Add(buttons);
        Content = new ScrollViewer { Content = panel, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }
}

internal sealed record RawSettingsResult(int Width, int Height, int? BitDepth, int? HeaderBytes);

internal sealed class RawSettingsWindow : Window
{
    private readonly TextBox _width = new(); private readonly TextBox _height = new();
    private readonly ComboBox _depth = new(); private readonly ComboBox _header = new();
    public RawSettingsWindow(int width, int height, int? depth, int? header)
    {
        Title = "RAW format settings"; Width = 430; SizeToContent = SizeToContent.Height; MaxHeight = 440; CanResize = false; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        _width.Text = width.ToString(CultureInfo.InvariantCulture); _height.Text = height.ToString(CultureInfo.InvariantCulture);
        _depth.ItemsSource = new[] { "Auto detect", "8-bit", "16-bit" }; _depth.SelectedIndex = depth == 8 ? 1 : depth == 16 ? 2 : 0;
        _header.ItemsSource = new[] { "Auto (0 or 200 bytes)", "No header", "200-byte header" }; _header.SelectedIndex = header == 0 ? 1 : header == 200 ? 2 : 0;
        var panel = new StackPanel { Margin = new Thickness(24), Spacing = 10 };
        var automatic = new CheckBox { Content = "Automatic / choose format for each image", IsChecked = width == 0 && height == 0 };
        void UpdateMode() { _width.IsEnabled = _height.IsEnabled = automatic.IsChecked != true; }
        automatic.IsCheckedChanged += (_, _) => UpdateMode(); UpdateMode();
        panel.Children.Add(automatic);
        panel.Children.Add(new TextBlock { Text = "Image width" }); panel.Children.Add(_width);
        panel.Children.Add(new TextBlock { Text = "Image height" }); panel.Children.Add(_height);
        panel.Children.Add(new TextBlock { Text = "Pixel depth" }); panel.Children.Add(_depth);
        panel.Children.Add(new TextBlock { Text = "Header bytes" }); panel.Children.Add(_header);
        panel.Children.Add(new TextBlock { Text = "Automatic mode reads dimensions such as 1024x768 from filenames when the file size matches. Other files ask for their format. Fixed dimensions are optional; each image can use a different format.",
            TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = MainWindow.Brush("#A7A7A7") });
        var save = new Button { Content = "Apply settings", Background = MainWindow.Brush("#F36F21"), Foreground = Brushes.White,
            HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right, MinWidth = 126 };
        save.Click += (_, _) =>
        {
            var w = 0; var h = 0;
            if (automatic.IsChecked != true && (!int.TryParse(_width.Text, out w) || !int.TryParse(_height.Text, out h) || w <= 0 || h <= 0)) return;
            var result = new RawSettingsResult(w, h, _depth.SelectedIndex switch { 1 => 8, 2 => 16, _ => null }, _header.SelectedIndex switch { 1 => 0, 2 => 200, _ => null });
            Close(result);
        };
        panel.Children.Add(save); Content = new ScrollViewer { Content = panel, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }
}
