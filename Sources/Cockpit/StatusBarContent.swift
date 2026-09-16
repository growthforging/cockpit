import SwiftUI

struct StatusBarEntry: Identifiable {
    var id: String
    var label: String
    var pct: Double
    var level: Level
    var expectedPct: Double
}

// The menu-bar chip, for screens without a notch. A monitor's menu bar has room, so it
// carries the same readouts the notch flanks do, each labelled, in one dark capsule.
struct StatusBarContent: View {
    let entries: [StatusBarEntry]
    let precise: Bool

    private let trackWidth: CGFloat = 26
    private let barHeight: CGFloat = 7

    var body: some View {
        HStack(spacing: 9) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { idx, e in
                if idx > 0 {
                    Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 12)
                }
                HStack(spacing: 5) {
                    if entries.count > 1 {
                        Text(e.label)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.66))
                    }
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.3)).frame(width: trackWidth, height: barHeight)
                        Capsule().fill(e.level.color).frame(width: max(3, trackWidth * CGFloat(min(100, e.pct)) / 100), height: barHeight)
                        if e.expectedPct > 2, e.expectedPct < 99 {
                            Rectangle().fill(Color.white.opacity(0.9)).frame(width: 1.5, height: barHeight + 3)
                                .offset(x: trackWidth * CGFloat(e.expectedPct) / 100 - 0.75)
                        }
                    }
                    .frame(width: trackWidth, height: barHeight)
                    Text(fmtPct(e.pct, precise: precise))
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(e.level.color)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            ZStack {
                Capsule(style: .continuous).fill(Color.black.opacity(0.34))
                Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.6)
            }
        )
        .padding(.vertical, 1)
    }
}
