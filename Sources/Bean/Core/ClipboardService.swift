import AppKit
import CoreGraphics

// Clipboard + synthetic-keystroke helper. This is the heart of the universal
// fallback path: when the Accessibility API can't read or write the selection
// directly (web views, Electron, etc.), we drive the standard system Copy/Paste
// shortcuts and shuttle text through NSPasteboard.
//
// CLIPBOARD SAFETY: the user's real clipboard must survive a fix in normal
// use. The flow always snapshots the pasteboard before touching it and restores
// that snapshot after a safe delay (see TextSelectionService).
enum ClipboardService {

    // MARK: - Snapshot / restore

    /// A full copy of the pasteboard's contents: one dictionary of
    /// type -> data per pasteboard item. Enough to faithfully restore text,
    /// rich text, images, etc.
    typealias Snapshot = [[String: Data]]

    /// Captures the current pasteboard so it can be restored later.
    static func snapshot() -> Snapshot {
        guard let items = NSPasteboard.general.pasteboardItems else { return [] }
        return items.map { item in
            var dict: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type.rawValue] = data
                }
            }
            return dict
        }
    }

    /// Restores a previously captured snapshot, overwriting whatever Bean put
    /// on the pasteboard during the fix.
    static func restore(_ snapshot: Snapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }

        let items: [NSPasteboardItem] = snapshot.map { dict in
            let item = NSPasteboardItem()
            for (rawType, data) in dict {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    // MARK: - Read / write plain text

    static var changeCount: Int { NSPasteboard.general.changeCount }

    static func readString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    static func writeString(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    // MARK: - Synthetic keystrokes

    // Virtual key codes (ANSI layout). These are stable regardless of the
    // user's keyboard layout for the physical key positions.
    private static let keyA: CGKeyCode = 0x00
    private static let keyC: CGKeyCode = 0x08
    private static let keyV: CGKeyCode = 0x09

    /// Simulates Cmd+C in the frontmost app.
    static func simulateCopy() {
        postCommandKey(keyC)
    }

    /// Simulates Cmd+V in the frontmost app.
    static func simulatePaste() {
        postCommandKey(keyV)
    }

    /// Simulates Cmd+A (Select All) in the frontmost app. Used ONLY by the
    /// guarded focused-field fallback — never blindly, because in document
    /// editors Cmd+A selects the whole file.
    static func simulateSelectAll() {
        postCommandKey(keyA)
    }

    /// Posts a key-down + key-up for `key` with the Command modifier held.
    /// Requires Accessibility permission; without it the events are silently
    /// dropped by the system.
    private static func postCommandKey(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
