import AppKit
import ApplicationServices

// Phase 6 + redesign: selective inline highlights with a contextual,
// anchored correction experience. Highlights are the affordance (no top-right
// badge): hover/click a highlight → a card appears beside the word with the
// mistake and fix. Applying one issue fixes only that issue, remaps the
// remaining issues against the updated field text (dropping any that no longer
// map uniquely), and continues the session.
@MainActor
final class InlineHighlightService {
    private static let maximumInlineCharacters = 50_000
    private static let maximumAutomaticProviderCharacters = 1_500

    private let settings: AppSettings
    private let userContent: UserContentStore
    private let history: OperationHistoryStore
    private let usageLedger: UsageLedgerStore
    private let automaticCallBudget: AutomaticCallBudgetStore
    private let undoStore: ReplacementUndoStore
    private let statusHUD: StatusHUD

    private let detector = IssueDetector()
    private let overlay = HighlightOverlayController()
    private let replacementService: TextSelectionService
    private let runAction: (WritingAction) -> Void
    private let analysisDependencies: AnalysisDependencies
    private var runGeneration = 0

    /// Keep analysis orchestration testable without querying another app,
    /// opening overlay windows, or requiring the system spelling server.
    @MainActor
    struct AnalysisDependencies {
        var value: (AXUIElement) -> String? = { AccessibilityService.value(of: $0) }
        var rangeText: (AXUIElement, NSRange) -> String? = { AccessibilityService.string(in: $0, range: $1) }
        var rangeRect: (AXUIElement, NSRange) -> CGRect? = { TextRangeLocator.screenRects(for: $1, in: $0).first }
        var localIssues: ((String, [DictionaryTerm], Int) -> [TextIssue])?
        var present: (([HighlightOverlayController.Entry]) -> Void)?
    }

    private var lastCallTime: Date?
    private var ignored = Set<String>()

    private struct AnalysisSnapshot {
        let element: AXUIElement
        let value: String
        var issues: [TextIssue]
        let configuration: CheckConfiguration
    }
    private struct CheckConfiguration: Equatable {
        let dictionary: [DictionaryTerm]
        let provider: ProviderKind
        let model: String
        let usesProvider: Bool
        let providerVerified: Bool
        let issueLimit: Int
    }
    private var analysis: AnalysisSnapshot?
    private var isApplying = false

    private struct Session {
        let app: NSRunningApplication?
        let element: AXUIElement
        var fingerprint: Int
        var value: String
    }
    private var session: Session?
    private var entries: [HighlightOverlayController.Entry] = []
    private var selectedID: UUID?
    private var floatingCardSuppressed = false
    private var renderedSourceAnchor: CGRect?

    init(settings: AppSettings, userContent: UserContentStore,
         history: OperationHistoryStore, usageLedger: UsageLedgerStore,
         automaticCallBudget: AutomaticCallBudgetStore,
         undoStore: ReplacementUndoStore,
         statusHUD: StatusHUD,
         runAction: @escaping (WritingAction) -> Void,
         analysisDependencies: AnalysisDependencies? = nil) {
        self.settings = settings
        self.userContent = userContent
        self.history = history
        self.usageLedger = usageLedger
        self.automaticCallBudget = automaticCallBudget
        self.undoStore = undoStore
        self.replacementService = TextSelectionService(undoStore: undoStore)
        self.statusHUD = statusHUD
        self.runAction = runAction
        self.analysisDependencies = analysisDependencies ?? AnalysisDependencies()
        overlay.onActivateIssue = { [weak self] id in self?.activate(id) }
        overlay.onApply = { [weak self] id in self?.apply(id) }
        overlay.onApplyAlternative = { [weak self] id, choice in self?.apply(id, choice: choice) }
        overlay.onIgnore = { [weak self] id in self?.ignore(id) }
        overlay.onNext = { [weak self] in self?.next() }
        overlay.onCloseCard = { [weak self] in self?.closeCard() }
        overlay.onWritingAction = { [weak self] in
            self?.performWritingAction()
        }
    }

    func hideUI() {
        runGeneration += 1
        clearPresentation()
    }

    private func clearPresentation() {
        overlay.hide(); entries = []; selectedID = nil; session = nil; renderedSourceAnchor = nil
    }
    var isShowingUI: Bool { overlay.isShowing }
    var isApplyingCorrection: Bool { isApplying }
    var ownsUIInteraction: Bool { overlay.ownsKeyboardInteraction }

