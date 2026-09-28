import SwiftUI

// The notch, widened into an island.
//
// Idle: one black bar exactly the menu bar's height spanning the notch plus a
// flank either side, bottom corners rounded to the display's own radius. Black on
// black, so it reads as one continuous piece of hardware with a readout tucked
// into each flank. Hover springs it down into a shelf; the flanks become the
// toolbar (tabs on the left, actions on the right) and the content hangs below.
// A click anywhere on the island pins it open; another click releases it.

enum IslandMetrics {
    static let shoulder: CGFloat = NotchShape().shoulder   // flare where the body meets the bezel
    static let expandedWidth: CGFloat = 436
    static let expandedRadius: CGFloat = 24
    static let windowWidth: CGFloat = 480
    static let windowHeight: CGFloat = 460
    static let pad: CGFloat = 14
    static let clipsListHeight: CGFloat = 6 * 38 + 10
    static let cardHeight: CGFloat = 112
    static let modelRowHeight: CGFloat = 84
    static let noteHeight: CGFloat = 56

    static func contentHeight(tab: IslandTab, modelBuckets: Int, hasNote: Bool) -> CGFloat {
        switch tab {
        case .usage: return pad + cardHeight + CGFloat(modelBuckets) * (modelRowHeight + 10) + (hasNote ? noteHeight + 10 : 0) + 10 + 22 + 8 + 22 + pad
        case .clips: return pad + 30 + 8 + clipsListHeight + 8 + 20 + pad
        case .scroll: return pad + 92 + 10 + 62 + pad
        }
    }
}

@MainActor
final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false          // stays open until released (click or Esc)
    @Published var tab: IslandTab = .usage
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 32
    @Published var cornerRadius: CGFloat = 9
    @Published var showFlanks = true
    @Published var searchFocusRequest = 0

    var idleWidth: CGFloat { notchWidth + 2 * NotchReadout.flankWidth }
    func expandedHeight(modelBuckets: Int, hasNote: Bool) -> CGFloat {
        notchHeight + IslandMetrics.contentHeight(tab: tab, modelBuckets: modelBuckets, hasNote: hasNote)
    }
}

struct IslandActions {
    var refresh: () -> Void
    var settings: () -> Void
    var quit: () -> Void
    var close: () -> Void
    var copy: (ClipItem) -> Void
    var paste: (ClipItem) -> Void
    var togglePin: () -> Void
    var openAccessibility: () -> Void
}

struct IslandView: View {
    @ObservedObject var island: IslandState
    @EnvironmentObject var usage: UsageModel
    @EnvironmentObject var clips: ClipboardStore
    @EnvironmentObject var scroll: ScrollFlipEngine
    let actions: IslandActions

    var body: some View {
        let expanded = island.expanded
        let width = expanded ? IslandMetrics.expandedWidth : island.idleWidth
        let height = expanded ? island.expandedHeight(modelBuckets: usage.modelBuckets.count, hasNote: usage.showsNote) : island.notchHeight
        let radius = expanded ? IslandMetrics.expandedRadius : island.cornerRadius
        let s = IslandMetrics.shoulder
        // The fill carries the flared shoulders; the content is clipped to the body alone,
        // so nothing ever draws into the curve where the black meets the bezel.
        let outline = NotchShape(shoulder: s, bottom: radius)
        let bodyShape = NotchShape(shoulder: 0, bottom: radius)

        ZStack(alignment: .top) {
            outline
                .fill(Color.black)
                .frame(width: width + 2 * s, height: height)
                .shadow(color: .black.opacity(expanded ? 0.32 : 0), radius: 10, y: 5)
                .opacity(island.showFlanks || expanded ? 1 : 0)

            VStack(spacing: 0) {
                band.frame(width: width, height: island.notchHeight)
                if expanded {
                    content
                        .frame(width: width, alignment: .top)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .frame(width: width, height: height, alignment: .top)
            .clipShape(bodyShape)
        }
        .contentShape(outline)
        .onTapGesture { if island.expanded { actions.togglePin() } }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: expanded)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: island.tab)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: usage.modelBuckets.count)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: usage.showsNote)
        .preferredColorScheme(.dark)
    }

    // The strip either side of the notch: readouts when idle, toolbar when open.
    private var band: some View {
        HStack(spacing: 0) {
            ZStack {
                if island.expanded {
                    SegmentedTabs(tab: $island.tab).transition(.opacity)
                } else if island.showFlanks {
                    flank(.left).transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)

            Spacer().frame(width: island.notchWidth)

            ZStack {
                if island.expanded {
                    actionButtons.transition(.opacity)
                } else if island.showFlanks {
                    flank(.right).transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func flank(_ side: UsageModel.Side) -> some View {
        if let bucket = usage.flankBucket(side) {
            NotchReadout(
                model: ReadoutModel(bucket: bucket, pace: usage.pace(for: bucket.key), precise: usage.precise),
                side: side == .left ? .leading : .trailing
            )
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 2) {
            if island.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Ink.dim)
                    .frame(width: 18, height: 22)
                    .help("Pinned open. Click anywhere on the island to release it.")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            IconButton(systemName: "arrow.clockwise", help: "Refresh now", action: actions.refresh)
                .rotationEffect(.degrees(usage.isRefreshing ? 360 : 0))
                .animation(usage.isRefreshing ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: usage.isRefreshing)
            IconButton(systemName: "gearshape", help: "Settings", action: actions.settings)
            IconButton(systemName: "power", help: "Quit Cockpit", action: actions.quit)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: island.pinned)
    }

    @ViewBuilder
    private var content: some View {
        ZStack(alignment: .top) {
            switch island.tab {
            case .usage:
                UsageTab()
                    .transition(.opacity.combined(with: .offset(y: 4)))
            case .clips:
                ClipsTab(focusTrigger: island.searchFocusRequest, autoFocus: island.pinned, onCopy: actions.copy, onPaste: actions.paste, onClose: actions.close)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            case .scroll:
                ScrollTab(openAccessibility: actions.openAccessibility)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
    }
}
