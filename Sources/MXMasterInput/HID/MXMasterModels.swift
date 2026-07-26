import Foundation

enum MXMasterProtocol {
    static let sensePanelControlID: UInt16 = 0x01A0
    static let divertPanelWithRawXY: UInt8 = 0x33
    static let restorePanelRawXYDefault: UInt8 = 0x22

    // Bit zero is the enable flag. Firmware still requires a valid retained
    // intensity when the flag is clear.
    static let hapticOffParameters: [UInt8] = [0x00, 0x32]
}

struct ReprogrammableControl: Equatable, Sendable {
    let index: UInt8
    let controlID: UInt16
    let taskID: UInt16
    let flags: UInt16
    let position: UInt8
    let group: UInt8
    let groupMask: UInt8

    var isDivertable: Bool {
        flags & 0x0020 != 0
    }

    var supportsRawXY: Bool {
        flags & 0x0100 != 0 || flags & 0x0200 != 0
    }
}

struct ConnectedMXMaster: Equatable, Sendable {
    let name: String
    let transport: String
    let receiverProductID: Int
    let deviceIndex: UInt8
    let controls: [ReprogrammableControl]
    let hapticSupported: Bool
    let hapticDisabled: Bool
    let panelDiverted: Bool
}

enum MXMasterEvent: Equatable, Sendable {
    case status(String)
    case connected(ConnectedMXMaster)
    case disconnected
    case panelDown
    case panelUp
    case direction(GestureDirection)
    case tap
    case error(String)
}

enum MXMasterSessionError: LocalizedError {
    case noVendorInterface
    case unableToOpen(String)
    case noMXMaster4
    case missingSensePanel
    case missingHapticFeature
    case hapticDisableFailed
    case panelDiversionFailed
    case stopped

    var errorDescription: String? {
        switch self {
        case .noVendorInterface:
            "No Logitech HID++ vendor interface is available."
        case let .unableToOpen(message):
            "Unable to open the Logitech HID++ interface: \(message)"
        case .noMXMaster4:
            "The receiver is present, but no MX Master 4 responded. Move the mouse to wake it, then enable again."
        case .missingSensePanel:
            "The MX Master 4 did not advertise its Sense Panel control."
        case .missingHapticFeature:
            "The MX Master 4 did not advertise its haptic-control feature."
        case .hapticDisableFailed:
            "The MX Master 4 did not confirm that its haptic engine was turned off."
        case .panelDiversionFailed:
            "The MX Master 4 rejected Sense Panel RawXY diversion."
        case .stopped:
            "The device session was stopped."
        }
    }
}
