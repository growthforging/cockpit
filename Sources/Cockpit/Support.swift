import AppKit
import SwiftUI
import UserNotifications

// Local notifications for pace alerts. Authorization is asked for the first time an
// alert would actually fire, rather than at launch alongside two other prompts, and the
// alert that triggered the request still goes out once permission is granted.
final class Notifier {
    func fire(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { Notifier.post(center, title: title, body: body) }
                }
            case .denied:
                return
            default:
                Notifier.post(center, title: title, body: body)
            }
        }
    }

    private static func post(_ center: UNUserNotificationCenter, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// Starts the app at login via a per-user LaunchAgent. A plain plist (rather than
// SMAppService) stays reliable for an ad-hoc-signed app.
enum LaunchAtLogin {
    static var label: String { Bundle.main.bundleIdentifier ?? "com.growthforging.cockpit" }

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func set(_ enabled: Bool) { enabled ? enable() : disable() }

    // The plist stores an absolute path. Re-point it whenever the app has moved since the
    // toggle was flipped, which is exactly what the documented build-then-copy flow does.
    static func repairIfMoved() {
        guard isEnabled else { return }
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              let stored = args.last
        else { return }
        if stored != Bundle.main.bundlePath { enable() }
    }

    private static func enable() {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", Bundle.main.bundlePath],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? data.write(to: plistURL)
    }

    private static func disable() { try? FileManager.default.removeItem(at: plistURL) }
}

// Cockpit's settings live in a window it owns. The SwiftUI Settings scene ignores
// the showSettingsWindow: selector from a non-activating panel, so the gear did nothing.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var usage: UsageModel?
    private var clips: ClipboardStore?
    private var scroll: ScrollFlipEngine?

    func configure(usage: UsageModel, clips: ClipboardStore, scroll: ScrollFlipEngine) {
        self.usage = usage
        self.clips = clips
        self.scroll = scroll
    }

    func show() {
        guard let usage, let clips, let scroll else { return }
        if window == nil {
            let root = SettingsView()
                .environmentObject(usage)
                .environmentObject(clips)
                .environmentObject(scroll)
            let w = NSWindow(contentViewController: NSHostingController(rootView: root))
            w.title = "Cockpit Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsOpener {
    @MainActor static func open() { SettingsWindowController.shared.show() }

    static func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// What the app actually put on screen, for when a readout seems to be missing.
enum Diagnostics {
    private static let ioQueue = DispatchQueue(label: "com.growthforging.cockpit.diagnostics", qos: .utility)

    // Which source fed the last refresh and how the Claude Code login went: ~/.cockpit/usage-state.json
    static func writeUsage(_ r: FetchResult, loginDeclined: Bool) {
        CockpitPaths.ensure()
        let iso = ISO8601DateFormatter()
        let buckets: [[String: Any]] = r.snapshot.buckets.map { b in
            ["key": b.key, "pct": b.pct, "reset": b.resetAt.map { iso.string(from: $0) } ?? ""]
        }
        let s: [String: Any] = [
            "source": r.snapshot.source.rawValue,
            "precise": r.snapshot.precise,
            "loginState": r.loginState.label,
            "loginDeclined": loginDeclined,
            "loginDiagnostic": ClaudeCodeLogin.lastDiagnostic,
            "endpointKeys": r.snapshot.rawKeys,
            "endpointExtras": r.snapshot.rawExtrasJSON,
            "buckets": buckets,
            "note": r.snapshot.note ?? "",
            "asOf": iso.string(from: r.snapshot.asOf),
        ]
        ioQueue.async {
            if let data = try? JSONSerialization.data(withJSONObject: s, options: .prettyPrinted) {
                CockpitPaths.writePrivate(data, to: CockpitPaths.usageState)
            }
        }
    }

    // The verdict per window: ~/.cockpit/pace-state.json
    static func writePaces(_ paces: [String: Pace]) {
        CockpitPaths.ensure()
        var s: [String: Any] = [:]
        for (key, p) in paces {
            s[key] = ["verdict": p.verdict.compact, "risk": "\(p.risk)", "expectedPct": (p.expectedPct * 10).rounded() / 10]
        }
        s["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        ioQueue.async {
            if let data = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) {
                CockpitPaths.writePrivate(data, to: CockpitPaths.paceState)
            }
        }
    }

    static func write(_ state: [String: Any]) {
        CockpitPaths.ensure()
        var s = state
        s["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        ioQueue.async {
            if let data = try? JSONSerialization.data(withJSONObject: s, options: .prettyPrinted) {
                CockpitPaths.writePrivate(data, to: CockpitPaths.state)
            }
        }
    }
}
