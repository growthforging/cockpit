import SwiftUI

@MainActor
final class PopoverState: ObservableObject {
    @Published var tab: IslandTab = .usage
    @Published var focusTrigger = 0
}

// Same content as the island, for the menu-bar chip (external displays, no notch).
struct PopoverView: View {
    @ObservedObject var state: PopoverState
    @EnvironmentObject var usage: UsageModel
    @EnvironmentObject var clips: ClipboardStore
    @EnvironmentObject var scroll: ScrollFlipEngine
    let actions: IslandActions

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SegmentedTabs(tab: $state.tab)
                Spacer()
                IconButton(systemName: "arrow.clockwise", help: "Refresh now", action: actions.refresh)
                IconButton(systemName: "gearshape", help: "Settings", action: actions.settings)
                IconButton(systemName: "power", help: "Quit Cockpit", action: actions.quit)
            }
            .padding(.horizontal, IslandMetrics.pad)
            .padding(.top, 12)

            ZStack(alignment: .top) {
                switch state.tab {
                case .usage:
                    UsageTab()
                case .clips:
                    ClipsTab(focusTrigger: state.focusTrigger, autoFocus: true, onCopy: actions.copy, onPaste: actions.paste, onClose: actions.close)
                case .scroll:
                    ScrollTab(openAccessibility: actions.openAccessibility)
                }
            }
        }
        .frame(width: 400)
        .background(Color.black.opacity(0.94))
        .preferredColorScheme(.dark)
    }
}
