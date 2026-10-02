import AppKit

/// Keeps one confirmed native edit in memory. Undo requires the exact edited
/// field and value, so it can never overwrite subsequent user writing.
@MainActor
final class ReplacementUndoStore {
    static let lifetime: TimeInterval = 5 * 60

    private struct Record {
        let createdAt: Date
        let targetApp: NSRunningApplication
        let element: AXUIElement
        let original: String
        let replacement: String
        let rangeEdit: RangeEdit?
    }

    private struct RangeEdit {
        let range: NSRange
        let original: String
        let replacement: String
    }

    private var record: Record?

    var isAvailable: Bool {
        guard let record else { return false }
        return Date().timeIntervalSince(record.createdAt) <= Self.lifetime
    }

    /// A newer confirmed edit without an exact undoable range must retire the
    /// previous change, rather than offer Undo for a different operation.
    func discard() {
        record = nil
    }

    func registerConfirmedWholeField(
        app: NSRunningApplication?,
        element: AXUIElement?,
        original: String,
        replacement: String
    ) {
        guard let app, !app.isTerminated, let element,
              !TextSelectionService.exactTextMatches(original, replacement) else { return }
        record = Record(createdAt: Date(), targetApp: app, element: element,
                        original: original, replacement: replacement, rangeEdit: nil)
    }

    func registerConfirmedRange(app: NSRunningApplication?, element: AXUIElement?,
                                original: String, replacement: String, range: NSRange,
                                originalRangeText: String, replacementRangeText: String) {
        guard let app, !app.isTerminated, let element,
              !TextSelectionService.exactTextMatches(original, replacement),
              Self.canRegisterRangeUndo(original: original, replacement: replacement, range: range,
                                        originalRangeText: originalRangeText,
                                        replacementRangeText: replacementRangeText) else { return }
        record = Record(createdAt: Date(), targetApp: app, element: element,
                        original: original, replacement: replacement,
                        rangeEdit: RangeEdit(range: range, original: originalRangeText,
                                             replacement: replacementRangeText))
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
        let selection = AccessibilityService.selectedRange(of: record.element)
        let service = TextSelectionService(undoStore: self)
        let result: TextSelectionService.ReplacementResult
        if let edit = record.rangeEdit {
            let range = NSRange(location: edit.range.location, length: (edit.replacement as NSString).length)
            if range.length > 0 {
                result = await service.replaceRange(
                    app: record.targetApp, element: record.element, valueBefore: record.replacement,
                    range: range, replacement: edit.original, selectionToRestore: selection
                )
            } else {
                // Undoing a verified deletion inserts the original substring;
                // restore the proven complete field through normal Paste.
                result = await service.replaceWholeField(
                    app: record.targetApp, element: record.element,
                    valueBefore: record.replacement, replacement: record.original,
                    selectionToRestore: selection
                )
            }
        } else {
            result = await service.replaceWholeField(
                app: record.targetApp, element: record.element,
                valueBefore: record.replacement, replacement: record.original,
                selectionToRestore: selection
            )
        }
        service.cancel()
        guard result == .replacedConfirmed else {
            // A retryable clipboard fallback must keep the original undo
            // record; an uncertain editor result needs a fresh exact check.
            self.record = record
            return result
        }

        self.record = nil
        return .replacedConfirmed
    }

    nonisolated static func currentValueMatches(_ current: String, expectedReplacement: String) -> Bool {
        TextSelectionService.exactTextMatches(current, expectedReplacement)
    }

    nonisolated static func canRegisterRangeUndo(original: String, replacement: String, range: NSRange,
                                                originalRangeText: String, replacementRangeText: String) -> Bool {
        !TextSelectionService.exactTextMatches(original, replacement)
            && TextSelectionService.exactTextMatches(TextSelectionService.expectedValueAfterSelectionReplacement(
            valueBefore: original, selectedRange: range,
            selectedText: originalRangeText, corrected: replacementRangeText
        ), replacement)
    }

    private func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) { app.activate() } else { app.activate(options: []) }
    }
}
