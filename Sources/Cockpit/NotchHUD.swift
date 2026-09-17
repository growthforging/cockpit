import SwiftUI
import AppKit

struct NotchGeometry {
    var screen: NSScreen
    var notchWidth: CGFloat
    var notchHeight: CGFloat

    static func detect() -> NotchGeometry? {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else { return nil }
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        let width = screen.frame.width - left - right
        guard width > 40, width < screen.frame.width else { return nil }
        return NotchGeometry(screen: screen, notchWidth: width, notchHeight: screen.safeAreaInsets.top)
    }

    static func describe() -> String {
        var out = "screens: \(NSScreen.screens.count)\n"
        for (i, s) in NSScreen.screens.enumerated() {
            out += "  [\(i)] frame=\(s.frame) safeTop=\(s.safeAreaInsets.top)"
            out += " auxL=\(s.auxiliaryTopLeftArea?.width ?? -1) auxR=\(s.auxiliaryTopRightArea?.width ?? -1)\n"
        }
        if let g = detect() {
            out += "notch: width=\(g.notchWidth) height=\(g.notchHeight)\n"
            out += "idle bar: width=\(g.notchWidth + 2 * IslandMetrics.flankWidth) height=\(g.notchHeight)\n"
            out += "island: width=\(IslandMetrics.expandedWidth) window=\(IslandMetrics.windowWidth)x\(IslandMetrics.windowHeight)"
        } else {
            out += "no notch detected (menu-bar mode only)"
        }
        return out
    }
}

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// The panel is larger than the island so the spring has room; clicks outside the
// black shape fall through to whatever is underneath, and the first click on a
// non-key panel still lands (otherwise the buttons feel dead).
final class IslandHostingView: NSHostingView<AnyView> {
    var hitRect: (() -> NSRect?)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let r = hitRect?(), !r.contains(point) { return nil }
        return super.hitTest(point)
    }
}

@MainActor
final class NotchHUD {
    let island = IslandState()
    var onRefresh: () -> Void = {}
    var onSettings: () -> Void = {}

    private let usage: UsageModel
    private let clips: ClipboardStore
    private let scroll: ScrollFlipEngine

    private var panel: NotchPanel?
    private var hosting: IslandHostingView?
    private var geo: NotchGeometry?
    private var pollTimer: Timer?
    private var outsideSince: Date?
    private var insideSince: Date?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var lastMouse = NSPoint(x: -1, y: -1)
    private var clickMonitors: [Any] = []
    private var previousApp: NSRunningApplication?
    private var keyboardMode = false        // opened by the hotkey: key window, closes on outside click

    private let collapseGrace: TimeInterval = 0.16
    private let expandDwell: TimeInterval = 0.12   // ignore a cursor merely sweeping past

    init(usage: UsageModel, clips: ClipboardStore, scroll: ScrollFlipEngine) {
        self.usage = usage
        self.clips = clips
        self.scroll = scroll
    }

    var isAvailable: Bool { NotchGeometry.detect() != nil }
    var isOpen: Bool { island.expanded }

    // MARK: - Lifecycle

