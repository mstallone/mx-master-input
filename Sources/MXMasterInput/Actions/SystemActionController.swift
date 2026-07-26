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
    private struct PendingAction: Sendable {
        let action: PanelAction
        let keyCode: Int
        let completion: @Sendable (ActionResult) -> Void
    }

    private static let missionControlKeyCode = 126
    private let outputQueue = DispatchQueue(
        label: "com.mattstallone.mxmasterinput.actions",
        qos: .userInteractive
    )
    let minimumActionInterval: TimeInterval
    private let postControlArrow: @Sendable (Int) -> Bool
    private var pendingActions: [PendingAction] = []
    private var lastPostTime = 0.0
    private var isDrainScheduled = false

    init(
        minimumActionInterval: TimeInterval = 1.2,
        postControlArrow: @escaping @Sendable (Int) -> Bool = {
            MXPostControlArrow($0)
        }
    ) {
        precondition(minimumActionInterval >= 0)
        self.minimumActionInterval = minimumActionInterval
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

        enqueue(
            action: mapping.0,
            keyCode: mapping.1,
            completion: completion
        )
    }

    func performTap(
        completion: @escaping @Sendable (ActionResult) -> Void
    ) {
        enqueue(
            action: .missionControl,
            keyCode: Self.missionControlKeyCode,
            completion: completion
        )
    }

    private func enqueue(
        action: PanelAction,
        keyCode: Int,
        completion: @escaping @Sendable (ActionResult) -> Void
    ) {
        outputQueue.async { [self] in
            pendingActions.append(
                PendingAction(
                    action: action,
                    keyCode: keyCode,
                    completion: completion
                )
            )
            drainWhenReady()
        }
    }

    private func drainWhenReady() {
        guard !pendingActions.isEmpty, !isDrainScheduled else {
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let remainingDelay = max(
            0,
            minimumActionInterval - (now - lastPostTime)
        )
        guard remainingDelay == 0 else {
            isDrainScheduled = true
            outputQueue.asyncAfter(
                deadline: .now() + remainingDelay
            ) { [self] in
                isDrainScheduled = false
                // Dispatch timers may wake slightly early. Recalculate from
                // the actual last post instead of submitting prematurely.
                drainWhenReady()
            }
            return
        }

        let pending = pendingActions.removeFirst()
        let secureInputWasEnabled = secureInputEnabled
        let succeeded = postControlArrow(pending.keyCode)
        lastPostTime = ProcessInfo.processInfo.systemUptime
        pending.completion(
            ActionResult(
                action: pending.action,
                succeeded: succeeded,
                secureInputWasEnabled: secureInputWasEnabled
            )
        )
        drainWhenReady()
    }
}
