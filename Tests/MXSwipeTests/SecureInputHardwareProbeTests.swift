import Carbon
import XCTest
@testable import MXSwipe

/// Opt-in check against a real MX Master 4, skipped by default:
///
///     MXMASTER_RUN_HARDWARE_PROBE=1 swift test --filter SecureInputHardwareProbeTests
///
/// Turns on Secure Event Input for this process, then connects in observation mode, which reads from the
/// mouse without diverting a control, changing haptics, or posting an event.
final class SecureInputHardwareProbeTests: XCTestCase {
    func testReadsMXMaster4DirectlyWhileSecureInputIsEnabled() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MXMASTER_RUN_HARDWARE_PROBE"] == "1", "Hardware probe is opt-in.")

        let enabled = await MainActor.run { EnableSecureEventInput() }
        XCTAssertEqual(enabled, noErr)
        XCTAssertTrue(IsSecureEventInputEnabled())

        let session = MXMasterSession()
        let result: Result<ConnectedMouse, Error>
        do { result = .success(try await session.start(activeMode: false) { _ in }) } catch { result = .failure(error) }
        await session.stop()
        let disabled = await MainActor.run { DisableSecureEventInput() }
        XCTAssertEqual(disabled, noErr)

        let mouse = try result.get()
        XCTAssertTrue(mouse.name.localizedCaseInsensitiveContains("MX Master 4"))
        XCTAssertTrue(mouse.hapticSupported)
        XCTAssertFalse(mouse.hapticDisabled)
        XCTAssertFalse(mouse.panelDiverted)
        let battery = try XCTUnwrap(mouse.batteryPercent)
        XCTAssertTrue((0 ... 100).contains(battery))
        print("\(mouse.name) battery: \(battery)%")
    }
}
