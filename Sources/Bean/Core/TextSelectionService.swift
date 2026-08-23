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
    enum ReplacementResult: Equatable {
        case replacedConfirmed          // verified: the field now holds the corrected text
        case replacementSentUnconfirmed // paste sent, but we couldn't verify
        case copiedToClipboardFallback  // paste couldn't happen / didn't land
        case staleCopiedToClipboard     // field changed since acquire; left on clipboard
        case clipboardPreservedRecoveryRequired // user copied while Bean pasted; correction is preview-only
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
        var selectedRangeBefore: NSRange?
        var clipboardOwnershipChangeCount: Int?
        var keepsFallbackCorrection: Bool
        var acquiredViaCmdA: Bool
        var allowsAXFreeFullFieldPaste: Bool
        var slackTypingAnchor: CGPoint?
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

        let postSelectionCopyCount = ClipboardService.changeCount
        if postSelectionCopyCount != preCount,
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
                selectedRangeBefore: field.flatMap {
                    AccessibilityService.selectedRange(of: $0.element)
                },
                clipboardOwnershipChangeCount: postSelectionCopyCount,
                keepsFallbackCorrection: false,
                acquiredViaCmdA: false,
                allowsAXFreeFullFieldPaste: false,
                slackTypingAnchor: ElectronTextFocusEvidence.validAnchor(for: targetApp)
            )
            let context = SourceAppContext.current(app: targetApp, field: field, mode: .selectedText)
            Log.event("Acquired \(context.logDescription)")
            return .acquired(text: copied, mode: .selectedText, context: context)
        }

        // A no-selection copy usually leaves the pasteboard untouched. Some
        // apps clear it instead; restore only while that change is still ours.
        var clipboardOwnershipAfterSelectionAttempt: Int?
        if postSelectionCopyCount != preCount,
           Self.restoreClipboardIfOwned(
               savedClipboard,
               beanOwnedChangeCount: postSelectionCopyCount
           ) {
            clipboardOwnershipAfterSelectionAttempt = ClipboardService.changeCount
        } else {
            clipboardOwnershipAfterSelectionAttempt = nil
        }

        // Respect the user's "fix focused field when no selection" preference.
        guard allowFocusedFieldFallback else {
            Log.event("No selection; focused-field fallback disabled")
            return .noSelectionOrFocusedField
        }

        // ---- B. Accessibility focused-field full text ---------------------
        guard let field = AccessibilityService.focusedField() else {
            if ElectronTextFocusEvidence.validAnchor(for: targetApp) != nil {
                let fallbackSavedClipboard = Self.clipboardSnapshotToRestore(
                    originalSaved: savedClipboard,
                    currentSnapshot: ClipboardService.snapshot(),
                    acquisitionOwnedChangeCount: clipboardOwnershipAfterSelectionAttempt,
                    currentChangeCount: ClipboardService.changeCount
                )
                return await acquireSlackFieldWithoutAX(targetApp: targetApp,
                                                        savedClipboard: fallbackSavedClipboard)
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
            if ElectronTextFocusEvidence.hasValidTypingEvidence(for: targetApp) {
                let fallbackSavedClipboard = Self.clipboardSnapshotToRestore(
                    originalSaved: savedClipboard,
                    currentSnapshot: ClipboardService.snapshot(),
                    acquisitionOwnedChangeCount: clipboardOwnershipAfterSelectionAttempt,
                    currentChangeCount: ClipboardService.changeCount
                )
                return await acquireSlackFieldWithoutAX(targetApp: targetApp,
                                                        savedClipboard: fallbackSavedClipboard)
            }
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
                selectedRangeBefore: nil,
                clipboardOwnershipChangeCount: clipboardOwnershipAfterSelectionAttempt,
                keepsFallbackCorrection: false,
                acquiredViaCmdA: false,
                allowsAXFreeFullFieldPaste: false,
                slackTypingAnchor: nil
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

        let fallbackSavedClipboard = Self.clipboardSnapshotToRestore(
            originalSaved: savedClipboard,
            currentSnapshot: ClipboardService.snapshot(),
            acquisitionOwnedChangeCount: clipboardOwnershipAfterSelectionAttempt,
            currentChangeCount: ClipboardService.changeCount
        )
        let preCountA = ClipboardService.changeCount
        ClipboardService.simulateSelectAll()
        await Task.pause(Timing.afterActivate)
        ClipboardService.simulateCopy()
        await Task.pause(Timing.afterCopy)

        let postCountA = ClipboardService.changeCount
        guard postCountA != preCountA,
              let copied = ClipboardService.readString(),
              !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.event("Cmd+A fallback produced no text")
            if postCountA != preCountA {
                Self.restoreClipboardIfOwned(fallbackSavedClipboard, beanOwnedChangeCount: postCountA)
            }
            return .noSelectionOrFocusedField
        }

        if copied.count > EngineConfig.maxAutoFieldCharacters {
            Log.event("Cmd+A focused text exceeds length guard")
            Self.restoreClipboardIfOwned(fallbackSavedClipboard, beanOwnedChangeCount: postCountA)
            return .tooLong
        }

        pending = Pending(
            mode: .focusedFieldFullText,
            savedClipboard: fallbackSavedClipboard,
            targetApp: targetApp,
            focusedElement: field.element,
            valueSettable: field.isValueSettable,
            fieldValueReadable: false, // AX value wasn't readable
            valueBefore: copied,
            selectedRangeBefore: nil,
            clipboardOwnershipChangeCount: postCountA,
            keepsFallbackCorrection: false,
            acquiredViaCmdA: true,
            allowsAXFreeFullFieldPaste: false,
            slackTypingAnchor: nil
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
        guard let typingAnchor = ElectronTextFocusEvidence.validAnchor(for: targetApp) else {
            Log.event("Slack AX-free acquisition lost typing evidence")
            return .noSelectionOrFocusedField
        }
        let preCount = ClipboardService.changeCount
        ClipboardService.simulateSelectAll()
        await Task.pause(Timing.afterActivate)
        ClipboardService.simulateCopy()
        await Task.pause(Timing.afterCopy)

        let postCount = ClipboardService.changeCount
        guard postCount != preCount,
              let copied = ClipboardService.readString(),
              !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.event("Slack AX-free Cmd+A fallback produced no text")
            if postCount != preCount {
                Self.restoreClipboardIfOwned(savedClipboard, beanOwnedChangeCount: postCount)
            }
            return .noSelectionOrFocusedField
        }
        guard copied.count <= EngineConfig.maxAutoFieldCharacters else {
            Log.event("Slack AX-free focused text exceeds length guard")
            Self.restoreClipboardIfOwned(savedClipboard, beanOwnedChangeCount: postCount)
            return .tooLong
        }

        pending = Pending(
            mode: .focusedFieldFullText,
            savedClipboard: savedClipboard,
            targetApp: targetApp,
            focusedElement: nil,
            valueSettable: false,
            fieldValueReadable: false,
            valueBefore: copied,
            selectedRangeBefore: nil,
            clipboardOwnershipChangeCount: postCount,
            keepsFallbackCorrection: false,
            acquiredViaCmdA: true,
            allowsAXFreeFullFieldPaste: true,
            slackTypingAnchor: typingAnchor
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
        if let pending, !pending.keepsFallbackCorrection {
            Self.restoreClipboardIfOwned(
                pending.savedClipboard,
                beanOwnedChangeCount: pending.clipboardOwnershipChangeCount
            )
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
            Self.restoreClipboardIfOwned(
                pending.savedClipboard,
                beanOwnedChangeCount: pending.clipboardOwnershipChangeCount
            )
            self.pending = nil
            return .failed(reason: "The model returned an empty response")
        }

        if corrected == original {
            Log.event("replace: no changes needed")
            Self.restoreClipboardIfOwned(
                pending.savedClipboard,
                beanOwnedChangeCount: pending.clipboardOwnershipChangeCount
            )
            self.pending = nil
            return .noChangesNeeded
        }

        // Preserve the newest user-owned clipboard before any replacement
        // attempt. If this attempt falls back to the correction and is later
        // retried successfully, this is the snapshot that must be restored.
        var replacementPending = pending
        let clipboardToPreserve = clipboardSnapshotForTemporaryWrite(pending)
        replacementPending.savedClipboard = clipboardToPreserve
        self.pending?.savedClipboard = clipboardToPreserve

        let result: ReplacementResult
        switch mode {
        case .selectedText:
            result = await replaceSelection(
                corrected: corrected,
                original: original,
                pending: replacementPending
            )
        case .focusedFieldFullText:
            result = await replaceFocusedField(corrected: corrected, pending: replacementPending)
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
            self.pending?.clipboardOwnershipChangeCount = ClipboardService.changeCount
            self.pending?.keepsFallbackCorrection = true
        case .clipboardPreservedRecoveryRequired:
            // The user copied while Bean was pasting. Keep the acquisition for
            // an explicit retry, but never claim or later restore their newer
            // clipboard contents.
            self.pending?.clipboardOwnershipChangeCount = nil
            self.pending?.keepsFallbackCorrection = false
        default:
            self.pending = nil
        }
        return result
    }

    // MARK: - Selection replacement (verified paste)

    private func replaceSelection(corrected: String, original: String, pending: Pending) async -> ReplacementResult {
        // A preview/menu click gives Bean focus. Reactivate the original app
        // before checking the target; checking first made preview replacements
        // incorrectly fall back to the clipboard every time.
        guard await reactivateAndConfirm(pending.targetApp) else {
            Log.event("replace(selection): source app not frontmost; clipboard fallback")
            writeFallbackCorrection(corrected, pending: pending)
            return .copiedToClipboardFallback
        }

        let isElectronSource = AppCategory.isElectron(pending.targetApp?.bundleIdentifier)
        let current = pending.targetApp.flatMap { AccessibilityService.focusedField(in: $0)?.element }
        let targetsMatch = pending.focusedElement.flatMap { target in
            current.map { AccessibilityService.isSameElement($0, target) }
        } ?? false
        if let focusFailure = Self.selectionFocusContinuityFailure(
            capturedTargetExists: pending.focusedElement != nil,
            currentTargetExists: current != nil,
            targetsMatch: targetsMatch,
            allowsMissingCurrentTargetForExactElectronRecopy: isElectronSource
        ) {
            Log.event("replace(selection): captured AX target not restored; clipboard fallback")
            writeFallbackCorrection(corrected, pending: pending)
            return focusFailure
        }

        // Capture what must survive before a clipboard-based continuity check
        // temporarily copies the live selection.
        var clipboardToRestore = clipboardSnapshotForTemporaryWrite(pending)
        self.pending?.savedClipboard = clipboardToRestore
        let currentRange = pending.focusedElement.flatMap {
            AccessibilityService.selectedRange(of: $0)
        }
        let nativeReconstructionAvailable = targetsMatch && Self.expectedValueAfterSelectionReplacement(
            valueBefore: pending.valueBefore,
            selectedRange: pending.selectedRangeBefore,
            selectedText: original,
            corrected: corrected
        ) != nil
        let validation = Self.selectionValidationStrategy(
            capturedTargetExists: pending.focusedElement != nil,
            isElectronSource: isElectronSource,
            nativeReconstructionAvailable: nativeReconstructionAvailable,
            selectedRangeBefore: pending.selectedRangeBefore,
            selectedRangeNow: currentRange
        )

        let expectedAfter: String?
        let beanClipboardChangeCount: Int
        switch validation {
        case .nativeRange:
            guard let target = pending.focusedElement else {
                ClipboardService.writeString(corrected)
                return .copiedToClipboardFallback
            }
            // A native selected-text replacement is safe only when Bean can
            // reconstruct the exact post-edit field from the original UTF-16
            // selection and prove that both value and range are unchanged.
            let currentValue = AccessibilityService.value(of: target)
            if let continuityFailure = Self.nativeSelectionContinuityFailure(
                valueBefore: pending.valueBefore,
                valueNow: currentValue,
                selectedRangeBefore: pending.selectedRangeBefore,
                selectedRangeNow: currentRange,
                selectedText: original
            ) {
                Log.event("replace(selection): captured native selection changed or became unverifiable; clipboard fallback")
                ClipboardService.writeString(corrected)
                return continuityFailure
            }
            guard let reconstructed = Self.expectedValueAfterSelectionReplacement(
                valueBefore: pending.valueBefore,
                selectedRange: pending.selectedRangeBefore,
                selectedText: original,
                corrected: corrected
            ) else {
                Log.event("replace(selection): could not reconstruct exact native result; clipboard fallback")
                ClipboardService.writeString(corrected)
                return .copiedToClipboardFallback
            }
            expectedAfter = reconstructed
            ClipboardService.writeString(corrected)
            beanClipboardChangeCount = ClipboardService.changeCount
            ClipboardService.simulatePaste()
        case .clipboardExact:
            // Slack/Electron can expose the focused element and value while
            // withholding AXSelectedTextRange, or no AX element at all. Copy
            // the live selection again and require an exact match immediately
            // before pasting; this also detects a moved caret/selection.
            let attempt = await guardedClipboardPaste(
                expected: original,
                corrected: corrected,
                selectAll: false,
                pending: pending,
                destination: .selectedText
            )
            clipboardToRestore = attempt.clipboardToRestore
            if let continuityFailure = attempt.failure {
                Log.event("replace(selection): clipboard revalidation failed; preserving clipboard for recovery")
                return continuityFailure
            }
            guard let ownedChangeCount = attempt.beanClipboardChangeCount else {
                return .clipboardPreservedRecoveryRequired
            }
            Log.event("replace(selection): limited-AX selection revalidated; sending unconfirmed")
            expectedAfter = nil
            beanClipboardChangeCount = ownedChangeCount
        case .unsupported:
            Log.event("replace(selection): native selection range unavailable; clipboard fallback")
            ClipboardService.writeString(corrected)
            return .copiedToClipboardFallback
        }

        await Task.pause(Timing.afterPaste)

        let afterValue: String?
        if let target = pending.focusedElement, targetsMatch {
            afterValue = AccessibilityService.value(of: target)
        } else {
            afterValue = AccessibilityService.readFocusedValue()
        }
        let result = Self.verificationResult(
            after: afterValue,
            valueBefore: pending.valueBefore,
            expectedAfter: expectedAfter
        )
        return await finishClipboard(
            for: result,
            saved: clipboardToRestore,
            beanClipboardChangeCount: beanClipboardChangeCount
        )
    }

    // MARK: - Focused-field replacement

    private func replaceFocusedField(corrected: String, pending: Pending) async -> ReplacementResult {
        guard let target = pending.focusedElement else {
            if pending.allowsAXFreeFullFieldPaste {
                return await replaceSlackFieldWithoutAX(corrected: corrected, pending: pending)
            }
            Log.event("replace(field): no saved target; clipboard fallback")
            writeFallbackCorrection(corrected, pending: pending)
            return .copiedToClipboardFallback
        }

        // Preview/menu UI can temporarily own focus. Restore the source app, let
        // it reinstate its field, and only then perform the same-element guard.
        guard await reactivateAndConfirm(pending.targetApp) else {
            Log.event("replace(field): source app not frontmost; clipboard fallback")
            writeFallbackCorrection(corrected, pending: pending)
            return .copiedToClipboardFallback
        }
        guard let app = pending.targetApp,
              let current = AccessibilityService.focusedField(in: app)?.element,
              AccessibilityService.isSameElement(current, target) else {
            Log.event("replace(field): target focus not restored; clipboard fallback")
            writeFallbackCorrection(corrected, pending: pending)
            return .copiedToClipboardFallback
        }

        var clipboardToRestore = clipboardSnapshotForTemporaryWrite(pending)
        self.pending?.savedClipboard = clipboardToRestore

        // Stale guard: if the field's text changed since we acquired it (e.g.
        // the user kept typing during a preview), don't overwrite their newer
        // text — leave the result on the clipboard instead.
        if let continuityFailure = Self.targetContinuityFailure(
            valueWasReadable: pending.fieldValueReadable,
            valueBefore: pending.valueBefore,
            valueNow: AccessibilityService.value(of: target)
        ) {
            Log.event("replace(field): field changed or became unverifiable since acquire; clipboard fallback")
            ClipboardService.writeString(corrected)
            return continuityFailure
        }

        if pending.acquiredViaCmdA {
            guard let capturedDraft = pending.valueBefore else {
                Log.event("replace(field): copied draft baseline missing; clipboard fallback")
                ClipboardService.writeString(corrected)
                return .copiedToClipboardFallback
            }
            let attempt = await guardedClipboardPaste(
                expected: capturedDraft,
                corrected: corrected,
                selectAll: true,
                pending: pending,
                destination: .focusedField
            )
            clipboardToRestore = attempt.clipboardToRestore
            if let continuityFailure = attempt.failure {
                Log.event("replace(field): copied draft changed or became unverifiable; preserving clipboard for recovery")
                return continuityFailure
            }
            guard let beanClipboardChangeCount = attempt.beanClipboardChangeCount else {
                return .clipboardPreservedRecoveryRequired
            }
            await Task.pause(Timing.afterPaste)
            let result = Self.verificationResult(
                after: AccessibilityService.value(of: target),
                valueBefore: pending.valueBefore,
                expectedAfter: corrected
            )
            return await finishClipboard(
                for: result,
                saved: clipboardToRestore,
                beanClipboardChangeCount: beanClipboardChangeCount
            )
        }

        // 1. Prefer a direct AX value write when the element supports it.
        if pending.valueSettable && !pending.acquiredViaCmdA {
            if AccessibilityService.setValue(corrected, on: target) {
                await Task.pause(Timing.afterActivate)
                if let after = AccessibilityService.value(of: target),
                   after == corrected {
                    Log.event("replace(field): AX setValue confirmed")
                    // A Cmd+A acquisition may have used the clipboard even
                    // though this direct write did not. Restore it only while
                    // that acquisition copy is still Bean-owned.
                    Self.restoreClipboardIfOwned(
                        pending.savedClipboard,
                        beanOwnedChangeCount: pending.clipboardOwnershipChangeCount
                    )
                    return .replacedConfirmed
                }
                Log.event("replace(field): AX setValue unverified; trying paste")
            } else {
                Log.event("replace(field): AX setValue failed; trying paste")
            }
        }

        // 2. Cmd+A + paste fallback (select the whole field, then replace).
        // A failed/unverified direct AX attempt awaited before reaching the
        // paste fallback, so promote any user copy made during that wait.
        clipboardToRestore = clipboardSnapshotForTemporaryWrite(pending)
        self.pending?.savedClipboard = clipboardToRestore
        ClipboardService.writeString(corrected)
        let beanClipboardChangeCount = ClipboardService.changeCount
        await Task.pause(Timing.afterActivate)
        ClipboardService.simulateSelectAll()
        await Task.pause(Timing.afterActivate)

        let clipboardStillOwned = Self.clipboardIsStillOwned(
            beanOwnedChangeCount: beanClipboardChangeCount,
            currentChangeCount: ClipboardService.changeCount
        )
        guard clipboardStillOwned else {
            Log.event("replace(field): user clipboard changed before paste; preserving it")
            return .clipboardPreservedRecoveryRequired
        }
        guard let current = AccessibilityService.focusedField(in: app)?.element,
              AccessibilityService.isSameElement(current, target) else {
            Log.event("replace(field): focus moved before paste; clipboard fallback")
            return .copiedToClipboardFallback
        }
        if let continuityFailure = Self.targetContinuityFailure(
            valueWasReadable: pending.fieldValueReadable,
            valueBefore: pending.valueBefore,
            valueNow: AccessibilityService.value(of: target)
        ) {
            Log.event("replace(field): field changed before paste; clipboard fallback")
            return continuityFailure
        }
        ClipboardService.simulatePaste()
        await Task.pause(Timing.afterPaste)

        let result = Self.verificationResult(
            after: AccessibilityService.value(of: target),
            valueBefore: pending.valueBefore,
            expectedAfter: corrected
        )
        return await finishClipboard(
            for: result,
            saved: clipboardToRestore,
            beanClipboardChangeCount: beanClipboardChangeCount
        )
    }

    private func replaceSlackFieldWithoutAX(corrected: String, pending: Pending) async -> ReplacementResult {
        guard await reactivateAndConfirm(pending.targetApp) else {
            Log.event("replace(field): Slack source app not frontmost; clipboard fallback")
            writeFallbackCorrection(corrected, pending: pending)
            return .copiedToClipboardFallback
        }
        var clipboardToRestore = clipboardSnapshotForTemporaryWrite(pending)
        self.pending?.savedClipboard = clipboardToRestore
        guard let capturedDraft = pending.valueBefore else {
            Log.event("replace(field): Slack copied draft baseline missing; clipboard fallback")
            ClipboardService.writeString(corrected)
            return .copiedToClipboardFallback
        }
        let attempt = await guardedClipboardPaste(
            expected: capturedDraft,
            corrected: corrected,
            selectAll: true,
            pending: pending,
            destination: .slackAXFreeField
        )
        clipboardToRestore = attempt.clipboardToRestore
        if let continuityFailure = attempt.failure {
            Log.event("replace(field): Slack draft changed or became unverifiable; preserving clipboard for recovery")
            return continuityFailure
        }
        guard let beanClipboardChangeCount = attempt.beanClipboardChangeCount else {
            return .clipboardPreservedRecoveryRequired
        }
        await Task.pause(Timing.afterPaste)
        Log.event("replace(field): Slack AX-free paste sent unconfirmed")
        let result: ReplacementResult = .replacementSentUnconfirmed
        return await finishClipboard(
            for: result,
            saved: clipboardToRestore,
            beanClipboardChangeCount: beanClipboardChangeCount
        )
    }

    // MARK: - Verification

    /// Verifies the exact field value expected after a paste. A substring match
    /// is insufficient because the corrected text may already exist elsewhere
    /// in the field, and trimming would hide whitespace-loss bugs.
    nonisolated static func verificationResult(
        after: String?,
        valueBefore: String?,
        expectedAfter: String?
    ) -> ReplacementResult {
        guard let after else { return .replacementSentUnconfirmed }
        if let valueBefore, after == valueBefore {
            return .copiedToClipboardFallback
        }
        guard let expectedAfter else { return .replacementSentUnconfirmed }
        return after == expectedAfter ? .replacedConfirmed : .replacementSentUnconfirmed
    }

    enum SelectionValidationStrategy: Equatable {
        case nativeRange
        case clipboardExact
        case unsupported
    }

    /// Chooses the strongest available selected-text continuity proof. Native
    /// apps must provide a stable non-empty AX range. Electron may fall back to
    /// an exact live clipboard recopy because its accessibility tree commonly
    /// omits AXSelectedTextRange even for a real editable composer.
    nonisolated static func selectionValidationStrategy(
        capturedTargetExists: Bool,
        isElectronSource: Bool,
        nativeReconstructionAvailable: Bool,
        selectedRangeBefore: NSRange?,
        selectedRangeNow: NSRange?
    ) -> SelectionValidationStrategy {
        let capturedRangeIsValid = selectedRangeBefore.map {
            $0.location != NSNotFound && $0.location >= 0 && $0.length > 0
        } ?? false
        let currentRangeIsValid = selectedRangeNow.map {
            $0.location != NSNotFound && $0.location >= 0 && $0.length > 0
        } ?? false
        if capturedTargetExists && nativeReconstructionAvailable
            && capturedRangeIsValid && currentRangeIsValid {
            return .nativeRange
        }
        if !capturedTargetExists || isElectronSource {
            return .clipboardExact
        }
        return .unsupported
    }

    /// Exact, content-only decision for a guarded Cmd+C revalidation. Any
    /// mismatch/no-proof may instead be a concurrent user Copy, so Bean leaves
    /// the current pasteboard untouched and keeps its correction preview-only.
    nonisolated static func clipboardRevalidationFailure(
        expected: String,
        copied: String?,
        clipboardDidChange: Bool
    ) -> ReplacementResult? {
        guard clipboardDidChange, let copied, copied == expected else {
            return .clipboardPreservedRecoveryRequired
        }
        return nil
    }

    /// A native target must remain the same. The sole missing-target exception
    /// is an Electron capture that will still require an exact live Cmd+C proof
    /// before paste; a different live target is never accepted.
    nonisolated static func selectionFocusContinuityFailure(
        capturedTargetExists: Bool,
        currentTargetExists: Bool,
        targetsMatch: Bool,
        allowsMissingCurrentTargetForExactElectronRecopy: Bool = false
    ) -> ReplacementResult? {
        guard capturedTargetExists else { return nil }
        if currentTargetExists { return targetsMatch ? nil : .copiedToClipboardFallback }
        return allowsMissingCurrentTargetForExactElectronRecopy
            ? nil
            : .copiedToClipboardFallback
    }

    /// Reconstructs a native selected-text edit using Cocoa's UTF-16 range
    /// semantics. The selected substring must exactly equal the text Bean copied.
    nonisolated static func expectedValueAfterSelectionReplacement(
        valueBefore: String?,
        selectedRange: NSRange?,
        selectedText: String,
        corrected: String
    ) -> String? {
        guard let valueBefore, let selectedRange,
              selectedRange.location != NSNotFound,
              selectedRange.location >= 0,
              selectedRange.length > 0 else { return nil }
        let value = valueBefore as NSString
        guard selectedRange.location <= value.length,
              selectedRange.length <= value.length - selectedRange.location,
              value.substring(with: selectedRange) == selectedText else { return nil }
        return value.replacingCharacters(in: selectedRange, with: corrected)
    }

    /// Native selected text requires a valid, non-empty captured range and the
    /// same live value/range before Bean may paste.
    nonisolated static func nativeSelectionContinuityFailure(
        valueBefore: String?,
        valueNow: String?,
        selectedRangeBefore: NSRange?,
        selectedRangeNow: NSRange?,
        selectedText: String
    ) -> ReplacementResult? {
        guard expectedValueAfterSelectionReplacement(
            valueBefore: valueBefore,
            selectedRange: selectedRangeBefore,
            selectedText: selectedText,
            corrected: selectedText
        ) != nil else {
            return .copiedToClipboardFallback
        }
        guard let valueBefore, let valueNow,
              let selectedRangeBefore, let selectedRangeNow else {
            return .copiedToClipboardFallback
        }
        if valueNow != valueBefore || selectedRangeNow != selectedRangeBefore {
            return .staleCopiedToClipboard
        }
        return nil
    }

    /// Returns the fail-closed outcome for a captured native whole-field target,
    /// or nil when its readable value is unchanged.
    nonisolated static func targetContinuityFailure(
        valueWasReadable: Bool,
        valueBefore: String?,
        valueNow: String?
    ) -> ReplacementResult? {
        if valueWasReadable, let valueBefore {
            guard let valueNow else { return .copiedToClipboardFallback }
            if valueNow != valueBefore { return .staleCopiedToClipboard }
        }
        return nil
    }

    // MARK: - Helpers

    /// Captures the newest pasteboard immediately before an early fallback
    /// replaces it with Bean's correction. This second promotion is necessary
    /// because app activation can await, giving the user time to copy something
    /// newer than the snapshot taken at Replace start. Guarded Cmd+C failures
    /// never call this helper; they preserve the current pasteboard untouched.
    private func writeFallbackCorrection(_ corrected: String, pending: Pending) {
        self.pending?.savedClipboard = clipboardSnapshotForTemporaryWrite(pending)
        ClipboardService.writeString(corrected)
    }

    /// Short-lived, content-free observation used only while a guarded
    /// Cmd+A/C/V sequence is in flight. Unlike the product's optional typing
    /// monitors, this proof is always attempted for replacement safety and is
    /// removed immediately after the paste decision.
    private final class GuardedInteractionMonitor {
        private final class LockedRevision: @unchecked Sendable {
            private let lock = NSLock()
            private var value: UInt64 = 0

            var current: UInt64 {
                lock.lock()
                defer { lock.unlock() }
                return value
            }

            func advance() {
                lock.lock()
                value &+= 1
                lock.unlock()
            }
        }

        private let lockedRevision = LockedRevision()
        private var eventMonitor: Any?
        private var activationObserver: NSObjectProtocol?

        init() {
            let state = lockedRevision
            eventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { event in
                if event.type == .keyDown,
                   ClipboardService.isBeanSyntheticKeyboardEvent(event) {
                    return
                }
                state.advance()
            }
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: nil
            ) { _ in
                state.advance()
            }
        }

        var isAvailable: Bool {
            eventMonitor != nil && activationObserver != nil
        }

        var revision: UInt64 { lockedRevision.current }

        func stop() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            if let activationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
                self.activationObserver = nil
            }
        }
    }

    struct GuardedClipboardPasteAttempt {
        let failure: ReplacementResult?
        let clipboardToRestore: ClipboardService.Snapshot
        let beanClipboardChangeCount: Int?
    }

    enum GuardedClipboardCheckPoint {
        case beforeSelection
        case beforeCopy
        case beforePaste
    }

    struct GuardedClipboardPasteEffects {
        let captureDestinationRevision: () -> UInt64
        let destinationIsValid: (UInt64, GuardedClipboardCheckPoint) -> Bool
        let simulateSelectAll: () -> Void
        let pauseAfterSelectAll: () async -> Void
        let snapshotClipboard: () -> ClipboardService.Snapshot
        let promoteSnapshot: (ClipboardService.Snapshot) -> Void
        let changeCount: () -> Int
        let simulateCopy: () -> Void
        let pauseAfterCopy: () async -> Void
        let readString: () -> String?
        let writeCorrection: (String) -> Void
        let simulatePaste: () -> Void
    }

    /// Owns the complete guarded clipboard sequence so there is no await
    /// between the final source/destination proof and Bean's correction write
    /// or paste. The injected effects are also the deterministic regression
    /// seam for focus/app-loss races.
    static func runGuardedClipboardPaste(
        expected: String,
        corrected: String,
        selectAll: Bool,
        effects: GuardedClipboardPasteEffects
    ) async -> GuardedClipboardPasteAttempt {
        let destinationRevision = effects.captureDestinationRevision()

        // Refuse even synthetic selection/copy if the original destination is
        // already gone when this production sequence starts.
        guard effects.destinationIsValid(destinationRevision, .beforeSelection) else {
            let snapshot = effects.snapshotClipboard()
            effects.promoteSnapshot(snapshot)
            return GuardedClipboardPasteAttempt(
                failure: .clipboardPreservedRecoveryRequired,
                clipboardToRestore: snapshot,
                beanClipboardChangeCount: nil
            )
        }

        if selectAll {
            effects.simulateSelectAll()
            await effects.pauseAfterSelectAll()
        }
        // Select All itself needs a settle delay. Promote any user Copy made
        // during that delay before Bean's Cmd+C temporarily replaces it.
        let clipboardToRestore = effects.snapshotClipboard()
        effects.promoteSnapshot(clipboardToRestore)

        // A focus/app change during Select All must stop before Cmd+C.
        guard effects.destinationIsValid(destinationRevision, .beforeCopy) else {
            return GuardedClipboardPasteAttempt(
                failure: .clipboardPreservedRecoveryRequired,
                clipboardToRestore: clipboardToRestore,
                beanClipboardChangeCount: nil
            )
        }

        let preCount = effects.changeCount()
        effects.simulateCopy()
        await effects.pauseAfterCopy()

        if let failure = clipboardRevalidationFailure(
            expected: expected,
            copied: effects.readString(),
            clipboardDidChange: effects.changeCount() != preCount
        ) {
            return GuardedClipboardPasteAttempt(
                failure: failure,
                clipboardToRestore: clipboardToRestore,
                beanClipboardChangeCount: nil
            )
        }

        // This is deliberately the last operation before the write and paste.
        // With MainActor isolation and no await below, focus cannot interleave.
        guard effects.destinationIsValid(destinationRevision, .beforePaste) else {
            return GuardedClipboardPasteAttempt(
                failure: .clipboardPreservedRecoveryRequired,
                clipboardToRestore: clipboardToRestore,
                beanClipboardChangeCount: nil
            )
        }

        effects.writeCorrection(corrected)
        let beanClipboardChangeCount = effects.changeCount()
        effects.simulatePaste()
        return GuardedClipboardPasteAttempt(
            failure: nil,
            clipboardToRestore: clipboardToRestore,
            beanClipboardChangeCount: beanClipboardChangeCount
        )
    }

    private enum GuardedDestinationProof {
        case selectedText
        case focusedField
        case slackAXFreeField
    }

    private func guardedClipboardPaste(
        expected: String,
        corrected: String,
        selectAll: Bool,
        pending: Pending,
        destination: GuardedDestinationProof
    ) async -> GuardedClipboardPasteAttempt {
        let interactionGuard = GuardedInteractionMonitor()
        defer { interactionGuard.stop() }
        return await Self.runGuardedClipboardPaste(
            expected: expected,
            corrected: corrected,
            selectAll: selectAll,
            effects: GuardedClipboardPasteEffects(
                captureDestinationRevision: {
                    interactionGuard.revision
                },
                destinationIsValid: { [weak self] revision, checkPoint in
                    guard interactionGuard.isAvailable,
                          interactionGuard.revision == revision else { return false }
                    return self?.guardedDestinationIsValid(
                        destination,
                        pending: pending,
                        checkPoint: checkPoint
                    ) == true
                },
                simulateSelectAll: { ClipboardService.simulateSelectAll() },
                pauseAfterSelectAll: { await Task.pause(Timing.afterActivate) },
                snapshotClipboard: { [weak self] in
                    self?.clipboardSnapshotForTemporaryWrite(pending) ?? ClipboardService.snapshot()
                },
                promoteSnapshot: { [weak self] snapshot in
                    self?.pending?.savedClipboard = snapshot
                },
                changeCount: { ClipboardService.changeCount },
                simulateCopy: { ClipboardService.simulateCopy() },
                pauseAfterCopy: { await Task.pause(Timing.afterCopy) },
                readString: { ClipboardService.readString() },
                writeCorrection: { ClipboardService.writeString($0) },
                simulatePaste: { ClipboardService.simulatePaste() }
            )
        )
    }

    private func guardedDestinationIsValid(
        _ destination: GuardedDestinationProof,
        pending: Pending,
        checkPoint: GuardedClipboardCheckPoint
    ) -> Bool {
        guard let app = pending.targetApp,
              !app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return false
        }

        switch destination {
        case .selectedText:
            if let target = pending.focusedElement {
                if let current = AccessibilityService.focusedField(in: app)?.element {
                    return AccessibilityService.isSameElement(current, target)
                }
                if checkPoint != .beforePaste {
                    return AppCategory.isElectron(app.bundleIdentifier)
                }
            }
            guard checkPoint == .beforePaste else { return true }
            return slackAXFreeDestinationIsValid(
                app: app,
                anchor: pending.slackTypingAnchor
            )
        case .focusedField:
            guard let target = pending.focusedElement,
                  let current = AccessibilityService.focusedField(in: app)?.element else {
                return false
            }
            return AccessibilityService.isSameElement(current, target)
        case .slackAXFreeField:
            return slackAXFreeDestinationIsValid(
                app: app,
                anchor: pending.slackTypingAnchor
            )
        }
    }

    private func slackAXFreeDestinationIsValid(
        app: NSRunningApplication,
        anchor: CGPoint?
    ) -> Bool {
        guard let anchor else { return false }
        return ElectronTextFocusEvidence.capturedAnchorRemainsInAppWindow(anchor, for: app)
    }

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
    enum ClipboardCompletion: Equatable {
        case restoreOriginal
        case keepCorrection
        case noAction
    }

    nonisolated static func clipboardCompletion(for result: ReplacementResult) -> ClipboardCompletion {
        switch result {
        case .replacedConfirmed, .replacementSentUnconfirmed:
            return .restoreOriginal
        case .copiedToClipboardFallback, .staleCopiedToClipboard:
            return .keepCorrection
        case .clipboardPreservedRecoveryRequired, .noChangesNeeded, .failed:
            return .noAction
        }
    }

    /// A failed paste may normally leave Bean's temporary correction on the
    /// clipboard. If the pasteboard changed meanwhile, that content belongs to
    /// the user: preserve it and report that recovery is preview-only.
    nonisolated static func replacementResultAfterClipboardCompletion(
        _ result: ReplacementResult,
        clipboardStillOwned: Bool
    ) -> ReplacementResult {
        switch result {
        case .copiedToClipboardFallback, .staleCopiedToClipboard:
            return clipboardStillOwned ? result : .clipboardPreservedRecoveryRequired
        default:
            return result
        }
    }

    nonisolated static func clipboardIsStillOwned(
        beanOwnedChangeCount: Int?,
        currentChangeCount: Int
    ) -> Bool {
        guard let beanOwnedChangeCount else { return false }
        return currentChangeCount == beanOwnedChangeCount
    }

    /// If the user copied something after acquisition, that newer clipboard is
    /// what a temporary Bean paste must restore—not the older launch snapshot.
    nonisolated static func clipboardSnapshotToRestore(
        originalSaved: ClipboardService.Snapshot,
        currentSnapshot: ClipboardService.Snapshot,
        acquisitionOwnedChangeCount: Int?,
        currentChangeCount: Int
    ) -> ClipboardService.Snapshot {
        clipboardIsStillOwned(
            beanOwnedChangeCount: acquisitionOwnedChangeCount,
            currentChangeCount: currentChangeCount
        ) ? originalSaved : currentSnapshot
    }

    @discardableResult
    static func restoreClipboardIfOwned(
        _ saved: ClipboardService.Snapshot,
        beanOwnedChangeCount: Int?,
        currentChangeCount: () -> Int = { ClipboardService.changeCount },
        restoreClipboard: (ClipboardService.Snapshot) -> Void = {
            ClipboardService.restore($0)
        }
    ) -> Bool {
        guard clipboardIsStillOwned(
            beanOwnedChangeCount: beanOwnedChangeCount,
            currentChangeCount: currentChangeCount()
        ) else { return false }
        restoreClipboard(saved)
        return true
    }

    static func applyClipboardCompletion(
        _ completion: ClipboardCompletion,
        saved: ClipboardService.Snapshot,
        clipboardStillOwned: Bool = true,
        restoreClipboard: (ClipboardService.Snapshot) -> Void = {
            ClipboardService.restore($0)
        }
    ) {
        switch completion {
        case .restoreOriginal:
            if clipboardStillOwned { restoreClipboard(saved) }
        case .keepCorrection:
            // The temporary pasteboard write already contains the correction.
            // Never write it again here: a newer change belongs to the user.
            break
        case .noAction:
            break
        }
    }

    private func clipboardSnapshotForTemporaryWrite(_ pending: Pending) -> ClipboardService.Snapshot {
        Self.clipboardSnapshotToRestore(
            originalSaved: pending.savedClipboard,
            currentSnapshot: ClipboardService.snapshot(),
            acquisitionOwnedChangeCount: pending.clipboardOwnershipChangeCount,
            currentChangeCount: ClipboardService.changeCount
        )
    }

    private func finishClipboard(
        for result: ReplacementResult,
        saved: ClipboardService.Snapshot,
        beanClipboardChangeCount: Int
    ) async -> ReplacementResult {
        let completion = Self.clipboardCompletion(for: result)
        if case .restoreOriginal = completion {
            await Task.pause(Timing.beforeClipboardRestore)
        }
        let clipboardStillOwned = Self.clipboardIsStillOwned(
            beanOwnedChangeCount: beanClipboardChangeCount,
            currentChangeCount: ClipboardService.changeCount
        )
        Self.applyClipboardCompletion(
            completion,
            saved: saved,
            clipboardStillOwned: clipboardStillOwned
        )
        return Self.replacementResultAfterClipboardCompletion(
            result,
            clipboardStillOwned: clipboardStillOwned
        )
    }
}
