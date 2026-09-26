import Foundation
import IOKit.hid

/// One Logitech vendor-defined HID collection, the interface that carries HID++. Input reports and
/// removal are delivered on a private serial queue. An opened device cannot be reopened; enumerate again.
final class HIDDevice: @unchecked Sendable {
    let productID: Int
    let usagePage: Int
    let usage: Int
    let transport: String

    private let device: IOHIDDevice
    private let queue = DispatchQueue(label: "com.mattstallone.mxmasterinput.hid", qos: .userInteractive)
    private let bufferSize: Int
    private let buffer: UnsafeMutablePointer<UInt8>
    private var onReport: (@Sendable (Data) -> Void)?
    private var onRemoval: (@Sendable () -> Void)?
    private var cancelled: DispatchSemaphore?

    /// Logitech's HID++ collections, in a stable order. Requiring a vendor usage page and a 20-byte output
    /// report skips the receiver's standard mouse and keyboard collections. Nothing is opened here:
    /// opening every Logitech collection would also open keyboards and mice, which can fail on their own.
    static func hidppInterfaces() -> [HIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046D] as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return devices
            .filter { $0.integer(kIOHIDPrimaryUsagePageKey) >= 0xFF00 && $0.integer(kIOHIDMaxOutputReportSizeKey) >= 20 }
            .map(HIDDevice.init)
            .sorted { ($0.productID, $0.usagePage, $0.usage) < ($1.productID, $1.usagePage, $1.usage) }
    }

    private init(_ device: IOHIDDevice) {
        self.device = device
        productID = device.integer(kIOHIDProductIDKey)
        usagePage = device.integer(kIOHIDPrimaryUsagePageKey)
        usage = device.integer(kIOHIDPrimaryUsageKey)
        transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        bufferSize = max(64, device.integer(kIOHIDMaxInputReportSizeKey))
        buffer = .allocate(capacity: bufferSize)
    }

    deinit {
        close()
        buffer.deallocate()
    }

    func open(onReport: @escaping @Sendable (Data) -> Void, onRemoval: @escaping @Sendable () -> Void) throws {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw HIDError(operation: "IOHIDDeviceOpen", result: result) }
        self.onReport = onReport
        self.onRemoval = onRemoval
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceSetDispatchQueue(device, queue)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, { context, result, _, _, _, report, length in
            guard result == kIOReturnSuccess, let context, length > 0 else { return }
            Unmanaged<HIDDevice>.fromOpaque(context).takeUnretainedValue().onReport?(Data(bytes: report, count: length))
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
            guard let context else { return }
            Unmanaged<HIDDevice>.fromOpaque(context).takeUnretainedValue().onRemoval?()
        }, context)
        let cancelled = DispatchSemaphore(value: 0)
        self.cancelled = cancelled
        IOHIDDeviceSetCancelHandler(device) { cancelled.signal() }
        IOHIDDeviceActivate(device)
    }

    func send(_ report: Data) throws {
        let result = report.withUnsafeBytes { bytes in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(report[0]),
                                 bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), report.count)
        }
        guard result == kIOReturnSuccess else { throw HIDError(operation: "IOHIDDeviceSetReport", result: result) }
    }

    /// Stops delivery and closes the device. Waits, without a timeout, until no callback can still run:
    /// after that the buffer and the unretained context are safe to release. The handlers never block,
    /// so the wait is short; it must not be called from a report or removal handler.
    func close() {
        guard let cancelled else { return }
        self.cancelled = nil
        IOHIDDeviceCancel(device)
        cancelled.wait()
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        onReport = nil
        onRemoval = nil
    }
}

struct HIDError: LocalizedError {
    let operation: String
    let result: IOReturn
    var errorDescription: String? { "\(operation) failed: \(String(format: "0x%08X", result))" }
}

private extension IOHIDDevice {
    func integer(_ key: String) -> Int { IOHIDDeviceGetProperty(self, key as CFString) as? Int ?? 0 }
}
