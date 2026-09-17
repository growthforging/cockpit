import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var usage: UsageModel
    @EnvironmentObject var clips: ClipboardStore
    @EnvironmentObject var scroll: ScrollFlipEngine
    @State private var tokenInput = ""
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    // "A file exists" is not the same as "the token works"; a mistyped or expired one
    // used to sit there in green indefinitely.
    private var tokenStatus: (String, Color) {
        guard usage.hasToken else { return ("none", .secondary) }
        let source = TokenStore.sourceDescription
        switch usage.snapshot.source {
        case .ping: return ("working (\(source))", .green)
        case .login: return ("saved (\(source)), unused while the login answers", .secondary)
        case .local, .unavailable: return ("saved (\(source)), but Anthropic did not accept it", .orange)
        }
    }

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
                Text("Fable, Opus and the other per-model windows only come from Anthropic's usage endpoint, which needs the login Claude Code keeps in your Keychain. macOS asks before Cockpit reads it. Access tokens last hours, so Cockpit renews the login the same way the CLI does, using the same endpoint, client id and scopes, then writes the renewed pair back into that same Keychain item so `claude` stays signed in. The current access token is cached at ~/.cockpit/claude-code-login.json, mode 0600, and a renewed refresh token lands there too on the rare occasion the Keychain write-back fails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Fallback token") {
                    Text(tokenStatus.0).foregroundStyle(tokenStatus.1)
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
                if clips.hotkeyUnavailable {
                    Text("macOS refused that shortcut. Another app, often a launcher like Raycast or Alfred, already owns ⇧⌘V. Free it there, or open the history from the island.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Stepper("Keep \(clips.maxItems) clips", value: $clips.maxItems, in: 20...500, step: 10)
                Button("Clear history", role: .destructive) { clips.clear() }
                    .disabled(clips.items.isEmpty)
                Text("Text, files and images, kept in ~/.cockpit at mode 0600. Apps that mark a copy concealed, among them 1Password and KeePassXC, are skipped, but that marking is a voluntary convention: Apple's Passwords app and anything copied through a browser extension are recorded like ordinary text. Switch recording off before copying a secret.")
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
