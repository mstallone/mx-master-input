import Foundation

/// A Logitech HID++ report. Requests go out as 20-byte long reports; replies and notifications arrive as
/// either length, with or without the report ID depending on the transport.
struct HIDPPPacket: Equatable, Sendable {
    static let shortReportID: UInt8 = 0x10
    static let longReportID: UInt8 = 0x11
    static let shortReportLength = 7
    static let longReportLength = 20
    /// Identifies our requests, so replies to other HID++ clients (Logi Options+, Solaar) are ignored.
    static let softwareID: UInt8 = 0x0A

    let reportID: UInt8?
    let deviceIndex: UInt8
    let featureIndex: UInt8
    let function: UInt8
    let softwareID: UInt8
    let parameters: [UInt8]

    /// The Bolt receiver answers requests for empty slots with the HID++ 1.0 error envelope (0x8F), even
    /// when the request was HID++ 2.0. Both envelopes put our software ID in the first parameter.
    var isError: Bool { featureIndex == 0xFF || (reportID == Self.shortReportID && featureIndex == 0x8F) }

    var errorCode: UInt8? { isError && parameters.count > 1 ? parameters[1] : nil }

    /// The receiver's HID++ 1.0 notification that a paired device's wireless link changed.
    var isDeviceConnectionNotification: Bool { featureIndex == 0x41 }

    /// Bit 6 of the device-info byte is clear while the link is established.
    var reportsEstablishedLink: Bool {
        isDeviceConnectionNotification && parameters.first.map { $0 & 0x40 == 0 } == true
    }

    static func parse(_ data: Data) -> HIDPPPacket? {
        let bytes = [UInt8](data)
        let offset = bytes.first == shortReportID || bytes.first == longReportID ? 1 : 0
        guard bytes.count >= max(4, offset + 3) else { return nil }
        return HIDPPPacket(
            reportID: offset == 1 ? bytes[0] : nil,
            deviceIndex: bytes[offset],
            featureIndex: bytes[offset + 1],
            function: bytes[offset + 2] >> 4,
            softwareID: bytes[offset + 2] & 0x0F,
            parameters: Array(bytes.dropFirst(offset + 3))
        )
    }

    static func request(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8, parameters: [UInt8]) -> Data {
        var bytes = [UInt8](repeating: 0, count: longReportLength)
        bytes[0] = longReportID
        bytes[1] = deviceIndex
        bytes[2] = featureIndex
        bytes[3] = (function & 0x0F) << 4 | softwareID
        for (index, byte) in parameters.prefix(longReportLength - 4).enumerated() { bytes[index + 4] = byte }
        return Data(bytes)
    }

    /// A HID++ 1.0 register read or write, addressed to the receiver itself.
    static func shortRegisterRequest(deviceIndex: UInt8, command: UInt8, address: UInt8, parameters: [UInt8]) -> Data {
        var bytes = [UInt8](repeating: 0, count: shortReportLength)
        bytes[0] = shortReportID
        bytes[1] = deviceIndex
        bytes[2] = command
        bytes[3] = address
        for (index, byte) in parameters.prefix(3).enumerated() { bytes[index + 4] = byte }
        return Data(bytes)
    }
}

/// HID++ 2.0 feature IDs used here. Each is looked up at connect time to find its per-device index.
enum FeatureID {
    static let deviceName: UInt16 = 0x0005
    static let batteryLevelStatus: UInt16 = 0x1000
    static let unifiedBattery: UInt16 = 0x1004
    static let haptic: UInt16 = 0x19B0
    static let reprogrammableControls: UInt16 = 0x1B04
    static let thumbWheel: UInt16 = 0x2150
}

enum SensePanel {
    static let controlID: UInt16 = 0x01A0
    /// Reprogrammable-control reporting flags: divert with raw XY, and the default without.
    static let divertWithRawXY: UInt8 = 0x33
    static let restoreDefault: UInt8 = 0x22
    /// Bit 0 turns the haptic engine off; the firmware rejects the request without a retained intensity.
    static let hapticOff: [UInt8] = [0x00, 0x32]
}

enum Receiver {
    static let boltProductID = 0xC548
    static let index: UInt8 = 0xFF
    static let readShortRegister: UInt8 = 0x81
    static let writeShortRegister: UInt8 = 0x80
    static let notificationsRegister: UInt8 = 0x00
    static let wirelessNotificationsFlag: UInt8 = 0x01
}

/// Battery readings from either HID++ battery feature.
enum Battery {
    enum Feature: Sendable {
        case unified, levelStatus

        var id: UInt16 { self == .unified ? FeatureID.unifiedBattery : FeatureID.batteryLevelStatus }
        var statusFunction: UInt8 { self == .unified ? 1 : 0 }
    }

    /// Unified battery devices may report only coarse levels. Bit 1 of the capability flags says the
    /// percentage is real, which keeps a genuine 0% distinct from "unknown".
    static func supportsPercentage(_ capabilities: [UInt8]) -> Bool {
        capabilities.count >= 2 && capabilities[1] & 0x02 != 0
    }

    /// The level-status feature uses 0 for "unknown"; the unified feature means empty.
    static func percent(from parameters: [UInt8], feature: Feature) -> Int? {
        guard parameters.count >= (feature == .unified ? 4 : 3), let level = parameters.first, level <= 100,
              feature == .unified || level != 0 else { return nil }
        return Int(level)
    }

    /// True for a reading the mouse pushed on its own (software ID 0), as opposed to a reply to a request
    /// from this app or another HID++ client.
    static func isNotification(_ packet: HIDPPPacket, deviceIndex: UInt8, featureIndex: UInt8) -> Bool {
        packet.deviceIndex == deviceIndex && packet.featureIndex == featureIndex
            && packet.function == 0 && packet.softwareID == 0
    }
}

extension UInt16 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 8), UInt8(self & 0xFF)] }
}

func unsigned16(_ high: UInt8, _ low: UInt8) -> UInt16 { UInt16(high) << 8 | UInt16(low) }
func signed16(_ high: UInt8, _ low: UInt8) -> Int { Int(Int16(bitPattern: unsigned16(high, low))) }
