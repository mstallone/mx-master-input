import Foundation

enum GestureDirection: String, CaseIterable, Equatable, Sendable {
    case left
    case right
    case up
    case down

    var controlArrowKeyCode: Int {
        switch self {
        case .left: 123
        case .right: 124
        case .up: 126
        case .down: 125
        }
    }

    var reversed: GestureDirection {
        switch self {
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        }
    }
}

enum GestureAxis: Int, Equatable, Sendable {
    case horizontal = 1
    case vertical = 2
}

enum ContinuousGesturePhase: Equatable, Sendable {
    case began
    case changed
}

enum PanelGestureEvent: Equatable, Sendable {
    case began(axis: GestureAxis, delta: Int)
    case changed(delta: Int)
    case ended
    case cancelled
}

struct ContinuousGestureUpdate: Equatable, Sendable {
    let phase: ContinuousGesturePhase
    let axis: GestureAxis
    let dx: Int
    let dy: Int

    var delta: Int {
        switch axis {
        case .horizontal: dx
        case .vertical: dy
        }
    }

    var direction: GestureDirection {
        switch axis {
        case .horizontal:
            dx < 0 ? .left : .right
        case .vertical:
            dy < 0 ? .up : .down
        }
    }
}

struct GestureEnd: Equatable, Sendable {
    let didBeginSwipe: Bool
    let isTap: Bool
}

/// Converts one held-panel session into one continuous system gesture.
///
/// Motion is buffered until it clears the radial activation threshold and the
/// directional dead zone. The recognizer then locks to either horizontal
/// or vertical motion. Downward activation uses a slightly larger threshold to
/// reject the RawXY pulse produced by pressing the pressure-sensitive panel.
/// The first update contains the buffered displacement; subsequent updates
/// preserve every reversal on the locked axis until release.
final class ContinuousGestureRecognizer {
    let activationThreshold: Double
    let downwardActivationThreshold: Double
    let horizontalDeadZone: Double
    let motionActivationDelay: TimeInterval
    let maximumTapDuration: TimeInterval

    private(set) var isTracking = false
    private(set) var didBeginSwipe = false

    private let now: () -> TimeInterval
    private let allowsDownwardGesture: () -> Bool
    private var activeAxis: GestureAxis?
    private var accumulatedX = 0.0
    private var accumulatedY = 0.0
    private var pressDisplacementX = 0.0
    private var pressDisplacementY = 0.0
    private var maximumHorizontalPressDisplacement = 0.0
    private var maximumUpwardPressDisplacement = 0.0
    private var rejectedDownwardGesture = false
    private var activeVerticalAllowsPositiveMotion = true
    private var activeVerticalPhysicalDisplacement = 0
    private var activeVerticalOutputDisplacement = 0
    private var beganAt = 0.0
    private var acceptsMotionAt = 0.0

    init(
        activationThreshold: Double = 30,
        downwardActivationThreshold: Double? = nil,
        horizontalDeadZone: Double = 12,
        motionActivationDelay: TimeInterval = 0,
        maximumTapDuration: TimeInterval = 0.4,
        allowsDownwardGesture: @escaping () -> Bool = { true },
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
        self.downwardActivationThreshold =
            downwardActivationThreshold ?? activationThreshold * 1.5
        precondition(self.downwardActivationThreshold >= activationThreshold)
        self.horizontalDeadZone = horizontalDeadZone
        self.motionActivationDelay = motionActivationDelay
        self.maximumTapDuration = maximumTapDuration
        self.allowsDownwardGesture = allowsDownwardGesture
        self.now = now
    }

