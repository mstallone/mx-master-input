import Foundation
import XCTest

private final class PostedActionRecorder: @unchecked Sendable {
    struct DockEntry {
        let progress: Double
        let phase: Int
        let time: TimeInterval
    }

    private let lock = NSLock()
    private var storedDockEntries: [DockEntry] = []
    private var storedKeyCodes: [Int] = []
    var dockResult = true

    func postDock(progress: Double, phase: Int) -> Bool {
        lock.lock()
        storedDockEntries.append(
            DockEntry(
                progress: progress,
                phase: phase,
                time: ProcessInfo.processInfo.systemUptime
            )
        )
        let result = dockResult
        lock.unlock()
        return result
    }

    func postKey(keyCode: Int) -> Bool {
        lock.lock()
        storedKeyCodes.append(keyCode)
        lock.unlock()
        return true
    }

    func snapshot() -> (dock: [DockEntry], keys: [Int]) {
        lock.lock()
        let snapshot = (storedDockEntries, storedKeyCodes)
        lock.unlock()
        return snapshot
    }
}

final class SystemActionControllerTests: XCTestCase {
    func testContinuousMotionPostsBeganChangedAndEndedProgress() {
        let recorder = PostedActionRecorder()
        let completion = expectation(description: "Gesture completes")
        let controller = makeController(recorder: recorder)

        controller.performGesture(.began(dx: -30)) { _ in
            XCTFail("Began must not complete the action")
        }
        controller.performGesture(.changed(dx: -100)) { _ in
            XCTFail("Changed must not complete the action")
        }
        controller.performGesture(.changed(dx: 80)) { _ in
            XCTFail("Changed must not complete the action")
        }
        controller.performGesture(.ended) { result in
            XCTAssertEqual(result.action, .nextSpace)
            XCTAssertTrue(result.succeeded)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
        let entries = recorder.snapshot().dock

        XCTAssertEqual(entries.map(\.phase), [1, 2, 2, 4])
        XCTAssertEqual(entries[0].progress, 0.072, accuracy: 0.000_001)
        XCTAssertEqual(entries[1].progress, 0.312, accuracy: 0.000_001)
        XCTAssertEqual(entries[2].progress, 0.12, accuracy: 0.000_001)
        XCTAssertEqual(entries[3].progress, 0.12, accuracy: 0.000_001)
    }

    func testRapidReversalsArePostedImmediatelyWithoutQueuing() throws {
        let recorder = PostedActionRecorder()
        let completion = expectation(description: "Gesture completes")
        let controller = makeController(recorder: recorder)

        controller.performGesture(.began(dx: -30)) { _ in }
        for dx in [100, -100, 100, -100, 100, -100] {
            controller.performGesture(.changed(dx: dx)) { _ in }
        }
        controller.performGesture(.ended) { _ in
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
        let entries = recorder.snapshot().dock
        let first = try XCTUnwrap(entries.first)
        let last = try XCTUnwrap(entries.last)

        XCTAssertEqual(entries.map(\.phase), [1, 2, 2, 2, 2, 2, 2, 4])
        XCTAssertLessThan(last.time - first.time, 0.15)
    }

    func testCancellationAlwaysClosesActiveDockSwipe() {
        let recorder = PostedActionRecorder()
        let controller = makeController(recorder: recorder)

        controller.performGesture(.began(dx: 40)) { _ in }
        controller.performGesture(.changed(dx: -10)) { _ in }
        controller.performGesture(.cancelled) { _ in
            XCTFail("Cancellation must not report an action")
        }
        controller.cancelGestureSynchronously()

        let entries = recorder.snapshot().dock
        XCTAssertEqual(entries.map(\.phase), [1, 2, 8])
        XCTAssertEqual(entries[2].progress, -0.072, accuracy: 0.000_001)
    }

    func testNewGestureCancelsAnOverlappingGestureFirst() {
        let recorder = PostedActionRecorder()
        let controller = makeController(recorder: recorder)

        controller.performGesture(.began(dx: -30)) { _ in }
        controller.performGesture(.began(dx: 30)) { _ in }
        controller.cancelGestureSynchronously()

        XCTAssertEqual(
            recorder.snapshot().dock.map(\.phase),
            [1, 8, 1, 8]
        )
    }

    func testKeyboardFallbackRunsOnlyWhenPrivateBeginFails() {
        let recorder = PostedActionRecorder()
        recorder.dockResult = false
        let completion = expectation(description: "Fallback completes")
        let controller = makeController(recorder: recorder)

        controller.performGesture(.began(dx: -30)) { _ in }
        controller.performGesture(.changed(dx: 100)) { _ in }
        controller.performGesture(.ended) { result in
            XCTAssertEqual(result.action, .previousSpace)
            XCTAssertTrue(result.succeeded)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.dock.map(\.phase), [1])
        XCTAssertEqual(snapshot.keys, [123])
    }

    func testMissionControlTapStillUsesImmediateAccessibilityShortcut() {
        let recorder = PostedActionRecorder()
        let completion = expectation(description: "Tap completes")
        let controller = makeController(recorder: recorder)

        controller.performTap { result in
            XCTAssertEqual(result.action, .missionControl)
            XCTAssertTrue(result.succeeded)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
        XCTAssertEqual(recorder.snapshot().keys, [126])
    }

    private func makeController(
        recorder: PostedActionRecorder
    ) -> SystemActionController {
        SystemActionController(
            rawMotionUnitsPerSpace: 500,
            postControlArrow: { keyCode in
                recorder.postKey(keyCode: keyCode)
            },
            postDockSwipe: { progress, phase in
                recorder.postDock(progress: progress, phase: phase)
            }
        )
    }
}
