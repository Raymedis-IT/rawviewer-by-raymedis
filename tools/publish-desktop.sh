#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/RawViewer/RawViewer.csproj"
RID="${1:-win-x64}"
case "$RID" in
  win-x64|win-arm64|osx-arm64|osx-x64|linux-x64|linux-arm64) ;;
  *) echo "Unsupported RID: $RID" >&2; echo "Use win-x64, win-arm64, osx-arm64, osx-x64, linux-x64, or linux-arm64." >&2; exit 2 ;;
esac
if [[ "$RID" == osx-* ]]; then
  exec bash "$ROOT/tools/build-macos-app.sh" "$RID"
fi

OUT="$ROOT/dist/$RID"
mkdir -p "$OUT"
dotnet publish "$PROJECT" -c Release -r "$RID" --self-contained true \
  -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true \
  -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None \
  -p:DebugSymbols=false -p:CopyOutputSymbolsToPublishDirectory=false \
  -p:UsedAvaloniaProducts= -o "$OUT"

# NuGet native rendering packages include large, non-runtime PDB files. Keep the
# self-contained app output compact and leave only its runnable files behind.
find "$OUT" -type f -name '*.pdb' -delete

if [[ "$RID" == win-* ]]; then
  echo "Windows executable: $OUT/RAW Viewer by Raymedis.exe"
else
  echo "Published $RID: $OUT"
fi
