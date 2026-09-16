import Foundation

enum LoginState: Equatable {
    case off            // switched off in Settings
    case connected
    case notFound       // no Claude Code login on this Mac
    case denied         // the Keychain prompt was declined
    case noScope        // login lacks user:profile
    case failed(String)

    var label: String {
        switch self {
        case .off: return "off"
        case .connected: return "connected"
        case .notFound: return "no Claude Code login found"
        case .denied: return "Keychain access declined"
        case .noScope: return "login lacks the usage scope"
        case .failed(let why): return why
        }
    }
}

struct FetchResult {
    var snapshot: UsageSnapshot
    var loginState: LoginState
}

// Fetches a usage snapshot, best source first:
//   1. Claude Code login → /api/oauth/usage (every window incl. per-model limits)
//   2. pasted token → one tiny ping, read the rate-limit headers (5h + 7d)
//   3. local log estimate
actor UsageService {
    private let messages = URL(string: "https://api.anthropic.com/v1/messages")!
    private let usage = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let pingModel = "claude-haiku-4-5-20251001"
    private let timeout: TimeInterval = 10

    enum UsageError: Error { case badResponse, unauthorized, forbidden, http(Int), noHeaders(Int), empty }

    func fetch(useLogin: Bool, allowKeychain: Bool) async -> FetchResult {
        var loginState: LoginState = .off

        if useLogin {
            switch await ClaudeCodeLogin.current(allowKeychain: allowKeychain) {
            case .success(let t):
                do {
                    return FetchResult(snapshot: try await fetchUsageEndpoint(token: t.accessToken), loginState: .connected)
                } catch UsageError.unauthorized {
                    // The token died early: renew it and go again.
                    ClaudeCodeLogin.clearCache()
                    if allowKeychain, case .success(let fresh) = await ClaudeCodeLogin.fromKeychain(forceRefresh: true),
                       let snap = try? await fetchUsageEndpoint(token: fresh.accessToken) {
                        return FetchResult(snapshot: snap, loginState: .connected)
                    }
                    loginState = .failed("Login expired · run `claude`, then /login")
                } catch UsageError.forbidden {
                    loginState = .noScope
                } catch UsageError.http(let code) {
                    loginState = .failed("usage endpoint answered HTTP \(code)")
                } catch UsageError.empty {
                    loginState = .failed("usage endpoint returned no windows")
                } catch {
                    loginState = .failed("usage endpoint unreachable · \((error as NSError).code)")
                }
            case .failure(let f):
                switch f {
                case .notFound: loginState = .notFound
                case .denied: loginState = .denied
                case .malformed: loginState = .failed("login item unreadable")
                case .noScope: loginState = .noScope
                case .expired: loginState = .failed("Login expired · run `claude`, then /login")
                case .refreshFailed(let why): loginState = .failed("Couldn't renew the login · \(why)")
                }
            }
        }

        let token = TokenStore.current()
        if let token, let snap = try? await ping(token: token) {
            return FetchResult(snapshot: snap, loginState: loginState)
        }

        if let local = LocalUsage.read() {
            let note = token == nil
                ? "Estimated from local logs · add a token in Settings for exact %"
                : "Estimated from local logs · exact ping unavailable"
            return FetchResult(
                snapshot: UsageSnapshot(buckets: local, source: .local, asOf: Date(), note: note, precise: false),
                loginState: loginState
            )
        }

        return FetchResult(
            snapshot: UsageSnapshot(
                buckets: [], source: .unavailable, asOf: Date(),
                note: token == nil ? "No token and no ~/.claude logs found" : "Couldn't reach Anthropic and no local logs found",
                precise: false
            ),
            loginState: loginState
        )
    }

    // MARK: - /api/oauth/usage

    private func fetchUsageEndpoint(token: String) async throws -> UsageSnapshot {
        var req = URLRequest(url: usage)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("claude-code/2.1.72", forHTTPHeaderField: "user-agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw UsageError.badResponse }
        if http.statusCode != 200 {
            let snippet = (String(data: data.prefix(200), encoding: .utf8) ?? "").replacingOccurrences(of: "\n", with: " ")
            ClaudeCodeLogin.lastDiagnostic += " · usage endpoint HTTP \(http.statusCode): \(snippet)"
        }
        switch http.statusCode {
        case 200: break
        case 401: throw UsageError.unauthorized
        case 403: throw UsageError.forbidden
        default: throw UsageError.http(http.statusCode)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            ClaudeCodeLogin.lastDiagnostic += " · usage endpoint body was not a JSON object"
            throw UsageError.badResponse
        }

        var buckets: [UsageBucket] = []

        // The `limits` array is the authoritative list: it names scoped windows
        // (kind weekly_scoped + scope.model.display_name "Fable") that the flat
        // top-level fields never mention.
        if let limits = obj["limits"] as? [[String: Any]] {
            for l in limits {
                guard let kind = l["kind"] as? String, let p = l["percent"] as? NSNumber else { continue }
                let reset = (l["resets_at"] as? String).flatMap(parseISO)
                let severity = l["severity"] as? String
                let binding = l["is_active"] as? Bool ?? false
                var bucket: UsageBucket
                switch kind {
                case "session":
                    bucket = UsageBucket(key: "five_hour", pct: clamp(p), resetAt: reset)
                case "weekly_all":
                    bucket = UsageBucket(key: "seven_day", pct: clamp(p), resetAt: reset)
                default:
                    let scope = l["scope"] as? [String: Any]
                    let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                    let surface = (scope?["surface"] as? [String: Any])?["display_name"] as? String
                    let name = model ?? surface ?? kind
                    let prefix = kind.hasPrefix("weekly") ? "seven_day_" : "five_hour_"
                    bucket = UsageBucket(key: prefix + Self.slug(name), pct: clamp(p), resetAt: reset)
                    bucket.label = name
                    bucket.detail = (kind.hasPrefix("weekly") ? "weekly" : "5-hour") + (model != nil ? " · model limit" : surface != nil ? " · surface limit" : "")
                }
                bucket.severity = severity
                bucket.binding = binding
                if !buckets.contains(where: { $0.key == bucket.key }) { buckets.append(bucket) }
            }
        }

        // Flat fields: five_hour / seven_day (if `limits` was missing) plus any codename
        // window Anthropic hasn't labelled yet.
        var rawKeys: [String: String] = [:]
        for (key, value) in obj {
            if value is NSNull { rawKeys[key] = "null"; continue }
            guard let d = value as? [String: Any] else { rawKeys[key] = "\(type(of: value))"; continue }
            guard let u = d["utilization"] as? NSNumber else { rawKeys[key] = "object"; continue }
            rawKeys[key] = "bucket"
            if buckets.contains(where: { $0.key == key }) { continue }
            var reset: Date?
            if let s = d["resets_at"] as? String { reset = parseISO(s) }
            else if let n = d["resets_at"] as? NSNumber { reset = Date(timeIntervalSince1970: n.doubleValue) }
            buckets.append(UsageBucket(key: key, pct: clamp(u), resetAt: reset))
        }
        guard !buckets.isEmpty else {
            ClaudeCodeLogin.lastDiagnostic += " · usage endpoint keys: \(obj.keys.sorted().joined(separator: ","))"
            throw UsageError.empty
        }
        buckets.sort { (BucketInfo.rank($0.key), $0.key) < (BucketInfo.rank($1.key), $1.key) }

        // Anthropic rounds to whole percents today; show a decimal only if one ever arrives.
        let precise = buckets.contains { $0.pct.rounded() != $0.pct }
        var snap = UsageSnapshot(buckets: buckets, source: .login, asOf: Date(), note: nil, precise: precise)
        snap.rawKeys = rawKeys

        if let bd = obj["seven_day_breakdown"] as? [String: Any], let rows = bd["rows"] as? [[String: Any]] {
            snap.breakdown = rows.compactMap { r in
                guard let n = r["display_name"] as? String, let p = r["percent"] as? NSNumber else { return nil }
                return BreakdownRow(name: n, percent: max(0, p.doubleValue))
            }.sorted { $0.percent > $1.percent }
        }

        var extras: [String: Any] = [:]
        for k in ["seven_day_breakdown", "limits", "extra_usage", "spend"] {
            if let v = obj[k], !(v is NSNull) { extras[k] = v }
        }
        if let data = try? JSONSerialization.data(withJSONObject: extras, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) { snap.rawExtrasJSON = s }
        return snap
    }

    private func clamp(_ n: NSNumber) -> Double { max(0, min(100, n.doubleValue)) }

    private static func slug(_ s: String) -> String {
        let lowered = s.lowercased()
        let mapped = lowered.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        return mapped.split(separator: "_").joined(separator: "_")
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private func parseISO(_ s: String) -> Date? { Self.isoFractional.date(from: s) ?? Self.iso.date(from: s) }

    // MARK: - Header ping

    private func ping(token: String) async throws -> UsageSnapshot {
        var req = URLRequest(url: messages)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("oauth-2025-04-20,claude-code-20250219", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": pingModel,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "."]],
        ])
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw UsageError.badResponse }

        // Every anthropic-ratelimit-unified-<segment>-utilization header becomes a bucket.
        var buckets: [UsageBucket] = []
        var precise = false
        for (rawKey, rawValue) in http.allHeaderFields {
            guard let name = (rawKey as? String)?.lowercased(),
                  name.hasPrefix("anthropic-ratelimit-unified-"), name.hasSuffix("-utilization"),
                  let valueString = rawValue as? String, let value = Double(valueString)
            else { continue }
            let segment = String(name.dropFirst("anthropic-ratelimit-unified-".count).dropLast("-utilization".count))
            let key = Self.bucketKey(for: segment)
            if let dot = valueString.firstIndex(of: "."), valueString.distance(from: dot, to: valueString.endIndex) > 3 { precise = true }
            let resetName = "anthropic-ratelimit-unified-\(segment)-reset"
            let reset = http.value(forHTTPHeaderField: resetName).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            buckets.append(UsageBucket(key: key, pct: max(0, min(100, value * 100)), resetAt: reset))
        }
        guard !buckets.isEmpty else { throw UsageError.noHeaders(http.statusCode) }
        buckets.sort { (BucketInfo.rank($0.key), $0.key) < (BucketInfo.rank($1.key), $1.key) }
        return UsageSnapshot(buckets: buckets, source: .ping, asOf: Date(), note: nil, precise: precise)
    }

    private static func bucketKey(for segment: String) -> String {
        switch segment {
        case "5h": return "five_hour"
        case "7d": return "seven_day"
        default:
            if segment.hasPrefix("7d-") { return "seven_day_" + segment.dropFirst(3).replacingOccurrences(of: "-", with: "_") }
            if segment.hasPrefix("5h-") { return "five_hour_" + segment.dropFirst(3).replacingOccurrences(of: "-", with: "_") }
            return segment.replacingOccurrences(of: "-", with: "_")
        }
    }
}
