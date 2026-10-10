import AppKit

/// Keeps one confirmed native edit in memory. Undo requires the exact edited
/// field and value, so it can never overwrite subsequent user writing.
@MainActor
final class ReplacementUndoStore {
    static let lifetime: TimeInterval = 5 * 60

    struct Request {
        let targetApp: NSRunningApplication
        let element: AXUIElement
        let original: String
        let replacement: String
        let rangeEdit: RangeEdit?
        let editPlan: NativeEditPlan?
    }

    struct Attempt {
        let result: TextSelectionService.ReplacementResult
        let didAttemptDelivery: Bool
    }

    /// Owned fixtures inject transport without activating apps, reading AX or
    /// posting input. Production uses the existing guarded editing service.
    struct Effects {
        let activateAndValidate: (NSRunningApplication, AXUIElement) async -> Bool
        let readValue: (AXUIElement) -> String?
        let selectedRange: (AXUIElement) -> NSRange?
        let apply: (Request, NSRange?) async -> Attempt
    }

    private struct Record {
        let createdAt: Date
        let targetApp: NSRunningApplication
        let element: AXUIElement
        let original: String
        let replacement: String
        let rangeEdit: RangeEdit?
        let editPlan: NativeEditPlan?
    }

    struct RangeEdit {
        let range: NSRange
        let original: String
        let replacement: String
    }

    private var record: Record?
    private var recordRevision: UInt64 = 0
    private var undoInFlight = false
    private let effects: Effects?

    init(effects: Effects? = nil) { self.effects = effects }

    private func updateRecord(_ record: Record?) {
        self.record = record
        recordRevision &+= 1
    }

    var isAvailable: Bool {
        guard !undoInFlight, let record else { return false }
        return Date().timeIntervalSince(record.createdAt) <= Self.lifetime
    }

    func isAvailable(for element: AXUIElement, value: String, app: NSRunningApplication?) -> Bool {
        guard isAvailable, let record, let app, !app.isTerminated,
              record.targetApp.processIdentifier == app.processIdentifier,
              AccessibilityService.isSameElement(record.element, element),
              Self.currentValueMatches(value, expectedReplacement: record.replacement) else { return false }
        return true
    }

    /// A newer confirmed edit without an exact undoable range must retire the
    /// previous change, rather than offer Undo for a different operation.
    func discard() {
        updateRecord(nil)
    }

    func registerConfirmedWholeField(
        app: NSRunningApplication?,
        element: AXUIElement?,
        original: String,
        replacement: String
    ) {
        guard let app, !app.isTerminated, let element,
              !TextSelectionService.exactTextMatches(original, replacement) else { return }
        updateRecord(Record(createdAt: Date(), targetApp: app, element: element,
                            original: original, replacement: replacement, rangeEdit: nil, editPlan: nil))
    }

    func registerConfirmedRange(app: NSRunningApplication?, element: AXUIElement?,
                                original: String, replacement: String, range: NSRange,
                                originalRangeText: String, replacementRangeText: String) {
        guard let app, !app.isTerminated, let element,
              !TextSelectionService.exactTextMatches(original, replacement),
              Self.canRegisterRangeUndo(original: original, replacement: replacement, range: range,
                                        originalRangeText: originalRangeText,
                                        replacementRangeText: replacementRangeText) else { return }
        updateRecord(Record(createdAt: Date(), targetApp: app, element: element,
                        original: original, replacement: replacement,
                        rangeEdit: RangeEdit(range: range, original: originalRangeText,
                                             replacement: replacementRangeText), editPlan: nil))
    }

    func registerConfirmedEdits(app: NSRunningApplication?, element: AXUIElement?, plan: NativeEditPlan) {
        guard let app, !app.isTerminated, let element, !plan.edits.isEmpty,
              let checked = NativeEditPlan.validated(original: plan.original, edits: plan.edits),
              Self.currentValueMatches(checked.replacement, expectedReplacement: plan.replacement) else { return }
        updateRecord(Record(createdAt: Date(), targetApp: app, element: element,
                        original: checked.original, replacement: checked.replacement,
                        rangeEdit: nil, editPlan: checked))
    }

