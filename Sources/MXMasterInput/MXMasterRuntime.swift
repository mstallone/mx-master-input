import Foundation

final class MXMasterRuntime: @unchecked Sendable {
    static let shared = MXMasterRuntime()

    let session = MXMasterSession(
        gestureThreshold: 30,
        horizontalDeadZone: 12,
        motionActivationDelay: 0.06,
        maximumTapDuration: 0.4
    )
    let actions = SystemActionController()

    private init() {}
}
