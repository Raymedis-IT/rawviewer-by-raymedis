param(
    [Parameter(Mandatory=$true)][string]$CertificateThumbprint,
    [Parameter(Mandatory=$true)][string]$SignTool,
    [ValidateSet('win-x64','win-arm64')][string]$Runtime = 'win-x64'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $root "dist/$Runtime/RAW Viewer by Raymedis.exe"
# The certificate's private key stays in the Windows certificate store/token.
& $SignTool sign /sha1 $CertificateThumbprint /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $exe
if ($LASTEXITCODE -ne 0) { throw 'Signing failed.' }
& $SignTool verify /pa /all /v $exe
if ($LASTEXITCODE -ne 0) { throw 'Signature verification failed.' }
if ((Get-AuthenticodeSignature -LiteralPath $exe).Status -ne 'Valid') { throw 'Windows does not trust this signature.' }
$archive = Join-Path $root "dist/RAW-Viewer-by-Raymedis-$Runtime-signed.zip"
Compress-Archive -LiteralPath $exe -DestinationPath $archive -Force
Write-Host "Signed archive: $archive"
Write-Host 'Test this downloaded package on a Smart App Control device before distribution; native dependencies are also subject to policy.'
