import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Disabled"
    @Published private(set) var deviceName = "No device connected"
    @Published private(set) var lastInput = "None"
    @Published private(set) var lastAction = "None"
    @Published private(set) var hapticStatus = "Unknown"
    @Published private(set) var secureInputEnabled = false
    @Published private(set) var secureInputVerification = "Not tested this run"
    @Published private(set) var hasPostEventAccess = false
    @Published var launchAtLogin = false

    private let runtime = MXMasterRuntime.shared
    private var secureInputTimer: Timer?

    init() {
        refreshPermissionState()
        refreshLaunchAtLogin()

        secureInputTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionState()
            }
        }

        if UserDefaults.standard.bool(forKey: "autoEnable"),
           hasPostEventAccess {
            enable()
        }
    }

    func enable() {
        guard !isBusy, !isEnabled else {
            return
        }

        refreshPermissionState()
        guard hasPostEventAccess else {
            status = "Accessibility/Post Event permission is required before enabling."
            return
        }

        isBusy = true
        status = "Connecting…"

        Task {
            do {
                let connected = try await runtime.session.start(
                    activeMode: true,
                    eventHandler: { [weak self] event in
                        Task { @MainActor in
                            self?.handle(event)
                        }
                    },
                    gestureHandler: { [weak self] event in
                        MXMasterRuntime.shared.actions.performGesture(event) { result in
                            Task { @MainActor in
                                self?.record(result)
                            }
                        }
                    },
                    tapHandler: { [weak self] in
                        MXMasterRuntime.shared.actions.performTap { result in
                            Task { @MainActor in
                                self?.record(result)
                            }
                        }
                    }
                )

                deviceName = connected.name
                hapticStatus = connected.hapticSupported
                    ? (connected.hapticDisabled ? "Off" : "Disable failed")
                    : "Unsupported"
                isEnabled = true
                isBusy = false
                status = connected.panelDiverted
                    ? "Enabled"
                    : "Connected in observation mode"
                UserDefaults.standard.set(true, forKey: "autoEnable")
            } catch {
                isEnabled = false
                isBusy = false
                status = error.localizedDescription
            }
        }
    }

    func disable() {
        guard !isBusy else {
            return
        }

        isBusy = true
        status = "Disconnecting…"
        Task {
            await runtime.session.stop()
            runtime.actions.cancelGestureSynchronously()
            isEnabled = false
            isBusy = false
            status = "Disabled"
            deviceName = "No device connected"
            UserDefaults.standard.set(false, forKey: "autoEnable")
        }
    }

    func requestPostEventPermission() {
        _ = runtime.actions.requestPostEventAccess()
        refreshPermissionState()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            status = "Login item: \(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }

    func refreshPermissionState() {
        hasPostEventAccess = runtime.actions.hasPostEventAccess
        secureInputEnabled = runtime.actions.secureInputEnabled
    }

    private func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func handle(_ event: MXMasterEvent) {
        switch event {
        case let .status(message):
            status = message
        case let .connected(device):
            deviceName = device.name
        case .disconnected:
            if !isBusy {
                status = "Disconnected"
                isEnabled = false
            }
        case .panelDown:
            lastInput = "Panel down"
        case .panelUp:
            lastInput = "Panel up"
        case let .direction(direction):
            lastInput = direction.rawValue
        case .tap:
            lastInput = "tap"
        case let .error(message):
            status = message
        }
    }

    private func record(_ result: ActionResult) {
        lastAction = result.succeeded
            ? result.action.rawValue
            : "\(result.action.rawValue) failed"

        if result.succeeded, result.secureInputWasEnabled {
            secureInputVerification =
                "Submitted — system event posted while enabled"
        }
    }
}
