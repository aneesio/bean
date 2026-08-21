import AppKit

// Passive Suggestions (Phase 5). Driven by the shared TypingPauseDispatcher —
// it no longer installs its own key monitor. On a dispatched pause it reads the
// focused field via Accessibility ONLY, runs a Proofread check, and (only if a
// meaningful, safe change exists) shows a small popover.
//
// Conservative: gated by app category / length / secure-field checks,
// rate-limited, stale-safe. No text is logged or stored; only in-memory
// fingerprints (hashes) are kept.
@MainActor
final class PassiveSuggestionService {
    private let settings: AppSettings
    private let userContent: UserContentStore
    private let history: OperationHistoryStore
    private let usageLedger: UsageLedgerStore
    private let undoStore: ReplacementUndoStore
    private let statusHUD: StatusHUD

    private let transformer = WritingTransformService()
    private let popover = SuggestionPopoverController()
    private let previewController = ActionMenuController()

    // In-memory only (never persisted, never logged).
    private var lastShownFingerprint: Int?
    private var lastCallTime: Date?
    private var ignoredFingerprints = Set<Int>()

    private struct Session {
        let app: NSRunningApplication?
        let element: AXUIElement
        let fingerprint: Int
        let sourceCore: String
        let leading: String
        let trailing: String
        var correctedCore: String
        let context: SourceAppContext
        var reviewReason: String?
    }
    private var current: Session?

    init(settings: AppSettings, userContent: UserContentStore,
         history: OperationHistoryStore, usageLedger: UsageLedgerStore,
         undoStore: ReplacementUndoStore,
         statusHUD: StatusHUD) {
        self.settings = settings
        self.userContent = userContent
        self.history = history
        self.usageLedger = usageLedger
        self.undoStore = undoStore
        self.statusHUD = statusHUD
    }

    func hideUI() { popover.dismiss() }
    var isShowingUI: Bool { popover.isShowing }

    // MARK: - Run (called by the dispatcher)

