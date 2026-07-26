import XCTest

final class AdditiveGestureRecognizerTests: XCTestCase {
    func testDirectionsMapToStandardMacOSArrowKeyCodes() {
        XCTAssertEqual(GestureDirection.left.controlArrowKeyCode, 123)
        XCTAssertEqual(GestureDirection.right.controlArrowKeyCode, 124)
    }

    func testSpaceDirectionsAreReversed() {
        XCTAssertEqual(GestureDirection.left.reversedSpaceDirection, .right)
        XCTAssertEqual(GestureDirection.right.reversedSpaceDirection, .left)
    }

    func testLeftThenRightCommitsBothActionsDuringOneHold() {
        let recognizer = AdditiveGestureRecognizer(threshold: 30)

        recognizer.begin()

        XCTAssertNil(recognizer.ingest(dx: -10, dy: 20))
        XCTAssertEqual(recognizer.ingest(dx: -5, dy: 10), .left)
        XCTAssertNil(recognizer.ingest(dx: 10, dy: -20))
        XCTAssertEqual(recognizer.ingest(dx: 5, dy: -10), .right)

        let end = recognizer.end()
        XCTAssertEqual(end.committedDirections, [.left, .right])
        XCTAssertFalse(end.isTap)
    }

    func testCommitCreatesFreshOriginForImmediateReversal() {
        let recognizer = AdditiveGestureRecognizer(threshold: 30)

        recognizer.begin()
        XCTAssertEqual(recognizer.ingest(dx: -35, dy: 0), .left)
        XCTAssertEqual(recognizer.ingest(dx: 31, dy: 0), .right)
    }

    func testSteepDiagonalTowardRightCommitsRight() {
        let recognizer = AdditiveGestureRecognizer(
            threshold: 30,
            horizontalDeadZone: 12
        )

        recognizer.begin()
        XCTAssertEqual(recognizer.ingest(dx: 12, dy: -30), .right)
    }

    func testSteepDiagonalTowardLeftCommitsLeft() {
        let recognizer = AdditiveGestureRecognizer(
            threshold: 30,
            horizontalDeadZone: 12
        )

        recognizer.begin()
        XCTAssertEqual(recognizer.ingest(dx: -12, dy: 30), .left)
    }

    func testSustainedRightGestureEmitsOnlyOnce() {
        let recognizer = AdditiveGestureRecognizer(threshold: 30)

        recognizer.begin()
        XCTAssertEqual(recognizer.ingest(dx: 30, dy: 0), .right)
        XCTAssertNil(recognizer.ingest(dx: 30, dy: 0))
        XCTAssertNil(recognizer.ingest(dx: 30, dy: 0))

        let end = recognizer.end()
        XCTAssertEqual(end.committedDirections, [.right])
        XCTAssertFalse(end.isTap)
    }

    func testSuppressedDuplicateStillCreatesFreshOriginForReversal() {
        let recognizer = AdditiveGestureRecognizer(threshold: 30)

        recognizer.begin()
        XCTAssertEqual(recognizer.ingest(dx: -30, dy: 0), .left)
        XCTAssertNil(recognizer.ingest(dx: -30, dy: 0))
        XCTAssertEqual(recognizer.ingest(dx: 30, dy: 0), .right)

        let end = recognizer.end()
        XCTAssertEqual(end.committedDirections, [.left, .right])
        XCTAssertFalse(end.isTap)
    }

    func testContinuedTravelDoesNotOffsetNextReversal() {
        let recognizer = AdditiveGestureRecognizer(threshold: 30)

        recognizer.begin()
        XCTAssertEqual(recognizer.ingest(dx: -30, dy: 0), .left)
        XCTAssertNil(recognizer.ingest(dx: -25, dy: 0))
        XCTAssertEqual(recognizer.ingest(dx: 30, dy: 0), .right)
    }

    func testSixRapidAlternatingGesturesCommitInOrder() {
        let recognizer = AdditiveGestureRecognizer(threshold: 30)
        let deltas = [-30, 30, -30, 30, -30, 30]

        recognizer.begin()
        let directions = deltas.compactMap {
            recognizer.ingest(dx: $0, dy: 0)
        }

        XCTAssertEqual(
            directions,
            [.left, .right, .left, .right, .left, .right]
        )
        XCTAssertEqual(recognizer.end().committedDirections, directions)
    }

    func testClickPressureMotionInsideDeadZoneDoesNotChooseSpace() {
        var currentTime = 10.0
        let recognizer = AdditiveGestureRecognizer(
            threshold: 30,
            horizontalDeadZone: 12,
            maximumTapDuration: 0.4,
            now: { currentTime }
        )

        recognizer.begin()
        XCTAssertNil(recognizer.ingest(dx: 5, dy: 40))
        currentTime += 0.2

        XCTAssertTrue(recognizer.end().isTap)
    }

    func testMotionBeforePostPressArmingWindowIsDiscarded() {
        var currentTime = 10.0
        let recognizer = AdditiveGestureRecognizer(
            threshold: 30,
            horizontalDeadZone: 12,
            motionActivationDelay: 0.06,
            now: { currentTime }
        )

        recognizer.begin()
        XCTAssertNil(recognizer.ingest(dx: 40, dy: 0))

        currentTime += 0.061
        XCTAssertEqual(recognizer.ingest(dx: 30, dy: 0), .right)
        XCTAssertEqual(
            recognizer.end().committedDirections,
            [.right]
        )
    }

    func testQueuedPrePressMotionDoesNotDisqualifyClick() {
        var currentTime = 10.0
        let recognizer = AdditiveGestureRecognizer(
            threshold: 30,
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
        let recognizer = AdditiveGestureRecognizer(
            threshold: 30,
            horizontalDeadZone: 12,
            maximumTapDuration: 0.4,
            now: { currentTime }
        )

        recognizer.begin()
        _ = recognizer.ingest(dx: 3, dy: 2)
        currentTime += 0.2

        XCTAssertTrue(recognizer.end().isTap)
    }

    func testLongHoldWithoutMovementIsNotTap() {
        var currentTime = 10.0
        let recognizer = AdditiveGestureRecognizer(
            threshold: 30,
            maximumTapDuration: 0.4,
            now: { currentTime }
        )

        recognizer.begin()
        currentTime += 0.5

        XCTAssertFalse(recognizer.end().isTap)
    }

    func testHorizontalMovementOutsideDeadZoneIsNotTap() {
        let recognizer = AdditiveGestureRecognizer(
            threshold: 30,
            horizontalDeadZone: 12
        )

        recognizer.begin()
        XCTAssertNil(recognizer.ingest(dx: 13, dy: 0))

        XCTAssertFalse(recognizer.end().isTap)
    }
}
