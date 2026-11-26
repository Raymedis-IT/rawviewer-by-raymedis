using System.Buffers.Binary;
using System.Globalization;
using System.Numerics;
using System.Text;

namespace Raymedis.RawViewer;

internal sealed class RawImage
{
    public required string Path { get; init; }
    public required int Width { get; init; }
    public required int Height { get; init; }
    public required int BitDepth { get; init; }
    public required byte[] Samples { get; init; }
    public required double InitialCenter { get; init; }
    public required double InitialWidth { get; init; }
    public string Name => System.IO.Path.GetFileName(Path);
    public int MaxSample => BitDepth == 8 ? 255 : 65535;

    public static RawImage Read(string path, int width, int height, int? bitDepth = null, int? headerBytes = null)
    {
        var length = new FileInfo(path).Length;
        if (width == 0 && height == 0)
        {
            var detected = RawFormat.FromFileName(path, length, bitDepth, headerBytes);
            if (detected is null) throw new RawFormatRequiredException(path);
            width = detected.Width; height = detected.Height; bitDepth = detected.BitDepth; headerBytes = detected.HeaderBytes;
        }
        if (width <= 0 || height <= 0 || (long)width * height > int.MaxValue / 4)
            throw new InvalidDataException("Enter positive dimensions. This image is too large if its rendered buffer exceeds 2 GB.");
        if (headerBytes < 0) throw new InvalidDataException("Header size cannot be negative.");
        var data = File.ReadAllBytes(path);
        var pixels = checked(width * height);
        var depths = bitDepth.HasValue ? new[] { bitDepth.Value } : new[] { 16, 8 };
        var headers = headerBytes.HasValue ? new[] { headerBytes.Value } : new[] { 0, 200 };
        var format = (from depth in depths
                      from header in headers
                      where (depth == 8 || depth == 16) && pixels * (depth / 8) + header == data.Length
                      select (depth, header)).FirstOrDefault();
        if (format == default)
        {
            var expected = string.Join("; ", from depth in depths from header in headers select $"{width} × {height}, {depth}-bit, {header}-byte header: {(long)pixels * (depth / 8) + header:N0} bytes");
            throw new InvalidDataException($"{System.IO.Path.GetFileName(path)} is {data.Length:N0} bytes. Expected {expected}. Check RAW settings.");
        }
        var samples = data.AsSpan(format.header).ToArray();
        var histogram = new int[format.depth == 8 ? 256 : 65536];
        var stride = Math.Max(1, pixels / 1_000_000);
        for (var i = 0; i < pixels; i += stride)
            histogram[SampleAt(samples, format.depth, i)]++;
        var low = Percentile(histogram, 0.01);
        var high = Math.Max(low + 1, Percentile(histogram, 0.99));
        return new RawImage { Path = path, Width = width, Height = height, BitDepth = format.depth,
            Samples = samples, InitialCenter = (low + high) / 2.0, InitialWidth = high - low };
    }

    public byte[] ToGray(double center, double windowWidth, bool inverted = false)
    {
        var output = new byte[Width * Height];
        var low = center - Math.Max(1, windowWidth) / 2.0;
        var scale = 255.0 / Math.Max(1, windowWidth);
        for (var i = 0; i < output.Length; i++)
        {
            var value = (int)Math.Round((SampleAt(Samples, BitDepth, i) - low) * scale);
            var gray = (byte)Math.Clamp(value, 0, 255);
            output[i] = inverted ? (byte)(255 - gray) : gray;
        }
        return output;
    }

    public byte[] Thumbnail(double center, double windowWidth, int maxDimension = 144)
    {
        var ratio = Math.Min(1, maxDimension / (double)Math.Max(Width, Height));
        var w = Math.Max(1, (int)Math.Round(Width * ratio));
        var h = Math.Max(1, (int)Math.Round(Height * ratio));
        var thumb = new byte[w * h];
        var low = center - Math.Max(1, windowWidth) / 2.0;
        var scale = 255.0 / Math.Max(1, windowWidth);
        for (var y = 0; y < h; y++)
        for (var x = 0; x < w; x++)
        {
            var src = Math.Min(Height - 1, y * Height / h) * Width + Math.Min(Width - 1, x * Width / w);
            thumb[y * w + x] = (byte)Math.Clamp((int)Math.Round((SampleAt(Samples, BitDepth, src) - low) * scale), 0, 255);
        }
        return thumb;
    }

