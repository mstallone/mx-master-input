import XCTest
@testable import MXSwipe

final class BatteryTests: XCTestCase {
    func testReadsBothStatusFormats() {
        for percent: UInt8 in [1, 87, 100] {
            XCTAssertEqual(Battery.percent(from: [percent, 0x02, 0x00, 0x01], feature: .unified), Int(percent))
            XCTAssertEqual(Battery.percent(from: [percent, 0x02, 0x00], feature: .levelStatus), Int(percent))
        }
    }

    func testZeroIsEmptyForUnifiedButUnknownForLevelStatus() {
        XCTAssertEqual(Battery.percent(from: [0, 1, 0, 0], feature: .unified), 0)
        XCTAssertNil(Battery.percent(from: [0, 0, 0], feature: .levelStatus))
    }

    func testRejectsTruncatedAndOutOfRangeStatus() {
        for feature in [Battery.Feature.unified, .levelStatus] {
            for parameters: [UInt8] in [[], [87], [87, 0], [101, 0, 0, 0], [255, 0, 0, 0]] {
                XCTAssertNil(Battery.percent(from: parameters, feature: feature))
            }
        }
        XCTAssertNil(Battery.percent(from: [87, 0, 0], feature: .unified))
    }

    func testRequiresStateOfChargeCapability() {
        XCTAssertTrue(Battery.supportsPercentage([0x0F, 0x02]))
        XCTAssertTrue(Battery.supportsPercentage([0, 0x03]))
        for parameters: [UInt8] in [[], [0x02], [0x0F, 0x01], [0x02, 0]] {
            XCTAssertFalse(Battery.supportsPercentage(parameters))
        }
    }

    func testAcceptsOnlyNotificationsForTheSelectedDeviceAndFeature() {
        XCTAssertTrue(isNotification())
        XCTAssertFalse(isNotification(device: 2))
        XCTAssertFalse(isNotification(feature: 9))
        XCTAssertFalse(isNotification(function: 1))
        // Replies to this app's requests, or another client's, are not unsolicited readings.
        XCTAssertFalse(isNotification(softwareID: HIDPPPacket.softwareID))
        XCTAssertFalse(isNotification(softwareID: 1))
    }

    private func isNotification(device: UInt8 = 1, feature: UInt8 = 8, function: UInt8 = 0, softwareID: UInt8 = 0) -> Bool {
        let packet = HIDPPPacket(reportID: HIDPPPacket.longReportID, deviceIndex: device, featureIndex: feature,
                                 function: function, softwareID: softwareID, parameters: [87, 0, 0, 0])
        return Battery.isNotification(packet, deviceIndex: 1, featureIndex: 8)
    }
}
