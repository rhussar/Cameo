import AppKit
import Carbon.HIToolbox

/// A shortcut you can assign: a key with Carbon modifier flags, or an extra mouse button (middle, back, forward,
/// or the side buttons on mice like Logitech's), plus how it reads (e.g. "⌃⌥Z", "Mouse Back").
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
    /// NSEvent/CGEvent button number (2 = middle, 3 = back, 4 = forward, higher = extra buttons). Nil for a key.
    var mouseButton: Int? = nil

    /// A mouse button. Left and right clicks (0, 1) aren't allowed.
    init?(mouseButton: Int) {
        guard mouseButton >= 2 else { return nil }
        let name = switch mouseButton {
        case 2: "Middle Click"
        case 3: "Mouse Back"
        case 4: "Mouse Forward"
        default: "Mouse Button \(mouseButton + 1)"
        }
        self.init(keyCode: 0, modifiers: 0, label: name)
        self.mouseButton = mouseButton
    }

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

/// A system-wide shortcut. Keys use Carbon hot keys, which need no permission, and the key press goes only to us,
/// not to the app you're demoing. Mouse buttons use an event tap, which needs Accessibility access, and swallow
/// the click so (say) Back doesn't also take your browser back mid-demo.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var button: Int64 = -1
    private let action: () -> Void

    /// Whether DemoRec may watch mouse buttons system-wide. `prompt` shows the macOS request (once per app version).
    static func mouseAccess(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Nil if another app already owns the key shortcut, or, for a mouse button, without Accessibility access.
    init?(_ shortcut: Shortcut, action: @escaping () -> Void) {
        self.action = action
        if let mouseButton = shortcut.mouseButton {
            guard installTap(button: mouseButton) else { return nil }
            return
        }
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

    private func installTap(button: Int) -> Bool {
        self.button = Int64(button)
        let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue) | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userInfo).takeUnretainedValue()
            // The tap's run loop source is on the main run loop.
            return MainActor.assumeIsolated { hotKey.handle(type: type, event: event) }
        }, userInfo: me) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.mouseEventButtonNumber) == button else { return Unmanaged.passUnretained(event) }
        if type == .otherMouseDown { action() }
        return nil // ours: swallow both press and release
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        ref = nil
        handler = nil
        tap = nil
        tapSource = nil
    }
}
