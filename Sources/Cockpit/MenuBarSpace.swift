import AppKit
import ApplicationServices

// How much of the menu bar the front app's menus and the menu-bar icons take up, read
// through Accessibility. The idle island uses it to stay off them: on a 14-inch display
// Chrome's nine menus run under the left readout, while Finder's six stop well short.
//
// Every value is a distance from a screen edge rather than a coordinate, because the
// active menu bar can be on another display and each display lays out the same menus.
@MainActor
final class MenuBarSpace {
    struct Reading: Equatable {
        var menusEnd: CGFloat?      // right end of the front app's last menu, from the screen's left edge
        var iconsStart: CGFloat?    // left end of the leftmost menu-bar icon, from the screen's right edge
    }

    var onChange: (Reading) -> Void = { _ in }
    private(set) var reading = Reading()

    private let queue = DispatchQueue(label: "cockpit.menubar-space", qos: .utility)
    private var timer: Timer?
    private var tokens: [NSObjectProtocol] = []
    private var iconsCheckedAt = Date.distantPast
    private var running = false
    private var appsObservation: NSKeyValueObservation?
    private var menusPid: pid_t?     // whose menus `reading.menusEnd` describes
    private var iconEdges: [pid_t: CGFloat] = [:]   // each app's last answer, for apps with icons
    private var iconGeneration = 0   // bumped by each launch or quit, so a burst runs one schedule
    private var iconScanQueued = false

