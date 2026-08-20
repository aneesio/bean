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
    private let statusHUD: StatusHUD
    private let selection = TextSelectionService()
    private let transformer = WritingTransformService()
    private let actionMenu = ActionMenuController()

    // `isRunning` guards the acquire+process burst; `sessionActive` guards the
    // interactive menu/preview session so a second trigger can't start mid-flow.
    private var isRunning = false
    private var sessionActive = false

    init(settings: AppSettings, userContent: UserContentStore, statusHUD: StatusHUD) {
        self.settings = settings
        self.userContent = userContent
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

    // MARK: - Entry points

    /// Quick Proofread: existing shortcut + "Proofread Now" menu item.
    func fixSelectedText() {
        guard !isRunning, !sessionActive else { return }
        isRunning = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false }
            guard self.ready() else { return }
            guard let job = await self.acquire() else { return }
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
            guard self.ready() else { return }
            guard let job = await self.acquire() else { return }
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
            guard self.ready() else { return }
            statusHUD.show(.progress, "Opening Bean…")
            guard let job = await self.acquire() else { return }
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

    private func ready() -> Bool {
        guard PermissionService.isAccessibilityGranted else {
            statusHUD.show(.warning, "Accessibility permission required")
            PermissionService.requestAccessibility()
            PermissionService.openAccessibilitySettings()
            return false
        }
        guard !settings.apiKey.isEmpty else {
            statusHUD.show(.warning, "Add an API key in Settings")
            return false
        }
        return true
    }

    private func acquire() async -> Job? {
        let acquisition = await selection.acquire(
            allowFocusedFieldFallback: settings.fixFocusedFieldWhenNoSelection
        )
        switch acquisition {
        case let .acquired(text, mode, context):
            let (leading, core, trailing) = TextNormalizer.split(text)
            return Job(original: text, leading: leading, core: core, trailing: trailing, mode: mode, context: context)
        case .noSelectionOrFocusedField:
            statusHUD.show(.warning, "No text selected or focused text field found")
            return nil
        case .tooLong:
            statusHUD.show(.warning, "Focused text is too long. Select a smaller section.")
            return nil
        case .failed(let reason):
            statusHUD.show(.error, reason)
            return nil
        }
    }

    private func process(job: Job, action: WritingAction, preview: Bool, explicitProfile: UUID?) async {
        // Proofread keeps its local fast-paths (typo / short / clean single word).
        if action == .proofread {
            if TextNormalizer.isSingleWord(job.core),
               let fixedWord = LocalTypoCorrector.correction(for: job.core) {
                Log.event("local: one-word typo corrected")
                let result = await selection.replace(corrected: job.leading + fixedWord + job.trailing,
                                                     original: job.original, mode: job.mode)
                report(result, mode: job.mode)
                diagnostics(job: job, action: action, outLen: fixedWord.count, validator: "local_typo", replacement: resultCode(result))
                sessionActive = false
                return
            }
            if job.core.count < 4 {
                endSession(restore: true, .warning, "Text too short to fix"); return
            }
            if TextNormalizer.isCleanSingleWord(job.core) {
                endSession(restore: true, .info, "No changes needed"); return
            }
        } else if job.core.count < 4 {
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
            endSession(restore: true, .error, error.errorDescription ?? "Could not transform text"); return
        } catch {
            endSession(restore: true, .error, "Could not transform text: \(error.localizedDescription)"); return
        }

        let outCore = TextNormalizer.sanitizeModelOutput(raw, originalCore: job.core)

        if case let .suspicious(reason) = OutputSafetyValidator.validate(input: job.core, output: outCore, action: action) {
            Log.event("validation: blocked (\(reason))")
            diagnostics(job: job, action: action, outLen: outCore.count, validator: reason, replacement: "blocked")
            endSession(restore: true, .warning, "Transformation looked unsafe. Original text was not changed.")
            return
        }

        if outCore == job.core {
            diagnostics(job: job, action: action, outLen: outCore.count, validator: "ok", replacement: "noChangesNeeded")
            endSession(restore: true, .info, "No changes needed")
            return
        }

        if preview {
            presentPreview(job: job, action: action, outCore: outCore, explicitProfile: explicitProfile, personalization: personalization)
        } else {
            let finalText = job.leading + outCore + job.trailing
            let result = await selection.replace(corrected: finalText, original: job.original, mode: job.mode)
            report(result, mode: job.mode)
            diagnostics(job: job, action: action, outLen: outCore.count, validator: "ok", replacement: resultCode(result))
            sessionActive = false
        }
    }

    // MARK: - Preview

    private func presentPreview(job: Job, action: WritingAction, outCore: String,
                                explicitProfile: UUID?, personalization: Personalization) {
        statusHUD.show(.info, "Preview ready")
        let model = PreviewModel(actionName: action.displayName, transformedText: outCore)
        model.styleName = personalization.styleName
        model.usedContext = personalization.usedContext
        model.allowsReplace = action.allowsReplaceFromPreview
        model.helperText = action.previewHelperText
        model.onReplace = { [weak self] in self?.previewReplace(job: job, model: model) }
        model.onCopy = { [weak self] in self?.previewCopy(model: model) }
        model.onTryAgain = { [weak self] in self?.previewRetry(job: job, action: action, model: model, explicitProfile: explicitProfile) }
        model.onCancel = { [weak self] in self?.previewCancel() }
        actionMenu.presentPreview(model)
    }

    private func previewReplace(job: Job, model: PreviewModel) {
        let finalText = job.leading + model.transformedText + job.trailing
        Task { [weak self] in
            guard let self else { return }
            let result = await self.selection.replace(corrected: finalText, original: job.original, mode: job.mode)
            self.report(result, mode: job.mode)
            self.diagnostics(job: job, action: nil, outLen: model.transformedText.count, validator: "ok", replacement: self.resultCode(result))
            self.actionMenu.dismissPreview()
            self.sessionActive = false
        }
    }

    private func previewCopy(model: PreviewModel) {
        ClipboardService.writeString(model.transformedText)
        selection.discard() // leave transformed text on the clipboard; don't restore
        actionMenu.dismissPreview()
        sessionActive = false
        statusHUD.show(.success, "Copied")
    }

    private func previewRetry(job: Job, action: WritingAction, model: PreviewModel, explicitProfile: UUID?) {
        model.isRunning = true
        model.errorMessage = nil
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
                if case .suspicious = OutputSafetyValidator.validate(input: job.core, output: outCore, action: action) {
                    model.errorMessage = "That result looked unsafe — try again."
                    return
                }
                model.transformedText = outCore
            } catch {
                model.errorMessage = "Couldn't reach the model. Try again."
            }
        }
    }

    private func previewCancel() {
        actionMenu.dismissPreview()
        endSession(restore: true, .info, "Replacement cancelled")
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

    // MARK: - Diagnostics (text-free)

    private func diagnostics(job: Job, action: WritingAction?, outLen: Int, validator: String, replacement: String) {
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
