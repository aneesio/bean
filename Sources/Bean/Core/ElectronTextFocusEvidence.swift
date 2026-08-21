import AppKit

// Slack's Electron accessibility tree can expose no focused UI element at all.
// This records short-lived, content-free evidence that the user clicked a
// plausible surface and then typed printable characters in Slack. It is used
// only to position the fallback bubble and to permit a guarded Cmd+A/C field
// acquisition. No keys, characters, text, titles, or clipboard data are kept.
@MainActor
enum ElectronTextFocusEvidence {
    private static let slackBundleID = "com.tinyspeck.slackmacgap"
    private static let maximumAge: TimeInterval = 30

    private static var processIdentifier: pid_t?
    private static var clickPoint: CGPoint?
    private static var clickedAt: Date?
    private static var lastPrintableKeyAt: Date?
    private static var printableKeyCount = 0

    static func recordClick(app: NSRunningApplication?, point: CGPoint,
                            focusedElementIsKnownNonText: Bool) {
        guard app?.bundleIdentifier == slackBundleID, !focusedElementIsKnownNonText else {
            clear()
            return
        }
        processIdentifier = app?.processIdentifier
        clickPoint = point
        clickedAt = Date()
        lastPrintableKeyAt = nil
        printableKeyCount = 0
    }

    static func recordKey(_ event: NSEvent, app: NSRunningApplication?) {
        guard app?.bundleIdentifier == slackBundleID,
              app?.processIdentifier == processIdentifier,
              let clickedAt, Date().timeIntervalSince(clickedAt) <= maximumAge,
              isPrintableTextEntry(event) else { return }
        printableKeyCount = min(printableKeyCount + 1, 3)
        lastPrintableKeyAt = Date()
    }

    static func validAnchor(for app: NSRunningApplication?) -> CGPoint? {
        guard app?.bundleIdentifier == slackBundleID,
              app?.processIdentifier == processIdentifier,
              printableKeyCount >= 2,
              let lastPrintableKeyAt,
              Date().timeIntervalSince(lastPrintableKeyAt) <= maximumAge else { return nil }
        return clickPoint
    }

    static func clear() {
        processIdentifier = nil
        clickPoint = nil
        clickedAt = nil
        lastPrintableKeyAt = nil
        printableKeyCount = 0
    }

    private static func isPrintableTextEntry(_ event: NSEvent) -> Bool {
        let disallowed = event.modifierFlags.intersection([.command, .control, .option])
        guard disallowed.isEmpty,
              let characters = event.charactersIgnoringModifiers,
              !characters.isEmpty else { return false }
        return characters.unicodeScalars.contains { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}
