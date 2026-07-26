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

struct GestureEnd: Equatable, Sendable {
    let committedDirections: [GestureDirection]
    let isTap: Bool
}

/// Recognizes multiple ordered gestures during one held-panel session.
///
/// A commit resets the displacement origin. That is the important difference
/// from a one-shot recognizer: left followed by right emits `[.left, .right]`
/// before the panel is released.
final class AdditiveGestureRecognizer {
    let threshold: Double
    let horizontalDeadZone: Double
    let motionActivationDelay: TimeInterval
    let maximumTapDuration: TimeInterval

    private(set) var isTracking = false
    private(set) var committedDirections: [GestureDirection] = []

    private let now: () -> TimeInterval
    private var accumulatedX = 0.0
    private var accumulatedY = 0.0
    private var pressDisplacementX = 0.0
    private var maximumHorizontalPressDisplacement = 0.0
    private var beganAt = 0.0
    private var acceptsMotionAt = 0.0
    private var isAwaitingReversal = false

    init(
        threshold: Double = 30,
        horizontalDeadZone: Double = 12,
        motionActivationDelay: TimeInterval = 0,
        maximumTapDuration: TimeInterval = 0.4,
        now: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        precondition(threshold > 0)
        precondition(horizontalDeadZone > 0)
        precondition(horizontalDeadZone < threshold)
        precondition(motionActivationDelay >= 0)
        precondition(maximumTapDuration > 0)
        self.threshold = threshold
        self.horizontalDeadZone = horizontalDeadZone
        self.motionActivationDelay = motionActivationDelay
        self.maximumTapDuration = maximumTapDuration
        self.now = now
    }

    func begin() {
        isTracking = true
        committedDirections.removeAll(keepingCapacity: true)
        resetDisplacement()
        pressDisplacementX = 0
        maximumHorizontalPressDisplacement = 0
        beganAt = now()
        acceptsMotionAt = beganAt + motionActivationDelay
        isAwaitingReversal = false
    }

    @discardableResult
    func ingest(dx: Int, dy: Int) -> GestureDirection? {
        guard isTracking else {
            return nil
        }

        // The HID++/USB queue can deliver a RawXY delta generated immediately
        // before the panel-down report just after that report. Do not let that
        // stale movement cross the new press boundary.
        guard now() >= acceptsMotionAt else {
            return nil
        }

        if isAwaitingReversal, let previousDirection = committedDirections.last {
            let isReversing = switch previousDirection {
            case .left: dx > 0
            case .right: dx < 0
            }
            guard isReversing else {
                return nil
            }
            isAwaitingReversal = false
        }

        accumulatedX += Double(dx)
        accumulatedY += Double(dy)
        pressDisplacementX += Double(dx)
        maximumHorizontalPressDisplacement = max(
            maximumHorizontalPressDisplacement,
            abs(pressDisplacementX)
        )

        // Once the stroke crosses the radial threshold, its horizontal sign
        // selects the Space. Vertical drift never disqualifies a gesture:
        // every direction in the right hemisphere is right, and every
        // direction in the left hemisphere is left. The central horizontal
        // dead zone filters the near-vertical RawXY pulse produced by clicking
        // the panel itself.
        guard hypot(accumulatedX, accumulatedY) >= threshold,
              abs(accumulatedX) >= horizontalDeadZone else {
            return nil
        }
        let direction: GestureDirection = accumulatedX < 0 ? .left : .right

        // Every threshold crossing establishes a fresh origin. Ignore
        // continued travel in that direction until the first opposite delta,
        // so leftover motion cannot make the next reversal cross extra
        // distance before it commits.
        resetDisplacement()
        isAwaitingReversal = true

        guard committedDirections.last != direction else {
            return nil
        }

        committedDirections.append(direction)
        return direction
    }

    func end() -> GestureEnd {
        let pressDuration = max(0, now() - beganAt)
        let result = GestureEnd(
            committedDirections: committedDirections,
            isTap: committedDirections.isEmpty
                && maximumHorizontalPressDisplacement < horizontalDeadZone
                && pressDuration <= maximumTapDuration
        )
        isTracking = false
        resetDisplacement()
        return result
    }

    func cancel() {
        isTracking = false
        committedDirections.removeAll(keepingCapacity: true)
        isAwaitingReversal = false
        resetDisplacement()
    }

    private func resetDisplacement() {
        accumulatedX = 0
        accumulatedY = 0
    }
}
