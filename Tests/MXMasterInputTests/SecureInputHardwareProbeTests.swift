import Carbon
import Foundation
import XCTest

/// Opt-in hardware verification. The normal test suite skips this test.
///
/// Run with:
/// MXMASTER_RUN_HARDWARE_PROBE=1 xcodebuild ... \
///   -only-testing:MXMasterInputTests/SecureInputHardwareProbeTests
///
/// The probe enables Secure Event Input only for its own process lifetime,
/// performs HID++ reads in observation mode, and then disables Secure Event
/// Input. It does not divert a control, change haptic state, or post an event.
final class SecureInputHardwareProbeTests: XCTestCase {
    func testReadsMXMaster4DirectlyWhileSecureInputIsEnabled() async throws {
        guard ProcessInfo.processInfo.environment[
            "MXMASTER_RUN_HARDWARE_PROBE"
        ] == "1" else {
            throw XCTSkip("Hardware probe is opt-in.")
        }

        let enableStatus = await MainActor.run {
            EnableSecureEventInput()
        }
        XCTAssertEqual(enableStatus, noErr)

        let secureInputBecameEnabled = await MainActor.run {
            IsSecureEventInputEnabled()
        }
        XCTAssertTrue(secureInputBecameEnabled)

        let session = MXMasterSession()
        do {
            let device = try await session.start(
                activeMode: false,
                eventHandler: { _ in },
                gestureHandler: { _ in
                    XCTFail("Observation mode must not produce a gesture.")
                },
                tapHandler: {
                    XCTFail("Observation mode must not produce a tap.")
                }
            )

            XCTAssertTrue(
                device.name.localizedCaseInsensitiveContains("MX Master 4")
            )
            XCTAssertTrue(device.hapticSupported)
            XCTAssertFalse(device.hapticDisabled)
            XCTAssertFalse(device.panelDiverted)
            await session.stop()
        } catch {
            await session.stop()
            _ = await MainActor.run {
                DisableSecureEventInput()
            }
            throw error
        }

        let disableStatus = await MainActor.run {
            DisableSecureEventInput()
        }
        XCTAssertEqual(disableStatus, noErr)
    }
}
