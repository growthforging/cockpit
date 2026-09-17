import SwiftUI

struct UsageTab: View {
    @EnvironmentObject var usage: UsageModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                BucketCard(bucket: usage.snapshot.fiveHour, pace: usage.pace(for: "five_hour"), precise: usage.precise)
                BucketCard(bucket: usage.snapshot.weekly, pace: usage.pace(for: "seven_day"), precise: usage.precise)
            }
            .frame(height: IslandMetrics.cardHeight)

            ForEach(usage.modelBuckets) { b in
                ModelRow(bucket: b, pace: usage.pace(for: b.key), precise: usage.precise)
                    .frame(height: IslandMetrics.modelRowHeight)
            }

            if let note = usage.snapshot.note, !note.isEmpty {
                noteRow(note).frame(height: IslandMetrics.noteHeight)
            }
            sourceRow.frame(height: 22)
            notchRow.frame(height: 22)
        }
        .padding(IslandMetrics.pad)
    }

    // Shown whenever the numbers are an estimate rather than a reading.
    private func noteRow(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Level.caution.color.opacity(0.9))
            Text(note)
                .font(.system(size: 10.5))
                .foregroundStyle(Ink.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Level.caution.color.opacity(0.10)))
    }

    private var sourceRow: some View {
        HStack(spacing: 8) {
            SourcePill(source: usage.snapshot.source)
            TimelineView(.periodic(from: .now, by: 5)) { ctx in
                if usage.snapshot.asOf != .distantPast {
                    Text("updated \(fmtAgo(usage.snapshot.asOf, now: ctx.date)) ago")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Ink.faint)
                }
            }
            Spacer()
            if let hint = loginHint {
                Button(action: { usage.retryLogin() }) {
                    Text(hint)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Ink.dim)
                        .underline(true, color: Ink.faint)
                }
                .buttonStyle(.plain)
                .help("Per-model windows come from the login Claude Code keeps in your Keychain. Run `claude` in a terminal and sign in, then click here to look again.")
            }
        }
    }

    // What the two idle readouts either side of the notch show.
    private var notchRow: some View {
        HStack(spacing: 8) {
            Text("Notch")
                .font(.system(size: 10.5))
                .foregroundStyle(Ink.faint)
            FlankPicker(side: .left)
            FlankPicker(side: .right)
            Spacer()
        }
    }

    // Shown until the Claude Code login is feeding per-model numbers.
    private var loginHint: String? {
        guard usage.useClaudeCodeLogin else { return "Connect Claude Code login" }
        switch usage.loginState {
        case .connected: return nil
        case .off: return "Connect Claude Code login"
        case .denied: return "Keychain declined · ask again"
        case .notFound: return "No Claude Code login · re-check"
        case .noScope: return "Login lacks the usage scope"
        case .failed(let why): return why
        }
    }
}

struct FlankPicker: View {
    let side: UsageModel.Side
    @EnvironmentObject var usage: UsageModel

    private var current: String { side == .left ? usage.leftFlankKey : usage.rightFlankKey }

    var body: some View {
        Menu {
            ForEach(usage.flankChoices, id: \.0) { choice in
                Button {
                    usage.setFlank(side, key: choice.0)
                } label: {
                    if current == choice.0 {
                        Label(choice.1, systemImage: "checkmark")
                    } else {
                        Text(choice.1)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(side == .left ? "Left" : "Right")
                    .foregroundStyle(Ink.faint)
                Text(usage.flankChoiceName(side))
                    .foregroundStyle(Ink.text)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Ink.faint)
            }
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Ink.surface))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("What the \(side == .left ? "left" : "right") side of the notch shows while idle")
    }
}

struct BucketCard: View {
    let bucket: UsageBucket
    let pace: Pace
    let precise: Bool

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bucket.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Ink.text)
                        Text(bucket.subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Ink.faint)
                    }
                    Spacer()
                    Text(bucket.synthesized ? "—" : fmtPct(bucket.pct, precise: precise))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(bucket.synthesized ? Ink.faint : pace.risk.color)
                        .contentTransition(.numericText(value: bucket.pct))
                        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: bucket.pct)
                }
                Spacer(minLength: 4)
                PaceBar(pct: bucket.synthesized ? 0 : bucket.pct, pace: pace, height: 8)
                Spacer(minLength: 4)
                if bucket.synthesized {
                    Text("no usage data yet")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Ink.faint)
                } else {
                    VerdictLine(pace: pace)
                }
                Text(fmtReset(bucket.resetAt)?.replacingOccurrences(of: "resets ", with: "↻ ") ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Ink.faint)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
            .padding(12)
        }
    }
}

struct ModelRow: View {
    let bucket: UsageBucket
    let pace: Pace
    let precise: Bool

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bucket.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Ink.text)
                        Text(bucket.subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Ink.faint)
                    }
                    Spacer()
                    Text(fmtPct(bucket.pct, precise: precise))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(pace.risk.color)
                        .contentTransition(.numericText(value: bucket.pct))
                        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: bucket.pct)
                }
                PaceBar(pct: bucket.pct, pace: pace, height: 6)
                HStack(spacing: 6) {
                    VerdictLine(pace: pace)
                    if let reset = fmtReset(bucket.resetAt) {
                        Text("· " + reset.replacingOccurrences(of: "resets ", with: "↻ "))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Ink.faint)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

// The prediction in words, coloured only when it's a warning.
struct VerdictLine: View {
    let pace: Pace

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
            Text(pace.verdict.compact)
                .lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(color)
    }

    private var icon: String {
        switch pace.verdict {
        case .measuring: return "hourglass"
        case .blocked: return "xmark.octagon.fill"
        case .dry: return "exclamationmark.triangle.fill"
        case .safe: return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch pace.verdict {
        case .measuring: return Ink.faint
        case .safe: return Ink.dim
        case .dry, .blocked: return pace.risk.color
        }
    }
}