    func start() {
        guard !running else { return }
        running = true
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkSoon() }
        })
        // Icons come and go with the apps that own them, and an app puts its icon up a
        // moment after it launches, so every pass after a launch reads them again. The
        // launch notifications skip menu-bar-only apps, which own most icons, so this
        // watches the list of running apps itself. Background helpers cannot show icons.
        appsObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { [weak self] _, change in
            let changed = (change.newValue ?? []) + (change.oldValue ?? [])
            guard changed.contains(where: { $0.activationPolicy != .prohibited }) else { return }
            Task { @MainActor in self?.checkSoon(forceIcons: true) }
        }
        // An app can change its menus without changing focus, as Chrome does while it
        // finishes launching.
        let t = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        t.tolerance = 1
        timer = t
        checkSoon(forceIcons: true)
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens.removeAll()
        appsObservation?.invalidate()
        appsObservation = nil
    }

    // An app's menus settle a moment after it comes forward, so look again shortly after.
    private func checkSoon(forceIcons: Bool = false) {
        if forceIcons { iconGeneration += 1 }
        let generation = iconGeneration
        check(forceIcons: forceIcons)
        for delay in forceIcons ? [0.35, 1.2, 4] : [0.35, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                // A later launch or quit started its own schedule; this pass still reads
                // the menus but leaves the icons to that one.
                self.check(forceIcons: forceIcons && generation == self.iconGeneration)
            }
        }
    }

    private func check(forceIcons: Bool = false) {
        guard running else { return }
        guard AXIsProcessTrusted() else {
            publish(Reading())
            return
        }
        // The menu bar belongs to the app whose menus it shows, which is not always the
        // frontmost one (a floating panel can be frontmost while another app's menus show).
        guard let owner = NSWorkspace.shared.menuBarOwningApplication ?? NSWorkspace.shared.frontmostApplication else { return }
        let pid = owner.processIdentifier
        // Cockpit has no menus of its own worth avoiding, and its Settings window coming
        // forward should not make the readouts jump.
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        // One icon scan at a time: they share the queue with the menu reads.
        let refreshIcons = !iconScanQueued && (forceIcons || Date().timeIntervalSince(iconsCheckedAt) > 30)
        if refreshIcons {
            iconsCheckedAt = Date()
            iconScanQueued = true
        }
        let screens = Self.screenFrames()
        // Background-only helpers cannot put up icons, and many never answer at all.
        let pids = refreshIcons
            ? NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }.map(\.processIdentifier)
            : []
        queue.async {
            var menusRead = true
            var menus: CGFloat?
            do { menus = try Self.menusEnd(pid: pid, screens: screens) } catch { menusRead = false }
            let icons = refreshIcons ? Self.iconsStart(pids: pids, screens: screens) : nil
            // Earlier values are read back here, not when the check was queued: the queue
            // is serial, so a pass queued earlier has published by now, and copying its
            // old value up front would put it back over the newer one.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if refreshIcons { self.iconScanQueued = false }
                // An app too busy to answer keeps the reading it last gave, so the readouts
                // do not jump back over its menus; the next pass corrects it.
                var end = menus
                if menusRead {
                    self.menusPid = pid
                } else {
                    end = self.menusPid == pid ? self.reading.menusEnd : nil
                }
                // Each app's last answer is kept, so one that is busy for a pass keeps its
                // icons counted, and one that never answers cannot freeze the edge.
                var start = self.reading.iconsStart
                if let icons {
                    let live = Set(pids)
                    self.iconEdges = self.iconEdges.filter { live.contains($0.key) }
                    for (app, edge) in icons { self.iconEdges[app] = edge }
                    start = self.iconEdges.values.max()
                }
                self.publish(Reading(menusEnd: end, iconsStart: start))
            }
        }
    }

    private func publish(_ r: Reading) {
        guard r != reading else { return }
        reading = r
        onChange(r)
    }

    // MARK: - Accessibility reads (off the main thread)

    // Screen frames in Accessibility's space: origin at the top-left of the primary display.
    private static func screenFrames() -> [CGRect] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map { s in
            CGRect(x: s.frame.minX, y: primaryHeight - s.frame.maxY, width: s.frame.width, height: s.frame.height)
        }
    }

    nonisolated private static func screen(containing r: CGRect, in screens: [CGRect]) -> CGRect? {
        screens.first { $0.contains(CGPoint(x: r.midX, y: r.midY)) }
    }

    nonisolated private static func menusEnd(pid: pid_t, screens: [CGRect]) throws -> CGFloat? {
        let timeout: Float = 0.25
        let app = AXUIElementCreateApplication(pid)
        guard let bar = try element(app, kAXMenuBarAttribute, timeout: timeout) else { return nil }
        let items = try children(bar, timeout: timeout)
        // The Apple menu comes first. A right-to-left menu bar (Arabic, Hebrew) puts it at
        // the right edge; the distances here assume left to right, so leave that bar alone.
        guard let apple = items.first else { return nil }
        if let r = try frame(apple, timeout: timeout), let s = screen(containing: r, in: screens), r.midX > s.midX {
            return nil
        }
        var end: CGFloat?
        for item in items {
            guard let r = try frame(item, timeout: timeout), r.width > 0, let s = screen(containing: r, in: screens) else { continue }
            end = max(end ?? 0, r.maxX - s.minX)
        }
        return end
    }

    // Menu-bar icons belong to whichever app put them there, so ask every app. Most
    // answer in well under a millisecond; a hung one gives up after a tenth of a second
    // and is left out, so its previous answer stands. An app that answered with no icons
    // maps to nil.
    nonisolated private static func iconsStart(pids: [pid_t], screens: [CGRect]) -> [pid_t: CGFloat?] {
        let timeout: Float = 0.1
        var answers: [pid_t: CGFloat?] = [:]
        for pid in pids {
            do {
                var edge: CGFloat?
                if let extras = try element(AXUIElementCreateApplication(pid), kAXExtrasMenuBarAttribute, timeout: timeout) {
                    for item in try children(extras, timeout: timeout) {
                        guard let r = try frame(item, timeout: timeout), r.width > 0, let s = screen(containing: r, in: screens) else { continue }
                        edge = max(edge ?? 0, s.maxX - r.minX)
                    }
                }
                answers[pid] = .some(edge)
            } catch {
                continue
            }
        }
        return answers
    }

    private struct NoAnswer: Error {}

    // One attribute read. An app without that attribute, or without Accessibility
    // support at all, has answered: nothing there. One that times out or fails some
    // other way has not, and that must never be mistaken for an app without menus.
    nonisolated private static func copy(_ el: AXUIElement, _ attribute: String, timeout: Float) throws -> CFTypeRef? {
        // The timeout belongs to the element, and a child element otherwise waits the
        // system default of six seconds.
        AXUIElementSetMessagingTimeout(el, timeout)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(el, attribute as CFString, &value) {
        case .success: return value
        case .noValue, .attributeUnsupported, .notImplemented, .apiDisabled, .invalidUIElement: return nil
        default: throw NoAnswer()
        }
    }

    nonisolated private static func element(_ el: AXUIElement, _ attribute: String, timeout: Float) throws -> AXUIElement? {
        guard let value = try copy(el, attribute, timeout: timeout), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    nonisolated private static func children(_ el: AXUIElement, timeout: Float) throws -> [AXUIElement] {
        let value = try copy(el, kAXChildrenAttribute, timeout: timeout)
        return (value as? [AXUIElement]) ?? []
    }

    nonisolated private static func frame(_ el: AXUIElement, timeout: Float) throws -> CGRect? {
        guard let p = try copy(el, kAXPositionAttribute, timeout: timeout),
              let s = try copy(el, kAXSizeAttribute, timeout: timeout),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
