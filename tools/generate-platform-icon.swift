import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: generate-platform-icon.swift <output.png> <output.ico>")
}

let pngURL = URL(fileURLWithPath: CommandLine.arguments[1])
let icoURL = URL(fileURLWithPath: CommandLine.arguments[2])
let size = 256
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Could not render the Raymedis app icon.")
}
context.setFillColor(NSColor(calibratedWhite: 0.025, alpha: 1).cgColor)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.setStrokeColor(NSColor(calibratedRed: 0.42, green: 0.44, blue: 0.46, alpha: 1).cgColor)
context.setLineWidth(11)
let orbit = CGRect(x: 34, y: 76, width: 188, height: 104)
for angle in [0.0, Double.pi / 3, -Double.pi / 3] {
    context.saveGState()
    context.translateBy(x: 128, y: 128)
    context.rotate(by: angle)
    context.strokeEllipse(in: CGRect(x: -94, y: -52, width: orbit.width, height: orbit.height))
    context.restoreGState()
}
context.setFillColor(NSColor(calibratedRed: 0.96, green: 0.31, blue: 0.08, alpha: 1).cgColor)
context.fillEllipse(in: CGRect(x: 103, y: 103, width: 50, height: 50))
for point in [CGPoint(x: 128, y: 33), CGPoint(x: 43, y: 194), CGPoint(x: 213, y: 194)] {
    context.fillEllipse(in: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18))
}
guard let image = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    fatalError("Could not encode the Raymedis app icon.")
}
try FileManager.default.createDirectory(at: pngURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: pngURL)

func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var number = value.littleEndian
    withUnsafeBytes(of: &number) { data.append(contentsOf: $0) }
}
var ico = Data([0, 0, 1, 0, 1, 0])
ico.append(contentsOf: [0, 0, 0, 0]) // 256 x 256 icon size.
appendLE(UInt16(1), to: &ico)
appendLE(UInt16(32), to: &ico)
appendLE(UInt32(png.count), to: &ico)
appendLE(UInt32(22), to: &ico)
ico.append(png)
try FileManager.default.createDirectory(at: icoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try ico.write(to: icoURL)
