import Foundation

// Usage only means something relative to the clock: 98% is fine two minutes before
// a reset and alarming four hours before one. This measures the recent burn rate
// per bucket and projects it against that bucket's reset time.

struct PacePoint { var t: Date; var pct: Double }

// One history sample: bucket key → [pct, resetEpoch].
struct PaceSample: Codable {
    var t: Double
    var b: [String: [Double]]
}

// MaxBar's history layout, converted on first load.
private struct LegacySample: Codable {
    var t: Double
    var fivePct: Int
    var fiveReset: Double
    var weeklyPct: Int
    var weeklyReset: Double
}

enum PaceVerdict {
    case measuring
    case blocked
    case dry(earlySeconds: Double, ratePerHour: Double)
    case safe(finishPct: Double, unusedPct: Double, ratePerHour: Double)

    var summary: String {
        switch self {
        case .measuring: return "measuring pace…"
        case .blocked: return "limit reached · waiting for the reset"
        case .dry(let early, _): return "on pace to run dry \(fmtDuration(early)) before reset"
        case .safe(let finish, let unused, _):
            if unused <= 3 { return "on pace to finish right at the line (\(Int(finish))%)" }
            return "on pace to finish at \(Int(finish))% · \(Int(unused))% unused"
        }
    }

    // One line that fits a card.
    var compact: String {
        switch self {
        case .measuring: return "measuring pace…"
        case .blocked: return "limit reached"
        case .dry(let early, _): return "runs dry \(fmtDuration(early)) early"
        case .safe(let finish, let unused, let rate):
            if finish < 0.5, rate <= 0.01 { return "nothing used yet" }
            if unused <= 3 { return "finishes right at the line" }
            return "finishes ~\(Int(finish.rounded()))% · \(Int(unused.rounded()))% unused"
        }
    }

    var short: String {
        switch self {
        case .measuring: return "measuring"
        case .blocked: return "limit reached"
        case .dry(let early, _): return "dry \(fmtDuration(early)) early"
        case .safe(_, let unused, _): return unused <= 3 ? "right at the line" : "\(Int(unused))% spare"
        }
    }
}

struct Pace {
    var verdict: PaceVerdict
    var risk: Level
    var expectedPct: Double   // where an even pace would put you right now
    static let unknown = Pace(verdict: .measuring, risk: .calm, expectedPct: 0)
}

enum PaceEngine {
    private static let historyMaxAge: TimeInterval = 48 * 3600

    static func compute(now: Date, pct: Double, resetAt: Date?, windowLength: TimeInterval, series: [PacePoint]) -> Pace {
        let lookback: TimeInterval = windowLength <= 6 * 3600 ? 45 * 60 : 24 * 3600
        let minSpan: TimeInterval = windowLength <= 6 * 3600 ? 8 * 60 : 3 * 3600

        var timeLeft: TimeInterval = 0
        var expected = 0.0
        if let resetAt {
            timeLeft = max(0, resetAt.timeIntervalSince(now))
            let elapsed = max(0, min(windowLength, windowLength - timeLeft))
            expected = elapsed / windowLength * 100
        }

        if pct >= 100 { return Pace(verdict: .blocked, risk: .critical, expectedPct: expected) }
        guard resetAt != nil, timeLeft > 0 else {
            return Pace(verdict: .measuring, risk: measuringRisk(pct), expectedPct: expected)
        }

        // Burn rate: the recent window when there's enough history, otherwise the
        // window's own average pace so far (fresh install, or a source that just came
        // back) once enough of the window has elapsed for that average to mean something.
        let recent = series.filter { now.timeIntervalSince($0.t) <= lookback }
        let rate: Double
        if let first = recent.first, let last = recent.last, last.t.timeIntervalSince(first.t) >= minSpan {
            rate = max(0, (last.pct - first.pct) / (last.t.timeIntervalSince(first.t) / 3600))
        } else {
            let elapsed = windowLength - timeLeft
            guard elapsed >= windowLength * 0.15 else {
                return Pace(verdict: .measuring, risk: measuringRisk(pct), expectedPct: expected)
            }
            rate = pct / (elapsed / 3600)
        }
        let timeLeftHours = timeLeft / 3600

        if rate <= 0.01 {
            return Pace(verdict: .safe(finishPct: pct, unusedPct: max(0, 100 - pct), ratePerHour: 0), risk: .calm, expectedPct: expected)
        }
        let hoursToEmpty = (100 - pct) / rate
        if hoursToEmpty < timeLeftHours {
            let early = (timeLeftHours - hoursToEmpty) * 3600
            let risk: Level = early > windowLength * 0.15 ? .critical : .caution
            return Pace(verdict: .dry(earlySeconds: early, ratePerHour: rate), risk: risk, expectedPct: expected)
        }
        let finish = min(100, pct + rate * timeLeftHours)
        return Pace(verdict: .safe(finishPct: finish, unusedPct: max(0, 100 - finish), ratePerHour: rate), risk: .calm, expectedPct: expected)
    }

    private static func measuringRisk(_ pct: Double) -> Level {
        if pct >= 95 { return .critical }
        if pct >= 80 { return .caution }
        return .calm
    }

    // MARK: - History

    static func loadHistory() -> [PaceSample] {
        guard let data = try? Data(contentsOf: CockpitPaths.history) else { return [] }
        if let samples = try? JSONDecoder().decode([PaceSample].self, from: data) { return samples }
        if let legacy = try? JSONDecoder().decode([LegacySample].self, from: data) {
            return legacy.map {
                PaceSample(t: $0.t, b: [
                    "five_hour": [Double($0.fivePct), $0.fiveReset],
                    "seven_day": [Double($0.weeklyPct), $0.weeklyReset],
                ])
            }
        }
        return []
    }

    static func record(_ snapshot: UsageSnapshot, now: Date = Date()) -> [PaceSample] {
        var samples = loadHistory()
        var b: [String: [Double]] = [:]
        for bucket in snapshot.buckets {
            b[bucket.key] = [bucket.pct, bucket.resetAt?.timeIntervalSince1970 ?? 0]
        }
        samples.append(PaceSample(t: now.timeIntervalSince1970, b: b))
        let cutoff = now.timeIntervalSince1970 - historyMaxAge
        samples = samples.filter { $0.t >= cutoff }
        CockpitPaths.ensure()
        if let data = try? JSONEncoder().encode(samples) { try? data.write(to: CockpitPaths.history) }
        return samples
    }

    // Only samples from the *current* window count — a reset restarts the series.
    static func series(from samples: [PaceSample], key: String, resetAt: Date?) -> [PacePoint] {
        guard let resetAt else { return [] }
        let target = resetAt.timeIntervalSince1970
        return samples.compactMap { s -> PacePoint? in
            guard let v = s.b[key], v.count == 2, abs(v[1] - target) < 60 else { return nil }
            return PacePoint(t: Date(timeIntervalSince1970: s.t), pct: v[0])
        }.sorted { $0.t < $1.t }
    }
}
