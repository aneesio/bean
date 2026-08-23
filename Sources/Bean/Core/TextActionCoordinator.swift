import AppKit

// Orchestrates every writing action. Two entry points share one pipeline:
//   • fixSelectedText()  — deterministic, offline Quick Fix (shortcut/menu).
//   • proofreadWithAI()  — explicit provider-backed proofreading.
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
    private let usageLedger: UsageLedgerStore
    private let undoStore: ReplacementUndoStore
    private let statusHUD: StatusHUD
    private let onShowSettings: () -> Void
    private let selection: TextSelectionService
    private let transformer = WritingTransformService()
    private let actionMenu = ActionMenuController()

    // `isRunning` guards the acquire+process burst; `sessionActive` guards the
    // interactive menu/preview session so a second trigger can't start mid-flow.
    private var isRunning = false
    private var sessionActive = false

    init(settings: AppSettings, userContent: UserContentStore,
         history: OperationHistoryStore, usageLedger: UsageLedgerStore,
         undoStore: ReplacementUndoStore,
         statusHUD: StatusHUD,
         onShowSettings: @escaping () -> Void = {}) {
        self.settings = settings
        self.userContent = userContent
        self.history = history
        self.usageLedger = usageLedger
        self.undoStore = undoStore
        self.selection = TextSelectionService(undoStore: undoStore)
        self.statusHUD = statusHUD
        self.onShowSettings = onShowSettings
    }

    /// True while a shortcut/menu/preview flow is mid-operation. Passive
    /// Suggestions checks this so it never collides with an explicit action.
    var isBusy: Bool { isRunning || sessionActive }

    /// The primary shortcut is a stable privacy contract: it must never begin
    /// using a provider merely because the user added an API key later.
    static let quickFixAction: WritingAction = .localQuickCheck

    /// Manual provider actions share the same bounded input contract as Bean's
    /// automatic/full-field and browser paths. Quick Fix is deliberately
    /// exempt: it is deterministic, local, and cannot spend provider tokens.
    static func exceedsProviderInputLimit(action: WritingAction, text: String) -> Bool {
        action.usesProvider && EngineConfig.exceedsProviderInputLimit(text)
    }

    /// Provider-backed proofreading may replace an explicit selection after
    /// verification, but whole-field AI output always needs user review first.
    static func requiresPreview(for action: WritingAction, mode: TextInputMode) -> Bool {
        action.requiresPreview || (action == .proofread && mode == .focusedFieldFullText)
    }

    /// Plain-language scope shown before the user chooses an action. The menu
    /// must make it clear whether Bean captured an explicit selection or the
    /// entire focused field.
    static func captureLabel(for mode: TextInputMode) -> String {
        switch mode {
        case .selectedText: return "Selected text"
        case .focusedFieldFullText: return "Whole field"
        }
    }

    /// Anything Bean cannot prove landed is unresolved and needs a persistent
    /// recovery surface. Only a confirmed replacement may report success.
    static func requiresReplacementRecovery(_ result: TextSelectionService.ReplacementResult) -> Bool {
        switch result {
        case .replacementSentUnconfirmed, .copiedToClipboardFallback,
             .staleCopiedToClipboard, .clipboardPreservedRecoveryRequired, .failed:
            return true
        case .replacedConfirmed, .noChangesNeeded:
            return false
        }
    }

    // MARK: - Acquired job

    private struct Job {
        let original: String
        let leading: String
        let core: String
        let trailing: String
        let mode: TextInputMode
        let context: SourceAppContext
        let sourceAnchorRect: CGRect?
    }

    // MARK: - Permissions menu action

    func checkPermissions() {
        let sourceAnchorRect = currentSourceNoticeAnchorRect()
        if PermissionService.isAccessibilityGranted {
            statusHUD.showConfirmedSuccess(
                "Accessibility permission granted",
                sourceAnchorRect: sourceAnchorRect
            )
        } else {
            presentAccessibilityNotice(sourceAnchorRect: sourceAnchorRect)
        }
    }

    /// Reverts only the last confirmed whole-field Bean replacement, and only
    /// while the exact Bean output is still present in that same field.
    func undoLastChange() {
        let sourceAnchorRect = currentSourceNoticeAnchorRect()
        guard !isRunning, !sessionActive else {
            statusHUD.showProgress("Bean is already working…",
                                   sourceAppName: NSWorkspace.shared.frontmostApplication?.localizedName,
                                   sourceAnchorRect: sourceAnchorRect)
            return
        }
        isRunning = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false }
            let startedAt = Date()
            let result = await self.undoStore.undo()
            self.reportUndo(result, sourceAnchorRect: sourceAnchorRect)
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

    /// Quick Fix: the primary shortcut and menu command. This path is always
    /// local and never reads provider credentials or sends text to a provider.
    func fixSelectedText() {
        guard beginOperation() else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false }
            let action = Self.quickFixAction
            guard self.ready(requestedAction: action.rawValue, requiresProvider: false) else { return }
            guard let job = await self.acquire(requestedAction: action.rawValue) else { return }
            await self.process(job: job, action: action, preview: false, explicitProfile: nil)
        }
    }

    /// Explicit AI entry point used by the menu bar. Unlike Quick Fix, this is
    /// visibly provider-backed and follows the AI preview policy.
    func proofreadWithAI() {
        runAction(.proofread)
    }

    /// Runs a specific action directly (used by the Bean Bubble mini menu).
    /// Reuses the exact same acquisition/preview/replacement pipeline as the
    /// action menu — no duplicated logic.
    func runAction(_ action: WritingAction) {
        guard beginOperation() else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false }
            guard self.ready(requestedAction: action.rawValue,
                             requiresProvider: action.usesProvider) else { return }
            guard let job = await self.acquire(requestedAction: action.rawValue) else { return }
            await self.process(job: job, action: action,
                               preview: Self.requiresPreview(for: action, mode: job.mode),
                               explicitProfile: nil)
        }
    }

    /// Bean menu: acquire text, then show the action menu.
    func showActionMenu() {
        guard beginOperation() else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false }
            guard self.ready(requestedAction: "openMenu", requiresProvider: false) else { return }
            statusHUD.showProgress("Opening Bean…",
                                   sourceAppName: NSWorkspace.shared.frontmostApplication?.localizedName,
                                   sourceAnchorRect: self.currentSourceNoticeAnchorRect())
            guard let job = await self.acquire(requestedAction: "openMenu") else { return }
            self.sessionActive = true
            statusHUD.dismiss()
            self.actionMenu.presentMenu(
                appName: job.context.appName,
                captureLabel: Self.captureLabel(for: job.mode),
                sourceAnchorRect: job.sourceAnchorRect,
                aiAvailable: self.settings.hasAPIKey,
                onSelect: { [weak self] action in
                    Task {
                        await self?.process(
                            job: job,
                            action: action,
                            preview: Self.requiresPreview(for: action, mode: job.mode),
                            explicitProfile: nil
                        )
                    }
                },
                onSetUpAI: { [weak self] in self?.openAISettingsFromCapturedMenu() },
                onCancel: { [weak self] in self?.endSession(restore: true) }
            )
        }
    }

    // MARK: - Pipeline

    /// Starts one explicit operation and always tells the user why a second
    /// trigger did nothing instead of silently swallowing it.
    private func beginOperation() -> Bool {
        let sourceAnchorRect = currentSourceNoticeAnchorRect()
        if sessionActive {
            statusHUD.showProgress("Finish or cancel the open Bean window first",
                                   sourceAppName: NSWorkspace.shared.frontmostApplication?.localizedName,
                                   sourceAnchorRect: sourceAnchorRect)
            return false
        }
        if isRunning {
            statusHUD.showProgress("Bean is already working…",
                                   sourceAppName: NSWorkspace.shared.frontmostApplication?.localizedName,
                                   sourceAnchorRect: sourceAnchorRect)
            return false
        }
        isRunning = true
        return true
    }

    private func finishNotice(restoreAcquisition: Bool) {
        if restoreAcquisition { selection.cancel() }
        sessionActive = false
    }

    private func openAISettingsFromCapturedMenu() {
        selection.cancel()
        sessionActive = false
        onShowSettings()
    }

    private func presentAccessibilityNotice(sourceAnchorRect: CGRect? = nil) {
        let noticeAnchorRect = sourceAnchorRect ?? currentSourceNoticeAnchorRect()
        sessionActive = true
        statusHUD.dismiss()
        actionMenu.presentNotice(ActionNotice(
            title: "Accessibility Permission Needed",
            message: "Bean needs Accessibility access to read and safely replace text only when you ask it to.",
            kind: .warning,
            primaryAction: .init("Open System Settings") { [weak self] in
                self?.finishNotice(restoreAcquisition: true)
                PermissionService.requestAccessibility()
                PermissionService.openAccessibilitySettings()
            },
            onDismiss: { [weak self] in
                self?.finishNotice(restoreAcquisition: true)
            }
        ), sourceAnchorRect: noticeAnchorRect)
    }

    private func presentAISetupNotice(sourceAnchorRect: CGRect? = nil) {
        let noticeAnchorRect = sourceAnchorRect ?? currentSourceNoticeAnchorRect()
        sessionActive = true
        statusHUD.dismiss()
        actionMenu.presentNotice(ActionNotice(
            title: "Set Up AI to Continue",
            message: "This action uses your AI provider. Quick Fix remains free, private, and available offline.",
            kind: .info,
            primaryAction: .init("Set Up AI") { [weak self] in
                self?.finishNotice(restoreAcquisition: true)
                self?.onShowSettings()
            },
            onDismiss: { [weak self] in
                self?.finishNotice(restoreAcquisition: true)
            }
        ), sourceAnchorRect: noticeAnchorRect)
    }

    private func presentAcquisitionNotice(
        title: String,
        message: String,
        kind: ActionNotice.Kind = .warning,
        sourceAnchorRect: CGRect? = nil
    ) {
        let noticeAnchorRect = sourceAnchorRect ?? currentSourceNoticeAnchorRect()
        sessionActive = true
        statusHUD.dismiss()
        actionMenu.presentNotice(ActionNotice(
            title: title,
            message: message,
            kind: kind,
            primaryAction: .init("Got It") { [weak self] in
                self?.finishNotice(restoreAcquisition: true)
            },
            onDismiss: { [weak self] in
                self?.finishNotice(restoreAcquisition: true)
            }
        ), sourceAnchorRect: noticeAnchorRect)
    }

    private func presentProviderFailure(
        _ message: String,
        error: LLMError?,
        job: Job,
        action: WritingAction,
        preview: Bool,
        explicitProfile: UUID?
    ) {
        sessionActive = true
        statusHUD.dismiss()

        let configurationProblem: Bool
        switch error {
        case .missingAPIKey?, .invalidAPIKey?: configurationProblem = true
        default: configurationProblem = false
        }

        let retry = ActionNotice.Action("Retry · uses AI") { [weak self] in
            guard let self else { return }
            self.finishNotice(restoreAcquisition: false)
            self.retryProviderOperation(
                job: job,
                action: action,
                preview: preview,
                explicitProfile: explicitProfile
            )
        }
        let settingsAction = ActionNotice.Action("Open AI Settings") { [weak self] in
            self?.finishNotice(restoreAcquisition: true)
            self?.onShowSettings()
        }

        actionMenu.presentNotice(ActionNotice(
            title: configurationProblem ? "Check Your AI Setup" : "AI Couldn’t Finish",
            message: message,
            kind: configurationProblem ? .warning : .danger,
            primaryAction: configurationProblem ? settingsAction : retry,
            secondaryAction: configurationProblem ? nil : settingsAction,
            onDismiss: { [weak self] in
                self?.finishNotice(restoreAcquisition: true)
            }
        ), sourceAnchorRect: job.sourceAnchorRect)
    }

    private func retryProviderOperation(
        job: Job,
        action: WritingAction,
        preview: Bool,
        explicitProfile: UUID?
    ) {
        guard beginOperation() else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false }
            await self.process(
                job: job,
                action: action,
                preview: preview,
                explicitProfile: explicitProfile
            )
        }
    }

    private func presentSafetyNotice(job: Job) {
        sessionActive = true
        statusHUD.dismiss()
        actionMenu.presentNotice(ActionNotice(
            title: "Bean Blocked This Result",
            message: "The AI response included content that did not look like a safe edit of your writing. Your original text was not changed.",
            kind: .warning,
            primaryAction: .init("Return to Writing") { [weak self] in
                self?.finishNotice(restoreAcquisition: true)
            },
            onDismiss: { [weak self] in
                self?.finishNotice(restoreAcquisition: true)
            }
        ), sourceAnchorRect: job.sourceAnchorRect)
    }

    private func ready(requestedAction: String, requiresProvider: Bool = true) -> Bool {
        guard PermissionService.isAccessibilityGranted else {
            recordPreflight(action: requestedAction, outcome: "accessibilityPermissionRequired")
            presentAccessibilityNotice()
            return false
        }
        guard !requiresProvider || settings.hasAPIKey else {
            recordPreflight(action: requestedAction, outcome: "missingAPIKey")
            presentAISetupNotice()
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
            return Job(original: text, leading: leading, core: core, trailing: trailing,
                       mode: mode, context: context,
                       sourceAnchorRect: currentSourceAnchorRect(for: mode, context: context))
        case .noSelectionOrFocusedField:
            recordPreflight(action: requestedAction, outcome: "noSelectionOrFocusedField")
            presentAcquisitionNotice(
                title: "No Editable Text Found",
                message: "Select text or place the cursor in an editable field, then try Quick Fix again."
            )
            return nil
        case .tooLong:
            recordPreflight(action: requestedAction, outcome: "inputTooLong")
            presentAcquisitionNotice(
                title: "Select Less Text",
                message: "This field is too long to change safely. Select the paragraph or sentence you want Bean to work on."
            )
            return nil
        case .failed(let reason):
            recordPreflight(action: requestedAction, outcome: "acquisitionFailed")
            presentAcquisitionNotice(title: "Bean Couldn’t Read This Field", message: reason, kind: .danger)
            return nil
        }
    }

    private func currentSourceAnchorRect(for mode: TextInputMode,
                                         context: SourceAppContext) -> CGRect? {
        if let field = AccessibilityService.focusedField() {
            if mode == .selectedText,
               let selectionRect = TextRangeLocator.selectionRect(for: field.element) {
                return selectionRect
            }
            if let fieldRect = TextRangeLocator.fieldRect(for: field.element) {
                return fieldRect
            }
        }
        if let processIdentifier = context.processIdentifier,
           let sourceApp = NSRunningApplication(processIdentifier: processIdentifier),
           let point = ElectronTextFocusEvidence.validAnchor(for: sourceApp) {
            return CGRect(origin: point, size: CGSize(width: 1, height: 1))
        }
        return nil
    }

    /// Best-effort source geometry for preflight and recovery surfaces that
    /// appear before a Job exists. Selection geometry wins over the whole
    /// field, then Electron typing evidence provides the AX-free fallback.
    private func currentSourceNoticeAnchorRect() -> CGRect? {
        if let field = AccessibilityService.focusedField() {
            if let selectionRect = TextRangeLocator.selectionRect(for: field.element) {
                return selectionRect
            }
            if let fieldRect = TextRangeLocator.fieldRect(for: field.element) {
                return fieldRect
            }
        }
        if let sourceApp = NSWorkspace.shared.frontmostApplication,
           let point = ElectronTextFocusEvidence.validAnchor(for: sourceApp) {
            return CGRect(origin: point, size: CGSize(width: 1, height: 1))
        }
        return nil
    }

    private func process(job: Job, action: WritingAction, preview: Bool, explicitProfile: UUID?) async {
        let operationStartedAt = Date()
        guard !action.usesProvider || !settings.apiKey.isEmpty else {
            diagnostics(job: job, action: action, outLen: 0, validator: "notRun",
                        replacement: "missingAPIKey", startedAt: operationStartedAt)
            presentAISetupNotice(sourceAnchorRect: job.sourceAnchorRect)
            return
        }

        if action == .localQuickCheck {
            statusHUD.showProgress(
                "Checking \(Self.captureLabel(for: job.mode).lowercased()) locally…",
                sourceAppName: job.context.appName,
                sourceAnchorRect: job.sourceAnchorRect
            )
            let correctedCore = LocalQuickChecker.corrected(job.core, dictionary: userContent.dictionary)
            guard correctedCore != job.core else {
                diagnostics(job: job, action: action, outLen: correctedCore.count,
                            validator: "local_quick", replacement: "noChangesNeeded",
                            startedAt: operationStartedAt)
                endSession(restore: true, confirmedMessage: "No obvious local issues found",
                           sourceAppName: job.context.appName,
                           sourceAnchorRect: job.sourceAnchorRect)
                return
            }
            let result = await selection.replace(
                corrected: job.leading + correctedCore + job.trailing,
                original: job.original, mode: job.mode)
            report(result, job: job)
            diagnostics(job: job, action: action, outLen: correctedCore.count,
                        validator: "local_quick", replacement: resultCode(result),
                        startedAt: operationStartedAt)
            if Self.requiresReplacementRecovery(result) {
                presentReplacementRecovery(job: job, action: action,
                                           outCore: correctedCore, result: result, model: nil)
            } else {
                sessionActive = false
            }
            return
        }

        if Self.exceedsProviderInputLimit(action: action, text: job.core) {
            diagnostics(job: job, action: action, outLen: 0, validator: "notRun",
                        replacement: "providerInputTooLong", startedAt: operationStartedAt)
            presentAcquisitionNotice(
                title: "Select Less Text",
                message: "AI actions can work on up to 8,000 characters at a time. Select a smaller passage, then try again.",
                sourceAnchorRect: job.sourceAnchorRect
            )
            return
        }

        // AI Proofread is explicit: once chosen, it follows the provider path.
        // Obvious local typo correction belongs exclusively to Quick Fix so the
        // two commands never silently exchange privacy/cost behavior.
        if action == .proofread {
            if job.core.count < 4 {
                diagnostics(job: job, action: action, outLen: 0, validator: "notRun",
                            replacement: "textTooShort", startedAt: operationStartedAt)
                presentAcquisitionNotice(
                    title: "Not Enough Text",
                    message: "Select a complete word or a longer passage, then try again.",
                    sourceAnchorRect: job.sourceAnchorRect
                )
                return
            }
        } else if job.core.count < 4 {
            diagnostics(job: job, action: action, outLen: 0, validator: "notRun",
                        replacement: "textTooShort", startedAt: operationStartedAt)
            presentAcquisitionNotice(
                title: "Not Enough Text",
                message: "Select a complete word or a longer passage, then try again.",
                sourceAnchorRect: job.sourceAnchorRect
            )
            return
        }

        statusHUD.showProgress(
            action == .proofread
                ? "AI is proofreading \(Self.captureLabel(for: job.mode).lowercased())…"
                : "AI is rewriting \(Self.captureLabel(for: job.mode).lowercased())…",
            sourceAppName: job.context.appName,
            sourceAnchorRect: job.sourceAnchorRect
        )

        let personalization = userContent.personalization(action: action, context: job.context,
                                                          explicitProfile: explicitProfile, sourceText: job.core)

        let completion: LLMCompletion
        do {
            completion = try await transformer.transform(
                text: job.core, action: action, context: job.context,
                userContextLines: personalization.userContextLines,
                provider: settings.provider, model: settings.model,
                apiKey: settings.apiKey, timeout: settings.timeoutSeconds
            )
        } catch let error as LLMError {
            diagnostics(job: job, action: action, outLen: 0, validator: "providerError",
                        replacement: providerErrorCode(error), startedAt: operationStartedAt)
            presentProviderFailure(
                error.errorDescription ?? "Could not transform text",
                error: error,
                job: job,
                action: action,
                preview: preview,
                explicitProfile: explicitProfile
            )
            return
        } catch {
            diagnostics(job: job, action: action, outLen: 0, validator: "providerError",
                        replacement: "unexpectedProviderError", startedAt: operationStartedAt)
            presentProviderFailure(
                "Could not transform text: \(error.localizedDescription)",
                error: nil,
                job: job,
                action: action,
                preview: preview,
                explicitProfile: explicitProfile
            )
            return
        }

        let outCore = TextNormalizer.sanitizeModelOutput(completion.text, originalCore: job.core)

        if case let .suspicious(reason) = OutputSafetyValidator.validate(input: job.core, output: outCore, action: action) {
            switch OutputSafetyValidator.disposition(for: reason) {
            case .hardBlock:
                Log.event("validation: blocked (\(reason))")
                diagnostics(job: job, action: action, outLen: outCore.count, validator: reason,
                            replacement: "blocked", startedAt: operationStartedAt,
                            usage: completion.usage)
                presentSafetyNotice(job: job)
            case .reviewRequired:
                Log.event("validation: review required (\(reason))")
                diagnostics(job: job, action: action, outLen: outCore.count, validator: reason,
                            replacement: "reviewRequired", startedAt: operationStartedAt,
                            usage: completion.usage)
                presentPreview(job: job, action: action, outCore: outCore,
                               explicitProfile: explicitProfile, personalization: personalization,
                               reviewReason: reason)
            }
            return
        }

        if outCore == job.core {
            diagnostics(job: job, action: action, outLen: outCore.count, validator: "ok",
                        replacement: "noChangesNeeded", startedAt: operationStartedAt,
                        usage: completion.usage)
            endSession(restore: true, confirmedMessage: "No changes needed",
                       sourceAppName: job.context.appName,
                       sourceAnchorRect: job.sourceAnchorRect)
            return
        }

        if preview {
            diagnostics(job: job, action: action, outLen: outCore.count, validator: "ok",
                        replacement: "previewReady", startedAt: operationStartedAt,
                        usage: completion.usage)
            presentPreview(job: job, action: action, outCore: outCore, explicitProfile: explicitProfile, personalization: personalization)
        } else {
            let finalText = job.leading + outCore + job.trailing
            let result = await selection.replace(corrected: finalText, original: job.original, mode: job.mode)
            report(result, job: job)
            diagnostics(job: job, action: action, outLen: outCore.count, validator: "ok",
                        replacement: resultCode(result), startedAt: operationStartedAt,
                        usage: completion.usage)
            if Self.requiresReplacementRecovery(result) {
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
        statusHUD.dismiss()
        let model = PreviewModel(
            actionName: action.displayName,
            transformedText: outCore,
            originalText: job.core,
            sourceAppName: job.context.appName,
            captureLabel: Self.captureLabel(for: job.mode),
            sourceAnchorRect: job.sourceAnchorRect
        )
        model.styleName = personalization.styleName
        model.usedContext = personalization.usedContext
        model.allowsReplace = action.allowsReplaceFromPreview
        model.helperText = action.previewHelperText
        model.retryButtonTitle = "Generate Again · uses AI"
        model.showsAIIndicator = action.usesProvider
        if let reviewReason {
            model.reviewWarning = OutputSafetyValidator.reviewMessage(for: reviewReason)
        }
        model.onReplace = model.weakHandler { [weak self] model in
            self?.previewReplace(job: job, action: action, model: model)
        }
        model.onCopy = model.weakHandler { [weak self] model in
            self?.previewCopy(job: job, action: action, model: model)
        }
        model.onTryAgain = model.weakHandler { [weak self] model in
            self?.previewRetry(
                job: job,
                action: action,
                model: model,
                explicitProfile: explicitProfile
            )
        }
        model.onCancel = model.weakHandler { [weak self] model in
            guard !model.isRunning else { return }
            self?.previewCancel(job: job, action: action)
        }
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
            self.report(result, job: job)
            self.diagnostics(job: job, action: action, outLen: model.transformedText.count,
                             validator: "previewApproved", replacement: self.resultCode(result),
                             startedAt: startedAt)
            if Self.requiresReplacementRecovery(result) {
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
        statusHUD.showConfirmedSuccess(
            "Result copied",
            sourceAppName: job.context.appName,
            sourceAnchorRect: job.sourceAnchorRect
        )
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
                let completion = try await self.transformer.transform(
                    text: job.core, action: action, context: job.context,
                    userContextLines: personalization.userContextLines,
                    provider: self.settings.provider, model: self.settings.model,
                    apiKey: self.settings.apiKey, timeout: self.settings.timeoutSeconds
                )
                let outCore = TextNormalizer.sanitizeModelOutput(completion.text, originalCore: job.core)
                if case let .suspicious(reason) = OutputSafetyValidator.validate(input: job.core, output: outCore, action: action) {
                    if OutputSafetyValidator.disposition(for: reason) == .hardBlock {
                        self.diagnostics(job: job, action: action, outLen: outCore.count,
                                         validator: reason, replacement: "retryBlocked",
                                         startedAt: Date(), usage: completion.usage)
                        model.errorMessage = "That result contained unsafe model output. Try again."
                        return
                    }
                    model.reviewWarning = OutputSafetyValidator.reviewMessage(for: reason)
                }
                model.transformedText = outCore
                self.diagnostics(job: job, action: action, outLen: outCore.count,
                                 validator: model.reviewWarning == nil ? "ok" : "reviewRequired",
                                 replacement: "retryReady", startedAt: Date(), usage: completion.usage)
            } catch {
                model.errorMessage = "Couldn't reach the model. Try again."
            }
        }
    }

    private func previewCancel(job: Job, action: WritingAction) {
        actionMenu.dismissPreview()
        diagnostics(job: job, action: action, outLen: 0, validator: "userDecision",
                    replacement: "cancelled", startedAt: Date())
        endSession(restore: true)
    }

    private func presentReplacementRecovery(job: Job, action: WritingAction, outCore: String,
                                            result: TextSelectionService.ReplacementResult,
                                            model existingModel: PreviewModel?) {
        sessionActive = true
        let model = existingModel ?? PreviewModel(
            actionName: "Replacement Recovery",
            transformedText: outCore,
            originalText: job.core,
            sourceAppName: job.context.appName,
            captureLabel: Self.captureLabel(for: job.mode),
            sourceAnchorRect: job.sourceAnchorRect
        )
        model.isRunning = false
        model.errorMessage = nil
        model.allowsReplace = false
        model.reviewWarning = recoveryMessage(for: result)
        model.retryButtonTitle = "Retry Replacement"
        model.showsAIIndicator = action.usesProvider
        switch result {
        case .replacementSentUnconfirmed:
            model.showsRetryButton = false
            model.helperText = "The suggestion is still available here. Check the original field, then copy it if needed."
        case .failed:
            model.showsRetryButton = false
            model.helperText = "The suggestion is still available here. Copy it to keep the result."
        case .copiedToClipboardFallback, .staleCopiedToClipboard:
            model.showsRetryButton = true
            model.helperText = "The suggestion is still available here and on your clipboard."
        case .clipboardPreservedRecoveryRequired:
            model.showsRetryButton = true
            model.helperText = "The suggestion is still available here. Your newer clipboard was preserved."
        case .replacedConfirmed, .noChangesNeeded:
            model.showsRetryButton = false
        }
        model.onCopy = model.weakHandler { [weak self] model in
            self?.previewCopy(job: job, action: action, model: model)
        }
        model.onTryAgain = model.weakHandler { [weak self] model in
            self?.previewReplace(job: job, action: action, model: model)
        }
        model.onCancel = model.weakHandler { [weak self] model in
            guard !model.isRunning else { return }
            self?.previewCancel(job: job, action: action)
        }
        if existingModel == nil { actionMenu.presentPreview(model) }
        statusHUD.dismiss()
    }

    private func recoveryMessage(for result: TextSelectionService.ReplacementResult) -> String {
        switch result {
        case .staleCopiedToClipboard:
            return "The field changed after Bean read it, so Bean did not overwrite your newer text."
        case .replacementSentUnconfirmed:
            return "Bean sent the replacement but could not confirm what changed. Check the original field before continuing."
        case .clipboardPreservedRecoveryRequired:
            return "Bean could not replace the text. Your newer clipboard was preserved, and the correction remains here."
        case .failed(let reason):
            return reason
        default:
            return "Bean could not confirm that the replacement landed. Focus the original field and try again, or copy it."
        }
    }

    // MARK: - Session / reporting

    private func endSession(restore: Bool, confirmedMessage: String? = nil,
                            sourceAppName: String? = nil,
                            sourceAnchorRect: CGRect? = nil) {
        if restore { selection.cancel() }
        sessionActive = false
        if let confirmedMessage {
            statusHUD.showConfirmedSuccess(
                confirmedMessage,
                sourceAppName: sourceAppName,
                sourceAnchorRect: sourceAnchorRect
            )
        } else {
            statusHUD.dismiss()
        }
    }

    private func report(_ result: TextSelectionService.ReplacementResult, job: Job) {
        switch result {
        case .replacedConfirmed:
            statusHUD.showConfirmedSuccess(
                job.mode == .focusedFieldFullText ? "Whole field fixed" : "Selected text fixed",
                sourceAppName: job.context.appName,
                sourceAnchorRect: job.sourceAnchorRect
            )
        case .noChangesNeeded:
            statusHUD.showConfirmedSuccess(
                "No changes needed",
                sourceAppName: job.context.appName,
                sourceAnchorRect: job.sourceAnchorRect
            )
        case .replacementSentUnconfirmed, .copiedToClipboardFallback,
             .staleCopiedToClipboard, .clipboardPreservedRecoveryRequired, .failed:
            // The caller immediately presents persistent recovery. Never show
            // these unresolved outcomes as a transient success-like HUD.
            statusHUD.dismiss()
        }
    }

    private func reportUndo(
        _ result: TextSelectionService.ReplacementResult,
        sourceAnchorRect: CGRect?
    ) {
        switch result {
        case .replacedConfirmed:
            statusHUD.showConfirmedSuccess(
                "Last Bean change undone",
                sourceAnchorRect: sourceAnchorRect
            )
        case .failed(let reason):
            presentUndoFailure(reason, sourceAnchorRect: sourceAnchorRect)
        default:
            presentUndoFailure(
                "Bean could not safely undo that change.",
                sourceAnchorRect: sourceAnchorRect
            )
        }
    }

    private func presentUndoFailure(_ message: String, sourceAnchorRect: CGRect?) {
        sessionActive = true
        statusHUD.dismiss()
        actionMenu.presentNotice(ActionNotice(
            title: "Couldn’t Undo Safely",
            message: message,
            kind: .warning,
            primaryAction: .init("Got It") { [weak self] in
                self?.finishNotice(restoreAcquisition: false)
            },
            onDismiss: { [weak self] in
                self?.finishNotice(restoreAcquisition: false)
            }
        ), sourceAnchorRect: sourceAnchorRect)
    }

    // MARK: - Diagnostics (text-free)

    private func diagnostics(job: Job, action: WritingAction?, outLen: Int, validator: String,
                             replacement: String, startedAt: Date, usage: LLMUsage? = nil) {
        Log.diag([
            "provider": settings.provider.rawValue,
            // Unified logs need only the fixed coarse category. App display
            // names remain available in the bounded, user-reviewed local
            // operation history and never need to enter an implicit log.
            "appCategory": AppCategory.from(
                bundleIdentifier: job.context.bundleIdentifier
            ).rawValue,
            "action": action?.rawValue ?? "rewrite",
            "inputMode": job.context.acquisitionMode.rawLabel,
            "inputLength": String(job.core.count),
            "outputLength": String(outLen),
            "validatorResult": validator,
            "replacementResult": replacement
        ])
        let local = validator == "local_typo" || validator == "localClean"
            || validator == "local_quick"
        if let usage {
            usageLedger.record(usage, source: .manual,
                               provider: settings.provider.rawValue, model: settings.model)
        }
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
            inputTokens: usage?.inputTokens,
            outputTokens: usage?.outputTokens,
            usageEstimated: usage?.isEstimated ?? false
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
        case .inputTooLong: return "providerInputTooLong"
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
        case .clipboardPreservedRecoveryRequired: return "clipboardPreservedRecoveryRequired"
        case .noChangesNeeded: return "noChangesNeeded"
        case .failed: return "failed"
        }
    }
}
