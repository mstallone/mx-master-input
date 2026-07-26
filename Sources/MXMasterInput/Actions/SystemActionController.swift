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
    private static let missionControlKeyCode = 126
    private let outputQueue = DispatchQueue(
        label: "com.mattstallone.mxmasterinput.actions",
        qos: .userInteractive
    )
    private let postControlArrow: @Sendable (Int) -> Bool

    init(
        postControlArrow: @escaping @Sendable (Int) -> Bool = {
            MXPostControlArrow($0)
        }
    ) {
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

        submit(
            action: mapping.0,
            keyCode: mapping.1,
            completion: completion
        )
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
