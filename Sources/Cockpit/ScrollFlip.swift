import AppKit
import ApplicationServices

// Keeps trackpad scrolling natural while reversing a wheel mouse.
//
// macOS has a single global "natural scrolling" switch shared by the trackpad and
// the mouse. Leave it ON. A trackpad / Magic Mouse sends *continuous* scroll events
// (left untouched); a traditional wheel mouse sends *discrete* ones, which get
// swallowed and re-posted with the opposite delta.

nonisolated(unsafe) private var scrollFlipActive = false
nonisolated(unsafe) private var scrollTap: CFMachPort?
private let syntheticTag: Int64 = 0x5350_4C50 // "SPLP": stamped on injected events

private func scrollEventCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = scrollTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard scrollFlipActive, type == .scrollWheel else { return Unmanaged.passUnretained(event) }
    if event.getIntegerValueField(.eventSourceUserData) == syntheticTag { return Unmanaged.passUnretained(event) }
    guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return Unmanaged.passUnretained(event) }

    let w1 = Int32(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
    let w2 = Int32(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
    if let src = CGEventSource(stateID: .hidSystemState),
       let flipped = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 2, wheel1: -w1, wheel2: -w2, wheel3: 0) {
        flipped.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
        flipped.post(tap: .cgSessionEventTap)
        return nil
    }
    return Unmanaged.passUnretained(event)
}

@MainActor
final class ScrollFlipEngine: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            scrollFlipActive = enabled
            UserDefaults.standard.set(enabled, forKey: "scrollFlipEnabled")
        }
    }
    @Published private(set) var axTrusted = AXIsProcessTrusted()
    @Published private(set) var tapActive = false

    private var retry: Timer?

    init() {
        let stored = (UserDefaults.standard.object(forKey: "scrollFlipEnabled") as? Bool) ?? false
        enabled = stored
        scrollFlipActive = stored
    }

    var isFlipping: Bool { enabled && tapActive }

    func start() {
        if createTap() { return }
        axTrusted = AXIsProcessTrusted()
        // Ask with the system dialog once, ever. After that the Scroll tab shows the
        // state and its button re-asks on demand. Nagging on every launch is what made
        // the old grant feel broken.
        let d = UserDefaults.standard
        if !d.bool(forKey: "axPromptShown") {
            d.set(true, forKey: "axPromptShown")
            requestPermission(prompt: true)
        }
        // Pick up the grant the moment it lands, no relaunch needed.
        retry = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.axTrusted = AXIsProcessTrusted()
                if self.createTap() {
                    self.retry?.invalidate()
                    self.retry = nil
                }
            }
        }
    }

    func requestPermission(prompt: Bool) {
        let opts = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        axTrusted = AXIsProcessTrustedWithOptions(opts)
    }

    @discardableResult
    private func createTap() -> Bool {
        if scrollTap != nil { tapActive = true; return true }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollEventCallback,
            userInfo: nil
        ) else {
            tapActive = false
            return false
        }
        scrollTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapActive = true
        axTrusted = true
        return true
    }
}
