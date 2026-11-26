import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RawSettings: Equatable {
    var width = 2500
    var height = 3052
    var bitDepth = BitDepth.automatic
    var header = HeaderSize.automatic

    enum BitDepth: String, CaseIterable, Identifiable {
        case automatic = "Auto"
        case eight = "8 bit"
        case sixteen = "16 bit"
        var id: String { rawValue }
        var value: Int? { self == .eight ? 8 : self == .sixteen ? 16 : nil }
    }

    enum HeaderSize: String, CaseIterable, Identifiable {
        case automatic = "Auto"
        case none = "0 bytes"
        case rxView = "200 bytes"
        var id: String { rawValue }
        var value: Int? { self == .none ? 0 : self == .rxView ? 200 : nil }
    }
}

struct DisplayWindow: Equatable {
    var center: Double
    var width: Double
}

struct RawFrame {
    let sourceURL: URL
    let width: Int
    let height: Int
    let bitDepth: Int
    let pixels: Data
    let displayWindow: DisplayWindow

    var minimum: Int { 0 }
    var maximum: Int { bitDepth == 8 ? 255 : 65535 }

    func displayPNG(window: DisplayWindow? = nil, inverted: Bool = false) throws -> Data {
        let bytes = try grayscaleBytes(window: window ?? displayWindow, inverted: inverted)
        return try encode(bytes: bytes, width: width, height: height, type: .png, quality: 1)
    }

    func displayJPEG(window: DisplayWindow? = nil, inverted: Bool = false, quality: Double = 0.94) throws -> Data {
        let bytes = try grayscaleBytes(window: window ?? displayWindow, inverted: inverted)
        return try encode(bytes: bytes, width: width, height: height, type: .jpeg, quality: quality)
    }

    func thumbnailPNG(maxDimension: Int) throws -> Data {
        let scale = min(1, Double(maxDimension) / Double(max(width, height)))
        let thumbWidth = max(1, Int((Double(width) * scale).rounded()))
        let thumbHeight = max(1, Int((Double(height) * scale).rounded()))
        let low = displayWindow.center - displayWindow.width / 2
        let windowWidth = max(1, displayWindow.width)
        var output = Data(count: thumbWidth * thumbHeight)
        output.withUnsafeMutableBytes { destination in
            guard let out = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            pixels.withUnsafeBytes { source in
                guard let input = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for y in 0..<thumbHeight {
                    let sourceY = min(height - 1, y * height / thumbHeight)
                    for x in 0..<thumbWidth {
                        let sourceX = min(width - 1, x * width / thumbWidth)
                        let index = sourceY * width + sourceX
                        let value: Double
                        if bitDepth == 8 {
                            value = Double(input[index])
                        } else {
                            let offset = index * 2
                            value = Double(UInt16(input[offset]) | (UInt16(input[offset + 1]) << 8))
                        }
                        let gray = (value - low) * 255 / windowWidth
                        out[y * thumbWidth + x] = UInt8(max(0, min(255, gray.rounded())))
                    }
                }
            }
        }
        return try encode(bytes: output, width: thumbWidth, height: thumbHeight, type: .png, quality: 1)
    }

    private func grayscaleBytes(window: DisplayWindow, inverted: Bool) throws -> Data {
        let pixelCount = width * height
        guard pixels.count == pixelCount * bitDepth / 8 else {
            throw RawReadError.invalidLength("Pixel data length no longer matches the selected format.")
        }
        let low = window.center - window.width / 2
        let windowWidth = max(1, window.width)
        var output = Data(count: pixelCount)
        output.withUnsafeMutableBytes { destination in
            guard let out = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            if bitDepth == 8 {
                pixels.withUnsafeBytes { source in
                    guard let input = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    for i in 0..<pixelCount {
                        let gray = (Double(input[i]) - low) * 255 / windowWidth
                        let clipped = UInt8(max(0, min(255, gray.rounded())))
                        out[i] = inverted ? 255 - clipped : clipped
                    }
                }
            } else {
                pixels.withUnsafeBytes { source in
                    guard let input = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    for i in 0..<pixelCount {
                        let offset = i * 2
                        let value = Double(UInt16(input[offset]) | (UInt16(input[offset + 1]) << 8))
                        let gray = (value - low) * 255 / windowWidth
                        let clipped = UInt8(max(0, min(255, gray.rounded())))
                        out[i] = inverted ? 255 - clipped : clipped
                    }
                }
            }
        }
        return output
    }

