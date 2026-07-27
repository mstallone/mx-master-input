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
                    "MX Master input is read directly from HID++. Panel drags "
                    + "use the Apple-native continuous gesture pipeline. Taps "
                    + "and the compatibility fallback use Control–arrow through "
                    + "Accessibility. Runtime verification confirms submission, "
                    + "not delivery."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Panel mapping") {
                mapping("Tap", "Control–Up · Mission Control")
                mapping("Drag up", "Fluid swipe · Mission Control")
                mapping(
                    "Drag down",
                    "Fluid swipe · Close Mission Control when open"
                )
                mapping("Drag left", "Fluid swipe · Next Space")
                mapping("Drag right", "Fluid swipe · Previous Space")

                Text(
                    "Magic Trackpad-style control: hold the Sense Panel and "
                    + "drag left, right, or up. The desktop follows the mouse, "
                    + "reversals take effect inside the same gesture, and "
                    + "release commits or snaps back. A central dead zone "
                    + "filters click pressure."
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
