import SwiftUI

struct ScrollTab: View {
    @EnvironmentObject var scroll: ScrollFlipEngine
    let openAccessibility: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Card(hoverable: false) {
                HStack(spacing: 12) {
                    Image(systemName: "computermouse")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(scroll.isFlipping ? Level.calm.color : Ink.dim)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.surface))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Reverse mouse wheel")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Ink.text)
                        Text("Trackpad stays natural. Only a wheel mouse gets flipped, so docking and undocking needs no toggling.")
                            .font(.system(size: 11))
                            .foregroundStyle(Ink.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $scroll.enabled)
                        .toggleStyle(.switch)
                        .tint(Level.calm.color)
                        .labelsHidden()
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 92)

            Card(hoverable: false) {
                HStack(spacing: 10) {
                    StatusDot(color: statusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Ink.text)
                        Text(statusDetail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Ink.faint)
                            .lineLimit(1)
                    }
                    Spacer()
                    if !scroll.axTrusted {
                        PillButton(title: "Open Settings", prominent: true, action: openAccessibility)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 62)
        }
        .padding(IslandMetrics.pad)
    }

    private var statusColor: Color {
        if !scroll.axTrusted { return Level.caution.color }
        return scroll.isFlipping ? Level.calm.color : Ink.faint
    }
    private var statusTitle: String {
        if !scroll.axTrusted { return "Accessibility permission needed" }
        return scroll.isFlipping ? "Active" : "Paused"
    }
    private var statusDetail: String {
        if !scroll.axTrusted { return "Privacy & Security → Accessibility → turn on Cockpit. It asks once, then it holds." }
        return scroll.isFlipping ? "Wheel events are being flipped · trackpad untouched" : "Wheel events pass through unchanged"
    }
}