    func begin() {
        isTracking = true
        didBeginSwipe = false
        activeAxis = nil
        accumulatedX = 0
        accumulatedY = 0
        pressDisplacementX = 0
        pressDisplacementY = 0
        maximumHorizontalPressDisplacement = 0
        maximumUpwardPressDisplacement = 0
        rejectedDownwardGesture = false
        activeVerticalAllowsPositiveMotion = true
        activeVerticalPhysicalDisplacement = 0
        activeVerticalOutputDisplacement = 0
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
        pressDisplacementY += Double(dy)
        maximumHorizontalPressDisplacement = max(
            maximumHorizontalPressDisplacement,
            abs(pressDisplacementX)
        )
        maximumUpwardPressDisplacement = max(
            maximumUpwardPressDisplacement,
            max(0, -pressDisplacementY)
        )

        if didBeginSwipe {
            guard let activeAxis else {
                return nil
            }

            switch activeAxis {
            case .horizontal:
                guard dx != 0 else {
                    return nil
                }
                return ContinuousGestureUpdate(
                    phase: .changed,
                    axis: activeAxis,
                    dx: dx,
                    dy: dy
                )
            case .vertical:
                guard dy != 0 else {
                    return nil
                }

                activeVerticalPhysicalDisplacement += dy
                let nextOutputDisplacement = activeVerticalAllowsPositiveMotion
                    ? activeVerticalPhysicalDisplacement
                    : min(0, activeVerticalPhysicalDisplacement)
                let outputDelta =
                    nextOutputDisplacement - activeVerticalOutputDisplacement
                activeVerticalOutputDisplacement = nextOutputDisplacement

                guard outputDelta != 0 else {
                    return nil
                }
                return ContinuousGestureUpdate(
                    phase: .changed,
                    axis: activeAxis,
                    dx: dx,
                    dy: outputDelta
                )
            }
        }

        accumulatedX += Double(dx)
        accumulatedY += Double(dy)

        guard hypot(accumulatedX, accumulatedY) >= activationThreshold else {
            return nil
        }

        let axis: GestureAxis
        if abs(accumulatedY) > abs(accumulatedX) {
            if accumulatedY < 0 {
                axis = .vertical
            } else if accumulatedY >= downwardActivationThreshold {
                guard !rejectedDownwardGesture else {
                    return nil
                }
                guard allowsDownwardGesture() else {
                    // A vertical DockSwipe down opens App Exposé from the
                    // desktop. Suppress it unless Mission Control is visible,
                    // and prevent release from being reinterpreted as a tap.
                    rejectedDownwardGesture = true
                    return nil
                }
                axis = .vertical
            } else {
                // Keep buffering dominant downward motion until it is large
                // enough to distinguish an intentional drag from the panel's
                // click-pressure pulse.
                return nil
            }
        } else if abs(accumulatedX) >= horizontalDeadZone {
            axis = .horizontal
        } else {
            return nil
        }

        didBeginSwipe = true
        activeAxis = axis
        if axis == .vertical {
            activeVerticalPhysicalDisplacement = Int(accumulatedY)
            activeVerticalOutputDisplacement = Int(accumulatedY)
            // A gesture that starts on the desktop may reverse to its origin,
            // but must not cross into the App Exposé direction.
            activeVerticalAllowsPositiveMotion =
                accumulatedY > 0 || allowsDownwardGesture()
        }
        return ContinuousGestureUpdate(
            phase: .began,
            axis: axis,
            dx: Int(accumulatedX),
            dy: Int(accumulatedY)
        )
    }

    func end() -> GestureEnd {
        let pressDuration = max(0, now() - beganAt)
        let result = GestureEnd(
            didBeginSwipe: didBeginSwipe,
            isTap: !didBeginSwipe
                && !rejectedDownwardGesture
                && maximumHorizontalPressDisplacement < horizontalDeadZone
                && maximumUpwardPressDisplacement < horizontalDeadZone
                && pressDuration <= maximumTapDuration
        )
        isTracking = false
        didBeginSwipe = false
        activeAxis = nil
        rejectedDownwardGesture = false
        activeVerticalAllowsPositiveMotion = true
        activeVerticalPhysicalDisplacement = 0
        activeVerticalOutputDisplacement = 0
        accumulatedX = 0
        accumulatedY = 0
        return result
    }

    @discardableResult
    func cancel() -> Bool {
        let cancelledActiveSwipe = didBeginSwipe
        isTracking = false
        didBeginSwipe = false
        activeAxis = nil
        rejectedDownwardGesture = false
        activeVerticalAllowsPositiveMotion = true
        activeVerticalPhysicalDisplacement = 0
        activeVerticalOutputDisplacement = 0
        accumulatedX = 0
        accumulatedY = 0
        return cancelledActiveSwipe
    }
}
