import Foundation
import XCTest

final class HIDPPPacketTests: XCTestCase {
    func testRequestEncodingUsesLongReportAndSoftwareID() {
        let data = HIDPPPacket.request(
            deviceIndex: 2,
            featureIndex: 0x07,
            function: 3,
            parameters: [0x01, 0xA0, 0x33]
        )
        let bytes = [UInt8](data)

        XCTAssertEqual(bytes.count, 20)
        XCTAssertEqual(bytes[0], 0x11)
        XCTAssertEqual(bytes[1], 2)
        XCTAssertEqual(bytes[2], 0x07)
        XCTAssertEqual(bytes[3], 0x3A)
        XCTAssertEqual(Array(bytes[4 ... 6]), [0x01, 0xA0, 0x33])
    }

    func testParseReportThatIncludesReportID() {
        let packet = HIDPPPacket.parse(
            Data([0x11, 0x02, 0x07, 0x1A, 0xFF, 0xFE, 0x00])
        )

        XCTAssertEqual(packet?.reportID, 0x11)
        XCTAssertEqual(packet?.deviceIndex, 2)
        XCTAssertEqual(packet?.featureIndex, 0x07)
        XCTAssertEqual(packet?.function, 1)
        XCTAssertEqual(packet?.softwareID, 0x0A)
        XCTAssertEqual(packet?.parameters, [0xFF, 0xFE, 0x00])
    }

    func testParseReportWithoutReportID() {
        let packet = HIDPPPacket.parse(
            Data([0x02, 0x07, 0x00, 0x01, 0xA0, 0x00])
        )

        XCTAssertNil(packet?.reportID)
        XCTAssertEqual(packet?.deviceIndex, 2)
        XCTAssertEqual(packet?.featureIndex, 0x07)
        XCTAssertEqual(packet?.function, 0)
        XCTAssertEqual(packet?.softwareID, 0)
        XCTAssertEqual(packet?.parameters, [0x01, 0xA0, 0x00])
    }

    func testErrorCodeIsDecoded() {
        let packet = HIDPPPacket.parse(
            Data([0x11, 0x02, 0xFF, 0x0A, 0x07, 0x02])
        )

        XCTAssertTrue(packet?.isError == true)
        XCTAssertEqual(packet?.errorCode, 0x02)
    }

    func testHapticOffRequestClearsEnableBitAndRetainsValidIntensity() {
        let data = HIDPPPacket.request(
            deviceIndex: 1,
            featureIndex: 0x0B,
            function: 2,
            parameters: MXMasterProtocol.hapticOffParameters
        )
        let bytes = [UInt8](data)

        XCTAssertEqual(bytes[3], 0x2A)
        XCTAssertEqual(Array(bytes[4 ... 5]), [0x00, 0x32])
    }

    func testSensePanelReportingConstantsMatchMXMaster4Protocol() {
        XCTAssertEqual(MXMasterProtocol.sensePanelControlID, 0x01A0)
        XCTAssertEqual(MXMasterProtocol.divertPanelWithRawXY, 0x33)
        XCTAssertEqual(MXMasterProtocol.restorePanelRawXYDefault, 0x22)
    }
}
