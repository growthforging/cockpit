import Foundation

// Everything Cockpit keeps lives in ~/.cockpit, and all of it is owner-only. The
// clipboard history is a plaintext record of everything you have copied, which makes
// it about as sensitive as anything on the machine.
enum CockpitPaths {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cockpit")
    static var token: URL { dir.appendingPathComponent("token") }
    static var history: URL { dir.appendingPathComponent("history.json") }
    static var clips: URL { dir.appendingPathComponent("clips.json") }
    static var clipImages: URL { dir.appendingPathComponent("clips") }
    static var state: URL { dir.appendingPathComponent("state.json") }
    static var usageState: URL { dir.appendingPathComponent("usage-state.json") }
    static var paceState: URL { dir.appendingPathComponent("pace-state.json") }
    static var loginCache: URL { dir.appendingPathComponent("claude-code-login.json") }

    // createDirectory ignores `attributes:` when the path already exists, so the mode is
    // set again every time. A directory that arrived from a backup, a Migration Assistant
    // transfer, or a bare mkdir before first launch gets repaired instead of staying open.
    static func ensure() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? fm.createDirectory(at: clipImages, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: clipImages.path)
    }

    // The only way anything here should reach disk. An atomic write lands as a fresh
    // file whose mode comes from the umask, so 0600 is applied afterwards rather than
    // assumed.
    @discardableResult
    static func writePrivate(_ data: Data, to url: URL) -> Bool {
        ensure()
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    // Tightens whatever an older build left world-readable, once per launch.
    static func repairPermissions() {
        ensure()
        let fm = FileManager.default
        var files = [token, history, clips, state, usageState, paceState, loginCache]
        if let images = try? fm.contentsOfDirectory(at: clipImages, includingPropertiesForKeys: nil) {
            files += images
        }
        for file in files where fm.fileExists(atPath: file.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
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
        CockpitPaths.writePrivate(Data(t.utf8), to: CockpitPaths.token)
    }

    static func clear() { try? FileManager.default.removeItem(at: CockpitPaths.token) }

    private static func readFile() -> String? {
        guard let s = try? String(contentsOf: CockpitPaths.token, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
