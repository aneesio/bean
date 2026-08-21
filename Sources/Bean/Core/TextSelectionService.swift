import AppKit

// High-level capture/replace engine.
//
// ACQUISITION (layered):
//   A. Selected text via clipboard: snapshot clipboard, Cmd+C, wait, read. If
//      the pasteboard changed and holds meaningful text, that's the selection.
//   B. No selection -> Accessibility focused-field full text: read the focused
//      editable element's value directly.
//   C. AX value unreadable -> guarded Cmd+A fallback: ONLY in clearly editable
//      fields and never in document editors (see EngineConfig). Cmd+A, Cmd+C,
//      read.
//   A long-field guard (EngineConfig.maxAutoFieldCharacters) caps automatic
//   full-field correction.
//
// REPLACEMENT (mode-aware, always verified where possible):
//   - selection: re-activate app, paste, verify by re-reading the field value.
//   - focused field via AX: prefer AX setValue (verify), else Cmd+A + paste.
//   - focused field via Cmd+A fallback: Cmd+A + paste (verify if readable).
//   "Text/Field fixed" is only reported when verified; otherwise "Replacement
//   sent" or the clipboard fallback.
//
// The user's text is never logged or stored.
@MainActor
final class TextSelectionService {

    private let undoStore: ReplacementUndoStore

    init(undoStore: ReplacementUndoStore) {
        self.undoStore = undoStore
    }

    /// Honest, verifiable outcomes of a replacement attempt.
    enum ReplacementResult {
        case replacedConfirmed          // verified: the field now holds the corrected text
        case replacementSentUnconfirmed // paste sent, but we couldn't verify
        case copiedToClipboardFallback  // paste couldn't happen / didn't land
        case staleCopiedToClipboard     // field changed since acquire; left on clipboard
        case noChangesNeeded            // corrected text equals the original
        case failed(reason: String)
    }

    // Everything captured during acquire() and consumed by replace().
    private struct Pending {
        var mode: TextInputMode
        var savedClipboard: ClipboardService.Snapshot
        var targetApp: NSRunningApplication?
        var focusedElement: AXUIElement?
        var valueSettable: Bool
        var fieldValueReadable: Bool   // can we read the field value to verify?
        var valueBefore: String?       // pre-change value, for verification
        var acquiredViaCmdA: Bool
        var allowsAXFreeFullFieldPaste: Bool
    }

    private var pending: Pending?

    // MARK: - Acquisition

    func acquire(allowFocusedFieldFallback: Bool) async -> TextAcquisitionResult {
        let targetApp = NSWorkspace.shared.frontmostApplication
        let savedClipboard = ClipboardService.snapshot()

        // ---- A. Selected text via clipboard -------------------------------
        let preCount = ClipboardService.changeCount
        // Pre-read the focused value now so selection-mode verification has a
        // "before" baseline (the selection lives inside this value).
        let fieldBeforeSelection = AccessibilityService.focusedField()
        let valueBeforeSelection = fieldBeforeSelection?.value
        ClipboardService.simulateCopy()
        await Task.pause(Timing.afterCopy)

        if ClipboardService.changeCount != preCount,
           let copied = ClipboardService.readString(),
           !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Genuine selection.
            let field = fieldBeforeSelection ?? AccessibilityService.focusedField()
            pending = Pending(
                mode: .selectedText,
                savedClipboard: savedClipboard,
                targetApp: targetApp,
                focusedElement: field?.element,
                valueSettable: field?.isValueSettable ?? false,
                fieldValueReadable: valueBeforeSelection != nil,
                valueBefore: valueBeforeSelection,
                acquiredViaCmdA: false,
                allowsAXFreeFullFieldPaste: false
            )
            let context = SourceAppContext.current(app: targetApp, field: field, mode: .selectedText)
            Log.event("Acquired \(context.logDescription)")
            return .acquired(text: copied, mode: .selectedText, context: context)
        }

        // No selection. The copy attempt didn't change the pasteboard; restore
        // it untouched before exploring the focused-field path.
        ClipboardService.restore(savedClipboard)

