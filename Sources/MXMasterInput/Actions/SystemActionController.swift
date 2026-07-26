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
    private struct PendingSpaceAction: Sendable {
        let action: PanelAction
        let keyCode: Int
        let completion: @Sendable (ActionResult) -> Void
    }

    private static let missionControlKeyCode = 126
    private let outputQueue = DispatchQueue(
        label: "com.mattstallone.mxmasterinput.actions",
        qos: .userInteractive
    )
    let minimumSpaceActionInterval: TimeInterval
    private let postControlArrow: @Sendable (Int) -> Bool
    private var pendingSpaceActions: [PendingSpaceAction] = []
    private var lastSpacePostTime = 0.0
    private var isSpaceDrainScheduled = false

    init(
        minimumSpaceActionInterval: TimeInterval = 1.2,
        postControlArrow: @escaping @Sendable (Int) -> Bool = {
            MXPostControlArrow($0)
        }
    ) {
        precondition(minimumSpaceActionInterval >= 0)
        self.minimumSpaceActionInterval = minimumSpaceActionInterval
        self.postControlArrow = postControlArrow
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

    func perform(
        _ direction: GestureDirection,
        completion: @escaping @Sendable (ActionResult) -> Void
    ) {
        let mapping: (PanelAction, Int) = switch direction {
        case .left:
            (
                .nextSpace,
                direction.reversedSpaceDirection.controlArrowKeyCode
            )
        case .right:
            (
                .previousSpace,
                direction.reversedSpaceDirection.controlArrowKeyCode
            )
        }

        enqueueSpaceAction(
            action: mapping.0,
            keyCode: mapping.1,
            completion: completion
        )
    }

    func performTap(
        completion: @escaping @Sendable (ActionResult) -> Void
    ) {
        outputQueue.async { [self] in
            let secureInputWasEnabled = secureInputEnabled
            completion(
                ActionResult(
                    action: .missionControl,
                    succeeded: postControlArrow(
                        Self.missionControlKeyCode
                    ),
                    secureInputWasEnabled: secureInputWasEnabled
                )
            )
        }
    }

    private func enqueueSpaceAction(
        action: PanelAction,
        keyCode: Int,
        completion: @escaping @Sendable (ActionResult) -> Void
    ) {
        outputQueue.async { [self] in
            pendingSpaceActions.append(
                PendingSpaceAction(
                    action: action,
                    keyCode: keyCode,
                    completion: completion
                )
            )
            drainSpaceActionsWhenReady()
        }
    }

    private func drainSpaceActionsWhenReady() {
        guard !pendingSpaceActions.isEmpty,
              !isSpaceDrainScheduled else {
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let remainingDelay = max(
            0,
            minimumSpaceActionInterval - (now - lastSpacePostTime)
        )
        guard remainingDelay == 0 else {
            isSpaceDrainScheduled = true
            outputQueue.asyncAfter(
                deadline: .now() + remainingDelay
            ) { [self] in
                isSpaceDrainScheduled = false
                // Dispatch timers may wake slightly early. Recalculate from
                // the actual last post instead of submitting prematurely.
                drainSpaceActionsWhenReady()
            }
            return
        }

        let pending = pendingSpaceActions.removeFirst()
        let secureInputWasEnabled = secureInputEnabled
        let succeeded = postControlArrow(pending.keyCode)
        lastSpacePostTime = ProcessInfo.processInfo.systemUptime
        pending.completion(
            ActionResult(
                action: pending.action,
                succeeded: succeeded,
                secureInputWasEnabled: secureInputWasEnabled
            )
        )
        drainSpaceActionsWhenReady()
    }
}
