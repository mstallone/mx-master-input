import Foundation
import XCTest

private final class PostedActionRecorder: @unchecked Sendable {
    struct Entry {
        let keyCode: Int
        let time: TimeInterval
    }

    private let lock = NSLock()
    private var storedEntries: [Entry] = []
    private var storedActions: [PanelAction] = []

    func post(keyCode: Int) -> Bool {
        lock.lock()
        storedEntries.append(
            Entry(
                keyCode: keyCode,
                time: ProcessInfo.processInfo.systemUptime
            )
        )
        lock.unlock()
        return true
    }

    func complete(action: PanelAction) {
        lock.lock()
        storedActions.append(action)
        lock.unlock()
    }

    func snapshot() -> (entries: [Entry], actions: [PanelAction]) {
        lock.lock()
        let snapshot = (storedEntries, storedActions)
        lock.unlock()
        return snapshot
    }
}

final class SystemActionControllerTests: XCTestCase {
    func testProductionCadenceExceedsMeasuredSpaceAnimation() {
        let controller = SystemActionController()

        XCTAssertEqual(controller.minimumSpaceActionInterval, 1.2)
    }

    func testRapidAlternatingActionsArePostedInOrderAndPaced() {
        let recorder = PostedActionRecorder()
        let completion = expectation(description: "All actions complete")
        completion.expectedFulfillmentCount = 6
        let controller = SystemActionController(
            minimumSpaceActionInterval: 0.02,
            postControlArrow: { keyCode in
                recorder.post(keyCode: keyCode)
            }
        )

        for direction in [
            GestureDirection.left,
            .right,
            .left,
            .right,
            .left,
            .right,
        ] {
            controller.perform(direction) { result in
                recorder.complete(action: result.action)
                completion.fulfill()
            }
        }

        wait(for: [completion], timeout: 2)
        let snapshot = recorder.snapshot()

        XCTAssertEqual(
            snapshot.entries.map(\.keyCode),
            [124, 123, 124, 123, 124, 123]
        )
        XCTAssertEqual(
            snapshot.actions,
            [
                .nextSpace,
                .previousSpace,
                .nextSpace,
                .previousSpace,
                .nextSpace,
                .previousSpace,
            ]
        )

        for (first, second) in zip(
            snapshot.entries,
            snapshot.entries.dropFirst()
        ) {
            XCTAssertGreaterThanOrEqual(second.time - first.time, 0.015)
        }
    }

    func testMissionControlBypassesPendingSpaceAction() {
        let recorder = PostedActionRecorder()
        let completion = expectation(description: "All actions complete")
        completion.expectedFulfillmentCount = 3
        let controller = SystemActionController(
            minimumSpaceActionInterval: 0.2,
            postControlArrow: { keyCode in
                recorder.post(keyCode: keyCode)
            }
        )

        controller.perform(.left) { result in
            recorder.complete(action: result.action)
            completion.fulfill()
        }
        controller.perform(.right) { result in
            recorder.complete(action: result.action)
            completion.fulfill()
        }
        controller.performTap { result in
            recorder.complete(action: result.action)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
        let snapshot = recorder.snapshot()

        XCTAssertEqual(snapshot.entries.map(\.keyCode), [124, 126, 123])
        XCTAssertEqual(
            snapshot.actions,
            [.nextSpace, .missionControl, .previousSpace]
        )
        XCTAssertLessThan(
            snapshot.entries[1].time - snapshot.entries[0].time,
            0.15
        )
        XCTAssertGreaterThanOrEqual(
            snapshot.entries[2].time - snapshot.entries[0].time,
            0.19
        )
    }
}
