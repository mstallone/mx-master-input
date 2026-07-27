import XCTest

final class ContinuousGestureRecognizerTests: XCTestCase {
    func testDirectionsMapToStandardMacOSArrowKeyCodes() {
        XCTAssertEqual(GestureDirection.left.controlArrowKeyCode, 123)
        XCTAssertEqual(GestureDirection.right.controlArrowKeyCode, 124)
        XCTAssertEqual(GestureDirection.up.controlArrowKeyCode, 126)
        XCTAssertEqual(GestureDirection.down.controlArrowKeyCode, 125)
    }

    func testDirectionsAreReversed() {
        XCTAssertEqual(GestureDirection.left.reversed, .right)
        XCTAssertEqual(GestureDirection.right.reversed, .left)
        XCTAssertEqual(GestureDirection.up.reversed, .down)
        XCTAssertEqual(GestureDirection.down.reversed, .up)
    }

    func testAxesMapToNativeDockSwipeMotionTypes() {
        XCTAssertEqual(GestureAxis.horizontal.rawValue, 1)
        XCTAssertEqual(GestureAxis.vertical.rawValue, 2)
    }

    func testActivationEmitsBufferedMotionAsBegan() {
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30
        )

        recognizer.begin()
        XCTAssertNil(recognizer.ingest(dx: -20, dy: 10))
        XCTAssertEqual(
            recognizer.ingest(dx: -10, dy: 5),
            ContinuousGestureUpdate(
                phase: .began,
                axis: .horizontal,
                dx: -30,
                dy: 15
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
            ContinuousGestureUpdate(
                phase: .began,
                axis: .horizontal,
                dx: 30,
                dy: 0
            )
        )
        XCTAssertEqual(
            recognizer.ingest(dx: 7, dy: 2),
            ContinuousGestureUpdate(
                phase: .changed,
                axis: .horizontal,
                dx: 7,
                dy: 2
            )
        )
        XCTAssertEqual(
            recognizer.ingest(dx: 9, dy: -2),
            ContinuousGestureUpdate(
                phase: .changed,
                axis: .horizontal,
                dx: 9,
                dy: -2
            )
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
            ContinuousGestureUpdate(
                phase: .changed,
                axis: .horizontal,
                dx: 20,
                dy: 0
            )
        )
        XCTAssertEqual(
            recognizer.ingest(dx: -18, dy: 0),
            ContinuousGestureUpdate(
                phase: .changed,
                axis: .horizontal,
                dx: -18,
                dy: 0
            )
        )
        XCTAssertTrue(recognizer.end().didBeginSwipe)
    }

    func testSteepUpwardDiagonalBeginsVerticalGesture() {
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30,
            horizontalDeadZone: 12
        )

        recognizer.begin()
        let update = recognizer.ingest(dx: 12, dy: -30)