    /// A successful Bean edit already remapped this exact session. The polling
    /// dispatcher can acknowledge it without closing the next correction card.
    func matchesCurrentSession(app: NSRunningApplication?, field: AccessibilityService.FocusedField) -> Bool {
        guard let session else { return false }
        return app?.processIdentifier == session.app?.processIdentifier
            && AccessibilityService.isSameElement(field.element, session.element)
            && field.value == session.value
    }

    /// Keep geometry attached to live text when the source window moves or
    /// scrolls, and dismiss if focus/text no longer matches.
    func refreshVisibleTarget() {
        guard !isApplying, !ownsUIInteraction, let session else { return }
        guard let app = session.app,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let focused = AccessibilityService.focusedField(in: app)?.element,
              AccessibilityService.isSameElement(focused, session.element),
              AccessibilityService.value(of: session.element) == session.value else { hideUI(); return }
        let issues = (analysis?.issues ?? entries.map(\.issue)).filter {
            !ignored.contains(ignoreKey(session.fingerprint, $0))
        }
        let updated = remap(issues, in: session.value, element: session.element)
        let geometryChanged = updated.count != entries.count || zip(updated, entries).contains {
            $0.issue.id != $1.issue.id || $0.rect != $1.rect
        }
        let sourceAnchor = TextRangeLocator.fieldRect(for: session.element)
            ?? TextRangeLocator.caretRect(for: session.element)
        guard geometryChanged || sourceAnchor != renderedSourceAnchor else { return }
        entries = updated
        if !entries.contains(where: { $0.issue.id == selectedID }) { selectedID = nil }
        renderOverlay()
    }

    /// The technically-honest coverage classification for a field — drives both
    /// runtime routing and the user-facing "why" (native vs web vs fallback).
    func coverage(for field: AccessibilityService.FocusedField) -> InlineSupportResult {
        guard PermissionService.isAccessibilityGranted else {
            return .unsupported(reason: InlineCoverageReason.noAccessibilityPermission)
        }
        guard field.isEnabled, !field.isSecure, field.acceptsTextInput else {
            return .unsupported(reason: field.isSecure ? "secureField" : "notEditableText")
        }
        guard let value = field.value else { return .unsupported(reason: "cannotReadText") }
        guard value.count <= Self.maximumInlineCharacters else { return .unsupported(reason: "textTooLong") }
        if TextRangeLocator.boundsAreReliable(for: field.element, value: value) {
            return .supported(mode: .nativeAccessibility, confidence: 0.9)
        }
        return .degraded(mode: .floatingSuggestions, reason: "nativeRangeBoundsMissing")
    }

    func support(for field: AccessibilityService.FocusedField) -> FieldSupport {
        switch coverage(for: field) {
        case .supported(.nativeAccessibility, _):
            return .supported
        case .degraded(.floatingSuggestions, _):
            return .supported
        case .supported(_, _):
            return .degradedUsePopover(reason: InlineCoverageReason.unknown)
        case .degraded(_, let reason):
            return .degradedUsePopover(reason: reason)
        case .unsupported(let reason):
            return .unsupported(reason: reason)
        }
    }

    // MARK: - Run (dispatcher calls this for supported fields)

