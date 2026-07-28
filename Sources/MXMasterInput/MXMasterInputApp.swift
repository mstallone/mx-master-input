import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MXMasterRuntime.shared.session.stopSynchronously()
        MXMasterRuntime.shared.actions.cancelGestureSynchronously()
    }
}
@main
struct MXMasterInputApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openSettings) private var openSettings
    @StateObject private var model = AppModel()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.deviceName)
                    .font(.headline)
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Button(model.isEnabled ? "Disable" : "Enable") {
                    if model.isEnabled {
                        model.disable()
                    } else {
                        model.enable()
                    }
                }
                .disabled(model.isBusy)

                Button("Settings…") {
                    openSettings()
                    NSApplication.shared.activate()
                }

                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)

                Divider()

                Button("Quit MX Master Input") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(8)
            .frame(width: 250)
        } label: {
            Label(
                "MX Master Input",
                systemImage: model.isEnabled
                    ? "computermouse.fill"
                    : "computermouse"
            )
        }

        Settings {
            ContentView(model: model)
        }
    }
}
