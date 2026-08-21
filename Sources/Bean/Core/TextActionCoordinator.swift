import AppKit

// Orchestrates every writing action. Two entry points share one pipeline:
//   • fixSelectedText()  — quick Proofread (existing shortcut / menu item).
//   • showActionMenu()   — acquire text, then present the action menu; rewrite
//                          actions go through a preview before replacing.
//
// Acquisition always happens FIRST (while the user's app is frontmost), so the
// action menu/preview can safely take focus — the replacement pipeline
// re-activates the original app before pasting.
//
// Privacy: user text only flows through here on explicit trigger and is never
// logged or persisted.
@MainActor
final class TextActionCoordinator {
    private let settings: AppSettings
    private let userContent: UserContentStore
    private let history: OperationHistoryStore
    private let undoStore: ReplacementUndoStore
    private let statusHUD: StatusHUD
    private let selection: TextSelectionService
    private let transformer = WritingTransformService()
    private let actionMenu = ActionMenuController()

    // `isRunning` guards the acquire+process burst; `sessionActive` guards the
    // interactive menu/preview session so a second trigger can't start mid-flow.
    private var isRunning = false
    private var sessionActive = false

    init(settings: AppSettings, userContent: UserContentStore,
         history: OperationHistoryStore, undoStore: ReplacementUndoStore,
         statusHUD: StatusHUD) {
        self.settings = settings
        self.userContent = userContent
        self.history = history
        self.undoStore = undoStore
        self.selection = TextSelectionService(undoStore: undoStore)
        self.statusHUD = statusHUD
    }

    /// True while a shortcut/menu/preview flow is mid-operation. Passive
    /// Suggestions checks this so it never collides with an explicit action.
    var isBusy: Bool { isRunning || sessionActive }

    // MARK: - Acquired job

    private struct Job {
        let original: String
        let leading: String
        let core: String
        let trailing: String
        let mode: TextInputMode
        let context: SourceAppContext
    }

    // MARK: - Permissions menu action

    func checkPermissions() {
        if PermissionService.isAccessibilityGranted {
            statusHUD.show(.success, "Accessibility permission granted")
        } else {
            statusHUD.show(.warning, "Accessibility permission required")
            PermissionService.requestAccessibility()
            PermissionService.openAccessibilitySettings()
        }
    }

