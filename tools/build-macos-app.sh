#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RID="${1:-osx-arm64}"
case "$RID" in osx-arm64|osx-x64) ;; *) echo "Use osx-arm64 or osx-x64" >&2; exit 2 ;; esac
dotnet publish "$ROOT/RawViewer/RawViewer.csproj" -c Release -r "$RID" --self-contained true \
  -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true \
  -p:IncludeNativeLibrariesForSelfExtract=false -p:DebugType=None -p:DebugSymbols=false \
  -p:CopyOutputSymbolsToPublishDirectory=false -p:UsedAvaloniaProducts= -o "$ROOT/.build/publish/$RID"
dotnet run --project "$ROOT/tools/MacPackage/MacPackage.csproj" -c Release -- "$ROOT" "$RID"
