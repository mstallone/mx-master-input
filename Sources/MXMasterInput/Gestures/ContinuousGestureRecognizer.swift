import Foundation

enum GestureDirection: String, CaseIterable, Equatable, Sendable {
    case left
    case right

    var controlArrowKeyCode: Int {
        switch self {
        case .left: 123
        case .right: 124
        }
    }

    var reversedSpaceDirection: GestureDirection {
        switch self {
        case .left: .right
        case .right: .left
        }
    }
}

enum ContinuousGesturePhase: Equatable, Sendable {
    case began
    case changed
}

enum PanelGestureEvent: Equatable, Sendable {
    case began(dx: Int)
    case changed(dx: Int)
    case ended
    case cancelled
}

struct ContinuousGestureUpdate: Equatable, Sendable {
    let phase: ContinuousGesturePhase
    let dx: Int
    let dy: Int

    var direction: GestureDirection {
        dx < 0 ? .left : .right
    }
}

struct GestureEnd: Equatable, Sendable {
    let didBeginSwipe: Bool
    let isTap: Bool
}

/// Converts one held-panel session into one continuous horizontal gesture.
///
/// Motion is buffered until it clears the radial activation threshold and the
/// horizontal dead zone. The first update contains the buffered displacement;
/// subsequent updates preserve every horizontal reversal until release.
final class ContinuousGestureRecognizer {
    let activationThreshold: Double
    let horizontalDeadZone: Double
    let motionActivationDelay: TimeInterval
    let maximumTapDuration: TimeInterval

    private(set) var isTracking = false
    private(set) var didBeginSwipe = false

    private let now: () -> TimeInterval
    private var accumulatedX = 0.0
    private var accumulatedY = 0.0
    private var pressDisplacementX = 0.0
    private var maximumHorizontalPressDisplacement = 0.0
    private var beganAt = 0.0
    private var acceptsMotionAt = 0.0

    init(
        activationThreshold: Double = 30,
        horizontalDeadZone: Double = 12,
        motionActivationDelay: TimeInterval = 0,
        maximumTapDuration: TimeInterval = 0.4,
        now: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        precondition(activationThreshold > 0)
        precondition(horizontalDeadZone > 0)
        precondition(horizontalDeadZone < activationThreshold)
        precondition(motionActivationDelay >= 0)
        precondition(maximumTapDuration > 0)
        self.activationThreshold = activationThreshold
        self.horizontalDeadZone = horizontalDeadZone
        self.motionActivationDelay = motionActivationDelay
        self.maximumTapDuration = maximumTapDuration
        self.now = now
    }

    func begin() {
        isTracking = true
        didBeginSwipe = false
        accumulatedX = 0
        accumulatedY = 0
        pressDisplacementX = 0
        maximumHorizontalPressDisplacement = 0
        beganAt = now()
        acceptsMotionAt = beganAt + motionActivationDelay
    }

    @discardableResult
    func ingest(dx: Int, dy: Int) -> ContinuousGestureUpdate? {
        guard isTracking else {
            return nil
        }

        // The HID++/USB queue can deliver a RawXY delta generated immediately
        // before the panel-down report just after that report. Do not let that
        // stale movement cross the new press boundary.
        guard now() >= acceptsMotionAt else {
            return nil
        }

        pressDisplacementX += Double(dx)
        maximumHorizontalPressDisplacement = max(
            maximumHorizontalPressDisplacement,
            abs(pressDisplacementX)
        )

        if didBeginSwipe {
            guard dx != 0 else {
                return nil
            }
            return ContinuousGestureUpdate(
                phase: .changed,
                dx: dx,
                dy: dy
            )
        }

        accumulatedX += Double(dx)
        accumulatedY += Double(dy)

        // Vertical drift never disqualifies a gesture, but the horizontal dead
        // zone filters the near-vertical RawXY pulse caused by clicking.
        guard hypot(accumulatedX, accumulatedY) >= activationThreshold,
              abs(accumulatedX) >= horizontalDeadZone else {
            return nil
        }

        didBeginSwipe = true
        return ContinuousGestureUpdate(
            phase: .began,
            dx: Int(accumulatedX),
            dy: Int(accumulatedY)
        )
    }

    func end() -> GestureEnd {
        let pressDuration = max(0, now() - beganAt)
        let result = GestureEnd(
            didBeginSwipe: didBeginSwipe,
            isTap: !didBeginSwipe
                && maximumHorizontalPressDisplacement < horizontalDeadZone
                && pressDuration <= maximumTapDuration
        )
        isTracking = false
        didBeginSwipe = false
        accumulatedX = 0
        accumulatedY = 0
        return result
    }

    @discardableResult
    func cancel() -> Bool {
        let cancelledActiveSwipe = didBeginSwipe
        isTracking = false
        didBeginSwipe = false
        accumulatedX = 0
        accumulatedY = 0
        return cancelledActiveSwipe
    }
}