        // Respect the user's "fix focused field when no selection" preference.
        guard allowFocusedFieldFallback else {
            Log.event("No selection; focused-field fallback disabled")
            return .noSelectionOrFocusedField
        }

        // ---- B. Accessibility focused-field full text ---------------------
        guard let field = AccessibilityService.focusedField() else {
            if ElectronTextFocusEvidence.validAnchor(for: targetApp) != nil {
                return await acquireSlackFieldWithoutAX(targetApp: targetApp,
                                                        savedClipboard: savedClipboard)
            }
            Log.event("No focused editable field found")
            return .noSelectionOrFocusedField
        }

        let category = AppCategory.from(bundleIdentifier: targetApp?.bundleIdentifier)
        let capabilities = FieldCapabilityPolicy.evaluate(
            bundleIdentifier: targetApp?.bundleIdentifier,
            category: category,
            traits: FieldTraits(field: field),
            preferences: .manual(focusedFieldFallbackEnabled: allowFocusedFieldFallback)
        )
        guard capabilities.focusedFieldReplacement.level != .unsupported else {
            Log.event("Focused-field acquisition refused: \(capabilities.focusedFieldReplacement.reason)")
            return .noSelectionOrFocusedField
        }

        let electronTextSurface = AppCategory.isElectron(targetApp?.bundleIdentifier)
            && field.isSemanticTextSurface
        if let value = field.value,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           field.acceptsTextInput || electronTextSurface {
            if value.count > EngineConfig.maxAutoFieldCharacters {
                Log.event("Focused field exceeds length guard")
                return .tooLong
            }
            pending = Pending(
                mode: .focusedFieldFullText,
                savedClipboard: savedClipboard,
                targetApp: targetApp,
                focusedElement: field.element,
                valueSettable: field.isValueSettable,
                fieldValueReadable: true,
                valueBefore: value,
                acquiredViaCmdA: false,
                allowsAXFreeFullFieldPaste: false
            )
            let context = SourceAppContext.current(app: targetApp, field: field, mode: .focusedFieldFullText)
            Log.event("Acquired \(context.logDescription)")
            return .acquired(text: value, mode: .focusedFieldFullText, context: context)
        }

        // ---- C. Guarded Cmd+A fallback ------------------------------------
        // Only when: enabled, the focused element is clearly a text field, and
        // the app isn't a document editor where Cmd+A grabs the whole buffer.
        let cmdAAllowed = EngineConfig.allowCmdAFieldFallback
            && (field.acceptsTextInput || electronTextSurface)
            && !EngineConfig.isCmdAFallbackBlocked(bundleID: targetApp?.bundleIdentifier)

        guard cmdAAllowed else {
            Log.event("No AX-readable field value and Cmd+A fallback not safe here")
            return .noSelectionOrFocusedField
        }

        // Re-snapshot in case the earlier restore changed the change count.
        let preCountA = ClipboardService.changeCount
        ClipboardService.simulateSelectAll()
        await Task.pause(Timing.afterActivate)
        ClipboardService.simulateCopy()
        await Task.pause(Timing.afterCopy)

