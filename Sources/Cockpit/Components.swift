import SwiftUI

// The island is black hardware; everything on it is white at a handful of opacities.
enum Ink {
    static let surface = Color.white.opacity(0.06)
    static let surfaceHover = Color.white.opacity(0.10)
    static let surfaceActive = Color.white.opacity(0.15)
    static let border = Color.white.opacity(0.09)
    static let borderStrong = Color.white.opacity(0.20)
    static let text = Color.white.opacity(0.94)
    static let dim = Color.white.opacity(0.58)
    static let faint = Color.white.opacity(0.38)
}

// The gauge. Solid fill is where you are; the faint extension is where the current
// pace lands you by the reset; the tick is where an even pace would put you right
// now. Fill behind the tick is slack, fill past it means you're burning too fast.
struct PaceBar: View {
    let pct: Double
    let pace: Pace
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let w: CGFloat = geo.size.width
            let fillW: CGFloat = max(height, w * CGFloat(min(100, pct)) / 100)
            let ghostW: CGFloat = ghostWidth(w)
            let tickX: CGFloat = w * CGFloat(pace.expectedPct) / 100 - 1
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.13))
                if pct > 0 { Capsule().fill(pace.risk.color.opacity(0.24)).frame(width: ghostW) }
                if pct > 0 {
                    Capsule()
                        .fill(pace.risk.color)
                        .frame(width: fillW)
                        .shadow(color: pace.risk.color.opacity(0.45), radius: 3)
                }
                if pace.expectedPct > 1.5, pace.expectedPct < 98.5 {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 2, height: height + 6)
                        .offset(x: tickX)
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .animation(.spring(response: 0.6, dampingFraction: 0.85), value: pct)
        }
        .frame(height: height + 6)
        .help("Solid: where you are. Faint: where this pace lands you by the reset. Tick: an even pace. Fill past the tick means you're burning faster than the window allows.")
    }

    private func ghostWidth(_ w: CGFloat) -> CGFloat {
        switch pace.verdict {
        case .safe(let finish, _, _): return finish > pct ? w * CGFloat(min(100, finish)) / 100 : 0
        case .dry, .blocked: return w
        case .measuring: return 0
        }
    }
}

struct Card<Content: View>: View {
    var hoverable = true
    var radius: CGFloat = 14
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(hover && hoverable ? Ink.surfaceHover : Ink.surface))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Ink.border, lineWidth: 0.5))
            .scaleEffect(hover && hoverable ? 1.01 : 1)
            .animation(.easeOut(duration: 0.18), value: hover)
            .onHover { hover = $0 }
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    var size: CGFloat = 12
    var tint: Color? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint ?? (hover ? Ink.text : Ink.dim))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? Ink.surfaceActive : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
        .help(help)
    }
}

struct PillButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Ink.text)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(Capsule().fill(prominent ? Color.white.opacity(hover ? 1 : 0.9) : Color.white.opacity(hover ? 0.17 : 0.10)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color.opacity(0.7), radius: 3)
    }
}

struct SourcePill: View {
    let source: UsageSource
    var body: some View {
        HStack(spacing: 5) {
            StatusDot(color: source.isLive ? Level.calm.color : (source == .local ? Level.caution.color : Ink.faint))
            Text(source.label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Ink.dim)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(Ink.surface))
    }
}

enum IslandTab: String, CaseIterable, Identifiable {
    case usage, clips, scroll
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .usage: return "gauge.with.needle"
        case .clips: return "doc.on.clipboard"
        case .scroll: return "computermouse"
        }
    }
    var title: String {
        switch self {
        case .usage: return "Usage"
        case .clips: return "Clipboard history  ⇧⌘V"
        case .scroll: return "Mouse wheel"
        }
    }
}

struct SegmentedTabs: View {
    @Binding var tab: IslandTab
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(IslandTab.allCases) { t in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { tab = t }
                } label: {
                    Image(systemName: t.icon)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(tab == t ? Ink.text : Ink.dim)
                        .frame(width: 30, height: 20)
                        .background {
                            if tab == t {
                                Capsule().fill(Color.white.opacity(0.16)).matchedGeometryEffect(id: "tab", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(t.title)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }
}
