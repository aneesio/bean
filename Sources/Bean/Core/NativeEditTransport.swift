import Foundation

/// Choose the edit mechanism before delivery. A writable AXSelectedText
/// attribute alone does not prove that a web editor implements the action.
enum NativeEditTransport: Equatable {
    case accessibilitySelectedText
    case keyboard

    static func preferred(bundleIdentifier: String?, selectedTextSettable: Bool,
                          isWebContent: Bool) -> Self {
        // Chromium exposes a selected-text setter that dispatches
        // kReplaceSelectedText, but BrowserAccessibility does not handle it.
        // Slack consequently accepts the AX request without editing its draft.
        // Known web hosts also need this fallback when AX ancestry is missing.
        guard selectedTextSettable, !isWebContent,
              !AppCategory.isElectron(bundleIdentifier),
              !AppCategory.isBrowser(bundleIdentifier) else { return .keyboard }
        return .accessibilitySelectedText
    }
}