    /// Reverts only the last confirmed whole-field Bean replacement, and only
    /// while the exact Bean output is still present in that same field.
    func undoLastChange() {
        guard !isRunning, !sessionActive else {
            statusHUD.show(.warning, "Finish the current Bean action before undoing")
            return
        }
        isRunning = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false }
            let startedAt = Date()
            let result = await self.undoStore.undo()
            self.reportUndo(result)
            let app = NSWorkspace.shared.frontmostApplication
            self.history.record(OperationRecord(
                source: .local,
                appName: app?.localizedName,
                appBundleIdentifier: app?.bundleIdentifier,
                appCategory: AppCategory.from(bundleIdentifier: app?.bundleIdentifier).rawValue,
                action: "undo",
                inputMode: "verifiedWholeField",
                inputLength: 0,
                durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
                safetyResult: "exactValueGuard",
                outcome: self.resultCode(result),
                usageEstimated: false
            ))
        }
    }

    // MARK: - Entry points

    /// Quick Proofread: existing shortcut + "Proofread Now" menu item.
    func fixSelectedText() {
        guard !isRunning, !sessionActive else { return }
        isRunning = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false }
            guard self.ready(requestedAction: WritingAction.proofread.rawValue) else { return }
            guard let job = await self.acquire(requestedAction: WritingAction.proofread.rawValue) else { return }
            await self.process(job: job, action: .proofread, preview: false, explicitProfile: nil)
        }
    }

    /// Runs a specific action directly (used by the Bean Bubble mini menu).
    /// Reuses the exact same acquisition/preview/replacement pipeline as the
    /// action menu — no duplicated logic.
    func runAction(_ action: WritingAction) {
        guard !isRunning, !sessionActive else { return }
        isRunning = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false }
            guard self.ready(requestedAction: action.rawValue) else { return }
            guard let job = await self.acquire(requestedAction: action.rawValue) else { return }
            await self.process(job: job, action: action, preview: action.requiresPreview, explicitProfile: nil)
        }
    }

    /// Bean menu: acquire text, then show the action menu.
    func showActionMenu() {
        guard !isRunning, !sessionActive else { return }
        isRunning = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false }
            guard self.ready(requestedAction: "openMenu") else { return }
            statusHUD.show(.progress, "Opening Bean…")
            guard let job = await self.acquire(requestedAction: "openMenu") else { return }
            self.sessionActive = true
            statusHUD.dismiss()
            let profiles = self.userContent.profiles.map { (id: $0.id, name: $0.name) }
            let defaultID = self.userContent.effectiveProfile(explicit: nil, context: job.context).id
            self.actionMenu.presentMenu(
                appName: job.context.appName,
                profiles: profiles,
                defaultProfileID: defaultID,
                onSelect: { [weak self] action, profileID in
                    Task { await self?.process(job: job, action: action, preview: action.requiresPreview, explicitProfile: profileID) }
                },
                onCancel: { [weak self] in self?.endSession(restore: true) }
            )
        }
    }

    // MARK: - Pipeline

    private func ready(requestedAction: String) -> Bool {
        guard PermissionService.isAccessibilityGranted else {
            recordPreflight(action: requestedAction, outcome: "accessibilityPermissionRequired")
            statusHUD.show(.warning, "Accessibility permission required")
            PermissionService.requestAccessibility()
            PermissionService.openAccessibilitySettings()
            return false
        }
        guard !settings.apiKey.isEmpty else {
            recordPreflight(action: requestedAction, outcome: "missingAPIKey")
            statusHUD.show(.warning, "Add an API key in Settings")
            return false
        }
        return true
    }

    private func acquire(requestedAction: String) async -> Job? {
        let acquisition = await selection.acquire(
            allowFocusedFieldFallback: settings.fixFocusedFieldWhenNoSelection
        )
        switch acquisition {
        case let .acquired(text, mode, context):
            let (leading, core, trailing) = TextNormalizer.split(text)
            return Job(original: text, leading: leading, core: core, trailing: trailing, mode: mode, context: context)
        case .noSelectionOrFocusedField:
            recordPreflight(action: requestedAction, outcome: "noSelectionOrFocusedField")
            statusHUD.show(.warning, "No text selected or focused text field found")
            return nil
        case .tooLong:
            recordPreflight(action: requestedAction, outcome: "inputTooLong")
            statusHUD.show(.warning, "Focused text is too long. Select a smaller section.")
            return nil
        case .failed(let reason):
            recordPreflight(action: requestedAction, outcome: "acquisitionFailed")
            statusHUD.show(.error, reason)
            return nil
        }
    }

    private func process(job: Job, action: WritingAction, preview: Bool, explicitProfile: UUID?) async {
        let operationStartedAt = Date()
        // Proofread keeps its local fast-paths (typo / short / clean single word).
        if action == .proofread {
            if TextNormalizer.isSingleWord(job.core),
               let fixedWord = LocalTypoCorrector.correction(for: job.core) {
                Log.event("local: one-word typo corrected")
                let result = await selection.replace(corrected: job.leading + fixedWord + job.trailing,
                                                     original: job.original, mode: job.mode)
                report(result, mode: job.mode)
                diagnostics(job: job, action: action, outLen: fixedWord.count,
                            validator: "local_typo", replacement: resultCode(result),
                            startedAt: operationStartedAt)
                if needsRecovery(result) {
                    presentReplacementRecovery(job: job, action: action, outCore: fixedWord,
                                               result: result, model: nil)
                } else {
                    sessionActive = false
                }
                return
            }
            if job.core.count < 4 {
                diagnostics(job: job, action: action, outLen: 0, validator: "notRun",
                            replacement: "textTooShort", startedAt: operationStartedAt)
                endSession(restore: true, .warning, "Text too short to fix"); return
            }
            if TextNormalizer.isCleanSingleWord(job.core) {
                diagnostics(job: job, action: action, outLen: job.core.count, validator: "localClean",
                            replacement: "noChangesNeeded", startedAt: operationStartedAt)
                endSession(restore: true, .info, "No changes needed"); return
            }
        } else if job.core.count < 4 {
            diagnostics(job: job, action: action, outLen: 0, validator: "notRun",
                        replacement: "textTooShort", startedAt: operationStartedAt)
            endSession(restore: true, .warning, "Text too short to fix"); return
        }

        statusHUD.show(.progress, action == .proofread ? "Fixing…" : "Rewriting…")

        let personalization = userContent.personalization(action: action, context: job.context,
                                                          explicitProfile: explicitProfile, sourceText: job.core)

        let raw: String
        do {
            raw = try await transformer.transform(
                text: job.core, action: action, context: job.context,
                personalization: personalization.systemBlock,
                extraContextLines: personalization.contextLines,
                provider: settings.provider, model: settings.model,
                apiKey: settings.apiKey, timeout: settings.timeoutSeconds
            )
        } catch let error as LLMError {
            diagnostics(job: job, action: action, outLen: 0, validator: "providerError",
                        replacement: providerErrorCode(error), startedAt: operationStartedAt)
            endSession(restore: true, .error, error.errorDescription ?? "Could not transform text"); return
        } catch {
            diagnostics(job: job, action: action, outLen: 0, validator: "providerError",
                        replacement: "unexpectedProviderError", startedAt: operationStartedAt)
            endSession(restore: true, .error, "Could not transform text: \(error.localizedDescription)"); return
        }

        let outCore = TextNormalizer.sanitizeModelOutput(raw, originalCore: job.core)

        if case let .suspicious(reason) = OutputSafetyValidator.validate(input: job.core, output: outCore, action: action) {
            switch OutputSafetyValidator.disposition(for: reason) {
            case .hardBlock:
                Log.event("validation: blocked (\(reason))")
                diagnostics(job: job, action: action, outLen: outCore.count, validator: reason,
                            replacement: "blocked", startedAt: operationStartedAt)
                endSession(restore: true, .warning, "Transformation was blocked because it contained unsafe model output.")
            case .reviewRequired:
                Log.event("validation: review required (\(reason))")
                diagnostics(job: job, action: action, outLen: outCore.count, validator: reason,
                            replacement: "reviewRequired", startedAt: operationStartedAt)
                presentPreview(job: job, action: action, outCore: outCore,
                               explicitProfile: explicitProfile, personalization: personalization,
                               reviewReason: reason)
            }
            return
        }

        if outCore == job.core {
            diagnostics(job: job, action: action, outLen: outCore.count, validator: "ok",
                        replacement: "noChangesNeeded", startedAt: operationStartedAt)
            endSession(restore: true, .info, "No changes needed")
            return
        }

        if preview {
            diagnostics(job: job, action: action, outLen: outCore.count, validator: "ok",
                        replacement: "previewReady", startedAt: operationStartedAt)
            presentPreview(job: job, action: action, outCore: outCore, explicitProfile: explicitProfile, personalization: personalization)
        } else {
            let finalText = job.leading + outCore + job.trailing
            let result = await selection.replace(corrected: finalText, original: job.original, mode: job.mode)
            report(result, mode: job.mode)
            diagnostics(job: job, action: action, outLen: outCore.count, validator: "ok",
                        replacement: resultCode(result), startedAt: operationStartedAt)
            if needsRecovery(result) {
                presentReplacementRecovery(job: job, action: action, outCore: outCore,
                                           result: result, model: nil)
            } else {
                sessionActive = false
            }
        }
    }

    // MARK: - Preview

    private func presentPreview(job: Job, action: WritingAction, outCore: String,
                                explicitProfile: UUID?, personalization: Personalization,
                                reviewReason: String? = nil) {
        sessionActive = true
        statusHUD.show(.info, "Preview ready")
        let model = PreviewModel(actionName: action.displayName, transformedText: outCore,
                                 originalText: job.core)
        model.styleName = personalization.styleName
        model.usedContext = personalization.usedContext
        model.allowsReplace = action.allowsReplaceFromPreview
        model.helperText = action.previewHelperText
        if let reviewReason {
            model.reviewWarning = OutputSafetyValidator.reviewMessage(for: reviewReason)
        }
        model.onReplace = { [weak self] in self?.previewReplace(job: job, action: action, model: model) }
        model.onCopy = { [weak self] in self?.previewCopy(job: job, action: action, model: model) }
        model.onTryAgain = { [weak self] in self?.previewRetry(job: job, action: action, model: model, explicitProfile: explicitProfile) }
        model.onCancel = { [weak self] in self?.previewCancel(job: job, action: action) }
        actionMenu.presentPreview(model)
    }

    private func previewReplace(job: Job, action: WritingAction, model: PreviewModel) {
        model.isRunning = true
        model.errorMessage = nil
        let startedAt = Date()
        let finalText = job.leading + model.transformedText + job.trailing
        Task { [weak self] in
            guard let self else { return }
            let result = await self.selection.replace(corrected: finalText, original: job.original, mode: job.mode)
            model.isRunning = false
            self.report(result, mode: job.mode)
            self.diagnostics(job: job, action: action, outLen: model.transformedText.count,
                             validator: "previewApproved", replacement: self.resultCode(result),
                             startedAt: startedAt)
            if self.needsRecovery(result) {
                self.presentReplacementRecovery(job: job, action: action,
                                                outCore: model.transformedText,
                                                result: result, model: model)
            } else if case let .failed(reason) = result {
                model.errorMessage = reason
            } else {
                self.actionMenu.dismissPreview()
                self.sessionActive = false
            }
        }
    }

    private func previewCopy(job: Job, action: WritingAction, model: PreviewModel) {
        ClipboardService.writeString(job.leading + model.transformedText + job.trailing)
        selection.discard() // leave transformed text on the clipboard; don't restore
        actionMenu.dismissPreview()
        sessionActive = false
        diagnostics(job: job, action: action, outLen: model.transformedText.count,
                    validator: model.reviewWarning == nil ? "userApprovedPreview" : "userReviewedWarning",
                    replacement: "copied", startedAt: Date())
        statusHUD.show(.success, "Copied")
    }

    private func previewRetry(job: Job, action: WritingAction, model: PreviewModel, explicitProfile: UUID?) {
        model.isRunning = true
        model.errorMessage = nil
        model.reviewWarning = nil
        Task { [weak self] in
            guard let self else { return }
            defer { model.isRunning = false }
            let personalization = self.userContent.personalization(action: action, context: job.context,
                                                                   explicitProfile: explicitProfile, sourceText: job.core)
            do {
                let raw = try await self.transformer.transform(
                    text: job.core, action: action, context: job.context,
                    personalization: personalization.systemBlock,
                    extraContextLines: personalization.contextLines,
                    provider: self.settings.provider, model: self.settings.model,
                    apiKey: self.settings.apiKey, timeout: self.settings.timeoutSeconds
                )
                let outCore = TextNormalizer.sanitizeModelOutput(raw, originalCore: job.core)
                if case let .suspicious(reason) = OutputSafetyValidator.validate(input: job.core, output: outCore, action: action) {
                    if OutputSafetyValidator.disposition(for: reason) == .hardBlock {
                        model.errorMessage = "That result contained unsafe model output. Try again."
                        return
                    }
                    model.reviewWarning = OutputSafetyValidator.reviewMessage(for: reason)
                }
                model.transformedText = outCore
            } catch {
                model.errorMessage = "Couldn't reach the model. Try again."
            }
        }
    }

    private func previewCancel(job: Job, action: WritingAction) {
        actionMenu.dismissPreview()
        diagnostics(job: job, action: action, outLen: 0, validator: "userDecision",
                    replacement: "cancelled", startedAt: Date())
        endSession(restore: true, .info, "Replacement cancelled")
    }

    private func presentReplacementRecovery(job: Job, action: WritingAction, outCore: String,
                                            result: TextSelectionService.ReplacementResult,
                                            model existingModel: PreviewModel?) {
        sessionActive = true
        let model = existingModel ?? PreviewModel(
            actionName: "Replacement Recovery",
            transformedText: outCore,
            originalText: job.core
        )
        model.isRunning = false
        model.errorMessage = nil
        model.allowsReplace = false
        model.reviewWarning = recoveryMessage(for: result)
        model.helperText = "The suggestion is still available here and on your clipboard."
        model.onCopy = { [weak self] in self?.previewCopy(job: job, action: action, model: model) }
        model.onTryAgain = { [weak self] in self?.previewReplace(job: job, action: action, model: model) }
        model.onCancel = { [weak self] in self?.previewCancel(job: job, action: action) }
        if existingModel == nil { actionMenu.presentPreview(model) }
        statusHUD.show(.warning, "Bean could not verify replacement. Review, retry, or copy.")
    }

    private func needsRecovery(_ result: TextSelectionService.ReplacementResult) -> Bool {
        switch result {
        case .copiedToClipboardFallback, .staleCopiedToClipboard: return true
        default: return false
        }
    }

    private func recoveryMessage(for result: TextSelectionService.ReplacementResult) -> String {
        switch result {
        case .staleCopiedToClipboard:
            return "The field changed after Bean read it, so Bean did not overwrite your newer text."
        default:
            return "Bean could not confirm that the replacement landed. Focus the original field and try again, or copy it."
        }
    }

    // MARK: - Session / reporting

    private func endSession(restore: Bool, _ style: StatusHUD.Style? = nil, _ message: String? = nil) {
        if restore { selection.cancel() }
        sessionActive = false
        if let style, let message { statusHUD.show(style, message) }
    }

    private func report(_ result: TextSelectionService.ReplacementResult, mode: TextInputMode) {
        switch result {
        case .replacedConfirmed:
            statusHUD.show(.success, mode == .focusedFieldFullText ? "Field fixed" : "Text fixed")
        case .replacementSentUnconfirmed:
            statusHUD.show(.info, "Replacement sent")
        case .noChangesNeeded:
            statusHUD.show(.info, "No changes needed")
        case .copiedToClipboardFallback:
            statusHUD.show(.warning, "Could not replace text. Corrected text copied to clipboard.")
        case .staleCopiedToClipboard:
            statusHUD.show(.warning, "Text changed. Copied suggestion to clipboard.")
        case .failed(let reason):
            statusHUD.show(.error, reason)
        }
    }

    private func reportUndo(_ result: TextSelectionService.ReplacementResult) {
        switch result {
        case .replacedConfirmed: statusHUD.show(.success, "Last Bean change undone")
        case .failed(let reason): statusHUD.show(.warning, reason)
        default: statusHUD.show(.warning, "Bean could not safely undo that change")
        }
    }

    // MARK: - Diagnostics (text-free)

    private func diagnostics(job: Job, action: WritingAction?, outLen: Int, validator: String,
                             replacement: String, startedAt: Date) {
        Log.diag([
            "provider": settings.provider.rawValue,
            "app": job.context.appName ?? "unknown",
            "action": action?.rawValue ?? "rewrite",
            "inputMode": job.context.acquisitionMode.rawLabel,
            "inputLength": String(job.core.count),
            "outputLength": String(outLen),
            "validatorResult": validator,
            "replacementResult": replacement
        ])
        let local = validator == "local_typo" || validator == "localClean"
        history.record(OperationRecord(
            source: local ? .local : .manual,
            appName: job.context.appName,
            appBundleIdentifier: job.context.bundleIdentifier,
            appCategory: AppCategory.from(bundleIdentifier: job.context.bundleIdentifier).rawValue,
            action: action?.rawValue ?? "unknown",
            inputMode: job.context.acquisitionMode.rawLabel,
            inputLength: job.core.count,
            outputLength: outLen,
            provider: local ? nil : settings.provider.rawValue,
            model: local ? nil : settings.model,
            durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
            safetyResult: validator,
            outcome: replacement,
            usageEstimated: true
        ))
    }

    private func recordPreflight(action: String, outcome: String) {
        let app = NSWorkspace.shared.frontmostApplication
        history.record(OperationRecord(
            source: .manual,
            appName: app?.localizedName,
            appBundleIdentifier: app?.bundleIdentifier,
            appCategory: AppCategory.from(bundleIdentifier: app?.bundleIdentifier).rawValue,
            action: action,
            inputMode: "notAcquired",
            inputLength: 0,
            provider: settings.provider.rawValue,
            model: settings.model,
            safetyResult: "notRun",
            outcome: outcome,
            usageEstimated: true
        ))
    }

    private func providerErrorCode(_ error: LLMError) -> String {
        switch error {
        case .missingAPIKey: return "missingAPIKey"
        case .invalidAPIKey: return "invalidAPIKey"
        case .network: return "networkError"
        case .timeout: return "timeout"
        case .emptyResponse: return "emptyResponse"
        case .server(let status, _): return "serverError\(status)"
        case .decoding: return "decodingError"
        }
    }

    private func resultCode(_ result: TextSelectionService.ReplacementResult) -> String {
        switch result {
        case .replacedConfirmed: return "replacedConfirmed"
        case .replacementSentUnconfirmed: return "replacementSentUnconfirmed"
        case .copiedToClipboardFallback: return "copiedToClipboardFallback"
        case .staleCopiedToClipboard: return "staleCopiedToClipboard"
        case .noChangesNeeded: return "noChangesNeeded"
        case .failed: return "failed"
        }
    }
}
