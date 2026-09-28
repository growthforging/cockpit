import SwiftUI

// The notch, widened into an island.
//
// Idle: one black bar exactly the menu bar's height spanning the notch plus a
// flank either side, bottom corners rounded to the display's own radius. Black on
// black, so it reads as one continuous piece of hardware with a readout tucked
// into each flank. When the front app's menus reach the left flank, that readout
// moves over to the right. Hover springs it down into a wide, shallow shelf; the
// band becomes the toolbar (tabs on the left, actions on the right) and the content
// hangs below. A click anywhere on the island pins it open; another click releases it.

enum IslandMetrics {
    static let shoulder: CGFloat = NotchShape().shoulder   // flare where the body meets the bezel
    // Wide enough for three usage cards in a row, so the panel grows sideways
    // rather than down. Every tab shares it, so switching tabs never jumps sideways.
    static let expandedWidth: CGFloat = 648
    static let expandedRadius: CGFloat = 24
    static let windowWidth: CGFloat = 720
    static let windowHeight: CGFloat = 460
    static let pad: CGFloat = 14
    static let cardHeight: CGFloat = 112
    static let noteHeight: CGFloat = 44
    static let clipColumns = 3
    static let clipRows = 2
    static let clipCardHeight: CGFloat = 88
    static var clipsGridHeight: CGFloat { CGFloat(clipRows) * clipCardHeight + CGFloat(clipRows - 1) * 8 }
    static let scrollCardHeight: CGFloat = 100

    // Session and week, then one card per model limit. Three fit in a row; four sit
    // two by two rather than leaving one alone on a second row.
    static func usageColumns(_ cards: Int) -> Int { cards == 4 ? 2 : min(max(cards, 1), 3) }
    static func usageRows(_ cards: Int) -> Int {
        let columns = usageColumns(cards)
        return (cards + columns - 1) / columns
    }

    static func contentHeight(tab: IslandTab, modelBuckets: Int, hasNote: Bool, hasHint: Bool) -> CGFloat {
        switch tab {
        case .usage:
            let rows = CGFloat(usageRows(2 + modelBuckets))
            return pad + rows * cardHeight + (rows - 1) * 10 + (hasNote ? noteHeight + 10 : 0) + (hasHint ? 22 + 10 : 0) + 10 + 22 + pad
        case .clips: return pad + 30 + 8 + clipsGridHeight + 8 + 20 + pad
        case .scroll: return pad + scrollCardHeight + pad
        }
    }
}

// Where the idle readouts sit. Split is the default, one each side of the camera. When
// the front app's menus reach the left one it joins the right one; with no room there
// either, only the reading closer to trouble stays. Menus too long for the left side
// continue right of the camera, and then nothing sits beside the notch at all.
enum IdleLayout: Equatable {
    case split, stacked, single, notchOnly

    var leftWidth: CGFloat { self == .split ? NotchReadout.flankWidth : 0 }
    var rightWidth: CGFloat {
        switch self {
        case .stacked: return 2 * NotchReadout.flankWidth
        case .notchOnly: return 0
        case .split, .single: return NotchReadout.flankWidth
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
    @Published var idleLayout: IdleLayout = .split

    var idleWidth: CGFloat { notchWidth + idleLayout.leftWidth + idleLayout.rightWidth }
    // How far right of the notch's centre the idle body's centre sits.
    var idleShift: CGFloat { (idleLayout.rightWidth - idleLayout.leftWidth) / 2 }
    func expandedHeight(modelBuckets: Int, hasNote: Bool, hasHint: Bool) -> CGFloat {
        notchHeight + IslandMetrics.contentHeight(tab: tab, modelBuckets: modelBuckets, hasNote: hasNote, hasHint: hasHint)
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
        let height = expanded ? island.expandedHeight(modelBuckets: usage.modelBuckets.count, hasNote: usage.showsNote, hasHint: usage.showsLoginHint) : island.notchHeight
        let radius = expanded ? IslandMetrics.expandedRadius : island.cornerRadius
        let shift = expanded ? 0 : island.idleShift
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
        .offset(x: shift)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: expanded)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: island.idleLayout)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: island.tab)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: usage.modelBuckets.count)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: usage.showsNote)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: usage.showsLoginHint)
        .preferredColorScheme(.dark)
    }

    // The strip either side of the notch: readouts when idle, toolbar when open.
    private var band: some View {
        ZStack {
            if island.expanded {
                HStack(spacing: 0) {
                    SegmentedTabs(tab: $island.tab)
                    Spacer(minLength: island.notchWidth)
                    actionButtons
                }
                .padding(.horizontal, IslandMetrics.pad)
                .transition(.opacity)
            } else if island.showFlanks {
                IdleReadouts(left: readout(.left), right: readout(.right), layout: island.idleLayout, notchWidth: island.notchWidth)
                    .transition(.opacity)
            }
        }
    }

    private func readout(_ side: UsageModel.Side) -> ReadoutModel? {
        usage.flankBucket(side).map { ReadoutModel(bucket: $0, pace: usage.pace(for: $0.key), precise: usage.precise) }
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

// The idle readouts laid out along the band. The right-hand reading keeps its place
// next to the camera in every layout, so only the one that had to move ever moves.
struct IdleReadouts: View {
    let left: ReadoutModel?
    let right: ReadoutModel?
    let layout: IdleLayout
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                if layout == .split, let left {
                    NotchReadout(model: left, side: .leading).transition(.opacity)
                }
            }
            .frame(width: layout.leftWidth)

            Color.clear.frame(width: notchWidth)

            // One slot for the camera-side reading in every layout, so switching layouts
            // never tears it down; only the second, stacked reading comes and goes.
            HStack(spacing: 0) {
                if layout != .notchOnly, let first = layout == .single ? Self.urgent(left, right) : right {
                    NotchReadout(model: first, side: .trailing)
                }
                if layout == .stacked, let left {
                    NotchReadout(model: left, side: .trailing).transition(.opacity)
                }
            }
            .frame(width: layout.rightWidth, alignment: .leading)
        }
    }

    // With room for one reading, show the one closer to trouble; on a tie, the right one.
    static func urgent(_ left: ReadoutModel?, _ right: ReadoutModel?) -> ReadoutModel? {
        guard let left else { return right }
        guard let right else { return left }
        return rank(left) > rank(right) ? left : right
    }

    private static func rank(_ m: ReadoutModel) -> Int {
        if m.synthesized { return -1 }
        if m.atLimit { return 3 }
        switch m.risk {
        case .calm: return 0
        case .caution: return 1
        case .critical: return 2
        }
    }
}
