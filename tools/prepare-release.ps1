$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$inputs = @('LICENSE', 'THIRD-PARTY-NOTICES.md', 'RELEASE_NOTES.md')
$inputs += @(Get-ChildItem (Join-Path $root 'licenses') -File | ForEach-Object { 'licenses/' + $_.Name })
$checksums = @()
foreach ($rid in @('win-x64', 'osx-arm64', 'osx-x64')) {
    $path = Join-Path $root "dist/RAW-Viewer-by-Raymedis-$rid.zip"
    $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Update)
    try {
        foreach ($relative in $inputs) {
            $old = $zip.GetEntry($relative)
            if ($null -ne $old) { $old.Delete() }
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $root $relative), $relative, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally { $zip.Dispose() }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksums += "$hash  $([IO.Path]::GetFileName($path))"
}
[IO.File]::WriteAllLines((Join-Path $root 'dist/SHA256SUMS.txt'), $checksums, [Text.UTF8Encoding]::new($false))
Write-Host 'Release ZIPs contain project/dependency licenses and release notes. SHA256SUMS.txt updated.'
