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
    private let automaticCallBudget: AutomaticCallBudgetStore
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
         automaticCallBudget: AutomaticCallBudgetStore,
         undoStore: ReplacementUndoStore,
         statusHUD: StatusHUD) {
        self.settings = settings
        self.userContent = userContent
        self.history = history
        self.usageLedger = usageLedger
        self.automaticCallBudget = automaticCallBudget
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
        let provider = settings.provider
        let model = settings.model
        // This hidden legacy path can be re-enabled by old preferences. Require
        // the exact current verified pair before touching Keychain or field text.
        guard settings.isProviderConnectionVerified(provider: provider, model: model) else {
            reason = "providerNotVerified"; return false
        }
        guard !settings.apiKey.isEmpty else { reason = "noKey"; return false }
        guard !field.isSecure else { reason = "secureField"; return false }
        guard field.acceptsTextInput, let value = field.value else { reason = "cannotReadText"; return false }
        guard categoryAllowed(field: field) else { reason = "appDisabled"; return false }

        let (leading, core, trailing) = TextNormalizer.split(value)
        guard core.count >= settings.passiveMinLength else { reason = "tooShort"; return false }
        guard value.count <= settings.passiveMaxLength else { reason = "textTooLong"; return false }
        let providerCharacterLimit = min(
            settings.passiveMaxLength,
            EngineConfig.maxProviderInputCharacters
        )
        guard !Self.exceedsProviderInputLimit(
            text: core,
            maximumCharacters: providerCharacterLimit
        ) else {
            reason = "providerInputTooLong"; return false
        }
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

        let fp = fingerprint(value)
        if fp == lastShownFingerprint { reason = "unchanged"; return false }
        if ignoredFingerprints.contains(fp) { reason = "ignored"; return false }
        if let last = lastCallTime, Date().timeIntervalSince(last) < EngineConfig.automaticLLMCooldown {
            reason = "rateLimited"; return false
        }
        let personalization = userContent.personalization(action: .proofread, context: context,
                                                          explicitProfile: nil, sourceText: core)
        guard WritingTransformService.providerPayloadIsWithinLimit(
            text: core,
            action: .proofread,
            context: context,
            userContextLines: personalization.userContextLines
        ) else {
            reason = "providerInputTooLong"
            return false
        }
        let apiKey = settings.apiKey
        let timeout = settings.timeoutSeconds
        let metadata = AutomaticCallMetadata(
            source: .passive, context: context,
            action: WritingAction.proofread.rawValue, inputLength: core.count,
            provider: provider.rawValue, model: model
        )
        let reservation: AutomaticCallBudgetStore.Reservation
        switch automaticCallBudget.reserve(
            dailyLimit: settings.dailyAutomaticCallLimit,
            leaseDuration: max(timeout + 30, 60),
            metadata: metadata
        ) {
        case .reserved(let value):
            reservation = value
        case .limitReached:
            reason = "automaticDailyLimit"
            return false
        case .unavailable:
            reason = "usageReservationUnavailable"
            return false
        }
        defer { reservation.cancel() }
        guard reservation.beginProviderAttempt() else {
            reason = "usageReservationUnavailable"
            return false
        }
        lastCallTime = Date()

        let completion: LLMCompletion
        do {
            completion = try await transformer.transform(
                text: core, action: .proofread, context: context,
                userContextLines: personalization.userContextLines,
                provider: provider, model: model,
                apiKey: apiKey, timeout: timeout)
        } catch {
            _ = reservation.fail(outcome: automaticProviderFailureOutcome(error))
            refreshAccounting()
            reason = error is CancellationError ? "requestCancelled" : "requestFailed"
            return false
        }

        // Stale guard: typing resumed or field changed while in flight.
        guard isCurrent(),
              let nowValue = AccessibilityService.value(of: field.element),
              fingerprint(nowValue) == fp else {
            _ = reservation.complete(
                usage: completion.usage, outputLength: 0,
                safetyResult: "notRun", outcome: "staleDiscarded"
            )
            refreshAccounting()
            reason = "staleDiscarded"; return false
        }

        let outCore = TextNormalizer.sanitizeModelOutput(completion.text, originalCore: core)
        var reviewReason: String?
        if case .suspicious(let r) = OutputSafetyValidator.validate(input: core, output: outCore, action: .proofread) {
            if OutputSafetyValidator.disposition(for: r) == .hardBlock {
                _ = reservation.complete(
                    usage: completion.usage, outputLength: outCore.count,
                    safetyResult: r, outcome: "blocked"
                )
                refreshAccounting()
                reason = r; return false
            }
            reviewReason = r
        }
        guard outCore != core else {
            _ = reservation.complete(
                usage: completion.usage, outputLength: outCore.count,
                safetyResult: "ok", outcome: "noChangesNeeded"
            )
            refreshAccounting()
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
        _ = reservation.complete(
            usage: completion.usage, outputLength: outCore.count,
            safetyResult: reviewReason ?? "ok", outcome: "suggestionShown"
        )
        refreshAccounting()
        reason = "shown"
        return true
    }

    static func exceedsProviderInputLimit(
        text: String,
        maximumCharacters: Int = EngineConfig.maxProviderInputCharacters
    ) -> Bool {
        EngineConfig.exceedsProviderInputLimit(
            text,
            maximumCharacters: maximumCharacters
        )
    }

    struct ReplacementRecoveryPolicy: Equatable {
        let isPersistent: Bool
        let correctionIsOnClipboard: Bool
        let allowsRetry: Bool
    }

    nonisolated static func replacementRecoveryPolicy(
        for result: TextSelectionService.ReplacementResult
    ) -> ReplacementRecoveryPolicy {
        switch result {
        case .replacementSentUnconfirmed:
            return ReplacementRecoveryPolicy(
                isPersistent: true,
                correctionIsOnClipboard: false,
                allowsRetry: false
            )
        case .copiedToClipboardFallback, .staleCopiedToClipboard:
            return ReplacementRecoveryPolicy(
                isPersistent: true,
                correctionIsOnClipboard: true,
                allowsRetry: true
            )
        case .clipboardPreservedRecoveryRequired:
            return ReplacementRecoveryPolicy(
                isPersistent: true,
                correctionIsOnClipboard: false,
                allowsRetry: true
            )
        case .failed:
            return ReplacementRecoveryPolicy(
                isPersistent: true,
                correctionIsOnClipboard: false,
                allowsRetry: false
            )
        case .replacedConfirmed, .noChangesNeeded:
            return ReplacementRecoveryPolicy(
                isPersistent: false,
                correctionIsOnClipboard: false,
                allowsRetry: false
            )
        }
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
        model.onReplace = model.weakHandler { [weak self] model in
            self?.attemptPreviewApply(session: session, model: model)
        }
        model.onCopy = model.weakHandler { [weak self] model in
            ClipboardService.writeString(session.leading + model.transformedText + session.trailing)
            self?.previewController.dismissPreview()
            self?.statusHUD.show(.success, "Copied")
        }
        model.onTryAgain = model.weakHandler { [weak self] model in
            self?.previewRetry(session: session, model: model)
        }
        model.onCancel = model.weakHandler { [weak self] model in
            guard !model.isRunning else { return }
            self?.previewController.dismissPreview()
        }
        previewController.presentPreview(model)
    }

    private func previewRetry(session: Session, model: PreviewModel) {
        model.isRunning = true
        model.errorMessage = nil
        model.reviewWarning = nil
        Task { [weak self] in
            guard let self else { return }
            defer { model.isRunning = false }
            guard EngineConfig.providerInputIsWithinLimit(session.sourceCore) else {
                model.errorMessage = "This text is too large for a safe AI check."
                return
            }
            let personalization = self.userContent.personalization(action: .proofread, context: session.context,
                                                                   explicitProfile: nil, sourceText: session.sourceCore)
            guard WritingTransformService.providerPayloadIsWithinLimit(
                text: session.sourceCore,
                action: .proofread,
                context: session.context,
                userContextLines: personalization.userContextLines
            ) else {
                model.errorMessage = "This text is too large for a safe AI check."
                return
            }
            let provider = self.settings.provider
            let providerModel = self.settings.model
            let apiKey = self.settings.apiKey
            let timeout = self.settings.timeoutSeconds
            let metadata = AutomaticCallMetadata(
                source: .manual, context: session.context,
                action: "proofreadRetry", inputLength: session.sourceCore.count,
                provider: provider.rawValue, model: providerModel
            )
            let reservation: AutomaticCallBudgetStore.Reservation
            switch self.automaticCallBudget.reserveManual(
                leaseDuration: max(timeout + 30, 60),
                metadata: metadata
            ) {
            case .reserved(let value):
                reservation = value
            case .limitReached, .unavailable:
                model.errorMessage = "Bean couldn't safely reserve this AI check. Try again."
                return
            }
            defer { reservation.cancel() }
            guard reservation.beginProviderAttempt() else {
                model.errorMessage = "Bean couldn't safely start this AI check. Try again."
                return
            }
            do {
                let completion = try await self.transformer.transform(
                    text: session.sourceCore, action: .proofread, context: session.context,
                    userContextLines: personalization.userContextLines,
                    provider: provider, model: providerModel,
                    apiKey: apiKey, timeout: timeout)
                let outCore = TextNormalizer.sanitizeModelOutput(completion.text, originalCore: session.sourceCore)
                if case let .suspicious(reason) = OutputSafetyValidator.validate(input: session.sourceCore, output: outCore, action: .proofread) {
                    if OutputSafetyValidator.disposition(for: reason) == .hardBlock {
                        _ = reservation.complete(
                            usage: completion.usage, outputLength: outCore.count,
                            safetyResult: reason, outcome: "retryBlocked"
                        )
                        self.refreshAccounting()
                        model.errorMessage = "That result contained unsafe model output. Try again."; return
                    }
                    model.reviewWarning = OutputSafetyValidator.reviewMessage(for: reason)
                }
                model.transformedText = outCore
                _ = reservation.complete(
                    usage: completion.usage, outputLength: outCore.count,
                    safetyResult: model.reviewWarning == nil ? "ok" : "reviewRequired",
                    outcome: "retryReady"
                )
                self.refreshAccounting()
            } catch {
                _ = reservation.fail(outcome: automaticProviderFailureOutcome(error))
                self.refreshAccounting()
                model.errorMessage = "Couldn't reach the model. Try again."
            }
        }
    }

    // MARK: - Apply (stale-safe)

    private func apply(session: Session, correctedCore: String) async -> TextSelectionService.ReplacementResult {
        guard let app = session.app, !app.isTerminated else {
            ClipboardService.writeString(session.leading + correctedCore + session.trailing)
            statusHUD.show(.warning, "Text changed. Copied suggestion to clipboard.")
            return .copiedToClipboardFallback
        }
        guard await reactivateAndConfirm(app) else {
            ClipboardService.writeString(session.leading + correctedCore + session.trailing)
            statusHUD.show(.warning, "Could not return to the original field. Copied suggestion to clipboard.")
            return .copiedToClipboardFallback
        }

        let currentElement = AccessibilityService.focusedField(in: app)?.element
        let targetsMatch = currentElement.map {
            AccessibilityService.isSameElement($0, session.element)
        } ?? false
        let sourceValue = session.leading + session.sourceCore + session.trailing
        let nowValue = AccessibilityService.value(of: session.element)
        guard Self.passiveTargetContinuityFailure(
            currentTargetExists: currentElement != nil,
            targetsMatch: targetsMatch,
            valueBefore: sourceValue,
            valueNow: nowValue
        ) == nil, let nowValue else {
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

    /// Exact continuity decision used only after the source app has been
    /// reactivated. A hash/fingerprint match is not enough for a destructive
    /// whole-field replacement.
    nonisolated static func passiveTargetContinuityFailure(
        currentTargetExists: Bool,
        targetsMatch: Bool,
        valueBefore: String,
        valueNow: String?
    ) -> TextSelectionService.ReplacementResult? {
        guard currentTargetExists, targetsMatch, let valueNow else {
            return .staleCopiedToClipboard
        }
        return valueNow == valueBefore ? nil : .staleCopiedToClipboard
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
        let policy = Self.replacementRecoveryPolicy(for: result)
        model.showsRetryButton = policy.allowsRetry
        model.helperText = policy.correctionIsOnClipboard
            ? "The suggestion remains available here and on your clipboard."
            : "The suggestion remains available here. Check the original field, then copy it if needed."
        model.onCopy = model.weakHandler { [weak self] model in
            ClipboardService.writeString(session.leading + model.transformedText + session.trailing)
            self?.previewController.dismissPreview()
            self?.statusHUD.show(.success, "Copied")
        }
        model.onTryAgain = model.weakHandler { [weak self] model in
            self?.attemptPreviewApply(session: session, model: model)
        }
        model.onCancel = model.weakHandler { [weak self] model in
            guard !model.isRunning else { return }
            self?.previewController.dismissPreview()
        }
    }

    private func needsRecovery(_ result: TextSelectionService.ReplacementResult) -> Bool {
        Self.replacementRecoveryPolicy(for: result).isPersistent
    }

    private func resultRecoveryMessage(_ result: TextSelectionService.ReplacementResult) -> String {
        if case .staleCopiedToClipboard = result {
            return "The field changed after Bean read it, so Bean did not overwrite your newer text."
        }
        if case .replacementSentUnconfirmed = result {
            return "Bean sent the replacement but could not confirm what changed. Check the original field before continuing."
        }
        if case .clipboardPreservedRecoveryRequired = result {
            return "Bean could not replace the text. Your newer clipboard was preserved, and the correction remains here."
        }
        return "Bean could not confirm that the replacement landed. Focus the original field and try again, or copy it."
    }

    private func replaceFullField(element: AXUIElement, app: NSRunningApplication,
                                  corrected: String, original: String) async -> TextSelectionService.ReplacementResult {
        // `apply` has already completed the activation delay. Re-read the
        // exact target and value at the destructive boundary so typing during
        // activation can never be overwritten by the direct AX write.
        let currentElementBeforeWrite = AccessibilityService.focusedField(in: app)?.element
        let targetMatchesBeforeWrite = currentElementBeforeWrite.map {
            AccessibilityService.isSameElement($0, element)
        } ?? false
        guard Self.passiveTargetContinuityFailure(
            currentTargetExists: currentElementBeforeWrite != nil,
            targetsMatch: targetMatchesBeforeWrite,
            valueBefore: original,
            valueNow: AccessibilityService.value(of: element)
        ) == nil else {
            ClipboardService.writeString(corrected)
            return .staleCopiedToClipboard
        }

        if AccessibilityService.isValueSettable(element), AccessibilityService.setValue(corrected, on: element) {
            await Task.pause(Timing.afterActivate)
            if let after = AccessibilityService.value(of: element),
               after == corrected { return .replacedConfirmed }
        }

        let saved = ClipboardService.snapshot()
        ClipboardService.writeString(corrected)
        let beanClipboardChangeCount = ClipboardService.changeCount
        await Task.pause(Timing.afterActivate)
        ClipboardService.simulateSelectAll()
        await Task.pause(Timing.afterActivate)

        let clipboardStillOwnedBeforePaste = TextSelectionService.clipboardIsStillOwned(
            beanOwnedChangeCount: beanClipboardChangeCount,
            currentChangeCount: ClipboardService.changeCount
        )
        let currentElement = AccessibilityService.focusedField(in: app)?.element
        let targetsMatch = currentElement.map {
            AccessibilityService.isSameElement($0, element)
        } ?? false
        if !clipboardStillOwnedBeforePaste || Self.passiveTargetContinuityFailure(
            currentTargetExists: currentElement != nil,
            targetsMatch: targetsMatch,
            valueBefore: original,
            valueNow: AccessibilityService.value(of: element)
        ) != nil {
            return TextSelectionService.replacementResultAfterClipboardCompletion(
                .staleCopiedToClipboard,
                clipboardStillOwned: clipboardStillOwnedBeforePaste
            )
        }
        ClipboardService.simulatePaste()
        await Task.pause(Timing.afterPaste)

        let result = TextSelectionService.verificationResult(
            after: AccessibilityService.value(of: element),
            valueBefore: original,
            expectedAfter: corrected
        )
        let completion = TextSelectionService.clipboardCompletion(for: result)
        if case .restoreOriginal = completion {
            await Task.pause(Timing.beforeClipboardRestore)
        }
        let clipboardStillOwned = TextSelectionService.clipboardIsStillOwned(
            beanOwnedChangeCount: beanClipboardChangeCount,
            currentChangeCount: ClipboardService.changeCount
        )
        TextSelectionService.applyClipboardCompletion(
            completion,
            saved: saved,
            clipboardStillOwned: clipboardStillOwned
        )
        return TextSelectionService.replacementResultAfterClipboardCompletion(
            result,
            clipboardStillOwned: clipboardStillOwned
        )
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

    private func reactivateAndConfirm(_ app: NSRunningApplication) async -> Bool {
        guard !app.isTerminated else { return false }
        activate(app)
        await Task.pause(Timing.afterActivate)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            return true
        }
        activate(app)
        await Task.pause(Timing.afterActivationRetry)
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private func report(_ result: TextSelectionService.ReplacementResult) {
        switch result {
        case .replacedConfirmed: statusHUD.show(.success, "Field fixed")
        case .replacementSentUnconfirmed: statusHUD.dismiss()
        case .noChangesNeeded: statusHUD.show(.info, "No changes needed")
        case .copiedToClipboardFallback: statusHUD.show(.warning, "Could not replace text. Corrected text copied to clipboard.")
        case .staleCopiedToClipboard: statusHUD.show(.warning, "Text changed. Copied suggestion to clipboard.")
        case .clipboardPreservedRecoveryRequired: statusHUD.dismiss()
        case .failed(let reason): statusHUD.show(.error, reason)
        }
    }

    private func refreshAccounting() {
        usageLedger.refresh()
        history.refresh()
    }

    private func fingerprint(_ s: String) -> Int {
        var hash: UInt64 = 1469598103934665603
        for byte in s.utf8 { hash ^= UInt64(byte); hash = hash &* 1099511628211 }
        return Int(bitPattern: UInt(truncatingIfNeeded: hash))
    }
}
