import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut you can assign, saved as the key and Carbon modifier flags plus how it reads (e.g. "⌃⌥Z").
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    static let defaultZoom = Shortcut(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥Z")

    /// The shortcut a key press makes. Nil for a plain key without ⌘, ⌃ or ⌥ (it would take over typing that key
    /// everywhere), except the F-keys, which are fine on their own.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = Int(event.keyCode)
        let fKey = Self.fKeys[code]
        guard fKey != nil || !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var carbon = 0
        var text = ""
        if flags.contains(.control) { carbon |= controlKey; text += "⌃" }
        if flags.contains(.option) { carbon |= optionKey; text += "⌥" }
        if flags.contains(.shift) { carbon |= shiftKey; text += "⇧" }
        if flags.contains(.command) { carbon |= cmdKey; text += "⌘" }
        let key = fKey ?? Self.named[code] ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? "?"
        self.init(keyCode: UInt32(code), modifiers: UInt32(carbon), label: text + key)
    }

    init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    private static let fKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]
    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]
}

/// A system-wide keyboard shortcut. Carbon hot keys need no Accessibility or Input Monitoring permission,
/// and the key press goes only to us, not to the app you're demoing.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// Nil if another app already owns the shortcut.
    init?(_ shortcut: Shortcut, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, me, &handler)
        let id = EventHotKeyID(signature: OSType(0x444D_525A), id: 1) // "DMRZ"
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
    }
}