    public void ExportImage(string destination, string format, double center, double windowWidth, bool inverted)
    {
        var gray = ToGray(center, windowWidth, inverted);
        var bgra = new byte[gray.Length * 4];
        for (var i = 0; i < gray.Length; i++)
        {
            var p = i * 4;
            bgra[p] = gray[i]; bgra[p + 1] = gray[i]; bgra[p + 2] = gray[i]; bgra[p + 3] = 255;
        }
        var info = new SkiaSharp.SKImageInfo(Width, Height, SkiaSharp.SKColorType.Bgra8888, SkiaSharp.SKAlphaType.Opaque);
        using var bitmap = new SkiaSharp.SKBitmap(info);
        System.Runtime.InteropServices.Marshal.Copy(bgra, 0, bitmap.GetPixels(), bgra.Length);
        using var image = SkiaSharp.SKImage.FromBitmap(bitmap);
        using var encoded = image.Encode(format.Equals("JPEG", StringComparison.OrdinalIgnoreCase) ? SkiaSharp.SKEncodedImageFormat.Jpeg : SkiaSharp.SKEncodedImageFormat.Png,
            format.Equals("JPEG", StringComparison.OrdinalIgnoreCase) ? 94 : 100);
        if (encoded is null) throw new IOException("Image encoder could not create the output.");
        using var output = File.Create(destination);
        encoded.SaveTo(output);
    }

    public void ExportDicom(string destination, double center, double windowWidth, bool inverted, string studyUid, string seriesUid, int instance)
    {
        if (Width > ushort.MaxValue || Height > ushort.MaxValue)
            throw new InvalidDataException("DICOM rows and columns cannot exceed 65,535 pixels. Use PNG or JPEG for this image.");
        var sopClass = "1.2.840.10008.5.1.4.1.1.7";
        var sopUid = NewUid();
        var now = DateTime.UtcNow;
        var date = now.ToString("yyyyMMdd", CultureInfo.InvariantCulture);
        var time = now.ToString("HHmmss", CultureInfo.InvariantCulture);
        using var metaBody = new MemoryStream();
        WriteElement(metaBody, 0x0002, 0x0001, "OB", new byte[] { 0, 1 });
        WriteText(metaBody, 0x0002, 0x0002, "UI", sopClass);
        WriteText(metaBody, 0x0002, 0x0003, "UI", sopUid);
        WriteText(metaBody, 0x0002, 0x0010, "UI", "1.2.840.10008.1.2.1");
        WriteText(metaBody, 0x0002, 0x0012, "UI", "2.25.31415926535897932384626433832795028841");
        WriteText(metaBody, 0x0002, 0x0013, "SH", "RAYMEDIS_RAW_1");
        using var stream = File.Create(destination);
        stream.Write(new byte[128]); stream.Write(Encoding.ASCII.GetBytes("DICM"));
        WriteElement(stream, 0x0002, 0x0000, "UL", UInt32((uint)metaBody.Length));
        metaBody.Position = 0; metaBody.CopyTo(stream);
        WriteText(stream, 0x0008, 0x0016, "UI", sopClass);
        WriteText(stream, 0x0008, 0x0018, "UI", sopUid);
        WriteText(stream, 0x0008, 0x0020, "DA", date); WriteText(stream, 0x0008, 0x0023, "DA", date);
        WriteText(stream, 0x0008, 0x0030, "TM", time); WriteText(stream, 0x0008, 0x0033, "TM", time);
        WriteText(stream, 0x0008, 0x0060, "CS", "OT"); WriteText(stream, 0x0008, 0x0064, "CS", "WSD");
        WriteText(stream, 0x0008, 0x0070, "LO", "Raymedis");
        WriteText(stream, 0x0008, 0x103E, "LO", System.IO.Path.GetFileNameWithoutExtension(Path));
        WriteText(stream, 0x0010, 0x0010, "PN", "Anonymous"); WriteText(stream, 0x0010, 0x0020, "LO", "RAW-EXPORT");
        WriteText(stream, 0x0020, 0x000D, "UI", studyUid); WriteText(stream, 0x0020, 0x000E, "UI", seriesUid);
        WriteText(stream, 0x0020, 0x0010, "SH", "RAWEXPORT"); WriteText(stream, 0x0020, 0x0011, "IS", "1");
        WriteText(stream, 0x0020, 0x0013, "IS", instance.ToString(CultureInfo.InvariantCulture));
        WriteElement(stream, 0x0028, 0x0002, "US", UInt16(1));
        WriteText(stream, 0x0028, 0x0004, "CS", inverted ? "MONOCHROME1" : "MONOCHROME2");
        WriteElement(stream, 0x0028, 0x0010, "US", UInt16((ushort)Height)); WriteElement(stream, 0x0028, 0x0011, "US", UInt16((ushort)Width));
        WriteElement(stream, 0x0028, 0x0100, "US", UInt16((ushort)BitDepth)); WriteElement(stream, 0x0028, 0x0101, "US", UInt16((ushort)BitDepth));
        WriteElement(stream, 0x0028, 0x0102, "US", UInt16((ushort)(BitDepth - 1))); WriteElement(stream, 0x0028, 0x0103, "US", UInt16(0));
        WriteText(stream, 0x0028, 0x1050, "DS", Math.Round(center).ToString(CultureInfo.InvariantCulture));
        WriteText(stream, 0x0028, 0x1051, "DS", Math.Max(1, Math.Round(windowWidth)).ToString(CultureInfo.InvariantCulture));
        WriteElement(stream, 0x7FE0, 0x0010, BitDepth == 8 ? "OB" : "OW", Samples);
    }

