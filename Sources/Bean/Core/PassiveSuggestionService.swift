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
    }
    private var current: Session?

    init(settings: AppSettings, userContent: UserContentStore, statusHUD: StatusHUD) {
        self.settings = settings
        self.userContent = userContent
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
        guard field.isTextLike, let value = field.value else { reason = "cannotReadText"; return false }
        guard categoryAllowed(field: field) else { reason = "appDisabled"; return false }

        let (leading, core, trailing) = TextNormalizer.split(value)
        guard core.count >= settings.passiveMinLength else { reason = "tooShort"; return false }
        guard value.count <= settings.passiveMaxLength else { reason = "textTooLong"; return false }
        if TextNormalizer.isCleanSingleWord(core), LocalTypoCorrector.correction(for: core) == nil {
            reason = "cleanWord"; return false
        }

        let fp = fingerprint(value)
        if fp == lastShownFingerprint { reason = "unchanged"; return false }
        if ignoredFingerprints.contains(fp) { reason = "ignored"; return false }
        if let last = lastCallTime, Date().timeIntervalSince(last) < 8 { reason = "rateLimited"; return false }
        lastCallTime = Date()

        let personalization = userContent.personalization(action: .proofread, context: context, explicitProfile: nil)
        let raw: String
        do {
            raw = try await transformer.transform(
                text: core, action: .proofread, context: context,
                personalization: personalization.systemBlock, extraContextLines: personalization.contextLines,
                provider: settings.provider, model: settings.model,
                apiKey: settings.apiKey, timeout: settings.timeoutSeconds)
        } catch { reason = "requestFailed"; return false }

        // Stale guard: typing resumed or field changed while in flight.
        guard isCurrent(),
              let nowValue = AccessibilityService.value(of: field.element),
              fingerprint(nowValue) == fp else { reason = "staleDiscarded"; return false }

        let outCore = TextNormalizer.stripArtifacts(raw, originalCore: core)
        if case .suspicious(let r) = OutputSafetyValidator.validate(input: core, output: outCore, action: .proofread) {
            reason = r; return false
        }
        guard outCore != core else { reason = "noChange"; return false }

        lastShownFingerprint = fp
        current = Session(app: app, element: field.element, fingerprint: fp,
                          sourceCore: core, leading: leading, trailing: trailing,
                          correctedCore: outCore, context: context)
        popover.present(
            previewText: outCore,
            showApply: !settings.passiveRequirePreview,
            onApply: { [weak self] in self?.applyCurrent() },
            onPreview: { [weak self] in self?.previewCurrent() },
            onIgnore: { [weak self] in self?.ignoreCurrent() },
            onCopy: { [weak self] in self?.copyCurrent() })
        reason = "shown"
        return true
    }

    // MARK: - Popover actions

    private func applyCurrent() {
        guard let session = current else { return }
        Task { await apply(session: session, correctedCore: session.correctedCore) }
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
        let model = PreviewModel(actionName: "Proofread", transformedText: session.correctedCore)
        model.helperText = "Review before replacing your text."
        model.allowsReplace = true
        model.onReplace = { [weak self] in
            Task { await self?.apply(session: session, correctedCore: model.transformedText) }
            self?.previewController.dismissPreview()
        }
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
        model.isRunning = true
        model.errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            defer { model.isRunning = false }
            let personalization = self.userContent.personalization(action: .proofread, context: session.context, explicitProfile: nil)
            do {
                let raw = try await self.transformer.transform(
                    text: session.sourceCore, action: .proofread, context: session.context,
                    personalization: personalization.systemBlock, extraContextLines: personalization.contextLines,
                    provider: self.settings.provider, model: self.settings.model,
                    apiKey: self.settings.apiKey, timeout: self.settings.timeoutSeconds)
                let outCore = TextNormalizer.stripArtifacts(raw, originalCore: session.sourceCore)
                if case .suspicious = OutputSafetyValidator.validate(input: session.sourceCore, output: outCore, action: .proofread) {
                    model.errorMessage = "That result looked unsafe — try again."; return
                }
                model.transformedText = outCore
            } catch { model.errorMessage = "Couldn't reach the model. Try again." }
        }
    }

    // MARK: - Apply (stale-safe)

    private func apply(session: Session, correctedCore: String) async {
        guard let app = session.app, !app.isTerminated else {
            ClipboardService.writeString(session.leading + correctedCore + session.trailing)
            statusHUD.show(.warning, "Text changed. Copied suggestion to clipboard.")
            return
        }
        guard let currentEl = AccessibilityService.focusedElement(),
              AccessibilityService.isSameElement(currentEl, session.element),
              let nowValue = AccessibilityService.value(of: session.element),
              fingerprint(nowValue) == session.fingerprint else {
            statusHUD.show(.warning, "Text changed. Run Bean again.")
            return
        }

        let corrected = session.leading + correctedCore + session.trailing
        let result = await replaceFullField(element: session.element, app: app, corrected: corrected, original: nowValue)
        report(result)
        lastShownFingerprint = nil
    }

    private func replaceFullField(element: AXUIElement, app: NSRunningApplication,
                                  corrected: String, original: String) async -> TextSelectionService.ReplacementResult {
        activate(app)
        await Task.pause(Timing.afterActivate)
        let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)

        if AccessibilityService.isValueSettable(element), AccessibilityService.setValue(corrected, on: element) {
            await Task.pause(Timing.afterActivate)
            if let after = AccessibilityService.value(of: element), after.contains(trimmed) { return .replacedConfirmed }
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
            if after.contains(trimmed) { result = .replacedConfirmed }
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

    private func fingerprint(_ s: String) -> Int {
        var hash: UInt64 = 1469598103934665603
        for byte in s.utf8 { hash ^= UInt64(byte); hash = hash &* 1099511628211 }
        return Int(bitPattern: UInt(truncatingIfNeeded: hash))
    }
}
