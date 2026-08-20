import AppKit

// User-friendly facade over the Accessibility permission. Keeps the AX details
// in AccessibilityService and exposes just what the UI/coordinator need.
enum PermissionService {

    static var isAccessibilityGranted: Bool {
        AccessibilityService.isTrusted
    }

    /// Triggers the one-time system prompt that deep-links to the Accessibility
    /// settings pane.
    static func requestAccessibility() {
        AccessibilityService.promptForTrust()
    }

    /// Opens the exact System Settings pane for Accessibility permissions.
    /// Works on Ventura+ via the x-apple.systempreferences URL scheme.
    static func openAccessibilitySettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// One-line human-readable explanation for the current permission state.
    static var statusDescription: String {
        isAccessibilityGranted
            ? "Accessibility: granted"
            : "Accessibility: not granted — Bean needs it to read and replace selected text."
    }
}
