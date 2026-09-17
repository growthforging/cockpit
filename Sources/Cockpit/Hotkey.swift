import AppKit
import Carbon.HIToolbox

// ⇧⌘V opens the clipboard history, the way Win+V does on Windows.
// Carbon hot keys work without any permission and from any app.
// The virtual key that types a given character on the keyboard layout in use.
enum KeyLayout {
    static func virtualKey(for target: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for code in UInt16(0)..<128 {
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), 0, keyboardType,
                    UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &chars
                )
                guard status == noErr, length == 1, let scalar = UnicodeScalar(chars[0]) else { continue }
                if Character(scalar) == target { return CGKeyCode(code) }
            }
            return nil
        }
    }
}

@MainActor
final class HotkeyCenter {
    nonisolated(unsafe) static var action: (() -> Void)?

    // noErr does not prove the key will ever fire, but a non-zero status proves it will not.
    private(set) var lastStatus: OSStatus = noErr

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register() {
        guard hotKeyRef == nil else { return }
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
                DispatchQueue.main.async { HotkeyCenter.action?() }
                return noErr
            }, 1, &spec, nil, &handlerRef)
        }
        let id = EventHotKeyID(signature: OSType(0x434B_5054), id: 1)   // "CKPT"
        lastStatus = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        lastStatus = noErr
    }
}
