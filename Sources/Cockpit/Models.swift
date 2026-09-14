import SwiftUI

// Where the numbers came from this refresh.
enum UsageSource: String {
    case login       // Claude Code login → /api/oauth/usage: every bucket, 0.1% precision
    case ping        // pasted token → rate-limit headers on a 1-token ping: 5h + 7d only
    case local       // estimated from ~/.claude logs
    case unavailable

    var label: String {
        switch self {
        case .login: return "live · Claude Code login"
        case .ping: return "live · token ping"
        case .local: return "local estimate"
        case .unavailable: return "no data"
        }
    }
    var isLive: Bool { self == .login || self == .ping }
}

// One usage window. Keys follow Anthropic's own names: five_hour, seven_day,
// seven_day_fable, seven_day_opus… whatever the account exposes shows up.
struct UsageBucket: Identifiable, Equatable {
    var key: String
    var pct: Double          // 0…100
    var resetAt: Date?
    var label: String? = nil      // set when the API names the window itself (e.g. "Fable")
    var detail: String? = nil
    var severity: String? = nil   // Anthropic's own read: normal / warning / critical
    var binding = false           // the window currently constraining you

    var id: String { key }
    var title: String { label ?? BucketInfo.title(for: key) }
    var subtitle: String { detail ?? BucketInfo.subtitle(for: key) }
    var windowLength: TimeInterval { key.hasPrefix("five_hour") ? 5 * 3600 : 7 * 24 * 3600 }
    var isModelSpecific: Bool { BucketInfo.isModelSpecific(key) }
}

// The weekly window split by surface (Claude Code, Chats, Cowork, Other), in percent of the week's usage.
struct BreakdownRow: Identifiable, Equatable {
    var name: String
    var percent: Double
    var id: String { name }
}

enum BucketInfo {
    private static let known: [String: (String, String)] = [
        "five_hour": ("Session", "5-hour window"),
        "seven_day": ("Week", "all models"),
        "seven_day_fable": ("Fable", "weekly"),
        "seven_day_mythos": ("Mythos", "weekly"),
        "seven_day_opus": ("Opus", "weekly"),
        "seven_day_sonnet": ("Sonnet", "weekly"),
        "seven_day_oauth_apps": ("OAuth apps", "weekly"),
        "seven_day_cowork": ("Cowork", "weekly"),
    ]
    private static let order = [
        "five_hour", "seven_day", "seven_day_fable", "seven_day_mythos", "seven_day_opus",
        "seven_day_sonnet", "seven_day_cowork", "seven_day_oauth_apps",
    ]

    static func title(for key: String) -> String {
        if let k = known[key] { return k.0 }
        return key
            .replacingOccurrences(of: "seven_day_", with: "")
            .replacingOccurrences(of: "five_hour_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
    static func subtitle(for key: String) -> String {
        if let k = known[key] { return k.1 }
        return "unlabeled window · \(key)"
    }
    static func isKnown(_ key: String) -> Bool { known[key] != nil }
    static func isModelSpecific(_ key: String) -> Bool { key != "five_hour" && key != "seven_day" }
    static func rank(_ key: String) -> Int { order.firstIndex(of: key) ?? 100 }
}

struct UsageSnapshot {
    var buckets: [UsageBucket]
    var source: UsageSource
    var asOf: Date
    var note: String?
    var precise: Bool        // the source carries sub-percent precision
    var rawKeys: [String: String] = [:]   // every top-level key the usage endpoint returned → kind
    var rawExtrasJSON: String = ""        // seven_day_breakdown / limits / extra_usage / spend, verbatim
    var breakdown: [BreakdownRow] = []

    func bucket(_ key: String) -> UsageBucket? { buckets.first { $0.key == key } }
    var fiveHour: UsageBucket { bucket("five_hour") ?? UsageBucket(key: "five_hour", pct: 0, resetAt: nil) }
    var weekly: UsageBucket { bucket("seven_day") ?? UsageBucket(key: "seven_day", pct: 0, resetAt: nil) }
    var fable: UsageBucket? { buckets.first { $0.key.contains("fable") || $0.key.contains("mythos") } }

    static let placeholder = UsageSnapshot(buckets: [], source: .unavailable, asOf: .distantPast, note: "Loading…", precise: false)
}

// Where the always-visible gauge lives.
enum DisplayMode: String, CaseIterable, Identifiable {
    case menuBar, notch, both
    var id: String { rawValue }
    var showsMenuBar: Bool { self != .notch }
    var showsNotch: Bool { self != .menuBar }
}

// Threshold → colour. The colour encodes risk (pace vs reset), not the raw number.
enum Level {
    case calm, caution, critical

    static func from(_ pct: Double) -> Level {
        if pct >= 90 { return .critical }
        if pct >= 50 { return .caution }
        return .calm
    }

    var color: Color {
        switch self {
        case .calm:     return Color(red: 0.30, green: 0.87, blue: 0.62)
        case .caution:  return Color(red: 0.99, green: 0.75, blue: 0.25)
        case .critical: return Color(red: 0.99, green: 0.44, blue: 0.41)
        }
    }
}

func fmtPct(_ pct: Double, precise: Bool) -> String {
    precise ? String(format: "%.1f%%", pct) : String(format: "%.0f%%", pct)
}

// "resets at 6:39 PM" (today) / "resets tomorrow 9:00 AM" / "resets Sun 11:00 AM".
func fmtReset(_ date: Date?) -> String? {
    guard let date else { return nil }
    if date.timeIntervalSinceNow <= 0 { return "resetting…" }
    let cal = Calendar.current
    let now = Date()
    let tf = DateFormatter()
    tf.locale = .current
    tf.setLocalizedDateFormatFromTemplate("jmm")
    let time = tf.string(from: date)
    if cal.isDate(date, inSameDayAs: now) { return "resets at \(time)" }
    if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
        return "resets tomorrow \(time)"
    }
    let df = DateFormatter()
    df.locale = .current
    df.setLocalizedDateFormatFromTemplate("EEE")
    return "resets \(df.string(from: date)) \(time)"
}

func fmtDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let d = total / 86400
    let h = (total % 86400) / 3600
    let m = (total % 3600) / 60
    if d > 0 { return h > 0 ? "~\(d)d \(h)h" : "~\(d)d" }
    if h > 0 { return "~\(h)h \(m)m" }
    return "~\(m)m"
}

func fmtAgo(_ date: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(date))
    if s < 5 { return "now" }
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}
