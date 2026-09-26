import AppKit
import OSLog
import ServiceManagement
import Sparkle

let appName = "MX Master Input"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum Status: Equatable {
        case off
        case needsAccessibility
        case connecting
        case connected(name: String, battery: Int?, asleep: Bool)
        /// `retrying` when the cause is one that fixes itself, like a sleeping mouse or a missing receiver.
        case failed(String, retrying: Bool)
    }

    private static let logger = Logger(subsystem: "com.mattstallone.mxmasterinput", category: "App")
    private static let activeIcon = icon(opacity: 1, description: appName)
    private static let inactiveIcon = icon(opacity: 0.4, description: "\(appName), inactive")
    private let session = MXMasterSession()
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private let menu = NSMenu()
    private var statusItem: NSStatusItem?
    private var connection: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var retryDelay: Duration = .seconds(2)
    private var permissionWatch: Timer?
    /// Set while a session is running, even when a failure is shown, so later events can still update
    /// the menu: a wake that succeeds after one that failed, or the receiver being unplugged.
    private var mouseName: String?

    private var status = Status.off {
        didSet { statusItem?.button?.image = status.isActive ? Self.activeIcon : Self.inactiveIcon }
    }

    /// Stored under the key 0.1.x used, so an upgrade keeps the user's choice.
    private var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "autoEnable") }
        set { UserDefaults.standard.set(newValue, forKey: "autoEnable") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["autoEnable": true])
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.inactiveIcon
        menu.delegate = self
        item.menu = menu
        statusItem = item
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        if isEnabled { connect() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.stopSynchronously()
    }

    // MARK: Menu, rebuilt on open so every state it shows is current

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem()
        header.view = headerView
        menu.addItem(header)
        switch status {
        case .needsAccessibility:
            menu.addItem(withTitle: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            let reset = menu.addItem(withTitle: "Reset Accessibility Permission", action: #selector(resetAccessibility), keyEquivalent: "")
            reset.isAlternate = true
            reset.keyEquivalentModifierMask = .option
        case .failed(_, retrying: false):
            menu.addItem(withTitle: "Try Again", action: #selector(tryAgain), keyEquivalent: "")
        default:
            break
        }
        let toggle = isEnabled ? "Turn Gestures Off" : "Turn Gestures On"
        menu.addItem(withTitle: toggle, action: #selector(toggleEnabled), keyEquivalent: "")
        menu.addItem(.separator())

        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let update = menu.addItem(withTitle: "Check for Updates…",
                                  action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updater
        menu.addItem(.separator())

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        addInfo("\(appName) \(version)")
        menu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate), keyEquivalent: "q")
    }

    /// The mouse, and its battery or what's keeping gestures from working.
    private var headerView: MenuHeaderView {
        switch status {
        case let .connected(name, battery, asleep):
            MenuHeaderView(title: name, detail: asleep ? .status("Asleep") : battery.map { .battery($0) })
        case .off: MenuHeaderView(title: "MX Master 4", detail: .status("Gestures Off"))
        case .connecting: MenuHeaderView(title: "MX Master 4", detail: .status("Connecting…"))
        case .needsAccessibility: MenuHeaderView(title: "MX Master 4", detail: .message("\(appName) needs Accessibility permission."))
        case let .failed(message, _): MenuHeaderView(title: "MX Master 4", detail: .message(message))
        }
    }

    private func addInfo(_ title: String) {
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
    }

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        Self.logger.notice("Gestures turned \(self.isEnabled ? "on" : "off")")
        if isEnabled { connect() } else { disconnect() }
    }

    @objc private func tryAgain() { connect() }

    @objc private func toggleLogin() {
        do { try SMAppService.mainApp.status == .enabled ? SMAppService.mainApp.unregister() : SMAppService.mainApp.register() }
        catch { NSApp.presentError(error) }
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Clears a stale entry, which is what macOS keeps when the app's signature changes: the switch
    /// shows as on, but the app is not trusted.
    @objc private func resetAccessibility() {
        let tccutil = Process()
        tccutil.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tccutil.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? ""]
        try? tccutil.run()
        tccutil.waitUntilExit()
        CGRequestPostEventAccess()
    }

    @objc private func systemDidWake() {
        if case .failed = status { connect() }
    }

    // MARK: Session

    private func connect() {
        connection?.cancel()
        retry?.cancel()
        mouseName = nil
        guard CGPreflightPostEventAccess() else {
            status = .needsAccessibility
            CGRequestPostEventAccess() // adds the app to the list, and prompts the first time
            watchForAccessibility()
            return
        }
        status = .connecting
        connection = Task {
            do {
                let mouse = try await session.start { event in
                    Task { @MainActor in self.handle(event) }
                }
                guard !Task.isCancelled else {
                    // Turned off while connecting; the stop may have run before this start did.
                    if !isEnabled { await session.stop() }
                    return
                }
                retryDelay = .seconds(2)
                mouseName = mouse.name
                status = .connected(name: mouse.name, battery: mouse.batteryPercent, asleep: false)
            } catch {
                guard !Task.isCancelled else { return }
                Self.logger.error("Connect failed: \(String(describing: error), privacy: .public)")
                fail(error.localizedDescription, retrying: Self.fixesItself(error))
            }
        }
    }

    private func disconnect() {
        connection?.cancel()
        retry?.cancel()
        mouseName = nil
        retryDelay = .seconds(2)
        permissionWatch?.invalidate()
        status = .off
        Task { await session.stop() }
    }

    private func handle(_ event: SessionEvent) {
        guard let name = mouseName else { return }
        let battery: Int? = if case let .connected(_, battery, _) = status { battery } else { nil }
        switch event {
        case let .battery(percent): status = .connected(name: name, battery: percent, asleep: false)
        case .asleep: status = .connected(name: name, battery: nil, asleep: true)
        case .awake: status = .connected(name: name, battery: battery, asleep: false)
        case .recoveryFailed: fail("It woke but didn’t accept its configuration.", retrying: false)
        case .receiverRemoved:
            mouseName = nil
            fail(SessionError.noReceiver.localizedDescription, retrying: true)
        }
    }

    /// Shows the failure, and for causes that resolve on their own, reconnects with a growing delay.
    private func fail(_ message: String, retrying: Bool) {
        status = .failed(message, retrying: retrying)
        guard retrying else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(10))
        retry = Task {
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { connect() }
        }
    }

    private static func fixesItself(_ error: Error) -> Bool {
        switch error as? SessionError {
        case .noReceiver, .noMouse: true
        default: false
        }
    }

    /// Accessibility is granted in System Settings while the app runs; start as soon as it is.
    private func watchForAccessibility() {
        permissionWatch?.invalidate()
        permissionWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard CGPreflightPostEventAccess() else { return }
            timer.invalidate()
            MainActor.assumeIsolated { self?.connect() }
        }
    }
}

extension AppDelegate {
    /// The menu-bar glyph at full strength while gestures work, and faded otherwise, as Runway fades a
    /// spent meter. Faded by drawing at partial opacity rather than with `appearsDisabled`, so the level
    /// is the same on every menu bar; it stays a template, so the menu bar still tints it.
    private static func icon(opacity: CGFloat, description: String) -> NSImage {
        let symbol = NSImage(systemSymbolName: "computermouse", accessibilityDescription: nil)!
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}

private extension AppDelegate.Status {
    /// Connected, including while the mouse sleeps: it wakes ready, and fading at every idle pause would
    /// make the icon flicker.
    var isActive: Bool {
        if case .connected = self { true } else { false }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
