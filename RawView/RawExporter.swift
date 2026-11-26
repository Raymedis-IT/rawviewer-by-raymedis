import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case png = "PNG"
    case jpeg = "JPEG"
    case dicom = "DICOM"
    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .dicom: "dcm"
        }
    }
}

enum RawExporter {
    static func write(_ frame: RawFrame, to destination: URL, format: ExportFormat,
                      window: DisplayWindow, inverted: Bool, studyUID: String,
                      seriesUID: String, instanceNumber: Int) throws {
        switch format {
        case .png:
            try frame.displayPNG(window: window, inverted: inverted).write(to: destination, options: .atomic)
        case .jpeg:
            try frame.displayJPEG(window: window, inverted: inverted).write(to: destination, options: .atomic)
        case .dicom:
            try DicomEncoder.encode(frame: frame, window: window, inverted: inverted,
                                    studyUID: studyUID, seriesUID: seriesUID,
                                    instanceNumber: instanceNumber).write(to: destination, options: .atomic)
        }
    }
}

private enum DicomEncoder {
    private static let sopClassUID = "1.2.840.10008.5.1.4.1.1.7"
    private static let transferSyntaxUID = "1.2.840.10008.1.2.1"

    static func encode(frame: RawFrame, window: DisplayWindow, inverted: Bool,
                       studyUID: String, seriesUID: String, instanceNumber: Int) -> Data {
        let sopUID = newUID()
        let date = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        let dateString = formatter.string(from: date)
        formatter.dateFormat = "HHmmss"
        let timeString = formatter.string(from: date)

        var meta = Data()
        meta.append(element(0x0002, 0x0001, "OB", Data([0, 1])))
        meta.append(element(0x0002, 0x0002, "UI", text(sopClassUID, vr: "UI")))
        meta.append(element(0x0002, 0x0003, "UI", text(sopUID, vr: "UI")))
        meta.append(element(0x0002, 0x0010, "UI", text(transferSyntaxUID, vr: "UI")))
        meta.append(element(0x0002, 0x0012, "UI", text("2.25.31415926535897932384626433832795028841", vr: "UI")))
        meta.append(element(0x0002, 0x0013, "SH", text("RAYMEDIS_RAW_1", vr: "SH")))

        var file = Data(repeating: 0, count: 128)
        file.append(contentsOf: [0x44, 0x49, 0x43, 0x4D])
        file.append(element(0x0002, 0x0000, "UL", uint32(UInt32(meta.count))))
        file.append(meta)
        file.append(element(0x0008, 0x0016, "UI", text(sopClassUID, vr: "UI")))
        file.append(element(0x0008, 0x0018, "UI", text(sopUID, vr: "UI")))
        file.append(element(0x0008, 0x0020, "DA", text(dateString, vr: "DA")))
        file.append(element(0x0008, 0x0023, "DA", text(dateString, vr: "DA")))
        file.append(element(0x0008, 0x0030, "TM", text(timeString, vr: "TM")))
        file.append(element(0x0008, 0x0033, "TM", text(timeString, vr: "TM")))
        file.append(element(0x0008, 0x0060, "CS", text("OT", vr: "CS")))
        file.append(element(0x0008, 0x0064, "CS", text("WSD", vr: "CS")))
        file.append(element(0x0008, 0x0070, "LO", text("Raymedis", vr: "LO")))
        file.append(element(0x0008, 0x103E, "LO", text(frame.sourceURL.deletingPathExtension().lastPathComponent, vr: "LO")))
        file.append(element(0x0010, 0x0010, "PN", text("Anonymous", vr: "PN")))
        file.append(element(0x0010, 0x0020, "LO", text("RAW-EXPORT", vr: "LO")))
        file.append(element(0x0020, 0x000D, "UI", text(studyUID, vr: "UI")))
        file.append(element(0x0020, 0x000E, "UI", text(seriesUID, vr: "UI")))
        file.append(element(0x0020, 0x0010, "SH", text("RAWEXPORT", vr: "SH")))
        file.append(element(0x0020, 0x0011, "IS", text("1", vr: "IS")))
        file.append(element(0x0020, 0x0013, "IS", text(String(instanceNumber), vr: "IS")))
        file.append(element(0x0028, 0x0002, "US", uint16(1)))
        file.append(element(0x0028, 0x0004, "CS", text(inverted ? "MONOCHROME1" : "MONOCHROME2", vr: "CS")))
        file.append(element(0x0028, 0x0010, "US", uint16(UInt16(frame.height))))
        file.append(element(0x0028, 0x0011, "US", uint16(UInt16(frame.width))))
        file.append(element(0x0028, 0x0100, "US", uint16(UInt16(frame.bitDepth))))
        file.append(element(0x0028, 0x0101, "US", uint16(UInt16(frame.bitDepth))))
        file.append(element(0x0028, 0x0102, "US", uint16(UInt16(frame.bitDepth - 1))))
        file.append(element(0x0028, 0x0103, "US", uint16(0)))
        file.append(element(0x0028, 0x1050, "DS", text(String(Int(window.center.rounded())), vr: "DS")))
        file.append(element(0x0028, 0x1051, "DS", text(String(max(1, Int(window.width.rounded()))), vr: "DS")))
        file.append(element(0x7FE0, 0x0010, frame.bitDepth == 8 ? "OB" : "OW", frame.pixels))
        return file
    }

    private static func element(_ group: UInt16, _ tag: UInt16, _ vr: String, _ value: Data) -> Data {
        var paddedValue = value
        if paddedValue.count % 2 == 1 {
            paddedValue.append(["UI", "OB", "OW"].contains(vr) ? 0 : 0x20)
        }
        var data = Data()
        appendLittleEndian(group, to: &data)
        appendLittleEndian(tag, to: &data)
        data.append(contentsOf: vr.utf8)
        if ["OB", "OW", "OF", "SQ", "UT", "UN", "UC", "UR"].contains(vr) {
            data.append(contentsOf: [0, 0])
            appendLittleEndian(UInt32(paddedValue.count), to: &data)
        } else {
            appendLittleEndian(UInt16(paddedValue.count), to: &data)
        }
        data.append(paddedValue)
        return data
    }

    private static func text(_ value: String, vr: String) -> Data {
        var data = Data(value.utf8)
        if data.count % 2 == 1 { data.append(vr == "UI" ? 0 : 0x20) }
        return data
    }

    private static func uint16(_ value: UInt16) -> Data {
        var data = Data()
        appendLittleEndian(value, to: &data)
        return data
    }

    private static func uint32(_ value: UInt32) -> Data {
        var data = Data()
        appendLittleEndian(value, to: &data)
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var number = value.littleEndian
        withUnsafeBytes(of: &number) { data.append(contentsOf: $0) }
    }

    private static func newUID() -> String {
        "2.25.\(UInt64.random(in: 1...UInt64.max))"
    }
}
