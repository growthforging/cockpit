import Foundation
import Security

// The per-model breakdown (Fable, Opus, …) only comes from /api/oauth/usage, and that
// endpoint needs the `user:profile` scope, which `claude setup-token` tokens lack.
// The Claude Code login on this Mac has it. It lives in a Keychain item whose
// service is "Claude Code-credentials" (possibly suffixed); macOS asks the user
// before handing the secret over, and a "Deny" is remembered so the prompt never nags.
//
// The access token is cached (0600) so rebuilds don't re-prompt while it's valid.
// Cockpit never refreshes the token itself: rotating it could log Claude Code out.
struct ClaudeCodeToken: Codable {
    var accessToken: String
    var expiresAt: Date?
    var scopes: [String]
    var subscription: String?
}

enum ClaudeCodeLogin {
    private static let service = "Claude Code-credentials"

    enum Failure: Error { case notFound, denied, malformed, noScope }

    // What the last Keychain search saw (service names only), for usage-state.json.
    nonisolated(unsafe) static var lastDiagnostic = ""

    static func current(allowKeychain: Bool) -> Result<ClaudeCodeToken, Failure> {
        if let cached = readCache(), let exp = cached.expiresAt, exp.timeIntervalSinceNow > 300 {
            return .success(cached)
        }
        guard allowKeychain else { return .failure(.notFound) }
        return readKeychain()
    }

    static func readKeychain() -> Result<ClaudeCodeToken, Failure> {
        let candidates = findCandidates()
        lastDiagnostic = candidates.isEmpty
            ? "no Keychain item with a Claude Code credentials service name"
            : "candidates: " + candidates.map { "\($0.service) [\($0.account)]" }.joined(separator: ", ")

        // Exact CLI name first, then whatever was touched most recently.
        let ordered = candidates.sorted { a, b in
            if (a.service == service) != (b.service == service) { return a.service == service }
            return a.modified > b.modified
        }
        let tries: [(String, String?)] = ordered.isEmpty ? [(service, nil)] : ordered.map { ($0.service, $0.account) }

        var lastFailure: Failure = .notFound
        for (svc, acct) in tries {
            switch readItem(service: svc, account: acct) {
            case .success(let t): return .success(t)
            case .failure(let f):
                lastFailure = f
                if f == .denied { return .failure(.denied) }
            }
        }
        return .failure(lastFailure)
    }

    private struct Candidate { var service: String; var account: String; var modified: Date }

    // Attributes only: no secret is read and macOS shows no prompt for this.
    private static func findCandidates() -> [Candidate] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let svc = item[kSecAttrService as String] as? String else { return nil }
            let s = svc.lowercased()
            guard s.contains("claude"), s.contains("credential") else { return nil }
            return Candidate(
                service: svc,
                account: item[kSecAttrAccount as String] as? String ?? "",
                modified: item[kSecAttrModificationDate as String] as? Date ?? .distantPast
            )
        }
    }

    private static func readItem(service: String, account: String?) -> Result<ClaudeCodeToken, Failure> {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account, !account.isEmpty { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return .failure(status == errSecItemNotFound ? .notFound : .denied)
        }
        guard let data = item as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return .failure(.malformed) }

        let scopes = oauth["scopes"] as? [String] ?? []
        let exp = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let t = ClaudeCodeToken(
            accessToken: token,
            expiresAt: exp,
            scopes: scopes,
            subscription: oauth["subscriptionType"] as? String
        )
        if !scopes.isEmpty, !scopes.contains("user:profile") { return .failure(.noScope) }
        writeCache(t)
        return .success(t)
    }

    static func clearCache() { try? FileManager.default.removeItem(at: CockpitPaths.loginCache) }

    private static func readCache() -> ClaudeCodeToken? {
        guard let data = try? Data(contentsOf: CockpitPaths.loginCache) else { return nil }
        return try? JSONDecoder().decode(ClaudeCodeToken.self, from: data)
    }

    private static func writeCache(_ t: ClaudeCodeToken) {
        CockpitPaths.ensure()
        guard let data = try? JSONEncoder().encode(t) else { return }
        try? data.write(to: CockpitPaths.loginCache, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: CockpitPaths.loginCache.path)
    }
}