    func run(field: AccessibilityService.FocusedField, app: NSRunningApplication?,
             context: SourceAppContext, isCurrent: @escaping () -> Bool, reason: inout String) async -> Bool {
        guard !field.isSecure, field.acceptsTextInput else { reason = "unsupportedField"; return false }
        guard let value = field.value, !value.isEmpty else { reason = "cannotReadText"; return false }
        guard value.count <= Self.maximumInlineCharacters else { reason = "textTooLong"; return false }
        let checkGeneration = runGeneration
        let fp = fingerprint(value)
        let configuration = currentConfiguration()
        if let analysis, AccessibilityService.isSameElement(analysis.element, field.element),
           analysis.value == value, analysis.configuration == configuration {
            guard !Task.isCancelled, checkGeneration == runGeneration, isCurrent(),
                  analysisDependencies.value(field.element) == value else {
                reason = "staleDiscarded"; return false
            }
            let cached = analysis.issues.filter { !ignored.contains(ignoreKey(fp, $0)) }
            entries = remap(cached, in: value, element: field.element)
            guard !entries.isEmpty else {
                clearPresentation()
                reason = cached.isEmpty ? "noIssues" : "cannotLocateRanges"
                return false
            }
            session = Session(app: app, element: field.element, fingerprint: fp, value: value)
            selectedID = nil
            renderOverlay()
            reason = "shown"
            return true
        }
        clearPresentation()
        ignored.removeAll()
        floatingCardSuppressed = false

        var localDetector = detector
        localDetector.maxIssues = max(8, (value as NSString).length)
        var issues = analysisDependencies.localIssues?(value, userContent.dictionary, localDetector.maxIssues)
            ?? localDetector.localIssues(in: value, dictionary: userContent.dictionary)
        guard !Task.isCancelled, checkGeneration == runGeneration, isCurrent(),
              analysisDependencies.value(field.element) == value else {
            reason = "staleDiscarded"; return false
        }
        // Local feedback appears immediately. A slower optional provider check
        // must never hold back the underline or simple in-field correction.
        if !issues.isEmpty {
            analysis = AnalysisSnapshot(element: field.element, value: value, issues: issues,
                                        configuration: configuration)
            session = Session(app: app, element: field.element, fingerprint: fp, value: value)
            entries = remap(issues, in: value, element: field.element)
            selectedID = nil
            renderOverlay()
        }
        var llmCount = 0
        let remainingLLMCapacity = IssueDetector.remainingProviderIssueCapacity(
            totalLimit: settings.inlineMaxIssues, localIssueCount: issues.count
        )
        let provider = settings.provider
        let model = settings.model
        let providerModeEnabled = remainingLLMCapacity > 0
            && !settings.inlineLocalOnly && settings.inlineIncludeLLM
            && !automaticProviderIsPaused
        // Legacy preferences or a just-changed provider/key can leave the old
        // automatic toggle on briefly. Never read Keychain, reserve budget, or
        // send field text unless this exact captured pair is still verified.
        let providerVerified = settings.isProviderConnectionVerified(
            provider: provider, model: model
        )
        let wantsLLM = providerModeEnabled && providerVerified && !settings.apiKey.isEmpty
        let providerInputWithinLimit = EngineConfig.providerInputIsWithinLimit(
            value,
            maximumCharacters: Self.maximumAutomaticProviderCharacters
        ) && IssueDetector.providerPayloadIsWithinLimit(
            text: value,
            context: context,
            dictionary: userContent.dictionary,
            maximumIssues: remainingLLMCapacity
        )
        let llmCooldownElapsed = lastCallTime.map {
            Date().timeIntervalSince($0) >= EngineConfig.automaticLLMCooldown
        } ?? true
        if wantsLLM, !providerInputWithinLimit {
            if issues.isEmpty { reason = "providerInputTooLong"; return false }
        } else if wantsLLM, llmCooldownElapsed {
            await Task.pause(.seconds(max(settings.passiveDelay, 1.2) - 0.45))
            guard !Task.isCancelled, checkGeneration == runGeneration, isCurrent(), currentConfiguration() == configuration,
                  analysisDependencies.value(field.element) == value else {
                reason = "staleDiscarded"; return false
            }
            let apiKey = settings.apiKey
            let timeout = settings.timeoutSeconds
            let metadata = AutomaticCallMetadata(
                source: .nativeInline, context: context,
                action: "detectIssues", inputLength: value.count,
                provider: provider.rawValue, model: model
            )
            let reservation: AutomaticCallBudgetStore.Reservation?
            switch automaticCallBudget.reserve(
                dailyLimit: settings.dailyAutomaticCallLimit,
                leaseDuration: max(timeout + 30, 60),
                metadata: metadata
            ) {
            case .reserved(let value):
                reservation = value
            case .limitReached:
                reservation = nil
                if issues.isEmpty { reason = "automaticDailyLimit"; return false }
            case .unavailable:
                reservation = nil
                if issues.isEmpty { reason = "usageReservationUnavailable"; return false }
            }

            if let reservation {
                defer { reservation.cancel() }
                if reservation.beginProviderAttempt() {
                    lastCallTime = Date()
                    var llmDetector = detector
                    llmDetector.maxIssues = remainingLLMCapacity
                    let llm = await llmDetector.llmIssues(
                        in: value, context: context, dictionary: userContent.dictionary,
                        provider: provider, model: model, apiKey: apiKey, timeout: timeout
                    )
                    llmCount = llm.issues.count
                    issues += llm.issues
                    if let usage = llm.usage {
                        _ = reservation.complete(
                            usage: usage,
                            outputLength: llm.issues.reduce(0) { $0 + $1.suggestion.count },
                            safetyResult: llm.failureOutcome ?? "structuredIssueMapping",
                            outcome: llm.failureOutcome ?? (llm.issues.isEmpty ? "noIssues" : "issuesShown")
                        )
                    } else {
                        _ = reservation.fail(outcome: llm.failureOutcome ?? "providerFailed")
                    }
                    usageLedger.refresh()
                    history.refresh()
                    if (llm.usage == nil || llm.failureOutcome != nil), issues.isEmpty {
                        reason = llm.failureOutcome ?? "providerFailed"
                        return false
                    }
                } else if issues.isEmpty {
                    reason = "usageReservationUnavailable"
                    return false
                }
            }
        } else if providerModeEnabled, !providerVerified, issues.isEmpty {
            reason = "providerNotVerified"; return false
        } else if wantsLLM, !llmCooldownElapsed, issues.isEmpty {
            reason = "rateLimited"; return false
        }

        guard checkGeneration == runGeneration, isCurrent(), currentConfiguration() == configuration,
              let nowValue = analysisDependencies.value(field.element), nowValue == value else {
            reason = "staleDiscarded"; return false
        }

        issues = issues.filter { !ignored.contains(ignoreKey(fp, $0)) }
        issues = IssueDetector.nonOverlappingIssues(issues, limit: max(1, issues.count))
        analysis = AnalysisSnapshot(element: field.element, value: value, issues: issues,
                                    configuration: configuration)

        let mapped = remap(issues, in: value, element: field.element)
        guard !mapped.isEmpty else {
            clearPresentation()
            reason = issues.isEmpty ? "noIssues" : "cannotLocateRanges"
            return false
        }

        session = Session(app: app, element: field.element, fingerprint: fp, value: value)
        entries = mapped
        if !entries.contains(where: { $0.issue.id == selectedID }) { selectedID = nil }
        diag(["issueCount": String(mapped.count), "localIssueCount": String(max(mapped.count - llmCount, 0)), "llmIssueCount": String(llmCount)])
        renderOverlay()
        reason = "shown"
        return true
    }

