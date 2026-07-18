import AppKit
import Carbon.HIToolbox

/// A user-recorded global shortcut, persisted in AppSettings.
struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt32          // Carbon virtual key code
    var carbonModifiers: UInt32  // Carbon flag bits (cmdKey / optionKey / …)
    var keyLabel: String         // display name for the non-modifier key ("G", "Space", "F5")

    var display: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel
    }

    /// nil when the combo can't be a sane global shortcut: without a ⌘/⌥/⌃
    /// anchor (or an F-key) it would swallow plain typing system-wide.
    init?(event: NSEvent) {
        var mods: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        let code = Int(event.keyCode)
        let anchored = mods & UInt32(cmdKey | optionKey | controlKey) != 0
        guard anchored || Self.functionKeys[code] != nil else { return nil }
        guard let label = Self.label(for: event) else { return nil }
        keyCode = UInt32(event.keyCode)
        carbonModifiers = mods
        keyLabel = label
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥",
        kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
    ]

    private static func label(for event: NSEvent) -> String? {
        let code = Int(event.keyCode)
        if let name = functionKeys[code] ?? specialKeys[code] { return name }
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
        let label = chars.uppercased()
        guard label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return label
    }
}

/// Registers the one system-wide hotkey (show/hide window). Carbon's
/// RegisterEventHotKey is still the only API for this that needs no
/// Accessibility permission and actually consumes the keystroke.
final class HotkeyManager {
    static let shared = HotkeyManager()
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

    /// Replaces any current registration. Returns false if the system refused
    /// the combo (usually because another app owns it).
    @discardableResult
    func register(_ config: HotkeyConfig?) -> Bool {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        guard let config else { return true }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 0x4743_484B /* "GCHK" */, id: 1)
        let status = RegisterEventHotKey(config.keyCode, config.carbonModifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        return true
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // C function pointer — no captures allowed, so route through the singleton.
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            DispatchQueue.main.async { HotkeyManager.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
