import AppKit

/// Keeps one verified whole-field replacement in memory so the user can undo
/// it safely. Nothing is persisted, and selected-text/unverified writes are
/// deliberately excluded because Bean cannot prove the exact previous state.
@MainActor
final class ReplacementUndoStore {
    static let lifetime: TimeInterval = 5 * 60

    private struct Record {
        let createdAt: Date
        let targetApp: NSRunningApplication
        let element: AXUIElement
        let original: String
        let replacement: String
    }

    private var record: Record?

    var isAvailable: Bool {
        guard let record else { return false }
        return Date().timeIntervalSince(record.createdAt) <= Self.lifetime
    }

    func registerConfirmedWholeField(
        app: NSRunningApplication?,
        element: AXUIElement?,
        original: String,
        replacement: String
    ) {
        guard let app, !app.isTerminated, let element, original != replacement else { return }
        record = Record(createdAt: Date(), targetApp: app, element: element,
                        original: original, replacement: replacement)
    }

    func undo() async -> TextSelectionService.ReplacementResult {
        guard let record else {
            return .failed(reason: "There is no recent verified Bean change to undo.")
        }
        guard Date().timeIntervalSince(record.createdAt) <= Self.lifetime else {
            self.record = nil
            return .failed(reason: "The undo window expired. Bean keeps changes for five minutes.")
        }
        guard !record.targetApp.isTerminated else {
            self.record = nil
            return .failed(reason: "The original app is no longer running.")
        }

        activate(record.targetApp)
        await Task.pause(Timing.afterActivate)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == record.targetApp.processIdentifier,
              let focused = AccessibilityService.focusedField(in: record.targetApp)?.element,
              AccessibilityService.isSameElement(focused, record.element) else {
            return .failed(reason: "Focus the field Bean changed, then try Undo again.")
        }
        guard let current = AccessibilityService.value(of: record.element),
              Self.currentValueMatches(current, expectedReplacement: record.replacement) else {
            self.record = nil
            return .failed(reason: "Undo was cancelled because the field changed after Bean edited it.")
        }
        guard AccessibilityService.isValueSettable(record.element),
              AccessibilityService.setValue(record.original, on: record.element) else {
            return .failed(reason: "This field does not support a safe verified undo.")
        }
        await Task.pause(Timing.afterActivate)
        guard AccessibilityService.value(of: record.element) == record.original else {
            return .failed(reason: "Bean could not verify the undo.")
        }

        self.record = nil
        return .replacedConfirmed
    }

    nonisolated static func currentValueMatches(_ current: String, expectedReplacement: String) -> Bool {
        current == expectedReplacement
    }

    private func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) { app.activate() } else { app.activate(options: []) }
    }
}
