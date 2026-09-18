import Foundation
import Security

// The per-model breakdown (Fable, Opus, …) only comes from /api/oauth/usage, and that
// endpoint needs the `user:profile` scope, which `claude setup-token` tokens lack.
// The Claude Code login on this Mac has it. It lives in a Keychain item whose
// service is "Claude Code-credentials"; macOS asks the user before handing the secret
// over, and a "Deny" is remembered so the prompt never nags.
//
// Access tokens last hours. The CLI only renews them when it runs, so Cockpit renews
// them itself exactly the way the CLI does (same endpoint, same client id, same
// scopes) and writes the new pair back into the same item, keeping the CLI logged in.
// The current access token is cached (0600) so rebuilds don't re-prompt while it's valid.
struct ClaudeCodeToken: Codable {
    var accessToken: String
    var expiresAt: Date?
    var scopes: [String]
    var subscription: String?
    var refreshToken: String? = nil   // only cached when the Keychain write-back failed
}

enum ClaudeCodeLogin {
    private static let service = "Claude Code-credentials"
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!   // Claude Code's TOKEN_URL
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"                     // Claude Code's public client
    private static let defaultScopes = ["user:inference", "user:profile"]

    enum Failure: Error, Equatable { case notFound, denied, malformed, noScope, expired, refreshFailed(String) }

    // What the last Keychain search / refresh saw (never the secret), for usage-state.json.
    // Written from inside the UsageService actor and from nonisolated statics, read on
    // the main actor, so it is lock-guarded and capped rather than grown without bound.
    private nonisolated(unsafe) static var diagnostic = ""
    private static let diagnosticLock = NSLock()
    private static let diagnosticLimit = 800

    static var lastDiagnostic: String {
        get {
            diagnosticLock.lock(); defer { diagnosticLock.unlock() }
            return diagnostic
        }
        set {
            diagnosticLock.lock(); defer { diagnosticLock.unlock() }
            diagnostic = String(newValue.prefix(diagnosticLimit))
        }
    }

    static func note(_ text: String) {
        diagnosticLock.lock(); defer { diagnosticLock.unlock() }
        diagnostic = String((diagnostic + text).suffix(diagnosticLimit))
    }

    struct Record {
        var service: String
        var account: String
        var token: ClaudeCodeToken
        var refreshToken: String?
    }

    static func current(allowKeychain: Bool) async -> Result<ClaudeCodeToken, Failure> {
        if let cached = readCache(), let exp = cached.expiresAt, exp.timeIntervalSinceNow > 300 {
            return .success(cached)
        }
        guard allowKeychain else { return .failure(.notFound) }
        return await fromKeychain(forceRefresh: false)
    }

    // forceRefresh: the server just rejected the access token, whatever its expiry says.
    static func fromKeychain(forceRefresh: Bool) async -> Result<ClaudeCodeToken, Failure> {
        switch readRecord() {
        case .failure(let f):
            return .failure(f)
        case .success(let rec):
            // A stash exists only because a write-back failed, which means the Keychain's
            // access token is the one the server already rejected. Short-circuiting to it
            // here would also write a record with no refreshToken over the cache and lose
            // the only live copy, so renew instead.
            let stash = readCache()?.refreshToken
            if !forceRefresh, stash == nil, let exp = rec.token.expiresAt, exp.timeIntervalSinceNow > 120 {
                writeCache(rec.token)
                return .success(rec.token)
            }
            return await refresh(rec)
        }
    }

    // MARK: - Renewal

    private static func refresh(_ rec: Record) async -> Result<ClaudeCodeToken, Failure> {
        // A refresh token the write-back couldn't store is newer than the Keychain's.
        var tokensToTry: [String] = []
        if let stashed = readCache()?.refreshToken, !stashed.isEmpty { tokensToTry.append(stashed) }
        if let kc = rec.refreshToken, !kc.isEmpty, !tokensToTry.contains(kc) { tokensToTry.append(kc) }
        guard !tokensToTry.isEmpty else { return .failure(.expired) }

        var lastFailure: Failure = .expired
        for rt in tokensToTry {
            switch await requestRefresh(refreshToken: rt, scopes: rec.token.scopes, subscription: rec.token.subscription) {
            case .success(let pair):
                // Cockpit never writes this Keychain item. Updating an item another app
                // created resets its access list, after which the Claude Code CLI has to ask
                // for the login password on every single read. The renewed pair lives in
                // ~/.cockpit instead, at 0600.
                var cached = pair.0
                cached.refreshToken = pair.1
                writeCache(cached)
                note(" · renewed (kept in ~/.cockpit)")
                return .success(pair.0)
            case .failure(let f):
                lastFailure = f
                // A refresh token the server has rejected is dead. Drop it so the next poll
                // does not replay it, which rotation-reuse detection reads as theft.
                if f == .expired, var cached = readCache(), cached.refreshToken == rt {
                    cached.refreshToken = nil
                    clearCache()
                    writeCache(cached)
                }
                if case .refreshFailed = f { return .failure(f) }   // network trouble: the other token won't help
            }
        }
        return .failure(lastFailure)
    }