    /// Runs the passive check for an already-fetched field. `forced` runs even
    /// if the Passive toggle is off (the inline → passive fallback case).
    /// Returns true if a suggestion popover was shown. `reason` is filled with a
    /// skip code when it returns false.
    func run(field: AccessibilityService.FocusedField, app: NSRunningApplication?,
             context: SourceAppContext, isCurrent: @escaping () -> Bool,
             forced: Bool, reason: inout String) async -> Bool {
        guard forced || settings.passiveActive else { reason = "passiveOff"; return false }
        guard !settings.apiKey.isEmpty else { reason = "noKey"; return false }
        guard !field.isSecure else { reason = "secureField"; return false }
        guard field.acceptsTextInput, let value = field.value else { reason = "cannotReadText"; return false }
        guard categoryAllowed(field: field) else { reason = "appDisabled"; return false }

        let (leading, core, trailing) = TextNormalizer.split(value)
        guard core.count >= settings.passiveMinLength else { reason = "tooShort"; return false }
        guard value.count <= settings.passiveMaxLength else { reason = "textTooLong"; return false }
        if TextNormalizer.isCleanSingleWord(core), LocalTypoCorrector.correction(for: core) == nil {
            reason = "cleanWord"; return false
        }

        // This setting existed in the UI but was not previously enforced, so a
        // clean field still generated a paid request after every pause. Use the
        // offline detector as the preflight signal when the cost-saving gate is on.
        if settings.passiveOnlyWhenLikely {
            var local = IssueDetector()
            local.maxIssues = 1
            guard !local.localIssues(in: core, dictionary: userContent.dictionary).isEmpty else {
                reason = "noLocalSignal"; return false
            }
        }

        guard usageLedger.allowsAutomaticCall(dailyLimit: settings.dailyAutomaticCallLimit) else {
            reason = "automaticDailyLimit"; return false
        }

        let fp = fingerprint(value)
        if fp == lastShownFingerprint { reason = "unchanged"; return false }
        if ignoredFingerprints.contains(fp) { reason = "ignored"; return false }
        if let last = lastCallTime, Date().timeIntervalSince(last) < EngineConfig.automaticLLMCooldown {
            reason = "rateLimited"; return false
        }
        lastCallTime = Date()

        let personalization = userContent.personalization(action: .proofread, context: context,
                                                          explicitProfile: nil, sourceText: core)
        let completion: LLMCompletion
        do {
            completion = try await transformer.transform(
                text: core, action: .proofread, context: context,
                personalization: personalization.systemBlock, extraContextLines: personalization.contextLines,
                provider: settings.provider, model: settings.model,
                apiKey: settings.apiKey, timeout: settings.timeoutSeconds)
        } catch { reason = "requestFailed"; return false }

        usageLedger.record(completion.usage, source: .passive,
                           provider: settings.provider.rawValue, model: settings.model)

        // Stale guard: typing resumed or field changed while in flight.
        guard isCurrent(),
              let nowValue = AccessibilityService.value(of: field.element),
              fingerprint(nowValue) == fp else {
            recordProviderOperation(context: context, inputLength: core.count, outputLength: 0,
                                    safety: "notRun", outcome: "staleDiscarded",
                                    usage: completion.usage)
            reason = "staleDiscarded"; return false
        }

        let outCore = TextNormalizer.sanitizeModelOutput(completion.text, originalCore: core)
        var reviewReason: String?
        if case .suspicious(let r) = OutputSafetyValidator.validate(input: core, output: outCore, action: .proofread) {
            if OutputSafetyValidator.disposition(for: r) == .hardBlock {
                recordProviderOperation(context: context, inputLength: core.count,
                                        outputLength: outCore.count, safety: r,
                                        outcome: "blocked", usage: completion.usage)
                reason = r; return false
            }
            reviewReason = r
        }
        guard outCore != core else {
            recordProviderOperation(context: context, inputLength: core.count,
                                    outputLength: outCore.count, safety: "ok",
                                    outcome: "noChangesNeeded", usage: completion.usage)
            reason = "noChange"; return false
        }

        lastShownFingerprint = fp
        current = Session(app: app, element: field.element, fingerprint: fp,
                          sourceCore: core, leading: leading, trailing: trailing,
                          correctedCore: outCore, context: context, reviewReason: reviewReason)
        popover.present(
            previewText: outCore,
            showApply: reviewReason == nil && !settings.passiveRequirePreview,
            onApply: { [weak self] in self?.applyCurrent() },
            onPreview: { [weak self] in self?.previewCurrent() },
            onIgnore: { [weak self] in self?.ignoreCurrent() },
            onCopy: { [weak self] in self?.copyCurrent() })
        recordProviderOperation(context: context, inputLength: core.count,
                                outputLength: outCore.count,
                                safety: reviewReason ?? "ok", outcome: "suggestionShown",
                                usage: completion.usage)
        reason = "shown"
        return true
    }

    // MARK: - Popover actions

