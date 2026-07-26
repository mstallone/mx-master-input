import XCTest

final class ContinuousGestureRecognizerTests: XCTestCase {
    func testDirectionsMapToStandardMacOSArrowKeyCodes() {
        XCTAssertEqual(GestureDirection.left.controlArrowKeyCode, 123)
        XCTAssertEqual(GestureDirection.right.controlArrowKeyCode, 124)
    }

    func testSpaceDirectionsAreReversed() {
        XCTAssertEqual(GestureDirection.left.reversedSpaceDirection, .right)
        XCTAssertEqual(GestureDirection.right.reversedSpaceDirection, .left)
    }

    func testActivationEmitsBufferedMotionAsBegan() {
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30
        )

        recognizer.begin()
        XCTAssertNil(recognizer.ingest(dx: -10, dy: 20))
        XCTAssertEqual(
            recognizer.ingest(dx: -5, dy: 10),
            ContinuousGestureUpdate(
                phase: .began,
                dx: -15,
                dy: 30
            )
        )
    }

    func testEveryHorizontalUpdateIsPreservedAfterActivation() {
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30
        )

        recognizer.begin()
        XCTAssertEqual(
            recognizer.ingest(dx: 30, dy: 0),
            ContinuousGestureUpdate(phase: .began, dx: 30, dy: 0)
        )
        XCTAssertEqual(
            recognizer.ingest(dx: 7, dy: 2),
            ContinuousGestureUpdate(phase: .changed, dx: 7, dy: 2)
        )
        XCTAssertEqual(
            recognizer.ingest(dx: 9, dy: -2),
            ContinuousGestureUpdate(phase: .changed, dx: 9, dy: -2)
        )
    }

    func testReversalsRemainInTheSameContinuousGesture() {
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30
        )

        recognizer.begin()
        XCTAssertEqual(recognizer.ingest(dx: -30, dy: 0)?.phase, .began)
        XCTAssertEqual(
            recognizer.ingest(dx: 20, dy: 0),
            ContinuousGestureUpdate(phase: .changed, dx: 20, dy: 0)
        )
        XCTAssertEqual(
            recognizer.ingest(dx: -18, dy: 0),
            ContinuousGestureUpdate(phase: .changed, dx: -18, dy: 0)
        )
        XCTAssertTrue(recognizer.end().didBeginSwipe)
    }

    func testSteepDiagonalTowardRightBeginsRight() {
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30,
            horizontalDeadZone: 12
        )

        recognizer.begin()
        let update = recognizer.ingest(dx: 12, dy: -30)

        XCTAssertEqual(update?.phase, .began)
        XCTAssertEqual(update?.direction, .right)
    }

    func testSteepDiagonalTowardLeftBeginsLeft() {
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30,
            horizontalDeadZone: 12
        )

        recognizer.begin()
        let update = recognizer.ingest(dx: -12, dy: 30)

        XCTAssertEqual(update?.phase, .began)
        XCTAssertEqual(update?.direction, .left)
    }

    func testClickPressureMotionInsideDeadZoneDoesNotBeginSwipe() {
        var currentTime = 10.0
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30,
            horizontalDeadZone: 12,
            maximumTapDuration: 0.4,
            now: { currentTime }
        )

        recognizer.begin()
        XCTAssertNil(recognizer.ingest(dx: 5, dy: 40))
        currentTime += 0.2

        let end = recognizer.end()
        XCTAssertFalse(end.didBeginSwipe)
        XCTAssertTrue(end.isTap)
    }

    func testMotionBeforePostPressArmingWindowIsDiscarded() {
        var currentTime = 10.0
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30,
            horizontalDeadZone: 12,
            motionActivationDelay: 0.06,
            now: { currentTime }
        )

        recognizer.begin()
        XCTAssertNil(recognizer.ingest(dx: 40, dy: 0))

        currentTime += 0.061
        XCTAssertEqual(
            recognizer.ingest(dx: 30, dy: 0),
            ContinuousGestureUpdate(phase: .began, dx: 30, dy: 0)
        )
    }

    func testQueuedPrePressMotionDoesNotDisqualifyClick() {
        var currentTime = 10.0
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30,
            horizontalDeadZone: 12,
            motionActivationDelay: 0.06,
            maximumTapDuration: 0.4,
            now: { currentTime }
        )

        recognizer.begin()
        XCTAssertNil(recognizer.ingest(dx: -40, dy: 20))
        currentTime += 0.2

        XCTAssertTrue(recognizer.end().isTap)
    }

    func testShortLowMotionPressIsTap() {
        var currentTime = 10.0
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30,
            horizontalDeadZone: 12,
            maximumTapDuration: 0.4,
            now: { currentTime }
        )

        recognizer.begin()
        XCTAssertNil(recognizer.ingest(dx: 3, dy: 2))
        currentTime += 0.2

        XCTAssertTrue(recognizer.end().isTap)
    }

    func testLongHoldWithoutMovementIsNotTap() {
        var currentTime = 10.0
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30,
            maximumTapDuration: 0.4,
            now: { currentTime }
        )

        recognizer.begin()
        currentTime += 0.5

        XCTAssertFalse(recognizer.end().isTap)
    }

    func testHorizontalMovementOutsideDeadZoneIsNotTap() {
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30,
            horizontalDeadZone: 12
        )

        recognizer.begin()
        XCTAssertNil(recognizer.ingest(dx: 13, dy: 0))

        XCTAssertFalse(recognizer.end().isTap)
    }

    func testCancelReportsWhetherDockSwipeNeedsCancellation() {
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30
        )

        recognizer.begin()
        XCTAssertFalse(recognizer.cancel())

        recognizer.begin()
        XCTAssertNotNil(recognizer.ingest(dx: 30, dy: 0))
        XCTAssertTrue(recognizer.cancel())
        XCTAssertFalse(recognizer.isTracking)
    }
}