    func undo() async -> TextSelectionService.ReplacementResult {
        guard !undoInFlight else { return .failed(reason: "Bean is already undoing a change.") }
        guard let record else {
            return .failed(reason: "There is no recent verified Bean change to undo.")
        }
        guard Date().timeIntervalSince(record.createdAt) <= Self.lifetime else {
            updateRecord(nil)
            return .failed(reason: "The undo window expired. Bean keeps changes for five minutes.")
        }
        guard !record.targetApp.isTerminated else {
            updateRecord(nil)
            return .failed(reason: "The original app is no longer running.")
        }

        let claimedRevision = recordRevision
        undoInFlight = true
        defer { undoInFlight = false }
        let destinationMatches: Bool
        if let effects {
            destinationMatches = await effects.activateAndValidate(record.targetApp, record.element)
        } else {
            activate(record.targetApp)
            await Task.pause(Timing.afterActivate)
            destinationMatches = NSWorkspace.shared.frontmostApplication?.processIdentifier == record.targetApp.processIdentifier
                && AccessibilityService.focusedField(in: record.targetApp).map {
                    AccessibilityService.isSameElement($0.element, record.element)
                } == true
        }
        guard recordRevision == claimedRevision else {
            return .failed(reason: "A newer Bean change replaced this Undo. Check the current field.")
        }
        guard destinationMatches, !Task.isCancelled else {
            return .failed(reason: "Focus the field Bean changed, then try Undo again.")
        }
        let current = readValue(of: record.element)
        guard let current,
              Self.currentValueMatches(current, expectedReplacement: record.replacement) else {
            updateRecord(nil)
            return .failed(reason: "Undo was cancelled because the field changed after Bean edited it.")
        }
        let selection = effects.map { $0.selectedRange(record.element) } ?? AccessibilityService.selectedRange(of: record.element)
        // Consume the claim before any inverse can be delivered. Its completion
        // must not erase or resurrect a record registered by a newer action.
        updateRecord(nil)
        let consumedRevision = recordRevision
        let attempt: Attempt
        if let effects {
            attempt = await effects.apply(Request(targetApp: record.targetApp, element: record.element,
                original: record.original, replacement: record.replacement, rangeEdit: record.rangeEdit,
                editPlan: record.editPlan), selection)
        } else {
            attempt = await performUndo(record, selection: selection)
        }
        let preDeliveryRefusal: Bool
        switch attempt.result {
        case .failed, .copiedToClipboardFallback, .staleCopiedToClipboard, .clipboardPreservedRecoveryRequired:
            preDeliveryRefusal = true
        case .replacedConfirmed, .replacementSentUnconfirmed, .noChangesNeeded:
            preDeliveryRefusal = false
        }
        if preDeliveryRefusal, !attempt.didAttemptDelivery, recordRevision == consumedRevision {
            let unchanged = readValue(of: record.element)
            if let unchanged, Self.currentValueMatches(unchanged, expectedReplacement: record.replacement) {
                updateRecord(record)
            }
        }
        return attempt.result
    }

    private func performUndo(_ record: Record, selection: NSRange?) async -> Attempt {
        // Inverse edits register their own temporary history. Keep that local;
        // they cannot replace a newer action's record in the live Undo store.
        let service = TextSelectionService(undoStore: ReplacementUndoStore())
        let result: TextSelectionService.ReplacementResult
        if let plan = record.editPlan {
            result = await service.replaceEdits(app: record.targetApp, element: record.element,
                valueBefore: record.replacement, edits: plan.inverseEdits, selectionToRestore: selection)
        } else if let edit = record.rangeEdit {
            let range = NSRange(location: edit.range.location, length: (edit.replacement as NSString).length)
            if range.length > 0 {
                result = await service.replaceRange(
                    app: record.targetApp, element: record.element, valueBefore: record.replacement,
                    range: range, replacement: edit.original, selectionToRestore: selection
                )
            } else {
                // A deletion is reversed at the proven numeric caret. Never
                // flatten surrounding formatting/attachments to restore it.
                result = await service.replaceEdits(app: record.targetApp, element: record.element,
                    valueBefore: record.replacement,
                    edits: [NativeTextEdit(range: range, original: "", replacement: edit.original)],
                    selectionToRestore: selection)
            }
        } else {
            result = await service.replaceWholeField(
                app: record.targetApp, element: record.element,
                valueBefore: record.replacement, replacement: record.original,
                selectionToRestore: selection
            )
        }
        let attempted = service.lastReplacementAttemptedDelivery
        service.cancel()
        return Attempt(result: result, didAttemptDelivery: attempted)
    }

    private func readValue(of element: AXUIElement) -> String? {
        if let effects { return effects.readValue(element) }
        return AccessibilityService.value(of: element)
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
