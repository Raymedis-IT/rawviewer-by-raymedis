using System.IO.Compression;
using System.Xml.Linq;

if (args.Length != 2 || args[1] is not ("osx-arm64" or "osx-x64"))
    throw new ArgumentException("Usage: MacPackage <project root> <osx-arm64|osx-x64>");
var root = Path.GetFullPath(args[0]);
var rid = args[1];
const string name = "RAW Viewer by Raymedis";
var source = Path.Combine(root, ".build", "publish", rid, name);
using (var reader = new BinaryReader(File.OpenRead(source)))
{
    if (reader.ReadUInt32() != 0xfeedfacf || reader.ReadUInt32() != (rid == "osx-arm64" ? 0x0100000cU : 0x01000007U))
        throw new InvalidDataException("Published executable is not the expected 64-bit Mach-O architecture.");
}
var app = Path.Combine(root, "dist", rid, name + ".app");
var executable = Path.Combine(app, "Contents", "MacOS", name);
var resources = Path.Combine(app, "Contents", "Resources");
Directory.CreateDirectory(Path.GetDirectoryName(executable)!);
Directory.CreateDirectory(resources);
File.Copy(source, executable, true);
// Keep native libraries beside the executable so Developer ID signing can cover
// each binary before signing the app bundle (no hidden unsigned extraction).
foreach (var file in Directory.EnumerateFiles(Path.GetDirectoryName(source)!, "*", SearchOption.AllDirectories))
{
    if (Path.GetExtension(file) == ".pdb") continue;
    var target = Path.Combine(Path.GetDirectoryName(executable)!, Path.GetRelativePath(Path.GetDirectoryName(source)!, file));
    Directory.CreateDirectory(Path.GetDirectoryName(target)!);
    File.Copy(file, target, true);
    if (!OperatingSystem.IsWindows() && (file == source || Path.GetExtension(file) == ".dylib"))
        File.SetUnixFileMode(target, (UnixFileMode)0x1ed);
}
File.Copy(Path.Combine(root, "RawViewer", "Assets", "RaymedisAppIcon.icns"), Path.Combine(resources, "RaymedisAppIcon.icns"), true);
if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(executable, (UnixFileMode)0x1ed);
var version = XDocument.Load(Path.Combine(root, "RawViewer", "RawViewer.csproj")).Descendants("Version").Single().Value;
var entries = new Dictionary<string, object>
{
    ["CFBundleExecutable"] = name, ["CFBundleIdentifier"] = "com.raymedis.rawviewer",
    ["CFBundleName"] = name, ["CFBundleDisplayName"] = name, ["CFBundlePackageType"] = "APPL",
    ["CFBundleShortVersionString"] = version, ["CFBundleVersion"] = "2",
    ["CFBundleIconFile"] = "RaymedisAppIcon.icns", ["LSMinimumSystemVersion"] = "14.0",
    ["NSHighResolutionCapable"] = true
};
var plist = new XDocument(new XDeclaration("1.0", "UTF-8", null),
    new XDocumentType("plist", "-//Apple//DTD PLIST 1.0//EN", "http://www.apple.com/DTDs/PropertyList-1.0.dtd", null),
    new XElement("plist", new XAttribute("version", "1.0"), new XElement("dict", entries.SelectMany(kv => new[] {
        new XElement("key", kv.Key), kv.Value is bool ? new XElement("true") : new XElement("string", kv.Value) }))));
plist.Save(Path.Combine(app, "Contents", "Info.plist"));
var archive = Path.Combine(root, "dist", $"RAW-Viewer-by-Raymedis-{rid}.zip");
using (var zip = ZipFile.Open(archive + ".tmp", ZipArchiveMode.Create))
{
    foreach (var file in Directory.EnumerateFiles(app, "*", SearchOption.AllDirectories).Order())
    {
        var relative = Path.GetRelativePath(Path.GetDirectoryName(app)!, file).Replace('\\', '/');
        var entry = zip.CreateEntryFromFile(file, relative, CompressionLevel.Optimal);
        entry.ExternalAttributes = (file == executable || Path.GetExtension(file) == ".dylib" ? 0x81ed : 0x81a4) << 16;
    }
}
// Set the ZIP creator OS to Unix as well as the mode bits. Otherwise some Mac
// extractors discard execute permissions when the archive is produced on Windows.
using (var stream = new FileStream(archive + ".tmp", FileMode.Open, FileAccess.ReadWrite))
using (var reader = new BinaryReader(stream))
using (var writer = new BinaryWriter(stream))
{
    stream.Position = stream.Length - 22;
    if (reader.ReadUInt32() != 0x06054b50) throw new InvalidDataException("Invalid ZIP trailer.");
    stream.Position += 12;
    var central = reader.ReadUInt32();
    stream.Position = central;
    while (reader.ReadUInt32() == 0x02014b50)
    {
        var start = stream.Position - 4;
        stream.Position = start + 5; writer.Write((byte)3);
        stream.Position = start + 28;
        var next = start + 46 + reader.ReadUInt16() + reader.ReadUInt16() + reader.ReadUInt16();
        stream.Position = next;
    }
}
File.Move(archive + ".tmp", archive, true);
using (var zip = ZipFile.OpenRead(archive))
{
    var entry = zip.GetEntry($"{name}.app/Contents/MacOS/{name}")!;
    if (((entry.ExternalAttributes >> 16) & 0x1ff) != 0x1ed || entry.Length != new FileInfo(source).Length)
        throw new InvalidDataException("Packaged executable or permissions failed verification.");
    foreach (var item in zip.Entries) { using var data = item.Open(); data.CopyTo(Stream.Null); }
}
Console.WriteLine($"Verified {rid} Mach-O, app metadata, ZIP readability and executable permissions.");
Console.WriteLine($"App: {app}\nZIP: {archive}\nDeveloper ID signing, notarization and Mac launch testing remain required for distribution.");
