import AppKit
import Carbon

/// A global keyboard shortcut, stored with Carbon modifier flags.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static let `default` = KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥R")

    /// nil unless the event has at least one of ⌃ ⌥ ⌘ (plain keys would hijack typing everywhere).
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var mods: UInt32 = 0, symbols = ""
        if flags.contains(.control) { mods |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { mods |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { mods |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { mods |= UInt32(cmdKey); symbols += "⌘" }
        // ponytail: only common key names; F-keys/arrows show as raw characters.
        let key: String
        switch Int(event.keyCode) {
        case kVK_Space: key = "Space"
        case kVK_Return: key = "↩"
        case kVK_Tab: key = "⇥"
        default: key = event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods, display: symbols + key)
    }

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }
}

/// Registers one system-wide hotkey via Carbon (works without Accessibility permission).
final class Hotkey {
    static let shared = Hotkey()
    var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register(_ combo: KeyCombo) {
        unregister()
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { Hotkey.shared.action?() }
                return noErr
            }, 1, &spec, nil, &handlerRef)
        }
        let id = EventHotKeyID(signature: OSType(0x4152_5354), id: 1) // "ARST"
        RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}