    private func applyCurrent() {
        guard let session = current else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.apply(session: session, correctedCore: session.correctedCore)
            if self.needsRecovery(result) {
                self.presentRecovery(session: session, correctedCore: session.correctedCore, result: result)
            }
        }
    }

    private func copyCurrent() {
        guard let session = current else { return }
        ClipboardService.writeString(session.leading + session.correctedCore + session.trailing)
        statusHUD.show(.success, "Copied")
    }

    private func ignoreCurrent() {
        if let session = current { ignoredFingerprints.insert(session.fingerprint) }
    }

    private func previewCurrent() {
        guard let session = current else { return }
        let model = PreviewModel(actionName: "Proofread", transformedText: session.correctedCore,
                                 originalText: session.sourceCore)
        model.helperText = "Review before replacing your text."
        if let reviewReason = session.reviewReason {
            model.reviewWarning = OutputSafetyValidator.reviewMessage(for: reviewReason)
        }
        model.allowsReplace = true
        model.onReplace = { [weak self] in self?.attemptPreviewApply(session: session, model: model) }
        model.onCopy = { [weak self] in
            ClipboardService.writeString(session.leading + model.transformedText + session.trailing)
            self?.previewController.dismissPreview()
            self?.statusHUD.show(.success, "Copied")
        }
        model.onTryAgain = { [weak self] in self?.previewRetry(session: session, model: model) }
        model.onCancel = { [weak self] in self?.previewController.dismissPreview() }
        previewController.presentPreview(model)
    }

    private func previewRetry(session: Session, model: PreviewModel) {
        guard usageLedger.allowsAutomaticCall(dailyLimit: settings.dailyAutomaticCallLimit) else {
            model.errorMessage = "Today's automatic AI limit has been reached. Manual actions still work."
            return
        }
        model.isRunning = true
        model.errorMessage = nil
        model.reviewWarning = nil
        Task { [weak self] in
            guard let self else { return }
            defer { model.isRunning = false }
            let personalization = self.userContent.personalization(action: .proofread, context: session.context,
                                                                   explicitProfile: nil, sourceText: session.sourceCore)
            do {
                let completion = try await self.transformer.transform(
                    text: session.sourceCore, action: .proofread, context: session.context,
                    personalization: personalization.systemBlock, extraContextLines: personalization.contextLines,
                    provider: self.settings.provider, model: self.settings.model,
                    apiKey: self.settings.apiKey, timeout: self.settings.timeoutSeconds)
                self.usageLedger.record(completion.usage, source: .passive,
                                        provider: self.settings.provider.rawValue, model: self.settings.model)
                let outCore = TextNormalizer.sanitizeModelOutput(completion.text, originalCore: session.sourceCore)
                if case let .suspicious(reason) = OutputSafetyValidator.validate(input: session.sourceCore, output: outCore, action: .proofread) {
                    if OutputSafetyValidator.disposition(for: reason) == .hardBlock {
                        self.recordProviderOperation(context: session.context,
                                                     inputLength: session.sourceCore.count,
                                                     outputLength: outCore.count, safety: reason,
                                                     outcome: "retryBlocked", usage: completion.usage)
                        model.errorMessage = "That result contained unsafe model output. Try again."; return
                    }
                    model.reviewWarning = OutputSafetyValidator.reviewMessage(for: reason)
                }
                model.transformedText = outCore
                self.recordProviderOperation(context: session.context,
                                             inputLength: session.sourceCore.count,
                                             outputLength: outCore.count,
                                             safety: model.reviewWarning == nil ? "ok" : "reviewRequired",
                                             outcome: "retryReady", usage: completion.usage)
            } catch { model.errorMessage = "Couldn't reach the model. Try again." }
        }
    }

    // MARK: - Apply (stale-safe)

    private func apply(session: Session, correctedCore: String) async -> TextSelectionService.ReplacementResult {
        guard let app = session.app, !app.isTerminated else {
            ClipboardService.writeString(session.leading + correctedCore + session.trailing)
            statusHUD.show(.warning, "Text changed. Copied suggestion to clipboard.")
            return .copiedToClipboardFallback
        }
        guard let currentEl = AccessibilityService.focusedElement(),
              AccessibilityService.isSameElement(currentEl, session.element),
              let nowValue = AccessibilityService.value(of: session.element),
              fingerprint(nowValue) == session.fingerprint else {
            ClipboardService.writeString(session.leading + correctedCore + session.trailing)
            statusHUD.show(.warning, "Text changed. Copied suggestion to clipboard.")
            return .staleCopiedToClipboard
        }

        let corrected = session.leading + correctedCore + session.trailing
        let result = await replaceFullField(element: session.element, app: app, corrected: corrected, original: nowValue)
        if case .replacedConfirmed = result {
            undoStore.registerConfirmedWholeField(app: app, element: session.element,
                                                  original: nowValue, replacement: corrected)
        }
        report(result)
        lastShownFingerprint = nil
        return result
    }

    private func attemptPreviewApply(session: Session, model: PreviewModel) {
        model.isRunning = true
        model.errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let result = await self.apply(session: session, correctedCore: model.transformedText)
            model.isRunning = false
            if self.needsRecovery(result) {
                self.configureRecovery(session: session, correctedCore: model.transformedText,
                                       result: result, model: model)
            } else if case let .failed(reason) = result {
                model.errorMessage = reason
            } else {
                self.previewController.dismissPreview()
            }
        }
    }

    private func presentRecovery(session: Session, correctedCore: String,
                                 result: TextSelectionService.ReplacementResult) {
        let model = PreviewModel(actionName: "Replacement Recovery", transformedText: correctedCore,
                                 originalText: session.sourceCore)
        configureRecovery(session: session, correctedCore: correctedCore, result: result, model: model)
        previewController.presentPreview(model)
    }

    private func configureRecovery(session: Session, correctedCore: String,
                                   result: TextSelectionService.ReplacementResult, model: PreviewModel) {
        model.isRunning = false
        model.allowsReplace = false
        model.reviewWarning = resultRecoveryMessage(result)
        model.helperText = "The suggestion remains available here and on your clipboard."
        model.onCopy = { [weak self] in
            ClipboardService.writeString(session.leading + model.transformedText + session.trailing)
            self?.previewController.dismissPreview()
            self?.statusHUD.show(.success, "Copied")
        }
        model.onTryAgain = { [weak self] in self?.attemptPreviewApply(session: session, model: model) }
        model.onCancel = { [weak self] in self?.previewController.dismissPreview() }
    }

    private func needsRecovery(_ result: TextSelectionService.ReplacementResult) -> Bool {
        switch result {
        case .copiedToClipboardFallback, .staleCopiedToClipboard: return true
        default: return false
        }
    }

    private func resultRecoveryMessage(_ result: TextSelectionService.ReplacementResult) -> String {
        if case .staleCopiedToClipboard = result {
            return "The field changed after Bean read it, so Bean did not overwrite your newer text."
        }
        return "Bean could not confirm that the replacement landed. Focus the original field and try again, or copy it."
    }

    private func replaceFullField(element: AXUIElement, app: NSRunningApplication,
                                  corrected: String, original: String) async -> TextSelectionService.ReplacementResult {
        activate(app)
        await Task.pause(Timing.afterActivate)
        let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)

        if AccessibilityService.isValueSettable(element), AccessibilityService.setValue(corrected, on: element) {
            await Task.pause(Timing.afterActivate)
            if let after = AccessibilityService.value(of: element),
               after.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed { return .replacedConfirmed }
        }

        let saved = ClipboardService.snapshot()
        ClipboardService.writeString(corrected)
        await Task.pause(Timing.afterActivate)
        ClipboardService.simulateSelectAll()
        await Task.pause(Timing.afterActivate)
        ClipboardService.simulatePaste()
        await Task.pause(Timing.afterPaste)

        let result: TextSelectionService.ReplacementResult
        if let after = AccessibilityService.value(of: element) {
            if after.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed { result = .replacedConfirmed }
            else if after == original { result = .copiedToClipboardFallback }
            else { result = .replacementSentUnconfirmed }
        } else { result = .replacementSentUnconfirmed }

        if case .copiedToClipboardFallback = result {
            ClipboardService.writeString(corrected)
        } else {
            await Task.pause(Timing.beforeClipboardRestore)
            ClipboardService.restore(saved)
        }
        return result
    }

    // MARK: - Helpers

    private func categoryAllowed(field: AccessibilityService.FocusedField) -> Bool {
        if field.isSearchLike { return settings.passiveInSearch }
        switch AppCategory.from(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
        case .codeEditor: return settings.passiveInCode
        case .chat: return settings.passiveInChat
        case .mail, .docs: return settings.passiveInMailBrowser
        case .unknown: return settings.passiveInMailBrowser
        }
    }

    private func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) { app.activate() } else { app.activate(options: []) }
    }

    private func report(_ result: TextSelectionService.ReplacementResult) {
        switch result {
        case .replacedConfirmed: statusHUD.show(.success, "Field fixed")
        case .replacementSentUnconfirmed: statusHUD.show(.info, "Replacement sent")
        case .noChangesNeeded: statusHUD.show(.info, "No changes needed")
        case .copiedToClipboardFallback: statusHUD.show(.warning, "Could not replace text. Corrected text copied to clipboard.")
        case .staleCopiedToClipboard: statusHUD.show(.warning, "Text changed. Copied suggestion to clipboard.")
        case .failed(let reason): statusHUD.show(.error, reason)
        }
    }

    private func recordProviderOperation(context: SourceAppContext, inputLength: Int,
                                         outputLength: Int, safety: String, outcome: String,
                                         usage: LLMUsage) {
        history.record(OperationRecord(
            source: .passive,
            appName: context.appName,
            appBundleIdentifier: context.bundleIdentifier,
            appCategory: AppCategory.from(bundleIdentifier: context.bundleIdentifier).rawValue,
            action: WritingAction.proofread.rawValue,
            inputMode: context.acquisitionMode.rawLabel,
            inputLength: inputLength,
            outputLength: outputLength,
            provider: settings.provider.rawValue,
            model: settings.model,
            safetyResult: safety,
            outcome: outcome,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            usageEstimated: usage.isEstimated
        ))
    }

    private func fingerprint(_ s: String) -> Int {
        var hash: UInt64 = 1469598103934665603
        for byte in s.utf8 { hash ^= UInt64(byte); hash = hash &* 1099511628211 }
        return Int(bitPattern: UInt(truncatingIfNeeded: hash))
    }
}
