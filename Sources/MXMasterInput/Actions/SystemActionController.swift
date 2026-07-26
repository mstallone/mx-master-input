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
    private let postControlArrow: @Sendable (Int) -> Bool
    private let postDockSwipe:
        @Sendable (_ progress: Double, _ phase: Int) -> Bool

    private var swipeActive = false
    private var usesKeyboardFallback = false
    private var swipeProgress = 0.0
    private var swipePostsSucceeded = true
    private var swipeBeganWithSecureInput = false
    private var lastPhysicalDirection = GestureDirection.right

    init(
        rawMotionUnitsPerSpace: Double = 500,
        postControlArrow: @escaping @Sendable (Int) -> Bool = {
            MXPostControlArrow($0)
        },
        postDockSwipe: @escaping @Sendable (Double, Int) -> Bool = {
            MXPostHorizontalDockSwipe($0, $1)
        }
    ) {
        precondition(rawMotionUnitsPerSpace > 0)
        self.rawMotionUnitsPerSpace = rawMotionUnitsPerSpace
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
        case let .began(dx):
            cancelActiveGesture()
            swipeActive = true
            swipeProgress = progressDelta(for: dx)
            lastPhysicalDirection = dx < 0 ? .left : .right
            swipeBeganWithSecureInput = secureInputEnabled
            swipePostsSucceeded = postDockSwipe(
                swipeProgress,
                DockSwipePhase.began.rawValue
            )
            usesKeyboardFallback = !swipePostsSucceeded

        case let .changed(dx):
            guard swipeActive, dx != 0 else {
                return
            }
            swipeProgress += progressDelta(for: dx)
            lastPhysicalDirection = dx < 0 ? .left : .right
            if !usesKeyboardFallback {
                swipePostsSucceeded = postDockSwipe(
                    swipeProgress,
                    DockSwipePhase.changed.rawValue
                ) && swipePostsSucceeded
            }

        case .ended:
            guard swipeActive else {
                return
            }
            let action = panelAction(for: swipeProgress)
            let succeeded: Bool
            if usesKeyboardFallback {
                succeeded = postControlArrow(
                    fallbackPhysicalDirection()
                        .reversedSpaceDirection
                        .controlArrowKeyCode
                )
            } else {
                let phase: DockSwipePhase = swipeProgress == 0
                    ? .cancelled
                    : .ended
                succeeded = postDockSwipe(
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

    private func fallbackPhysicalDirection() -> GestureDirection {
        if swipeProgress > 0 {
            return .left
        }
        if swipeProgress < 0 {
            return .right
        }
        return lastPhysicalDirection
    }

    private func progressDelta(for rawDeltaX: Int) -> Double {
        // Reverse physical motion to preserve the established panel mapping:
        // left reveals the next/right Space and right reveals the previous.
        -Double(rawDeltaX) * (1.2 / rawMotionUnitsPerSpace)
    }

    private func panelAction(for progress: Double) -> PanelAction {
        if progress > 0 {
            return .nextSpace
        }
        if progress < 0 {
            return .previousSpace
        }
        return switch lastPhysicalDirection {
        case .left: .nextSpace
        case .right: .previousSpace
        }
    }

    private func cancelActiveGesture() {
        guard swipeActive else {
            return
        }
        if !usesKeyboardFallback {
            _ = postDockSwipe(
                swipeProgress,
                DockSwipePhase.cancelled.rawValue
            )
        }
        resetGestureState()
    }

    private func resetGestureState() {
        swipeActive = false
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
