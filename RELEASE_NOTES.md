# RAW Viewer by Raymedis v0.1.0 — Preview

Initial public release of the shared Windows/macOS desktop viewer.

- Responsive dark UI with Raymedis branding and centered vector toolbar icons.
- Per-image RAW dimensions, file-size suggestions, custom header lengths and mixed-size galleries.
- Unsigned 8-bit and 16-bit little-endian image samples.
- Window/level controls, zoom, invert, thumbnails and keyboard navigation.
- PNG, JPEG and DICOM export.

## Downloads

- `RAW-Viewer-by-Raymedis-win-x64.zip`: Windows Intel/AMD 64-bit.
- `RAW-Viewer-by-Raymedis-osx-arm64.zip`: Apple Silicon Mac, macOS 14+.
- `RAW-Viewer-by-Raymedis-osx-x64.zip`: Intel Mac, macOS 14+.
- `SHA256SUMS.txt`: checksums for the downloadable ZIPs.

Extract on the destination operating system. No separate .NET installation is required.

## Known limitations

- Windows executable is unsigned. Smart App Control may block it because its publisher cannot be verified. This release does not resolve that restriction.
- Mac packages are cross-compiled and structurally verified, but have not been launched on a Mac. They are not Developer ID signed/notarized and may be blocked by Gatekeeper.
- Headerless RAW cannot reliably identify dimensions on its own. Filename dimensions are used only when the byte count matches; otherwise confirm the format in the import dialog.
- Packed, signed, floating-point, compressed and proprietary camera RAW formats are not decoded. Memory limits apply.
- DICOM exports use anonymous identifiers and are not a complete clinical metadata workflow.

## Validation

Windows UI checks cover multiple window sizes, centered controls, filename bounds and RAW rendering. Loader/export checks cover several dimensions, 8/16-bit samples and 0/128/200-byte headers. Both Mac archive architectures, bundle metadata and Unix executable permissions were checked. Signing/notarization scripts are supplied but have not been exercised with real credentials.
