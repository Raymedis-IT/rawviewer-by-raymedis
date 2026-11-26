using Raymedis.RawViewer;
using SkiaSharp;

var output = Path.GetFullPath(".build/raw-smoke");
Directory.CreateDirectory(output);
foreach (var (w, h, bits, header) in new[] { (37, 19, 8, 0), (113, 71, 16, 200), (320, 240, 8, 200), (1024, 512, 16, 0), (17, 31, 16, 128), (20001, 1, 8, 0) })
{
    var path = Path.Combine(output, $"sample_{w}x{h}_{bits}_{header}.raw");
    var data = new byte[w * h * (bits / 8) + header];
    for (var i = header; i < data.Length; i++) data[i] = (byte)(i % 251);
    File.WriteAllBytes(path, data);
    var frame = header == 128 ? RawImage.Read(path, w, h, bits, header) : RawImage.Read(path, 0, 0);
    if (frame.Width != w || frame.Height != h || frame.BitDepth != bits || !frame.Samples.SequenceEqual(data.Skip(header))) throw new Exception("Decoded metadata or pixels differ.");
    foreach (var format in new[] { "PNG", "JPEG" })
    {
        var file = path + "." + format;
        frame.ExportImage(file, format, frame.InitialCenter, frame.InitialWidth, false);
        using var decoded = SKBitmap.Decode(file);
        if (decoded.Width != w || decoded.Height != h) throw new Exception("Export dimensions differ.");
    }
    frame.ExportDicom(path + ".dcm", frame.InitialCenter, frame.InitialWidth, false, "2.25.1", "2.25.2", 1);
    if (!File.ReadAllBytes(path + ".dcm").AsSpan(128, 4).SequenceEqual("DICM"u8)) throw new Exception("Invalid DICOM marker.");
    Console.WriteLine($"PASS {w}x{h}, {bits}-bit, header {header}: samples and PNG/JPEG dimensions, DICOM output.");
}
var ambiguous = Path.Combine(output, "unknown.raw");
File.WriteAllBytes(ambiguous, new byte[2048]);
try { RawImage.Read(ambiguous, 0, 0); throw new Exception("Ambiguous file silently guessed."); }
catch (RawFormatRequiredException) { Console.WriteLine("PASS ambiguous RAW requests its format."); }
if (RawFormat.Suggestions(2048).Any(f => !f.Matches(2048))) throw new Exception("Invalid size suggestion.");
try { RawImage.Read(ambiguous, 13, 17, 16, 0); throw new Exception("Invalid format accepted."); }
catch (InvalidDataException) { Console.WriteLine("PASS mismatched dimensions rejected."); }
try { RawImage.Read(ambiguous, 32, 32, 16, -1); throw new Exception("Negative header accepted."); }
catch (InvalidDataException) { Console.WriteLine("PASS negative header rejected."); }
