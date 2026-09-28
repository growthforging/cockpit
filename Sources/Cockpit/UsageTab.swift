import SwiftUI

struct UsageTab: View {
    @EnvironmentObject var usage: UsageModel

    var body: some View {
        let buckets = [usage.snapshot.fiveHour, usage.snapshot.weekly] + usage.modelBuckets
        VStack(spacing: 10) {
            BucketGrid(entries: buckets.map { ($0, usage.pace(for: $0.key)) }, precise: usage.precise)

            if let note = usage.snapshot.note, !note.isEmpty {
                noteRow(note).frame(height: IslandMetrics.noteHeight)
            }
            if let hint = usage.loginHint {
                hintRow(hint).frame(height: 22)
            }
            footer.frame(height: 22)
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
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Level.caution.color.opacity(0.10)))
    }

    // A login problem gets a row of its own: it can be long, and it matters more than
    // anything else down here.
    private func hintRow(_ hint: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "key")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Ink.faint)
            Button(action: { usage.retryLogin() }) {
                Text(hint)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Ink.dim)
                    .underline(true, color: Ink.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("\(hint)\n\nPer-model windows come from the login Claude Code keeps in your Keychain. Run `claude` in a terminal and sign in, then click here to look again.")
            Spacer(minLength: 0)
        }
    }

    // Where the numbers came from on the left, what the idle notch shows on the right.
    private var footer: some View {
        HStack(spacing: 8) {
            SourcePill(source: usage.snapshot.source)
            TimelineView(.periodic(from: .now, by: 5)) { ctx in
                if usage.snapshot.asOf != .distantPast {
                    Text("updated \(fmtAgo(usage.snapshot.asOf, now: ctx.date)) ago")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Ink.faint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text("Notch")
                .font(.system(size: 10.5))
                .foregroundStyle(Ink.faint)
            FlankPicker(side: .left)
            FlankPicker(side: .right)
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
            FlankChip(side: side == .left ? "Left" : "Right", name: usage.flankChoiceName(side))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("What the \(side == .left ? "left" : "right") side of the notch shows while idle")
    }
}

// The face of a FlankPicker, on its own so the README picture draws the same chip.
struct FlankChip: View {
    let side: String
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Text(side)
                .foregroundStyle(Ink.faint)
            Text(name)
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
}

struct BucketCard: View {
    let bucket: UsageBucket
    let pace: Pace
    let precise: Bool

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    // Three cards to a row leave about 200pt each: the name and subtitle
                    // shrink a little before they would cut off, the number never does.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bucket.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Ink.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(bucket.subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Ink.faint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    Spacer(minLength: 6)
                    Text(bucket.synthesized ? "—" : fmtPct(bucket.pct, precise: precise))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .fixedSize()
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

// Every usage window as a card, side by side: session and week first, then each
// model limit, wrapped by IslandMetrics.usageColumns.
struct BucketGrid: View {
    let entries: [(bucket: UsageBucket, pace: Pace)]
    let precise: Bool

    var body: some View {
        let columns = IslandMetrics.usageColumns(entries.count)
        let rows = stride(from: 0, to: entries.count, by: columns).map { Array(entries[$0..<min($0 + columns, entries.count)]) }
        VStack(spacing: 10) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 10) {
                    ForEach(rows[r], id: \.bucket.key) { e in
                        BucketCard(bucket: e.bucket, pace: e.pace, precise: precise)
                    }
                }
                .frame(height: IslandMetrics.cardHeight)
            }
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
