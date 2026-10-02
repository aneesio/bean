import AppKit

// High-level capture/replace engine.
//
// ACQUISITION (layered):
//   A. Selected text via AX range or opaque text marker; otherwise guarded
//      clipboard Copy in a proven editable destination.
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
//   - focused field via AX: exact selection + normal Paste to preserve editing
//     notifications and native Undo, with Cmd+A + exact Copy as a fallback.
//   - focused field via Cmd+A fallback: Cmd+A + paste (verify if readable).
//   "Text/Field fixed" is only reported when verified; otherwise "Replacement
//   sent" or the clipboard fallback.
//
// The user's text is never logged or stored.
@MainActor
final class TextSelectionService {

    private let undoStore: ReplacementUndoStore
    private(set) var lastReplacementAttemptedDelivery = false

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

    enum ReplacementStrategy: Equatable {
        case selectedSpan
        case minimalProofread
    }

    /// Content-free diagnostics for acquisition failures. Never retain field
    /// text, titles, clipboard contents, or app identity in this reason.
    enum AcquisitionFailureReason: String {
        case noFocusedEditor
        case secureOrReadOnly
        case noReadableValueOrSelection
        case selectionChanged
        case focusChanged
        case clipboardUnavailable
        case focusedFieldFallbackDisabled
        case inputTooLong
        case preciseParagraphUnavailable
    }

