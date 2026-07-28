import Foundation

struct HIDPPPacket: Equatable, Sendable {
    static let shortReportID: UInt8 = 0x10
    static let longReportID: UInt8 = 0x11
    static let shortReportLength = 7
    static let longReportLength = 20
    static let softwareID: UInt8 = 0x0A

    let reportID: UInt8?
    let deviceIndex: UInt8
    let featureIndex: UInt8
    let function: UInt8
    let softwareID: UInt8
    let parameters: [UInt8]

    var isError: Bool {
        featureIndex == 0xFF
    }

    var errorCode: UInt8? {
        guard isError, parameters.count > 1 else {
            return nil
        }
        return parameters[1]
    }

    /// HID++ 1.0 receiver notification sent when a paired device changes its
    /// wireless-link state. Modern HID++ 2.0 devices still use this receiver
    /// notification envelope.
    var isDeviceConnectionNotification: Bool {
        featureIndex == 0x41
    }

    /// `true` when a device-connection notification says the wireless link is
    /// established. Bit 6 of the device-info byte is clear while in range.
    var reportsEstablishedLink: Bool {
        isDeviceConnectionNotification
            && parameters.first.map { $0 & 0x40 == 0 } == true
    }

    static func parse(_ data: Data) -> HIDPPPacket? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else {
            return nil
        }

        let includesReportID =
            bytes[0] == shortReportID || bytes[0] == longReportID
        let offset = includesReportID ? 1 : 0
        guard bytes.count >= offset + 3 else {
            return nil
        }

        let functionAndSoftwareID = bytes[offset + 2]
        return HIDPPPacket(
            reportID: includesReportID ? bytes[0] : nil,
            deviceIndex: bytes[offset],
            featureIndex: bytes[offset + 1],
            function: (functionAndSoftwareID >> 4) & 0x0F,
            softwareID: functionAndSoftwareID & 0x0F,
            parameters: Array(bytes.dropFirst(offset + 3))
        )
    }

    static func request(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        function: UInt8,
        parameters: [UInt8]
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: longReportLength)
        bytes[0] = longReportID
        bytes[1] = deviceIndex
        bytes[2] = featureIndex
        bytes[3] = ((function & 0x0F) << 4) | softwareID

        for (index, byte) in parameters.prefix(longReportLength - 4).enumerated() {
            bytes[index + 4] = byte
        }
        return Data(bytes)
    }

    static func shortRegisterRequest(
        deviceIndex: UInt8,
        command: UInt8,
        address: UInt8,
        parameters: [UInt8]
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: shortReportLength)
        bytes[0] = shortReportID
        bytes[1] = deviceIndex
        bytes[2] = command
        bytes[3] = address

        for (index, byte) in parameters.prefix(3).enumerated() {
            bytes[index + 4] = byte
        }
        return Data(bytes)
    }
}
