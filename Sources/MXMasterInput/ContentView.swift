import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Device") {
                LabeledContent("Status", value: model.status)
                LabeledContent("Device", value: model.deviceName)
                LabeledContent("Haptic engine", value: model.hapticStatus)

                HStack {
                    Button(model.isEnabled ? "Disable" : "Enable") {
                        if model.isEnabled {
                            model.disable()
                        } else {
                            model.enable()
                        }
                    }
                    .disabled(model.isBusy)

                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            Section("Secure Input path") {
                LabeledContent(
                    "Secure Input",
                    value: model.secureInputEnabled ? "Enabled" : "Disabled"
                )
                LabeledContent(
                    "Post-event permission",
                    value: model.hasPostEventAccess ? "Granted" : "Required"
                )
                LabeledContent(
                    "Runtime verification",
                    value: model.secureInputVerification
                )

                if !model.hasPostEventAccess {
                    Button("Grant Accessibility permission") {
                        model.requestPostEventPermission()
                    }
                }

                Text(
                    "MX Master input is read directly from HID++. Space changes "
                    + "and window actions use Control-arrow shortcuts posted "
                    + "through Accessibility. Runtime verification confirms "
                    + "submission, not delivery, while Secure Input is on."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Panel mapping") {
                mapping("Tap", "Control–Up · Mission Control")
                mapping("Left", "Control–Right · Next Space")
                mapping("Right", "Control–Left · Previous Space")

                Text(
                    "Any movement into the left or right half-plane changes "
                    + "Spaces in that direction. A central dead zone filters "
                    + "click pressure. Actions post immediately. A short click "
                    + "opens Mission Control."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                LabeledContent("Last input", value: model.lastInput)
                LabeledContent("Last action", value: model.lastAction)
            }

            Section {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 590)
        .padding()
    }

    private func mapping(_ input: String, _ output: String) -> some View {
        LabeledContent(input, value: output)
    }
}