    private(set) var lastAcquisitionFailureReason: AcquisitionFailureReason?

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
        var selectionToRestore: NSRange? = nil
        var allowsEmptyRangeReplacement = false
        var selectionSnapshotBefore: AccessibilityService.TextSelectionSnapshot? = nil
        var deferredSelectionRange: NSRange? = nil
    }

    private var pending: Pending?

    var capturedScopeLabel: String? {
        guard let pending else { return nil }
        if pending.deferredSelectionRange != nil { return "Current paragraph" }
        return pending.mode == .selectedText ? "Selected text" : "Whole field"
    }

    // MARK: - Acquisition

    func acquire(allowFocusedFieldFallback: Bool, preferCurrentParagraph: Bool = false) async -> TextAcquisitionResult {
        lastAcquisitionFailureReason = nil
        let interactionMonitor = GuardedInteractionMonitor()
        let interactionRevision = interactionMonitor.revision
        defer { interactionMonitor.stop() }
        let targetApp = NSWorkspace.shared.frontmostApplication
        let savedClipboard = ClipboardService.snapshot()

        // ---- A. Selected text via AX, then guarded clipboard ---------------
        // Pre-read the focused value now so selection-mode verification has a
        // "before" baseline (the selection lives inside this value).
        let fieldBeforeSelection = AccessibilityService.focusedField()
        let valueBeforeSelection = fieldBeforeSelection?.value
        let rangeBeforeSelection = fieldBeforeSelection.flatMap {
            AccessibilityService.selectedRange(of: $0.element)
        }
        // Never copy a password or a known read-only/non-text control. A
        // native Copy with an empty selection can copy an entire line/document
        // in some apps; the AX caret tells us to skip that ambiguous operation.
        if let fieldBeforeSelection,
           fieldBeforeSelection.isSecure || !fieldBeforeSelection.isEnabled
                || fieldBeforeSelection.isExplicitlyEditable == false {
            return acquisitionFailure(.secureOrReadOnly)
        }
        if let fieldBeforeSelection, !fieldBeforeSelection.isSemanticTextSurface {
            return acquisitionFailure(.noFocusedEditor)
        }
        let selectionSnapshotBefore = fieldBeforeSelection.flatMap { field in
            field.acceptsTextInput ? AccessibilityService.selectionSnapshot(of: field.element) : nil
        }
        if let field = fieldBeforeSelection,
           field.acceptsTextInput,
           let range = rangeBeforeSelection,
           range.location >= 0, range.length > 0,
           let selected = Self.selectedText(value: valueBeforeSelection, range: range)
                ?? AccessibilityService.selectedText(of: field.element),
           (selected as NSString).length == range.length,
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pending = Pending(
                mode: .selectedText, savedClipboard: savedClipboard, targetApp: targetApp,
                focusedElement: field.element, valueSettable: field.isValueSettable,
                fieldValueReadable: valueBeforeSelection != nil, valueBefore: valueBeforeSelection,
                selectedRangeBefore: range, clipboardOwnershipChangeCount: nil,
                keepsFallbackCorrection: false, acquiredViaCmdA: false,
                allowsAXFreeFullFieldPaste: false, slackTypingAnchor: nil,
                selectionSnapshotBefore: nil
            )
            let context = SourceAppContext.current(app: targetApp, field: field, mode: .selectedText)
            return .acquired(text: selected, mode: .selectedText, context: context)
        }

        // WebKit rich editors can expose a genuine selected text-marker range
        // while omitting AXSelectedTextRange. Keep that opaque identity and the
        // full field snapshot; never guess the position of a repeated word.
        if let field = fieldBeforeSelection, field.acceptsTextInput,
           rangeBeforeSelection == nil,
           let snapshot = selectionSnapshotBefore, snapshot.range == nil,
           let selected = Self.markerOnlySelectedText(
               valueBefore: valueBeforeSelection, selectedText: snapshot.text
           ) {
            pending = Pending(
                mode: .selectedText, savedClipboard: savedClipboard, targetApp: targetApp,
                focusedElement: field.element, valueSettable: field.isValueSettable,
                fieldValueReadable: true, valueBefore: valueBeforeSelection,
                selectedRangeBefore: nil, clipboardOwnershipChangeCount: nil,
                keepsFallbackCorrection: false, acquiredViaCmdA: false,
                allowsAXFreeFullFieldPaste: false, slackTypingAnchor: nil,
                selectionSnapshotBefore: snapshot
            )
            let context = SourceAppContext.current(app: targetApp, field: field, mode: .selectedText)
            return .acquired(text: selected, mode: .selectedText, context: context)
        }

        let preCount = ClipboardService.changeCount
        let attemptSelectionCopy = Self.shouldAttemptSelectionCopy(
            capturedRange: rangeBeforeSelection,
            hasEditableTextTarget: fieldBeforeSelection?.acceptsTextInput == true,
            hasTypingEvidence: ElectronTextFocusEvidence.validAnchor(for: targetApp) != nil
        )
        if attemptSelectionCopy {
            ClipboardService.simulateCopy()
            await Task.pause(Timing.afterCopy)
            guard acquisitionTargetIsCurrent(app: targetApp, element: fieldBeforeSelection?.element) else {
                return acquisitionFailure(.focusChanged)
            }
            guard !interactionMonitor.isAvailable || interactionMonitor.revision == interactionRevision
            else { return acquisitionFailure(.selectionChanged) }
        }

        let postSelectionCopyCount = ClipboardService.changeCount
        if postSelectionCopyCount != preCount,
           let copied = ClipboardService.readString(),
           !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Genuine selection.
            let field = fieldBeforeSelection ?? AccessibilityService.focusedField()
            Self.restoreClipboardIfOwned(savedClipboard, beanOwnedChangeCount: postSelectionCopyCount)
            pending = Pending(
                mode: .selectedText,
                savedClipboard: savedClipboard,
                targetApp: targetApp,
                focusedElement: field?.element,
                valueSettable: field?.isValueSettable ?? false,
                fieldValueReadable: valueBeforeSelection != nil,
                valueBefore: valueBeforeSelection,
                selectedRangeBefore: rangeBeforeSelection,
                clipboardOwnershipChangeCount: nil,
                keepsFallbackCorrection: false,
                acquiredViaCmdA: false,
                allowsAXFreeFullFieldPaste: false,
                slackTypingAnchor: ElectronTextFocusEvidence.validAnchor(for: targetApp),
                selectionSnapshotBefore: rangeBeforeSelection == nil && valueBeforeSelection != nil
                    && selectionSnapshotBefore?.range == nil
                    && Self.exactTextMatches(selectionSnapshotBefore?.text, copied)
                    ? selectionSnapshotBefore : nil
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
            return acquisitionFailure(.focusedFieldFallbackDisabled)
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
            return acquisitionFailure(.noFocusedEditor)
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
            return acquisitionFailure(.secureOrReadOnly)
        }

        let electronTextSurface = AppCategory.isElectron(targetApp?.bundleIdentifier)
            && field.isSemanticTextSurface
        if let value = field.value,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           field.acceptsTextInput || electronTextSurface {
            if preferCurrentParagraph, value.contains(where: { $0.isNewline }) {
                guard let caret = AccessibilityService.selectedRange(of: field.element),
                      AccessibilityService.isSelectedRangeSettable(field.element),
                      let paragraph = NativeActionScope.paragraphRange(in: value, caret: caret)
                else { return acquisitionFailure(.preciseParagraphUnavailable) }
                let text = (value as NSString).substring(with: paragraph)
                guard text.count <= EngineConfig.maxAutoFieldCharacters else {
                    return acquisitionFailure(.inputTooLong, result: .tooLong)
                }
                // Reading the paragraph does not move the user's caret while
                // a provider works. Exact source/caret proof precedes selection.
                pending = Pending(mode: .selectedText, savedClipboard: savedClipboard,
                    targetApp: targetApp, focusedElement: field.element,
                    valueSettable: field.isValueSettable, fieldValueReadable: true,
                    valueBefore: value, selectedRangeBefore: caret,
                    clipboardOwnershipChangeCount: clipboardOwnershipAfterSelectionAttempt,
                    keepsFallbackCorrection: false, acquiredViaCmdA: false,
                    allowsAXFreeFullFieldPaste: false, slackTypingAnchor: nil,
                    selectionToRestore: caret, deferredSelectionRange: paragraph)
                let context = SourceAppContext.current(app: targetApp, field: field, mode: .selectedText)
                return .acquired(text: text, mode: .selectedText, context: context)
            }
            if value.count > EngineConfig.maxAutoFieldCharacters {
                Log.event("Focused field exceeds length guard")
                return acquisitionFailure(.inputTooLong, result: .tooLong)
            }
            pending = Pending(
                mode: .focusedFieldFullText,
                savedClipboard: savedClipboard,
                targetApp: targetApp,
                focusedElement: field.element,
                valueSettable: field.isValueSettable,
                fieldValueReadable: true,
                valueBefore: value,
                selectedRangeBefore: rangeBeforeSelection,
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
            return acquisitionFailure(.noReadableValueOrSelection)
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
        guard acquisitionTargetIsCurrent(app: targetApp, element: field.element) else {
            return acquisitionFailure(.focusChanged)
        }
        guard !interactionMonitor.isAvailable || interactionMonitor.revision == interactionRevision
        else { return acquisitionFailure(.selectionChanged) }
        ClipboardService.simulateCopy()
        await Task.pause(Timing.afterCopy)
        guard acquisitionTargetIsCurrent(app: targetApp, element: field.element) else {
            return acquisitionFailure(.focusChanged)
        }
        guard !interactionMonitor.isAvailable || interactionMonitor.revision == interactionRevision
        else { return acquisitionFailure(.selectionChanged) }

        let postCountA = ClipboardService.changeCount
        guard postCountA != preCountA,
              let copied = ClipboardService.readString(),
              !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.event("Cmd+A fallback produced no text")
            if postCountA != preCountA {
                Self.restoreClipboardIfOwned(fallbackSavedClipboard, beanOwnedChangeCount: postCountA)
            }
            restoreAcquisitionSelection(rangeBeforeSelection, on: field.element)
            return acquisitionFailure(.clipboardUnavailable)
        }

        if copied.count > EngineConfig.maxAutoFieldCharacters {
            Log.event("Cmd+A focused text exceeds length guard")
            Self.restoreClipboardIfOwned(fallbackSavedClipboard, beanOwnedChangeCount: postCountA)
            restoreAcquisitionSelection(rangeBeforeSelection, on: field.element)
            return acquisitionFailure(.inputTooLong, result: .tooLong)
        }

        Self.restoreClipboardIfOwned(fallbackSavedClipboard, beanOwnedChangeCount: postCountA)
        restoreAcquisitionSelection(rangeBeforeSelection, on: field.element)

        pending = Pending(
            mode: .focusedFieldFullText,
            savedClipboard: fallbackSavedClipboard,
            targetApp: targetApp,
            focusedElement: field.element,
            valueSettable: field.isValueSettable,
            fieldValueReadable: false, // AX value wasn't readable
            valueBefore: copied,
            selectedRangeBefore: rangeBeforeSelection,
            clipboardOwnershipChangeCount: nil,
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
        let interactionMonitor = GuardedInteractionMonitor()
        let interactionRevision = interactionMonitor.revision
        defer { interactionMonitor.stop() }
        guard let typingAnchor = ElectronTextFocusEvidence.validAnchor(for: targetApp) else {
            Log.event("Slack AX-free acquisition lost typing evidence")
            return acquisitionFailure(.noFocusedEditor)
        }
        let preCount = ClipboardService.changeCount
        ClipboardService.simulateSelectAll()
        await Task.pause(Timing.afterActivate)
        guard acquisitionTargetIsCurrent(app: targetApp, element: nil) else {
            return acquisitionFailure(.focusChanged)
        }
        guard !interactionMonitor.isAvailable || interactionMonitor.revision == interactionRevision
        else { return acquisitionFailure(.selectionChanged) }
        ClipboardService.simulateCopy()
        await Task.pause(Timing.afterCopy)
        guard acquisitionTargetIsCurrent(app: targetApp, element: nil) else {
            return acquisitionFailure(.focusChanged)
        }
        guard !interactionMonitor.isAvailable || interactionMonitor.revision == interactionRevision
        else { return acquisitionFailure(.selectionChanged) }

        let postCount = ClipboardService.changeCount
        guard postCount != preCount,
              let copied = ClipboardService.readString(),
              !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.event("Slack AX-free Cmd+A fallback produced no text")
            if postCount != preCount {
                Self.restoreClipboardIfOwned(savedClipboard, beanOwnedChangeCount: postCount)
            }
            ClipboardService.simulateCollapseSelectionToEnd()
            return acquisitionFailure(.clipboardUnavailable)
        }
        guard copied.count <= EngineConfig.maxAutoFieldCharacters else {
            Log.event("Slack AX-free focused text exceeds length guard")
            Self.restoreClipboardIfOwned(savedClipboard, beanOwnedChangeCount: postCount)
            ClipboardService.simulateCollapseSelectionToEnd()
            return acquisitionFailure(.inputTooLong, result: .tooLong)
        }

        Self.restoreClipboardIfOwned(savedClipboard, beanOwnedChangeCount: postCount)
        ClipboardService.simulateCollapseSelectionToEnd()

        pending = Pending(
            mode: .focusedFieldFullText,
            savedClipboard: savedClipboard,
            targetApp: targetApp,
            focusedElement: nil,
            valueSettable: false,
            fieldValueReadable: false,
            valueBefore: copied,
            selectedRangeBefore: nil,
            clipboardOwnershipChangeCount: nil,
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

    /// Applies nonoverlapping original-snapshot spans in one guarded session.
    /// Never broadens a missing range into a whole-document plain-text paste.
    func replaceEdits(app: NSRunningApplication, element: AXUIElement, valueBefore: String,
                      edits: [NativeTextEdit], selectionToRestore: NSRange? = nil,
                      capturedSelection: NSRange? = nil) async -> ReplacementResult {
        lastReplacementAttemptedDelivery = false
        guard let plan = NativeEditPlan.validated(original: valueBefore, edits: edits) else {
            return .failed(reason: "The corrections no longer match this field or change document structure.")
        }
        guard !plan.edits.isEmpty else { return .noChangesNeeded }
        guard await reactivateAndConfirm(app),
              let field = AccessibilityService.focusedField(in: app), field.acceptsTextInput,
              AccessibilityService.isSameElement(field.element, element),
              Self.exactTextMatches(field.value, valueBefore),
              AccessibilityService.isSelectedRangeSettable(element) else {
            return .failed(reason: "This editor cannot safely target the corrections. Select the text and try again.")
        }
        let selection = AccessibilityService.selectedRange(of: element)
        guard let selection else {
            return .failed(reason: "This editor does not expose a precise caret or selection.")
        }
        let monitor = GuardedInteractionMonitor()
        let revision = monitor.revision
        defer { monitor.stop() }
        let savedClipboard = ClipboardService.snapshot()
        let initialClipboardCount = ClipboardService.changeCount
        var ownedClipboardCount: Int?
        let destinationIsValid: () -> Bool = {
            guard !Task.isCancelled,
                  !monitor.isAvailable || monitor.revision == revision,
                  ClipboardService.changeCount == (ownedClipboardCount ?? initialClipboardCount),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  let focused = AccessibilityService.focusedField(in: app), focused.acceptsTextInput,
                  AccessibilityService.isSameElement(focused.element, element) else { return false }
            return true
        }
        let outcome = await NativeEditTransaction.run(plan: plan, capturedSelection: capturedSelection ?? selection,
            effects: .init(destinationIsValid: destinationIsValid,
                readValue: { AccessibilityService.value(of: element) },
                selectedRange: { AccessibilityService.selectedRange(of: element) },
                setSelectedRange: { AccessibilityService.setSelectedRange($0, on: element) },
                sendEdit: { replacement in
                    if replacement.isEmpty { ClipboardService.simulateDelete(to: app.processIdentifier) }
                    else {
                        ClipboardService.writeString(replacement)
                        ownedClipboardCount = ClipboardService.changeCount
                        ClipboardService.simulatePaste(to: app.processIdentifier)
                    }
                },
                verify: { before, expected in
                    if Self.verificationResult(after: AccessibilityService.value(of: element),
                                               valueBefore: before, expectedAfter: expected) == .replacedConfirmed {
                        return .replacedConfirmed
                    }
                    return await Self.verifyReplacement(valueBefore: before, expectedAfter: expected,
                        readValue: { AccessibilityService.value(of: element) }, wait: { await Task.pause($0) })
                },
                readSelectedText: { AccessibilityService.selectedText(of: element) },
                replaceSelectedText: field.isSelectedTextSettable
                    ? { AccessibilityService.setSelectedText($0, on: element) } : nil,
                settleSelection: { await Task.pause(.milliseconds(35)) }))
        lastReplacementAttemptedDelivery = outcome.editWasSent
        if outcome.editWasSent { undoStore.discard() }
        if !outcome.confirmedEdits.isEmpty,
           Self.exactTextMatches(AccessibilityService.value(of: element), outcome.confirmedValue),
           let applied = NativeEditPlan.validated(original: valueBefore, edits: outcome.confirmedEdits),
            Self.exactTextMatches(applied.replacement, outcome.confirmedValue) {
            undoStore.registerConfirmedEdits(app: app, element: element, plan: applied)
            let currentSelection = AccessibilityService.selectedRange(of: element)
            let selectionIsOurs = outcome.lastReplacementRange.map {
                Self.shouldRestoreSelectionAfterPaste(current: currentSelection, replacementRange: $0)
            } == true || (outcome.lastRequestedRange != nil && currentSelection == outcome.lastRequestedRange)
            if destinationIsValid(), selectionIsOurs,
               let mapped = applied.selectionAfterEdits(selectionToRestore ?? selection) {
                AccessibilityService.setSelectedRange(mapped, on: element)
            }
        } else if !outcome.editWasSent, destinationIsValid(),
                  Self.exactTextMatches(AccessibilityService.value(of: element), valueBefore),
                  plan.edits.contains(where: { AccessibilityService.selectedRange(of: element) == $0.range }) {
            AccessibilityService.setSelectedRange(selection, on: element)
        }
        guard let ownedClipboardCount else { return outcome.result }
        // A batch never leaves an individual edit fragment as a recovery
        // clipboard. Restore our temporary write even on a partial failure;
        // concurrent user Copy wins throughout this final consumption window.
        if outcome.result == .replacementSentUnconfirmed {
            await Task.pause(Timing.beforeClipboardRestore)
        }
        Self.restoreClipboardIfOwned(savedClipboard, beanOwnedChangeCount: ownedClipboardCount)
        return outcome.result
    }

    /// Applies a single inline suggestion through the same verified native
    /// editing path as a shortcut. Using a normal paste preserves the target
    /// app's edit notifications and native Undo, including fields whose AX
    /// selected-text attribute is read-only.
    func replaceRange(app: NSRunningApplication, element: AXUIElement,
                      valueBefore: String, range: NSRange, replacement: String,
                      selectionToRestore: NSRange? = nil) async -> ReplacementResult {
        lastReplacementAttemptedDelivery = false
        guard let original = Self.selectedText(value: valueBefore, range: range),
              !original.isEmpty else {
            return .failed(reason: "The suggestion no longer matches this field.")
        }
        if Self.exactTextMatches(original, replacement) { return .noChangesNeeded }
        if AccessibilityService.isSelectedRangeSettable(element) {
            return await replaceEdits(app: app, element: element, valueBefore: valueBefore,
                edits: [NativeTextEdit(range: range, original: original, replacement: replacement)],
                selectionToRestore: selectionToRestore)
        }
        guard await reactivateAndConfirm(app),
              let field = AccessibilityService.focusedField(in: app),
              field.acceptsTextInput,
              AccessibilityService.isSameElement(field.element, element),
              Self.exactTextMatches(field.value, valueBefore) else {
            return .failed(reason: "The field changed. Check the current suggestion again.")
        }
        let priorSelection = selectionToRestore ?? AccessibilityService.selectedRange(of: element)
        let snapshot = ClipboardService.snapshot()
        if AccessibilityService.setSelectedRange(range, on: element),
           AccessibilityService.selectedRange(of: element) == range {
            pending = Pending(
                mode: .selectedText, savedClipboard: snapshot, targetApp: app,
                focusedElement: element, valueSettable: field.isValueSettable,
                fieldValueReadable: true, valueBefore: valueBefore,
                selectedRangeBefore: range, clipboardOwnershipChangeCount: nil,
                keepsFallbackCorrection: false, acquiredViaCmdA: false,
                allowsAXFreeFullFieldPaste: false, slackTypingAnchor: nil,
                selectionToRestore: priorSelection, allowsEmptyRangeReplacement: true
            )
            return await replace(corrected: replacement, original: original, mode: .selectedText)
        }

        // Some editors expose readable text without a writable AX range. A
        // guarded whole-field paste still applies the exact occurrence. It
        // proves Select All copied the complete draft before touching text.
        // A document-style WebArea can also contain rich signatures, links,
        // and attachments. Plain text cannot preserve those outside the issue.
        guard Self.canUseWholeFieldRangeFallback(role: field.role, value: valueBefore) else {
            return .failed(reason: "Bean can’t target this correction safely. Select the text and use the shortcut.")
        }
        guard let expected = Self.expectedValueAfterSelectionReplacement(
            valueBefore: valueBefore, selectedRange: range,
            selectedText: original, corrected: replacement
        ) else { return .failed(reason: "The suggestion no longer matches this field.") }
        pending = Pending(
            mode: .focusedFieldFullText, savedClipboard: snapshot, targetApp: app,
            focusedElement: element, valueSettable: field.isValueSettable,
            fieldValueReadable: true, valueBefore: valueBefore,
            selectedRangeBefore: priorSelection, clipboardOwnershipChangeCount: nil,
            keepsFallbackCorrection: false, acquiredViaCmdA: false,
            allowsAXFreeFullFieldPaste: false, slackTypingAnchor: nil,
            selectionToRestore: priorSelection, allowsEmptyRangeReplacement: true
        )
        let result = await replace(corrected: expected, original: valueBefore, mode: .focusedFieldFullText)
        if result == .replacedConfirmed {
            undoStore.registerConfirmedRange(
                app: app, element: element, original: valueBefore, replacement: expected,
                range: range, originalRangeText: original, replacementRangeText: replacement
            )
        }
        return result
    }

    /// Applies a complete corrected snapshot as surgical spans. Rich document
    /// callers never turn an unavailable range into a whole-document paste.
    func replaceWholeField(app: NSRunningApplication, element: AXUIElement,
                           valueBefore: String, replacement: String,
                           selectionToRestore: NSRange? = nil) async -> ReplacementResult {
        lastReplacementAttemptedDelivery = false
        guard await reactivateAndConfirm(app),
              let field = AccessibilityService.focusedField(in: app),
              field.acceptsTextInput,
              AccessibilityService.isSameElement(field.element, element),
              Self.exactTextMatches(field.value, valueBefore) else {
            return .failed(reason: "The field changed. Bean left the current text intact.")
        }
        pending = Pending(
            mode: .focusedFieldFullText, savedClipboard: ClipboardService.snapshot(), targetApp: app,
            focusedElement: element, valueSettable: field.isValueSettable,
            fieldValueReadable: true, valueBefore: valueBefore,
            selectedRangeBefore: AccessibilityService.selectedRange(of: element),
            clipboardOwnershipChangeCount: nil, keepsFallbackCorrection: false,
            acquiredViaCmdA: false, allowsAXFreeFullFieldPaste: false, slackTypingAnchor: nil,
            selectionToRestore: selectionToRestore, allowsEmptyRangeReplacement: true
        )
        return await replace(corrected: replacement, original: valueBefore, mode: .focusedFieldFullText,
                             strategy: .minimalProofread)
    }

    func replace(corrected: String, original: String, mode: TextInputMode,
                 strategy: ReplacementStrategy = .selectedSpan) async -> ReplacementResult {
        lastReplacementAttemptedDelivery = false
        guard var pending else {
            return .failed(reason: "Internal error: nothing acquired")
        }
        guard mode == pending.mode else {
            cancel()
            return .failed(reason: "The captured field no longer matches this action.")
        }

        let trimmedCorrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCorrected.isEmpty || pending.allowsEmptyRangeReplacement else {
            Log.event("replace: correction was empty")
            Self.restoreClipboardIfOwned(
                pending.savedClipboard,
                beanOwnedChangeCount: pending.clipboardOwnershipChangeCount
            )
            self.pending = nil
            return .failed(reason: "The model returned an empty response")
        }

        if Self.exactTextMatches(corrected, original) {
            Log.event("replace: no changes needed")
            Self.restoreClipboardIfOwned(
                pending.savedClipboard,
                beanOwnedChangeCount: pending.clipboardOwnershipChangeCount
            )
            self.pending = nil
            return .noChangesNeeded
        }

        let role = pending.focusedElement.flatMap {
            AccessibilityService.focusedField(from: $0, includeValue: false)?.role
        }
        let plainFieldSnapshot = pending.valueBefore.map {
            Self.canUseWholeFieldRangeFallback(role: role, value: $0)
                && Self.canUseWholeFieldRangeFallback(role: role, value: corrected)
        } == true
        let useSurgicalEdits = Self.requiresSurgicalEdits(mode: mode, strategy: strategy, role: role,
                                                       valueBefore: pending.valueBefore, corrected: corrected)

        if useSurgicalEdits, mode == .focusedFieldFullText, !plainFieldSnapshot,
           pending.focusedElement == nil || !pending.fieldValueReadable {
            cancel()
            return .failed(reason: "Select the passage first so Bean can proofread without replacing the whole document.")
        }
        if useSurgicalEdits, pending.fieldValueReadable,
           let app = pending.targetApp, let element = pending.focusedElement,
           let before = pending.valueBefore {
            let scope = pending.deferredSelectionRange ?? (mode == .selectedText
                ? pending.selectedRangeBefore
                : NSRange(location: 0, length: (before as NSString).length))
            if let scope, scope.length > 0 || mode == .focusedFieldFullText,
               let captured = NativeEditPlan.sourceText(in: before, range: scope),
               Self.exactTextMatches(captured, original),
               AccessibilityService.isSelectedRangeSettable(element) {
                guard let localPlan = NativeEditPlan.proofread(original: original, corrected: corrected) else {
                    cancel()
                    return .failed(reason: "This change cannot preserve the document safely. Select a smaller passage to replace.")
                }
                let edits = localPlan.edits.map { edit in
                    NativeTextEdit(range: NSRange(location: scope.location + edit.range.location, length: edit.range.length),
                                   original: edit.original, replacement: edit.replacement)
                }
                let result = await replaceEdits(app: app, element: element, valueBefore: before, edits: edits,
                    selectionToRestore: pending.selectionToRestore ?? pending.selectedRangeBefore,
                    capturedSelection: pending.selectedRangeBefore)
                self.pending = nil
                return result
            }
            // An explicit opaque marker selection still supports the proven
            // selected-span Mail path. A plain single-line field also retains
            // its exact Copy/Paste fallback; rich documents never take it.
            let isExplicitMarkerSelection = mode == .selectedText && pending.selectionSnapshotBefore != nil
            let isPlainField = mode == .focusedFieldFullText
                && Self.canUseWholeFieldRangeFallback(role: role, value: before)
                && Self.canUseWholeFieldRangeFallback(role: role, value: corrected)
            guard isExplicitMarkerSelection || isPlainField else {
                cancel()
                return .failed(reason: "This editor cannot safely target the corrections. Select the passage and try again.")
            }
        }

        if let range = pending.deferredSelectionRange {
            guard await reactivateAndConfirm(pending.targetApp), let app = pending.targetApp,
                  let element = pending.focusedElement,
                  let field = AccessibilityService.focusedField(in: app), field.acceptsTextInput,
                  AccessibilityService.isSameElement(field.element, element),
                  Self.exactTextMatches(field.value, pending.valueBefore),
                  AccessibilityService.selectedRange(of: element) == pending.selectedRangeBefore else {
                cancel()
                return .failed(reason: "The paragraph or caret changed. Bean left the current text intact.")
            }
            guard AccessibilityService.setSelectedRange(range, on: element),
                  AccessibilityService.selectedRange(of: element) == range else {
                var temporary = pending
                temporary.selectedRangeBefore = range
                restoreSelectionWithoutEdit(temporary, on: element)
                cancel()
                return .failed(reason: "This editor could not select the exact paragraph. Bean left the text intact.")
            }
            pending.selectedRangeBefore = range
            pending.deferredSelectionRange = nil
            self.pending = pending
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

        if case .replacedConfirmed = result {
            // The latest confirmed edit replaces any older Bean Undo. An
            // opaque selection cannot safely become a whole-field Undo:
            // pasting plain text over the field would erase unrelated rich
            // formatting, links and attachments. The editor's native Undo
            // continues to preserve the complete editing operation.
            undoStore.discard()
        }
        if case .replacedConfirmed = result, mode == .focusedFieldFullText {
            undoStore.registerConfirmedWholeField(
                app: pending.targetApp,
                element: pending.focusedElement,
                original: original,
                replacement: corrected
            )
        } else if case .replacedConfirmed = result, mode == .selectedText,
                  let valueBefore = pending.valueBefore,
                  let range = pending.selectedRangeBefore,
                  let expectedAfter = Self.expectedValueAfterSelectionReplacement(
                    valueBefore: valueBefore, selectedRange: range,
                    selectedText: original, corrected: corrected
                  ) {
            undoStore.registerConfirmedRange(
                app: pending.targetApp, element: pending.focusedElement,
                original: valueBefore, replacement: expectedAfter, range: range,
                originalRangeText: original, replacementRangeText: corrected
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
        if result == .copiedToClipboardFallback || result == .clipboardPreservedRecoveryRequired,
           let element = pending.focusedElement, pending.selectionToRestore != nil {
            restoreSelectionWithoutEdit(pending, on: element)
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
        if let snapshot = pending.selectionSnapshotBefore,
           let target = pending.focusedElement,
           let failure = Self.selectedTextSnapshotContinuityFailure(
               valueBefore: pending.valueBefore,
               valueNow: AccessibilityService.value(of: target),
               selectedTextBefore: snapshot.text,
               selectedTextNow: AccessibilityService.selectedText(of: target),
               selectionIdentityMatches: AccessibilityService.selectionMatches(snapshot, on: target)
           ) {
            Log.event("replace(selection): captured text selection changed; clipboard fallback")
            writeFallbackCorrection(corrected, pending: pending)
            return failure
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
            selectedRangeNow: currentRange,
            allowsExactClipboardFallback: targetsMatch
        )

        let expectedAfter: String?
        var beanClipboardChangeCount: Int?
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
            // Prove the captured range again immediately before the edit. A
            // normal paste lets Cocoa, Chromium and Electron update their own
            // editing model and native Undo history.
            guard Self.exactTextMatches(AccessibilityService.selectedText(of: target), original) else {
                return .failed(reason: "The selected text changed. Bean left the current text intact.")
            }
            if AccessibilityService.isSelectedTextSettable(target) {
                lastReplacementAttemptedDelivery = true
                _ = AccessibilityService.setSelectedText(corrected, on: target)
            } else {
                ClipboardService.writeString(corrected)
                beanClipboardChangeCount = ClipboardService.changeCount
                lastReplacementAttemptedDelivery = true
                if corrected.isEmpty { ClipboardService.simulateDelete(to: pending.targetApp?.processIdentifier) }
                else { ClipboardService.simulatePaste(to: pending.targetApp?.processIdentifier) }
            }
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
            // A marker proves selection identity. Only a unique exact source
            // occurrence can also predict the full field after Paste; repeated
            // text never picks the first occurrence for verification.
            expectedAfter = pending.selectionSnapshotBefore == nil ? nil
                : Self.expectedValueAfterUniqueSelectedTextReplacement(
                    valueBefore: pending.valueBefore, selectedText: original, corrected: corrected
                  )
            Log.event("replace(selection): limited-AX selection revalidated")
            beanClipboardChangeCount = ownedChangeCount
        case .unsupported:
            Log.event("replace(selection): native selection range unavailable; clipboard fallback")
            ClipboardService.writeString(corrected)
            return .copiedToClipboardFallback
        }

        let result = await verifyPaste(pending: pending, expectedAfter: expectedAfter)
        if result == .replacedConfirmed,
           let selection = pending.selectionToRestore,
           let element = pending.focusedElement,
           let range = pending.selectedRangeBefore, let before = pending.valueBefore {
            restoreSelection(selection, afterReplacing: range, with: corrected,
                             originalValue: before, on: element)
        }
        if let beanClipboardChangeCount {
            return await finishClipboard(for: result, saved: clipboardToRestore,
                                         beanClipboardChangeCount: beanClipboardChangeCount)
        }
        Self.restoreClipboardIfOwned(clipboardToRestore, beanOwnedChangeCount: pending.clipboardOwnershipChangeCount)
        return result
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

        guard let capturedDraft = pending.valueBefore else {
            return .failed(reason: "The original field could not be verified.")
        }
        if capturedDraft.isEmpty {
            // Undoing deletion can legitimately restore an empty field. Copy
            // cannot prove an empty selection (many apps leave the clipboard
            // unchanged), but the exact readable empty value already does.
            ClipboardService.writeString(corrected)
            let ownedCount = ClipboardService.changeCount
            lastReplacementAttemptedDelivery = true
            ClipboardService.simulatePaste(to: pending.targetApp?.processIdentifier)
            let result = await verifyPaste(pending: pending, expectedAfter: corrected)
            if result == .replacedConfirmed { restoreWholeFieldSelection(pending, replacement: corrected, on: target) }
            return await finishClipboard(for: result, saved: clipboardToRestore,
                                         beanClipboardChangeCount: ownedCount)
        }
        // Select the field's exact UTF-16 range when AX supports it. Otherwise
        // Cmd+A is accepted only after Cmd+C proves it selected precisely the
        // captured field, preventing a whole-document or page replacement.
        let fullRange = NSRange(location: 0, length: (capturedDraft as NSString).length)
        let attempt = await guardedClipboardPaste(
            expected: capturedDraft, corrected: corrected, selectAll: true,
            pending: pending, destination: .focusedField,
            selecting: AccessibilityService.isSelectedRangeSettable(target) ? fullRange : nil
        )
        clipboardToRestore = attempt.clipboardToRestore
        if let continuityFailure = attempt.failure {
            restoreSelectionWithoutEdit(pending, on: target)
            return continuityFailure
        }
        guard let beanClipboardChangeCount = attempt.beanClipboardChangeCount else {
            restoreSelectionWithoutEdit(pending, on: target)
            return .clipboardPreservedRecoveryRequired
        }
        let result = await verifyPaste(pending: pending, expectedAfter: corrected)
        if result == .replacedConfirmed {
            restoreWholeFieldSelection(pending, replacement: corrected, on: target)
        } else if result == .copiedToClipboardFallback {
            restoreSelectionWithoutEdit(pending, on: target)
        }
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

    /// Editor models can update one or two run-loop turns after Paste. Read
    /// repeatedly within a short deadline instead of treating the first old
    /// value as a failed replacement. Never repeat Paste: that could duplicate
    /// text in an editor whose first paste is merely delayed.
    private func verifyPaste(pending: Pending, expectedAfter: String?) async -> ReplacementResult {
        let polled = await Self.verifyReplacement(
            valueBefore: pending.valueBefore, expectedAfter: expectedAfter,
            readValue: {
                pending.focusedElement.map { AccessibilityService.value(of: $0) }
                    ?? AccessibilityService.readFocusedValue()
            },
            wait: { await Task.pause($0) }
        )
        return Self.postDeliveryVerificationResult(polled)
    }

    static func verifyReplacement(valueBefore: String?, expectedAfter: String?,
                                  readValue: () -> String?,
                                  wait: (Duration) async -> Void) async -> ReplacementResult {
        var result: ReplacementResult = .replacementSentUnconfirmed
        for delay in [Timing.afterPaste, Duration.milliseconds(100), .milliseconds(180)] {
            await wait(delay)
            result = verificationResult(after: readValue(), valueBefore: valueBefore,
                                        expectedAfter: expectedAfter)
            if result == .replacedConfirmed { return result }
        }
        return result
    }

    /// After a command or setter was delivered, unchanged text can still mean
    /// delayed delivery. Never turn that into a clipboard claim or retry.
    nonisolated static func postDeliveryVerificationResult(_ result: ReplacementResult) -> ReplacementResult {
        result == .replacedConfirmed ? .replacedConfirmed : .replacementSentUnconfirmed
    }

    nonisolated static func selectedText(value: String?, range: NSRange?) -> String? {
        guard let value, let range, range.length > 0,
              let stringRange = Range(range, in: value),
              value.indices.contains(stringRange.lowerBound),
              stringRange.upperBound == value.endIndex || value.indices.contains(stringRange.upperBound)
        else { return nil }
        return (value as NSString).substring(with: range)
    }

    /// A marker-only selection is useful only alongside the exact readable
    /// field. A collapsed caret, whitespace-only selection, or selection text
    /// absent from that snapshot must never qualify as captured writing.
    nonisolated static func markerOnlySelectedText(valueBefore: String?, selectedText: String) -> String? {
        guard let valueBefore, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let range = (valueBefore as NSString).range(of: selectedText, options: .literal)
        guard let sourceText = Self.selectedText(value: valueBefore, range: range),
              sourceText.utf16.elementsEqual(selectedText.utf16) else { return nil }
        return selectedText
    }

    /// Opaque markers prove the actual selected span independently of its
    /// position. Keep the full source and selected text exact as well; moving
    /// to another identical word must fail the identity check.
    nonisolated static func selectedTextSnapshotContinuityFailure(
        valueBefore: String?, valueNow: String?, selectedTextBefore: String,
        selectedTextNow: String?, selectionIdentityMatches: Bool
    ) -> ReplacementResult? {
        guard let valueBefore, let valueNow, let selectedTextNow,
              markerOnlySelectedText(valueBefore: valueBefore, selectedText: selectedTextBefore) != nil else {
            return .copiedToClipboardFallback
        }
        if !valueBefore.utf16.elementsEqual(valueNow.utf16)
            || !selectedTextBefore.utf16.elementsEqual(selectedTextNow.utf16) || !selectionIdentityMatches {
            return .staleCopiedToClipboard
        }
        return nil
    }

    /// Predicts a field value for verification only. This never sets a range
    /// or chooses between repeated source occurrences, including overlapping
    /// matches such as "aa" inside "aaa".
    nonisolated static func expectedValueAfterUniqueSelectedTextReplacement(
        valueBefore: String?, selectedText: String, corrected: String
    ) -> String? {
        guard let valueBefore, !selectedText.isEmpty else { return nil }
        let value = valueBefore as NSString
        let range = value.range(of: selectedText, options: .literal)
        guard let sourceText = Self.selectedText(value: valueBefore, range: range),
              sourceText.utf16.elementsEqual(selectedText.utf16) else { return nil }
        let remainderStart = range.location + 1
        let remainder = NSRange(location: remainderStart, length: value.length - remainderStart)
        guard value.range(of: selectedText, options: .literal, range: remainder).location == NSNotFound else { return nil }
        return value.replacingCharacters(in: range, with: corrected)
    }

    /// An empty AX range is a caret, even in editors whose Copy shortcut
    /// silently copies a line. Missing range metadata can use Copy only in a
    /// verified editable field or with recent guarded typing evidence.
    nonisolated static func shouldAttemptSelectionCopy(capturedRange: NSRange?,
                                                       hasEditableTextTarget: Bool,
                                                       hasTypingEvidence: Bool) -> Bool {
        if let capturedRange {
            return capturedRange.location != NSNotFound && capturedRange.location >= 0
                && capturedRange.length > 0 && hasEditableTextTarget
        }
        return hasEditableTextTarget || hasTypingEvidence
    }

    /// A whole-field Paste need not move the caret to the end when a small
    /// edit occurs elsewhere. Find the smallest Character-aligned changed
    /// span and map the original selection around that span in UTF-16 units.
    nonisolated static func selectionAfterWholeFieldReplacement(
        original: String, replacement: String, selection: NSRange
    ) -> NSRange? {
        let before = Array(original)
        let after = Array(replacement)
        var prefix = 0
        while prefix < min(before.count, after.count),
              exactTextMatches(String(before[prefix]), String(after[prefix])) { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              exactTextMatches(String(before[before.count - suffix - 1]),
                               String(after[after.count - suffix - 1])) { suffix += 1 }
        let prefixLength = (String(before.prefix(prefix)) as NSString).length
        let beforeChange = String(before[prefix..<(before.count - suffix)])
        let afterChange = String(after[prefix..<(after.count - suffix)])
        return InlineIssueMapping.selectionAfterReplacing(
            NSRange(location: prefixLength, length: (beforeChange as NSString).length),
            replacementLength: (afterChange as NSString).length, selection: selection,
            originalLength: (original as NSString).length
        )
    }

    /// Verifies the exact field value expected after a paste. A substring match
    /// is insufficient because the corrected text may already exist elsewhere
    /// in the field, and trimming would hide whitespace-loss bugs.
    nonisolated static func verificationResult(
        after: String?,
        valueBefore: String?,
        expectedAfter: String?
    ) -> ReplacementResult {
        guard let after else { return .replacementSentUnconfirmed }
        if let valueBefore, exactTextMatches(after, valueBefore) {
            return .copiedToClipboardFallback
        }
        guard let expectedAfter else { return .replacementSentUnconfirmed }
        return exactTextMatches(after, expectedAfter) ? .replacedConfirmed : .replacementSentUnconfirmed
    }

    /// Accessibility offsets refer to UTF-16 code units. Swift String equality
    /// accepts canonical Unicode equivalents whose offsets can differ, so it
    /// cannot establish an exact captured field or post-edit result.
    nonisolated static func exactTextMatches(_ first: String?, _ second: String?) -> Bool {
        guard let first, let second else { return false }
        return first.utf16.elementsEqual(second.utf16)
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
        selectedRangeNow: NSRange?,
        allowsExactClipboardFallback: Bool = false
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
        if !capturedTargetExists || isElectronSource || allowsExactClipboardFallback {
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
        guard clipboardDidChange, let copied, exactTextMatches(copied, expected) else {
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
              let captured = Self.selectedText(value: valueBefore, range: selectedRange),
              exactTextMatches(captured, selectedText) else { return nil }
        return value.replacingCharacters(in: selectedRange, with: corrected)
    }

    nonisolated static func canUseWholeFieldRangeFallback(role: String?) -> Bool {
        role == "AXTextField"
    }

    nonisolated static func canUseWholeFieldRangeFallback(role: String?, value: String) -> Bool {
        canUseWholeFieldRangeFallback(role: role)
            && !value.contains(where: { $0.isNewline || $0 == "\u{fffc}" })
    }

    /// Explicit selected passages may use a span Paste. Whole fields need
    /// surgical edits unless their role and both snapshots prove plain input.
    nonisolated static func requiresSurgicalEdits(mode: TextInputMode, strategy: ReplacementStrategy,
                                                 role: String?, valueBefore: String?, corrected: String) -> Bool {
        if strategy == .minimalProofread { return true }
        guard mode == .focusedFieldFullText else { return false }
        guard let valueBefore else { return true }
        return !canUseWholeFieldRangeFallback(role: role, value: valueBefore)
            || !canUseWholeFieldRangeFallback(role: role, value: corrected)
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
        if !exactTextMatches(valueNow, valueBefore) || selectedRangeNow != selectedRangeBefore {
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
            if !exactTextMatches(valueNow, valueBefore) { return .staleCopiedToClipboard }
        }
        return nil
    }

    // MARK: - Helpers

    private func acquisitionFailure(_ reason: AcquisitionFailureReason,
                                    result: TextAcquisitionResult = .noSelectionOrFocusedField) -> TextAcquisitionResult {
        lastAcquisitionFailureReason = reason
        return result
    }

    private func acquisitionTargetIsCurrent(app: NSRunningApplication?, element: AXUIElement?) -> Bool {
        guard !Task.isCancelled, let app, !app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return false
        }
        if let element {
            guard let focused = AccessibilityService.focusedField(in: app),
                  focused.acceptsTextInput else { return false }
            return AccessibilityService.isSameElement(focused.element, element)
        }
        return ElectronTextFocusEvidence.validAnchor(for: app) != nil
    }

    private func restoreAcquisitionSelection(_ selection: NSRange?, on element: AXUIElement) {
        if let selection, AccessibilityService.setSelectedRange(selection, on: element) { return }
        ClipboardService.simulateCollapseSelectionToEnd()
    }

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
        destination: GuardedDestinationProof,
        selecting range: NSRange? = nil
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
                    guard !Task.isCancelled,
                          interactionGuard.revision == revision else { return false }
                    // AX focus + readable value + selected range supply the
                    // same continuity proof when macOS denies a global key
                    // monitor. Limited-AX/AX-free targets still require it.
                    guard interactionGuard.isAvailable || self?.hasNativeDestinationProof(pending) == true
                    else { return false }
                    return self?.guardedDestinationIsValid(
                        destination,
                        pending: pending,
                        checkPoint: checkPoint
                    ) == true
                },
                simulateSelectAll: {
                    if let range, let target = pending.focusedElement,
                       AccessibilityService.setSelectedRange(range, on: target) {
                        return
                    }
                    ClipboardService.simulateSelectAll()
                },
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
                simulatePaste: {
                    self.lastReplacementAttemptedDelivery = true
                    if corrected.isEmpty { ClipboardService.simulateDelete(to: pending.targetApp?.processIdentifier) }
                    else { ClipboardService.simulatePaste(to: pending.targetApp?.processIdentifier) }
                }
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
                    guard AccessibilityService.isSameElement(current, target) else { return false }
                    if let snapshot = pending.selectionSnapshotBefore {
                        return Self.selectedTextSnapshotContinuityFailure(
                            valueBefore: pending.valueBefore, valueNow: AccessibilityService.value(of: target),
                            selectedTextBefore: snapshot.text,
                            selectedTextNow: AccessibilityService.selectedText(of: target),
                            selectionIdentityMatches: AccessibilityService.selectionMatches(snapshot, on: target)
                        ) == nil
                    }
                    return true
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
                && Self.targetContinuityFailure(valueWasReadable: pending.fieldValueReadable,
                                                valueBefore: pending.valueBefore,
                                                valueNow: AccessibilityService.value(of: target)) == nil
        case .slackAXFreeField:
            return slackAXFreeDestinationIsValid(
                app: app,
                anchor: pending.slackTypingAnchor
            )
        }
    }

    private func hasNativeDestinationProof(_ pending: Pending) -> Bool {
        guard let app = pending.targetApp, let target = pending.focusedElement,
              let current = AccessibilityService.focusedField(in: app),
              current.acceptsTextInput,
              AccessibilityService.isSameElement(current.element, target),
              let valueBefore = pending.valueBefore,
              Self.exactTextMatches(current.value, valueBefore) else { return false }
        if let snapshot = pending.selectionSnapshotBefore {
            return Self.selectedTextSnapshotContinuityFailure(
                valueBefore: valueBefore, valueNow: current.value, selectedTextBefore: snapshot.text,
                selectedTextNow: AccessibilityService.selectedText(of: target),
                selectionIdentityMatches: AccessibilityService.selectionMatches(snapshot, on: target)
            ) == nil
        }
        return AccessibilityService.selectedRange(of: target) != nil
    }

    private func restoreSelectionWithoutEdit(_ pending: Pending, on element: AXUIElement) {
        guard let before = pending.valueBefore,
              Self.exactTextMatches(AccessibilityService.value(of: element), before),
              AccessibilityService.focusedField().map({ AccessibilityService.isSameElement($0.element, element) }) == true,
              let temporarySelection = pending.mode == .selectedText
                ? pending.selectedRangeBefore
                : NSRange(location: 0, length: (before as NSString).length),
              AccessibilityService.selectedRange(of: element) == temporarySelection,
              let selection = pending.selectionToRestore ?? pending.selectedRangeBefore else { return }
        AccessibilityService.setSelectedRange(selection, on: element)
    }

    private func restoreSelection(_ selection: NSRange?, afterReplacing range: NSRange,
                                  with replacement: String, originalValue: String,
                                  on element: AXUIElement) {
        guard let selection, let original = Self.selectedText(value: originalValue, range: range),
              let expected = Self.expectedValueAfterSelectionReplacement(
                valueBefore: originalValue, selectedRange: range, selectedText: original, corrected: replacement
              ),
              Self.exactTextMatches(AccessibilityService.value(of: element), expected),
              AccessibilityService.focusedField().map({ AccessibilityService.isSameElement($0.element, element) }) == true,
              Self.shouldRestoreSelectionAfterPaste(
                current: AccessibilityService.selectedRange(of: element),
                replacementRange: NSRange(location: range.location, length: (replacement as NSString).length)
              ),
              let mapped = InlineIssueMapping.selectionAfterReplacing(
                range, replacementLength: (replacement as NSString).length,
                selection: selection, originalLength: (originalValue as NSString).length
              ) else { return }
        AccessibilityService.setSelectedRange(mapped, on: element)
    }

    private func restoreWholeFieldSelection(_ pending: Pending, replacement: String, on element: AXUIElement) {
        guard let original = pending.valueBefore,
              let selection = pending.selectionToRestore ?? pending.selectedRangeBefore,
              Self.exactTextMatches(AccessibilityService.value(of: element), replacement),
              AccessibilityService.focusedField().map({ AccessibilityService.isSameElement($0.element, element) }) == true,
              Self.shouldRestoreSelectionAfterPaste(
                current: AccessibilityService.selectedRange(of: element),
                replacementRange: NSRange(location: 0, length: (replacement as NSString).length)
              ),
              let mapped = Self.selectionAfterWholeFieldReplacement(
                original: original, replacement: replacement, selection: selection
              ) else { return }
        AccessibilityService.setSelectedRange(mapped, on: element)
    }

    nonisolated static func shouldRestoreSelectionAfterPaste(current: NSRange?, replacementRange: NSRange) -> Bool {
        guard let current else { return false }
        return current == NSRange(location: NSMaxRange(replacementRange), length: 0)
            || current == replacementRange
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
