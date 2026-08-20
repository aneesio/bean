import Foundation

// Internal tuning constants for the acquisition/replacement engine. These are
// intentionally NOT exposed as a big settings UI in Phase 0 (one optional
// checkbox lives in AppSettings). Timing delays live in Timing.swift; this file
// holds the behavioural limits.
enum EngineConfig {
    /// Maximum length of a focused field that Bean will auto-correct in full
    /// (when there is no selection). Longer fields ask the user to select a
    /// smaller section instead, to avoid expensive/destructive whole-document
    /// rewrites.
    static let maxAutoFieldCharacters = 8_000

    /// Master switch for the guarded Cmd+A focused-field fallback (used only
    /// when the Accessibility value can't be read directly).
    static let allowCmdAFieldFallback = true

    /// Apps where a blind Cmd+A would select an entire document/buffer rather
    /// than a single field. Bean never uses the Cmd+A fallback here; it sticks
    /// to selection-only or shows a safe message.
    static let cmdAFallbackBlockedBundleIDs: Set<String> = [
        "com.microsoft.VSCode",            // VS Code
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.apple.dt.Xcode",              // Xcode
        "com.apple.Terminal",              // Terminal
        "com.googlecode.iterm2",           // iTerm2
        "com.sublimetext.4",               // Sublime Text
        "com.jetbrains.intellij"           // IntelliJ family (representative)
    ]

    static func isCmdAFallbackBlocked(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return cmdAFallbackBlockedBundleIDs.contains(bundleID)
    }
}
