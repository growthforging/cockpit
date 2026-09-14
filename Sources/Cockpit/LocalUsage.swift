import Foundation

// Token-free fallback: scan ~/.claude/projects/**/*.jsonl, sum cache tokens from
// assistant turns (Opus/Fable/Mythos weighted 5x), divide by calibrated budgets.
enum LocalUsage {
    private static let fiveHourBudget: Double = 1_086_000_000
    private static let weeklyBudget: Double = 7_910_000_000

    private struct Entry { var ts: Date; var raw: Double; var weight: Double }

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

    static func read() -> [UsageBucket]? {
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }

        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let needle = Data("assistant".utf8)
        var dedup: [String: Entry] = [:]

        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                if let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, mod < weekAgo { continue }
                parse(file, weekAgo: weekAgo, needle: needle, into: &dedup)
            }
        }

        var five = 0.0, week = 0.0
        for e in dedup.values {
            if e.ts >= weekAgo { week += e.raw * e.weight }
            if e.ts >= fiveHoursAgo { five += e.raw * e.weight }
        }
        return [
            UsageBucket(key: "five_hour", pct: pct(five, fiveHourBudget), resetAt: nil),
            UsageBucket(key: "seven_day", pct: pct(week, weeklyBudget), resetAt: nil),
        ]
    }

    private static func pct(_ used: Double, _ budget: Double) -> Double {
        max(0, min(100, (used / budget * 1000).rounded() / 10))
    }

    private static func parse(_ url: URL, weekAgo: Date, needle: Data, into dedup: inout [String: Entry]) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        var buffer = Data()
        let newline = UInt8(0x0A)
        while let chunk = try? fh.read(upToCount: 1 << 20), !chunk.isEmpty {
            buffer.append(chunk)
            while let idx = buffer.firstIndex(of: newline) {
                let line = Data(buffer[buffer.startIndex..<idx])
                buffer = Data(buffer[buffer.index(after: idx)...])
                handle(line, weekAgo: weekAgo, needle: needle, into: &dedup)
            }
        }
        if !buffer.isEmpty { handle(buffer, weekAgo: weekAgo, needle: needle, into: &dedup) }
    }

    private static func handle(_ line: Data, weekAgo: Date, needle: Data, into dedup: inout [String: Entry]) {
        guard line.count > 20, line.range(of: needle) != nil else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let tsString = obj["timestamp"] as? String,
              let ts = isoFractional.date(from: tsString) ?? iso.date(from: tsString),
              ts >= weekAgo,
              let message = obj["message"] as? [String: Any],
              let id = message["id"] as? String
        else { return }
        let usage = message["usage"] as? [String: Any]
        let raw = ((usage?["cache_read_input_tokens"] as? NSNumber)?.doubleValue ?? 0)
            + ((usage?["cache_creation_input_tokens"] as? NSNumber)?.doubleValue ?? 0)
        if raw == 0 { return }
        let model = (message["model"] as? String ?? "").lowercased()
        let weight = (model.contains("opus") || model.contains("fable") || model.contains("mythos")) ? 5.0 : 1.0
        if let existing = dedup[id], existing.raw >= raw { return }
        dedup[id] = Entry(ts: ts, raw: raw, weight: weight)
    }
}
