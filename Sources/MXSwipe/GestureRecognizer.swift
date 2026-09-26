import Foundation

/// DockSwipe motion types: Spaces, or Mission Control and App Exposé.
enum GestureAxis: Int, Sendable {
    case horizontal = 1
    case vertical = 2
}

/// What the session hands the Dock-swipe output while the panel is held.
enum PanelGestureEvent: Equatable, Sendable {
    case began(axis: GestureAxis, delta: Int)
    case changed(delta: Int)
    case ended
    case cancelled
}

struct ContinuousGestureUpdate: Equatable, Sendable {
    enum Phase: Sendable { case began, changed }

    let phase: Phase
    let axis: GestureAxis
    let dx: Int
    let dy: Int

    var delta: Int { axis == .horizontal ? dx : dy }
}

struct GestureEnd: Equatable, Sendable {
    let didBeginSwipe: Bool
    let isTap: Bool
}

/// Turns one press of the Sense Panel into at most one continuous system gesture.
///
/// Motion is buffered until it clears the radial activation threshold and the horizontal dead zone,
/// then the gesture locks to one axis. Downward activation needs a larger threshold, because pressing
/// the pressure-sensitive panel produces a downward raw-XY pulse. The first update carries the buffered
/// displacement; later updates pass every reversal on the locked axis through until release.
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
    private var verticalAllowsDownwardMotion = true
    private var verticalPhysicalDisplacement = 0
    private var verticalOutputDisplacement = 0
    private var beganAt = 0.0

    /// `allowsDownwardGesture` is asked at most once per press; a downward DockSwipe only makes sense
    /// while Mission Control is open.
    init(
        activationThreshold: Double = 30,
        downwardActivationThreshold: Double? = nil,
        horizontalDeadZone: Double = 12,
        motionActivationDelay: TimeInterval = 0,
        maximumTapDuration: TimeInterval = 0.4,
        allowsDownwardGesture: @escaping () -> Bool = { true },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        let downwardActivationThreshold = downwardActivationThreshold ?? activationThreshold * 1.5
        precondition(0 < horizontalDeadZone && horizontalDeadZone < activationThreshold)
        precondition(downwardActivationThreshold >= activationThreshold)
        precondition(motionActivationDelay >= 0 && maximumTapDuration > 0)
        self.activationThreshold = activationThreshold
        self.downwardActivationThreshold = downwardActivationThreshold
        self.horizontalDeadZone = horizontalDeadZone
        self.motionActivationDelay = motionActivationDelay
        self.maximumTapDuration = maximumTapDuration
        self.allowsDownwardGesture = allowsDownwardGesture
        self.now = now
    }

    func begin() {
        reset()
        isTracking = true
        pressDisplacementX = 0
        pressDisplacementY = 0
        maximumHorizontalPressDisplacement = 0
        maximumUpwardPressDisplacement = 0
        beganAt = now()
    }

    @discardableResult
    func ingest(dx: Int, dy: Int) -> ContinuousGestureUpdate? {
        // The HID queue can deliver motion generated just before the press after the press report.
        // Keep that stale movement from crossing the press boundary.
        guard isTracking, now() >= beganAt + motionActivationDelay else { return nil }

        pressDisplacementX += Double(dx)
        pressDisplacementY += Double(dy)
        maximumHorizontalPressDisplacement = max(maximumHorizontalPressDisplacement, abs(pressDisplacementX))
        maximumUpwardPressDisplacement = max(maximumUpwardPressDisplacement, -pressDisplacementY)

        if let activeAxis {
            switch activeAxis {
            case .horizontal:
                return dx == 0 ? nil : ContinuousGestureUpdate(phase: .changed, axis: .horizontal, dx: dx, dy: dy)
            case .vertical:
                guard dy != 0 else { return nil }
                verticalPhysicalDisplacement += dy
                let output = verticalAllowsDownwardMotion ? verticalPhysicalDisplacement : min(0, verticalPhysicalDisplacement)
                let outputDelta = output - verticalOutputDisplacement
                verticalOutputDisplacement = output
                return outputDelta == 0 ? nil : ContinuousGestureUpdate(phase: .changed, axis: .vertical, dx: dx, dy: outputDelta)
            }
        }

        accumulatedX += Double(dx)
        accumulatedY += Double(dy)
        guard hypot(accumulatedX, accumulatedY) >= activationThreshold else { return nil }

        let axis: GestureAxis
        if abs(accumulatedY) > abs(accumulatedX) {
            if accumulatedY < 0 {
                axis = .vertical
            } else if accumulatedY >= downwardActivationThreshold, !rejectedDownwardGesture {
                guard allowsDownwardGesture() else {
                    // Downward from the desktop would open App Exposé. Ignore it, and keep the release
                    // from counting as a tap.
                    rejectedDownwardGesture = true
                    return nil
                }
                axis = .vertical
            } else {
                // Still possibly the click-pressure pulse; keep buffering.
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
            verticalPhysicalDisplacement = Int(accumulatedY)
            verticalOutputDisplacement = Int(accumulatedY)
            // A gesture that starts upward on the desktop may return to where it started, but must not
            // cross into the App Exposé direction.
            verticalAllowsDownwardMotion = accumulatedY > 0 || allowsDownwardGesture()
        }
        return ContinuousGestureUpdate(phase: .began, axis: axis, dx: Int(accumulatedX), dy: Int(accumulatedY))
    }

    func end() -> GestureEnd {
        let isTap = !didBeginSwipe && !rejectedDownwardGesture
            && maximumHorizontalPressDisplacement < horizontalDeadZone
            && maximumUpwardPressDisplacement < horizontalDeadZone
            && now() - beganAt <= maximumTapDuration
        let result = GestureEnd(didBeginSwipe: didBeginSwipe, isTap: isTap)
        reset()
        return result
    }

    /// Returns whether a swipe had begun, and so needs a cancelled DockSwipe to close it.
    @discardableResult
    func cancel() -> Bool {
        let hadBegun = didBeginSwipe
        reset()
        return hadBegun
    }

    private func reset() {
        isTracking = false
        didBeginSwipe = false
        activeAxis = nil
        accumulatedX = 0
        accumulatedY = 0
        rejectedDownwardGesture = false
        verticalAllowsDownwardMotion = true
        verticalPhysicalDisplacement = 0
        verticalOutputDisplacement = 0
    }
}