    private func encode(bytes: Data, width: Int, height: Int, type: UTType, quality: Double) throws -> Data {
        let mutable = NSMutableData(data: bytes)
        guard let provider = CGDataProvider(data: mutable) else {
            throw RawReadError.exportFailed("Could not prepare the image pixels.")
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw RawReadError.exportFailed("Could not create a grayscale preview.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw RawReadError.exportFailed("Could not create the image file.")
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw RawReadError.exportFailed("Image encoding failed.")
        }
        return output as Data
    }
}

enum RawReadError: LocalizedError {
    case unsupportedSize(String)
    case invalidSettings(String)
    case invalidLength(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSize(let message), .invalidSettings(let message), .invalidLength(let message), .exportFailed(let message):
            message
        }
    }
}

enum RawReader {
    static let rxViewHeaderBytes = 200

    static func read(url: URL, settings: RawSettings) throws -> RawFrame {
        let fileData = try Data(contentsOf: url, options: .mappedIfSafe)
        guard settings.width > 0, settings.height > 0, settings.width <= 20000, settings.height <= 20000 else {
            throw RawReadError.invalidSettings("Enter a valid image width and height.")
        }
        let count = settings.width * settings.height
        let detected = try detect(fileSize: fileData.count, pixelCount: count, settings: settings, name: url.lastPathComponent)
        let pixelData = fileData.subdata(in: detected.headerBytes..<fileData.count)
        let window = initialWindow(pixels: pixelData, bitDepth: detected.bitDepth)
        return RawFrame(sourceURL: url, width: settings.width, height: settings.height,
                        bitDepth: detected.bitDepth, pixels: pixelData, displayWindow: window)
    }

    private static func detect(fileSize: Int, pixelCount: Int, settings: RawSettings, name: String) throws -> (bitDepth: Int, headerBytes: Int) {
        let depths = settings.bitDepth.value.map { [$0] } ?? [16, 8]
        let headers: [Int]
        if let fixedHeader = settings.header.value {
            headers = [fixedHeader]
        } else {
            headers = [0, rxViewHeaderBytes]
        }
        for depth in depths {
            let expected = pixelCount * depth / 8
            if let header = headers.first(where: { expected + $0 == fileSize }) {
                return (depth, header)
            }
        }
        let sizes = depths.map { "\($0)-bit: \(pixelCount * $0 / 8) or \(pixelCount * $0 / 8 + rxViewHeaderBytes) bytes" }
            .joined(separator: "; ")
        throw RawReadError.unsupportedSize("\(name) is \(fileSize) bytes. Expected \(sizes). Adjust the RAW format settings to continue.")
    }

    private static func initialWindow(pixels: Data, bitDepth: Int) -> DisplayWindow {
        let bins = bitDepth == 8 ? 256 : 65536
        var histogram = [Int](repeating: 0, count: bins)
        let stride = max(1, pixels.count / 1_000_000 / (bitDepth / 8))
        if bitDepth == 8 {
            pixels.withUnsafeBytes { bytes in
                guard let values = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var i = 0
                while i < pixels.count { histogram[Int(values[i])] += 1; i += stride }
            }
        } else {
            pixels.withUnsafeBytes { bytes in
                guard let values = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                let samples = pixels.count / 2
                var i = 0
                while i < samples {
                    let offset = i * 2
                    let value = Int(values[offset]) | (Int(values[offset + 1]) << 8)
                    histogram[value] += 1
                    i += stride
                }
            }
        }
        let low = percentile(histogram, fraction: 0.01)
        let high = max(low + 1, percentile(histogram, fraction: 0.99))
        return DisplayWindow(center: Double(low + high) / 2, width: Double(high - low))
    }

    private static func percentile(_ histogram: [Int], fraction: Double) -> Int {
        let total = histogram.reduce(0, +)
        let target = max(1, Int(Double(total) * fraction))
        var sum = 0
        for (index, amount) in histogram.enumerated() {
            sum += amount
            if sum >= target { return index }
        }
        return histogram.count - 1
    }
}
