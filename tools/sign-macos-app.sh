#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RID="${1:?Usage: sign-macos-app.sh osx-arm64|osx-x64 'Developer ID Application: ...' keychain-profile}"
IDENTITY="${2:?Provide a Developer ID Application identity}"
PROFILE="${3:?Provide the notarytool keychain profile name}"
case "$RID" in osx-arm64|osx-x64) ;; *) exit 2 ;; esac
[[ "$(uname -s)" == Darwin ]] || { echo "Run signing and notarization on a Mac." >&2; exit 1; }
APP="$ROOT/dist/$RID/RAW Viewer by Raymedis.app"
ZIP="$ROOT/dist/RAW-Viewer-by-Raymedis-$RID-signed.zip"
chmod +x "$APP/Contents/MacOS/RAW Viewer by Raymedis"
while IFS= read -r -d '' library; do
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$library"
done < <(find "$APP/Contents/MacOS" -type f -name '*.dylib' -print0)
codesign --force --timestamp --options runtime --entitlements "$ROOT/tools/macos.entitlements" --sign "$IDENTITY" "$APP/Contents/MacOS/RAW Viewer by Raymedis"
codesign --force --timestamp --options runtime --entitlements "$ROOT/tools/macos.entitlements" --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --wait --keychain-profile "$PROFILE"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "Signed and notarized ZIP: $ZIP"
