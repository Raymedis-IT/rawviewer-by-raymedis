# RAW Viewer by Raymedis

[Download Windows and Mac builds](https://github.com/discreteBody/rawviewer-by-raymedis/releases)

The initial release is a preview. Windows builds are unsigned and may be blocked by Smart App Control. Mac builds are cross-compiled, not launch-tested on macOS, and not Developer ID signed or notarized. Choose `win-x64` for Intel/AMD Windows PCs, `osx-arm64` for Apple Silicon Macs, or `osx-x64` for Intel Macs. Extract the ZIP on the target computer and open the executable/app bundle. The runtime is included.

Source code is MIT licensed; see [LICENSE](LICENSE). Third-party components retain their own licenses. This license grants no trademark rights to the Raymedis name or branding.

After building all three release packages, run `powershell -ExecutionPolicy Bypass -File tools/prepare-release.ps1` to include license notices and generate `dist/SHA256SUMS.txt` before uploading a release.

A minimal, responsive desktop viewer and exporter for detector RAW images. Windows and the updated macOS packages use the same Avalonia UI and .NET image-loading/export code. The Raymedis wordmark is included in the header, with a black Raymedis atom mark for the app icon.

## RAW handling

Images are loaded with per-file dimensions, not a fixed detector size. The loader recognizes dimensions in filenames such as `image_1024x768.raw` when the byte count matches an 8-bit or 16-bit unsigned image with no header or a 200-byte header. Otherwise an import dialog offers file-size suggestions and accepts any positive width and height, 8/16-bit unsigned samples, and a custom header byte count. Confirm the actual format: headerless RAW does not store dimensions, and many shapes can have the same byte count. Formats are remembered per file for the current session, including mixed-size galleries and exports. Optional fixed dimensions remain available in RAW format settings. 16-bit samples are little endian; packed, signed, floating-point, compressed and proprietary camera RAW formats are not currently decoded. Very large images remain subject to available memory and the 2 GB rendered-buffer limit.

## Features

- Open one or more `.raw` files or browse a folder as a thumbnail gallery.
- View 8-bit and 16-bit frames with level, width, invert, zoom, and previous / next controls.
- Export the selected image or the folder set as PNG, JPEG, or DICOM.
- Keep DICOM pixel samples at their original bit depth; PNG and JPEG use the current display window.
- Load and export images away from the main UI thread.
- Responsive desktop layout down to a 640 × 480 logical-pixel window, centered vector toolbar icons, and truncated filenames with full-name tooltips.
- Browse with Up/Down or Left/Right. Shift + Left/Right adjusts level; Shift + Up/Down adjusts width. Use the viewer controls or +/- keys for zoom.

DICOM exports use anonymous patient identifiers and generated study and series identifiers. They are intended for conversion and review workflows where a user can supply the required clinical metadata in a downstream system.

## macOS build

With the .NET 10 SDK installed, build the shared app for each Mac architecture:

```sh
bash tools/build-macos-app.sh osx-arm64
bash tools/build-macos-app.sh osx-x64
```

On Windows, `tools/publish-desktop.ps1 osx-arm64` and `osx-x64` build the same packages. Updated bundles are at `dist/osx-arm64/RAW Viewer by Raymedis.app` and `dist/osx-x64/RAW Viewer by Raymedis.app`. Architecture-specific ZIPs are at `dist/RAW-Viewer-by-Raymedis-osx-arm64.zip` and `dist/RAW-Viewer-by-Raymedis-osx-x64.zip`. They preserve Unix executable permissions even when built on Windows. Extract on the Mac, rather than copying an extracted Windows folder. No separate .NET installation is required. These packages target macOS 14 or newer; local Mac launch testing remains necessary.

The top-level `dist/RAW Viewer by Raymedis.app` is the OLD Swift build and does not contain the latest changes. Its source and rebuild command are preserved as `RawView/` and `tools/build-macos-legacy.sh`. Use the new architecture-specific packages above.

Before public distribution, use an Apple Developer ID Application identity and a `notarytool` keychain profile on a Mac:

```sh
bash tools/sign-macos-app.sh osx-arm64 'Developer ID Application: Your Company (TEAMID)' PROFILE
```

Repeat for `osx-x64`. This signs native libraries and the app, submits to Apple, staples the ticket, validates it, and writes a `-signed.zip`. These signing steps have not been run: no signing account is configured. Unsigned/unnotarized archives may be blocked by Gatekeeper. Do not treat the cross-built archives as signed releases.

## Windows and shared desktop builds

On Windows, install the .NET 10 SDK for building, then run from the project folder:

```powershell
powershell -ExecutionPolicy Bypass -File tools/publish-desktop.ps1 win-x64
```

Open `dist/win-x64/RAW Viewer by Raymedis.exe` to use the app. This is a portable, self-contained app: users do not need to install .NET or copy the Assets folder. The script also creates `dist/RAW-Viewer-by-Raymedis-win-x64.zip` for sharing. Use `win-arm64` for Windows devices with ARM processors. The executable is currently unsigned.

The `RawViewer` project is the cross-platform UI/core. It targets .NET 10 LTS and uses Avalonia for native desktop windows and Skia for PNG/JPEG output. Build a self-contained Windows x64 executable on macOS, Windows, or Linux with:

```sh
bash tools/publish-desktop.sh win-x64
```

The executable is written to `dist/win-x64/RAW Viewer by Raymedis.exe`. The build script also accepts `win-arm64`, `osx-arm64`, `osx-x64`, `linux-x64`, and `linux-arm64`. Each operating system and processor architecture needs its own publish target; the same source tree produces distinct Windows, macOS, and Linux outputs.

## Windows publisher verification

The current Windows executable is unsigned. Smart App Control can block it because Windows cannot verify its publisher; changing the ZIP or creating an installer does not establish publisher trust. Obtain trusted code signing for Raymedis (a CA-issued code-signing certificate or Azure Artifact Signing), or pursue Microsoft Store distribution. Self-signing is not a public-distribution fix.

For a trusted code-signing certificate installed in the current user's certificate store, use the Windows SDK SignTool:

```powershell
./tools/sign-windows.ps1 -CertificateThumbprint YOUR_THUMBPRINT -SignTool 'C:/path/to/signtool.exe'
```

This timestamps and verifies the executable signature before creating a separate `-signed.zip`. The script is prepared but untested with a real certificate; none is configured here. Test the downloaded signed package on a Smart App Control device before sharing widely, including native-library trust. Azure Artifact Signing needs its own service configuration and signing client. Do not disable Smart App Control as an app deployment step.

References: [Microsoft signing guidance](https://learn.microsoft.com/en-us/windows/apps/develop/smart-app-control/code-signing-for-smart-app-control), [Avalonia macOS packaging](https://docs.avaloniaui.net/docs/deployment/macos).
