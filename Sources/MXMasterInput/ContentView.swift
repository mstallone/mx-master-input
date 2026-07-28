import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var diagnosticsExpanded = true

    var body: some View {
        Form {
            Section("Device") {
                LabeledContent("Status", value: model.status)
                LabeledContent("Device", value: model.deviceName)
                LabeledContent("Haptic engine", value: model.hapticStatus)
                LabeledContent(
                    "Accessibility",
                    value: model.hasPostEventAccess ? "Granted" : "Required"
                )

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

                    if !model.hasPostEventAccess {
                        Button("Grant Accessibility permission") {
                            model.requestPostEventPermission()
                        }
                    }
                }
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

            Section {
                DisclosureGroup(
                    isExpanded: $diagnosticsExpanded
                ) {
                    VStack(spacing: 10) {
                        LabeledContent(
                            "Secure Input",
                            value: model.secureInputEnabled
                                ? "Enabled"
                                : "Disabled"
                        )
                        LabeledContent("Last input", value: model.lastInput)
                        LabeledContent("Last action", value: model.lastAction)
                    }
                    .padding(.top, 10)
                } label: {
                    Text("Diagnostics")
                        .font(.headline)
                }
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
