import Foundation
import os

// Development-safe operational logging.
//
// PRIVACY: this logger is ONLY ever passed fixed, operational strings and
// non-text metrics (lengths, result codes, provider/app names). The user's
// text, the corrected text, API response bodies, clipboard contents, and
// prompts are NEVER passed here or logged anywhere. All messages are marked
// `.public` precisely because they must never contain user content.
enum Log {
    private static let logger = Logger(subsystem: "com.bean.app", category: "engine")

    /// Always-on operational event (no text).
    static func event(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }

    /// When true, `diag` emits a structured, text-free summary line. Off by
    /// default; toggled from AppSettings. Marked unsafe because it's a simple
    /// debug flag flipped from the main actor and read during logging.
    nonisolated(unsafe) static var diagnosticsEnabled = false

    /// Diagnostics line (only emitted when diagnostics are enabled). Callers
    /// must pass non-text key/value metrics only.
    static func diag(_ fields: [String: String]) {
        guard diagnosticsEnabled else { return }
        let line = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        logger.log("diag \(line, privacy: .public)")
    }
}