    // MARK: - Card interaction

    private func activate(_ id: UUID) {
        guard entries.contains(where: { $0.issue.id == id }) else { return }
        floatingCardSuppressed = false
        selectedID = id
        diag(["inlineCardShown": "true"])
        renderOverlay()
    }

    private func closeCard() {
        selectedID = nil
        floatingCardSuppressed = true
        renderOverlay()
    }

    private func next() {
        guard let id = selectedID, let i = entries.firstIndex(where: { $0.issue.id == id }), !entries.isEmpty else { return }
        selectedID = entries[(i + 1) % entries.count].issue.id
        renderOverlay()
    }

    private func ignore(_ id: UUID) {
        guard let s = session, let i = entries.firstIndex(where: { $0.issue.id == id }) else { return }
        ignored.insert(ignoreKey(s.fingerprint, entries[i].issue))
        analysis?.issues.removeAll(where: { $0.id == id })
        entries = remap(analysis?.issues ?? entries.filter { $0.issue.id != id }.map(\.issue),
                        in: s.value, element: s.element)
        if entries.isEmpty { hideUI(); statusHUD.show(.info, "No more suggestions"); return }
        selectedID = entries[min(i, entries.count - 1)].issue.id // show next
        renderOverlay()
    }

    private func apply(_ id: UUID, choice: String? = nil) {
        guard !isApplying else { return }
        Task { [weak self] in await self?.applyIssue(id, choice: choice) }
    }