    private static func requestRefresh(refreshToken: String, scopes: [String], subscription: String?) async -> Result<(ClaudeCodeToken, String), Failure> {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let scopeList = scopes.isEmpty ? defaultScopes : scopes
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": scopeList.joined(separator: " "),
        ])
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .failure(.refreshFailed("no response")) }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard http.statusCode == 200, let access = obj?["access_token"] as? String, !access.isEmpty else {
                let why = (obj?["error_description"] as? String) ?? (obj?["error"] as? String) ?? "HTTP \(http.statusCode)"
                note(" · refresh refused: \(why)")
                return .failure((400...401).contains(http.statusCode) ? .expired : .refreshFailed(why))
            }
            let newRefresh = (obj?["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
            let expiresIn = (obj?["expires_in"] as? NSNumber)?.doubleValue ?? 3600
            let newScopes = (obj?["scope"] as? String).map { $0.split(separator: " ").map(String.init) } ?? scopeList
            let token = ClaudeCodeToken(accessToken: access, expiresAt: Date().addingTimeInterval(expiresIn), scopes: newScopes, subscription: subscription)
            return .success((token, newRefresh))
        } catch {
            return .failure(.refreshFailed("offline"))
        }
    }

    // MARK: - Reading

    private static func readRecord() -> Result<Record, Failure> {
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
            case .success(let r): return .success(r)
            case .failure(let f):
                lastFailure = f
                if f == .denied { return .failure(.denied) }
            }
        }
        return .failure(lastFailure)
    }

    private struct Candidate { var service: String; var account: String; var modified: Date }

    // Attributes only: no secret is read and macOS shows no prompt for this. The exact
    // service name is asked for first, so the broad scan below only runs for the rare
    // install whose item carries a suffix.
    private static func findCandidates() -> [Candidate] {
        var exact: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        exact[kSecReturnData as String] = false
        var exactResult: CFTypeRef?
        if SecItemCopyMatching(exact as CFDictionary, &exactResult) == errSecSuccess,
           let items = exactResult as? [[String: Any]], !items.isEmpty {
            return items.map { item in
                Candidate(
                    service: item[kSecAttrService as String] as? String ?? service,
                    account: item[kSecAttrAccount as String] as? String ?? "",
                    modified: item[kSecAttrModificationDate as String] as? Date ?? .distantPast
                )
            }
        }

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

    private static func readItem(service: String, account: String?) -> Result<Record, Failure> {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account, !account.isEmpty { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return .failure(status == errSecItemNotFound ? .notFound : .denied)
        }
        guard let dict = item as? [String: Any],
              let data = dict[kSecValueData as String] as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
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
        let acct = dict[kSecAttrAccount as String] as? String ?? account ?? ""
        return .success(Record(service: service, account: acct, token: t, refreshToken: oauth["refreshToken"] as? String))
    }

    // MARK: - Cache

    static func clearCache() { try? FileManager.default.removeItem(at: CockpitPaths.loginCache) }

    // The server rejected the access token. Dropping the whole cache here would also drop a
    // refresh token that `writeBack` failed to store, and that copy is the only live one:
    // the Keychain still holds the predecessor the server invalidated when it rotated.
    // Losing it signs the user out of Cockpit and of the Claude Code CLI, permanently.
    static func invalidateAccessToken() {
        guard var cached = readCache(), let stashed = cached.refreshToken, !stashed.isEmpty else {
            clearCache()
            return
        }
        cached.accessToken = ""
        cached.expiresAt = .distantPast
        writeCache(cached)
    }

    private static func readCache() -> ClaudeCodeToken? {
        guard let data = try? Data(contentsOf: CockpitPaths.loginCache) else { return nil }
        return try? JSONDecoder().decode(ClaudeCodeToken.self, from: data)
    }

    private static func writeCache(_ t: ClaudeCodeToken) {
        CockpitPaths.ensure()
        // Never drop a refresh token already on disk: it can be the only live copy.
        var t = t
        if t.refreshToken == nil, let existing = readCache()?.refreshToken, !existing.isEmpty {
            t.refreshToken = existing
        }
        guard let data = try? JSONEncoder().encode(t) else { return }
        CockpitPaths.writePrivate(data, to: CockpitPaths.loginCache)
    }
}
