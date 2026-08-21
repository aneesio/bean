import Foundation

// Centralized, short delay constants for the capture/replace engine.
//
// Pasteboard writes and synthetic Cmd+C / Cmd+V are asynchronous: the target
// app needs a brief moment to service the keystroke and update the pasteboard
// or its own text. These are deliberately small (100–500ms) — long enough to be
// reliable, short enough to feel instant. Tune here, not at call sites.
enum Timing {
    /// Wait after simulating Cmd+C before reading the pasteboard.
    static let afterCopy: Duration = .milliseconds(150)

    /// Wait after re-activating the target app (and after writing the
    /// pasteboard) before simulating Cmd+V, so the paste lands in the right app.
    static let afterActivate: Duration = .milliseconds(120)

    /// One retry window for Electron apps whose activation/focus propagation is
    /// slower than native AppKit controls.
    static let afterActivationRetry: Duration = .milliseconds(350)

    /// Wait after simulating Cmd+V before reading back the field for
    /// verification.
    static let afterPaste: Duration = .milliseconds(220)

    /// Wait after a confirmed/sent paste before restoring the user's original
    /// clipboard. Restoring too early can make the target paste the OLD
    /// clipboard (or nothing), so this is intentionally the longest delay.
    static let beforeClipboardRestore: Duration = .milliseconds(500)
}

extension Task where Success == Never, Failure == Never {
    /// Convenience: `try? await Task.sleep(for:)` already exists; this wrapper
    /// keeps call sites terse and non-throwing for our fixed delays.
    static func pause(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}
