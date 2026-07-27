import Foundation
import XCTest

private final class PostedActionRecorder: @unchecked Sendable {
    struct DockEntry {
        let axis: GestureAxis
        let progress: Double
        let phase: Int
        let time: TimeInterval
    }

    private let lock = NSLock()
    private var storedDockEntries: [DockEntry] = []
    private var storedKeyCodes: [Int] = []
    var dockResult = true

    func postDock(
        axis: GestureAxis,
        progress: Double,
        phase: Int
    ) -> Bool {
        lock.lock()
        storedDockEntries.append(
            DockEntry(
                axis: axis,
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

        controller.performGesture(
            .began(axis: .horizontal, delta: -30)
        ) { _ in
            XCTFail("Began must not complete the action")
        }
        controller.performGesture(.changed(delta: -100)) { _ in
            XCTFail("Changed must not complete the action")
        }
        controller.performGesture(.changed(delta: 80)) { _ in
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
        XCTAssertEqual(entries.map(\.axis), [
            .horizontal,
            .horizontal,
            .horizontal,
            .horizontal,
        ])
        XCTAssertEqual(entries[0].progress, 0.072, accuracy: 0.000_001)
        XCTAssertEqual(entries[1].progress, 0.312, accuracy: 0.000_001)
        XCTAssertEqual(entries[2].progress, 0.12, accuracy: 0.000_001)
        XCTAssertEqual(entries[3].progress, 0.12, accuracy: 0.000_001)
    }

    func testRapidReversalsArePostedImmediatelyWithoutQueuing() throws {
        let recorder = PostedActionRecorder()
        let completion = expectation(description: "Gesture completes")
        let controller = makeController(recorder: recorder)

        controller.performGesture(
            .began(axis: .horizontal, delta: -30)
        ) { _ in }
        for dx in [100, -100, 100, -100, 100, -100] {
            controller.performGesture(.changed(delta: dx)) { _ in }
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

    func testOppositeSequentialSwipesRestartWithIndependentDirection() {
        let recorder = PostedActionRecorder()
        let firstCompletion = expectation(description: "First gesture completes")
        let secondCompletion = expectation(
            description: "Second gesture completes"
        )
        let controller = makeController(recorder: recorder)

        controller.performGesture(
            .began(axis: .horizontal, delta: -100)
        ) { _ in }
        controller.performGesture(.ended) { _ in
            firstCompletion.fulfill()
        }
        controller.performGesture(
            .began(axis: .horizontal, delta: 100)
        ) { _ in }
        controller.performGesture(.ended) { _ in
            secondCompletion.fulfill()
        }

        wait(for: [firstCompletion, secondCompletion], timeout: 2)
        let entries = recorder.snapshot().dock

        XCTAssertEqual(entries.map(\.phase), [1, 4, 1, 4])
        XCTAssertEqual(entries[0].progress, 0.24, accuracy: 0.000_001)
        XCTAssertEqual(entries[1].progress, 0.24, accuracy: 0.000_001)
        XCTAssertEqual(entries[2].progress, -0.24, accuracy: 0.000_001)
        XCTAssertEqual(entries[3].progress, -0.24, accuracy: 0.000_001)
    }

    func testCancellationAlwaysClosesActiveDockSwipe() {
        let recorder = PostedActionRecorder()
        let controller = makeController(recorder: recorder)

        controller.performGesture(
            .began(axis: .horizontal, delta: 40)
        ) { _ in }
        controller.performGesture(.changed(delta: -10)) { _ in }
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

        controller.performGesture(
            .began(axis: .horizontal, delta: -30)
        ) { _ in }
        controller.performGesture(
            .began(axis: .vertical, delta: -30)
        ) { _ in }
        controller.cancelGestureSynchronously()

        let entries = recorder.snapshot().dock
        XCTAssertEqual(entries.map(\.axis), [
            .horizontal,
            .horizontal,
            .vertical,
            .vertical,
        ])
        XCTAssertEqual(entries.map(\.phase), [1, 8, 1, 8])
    }

    func testKeyboardFallbackRunsOnlyWhenPrivateBeginFails() {
        let recorder = PostedActionRecorder()
        recorder.dockResult = false
        let completion = expectation(description: "Fallback completes")
        let controller = makeController(recorder: recorder)

        controller.performGesture(
            .began(axis: .horizontal, delta: -30)
        ) { _ in }
        controller.performGesture(.changed(delta: 100)) { _ in }
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

    func testUpwardMotionPostsContinuousVerticalMissionControlSwipe() {
        let recorder = PostedActionRecorder()
        let completion = expectation(description: "Gesture completes")
        let controller = makeController(recorder: recorder)

        controller.performGesture(
            .began(axis: .vertical, delta: -30)
        ) { _ in
            XCTFail("Began must not complete the action")
        }
        controller.performGesture(.changed(delta: -100)) { _ in
            XCTFail("Changed must not complete the action")
        }
        controller.performGesture(.changed(delta: 80)) { _ in
            XCTFail("Changed must not complete the action")
        }
        controller.performGesture(.ended) { result in
            XCTAssertEqual(result.action, .missionControl)
            XCTAssertTrue(result.succeeded)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
        let entries = recorder.snapshot().dock

        XCTAssertEqual(entries.map(\.axis), [
            .vertical,
            .vertical,
            .vertical,
            .vertical,
        ])
        XCTAssertEqual(entries.map(\.phase), [1, 2, 2, 4])
        XCTAssertEqual(entries[0].progress, -0.072, accuracy: 0.000_001)
        XCTAssertEqual(entries[1].progress, -0.312, accuracy: 0.000_001)
        XCTAssertEqual(entries[2].progress, -0.12, accuracy: 0.000_001)
        XCTAssertEqual(entries[3].progress, -0.12, accuracy: 0.000_001)
    }

    func testDownwardMotionPostsContinuousVerticalMissionControlSwipe() {
        let recorder = PostedActionRecorder()
        let completion = expectation(description: "Gesture completes")
        let controller = makeController(recorder: recorder)

        controller.performGesture(
            .began(axis: .vertical, delta: 45)
        ) { _ in
            XCTFail("Began must not complete the action")
        }
        controller.performGesture(.changed(delta: 100)) { _ in
            XCTFail("Changed must not complete the action")
        }
        controller.performGesture(.ended) { result in
            XCTAssertEqual(result.action, .missionControl)
            XCTAssertTrue(result.succeeded)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
        let entries = recorder.snapshot().dock

        XCTAssertEqual(entries.map(\.axis), [
            .vertical,
            .vertical,
            .vertical,
        ])
        XCTAssertEqual(entries.map(\.phase), [1, 2, 4])
        XCTAssertEqual(entries[0].progress, 0.108, accuracy: 0.000_001)
        XCTAssertEqual(entries[1].progress, 0.348, accuracy: 0.000_001)
        XCTAssertEqual(entries[2].progress, 0.348, accuracy: 0.000_001)
    }

    func testVerticalGestureFallsBackToMissionControlShortcut() {
        let recorder = PostedActionRecorder()
        recorder.dockResult = false
        let completion = expectation(description: "Fallback completes")
        let controller = makeController(recorder: recorder)

        controller.performGesture(
            .began(axis: .vertical, delta: -30)
        ) { _ in }
        controller.performGesture(.changed(delta: 100)) { _ in }
        controller.performGesture(.ended) { result in
            XCTAssertEqual(result.action, .missionControl)
            XCTAssertTrue(result.succeeded)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.dock.map(\.axis), [.vertical])
        XCTAssertEqual(snapshot.dock.map(\.phase), [1])
        XCTAssertEqual(snapshot.keys, [126])
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
            rawMotionUnitsPerMissionControl: 500,
            postControlArrow: { keyCode in
                recorder.postKey(keyCode: keyCode)
            },
            postDockSwipe: { axis, progress, phase in
                recorder.postDock(
                    axis: axis,
                    progress: progress,
                    phase: phase
                )
            }
        )
    }
}