    private func applyIssue(_ id: UUID, choice: String?) async {
        guard !isApplying else { return }
        guard let s = session, let app = s.app, !app.isTerminated,
              let entry = entries.first(where: { $0.issue.id == id }) else {
            hideUI(); statusHUD.show(.warning, "Return to your text to check it again."); return
        }
        guard let chosen = entry.issue.choosingSuggestion(choice ?? entry.issue.suggestion) else { return }
        isApplying = true
        defer { isApplying = false }
        // Explicit overlay interaction can make Bean key. Activation is
        // asynchronous, so restore the source before validating its live field.
        if #available(macOS 14.0, *) { app.activate() } else { app.activate(options: []) }
        await Task.pause(Timing.afterActivate)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let current = AccessibilityService.focusedField(in: app)?.element,
              AccessibilityService.isSameElement(current, s.element),
              let nowValue = AccessibilityService.value(of: s.element),
              nowValue == s.value,
              let expected = InlineIssueMapping.expectedValue(afterApplying: chosen, to: nowValue) else {
            diag(["inlineApplyResult": "stale"])
            hideUI()
            statusHUD.show(.warning, "Your text changed. Bean kept your newer writing.")
            return
        }

        let selection = AccessibilityService.selectedRange(of: s.element)
        let result = await replacementService.replaceRange(
            app: app, element: s.element, valueBefore: nowValue, range: entry.issue.range,
            replacement: chosen.suggestion, selectionToRestore: selection
        )
        switch result {
        case .replacedConfirmed: break
        case .replacementSentUnconfirmed:
            hideUI()
            statusHUD.show(.warning, "Bean couldn't confirm the change. Check your text before applying again.")
            return
        case .copiedToClipboardFallback:
            statusHUD.show(.warning, "This app couldn't apply the fix. The suggestion was copied.")
            return
        case .staleCopiedToClipboard:
            hideUI()
            statusHUD.show(.warning, "Your text changed. The suggestion is on the clipboard.")
            return
        case .clipboardPreservedRecoveryRequired:
            statusHUD.show(.warning, "Your clipboard changed. Bean kept it safe; your suggestion is still here.")
            return
        case .noChangesNeeded:
            hideUI()
            return
        case .failed(let reason):
            statusHUD.show(.warning, reason)
            return
        }
        guard let updatedValue = AccessibilityService.value(of: s.element), updatedValue == expected else {
            // The shared replacement path already confirmed this edit. New
            // typing afterward invalidates the cards, not that confirmation.
            diag(["inlineApplyResult": "replacedConfirmedNewerText"])
            analysis = nil
            hideUI()
            statusHUD.showConfirmedSuccess("Suggestion applied", sourceAnchorRect: TextRangeLocator.fieldRect(for: s.element))
            return
        }
        let remaining = InlineIssueMapping.issuesAfterApplying(
            chosen, to: analysis?.issues ?? entries.map(\.issue),
            valueBefore: nowValue, valueAfter: updatedValue
        )
        let beforeCount = remaining.count
        let newFp = fingerprint(updatedValue)
        analysis = AnalysisSnapshot(element: s.element, value: updatedValue, issues: remaining,
                                    configuration: currentConfiguration())
        ignored.removeAll()
        session = Session(app: app, element: s.element, fingerprint: newFp, value: updatedValue)
        entries = remap(remaining, in: updatedValue, element: s.element)
        let dropped = beforeCount - entries.count
        diag(["inlineApplyResult": "replacedConfirmed", "lineBreakPreserved": "true",
              "inlineRemainingIssues": String(entries.count), "inlineRemapDroppedCount": String(dropped)])

        let undo: (() -> Void)? = undoStore.isAvailable
            ? { [weak self] in self?.undoLastCorrection() } : nil
        statusHUD.showConfirmedSuccess("Suggestion applied", sourceAnchorRect: TextRangeLocator.fieldRect(for: s.element),
                                       onUndo: undo)
        if entries.isEmpty {
            hideUI()
        } else {
            selectedID = entries.first?.issue.id // continue with the next issue
            renderOverlay()
        }
    }

    // MARK: - Rendering / remap

    private func renderOverlay() {
        if selectedID == nil, !floatingCardSuppressed, !entries.isEmpty, entries.allSatisfy({ $0.rect == nil }) {
            selectedID = entries.first?.issue.id
        }
        if let present = analysisDependencies.present {
            present(entries)
            return
        }
        let position: (index: Int, total: Int)? = selectedID.flatMap { id in
            entries.firstIndex(where: { $0.issue.id == id }).map { ($0, entries.count) }
        }
        overlay.showExplanation = settings.inlineShowExplanation
        overlay.writingActionLabel = settings.hasAPIKey ? "AI Proofread" : "Quick Fix"
        let sourceAnchor = session.flatMap {
            TextRangeLocator.fieldRect(for: $0.element) ?? TextRangeLocator.caretRect(for: $0.element)
        }
        renderedSourceAnchor = sourceAnchor
        overlay.render(entries: entries, selectedID: selectedID, position: position, sourceAnchor: sourceAnchor)
    }

