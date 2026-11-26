import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: generate-macos-icon.swift <output.icns>")
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let dimension = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(data: nil, width: dimension, height: dimension,
                              bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Could not create the app icon canvas.")
}
context.setFillColor(NSColor(calibratedWhite: 0.025, alpha: 1).cgColor)
context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))

// A clean, vector-sharp take on the atom mark from the provided Raymedis logo.
let gray = NSColor(calibratedRed: 0.42, green: 0.44, blue: 0.46, alpha: 1).cgColor
let orange = NSColor(calibratedRed: 0.96, green: 0.31, blue: 0.08, alpha: 1).cgColor
context.setStrokeColor(gray)
context.setLineWidth(42)
let orbit = CGRect(x: -345, y: -155, width: 690, height: 310)
for angle in [0.0, Double.pi / 3, -Double.pi / 3] {
    context.saveGState()
    context.translateBy(x: 512, y: 512)
    context.rotate(by: angle)
    context.strokeEllipse(in: orbit)
    context.restoreGState()
}
context.setFillColor(orange)
context.fillEllipse(in: CGRect(x: 414, y: 414, width: 196, height: 196))
for point in [CGPoint(x: 512, y: 145), CGPoint(x: 200, y: 690), CGPoint(x: 824, y: 690)] {
    context.fillEllipse(in: CGRect(x: point.x - 36, y: point.y - 36, width: 72, height: 72))
}
guard let fullSizeIcon = context.makeImage() else { fatalError("Could not render the app icon.") }

func pngData(size: Int) -> Data {
    guard let resizedContext = CGContext(data: nil, width: size, height: size,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Could not resize the app icon to \(size) pixels.")
    }
    resizedContext.interpolationQuality = .high
    resizedContext.draw(fullSizeIcon, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let resizedIcon = resizedContext.makeImage(),
          let png = NSBitmapImageRep(cgImage: resizedIcon).representation(using: .png, properties: [:]) else {
        fatalError("Could not encode the \(size)-pixel app icon.")
    }
    return png
}

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    data.append(contentsOf: [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                             UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
}

let representations: [(String, Int)] = [
    ("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
    ("ic08", 256), ("ic09", 512), ("ic10", 1024)
]
var payload = Data()
for (type, size) in representations {
    let png = pngData(size: size)
    payload.append(contentsOf: type.utf8)
    appendBigEndian(UInt32(png.count + 8), to: &payload)
    payload.append(png)
}
var icns = Data("icns".utf8)
appendBigEndian(UInt32(payload.count + 8), to: &icns)
icns.append(payload)

try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
try icns.write(to: outputURL, options: .atomic)
