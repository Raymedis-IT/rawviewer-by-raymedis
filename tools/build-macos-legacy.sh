#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_ROOT/dist/RAW Viewer by Raymedis.app"
ICON_TEMP="$APP_PATH/Contents/Resources/RaymedisAppIcon-$$.icns"
ICON_GENERATOR="$PROJECT_ROOT/.build/generate-macos-icon-$$"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
mkdir -p "$PROJECT_ROOT/.build"
cp "$PROJECT_ROOT/RawView/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$PROJECT_ROOT/RawView/Assets/RaymedisLogo.png" "$APP_PATH/Contents/Resources/RaymedisLogo.png"

swiftc -O -module-cache-path "$PROJECT_ROOT/.build/module-cache-icon" \
  "$PROJECT_ROOT/tools/generate-macos-icon.swift" -o "$ICON_GENERATOR"
"$ICON_GENERATOR" "$ICON_TEMP"
mv "$ICON_TEMP" "$APP_PATH/Contents/Resources/RaymedisAppIcon.icns"

SWIFT_SOURCES=("$PROJECT_ROOT"/RawView/*.swift)
SWIFT_COMMON=(
  -swift-version 5
  -O
  -framework AppKit
  -framework CoreGraphics
  -framework ImageIO
  -framework UniformTypeIdentifiers
)
ARM64_BINARY="$PROJECT_ROOT/.build/RawView-arm64-$$"
X64_BINARY="$PROJECT_ROOT/.build/RawView-x86_64-$$"

swiftc "${SWIFT_COMMON[@]}" \
  -target arm64-apple-macosx13.0 \
  -module-cache-path "$PROJECT_ROOT/.build/module-cache-arm64" \
  "${SWIFT_SOURCES[@]}" -o "$ARM64_BINARY"
swiftc "${SWIFT_COMMON[@]}" \
  -target x86_64-apple-macosx13.0 \
  -module-cache-path "$PROJECT_ROOT/.build/module-cache-x86_64" \
  "${SWIFT_SOURCES[@]}" -o "$X64_BINARY"
lipo -create "$ARM64_BINARY" "$X64_BINARY" -output "$APP_PATH/Contents/MacOS/RawView"

codesign --force --sign - "$APP_PATH"
echo "Built: $APP_PATH"