    private static int SampleAt(byte[] samples, int depth, int index) => depth == 8 ? samples[index] : BinaryPrimitives.ReadUInt16LittleEndian(samples.AsSpan(index * 2, 2));
    private static int Percentile(int[] histogram, double fraction)
    {
        var target = Math.Max(1, (int)(histogram.Sum() * fraction)); var sum = 0;
        for (var i = 0; i < histogram.Length; i++) { sum += histogram[i]; if (sum >= target) return i; }
        return histogram.Length - 1;
    }
    private static string NewUid() => "2.25." + BigInteger.Parse("0" + Guid.NewGuid().ToString("N"), NumberStyles.HexNumber, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture);
    private static byte[] UInt16(ushort value) { var bytes = new byte[2]; BinaryPrimitives.WriteUInt16LittleEndian(bytes, value); return bytes; }
    private static byte[] UInt32(uint value) { var bytes = new byte[4]; BinaryPrimitives.WriteUInt32LittleEndian(bytes, value); return bytes; }
    private static void WriteText(Stream stream, ushort group, ushort element, string vr, string text)
    {
        var bytes = Encoding.ASCII.GetBytes(text);
        if ((bytes.Length & 1) != 0) Array.Resize(ref bytes, bytes.Length + 1);
        if (vr == "UI" && bytes.Length > 0 && bytes[^1] == 0) { }
        else if (bytes.Length > 0 && bytes[^1] == 0) bytes[^1] = 0x20;
        WriteElement(stream, group, element, vr, bytes);
    }
    private static void WriteElement(Stream stream, ushort group, ushort element, string vr, byte[] value)
    {
        if ((value.Length & 1) != 0) Array.Resize(ref value, value.Length + 1);
        Span<byte> head = stackalloc byte[8]; BinaryPrimitives.WriteUInt16LittleEndian(head, group); BinaryPrimitives.WriteUInt16LittleEndian(head[2..], element);
        Encoding.ASCII.GetBytes(vr, head[4..6]);
        stream.Write(head[..6]);
        if (vr is "OB" or "OW" or "SQ" or "UT" or "UN")
        {
            stream.Write(new byte[2]); Span<byte> length = stackalloc byte[4]; BinaryPrimitives.WriteUInt32LittleEndian(length, (uint)value.Length); stream.Write(length);
        }
        else { Span<byte> length = stackalloc byte[2]; BinaryPrimitives.WriteUInt16LittleEndian(length, (ushort)value.Length); stream.Write(length); }
        stream.Write(value);
    }
}
