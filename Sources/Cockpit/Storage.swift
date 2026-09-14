import Foundation

// Everything Cockpit persists lives in ~/.cockpit (0700).
enum CockpitPaths {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cockpit")
    static var token: URL { dir.appendingPathComponent("token") }
    static var history: URL { dir.appendingPathComponent("history.json") }
    static var clips: URL { dir.appendingPathComponent("clips.json") }
    static var clipImages: URL { dir.appendingPathComponent("clips") }
    static var state: URL { dir.appendingPathComponent("state.json") }
    static var loginCache: URL { dir.appendingPathComponent("claude-code-login.json") }

    static func ensure() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.createDirectory(at: clipImages, withIntermediateDirectories: true)
    }

    // First launch inherits MaxBar's token and pace history, so nothing needs pasting again.
    static func migrateFromMaxBar() {
        ensure()
        let fm = FileManager.default
        let old = fm.homeDirectoryForCurrentUser.appendingPathComponent(".maxbar")
        let oldToken = old.appendingPathComponent("token")
        if !fm.fileExists(atPath: token.path), fm.fileExists(atPath: oldToken.path) {
            try? fm.copyItem(at: oldToken, to: token)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        }
        let oldHistory = old.appendingPathComponent("history.json")
        if !fm.fileExists(atPath: history.path), fm.fileExists(atPath: oldHistory.path) {
            try? fm.copyItem(at: oldHistory, to: history)
        }
    }
}

// MaxBar's preferences, read once so Cockpit starts with the same tuning.
enum LegacyPrefs {
    private static let suite = UserDefaults(suiteName: "com.planmaxxing.maxbar")
    static func object(_ key: String) -> Any? { suite?.object(forKey: key) }
}

// The OAuth token for the exact-usage ping. Sourced in priority order:
//   1. CLAUDE_CODE_OAUTH_TOKEN in the environment
//   2. ~/.cockpit/token (0600 file, written when you paste a token in Settings)
enum TokenStore {
    private static let envKey = "CLAUDE_CODE_OAUTH_TOKEN"

    static func current() -> String? {
        if let env = ProcessInfo.processInfo.environment[envKey] {
            let t = env.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return readFile()
    }

    static var hasToken: Bool { current() != nil }

    static var sourceDescription: String {
        if let env = ProcessInfo.processInfo.environment[envKey], !env.isEmpty { return "environment variable" }
        if readFile() != nil { return "~/.cockpit/token" }
        return "none"
    }

    static func save(_ token: String) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { clear(); return }
        CockpitPaths.ensure()
        do {
            try t.write(to: CockpitPaths.token, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: CockpitPaths.token.path)
        } catch {
            NSLog("Cockpit token save error: \(error.localizedDescription)")
        }
    }

    static func clear() { try? FileManager.default.removeItem(at: CockpitPaths.token) }

    private static func readFile() -> String? {
        guard let s = try? String(contentsOf: CockpitPaths.token, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
