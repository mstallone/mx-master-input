import Foundation
import XCTest

final class MXMasterSessionBatteryTests: XCTestCase {
    func testReadsBothBatteryStatusFormats() {
        for percent: UInt8 in [1, 87, 100] {
            XCTAssertEqual(
                MXMasterSession.batteryPercent(
                    from: [percent, 0x02, 0x00, 0x01], feature: .unified
                ), Int(percent)
            )
            XCTAssertEqual(
                MXMasterSession.batteryPercent(
                    from: [percent, 0x02, 0x00], feature: .levelStatus
                ), Int(percent)
            )
        }
    }

    func testZeroIsEmptyForUnifiedButUnknownForLegacyBattery() {
        XCTAssertEqual(
            MXMasterSession.batteryPercent(from: [0, 1, 0, 0], feature: .unified), 0
        )
        XCTAssertNil(
            MXMasterSession.batteryPercent(from: [0, 0, 0], feature: .levelStatus)
        )
    }

    func testRejectsTruncatedAndOutOfRangeStatus() {
        for feature in [MXMasterSession.BatteryFeature.unified, .levelStatus] {
            for parameters: [UInt8] in [[], [87], [87, 0], [101, 0, 0, 0], [255, 0, 0, 0]] {
                XCTAssertNil(MXMasterSession.batteryPercent(from: parameters, feature: feature))
            }
        }
        XCTAssertNil(MXMasterSession.batteryPercent(from: [87, 0, 0], feature: .unified))
    }

    func testRequiresStateOfChargeCapability() {
        XCTAssertTrue(MXMasterSession.supportsBatteryPercentage([0x0F, 0x02]))
        XCTAssertTrue(MXMasterSession.supportsBatteryPercentage([0, 0x03]))
        for parameters: [UInt8] in [[], [0x02], [0x0F, 0x01], [0x02, 0]] {
            XCTAssertFalse(MXMasterSession.supportsBatteryPercentage(parameters))
        }
    }

    func testAcceptsOnlyBatteryNotificationsForSelectedDeviceAndFeature() {
        XCTAssertEqual(event(), .battery(percent: 87))
        XCTAssertNil(event(device: 2))
        XCTAssertNil(event(feature: 9))
        XCTAssertNil(event(function: 1))
        // Capability/status replies from our client or another application
        // must not be interpreted as unsolicited battery percentages.
        XCTAssertNil(event(softwareID: HIDPPPacket.softwareID))
        XCTAssertNil(event(softwareID: 1))
    }

    func testUnknownNotificationClearsPreviousReading() {
        XCTAssertEqual(event(parameters: [255, 0, 0, 0]), .battery(percent: nil))
        XCTAssertEqual(event(parameters: [0, 1, 0, 0]), .battery(percent: 0))
        XCTAssertEqual(event(parameters: [0, 0, 0], batteryFeature: .levelStatus), .battery(percent: nil))
    }

    private func event(
        device: UInt8 = 1,
        feature: UInt8 = 8,
        function: UInt8 = 0,
        softwareID: UInt8 = 0,
        parameters: [UInt8] = [87, 0, 0, 0],
        batteryFeature: MXMasterSession.BatteryFeature = .unified
    ) -> MXMasterEvent? {
        MXMasterSession.batteryEvent(
            from: HIDPPPacket(
                reportID: HIDPPPacket.longReportID,
                deviceIndex: device,
                featureIndex: feature,
                function: function,
                softwareID: softwareID,
                parameters: parameters
            ),
            deviceIndex: 1,
            featureIndex: 8,
            feature: batteryFeature
        )
    }
}
