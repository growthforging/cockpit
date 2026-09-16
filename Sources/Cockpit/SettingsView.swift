import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var usage: UsageModel
    @EnvironmentObject var clips: ClipboardStore
    @EnvironmentObject var scroll: ScrollFlipEngine
    @State private var tokenInput = ""
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section("Usage") {
                Toggle("Per-model usage from the Claude Code login", isOn: $usage.useClaudeCodeLogin)
                LabeledContent("Login") {
                    Text(usage.useClaudeCodeLogin ? usage.loginState.label : "off")
                        .foregroundStyle(usage.loginState == .connected ? .green : .secondary)
                }
                if usage.useClaudeCodeLogin, usage.loginState != .connected {
                    Button("Ask for Keychain access again") { usage.retryLogin() }
                }
                Toggle("Show unlabeled windows the usage API returns", isOn: $usage.showUnlabeledBuckets)
                Text("Fable, Opus and the other per-model windows only come from Anthropic's usage endpoint, which needs the login Claude Code keeps in your Keychain. macOS asks before Cockpit can read it; the token is cached locally and never refreshed by Cockpit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Fallback token") {
                    Text(usage.hasToken ? "found (\(TokenStore.sourceDescription))" : "none")
                        .foregroundStyle(usage.hasToken ? .green : .secondary)
                }
                SecureField("Paste a `claude setup-token` token", text: $tokenInput)
                HStack {
                    Button("Save token") {
                        usage.setToken(tokenInput)
                        tokenInput = ""
                    }
                    .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if usage.hasToken {
                        Button("Clear", role: .destructive) { usage.clearToken() }
                    }
                }
                Text("Used only when the login isn't available: one 1-token ping reads the session and weekly % from Anthropic's response headers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notch") {
                Picker("Show", selection: $usage.displayMode) {
                    Text("Menu bar").tag(DisplayMode.menuBar)
                    Text("Under notch").tag(DisplayMode.notch)
                    Text("Both").tag(DisplayMode.both)
                }
                .pickerStyle(.segmented)
                Toggle("Readouts either side of the notch", isOn: $usage.notchFlanks)
                    .disabled(!usage.displayMode.showsNotch)
                Picker("Left of notch", selection: $usage.leftFlankKey) {
                    ForEach(usage.flankChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Right of notch", selection: $usage.rightFlankKey) {
                    ForEach(usage.flankChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                Text("Automatic shows Fable on the left when the login provides it (otherwise the week), and the 5-hour session on the right. Pick Fable for both, or Nothing for a side, to make the notch show only what you care about.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Menu bar chip", selection: $usage.menuBarMode) {
                    Text("Same readouts as the notch").tag(MenuBarMode.flanks)
                    Text("Every window").tag(MenuBarMode.all)
                }
                Text("The chip lives in the menu bar of an external display (and beside the island whenever more than one screen is connected). Click it for the full panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Corner radius")
                    Slider(value: $usage.notchCornerRadius, in: 2...18, step: 0.5)
                    Text(String(format: "%.1f", usage.notchCornerRadius))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                .disabled(!usage.displayMode.showsNotch)
            }

            Section("Clipboard history") {
                Toggle("Record what I copy", isOn: $clips.enabled)
                Toggle("Add new screenshots to the history", isOn: $clips.screenshotsEnabled)
                Toggle("⇧⌘V opens the history", isOn: $clips.hotkeyEnabled)
                Stepper("Keep \(clips.maxItems) clips", value: $clips.maxItems, in: 20...500, step: 10)
                Button("Clear history", role: .destructive) { clips.clear() }
                    .disabled(clips.items.isEmpty)
                Text("Text, files and images. Copies from password managers are marked concealed and never recorded. Everything stays in ~/.cockpit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Mouse wheel") {
                Toggle("Reverse mouse wheel (trackpad stays natural)", isOn: $scroll.enabled)
                LabeledContent("Accessibility") {
                    Text(scroll.axTrusted ? "granted" : "not granted")
                        .foregroundStyle(scroll.axTrusted ? .green : .orange)
                }
                if !scroll.axTrusted {
                    Button("Open Accessibility settings") {
                        scroll.requestPermission(prompt: true)
                        SettingsOpener.openAccessibility()
                    }
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { launchAtLogin = $0; LaunchAtLogin.set($0) }
                ))
                Stepper("Refresh every \(usage.refreshSeconds)s", value: $usage.refreshSeconds, in: 15...600, step: 15)
                Toggle("Pace notifications", isOn: $usage.notificationsEnabled)
                Text("Warns when your burn rate puts you on track to run dry before a window resets, and when a limit is actually reached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 720)
    }
}
