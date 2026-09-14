import SwiftUI

// The menu-bar chip, for screens without a notch: a mini pace bar + the number.
struct StatusBarContent: View {
    let pct: Double
    let level: Level
    let expectedPct: Double
    let precise: Bool

    private let trackWidth: CGFloat = 24
    private let barHeight: CGFloat = 7

    var body: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.32)).frame(width: trackWidth, height: barHeight)
                Capsule().fill(level.color).frame(width: max(3, trackWidth * CGFloat(min(100, pct)) / 100), height: barHeight)
                if expectedPct > 2, expectedPct < 99 {
                    Rectangle().fill(Color.white.opacity(0.85)).frame(width: 1.5, height: barHeight + 3)
                        .offset(x: trackWidth * CGFloat(expectedPct) / 100 - 0.75)
                }
            }
            .frame(width: trackWidth, height: barHeight)
            Text(fmtPct(pct, precise: precise))
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(level.color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            ZStack {
                Capsule(style: .continuous).fill(Color.black.opacity(0.28))
                Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.6)
            }
        )
        .padding(.vertical, 1)
    }
}
