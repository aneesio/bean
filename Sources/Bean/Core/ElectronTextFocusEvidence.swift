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
        guard app?.bundleIdentifier == slackBundleID else {
            clear()
            return
        }
        // A menu-bar item can be clicked while Slack remains the frontmost app.
        // Accept only clicks geometrically inside a real Slack window, so using
        // Bean's menu does not erase or replace valid composer evidence.
        guard clickIsInsideAppWindow(point, processIdentifier: app?.processIdentifier) else { return }
        guard !focusedElementIsKnownNonText else { clear(); return }
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

    static func hasValidTypingEvidence(for app: NSRunningApplication?) -> Bool {
        validAnchor(for: app) != nil
    }

    /// Re-validates the geometry portion of a previously captured typing
    /// anchor after Bean temporarily became active and the live evidence cache
    /// was cleared. Callers must also require an unchanged interaction revision
    /// and the exact re-copied draft before using this as destination proof.
    static func capturedAnchorRemainsInAppWindow(_ point: CGPoint,
                                                 for app: NSRunningApplication?) -> Bool {
        guard app?.bundleIdentifier == slackBundleID else { return false }
        return clickIsInsideAppWindow(point, processIdentifier: app?.processIdentifier)
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

    private static func clickIsInsideAppWindow(_ appKitPoint: CGPoint,
                                               processIdentifier: pid_t?) -> Bool {
        guard let processIdentifier,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) }),
              let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        let displayBounds = CGDisplayBounds(CGDirectDisplayID(displayNumber.uint32Value))
        let quartzPoint = CGPoint(
            x: displayBounds.minX + (appKitPoint.x - screen.frame.minX),
            y: displayBounds.minY + (screen.frame.maxY - appKitPoint.y)
        )
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let rawBounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = rawBounds["X"] as? NSNumber,
                  let y = rawBounds["Y"] as? NSNumber,
                  let width = rawBounds["Width"] as? NSNumber,
                  let height = rawBounds["Height"] as? NSNumber else { return false }
            let bounds = CGRect(x: x.doubleValue, y: y.doubleValue,
                                width: width.doubleValue, height: height.doubleValue)
            return bounds.contains(quartzPoint)
        }
    }
}
