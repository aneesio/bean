import AppKit
import Carbon.HIToolbox

// A global keyboard shortcut: a key plus modifier flags, stored in Carbon terms
// (the units RegisterEventHotKey wants) and Codable for UserDefaults.
//
// Keeping all the Carbon/NSEvent translation here means HotkeyService stays a
// thin registrar and the UI never touches raw key codes.
struct GlobalShortcut: Codable, Equatable {
    /// Carbon virtual key code (matches NSEvent.keyCode and kVK_* constants).
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey | shiftKey | optionKey | controlKey).
    var carbonModifiers: UInt32

    /// The shipped default for quick proofread: Command + Shift + G.
    static let `default` = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_G),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )

    /// The shipped default for the Bean action menu: Control + Option + B.
    static let beanMenuDefault = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_B),
        carbonModifiers: UInt32(controlKey | optionKey)
    )

    // MARK: - Modifier helpers

    var hasCommand: Bool { carbonModifiers & UInt32(cmdKey) != 0 }
    var hasShift: Bool { carbonModifiers & UInt32(shiftKey) != 0 }
    var hasOption: Bool { carbonModifiers & UInt32(optionKey) != 0 }
    var hasControl: Bool { carbonModifiers & UInt32(controlKey) != 0 }

    /// AppKit modifier flags (for menu item display / key equivalents).
    var nsModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if hasControl { flags.insert(.control) }
        if hasOption { flags.insert(.option) }
        if hasShift { flags.insert(.shift) }
        if hasCommand { flags.insert(.command) }
        return flags
    }

    // MARK: - Display

    /// e.g. "⌘⇧G" or "⌃⌥B". Modifiers ordered ⌘ ⌃ ⌥ ⇧ then the key, matching
    /// how Bean refers to its shortcut elsewhere.
    var displayString: String {
        var result = ""
        if hasCommand { result += "⌘" }
        if hasControl { result += "⌃" }
        if hasOption { result += "⌥" }
        if hasShift { result += "⇧" }
        result += Self.keyName(for: keyCode)
        return result
    }

    /// The lowercase letter/number to use as an NSMenuItem keyEquivalent, or
    /// nil for keys that don't map cleanly to one.
    var menuKeyEquivalent: String? {
        let name = Self.keyName(for: keyCode)
        guard name.count == 1, let ch = name.first, ch.isLetter || ch.isNumber else { return nil }
        return name.lowercased()
    }

    // MARK: - From NSEvent

    static func from(event: NSEvent) -> GlobalShortcut {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return GlobalShortcut(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers)
    }

    // MARK: - Validation

    /// Keys that must not be used as the trigger key on their own.
    private static let reservedKeyCodes: Set<Int> = [
        kVK_Escape, kVK_Tab, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space, kVK_Delete
    ]

    /// Bare ⌘<key> combos that collide with ubiquitous system/app shortcuts.
    private static let dangerousCommandKeys: Set<Int> = [
        kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X,
        kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_P, kVK_ANSI_Z
    ]

    /// Returns a user-facing reason the shortcut is invalid, or nil if it's OK.
    var validationError: String? {
        if Self.reservedKeyCodes.contains(Int(keyCode)) {
            return "That key can't be used. Pick a letter or number."
        }
        // Require a "primary" modifier; Shift alone (or nothing) isn't enough.
        if !hasCommand && !hasOption && !hasControl {
            return "Add ⌘, ⌥, or ⌃ — Shift alone isn't enough."
        }
        // Bare ⌘<key> that's a common system shortcut.
        if hasCommand && !hasOption && !hasControl && !hasShift,
           Self.dangerousCommandKeys.contains(Int(keyCode)) {
            return "That's a common system shortcut. Add ⇧ or ⌥, or choose another key."
        }
        return nil
    }

    var isValid: Bool { validationError == nil }

    // MARK: - Key code → name

    static func keyName(for keyCode: UInt32) -> String {
        keyNames[Int(keyCode)] ?? "Key \(keyCode)"
    }

    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_Escape: "⎋", kVK_ANSI_KeypadEnter: "⌅",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12"
    ]
}
