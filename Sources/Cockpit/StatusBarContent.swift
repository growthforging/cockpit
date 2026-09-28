import SwiftUI

// The menu-bar chip, for screens without a notch. It carries the same readouts the notch
// flanks do and draws them the same way: a white number, a short bar that stays white
// while things are fine and only takes colour when they are not. Each is labelled,
// because a monitor's menu bar has room and nothing there says which is which.
struct StatusBarContent: View {
    let entries: [ReadoutModel]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(entries.enumerated()), id: \.offset) { idx, e in
                if idx > 0 {
                    Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 11)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if entries.count > 1 {
                        Text(e.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    ReadoutNumber(model: e, size: 12)
                    ReadoutBar(model: e, width: 18, height: 4)
                        .alignmentGuide(.firstTextBaseline) { d in d.height / 2 + 4.2 }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(
            ZStack {
                Capsule(style: .continuous).fill(Color.black.opacity(0.74))
                Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
            }
        )
        .padding(.vertical, 1)
    }
}
