using System.Text.RegularExpressions;

namespace Raymedis.RawViewer;

internal sealed record RawFormat(int Width, int Height, int BitDepth, int HeaderBytes)
{
    public override string ToString() => $"{Width} × {Height} · {BitDepth}-bit · {HeaderBytes}-byte header";

    public bool Matches(long length) => Width > 0 && Height > 0 && BitDepth is 8 or 16 && HeaderBytes >= 0 &&
        (long)Width * Height * (BitDepth / 8) + HeaderBytes == length;

    // Plain RAW has no standard header. File length alone cannot identify its shape.
    public static RawFormat? FromFileName(string path, long length, int? depth, int? header)
    {
        var match = Regex.Match(System.IO.Path.GetFileNameWithoutExtension(path), @"(?<!\d)(\d{1,9})[xX×](\d{1,9})(?!\d)");
        if (!match.Success || !int.TryParse(match.Groups[1].Value, out var w) || !int.TryParse(match.Groups[2].Value, out var h)) return null;
        var matches = (from d in depth.HasValue ? new[] { depth.Value } : new[] { 8, 16 }
                       from offset in header.HasValue ? new[] { header.Value } : new[] { 0, 200 }
                       let format = new RawFormat(w, h, d, offset)
                       where format.Matches(length)
                       select format).ToArray();
        return matches.Length == 1 ? matches[0] : null;
    }

    public static RawFormat[] Suggestions(long length)
    {
        var candidates = new List<RawFormat>();
        foreach (var depth in new[] { 16, 8 })
        foreach (var header in new[] { 0, 200 })
        {
            var bytes = length - header;
            if (bytes <= 0 || bytes % (depth / 8) != 0) continue;
            var pixels = bytes / (depth / 8);
            for (var w = 1; (long)w * w <= pixels && w <= 65536; w++)
            {
                if (pixels % w != 0 || pixels / w > int.MaxValue) continue;
                var h = (int)(pixels / w);
                candidates.Add(new(w, h, depth, header));
                if (w != h) candidates.Add(new(h, w, depth, header));
            }
        }
        return candidates.OrderBy(f => f.Width == 2500 && f.Height == 3052 ? 0 : 1)
            .ThenBy(f => Math.Abs(Math.Log((double)f.Width / f.Height)))
            .ThenByDescending(f => f.BitDepth).Take(80).ToArray();
    }
}

internal sealed class RawFormatRequiredException(string path) : IOException(
    $"Choose the dimensions and pixel format for {System.IO.Path.GetFileName(path)}. Headerless RAW does not store this information.");
