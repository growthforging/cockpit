import AppKit
import CryptoKit
import Foundation

// Cockpit's own Claude sign-in: the browser flow `claude /login` runs (same authorize
// page, same public client, PKCE, a one-shot listener on 127.0.0.1), ending in a login
// that belongs to Cockpit alone.
//
// Borrowing the CLI's login is what kept breaking. Each renewal rotates the refresh
// token, so whichever of the two renewed last left the other holding a dead one, and when
// the CLI signs out its Keychain item vanishes with it. A grant of Cockpit's own renews
// on its own and never touches the CLI's.
enum ClaudeSignIn {
    private static let authorizeURL = URL(string: "https://claude.com/cai/oauth/authorize")!   // Claude Code's CLAUDE_AI_AUTHORIZE_URL
    // The usage endpoint needs user:profile; nothing else here is used.
    private static let scopes = ["user:profile", "user:inference"]

    enum Failure: Error, Equatable {
        case cancelled
        case timedOut
        case refused(String)      // the authorize page answered with an error
        case exchange(String)     // the code came back but the token endpoint said no
        case listener             // no loopback port to receive the callback on

        var message: String {
            switch self {
            case .cancelled: return "cancelled"
            case .timedOut: return "Sign-in timed out"
            case .refused(let why): return why == "access_denied" ? "Sign-in was declined" : "Sign-in failed · \(why)"
            case .exchange(let why): return "Sign-in failed · \(why)"
            case .listener: return "Couldn't open a local port for the sign-in"
            }
        }
    }

    static func run(timeout: TimeInterval = 300) async -> Result<Void, Failure> {
        guard let server = LoopbackServer() else { return .failure(.listener) }
        defer { server.close() }

        let verifier = randomURLSafe(32)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafe(32)
        let redirect = "http://localhost:\(server.port)/callback"

        var parts = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: ClaudeCodeLogin.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = parts.url else { return .failure(.listener) }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }

        let deadline = Date().addingTimeInterval(timeout)
        let callback: LoopbackServer.Callback
        switch await withTaskCancellationHandler(
            operation: { await server.waitForCallback(state: state, until: deadline) },
            onCancel: { server.cancel() }
        ) {
        case .success(let c): callback = c
        case .failure(let f): return .failure(f)
        }

        // The browser tab stays open on the request until the exchange is done, so the
        // page it lands on tells the truth about whether the sign-in worked.
        switch await exchange(code: callback.code, verifier: verifier, state: state, redirect: redirect) {
        case .success(let pair):
            ClaudeCodeLogin.adopt(pair.0, refreshToken: pair.1)
            callback.respond(page: "Cockpit is signed in", detail: "You can close this tab.")
            return .success(())
        case .failure(let f):
            callback.respond(page: "Cockpit could not sign in", detail: f.message + ". Close this tab and try again from Cockpit.")
            return .failure(f)
        }
    }

    private static func exchange(code: String, verifier: String, state: String, redirect: String) async -> Result<(ClaudeCodeToken, String), Failure> {
        var req = URLRequest(url: ClaudeCodeLogin.tokenURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect,
            "client_id": ClaudeCodeLogin.clientID,
            "code_verifier": verifier,
            "state": state,
        ])
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard status == 200,
                  let access = obj?["access_token"] as? String, !access.isEmpty,
                  let refresh = obj?["refresh_token"] as? String, !refresh.isEmpty
            else {
                let why = ClaudeCodeLogin.errorText(obj, status: status)
                ClaudeCodeLogin.note(" · sign-in exchange refused: \(why)")
                return .failure(.exchange(why))
            }
            let expiresIn = (obj?["expires_in"] as? NSNumber)?.doubleValue ?? 3600
            let granted = (obj?["scope"] as? String).map { $0.split(separator: " ").map(String.init) } ?? scopes
            let token = ClaudeCodeToken(accessToken: access, expiresAt: Date().addingTimeInterval(expiresIn), scopes: granted, subscription: nil)
            return .success((token, refresh))
        } catch {
            return .failure(.exchange("offline"))
        }
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &raw)
        return base64URL(Data(raw))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// A single-purpose HTTP listener bound to 127.0.0.1 only, so the firewall never asks and