        XCTAssertEqual(update?.phase, .began)
        XCTAssertEqual(update?.axis, .vertical)
        XCTAssertEqual(update?.delta, -30)
        XCTAssertEqual(update?.direction, .up)
    }

    func testSteepDownwardDiagonalWaitsForPressureRejectionThreshold() {
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30,
            horizontalDeadZone: 12
        )

        recognizer.begin()
        XCTAssertNil(recognizer.ingest(dx: -12, dy: 30))
        let update = recognizer.ingest(dx: -2, dy: 16)

        XCTAssertEqual(update?.phase, .began)
        XCTAssertEqual(update?.axis, .vertical)
        XCTAssertEqual(update?.delta, 46)
        XCTAssertEqual(update?.direction, .down)
    }

    func testUpwardMovementEmitsBufferedVerticalMotion() {
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30,
            horizontalDeadZone: 12
        )

        recognizer.begin()
        XCTAssertNil(recognizer.ingest(dx: -10, dy: -20))
        XCTAssertEqual(
            recognizer.ingest(dx: -5, dy: -10),
            ContinuousGestureUpdate(
                phase: .began,
                axis: .vertical,
                dx: -15,
                dy: -30
            )
        )
    }

    func testVerticalUpdatesAndReversalsStayOnYAxis() {
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30
        )

        recognizer.begin()
        XCTAssertEqual(
            recognizer.ingest(dx: 5, dy: -30)?.axis,
            .vertical
        )
        XCTAssertNil(recognizer.ingest(dx: 20, dy: 0))
        XCTAssertEqual(
            recognizer.ingest(dx: 2, dy: -8),
            ContinuousGestureUpdate(
                phase: .changed,
                axis: .vertical,
                dx: 2,
                dy: -8
            )
        )
        XCTAssertEqual(
            recognizer.ingest(dx: -3, dy: 12),
            ContinuousGestureUpdate(
                phase: .changed,
                axis: .vertical,
                dx: -3,
                dy: 12
            )
        )
    }

    func testUpwardGestureFromDesktopClampsReversalAtOrigin() {
        var missionControlChecks = 0
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30,
            allowsDownwardGesture: {
                missionControlChecks += 1
                return false
            }
        )

        recognizer.begin()

        let began = recognizer.ingest(dx: 0, dy: -30)
        XCTAssertEqual(began?.phase, .began)
        XCTAssertEqual(began?.axis, .vertical)
        XCTAssertEqual(began?.dy, -30)
        XCTAssertEqual(missionControlChecks, 1)

        XCTAssertEqual(recognizer.ingest(dx: 0, dy: 20)?.dy, 20)
        XCTAssertEqual(recognizer.ingest(dx: 0, dy: 20)?.dy, 10)
        XCTAssertNil(recognizer.ingest(dx: 0, dy: 10))
        XCTAssertNil(recognizer.ingest(dx: 0, dy: -15))
        XCTAssertEqual(recognizer.ingest(dx: 0, dy: -10)?.dy, -5)
        XCTAssertEqual(missionControlChecks, 1)
    }

    func testUpwardGestureInMissionControlCanReversePastOrigin() {
        var missionControlChecks = 0
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30,
            allowsDownwardGesture: {
                missionControlChecks += 1
                return true
            }
        )

        recognizer.begin()

        let began = recognizer.ingest(dx: 0, dy: -30)
        XCTAssertEqual(began?.phase, .began)
        XCTAssertEqual(began?.axis, .vertical)
        XCTAssertEqual(missionControlChecks, 1)

        let reversal = recognizer.ingest(dx: 0, dy: 40)
        XCTAssertEqual(reversal?.phase, .changed)
        XCTAssertEqual(reversal?.axis, .vertical)
        XCTAssertEqual(reversal?.dy, 40)
        XCTAssertEqual(missionControlChecks, 1)
    }

    func testReleasedUpwardSwipeCanBeFollowedByNewDownwardSwipe() {
        var isMissionControlActive = false
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30,
            downwardActivationThreshold: 45,
            allowsDownwardGesture: { isMissionControlActive }
        )

        recognizer.begin()
        XCTAssertEqual(
            recognizer.ingest(dx: 0, dy: -30)?.direction,
            .up
        )
        XCTAssertTrue(recognizer.end().didBeginSwipe)

        isMissionControlActive = true
        recognizer.begin()
        let update = recognizer.ingest(dx: 0, dy: 45)
        XCTAssertEqual(update?.phase, .began)
        XCTAssertEqual(update?.axis, .vertical)
        XCTAssertEqual(update?.direction, .down)
        XCTAssertTrue(recognizer.end().didBeginSwipe)
    }

    func testDownwardGestureOutsideMissionControlIsNotSwipeOrTap() {
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30,
            downwardActivationThreshold: 45,
            allowsDownwardGesture: { false }
        )

        recognizer.begin()
        XCTAssertNil(recognizer.ingest(dx: 0, dy: 45))

        let end = recognizer.end()
        XCTAssertFalse(end.didBeginSwipe)
        XCTAssertFalse(end.isTap)
    }

    func testRejectedDownwardGestureChecksPermissionOncePerPress() {
        var permissionChecks = 0
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30,
            downwardActivationThreshold: 45,
            allowsDownwardGesture: {
                permissionChecks += 1
                return false
            }
        )

        recognizer.begin()
        XCTAssertNil(recognizer.ingest(dx: 0, dy: 45))
        XCTAssertNil(recognizer.ingest(dx: 0, dy: 10))
        XCTAssertNil(recognizer.ingest(dx: 0, dy: 10))
        XCTAssertEqual(permissionChecks, 1)

        // Rejecting down does not freeze the entire press. A deliberate
        // redirection can still begin on another dominant axis.
        XCTAssertEqual(
            recognizer.ingest(dx: 70, dy: 0)?.axis,
            .horizontal
        )
        XCTAssertTrue(recognizer.end().didBeginSwipe)

        recognizer.begin()
        XCTAssertNil(recognizer.ingest(dx: 0, dy: 45))
        XCTAssertEqual(permissionChecks, 2)
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
            ContinuousGestureUpdate(
                phase: .began,
                axis: .horizontal,
                dx: 30,
                dy: 0
            )
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

    func testUpwardMovementOutsideDeadZoneIsNotTap() {
        let recognizer = ContinuousGestureRecognizer(
            activationThreshold: 30,
            horizontalDeadZone: 12
        )

        recognizer.begin()
        XCTAssertNil(recognizer.ingest(dx: 0, dy: -13))

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