    private func undoLastCorrection() {
        guard !isApplying else { return }
        Task { [weak self] in
            guard let self else { return }
            self.isApplying = true
            defer { self.isApplying = false }
            let result = await self.undoStore.undo()
            if result == .replacedConfirmed {
                self.analysis = nil
                self.hideUI()
                self.statusHUD.show(.success, "Change undone")
            } else if case .failed(let reason) = result {
                self.statusHUD.show(.warning, reason)
            } else {
                self.statusHUD.show(.warning, "Bean couldn't confirm Undo. Check your text.")
            }
        }
    }

    private func performWritingAction() {
        guard let captured = session, let app = captured.app, !app.isTerminated else { return }
        let action: WritingAction = settings.hasAPIKey ? .proofread : .localQuickCheck
        hideUI()
        Task { [weak self] in
            guard let self else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
                    self.statusHUD.show(.warning, "Return to the original field, then choose Bean again.")
                    return
                }
                if #available(macOS 14.0, *) { app.activate() }
                else { app.activate(options: []) }
                await Task.pause(Timing.afterActivate)
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  let field = AccessibilityService.focusedField(in: app),
                  AccessibilityService.isSameElement(field.element, captured.element) else {
                self.statusHUD.show(.warning, "Return to the original field, then choose Bean again.")
                return
            }
            self.runAction(action)
        }
    }

    /// Preserve exact detector offsets, including repeated misspellings. A
    /// unique-substring fallback handles candidates without a usable offset.
    private func remap(_ issues: [TextIssue], in value: String, element: AXUIElement) -> [HighlightOverlayController.Entry] {
        var result: [HighlightOverlayController.Entry] = []
        var lineBreakRefused = 0
        for issue in issues {
            if result.count >= max(1, settings.inlineMaxIssues) { break }
            // LINE-BREAK SAFETY: native inline issues are single-line and their
            // suggestion must preserve the exact CR/LF/Unicode boundary shape.
            // This blocks provider output from inserting a new line or paragraph
            // separator into an otherwise safe range.
            if !TextBoundarySafety.isSingleLine(issue.original)
                || !TextBoundarySafety.preservesLineBreakStructure(
                    from: issue.original, to: issue.suggestion
                ) {
                lineBreakRefused += 1
                continue
            }
            guard let range = InlineIssueMapping.resolvedRange(for: issue, in: value) else { continue }
            // Some native editors expose AXValue and bounds without
            // AXStringForRange. The exact snapshot already proves this range.
            if let live = analysisDependencies.rangeText(element, range), live != issue.original { continue }
            let rect = analysisDependencies.rangeRect(element, range)
            var updated = issue
            updated.range = range
            result.append(HighlightOverlayController.Entry(issue: updated, rect: rect))
        }
        if lineBreakRefused > 0 { diag(["lineBreakRiskRefused": String(lineBreakRefused)]) }
        return result.sorted { $0.issue.range.location < $1.issue.range.location }
    }

    // MARK: - Helpers

    private func currentConfiguration() -> CheckConfiguration {
        CheckConfiguration(dictionary: userContent.dictionary, provider: settings.provider,
                           model: settings.model,
                           usesProvider: !settings.inlineLocalOnly && settings.inlineIncludeLLM && !automaticProviderIsPaused,
                           providerVerified: settings.isProviderConnectionVerified,
                           issueLimit: settings.inlineMaxIssues)
    }

    private var automaticProviderIsPaused: Bool {
        settings.passivePausedUntil.map { $0 > Date() } ?? false
    }

    private func ignoreKey(_ fp: Int, _ issue: TextIssue) -> String { "\(fp):\(issue.original):\(issue.range.location)" }

    private func diag(_ extra: [String: String]) {
        guard settings.diagnosticsEnabled else { return }
        var fields = ["inline": "true"]
        fields.merge(extra) { _, new in new }
        Log.diag(fields)
    }

    private func fingerprint(_ s: String) -> Int {
        var hash: UInt64 = 1469598103934665603
        for byte in s.utf8 { hash ^= UInt64(byte); hash = hash &* 1099511628211 }
        return Int(bitPattern: UInt(truncatingIfNeeded: hash))
    }
}