        guard ClipboardService.changeCount != preCountA,
              let copied = ClipboardService.readString(),
              !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.event("Cmd+A fallback produced no text")
            ClipboardService.restore(savedClipboard)
            return .noSelectionOrFocusedField
        }

        if copied.count > EngineConfig.maxAutoFieldCharacters {
            Log.event("Cmd+A focused text exceeds length guard")
            ClipboardService.restore(savedClipboard)
            return .tooLong
        }

        pending = Pending(
            mode: .focusedFieldFullText,
            savedClipboard: savedClipboard,
            targetApp: targetApp,
            focusedElement: field.element,
            valueSettable: field.isValueSettable,
            fieldValueReadable: false, // AX value wasn't readable
            valueBefore: nil,
            acquiredViaCmdA: true,
            allowsAXFreeFullFieldPaste: false
        )
        let context = SourceAppContext.current(app: targetApp, field: field, mode: .focusedFieldFullText)
        Log.event("Acquired \(context.logDescription) (Cmd+A)")
        return .acquired(text: copied, mode: .focusedFieldFullText, context: context)
    }

    /// Slack-only whole-composer acquisition when Electron exposes no AX field.
    /// Short-lived click+typing evidence is required before this method can be
    /// reached, so Cmd+A is never sent merely because Slack is frontmost.
    private func acquireSlackFieldWithoutAX(targetApp: NSRunningApplication?,
                                            savedClipboard: ClipboardService.Snapshot) async -> TextAcquisitionResult {
        let preCount = ClipboardService.changeCount
        ClipboardService.simulateSelectAll()
        await Task.pause(Timing.afterActivate)
        ClipboardService.simulateCopy()
        await Task.pause(Timing.afterCopy)

        guard ClipboardService.changeCount != preCount,
              let copied = ClipboardService.readString(),
              !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.event("Slack AX-free Cmd+A fallback produced no text")
            ClipboardService.restore(savedClipboard)
            return .noSelectionOrFocusedField
        }
        guard copied.count <= EngineConfig.maxAutoFieldCharacters else {
            Log.event("Slack AX-free focused text exceeds length guard")
            ClipboardService.restore(savedClipboard)
            return .tooLong
        }

        pending = Pending(
            mode: .focusedFieldFullText,
            savedClipboard: savedClipboard,
            targetApp: targetApp,
            focusedElement: nil,
            valueSettable: false,
            fieldValueReadable: false,
            valueBefore: nil,
            acquiredViaCmdA: true,
            allowsAXFreeFullFieldPaste: true
        )
        let context = SourceAppContext.current(app: targetApp, field: nil, mode: .focusedFieldFullText)
        Log.event("Acquired \(context.logDescription) (Slack typing-evidence Cmd+A)")
        return .acquired(text: copied, mode: .focusedFieldFullText, context: context)
    }

    /// Aborts a pending fix without replacing anything, restoring the user's
    /// clipboard. Call this when the flow bails after acquire() (LLM error,
    /// failed output validation) so the copied text doesn't linger on the
    /// clipboard.
    func cancel() {
        if let pending {
            ClipboardService.restore(pending.savedClipboard)
        }
        pending = nil
    }

    /// Clears the pending acquisition WITHOUT restoring the clipboard. Used by
    /// the preview "Copy" action, where the transformed text is intentionally
    /// left on the clipboard for the user.
    func discard() {
        pending = nil
    }

    // MARK: - Replacement

    func replace(corrected: String, original: String, mode: TextInputMode) async -> ReplacementResult {
        guard let pending else {
            return .failed(reason: "Internal error: nothing acquired")
        }

        let trimmedCorrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCorrected.isEmpty else {
            Log.event("replace: correction was empty")
            ClipboardService.restore(pending.savedClipboard)
            self.pending = nil
            return .failed(reason: "The model returned an empty response")
        }

        if trimmedCorrected == original.trimmingCharacters(in: .whitespacesAndNewlines) {
            Log.event("replace: no changes needed")
            ClipboardService.restore(pending.savedClipboard)
            self.pending = nil
            return .noChangesNeeded
        }

        let result: ReplacementResult
        switch mode {
        case .selectedText:
            result = await replaceSelection(corrected: corrected, trimmedCorrected: trimmedCorrected, pending: pending)
        case .focusedFieldFullText:
            result = await replaceFocusedField(corrected: corrected, trimmedCorrected: trimmedCorrected, pending: pending)
        }

        if case .replacedConfirmed = result, mode == .focusedFieldFullText {
            undoStore.registerConfirmedWholeField(
                app: pending.targetApp,
                element: pending.focusedElement,
                original: original,
                replacement: corrected
            )
        }

        // A clipboard fallback can be retried safely with the original target.
        // All other outcomes resolve the acquisition and release its text.
        switch result {
        case .copiedToClipboardFallback, .staleCopiedToClipboard:
            break
        default:
            self.pending = nil
        }
        return result
    }

    // MARK: - Selection replacement (verified paste)

    private func replaceSelection(corrected: String, trimmedCorrected: String, pending: Pending) async -> ReplacementResult {
        // A preview/menu click gives Bean focus. Reactivate the original app
        // before checking the target; checking first made preview replacements
        // incorrectly fall back to the clipboard every time.
        guard await reactivateAndConfirm(pending.targetApp) else {
            Log.event("replace(selection): source app not frontmost; clipboard fallback")
            ClipboardService.writeString(corrected)
            return .copiedToClipboardFallback
        }

        let current = pending.targetApp.flatMap { AccessibilityService.focusedField(in: $0)?.element }
        if let target = pending.focusedElement, let current,
           !AccessibilityService.isSameElement(current, target) {
            Log.event("replace(selection): target focus not restored; clipboard fallback")
            ClipboardService.writeString(corrected)
            return .copiedToClipboardFallback
        }
        if current == nil {
            // A changed clipboard proves there was an explicit selection. Some
            // Electron/web editors (notably Slack) expose no AX-focused element
            // after app activation; once the exact source app is confirmed
            // frontmost, send the paste and report it as unverified.
            Log.event("replace(selection): AX focus unavailable; sending to confirmed source app")
        }

        ClipboardService.writeString(corrected)
        await Task.pause(Timing.afterActivate)
        ClipboardService.simulatePaste()
        await Task.pause(Timing.afterPaste)

        let result = verifyByFocusedValue(trimmedCorrected: trimmedCorrected, valueBefore: pending.valueBefore)
        await finishClipboard(for: result, corrected: corrected, saved: pending.savedClipboard)
        return result
    }

    // MARK: - Focused-field replacement

    private func replaceFocusedField(corrected: String, trimmedCorrected: String, pending: Pending) async -> ReplacementResult {
        guard let target = pending.focusedElement else {
            if pending.allowsAXFreeFullFieldPaste {
                return await replaceSlackFieldWithoutAX(corrected: corrected, pending: pending)
            }
            Log.event("replace(field): no saved target; clipboard fallback")
            ClipboardService.writeString(corrected)
            return .copiedToClipboardFallback
        }

        // Preview/menu UI can temporarily own focus. Restore the source app, let
        // it reinstate its field, and only then perform the same-element guard.
        guard await reactivateAndConfirm(pending.targetApp) else {
            Log.event("replace(field): source app not frontmost; clipboard fallback")
            ClipboardService.writeString(corrected)
            return .copiedToClipboardFallback
        }
        guard let app = pending.targetApp,
              let current = AccessibilityService.focusedField(in: app)?.element,
              AccessibilityService.isSameElement(current, target) else {
            Log.event("replace(field): target focus not restored; clipboard fallback")
            ClipboardService.writeString(corrected)
            return .copiedToClipboardFallback
        }

        // Stale guard: if the field's text changed since we acquired it (e.g.
        // the user kept typing during a preview), don't overwrite their newer
        // text — leave the result on the clipboard instead.
        if pending.fieldValueReadable, let before = pending.valueBefore,
           let now = AccessibilityService.value(of: target), now != before {
            Log.event("replace(field): field changed since acquire; stale -> clipboard")
            ClipboardService.writeString(corrected)
            return .staleCopiedToClipboard
        }

        // 1. Prefer a direct AX value write when the element supports it.
        if pending.valueSettable {
            if AccessibilityService.setValue(corrected, on: target) {
                await Task.pause(Timing.afterActivate)
                if let after = AccessibilityService.value(of: target),
                   after.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedCorrected {
                    Log.event("replace(field): AX setValue confirmed")
                    // AX write didn't touch the clipboard; nothing to restore.
                    return .replacedConfirmed
                }
                Log.event("replace(field): AX setValue unverified; trying paste")
            } else {
                Log.event("replace(field): AX setValue failed; trying paste")
            }
        }

        // 2. Cmd+A + paste fallback (select the whole field, then replace).
        ClipboardService.writeString(corrected)
        await Task.pause(Timing.afterActivate)
        ClipboardService.simulateSelectAll()
        await Task.pause(Timing.afterActivate)
        ClipboardService.simulatePaste()
        await Task.pause(Timing.afterPaste)

        let result: ReplacementResult
        if pending.fieldValueReadable || AccessibilityService.value(of: target) != nil {
            result = verifyFieldValue(target: target, trimmedCorrected: trimmedCorrected, valueBefore: pending.valueBefore)
        } else {
            // Can't read it back (e.g. web/Electron); paste very likely landed.
            Log.event("replace(field): value unreadable -> sent (unconfirmed)")
            result = .replacementSentUnconfirmed
        }

        await finishClipboard(for: result, corrected: corrected, saved: pending.savedClipboard)
        return result
    }

    private func replaceSlackFieldWithoutAX(corrected: String, pending: Pending) async -> ReplacementResult {
        guard await reactivateAndConfirm(pending.targetApp) else {
            Log.event("replace(field): Slack source app not frontmost; clipboard fallback")
            ClipboardService.writeString(corrected)
            return .copiedToClipboardFallback
        }
        ClipboardService.writeString(corrected)
        await Task.pause(Timing.afterActivate)
        ClipboardService.simulateSelectAll()
        await Task.pause(Timing.afterActivate)
        ClipboardService.simulatePaste()
        await Task.pause(Timing.afterPaste)
        Log.event("replace(field): Slack AX-free paste sent unconfirmed")
        let result: ReplacementResult = .replacementSentUnconfirmed
        await finishClipboard(for: result, corrected: corrected, saved: pending.savedClipboard)
        return result
    }

    // MARK: - Verification

    /// Verifies a selection paste by comparing the focused element's value
    /// before and after.
    private func verifyByFocusedValue(trimmedCorrected: String, valueBefore: String?) -> ReplacementResult {
        guard let after = AccessibilityService.readFocusedValue() else {
            Log.event("verify(selection): value unreadable -> sent")
            return .replacementSentUnconfirmed
        }
        if let before = valueBefore, after == before {
            Log.event("verify(selection): unchanged -> clipboard fallback")
            return .copiedToClipboardFallback
        }
        if after.contains(trimmedCorrected) {
            Log.event("verify(selection): confirmed")
            return .replacedConfirmed
        }
        Log.event("verify(selection): changed but unconfirmed -> sent")
        return .replacementSentUnconfirmed
    }

    /// Verifies a focused-field paste against a specific element.
    private func verifyFieldValue(target: AXUIElement, trimmedCorrected: String, valueBefore: String?) -> ReplacementResult {
        guard let after = AccessibilityService.value(of: target) else {
            Log.event("verify(field): value unreadable -> sent")
            return .replacementSentUnconfirmed
        }
        if let before = valueBefore, after == before {
            Log.event("verify(field): unchanged -> clipboard fallback")
            return .copiedToClipboardFallback
        }
        if after.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedCorrected {
            Log.event("verify(field): confirmed")
            return .replacedConfirmed
        }
        Log.event("verify(field): changed but unconfirmed -> sent")
        return .replacementSentUnconfirmed
    }

    // MARK: - Helpers

    private func activate(_ app: NSRunningApplication?) {
        guard let app else { return }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [])
        }
    }

    /// Restores the exact source app before a synthetic paste. The retry covers
    /// Electron apps that update macOS activation state one run-loop later.
    private func reactivateAndConfirm(_ app: NSRunningApplication?) async -> Bool {
        guard let app, !app.isTerminated else { return false }
        activate(app)
        await Task.pause(Timing.afterActivate)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            return true
        }
        activate(app)
        await Task.pause(Timing.afterActivationRetry)
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    /// Restores the user's clipboard after a safe delay for paths that pasted,
    /// or deliberately leaves the corrected text on the clipboard for the
    /// fallback path.
    private func finishClipboard(for result: ReplacementResult, corrected: String, saved: ClipboardService.Snapshot) async {
        switch result {
        case .replacedConfirmed, .replacementSentUnconfirmed:
            await Task.pause(Timing.beforeClipboardRestore)
            ClipboardService.restore(saved)
        case .copiedToClipboardFallback, .staleCopiedToClipboard:
            ClipboardService.writeString(corrected)
        case .noChangesNeeded, .failed:
            break
        }
    }
}
