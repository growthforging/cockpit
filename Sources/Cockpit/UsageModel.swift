import SwiftUI
import Combine

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot.placeholder
    @Published private(set) var paces: [String: Pace] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasToken = TokenStore.hasToken
    @Published private(set) var loginState: LoginState = .off

    @Published var refreshSeconds: Int { didSet { save(); scheduleTimer() } }
    @Published var notificationsEnabled: Bool { didSet { save() } }
    @Published var displayMode: DisplayMode { didSet { save(); onDisplayModeChange?() } }
    @Published var notchFlanks: Bool { didSet { save(); onDisplayModeChange?() } }
    @Published var notchCornerRadius: Double { didSet { save(); onDisplayModeChange?() } }
    @Published var leftFlankKey: String { didSet { save() } }     // "auto" = Fable if present, else Week
    @Published var rightFlankKey: String { didSet { save() } }    // "auto" = Session
    @Published var useClaudeCodeLogin: Bool {
        didSet {
            save()
            if useClaudeCodeLogin { loginDeclined = false }
            Task { await refresh(force: true) }
        }
    }
    @Published var loginDeclined: Bool { didSet { save() } }
    @Published var showUnlabeledBuckets: Bool { didSet { save() } }

    var onDisplayModeChange: (() -> Void)?

    private let service = UsageService()
    private let notifier = Notifier()
    private var timer: Timer?
    private var notified: Set<String> = []
    private var wakeObserver: NSObjectProtocol?

    init() {
        let d = UserDefaults.standard
        func int(_ key: String, _ fallback: Int) -> Int { (d.object(forKey: key) ?? LegacyPrefs.object(key)) as? Int ?? fallback }
        func bool(_ key: String, _ fallback: Bool) -> Bool { (d.object(forKey: key) ?? LegacyPrefs.object(key)) as? Bool ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double { (d.object(forKey: key) ?? LegacyPrefs.object(key)) as? Double ?? fallback }

        refreshSeconds = max(15, int("refreshSeconds", 60))
        notificationsEnabled = bool("notificationsEnabled", true)
        notchFlanks = bool("notchFlanks", true)
        notchCornerRadius = double("notchCornerRadius", 9)
        displayMode = DisplayMode(rawValue: d.string(forKey: "displayMode") ?? "") ?? .notch
        leftFlankKey = d.string(forKey: "leftFlankKey") ?? "auto"
        rightFlankKey = d.string(forKey: "rightFlankKey") ?? "auto"
        useClaudeCodeLogin = (d.object(forKey: "useClaudeCodeLogin") as? Bool) ?? true
        loginDeclined = d.bool(forKey: "loginDeclined")
        showUnlabeledBuckets = d.bool(forKey: "showUnlabeledBuckets")
    }

    func start() {
        notifier.requestAuthorization()
        scheduleTimer()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    // MARK: - Reading the snapshot

    var precise: Bool { snapshot.precise }
    // Anthropic's endpoint also returns windows under internal codenames (e.g. an
    // unreleased limit). Those stay hidden while they read 0%, unless asked for.
    var modelBuckets: [UsageBucket] {
        snapshot.buckets.filter { b in
            b.isModelSpecific && (BucketInfo.isKnown(b.key) || b.label != nil || showUnlabeledBuckets || b.pct > 0)
        }
    }
    var hiddenBucketCount: Int { snapshot.buckets.filter { $0.isModelSpecific }.count - modelBuckets.count }
    func pace(for key: String) -> Pace { paces[key] ?? .unknown }

    enum Side { case left, right }

    // nil = that side of the notch stays empty.
    func flankBucket(_ side: Side) -> UsageBucket? {
        let pref = side == .left ? leftFlankKey : rightFlankKey
        if pref == "none" { return nil }
        if pref != "auto", let b = snapshot.bucket(pref) { return b }
        return side == .left ? (snapshot.fable ?? snapshot.weekly) : snapshot.fiveHour
    }

    func setFlank(_ side: Side, key: String) {
        if side == .left { leftFlankKey = key } else { rightFlankKey = key }
    }

    func flankChoiceName(_ side: Side) -> String {
        let key = side == .left ? leftFlankKey : rightFlankKey
        if key == "auto" { return "Auto · " + (flankBucket(side)?.title ?? "—") }
        return flankChoices.first { $0.0 == key }?.1 ?? key
    }

    // Choices offered in Settings for each flank.
    var flankChoices: [(String, String)] {
        var out = [("auto", "Automatic")]
        for b in snapshot.buckets { out.append((b.key, b.title + (b.isModelSpecific ? " · weekly" : ""))) }
        for key in ["five_hour", "seven_day"] where !snapshot.buckets.contains(where: { $0.key == key }) {
            out.append((key, BucketInfo.title(for: key)))
        }
        out.append(("none", "Nothing"))
        return out
    }

    // MARK: - Refresh

    func refresh(force: Bool = false) async {
        if isRefreshing && !force { return }
        isRefreshing = true
        let r = await service.fetch(useLogin: useClaudeCodeLogin && !loginDeclined, allowKeychain: true)
        snapshot = r.snapshot
        if case .denied = r.loginState { loginDeclined = true }
        loginState = (useClaudeCodeLogin && loginDeclined) ? .denied : r.loginState
        hasToken = TokenStore.hasToken
        isRefreshing = false
        updatePace(r.snapshot)
        Diagnostics.writeUsage(r, loginDeclined: loginDeclined)
    }

    func refreshIfStale(maxAge: TimeInterval = 20) async {
        if Date().timeIntervalSince(snapshot.asOf) > maxAge { await refresh() }
    }

    func retryLogin() {
        loginDeclined = false
        useClaudeCodeLogin = true
    }

    func setToken(_ token: String) {
        TokenStore.save(token)
        hasToken = TokenStore.hasToken
        Task { await refresh(force: true) }
    }

    func clearToken() {
        TokenStore.clear()
        hasToken = TokenStore.hasToken
        Task { await refresh(force: true) }
    }

    // MARK: - Pace + alerts

    private func updatePace(_ snap: UsageSnapshot) {
        let now = Date()
        let samples = PaceEngine.record(snap, now: now)
        var next: [String: Pace] = [:]
        for b in snap.buckets {
            let series = PaceEngine.series(from: samples, key: b.key, resetAt: b.resetAt)
            var p = PaceEngine.compute(now: now, pct: b.pct, resetAt: b.resetAt, windowLength: b.windowLength, series: series)
            // Anthropic's own severity never lowers the pace verdict, only raises it.
            switch (b.severity ?? "").lowercased() {
            case "critical", "exceeded", "blocked": p.risk = .critical
            case "warning", "elevated", "high": if p.risk == .calm { p.risk = .caution }
            default: break
            }
            next[b.key] = p
        }
        paces = next
        for b in snap.buckets { notifyIfNeeded(bucket: b, pace: next[b.key] ?? .unknown) }
    }

    // Alerts fire on projected run-out, not arbitrary percentages, once per window.
    private func notifyIfNeeded(bucket: UsageBucket, pace: Pace) {
        guard notificationsEnabled else { return }
        let resetKey = bucket.resetAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        let name = bucket.title
        switch pace.verdict {
        case .blocked:
            let tail = fmtReset(bucket.resetAt).map { " · \($0)" } ?? ""
            fireOnce("\(bucket.key)-\(resetKey)-blocked", "\(name) limit reached\(tail)")
        case .dry(let early, _):
            guard pace.risk == .critical else { return }
            fireOnce("\(bucket.key)-\(resetKey)-dry", "\(name): at this pace you'll run dry \(fmtDuration(early)) before reset")
        case .safe, .measuring:
            break
        }
    }

    private func fireOnce(_ key: String, _ body: String) {
        guard !notified.contains(key) else { return }
        if notified.count > 200 { notified.removeAll() }
        notified.insert(key)
        notifier.fire(title: "Claude usage", body: body)
    }

    // MARK: - Prefs / timer

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(15, refreshSeconds))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(refreshSeconds, forKey: "refreshSeconds")
        d.set(notificationsEnabled, forKey: "notificationsEnabled")
        d.set(displayMode.rawValue, forKey: "displayMode")
        d.set(notchFlanks, forKey: "notchFlanks")
        d.set(notchCornerRadius, forKey: "notchCornerRadius")
        d.set(leftFlankKey, forKey: "leftFlankKey")
        d.set(rightFlankKey, forKey: "rightFlankKey")
        d.set(useClaudeCodeLogin, forKey: "useClaudeCodeLogin")
        d.set(loginDeclined, forKey: "loginDeclined")
        d.set(showUnlabeledBuckets, forKey: "showUnlabeledBuckets")
    }
}
