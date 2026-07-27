import Foundation

enum PanelAction: String, Equatable, Sendable {
    case previousSpace
    case nextSpace
    case missionControl
}

struct ActionResult: Equatable, Sendable {
    let action: PanelAction
    let succeeded: Bool
    let secureInputWasEnabled: Bool
}

final class SystemActionController: @unchecked Sendable {
    private enum DockSwipePhase: Int {
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8
    }

    private static let missionControlKeyCode = 126
    private let outputQueue = DispatchQueue(
        label: "com.mattstallone.mxmasterinput.actions",
        qos: .userInteractive
    )
    let rawMotionUnitsPerSpace: Double
    let rawMotionUnitsPerMissionControl: Double
    private let postControlArrow: @Sendable (Int) -> Bool
    private let postDockSwipe:
        @Sendable (_ axis: GestureAxis, _ progress: Double, _ phase: Int) -> Bool

    private var swipeActive = false
    private var swipeAxis: GestureAxis?
    private var usesKeyboardFallback = false
    private var swipeProgress = 0.0
    private var swipePostsSucceeded = true
    private var swipeBeganWithSecureInput = false
    private var lastPhysicalDirection = GestureDirection.right

    init(
        rawMotionUnitsPerSpace: Double = 500,
        rawMotionUnitsPerMissionControl: Double = 500,
        postControlArrow: @escaping @Sendable (Int) -> Bool = {
            MXPostControlArrow($0)
        },
        postDockSwipe:
            @escaping @Sendable (GestureAxis, Double, Int) -> Bool = {
                MXPostDockSwipe($1, $0.rawValue, $2)
        }
    ) {
        precondition(rawMotionUnitsPerSpace > 0)
        precondition(rawMotionUnitsPerMissionControl > 0)
        self.rawMotionUnitsPerSpace = rawMotionUnitsPerSpace
        self.rawMotionUnitsPerMissionControl = rawMotionUnitsPerMissionControl
        self.postControlArrow = postControlArrow
        self.postDockSwipe = postDockSwipe
    }

    var hasPostEventAccess: Bool {
        MXHasPostEventAccess()
    }

    var secureInputEnabled: Bool {
        MXIsSecureInputEnabled()
    }

    @discardableResult
    func requestPostEventAccess() -> Bool {
        MXRequestPostEventAccess()
    }

    func performGesture(
        _ event: PanelGestureEvent,
        completion: @escaping @Sendable (ActionResult) -> Void
    ) {
        outputQueue.async { [self] in
            handleGesture(event, completion: completion)
        }
    }

    func performTap(
        completion: @escaping @Sendable (ActionResult) -> Void
    ) {
        submit(
            action: .missionControl,
            keyCode: Self.missionControlKeyCode,
            completion: completion
        )
    }

    func cancelGestureSynchronously() {
        outputQueue.sync { [self] in
            cancelActiveGesture()
        }
    }

    private func handleGesture(
        _ event: PanelGestureEvent,
        completion: @escaping @Sendable (ActionResult) -> Void
    ) {
        switch event {
        case let .began(axis, delta):
            cancelActiveGesture()
            swipeActive = true
            swipeAxis = axis
            swipeProgress = progressDelta(for: delta, axis: axis)
            lastPhysicalDirection = direction(for: delta, axis: axis)
            swipeBeganWithSecureInput = secureInputEnabled
            swipePostsSucceeded = postDockSwipe(
                axis,
                swipeProgress,
                DockSwipePhase.began.rawValue
            )
            usesKeyboardFallback = !swipePostsSucceeded

        case let .changed(delta):
            guard swipeActive, let swipeAxis, delta != 0 else {
                return
            }
            swipeProgress += progressDelta(for: delta, axis: swipeAxis)
            lastPhysicalDirection = direction(for: delta, axis: swipeAxis)
            if !usesKeyboardFallback {
                swipePostsSucceeded = postDockSwipe(
                    swipeAxis,
                    swipeProgress,
                    DockSwipePhase.changed.rawValue
                ) && swipePostsSucceeded
            }

        case .ended:
            guard swipeActive, let swipeAxis else {
                return
            }
            let action = panelAction(for: swipeProgress, axis: swipeAxis)
            let succeeded: Bool
            if usesKeyboardFallback {
                succeeded = postControlArrow(fallbackKeyCode(for: swipeAxis))
            } else {
                let phase: DockSwipePhase = swipeProgress == 0
                    ? .cancelled
                    : .ended
                succeeded = postDockSwipe(
                    swipeAxis,
                    swipeProgress,
                    phase.rawValue
                ) && swipePostsSucceeded
            }
            let secureInputWasEnabled = swipeBeganWithSecureInput
            resetGestureState()
            completion(
                ActionResult(
                    action: action,
                    succeeded: succeeded,
                    secureInputWasEnabled: secureInputWasEnabled
                )
            )

        case .cancelled:
            cancelActiveGesture()
        }
    }

    private func fallbackKeyCode(for axis: GestureAxis) -> Int {
        guard axis == .horizontal else {
            return Self.missionControlKeyCode
        }

        let physicalDirection: GestureDirection
        if swipeProgress > 0 {
            physicalDirection = .left
        } else if swipeProgress < 0 {
            physicalDirection = .right
        } else {
            physicalDirection = lastPhysicalDirection
        }
        return physicalDirection.reversed.controlArrowKeyCode
    }

    private func progressDelta(
        for rawDelta: Int,
        axis: GestureAxis
    ) -> Double {
        switch axis {
        case .horizontal:
            // Reverse physical motion to preserve the established panel
            // mapping: left reveals the next/right Space and right reveals the
            // previous.
            -Double(rawDelta) * (1.2 / rawMotionUnitsPerSpace)
        case .vertical:
            // HID RawXY uses negative Y for upward motion, matching the
            // vertical DockSwipe direction that reveals Mission Control.
            Double(rawDelta) * (1.2 / rawMotionUnitsPerMissionControl)
        }
    }

    private func direction(
        for rawDelta: Int,
        axis: GestureAxis
    ) -> GestureDirection {
        switch axis {
        case .horizontal:
            rawDelta < 0 ? .left : .right
        case .vertical:
            rawDelta < 0 ? .up : .down
        }
    }

    private func panelAction(
        for progress: Double,
        axis: GestureAxis
    ) -> PanelAction {
        if axis == .vertical {
            return .missionControl
        }
        if progress > 0 {
            return .nextSpace
        }
        if progress < 0 {
            return .previousSpace
        }
        return switch lastPhysicalDirection {
        case .left: .nextSpace
        case .right: .previousSpace
        case .up, .down: .missionControl
        }
    }

    private func cancelActiveGesture() {
        guard swipeActive else {
            return
        }
        guard let swipeAxis else {
            resetGestureState()
            return
        }
        if !usesKeyboardFallback {
            _ = postDockSwipe(
                swipeAxis,
                swipeProgress,
                DockSwipePhase.cancelled.rawValue
            )
        }
        resetGestureState()
    }

    private func resetGestureState() {
        swipeActive = false
        swipeAxis = nil
        usesKeyboardFallback = false
        swipeProgress = 0
        swipePostsSucceeded = true
        swipeBeganWithSecureInput = false
    }

    private func submit(
        action: PanelAction,
        keyCode: Int,
        completion: @escaping @Sendable (ActionResult) -> Void
    ) {
        outputQueue.async { [self] in
            let secureInputWasEnabled = secureInputEnabled
            completion(
                ActionResult(
                    action: action,
                    succeeded: postControlArrow(keyCode),
                    secureInputWasEnabled: secureInputWasEnabled
                )
            )
        }
    }
}
