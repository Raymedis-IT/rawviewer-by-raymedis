param(
    [ValidateSet('win-x64', 'win-arm64', 'osx-arm64', 'osx-x64', 'linux-x64', 'linux-arm64')]
    [string]$Runtime = 'win-x64'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$project = Join-Path $projectRoot 'RawViewer/RawViewer.csproj'
$output = Join-Path $projectRoot "dist/$Runtime"
if ($Runtime -like 'osx-*') { $output = Join-Path $projectRoot ".build/publish/$Runtime" }
$bundleNative = if ($Runtime -like 'osx-*') { 'false' } else { 'true' }

dotnet publish $project -c Release -r $Runtime --self-contained true `
    -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true `
    "-p:IncludeNativeLibrariesForSelfExtract=$bundleNative" -p:DebugType=None `
    -p:DebugSymbols=false -p:CopyOutputSymbolsToPublishDirectory=false `
    -p:UsedAvaloniaProducts= -o $output
if ($LASTEXITCODE -ne 0) { throw "Publish failed for $Runtime (exit code $LASTEXITCODE)." }

if ($Runtime -like 'win-*') {
    $executable = Join-Path $output 'RAW Viewer by Raymedis.exe'
    if (!(Test-Path -LiteralPath $executable)) { throw "Missing executable: $executable" }
    $archive = Join-Path $projectRoot "dist/RAW-Viewer-by-Raymedis-$Runtime.zip"
    Compress-Archive -LiteralPath $executable -DestinationPath $archive -Force
    Write-Host "Windows executable: $executable"
    Write-Host "Portable ZIP: $archive"
} elseif ($Runtime -like 'osx-*') {
    dotnet run --project (Join-Path $projectRoot 'tools/MacPackage/MacPackage.csproj') -c Release -- $projectRoot $Runtime
    if ($LASTEXITCODE -ne 0) { throw 'Mac packaging failed.' }
} else {
    Write-Host "Published ${Runtime}: $output"
}
