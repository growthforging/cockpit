import SwiftUI

struct ScrollTab: View {
    @EnvironmentObject var scroll: ScrollFlipEngine
    let openAccessibility: () -> Void

    var body: some View {
        HStack(spacing: 10) {
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
                        Text("Trackpad stays natural. Only a wheel mouse gets flipped, so docking needs no toggling.")
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

            Card(hoverable: false) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    StatusDot(color: statusColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Ink.text)
                        Text(statusDetail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Ink.faint)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        if !scroll.axTrusted {
                            PillButton(title: "Open Settings", prominent: true, action: openAccessibility)
                                .padding(.top, 3)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(height: IslandMetrics.scrollCardHeight)
        .padding(IslandMetrics.pad)
    }

    private var statusColor: Color {
        if !scroll.axTrusted { return Level.caution.color }
        return scroll.isFlipping ? Level.calm.color : Ink.faint
    }
    private var statusTitle: String {
        if !scroll.axTrusted { return "Permission needed" }
        return scroll.isFlipping ? "Active" : "Paused"
    }
    private var statusDetail: String {
        if !scroll.axTrusted { return "Privacy & Security → \(SettingsOpener.accessibilityName) → Cockpit. It also moves the notch numbers off long menus." }
        return scroll.isFlipping ? "Wheel events are being flipped · trackpad untouched" : "Wheel events pass through unchanged"
    }
}
