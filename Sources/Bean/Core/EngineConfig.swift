import Foundation

// Internal tuning constants for the acquisition/replacement engine. These are
// intentionally NOT exposed as a big settings UI in Phase 0 (one optional
// checkbox lives in AppSettings). Timing delays live in Timing.swift; this file
// holds the behavioural limits.
enum EngineConfig {
    /// Minimum gap between provider-backed checks that happen automatically
    /// after typing. Explicit shortcut/menu actions are never rate-limited.
    static let automaticLLMCooldown: TimeInterval = 20

    /// One conservative grapheme ceiling for provider requests. Browser
    /// requests use the same 8,000-character boundary in their isolated host
    /// pipeline. Keeping the native limit here prevents an explicit selection
    /// from silently becoming an unexpectedly expensive request.
    static let maxProviderInputCharacters = 8_000

    /// Swift's `String.count` measures extended grapheme clusters. One cluster
    /// can contain an arbitrary number of combining scalars, so a character-only
    /// check is not a cost boundary. Four UTF-8 bytes per allowed character keeps
    /// every single-scalar Unicode character representable at the boundary while
    /// placing a hard 32 KB ceiling on the actual source payload.
    static let maxProviderInputUTF8Bytes = maxProviderInputCharacters * 4

    /// Exact ceiling for the complete trusted-system + encoded-user request.
    /// The source allowance is 32 KB; this additional headroom covers Bean's
    /// fixed instructions and bounded personalization while preventing JSON
    /// escaping or an unexpected prompt component from creating an unbounded
    /// provider request.
    static let maxProviderRequestInputUTF8Bytes = 64 * 1_024

    /// Shared last-line provider-input policy. Callers with a tighter product
    /// limit (for example a 2,000-character browser paragraph) receive a
    /// proportionally tighter byte limit and cannot reserve usage before this
    /// check succeeds.
    static func providerInputIsWithinLimit(
        _ text: String,
        maximumCharacters: Int = maxProviderInputCharacters
    ) -> Bool {
        guard maximumCharacters >= 0,
              text.count <= maximumCharacters else { return false }
        let byteLimit = utf8ByteLimit(maximumCharacters: maximumCharacters)
        return text.utf8.count <= byteLimit
    }

    static func exceedsProviderInputLimit(
        _ text: String,
        maximumCharacters: Int = maxProviderInputCharacters
    ) -> Bool {
        !providerInputIsWithinLimit(text, maximumCharacters: maximumCharacters)
    }

    /// Proportional UTF-8 allowance used by source and prompt-component
    /// formatters. A single ordinary Unicode scalar can require four bytes;
    /// extended graphemes containing unbounded combining scalars cannot.
    static func utf8ByteLimit(maximumCharacters: Int) -> Int {
        guard maximumCharacters > 0 else { return 0 }
        let scaled = maximumCharacters.multipliedReportingOverflow(by: 4)
        return scaled.overflow
            ? maxProviderInputUTF8Bytes
            : min(maxProviderInputUTF8Bytes, scaled.partialValue)
    }

    /// Final byte/token-estimate boundary for the exact strings handed to a
    /// provider. Callers on metered automatic paths also run this same check
    /// before reserving usage, then the provider service repeats it immediately
    /// before constructing a provider.
    static func providerRequestInputIsWithinLimit(
        systemPrompt: String,
        userText: String
    ) -> Bool {
        let systemBytes = systemPrompt.utf8.count
        guard systemBytes <= maxProviderRequestInputUTF8Bytes else { return false }
        return userText.utf8.count <= maxProviderRequestInputUTF8Bytes - systemBytes
    }

    /// Maximum length of a focused field that Bean will auto-correct in full
    /// (when there is no selection). This shares the provider ceiling even for
    /// local Quick Fix because replacing a larger whole field would also be a
    /// destructive editing risk. Explicit Quick Fix selections remain local
    /// and are not subject to the provider limit.
    static let maxAutoFieldCharacters = maxProviderInputCharacters

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