// nothing off this Mac can reach it. It answers one /callback carrying the right state;
// anything else gets a 404 and the wait goes on.
private final class LoopbackServer: @unchecked Sendable {
    let port: UInt16
    private var fd: Int32
    private let lock = NSLock()
    private var cancelled = false

    struct Callback {
        let code: String
        let connection: Int32

        func respond(page title: String, detail: String) {
            LoopbackServer.send(connection, status: "200 OK", html: LoopbackServer.page(title, detail))
            Darwin.close(connection)
        }
    }

    init?() {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        guard bound == 0, named == 0, listen(s, 8) == 0 else {
            Darwin.close(s)
            return nil
        }
        fd = s
        port = UInt16(bigEndian: actual.sin_port)
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    // Blocking accept loop, run off the cooperative pool. It wakes every quarter second
    // to notice a cancel or the deadline.
    func waitForCallback(state: String, until deadline: Date) async -> Result<Callback, ClaudeSignIn.Failure> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.acceptLoop(state: state, until: deadline))
            }
        }
    }

    private func acceptLoop(state: String, until deadline: Date) -> Result<Callback, ClaudeSignIn.Failure> {
        let listener = fd
        while true {
            if isCancelled { return .failure(.cancelled) }
            if Date() >= deadline { return .failure(.timedOut) }
            var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 250) > 0 else { continue }
            let conn = accept(listener, nil, nil)
            guard conn >= 0 else { continue }

            var noSigPipe: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            // Browsers open spare connections they may never send on; don't let one stall the
            // real callback queued behind it.
            var wait = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

            guard let target = Self.readRequestTarget(conn),
                  let parts = URLComponents(string: "http://localhost" + target),
                  parts.path == "/callback"
            else {
                Self.send(conn, status: "404 Not Found", html: Self.page("Not found", ""))
                Darwin.close(conn)
                continue
            }
            let query = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            // A callback without this run's state is someone else's request, or a stale tab.
            guard query["state"] == state else {
                Self.send(conn, status: "400 Bad Request", html: Self.page("This sign-in link is out of date", "Start the sign-in again from Cockpit."))
                Darwin.close(conn)
                continue
            }
            if let error = query["error"], !error.isEmpty {
                Self.send(conn, status: "200 OK", html: Self.page("Cockpit did not sign in", "You can close this tab."))
                Darwin.close(conn)
                return .failure(.refused(error))
            }
            guard let code = query["code"], !code.isEmpty else {
                Self.send(conn, status: "400 Bad Request", html: Self.page("The sign-in came back without a code", "Start the sign-in again from Cockpit."))
                Darwin.close(conn)
                continue
            }
            return .success(Callback(code: code, connection: conn))
        }
    }

    // "GET /callback?code=…&state=… HTTP/1.1" → "/callback?code=…&state=…"
    private static func readRequestTarget(_ conn: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var used = 0
        while used < buffer.count {
            let n = buffer.withUnsafeMutableBytes { read(conn, $0.baseAddress! + used, $0.count - used) }
            guard n > 0 else { break }
            used += n
            if let text = String(bytes: buffer[0..<used], encoding: .utf8), text.contains("\r\n") { break }
        }
        guard let text = String(bytes: buffer[0..<used], encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first
        else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET" else { return nil }
        return String(fields[1])
    }

    fileprivate static func send(_ conn: Int32, status: String, html: String) {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        let bytes = Data(head.utf8) + body
        bytes.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(conn, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    fileprivate static func page(_ title: String, _ detail: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>Cockpit</title>
        <style>body{margin:0;height:100vh;display:grid;place-items:center;background:#000;color:rgba(255,255,255,.94);font:15px -apple-system,BlinkMacSystemFont,sans-serif}
        h1{font-size:20px;font-weight:600;margin:0 0 6px}p{margin:0;color:rgba(255,255,255,.58)}div{text-align:center}</style></head>
        <body><div><h1>\(escape(title))</h1><p>\(escape(detail))</p></div></body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