    func show() {
        guard let g = NotchGeometry.detect() else { return }
        geo = g
        island.notchWidth = g.notchWidth
        island.notchHeight = g.notchHeight
        applyPrefs()

        if panel == nil {
            let p = NotchPanel()
            let actions = IslandActions(
                refresh: { [weak self] in self?.onRefresh() },
                settings: { [weak self] in self?.close(); self?.onSettings() },
                quit: { NSApp.terminate(nil) },
                close: { [weak self] in self?.close() },
                copy: { [weak self] item in self?.clips.copy(item) },
                paste: { [weak self] item in self?.paste(item) },
                togglePin: { [weak self] in self?.togglePinByClick() },
                openAccessibility: { [weak self] in
                    self?.close()
                    self?.scroll.requestPermission(prompt: true)   // registers Cockpit in the list
                    SettingsOpener.openAccessibility()
                }
            )
            let root = AnyView(
                IslandView(island: island, actions: actions)
                    .environmentObject(usage)
                    .environmentObject(clips)
                    .environmentObject(scroll)
            )
            let h = IslandHostingView(rootView: root)
            h.hitRect = { [weak self] in self?.hitRectInWindow() }
            p.contentView = h
            p.ignoresMouseEvents = true
            panel = p
            hosting = h
            p.orderFrontRegardless()

            let center = NotificationCenter.default
            observers.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reposition() }
            }))
            // A workspace token cannot be unregistered through the default centre, so each
            // observer is stored beside the centre that owns it.
            let workspace = NSWorkspace.shared.notificationCenter
            observers.append((workspace, workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.panel?.orderFrontRegardless() }
            }))
            startTracking()
        }
        position()
    }

    func hide() {
        pollTimer?.invalidate()
        pollTimer = nil
        removeClickMonitors()
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        island.expanded = false
        island.pinned = false
        keyboardMode = false
        lastMouse = NSPoint(x: -1, y: -1)
    }

    func applyPrefs() {
        island.showFlanks = usage.notchFlanks
        island.cornerRadius = CGFloat(usage.notchCornerRadius)
    }

    private func position() {
        guard let panel, let geo else { return }
        let f = geo.screen.frame
        panel.setFrame(NSRect(
            x: f.midX - IslandMetrics.windowWidth / 2,
            y: f.maxY - IslandMetrics.windowHeight,
            width: IslandMetrics.windowWidth,
            height: IslandMetrics.windowHeight
        ), display: true)
        panel.orderFrontRegardless()
    }

    private func reposition() {
        guard let g = NotchGeometry.detect() else { hide(); return }
        geo = g
        island.notchWidth = g.notchWidth
        island.notchHeight = g.notchHeight
        position()
    }

    // MARK: - Geometry

    private func currentSize() -> CGSize {
        if island.expanded {
            return CGSize(width: IslandMetrics.expandedWidth, height: island.expandedHeight(modelBuckets: usage.modelBuckets.count, hasNote: usage.showsNote))
        }
        return CGSize(width: island.idleWidth, height: island.notchHeight)
    }

    private func shapeScreenRect() -> NSRect {
        guard let geo else { return .zero }
        let f = geo.screen.frame
        let s = currentSize()
        return NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)
    }

    private func hitRectInWindow() -> NSRect? {
        guard let panel else { return nil }
        let s = currentSize()
        let f = panel.frame
        return NSRect(x: (f.width - s.width) / 2, y: f.height - s.height, width: s.width, height: s.height)
    }

    private var mouseIsOverIsland: Bool {
        shapeScreenRect().insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
    }

    // MARK: - Hover

    private func startTracking() {
        pollTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 0.02
        pollTimer = t
    }

    private func tick() {
        guard !island.pinned, let geo else { return }
        let mouse = NSEvent.mouseLocation
        // With the cursor parked away from the notch, which is nearly always, there is
        // nothing to recompute.
        if !island.expanded, insideSince == nil, mouse == lastMouse { return }
        lastMouse = mouse
        let f = geo.screen.frame
        let idleWidth = island.idleWidth
        let trigger = NSRect(x: f.midX - idleWidth / 2, y: f.maxY - geo.notchHeight - 2, width: idleWidth, height: geo.notchHeight + 2)

        if island.expanded {
            if mouseIsOverIsland {
                outsideSince = nil
            } else if let since = outsideSince {
                if Date().timeIntervalSince(since) >= collapseGrace { setExpanded(false) }
            } else {
                outsideSince = Date()
            }
            return
        }

        if trigger.contains(mouse) {
            if let since = insideSince {
                if Date().timeIntervalSince(since) >= expandDwell {
                    setExpanded(true)
                    Task { await usage.refreshIfStale() }
                }
            } else {
                insideSince = Date()
            }
        } else {
            insideSince = nil
        }
    }

    private func setExpanded(_ value: Bool) {
        island.expanded = value
        insideSince = nil
        outsideSince = nil
        // The cached position went stale while the island was open; without this a cursor
        // that never moves can never re-arm the hover.
        lastMouse = NSPoint(x: -1, y: -1)
        panel?.ignoresMouseEvents = !value
        if value { panel?.orderFrontRegardless() }
    }

    // MARK: - Pinning

    // Click on the island: pin it open. Click again: release it (it collapses once
    // the cursor leaves, or right away if it already has).
    func togglePinByClick() {
        if island.pinned {
            release()
            if !mouseIsOverIsland { setExpanded(false) }
        } else {
            island.pinned = true
        }
    }

    // ⇧⌘V: pinned, key (so typing filters), closes on Esc, ↩ paste or a click outside.
    func togglePinned(tab: IslandTab) {
        if island.pinned { close() } else { openPinned(tab: tab) }
    }

    func openPinned(tab: IslandTab) {
        guard let panel else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        island.tab = tab
        island.pinned = true
        keyboardMode = true
        setExpanded(true)
        panel.makeKeyAndOrderFront(nil)
        island.searchFocusRequest += 1
        installClickMonitors()
        Task { await usage.refreshIfStale() }
    }

    func close() {
        release()
        setExpanded(false)
    }

    private func release() {
        removeClickMonitors()
        island.pinned = false
        if keyboardMode {
            keyboardMode = false
            panel?.resignKey()
            _ = previousApp?.activate()
            previousApp = nil
        }
    }

    private func paste(_ item: ClipItem) {
        clips.copy(item)
        let wasKeyboard = keyboardMode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            self?.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + (wasKeyboard ? 0.16 : 0.06)) {
                ClipboardStore.sendPaste()
            }
        }
    }

    private func installClickMonitors() {
        removeClickMonitors()
        let handler: (NSEvent) -> Void = { [weak self] _ in
            guard let self, self.keyboardMode else { return }
            if !self.shapeScreenRect().insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) { self.close() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) { clickMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) { clickMonitors.append(l) }
    }

    private func removeClickMonitors() {
        clickMonitors.forEach { NSEvent.removeMonitor($0) }
        clickMonitors.removeAll()
    }
}
