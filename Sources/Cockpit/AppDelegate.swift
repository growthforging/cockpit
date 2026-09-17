import SwiftUI
import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let usage = UsageModel()
    let clips = ClipboardStore()
    let scroll = ScrollFlipEngine()

    private var hud: NotchHUD?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let popoverState = PopoverState()
    private let hotkey = HotkeyCenter()
    private var cancellables = Set<AnyCancellable>()
    private var lastClose = Date.distantPast
    private var popoverPreviousApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--notchinfo") {
            print(NotchGeometry.describe())
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--shot") {
            let path = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "docs/cockpit.png"
            exit(Shot.render(to: path) ? 0 : 1)
        }

        // One copy only: a second would double the pings and the gauges.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.growthforging.cockpit"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        CockpitPaths.repairPermissions()
        LaunchAtLogin.repairIfMoved()
        NSApp.setActivationPolicy(.accessory)
        SettingsWindowController.shared.configure(usage: usage, clips: clips, scroll: scroll)

        let hud = NotchHUD(usage: usage, clips: clips, scroll: scroll)
        hud.onRefresh = { [weak self] in Task { await self?.usage.refresh(force: true) } }
        hud.onSettings = { SettingsWindowController.shared.show() }
        self.hud = hud

        let actions = IslandActions(
            refresh: { [weak self] in Task { await self?.usage.refresh(force: true) } },
            settings: { [weak self] in self?.popover.performClose(nil); SettingsWindowController.shared.show() },
            quit: { NSApp.terminate(nil) },
            close: { [weak self] in self?.popover.performClose(nil) },
            copy: { [weak self] item in self?.clips.copy(item) },
            paste: { [weak self] item in self?.pasteFromPopover(item) },
            togglePin: {},
            openAccessibility: { [weak self] in
                self?.popover.performClose(nil)
                self?.scroll.requestPermission(prompt: true)
                SettingsOpener.openAccessibility()
            }
        )
        let hosting = NSHostingController(
            rootView: PopoverView(state: popoverState, actions: actions)
                .environmentObject(usage)
                .environmentObject(clips)
                .environmentObject(scroll)
        )
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self
        popover.appearance = NSAppearance(named: .darkAqua)

        usage.onDisplayModeChange = { [weak self] in self?.applyDisplayMode() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyDisplayMode() }
        }
        usage.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.renderStatusItem() } }
            .store(in: &cancellables)
        clips.$hotkeyEnabled
            .sink { [weak self] on in DispatchQueue.main.async { self?.setHotkey(on) } }
            .store(in: &cancellables)
        HotkeyCenter.action = { [weak self] in self?.toggleClips() }

        applyDisplayMode()
        renderStatusItem()
        usage.start()
        clips.start()
        scroll.start()
    }

    // MARK: - Presentation

    // The island only exists on the built-in display. With no notch, or more than
    // one screen, the menu-bar chip comes back so there's always a readout.
    private var notchCoversEverything: Bool {
        hud?.isAvailable == true && NSScreen.screens.count == 1
    }

    private func applyDisplayMode() {
        let mode = usage.displayMode
        let wantsMenuBar = mode.showsMenuBar || !notchCoversEverything
        let wantsNotch = mode.showsNotch && hud?.isAvailable == true

        if wantsMenuBar, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            statusItem = item
        } else if !wantsMenuBar, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }

        if wantsNotch { hud?.show() } else { hud?.hide() }
        renderStatusItem()
        Diagnostics.write([
            "displayMode": mode.rawValue,
            "screens": NSScreen.screens.count,
            "notchAvailable": hud?.isAvailable == true,
            "statusItemActive": statusItem != nil,
            "notchShown": wantsNotch,
            "accessibility": scroll.axTrusted,
        ])
    }

    private func renderStatusItem() {
        guard statusItem != nil else { return }
        var buckets: [UsageBucket] = []
        switch usage.menuBarMode {
        case .flanks:
            for side in [UsageModel.Side.left, .right] {
                if let b = usage.flankBucket(side), !buckets.contains(where: { $0.key == b.key }) { buckets.append(b) }
            }
        case .all:
            buckets = [usage.snapshot.fiveHour, usage.snapshot.weekly] + usage.modelBuckets
        }
        if buckets.isEmpty { buckets = [usage.snapshot.fiveHour] }
        let entries = buckets.map { b -> StatusBarEntry in
            let pace = usage.pace(for: b.key)
            return StatusBarEntry(id: b.key, label: b.title, pct: b.pct, level: pace.risk, expectedPct: pace.expectedPct, synthesized: b.synthesized)
        }
        let renderer = ImageRenderer(content: StatusBarContent(entries: entries, precise: usage.precise))
        renderer.scale = max(2, NSScreen.main?.backingScaleFactor ?? 2)
        if let image = renderer.nsImage {
            image.isTemplate = false
            statusItem?.button?.image = image
            statusItem?.button?.imagePosition = .imageOnly
        }
    }

    // MARK: - Hotkey → clipboard history

    private func setHotkey(_ on: Bool) {
        on ? hotkey.register() : hotkey.unregister()
        clips.hotkeyUnavailable = on && hotkey.lastStatus != noErr
    }

    private func toggleClips() {
        if let hud, hud.isAvailable, usage.displayMode.showsNotch {
            hud.togglePinned(tab: .clips)
            return
        }
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        popoverState.tab = .clips
        popoverState.focusTrigger += 1
        showPopover(from: button)
    }

    // MARK: - Popover (menu-bar chip)

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        if Date().timeIntervalSince(lastClose) < 0.2 { return }
        showPopover(from: button)
    }

    private func showPopover(from button: NSStatusBarButton) {
        popoverPreviousApp = NSWorkspace.shared.frontmostApplication
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        Task { await usage.refreshIfStale() }
    }

    private func pasteFromPopover(_ item: ClipItem) {
        clips.copy(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            self?.popover.performClose(nil)
            _ = self?.popoverPreviousApp?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { ClipboardStore.sendPaste() }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        lastClose = Date()
    }
}
