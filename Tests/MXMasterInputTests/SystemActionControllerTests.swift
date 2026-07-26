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

        XCTAssertEqual(controller.minimumActionInterval, 1.2)
    }

    func testRapidAlternatingActionsArePostedInOrderAndPaced() {
        let recorder = PostedActionRecorder()
        let completion = expectation(description: "All actions complete")
        completion.expectedFulfillmentCount = 6
        let controller = SystemActionController(
            minimumActionInterval: 0.02,
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
}
