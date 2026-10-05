import AppKit
import ApplicationServices

// A quiet field control and exact native underlines share one review session.
// Cards open only after explicit activation. Accepting a suggestion changes
// its verified range, preserves unrelated rich content, and offers safe Undo.
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
    private let runParagraphAction: ((WritingAction) -> Void)?
    private let analysisDependencies: AnalysisDependencies
    private var runGeneration = 0

    /// Keep analysis orchestration testable without querying another app,
    /// opening overlay windows, or requiring the system spelling server.
    @MainActor
    struct AnalysisDependencies {
        var value: (AXUIElement) -> String? = { AccessibilityService.value(of: $0) }
        var rangeText: (AXUIElement, NSRange) -> String? = { AccessibilityService.string(in: $0, range: $1) }
        var rangeRect: (AXUIElement, NSRange) -> CGRect? = { TextRangeLocator.screenRects(for: $1, in: $0).first }
        var localAnalysis: ((String, [DictionaryTerm], Int, WritingDialect) -> IssueDetector.LocalAnalysis)?
        var present: (([HighlightOverlayController.Entry]) -> Void)?
        var selectedRange: (AXUIElement) -> NSRange? = { AccessibilityService.selectedRange(of: $0) }
        var anchor: (AXUIElement) -> CGRect? = { TextRangeLocator.fieldRect(for: $0) }
        var presentState: ((NativeAssistantState) -> Void)?
        var canEditRanges: (AXUIElement) -> Bool = { AccessibilityService.isSelectedRangeSettable($0) }
        var placementGeometry: (AXUIElement) -> FieldOverlayGeometry? = { AccessibilityService.fieldOverlayGeometry(for: $0) }
        var presentPlacement: ((FieldOverlayGeometry?) -> Void)?
        var monotonicTime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    }

    private var lastCallTime: Date?
    private var dismissed = DismissedIssueTracker()
    private var dismissalElement: AXUIElement?
    private(set) var assistantState = NativeAssistantState()
    var onLocalFeedback: ((Int) -> Void)?

    private struct AnalysisSnapshot {
        let element: AXUIElement
        let value: String
        var issues: [TextIssue]
        let configuration: CheckConfiguration
        var localLimitation: String? = nil
        var providerLimitation: String? = nil
    }
    private struct CheckConfiguration: Equatable {
        let dictionary: [DictionaryTerm]
        let provider: ProviderKind
        let model: String
        let usesProvider: Bool
        let providerVerified: Bool
        let issueLimit: Int
        let dialect: WritingDialect
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
    private var renderedSourceAnchor: CGRect?
    private var renderedPlacementGeometry: FieldOverlayGeometry?
    private var placementCheckedAt: TimeInterval = 0
    private var placementElement: AXUIElement?
    private var placementPID: pid_t?

    init(settings: AppSettings, userContent: UserContentStore,
         history: OperationHistoryStore, usageLedger: UsageLedgerStore,
         automaticCallBudget: AutomaticCallBudgetStore,
         undoStore: ReplacementUndoStore,
         statusHUD: StatusHUD,
         runAction: @escaping (WritingAction) -> Void,
         runParagraphAction: ((WritingAction) -> Void)? = nil,
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
        self.runParagraphAction = runParagraphAction
        if let analysisDependencies { self.analysisDependencies = analysisDependencies }
        else {
            var dependencies = AnalysisDependencies()
            dependencies.placementGeometry = { element in
                AccessibilityService.fieldOverlayGeometry(for: element, onDiagnostics: { result in
                    guard settings.diagnosticsEnabled else { return }
                    Log.diag(["nativePlacement": "capture", "reason": result.failureReason?.rawValue ?? "captured",
                        "nodeCount": String(result.nodeCount), "ancestorCount": String(result.ancestorCount),
                        "excludedBranchCount": String(result.excludedBranchCount),
                        "elapsedMilliseconds": String(result.elapsedMilliseconds)])
                })
            }
            self.analysisDependencies = dependencies
        }
        overlay.onActivateIssue = { [weak self] id in self?.activate(id) }
        overlay.onApply = { [weak self] id in self?.apply(id) }
        overlay.onApplyAlternative = { [weak self] id, choice in self?.apply(id, choice: choice) }
        overlay.onIgnore = { [weak self] id in self?.dismissIssue(id) }
        overlay.onLearnWord = { [weak self] id in self?.learnWord(id) }
        overlay.onNext = { [weak self] in self?.next() }
        overlay.onCloseCard = { [weak self] in self?.closeCard() }
        overlay.onWritingAction = { [weak self] action, paragraph in self?.performWritingAction(action, currentParagraph: paragraph) }
        overlay.onFixAll = { [weak self] in self?.fixAll() }
        overlay.onUndo = { [weak self] in self?.undoLastCorrection() }
        overlay.onPauseApp = { [weak self] in self?.pauseCurrentApp() }
        overlay.onPrepareAssistant = { [weak self] in self?.renderOverlay() }
    }

    func hideUI() {
        runGeneration += 1
        overlay.dismissExpandedUI()
        clearPresentation()
    }

    private func clearPresentation() {
        overlay.hide(); entries = []; selectedID = nil; session = nil; renderedSourceAnchor = nil
        renderedPlacementGeometry = nil; placementCheckedAt = 0
        placementElement = nil; placementPID = nil
    }

    /// Keep the same small control present across typing revisions. Cards and
    /// stale underlines close immediately; checking waits for the typing pause.
    func prepare(field: AccessibilityService.FocusedField, app: NSRunningApplication?) {
        guard !settings.isAssistancePaused(for: app?.bundleIdentifier) else { hideUI(); return }
        guard field.acceptsTextInput, !field.isSecure else { hideUI(); return }
        runGeneration += 1
        overlay.dismissExpandedUI()
        entries = []
        selectedID = nil
        session = Session(app: app, element: field.element, fingerprint: fingerprint(field.value ?? ""),
                          value: field.value ?? "")
        assistantState.phase = field.value == nil ? .unavailable("cannotReadText")
            : field.value?.isEmpty == true ? .ready : .waiting
        assistantState.localLimitation = nil
        assistantState.limitation = nil
        renderOverlay()
    }

    func typingBegan() {
        guard session != nil else { return }
        runGeneration += 1
        overlay.dismissExpandedUI()
        entries = []
        selectedID = nil
        assistantState.phase = .waiting
        assistantState.localLimitation = nil
        assistantState.limitation = nil
        renderOverlay()
    }

    func showUnavailable(field: AccessibilityService.FocusedField, app: NSRunningApplication?, reason: String) {
        guard field.acceptsTextInput, !field.isSecure else { hideUI(); return }
        session = Session(app: app, element: field.element, fingerprint: fingerprint(field.value ?? ""),
                          value: field.value ?? "")
        entries = []
        selectedID = nil
        assistantState.phase = .unavailable(reason)
        assistantState.localLimitation = nil
        assistantState.limitation = nil
        renderOverlay()
    }
    var isShowingUI: Bool { overlay.isShowing }
    /// Owning a review session also suppresses the legacy launcher when the
    /// compact dot has intentionally been hidden for lack of safe space.
    var ownsFocusedFieldSession: Bool { session != nil }
    var isApplyingCorrection: Bool { isApplying }
    var ownsUIInteraction: Bool { overlay.ownsKeyboardInteraction }
    var selectedIssueID: UUID? { selectedID }

    /// A successful Bean edit already remapped this exact session. The polling
    /// dispatcher can acknowledge it without closing the next correction card.
    func matchesCurrentSession(app: NSRunningApplication?, field: AccessibilityService.FocusedField) -> Bool {
        guard let session, let analysis,
              AccessibilityService.isSameElement(analysis.element, session.element),
              TextSelectionService.exactTextMatches(analysis.value, session.value),
              analysis.configuration == currentConfiguration() else { return false }
        return app?.processIdentifier == session.app?.processIdentifier
            && AccessibilityService.isSameElement(field.element, session.element)
            && TextSelectionService.exactTextMatches(field.value, session.value)
    }

    /// Keep geometry attached to live text when the source window moves or
    /// scrolls, and dismiss if focus/text no longer matches.
    func refreshVisibleTarget() {
        guard !isApplying, !ownsUIInteraction, let session else { return }
        guard let app = session.app,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let focused = AccessibilityService.focusedField(in: app)?.element,
              AccessibilityService.isSameElement(focused, session.element),
              TextSelectionService.exactTextMatches(AccessibilityService.value(of: session.element), session.value) else { hideUI(); return }
        let issues = (analysis.flatMap { TextSelectionService.exactTextMatches($0.value, session.value) ? $0.issues : nil } ?? entries.map(\.issue)).filter {
            !dismissed.contains($0)
        }
        let updated = remap(issues, in: session.value, element: session.element)
        let geometryChanged = updated.count != entries.count || zip(updated, entries).contains {
            $0.issue.id != $1.issue.id || $0.rect != $1.rect
        }
        let sourceAnchor = analysisDependencies.anchor(session.element)
        let previousPlacement = renderedPlacementGeometry
        refreshPlacementGeometry(for: session, sourceAnchor: sourceAnchor)
        let placementChanged = previousPlacement != renderedPlacementGeometry
        guard geometryChanged || sourceAnchor != renderedSourceAnchor || placementChanged else { return }
        entries = updated
        if !entries.contains(where: { $0.issue.id == selectedID }) { selectedID = nil }
        renderOverlay()
    }

    private func refreshPlacementGeometry(for session: Session, sourceAnchor: CGRect?) {
        let ownerChanged = (placementElement.map { !AccessibilityService.isSameElement($0, session.element) } ?? true)
            || placementPID != session.app?.processIdentifier
        if ownerChanged {
            renderedPlacementGeometry = nil; placementCheckedAt = 0
            placementElement = session.element; placementPID = session.app?.processIdentifier
        }
        if ownerChanged || analysisDependencies.monotonicTime() - placementCheckedAt >= 0.250
            || sourceAnchor != renderedSourceAnchor {
            renderedPlacementGeometry = analysisDependencies.placementGeometry(session.element)
            placementCheckedAt = analysisDependencies.monotonicTime()
        }
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
        guard !settings.isAssistancePaused(for: app?.bundleIdentifier ?? context.bundleIdentifier) else {
            reason = "appPaused"; hideUI(); return false
        }
        guard !field.isSecure, field.acceptsTextInput else { reason = "unsupportedField"; return false }
        guard let value = field.value else {
            reason = "cannotReadText"; showUnavailable(field: field, app: app, reason: reason); return false
        }
        guard !value.isEmpty else { prepare(field: field, app: app); reason = "empty"; return false }
        guard value.count <= Self.maximumInlineCharacters else {
            reason = "textTooLong"; showUnavailable(field: field, app: app, reason: reason); return false
        }
        let checkGeneration = runGeneration
        let fp = fingerprint(value)
        let configuration = currentConfiguration()
        let dialect = configuration.dialect
        guard !Task.isCancelled, isCurrent(), TextSelectionService.exactTextMatches(analysisDependencies.value(field.element), value) else {
            reason = "staleDiscarded"; return false
        }
        defer {
            if assistantState.phase == .checkingAI, reason != "staleDiscarded" {
                assistantState.phase = .complete
                assistantState.limitation = reason
                analysis?.providerLimitation = reason
                renderOverlay()
            }
        }
        if let analysis, AccessibilityService.isSameElement(analysis.element, field.element),
           TextSelectionService.exactTextMatches(analysis.value, value), analysis.configuration == configuration {
            guard !Task.isCancelled, checkGeneration == runGeneration, isCurrent(),
                  TextSelectionService.exactTextMatches(analysisDependencies.value(field.element), value) else {
                reason = "staleDiscarded"; return false
            }
            let cached = analysis.issues.filter { !dismissed.contains($0) }
            entries = remap(cached, in: value, element: field.element)
            session = Session(app: app, element: field.element, fingerprint: fp, value: value)
            selectedID = nil
            assistantState.localLimitation = analysis.localLimitation
            assistantState.limitation = analysis.providerLimitation
            assistantState.phase = cached.isEmpty || !entries.isEmpty ? .complete : .unavailable("cannotLocateRanges")
            guard !entries.isEmpty else {
                reason = cached.isEmpty ? "noIssues" : "cannotLocateRanges"
                renderOverlay()
                onLocalFeedback?(entries.count)
                AssistanceMetrics.shared.recordNativeAnalysis(inputLength: value.count, issueCount: entries.count,
                    elapsedMilliseconds: 0, cached: true, outcome: reason)
                return false
            }
            renderOverlay()
            onLocalFeedback?(entries.count)
            AssistanceMetrics.shared.recordNativeAnalysis(inputLength: value.count, issueCount: entries.count,
                elapsedMilliseconds: 0, cached: true, outcome: "shown")
            reason = "shown"
            return true
        }
        if dismissalElement.map({ AccessibilityService.isSameElement($0, field.element) }) == true {
            dismissed.update(to: value)
        } else {
            dismissalElement = field.element
            dismissed.reset(to: value)
        }
        entries = []
        selectedID = nil
        session = Session(app: app, element: field.element, fingerprint: fp, value: value)
        assistantState.phase = .checkingLocal
        assistantState.limitation = nil
        assistantState.localLimitation = nil
        renderOverlay()

        let localStartedAt = Date()
        var localDetector = detector
        localDetector.maxIssues = max(8, (value as NSString).length)
        let local = analysisDependencies.localAnalysis?(value, userContent.dictionary, localDetector.maxIssues, dialect)
            ?? localDetector.localAnalysis(in: value, dictionary: userContent.dictionary, dialect: dialect)
        var issues = local.issues
        let coverages = [local.spellingCoverage, local.grammarCoverage]
        let localLimitation: String?
        if coverages.contains(.invalidResponse) { localLimitation = "invalidResponse" }
        else if coverages.contains(.unavailable) { localLimitation = "unavailable" }
        else if coverages.contains(.limitReached) { localLimitation = "limitReached" }
        else { localLimitation = nil }
        assistantState.localLimitation = localLimitation
        AssistanceMetrics.shared.recordNativeAnalysis(inputLength: value.count, issueCount: issues.count,
            elapsedMilliseconds: Int(Date().timeIntervalSince(localStartedAt) * 1_000), cached: false, outcome: issues.isEmpty ? "noIssues" : "shown")
        guard !Task.isCancelled, checkGeneration == runGeneration, isCurrent(),
              TextSelectionService.exactTextMatches(analysisDependencies.value(field.element), value) else {
            reason = "staleDiscarded"; return false
        }
        // Local feedback appears immediately. A slower optional provider check
        // must never hold back the underline or simple in-field correction.
        analysis = AnalysisSnapshot(element: field.element, value: value, issues: issues,
                                    configuration: configuration, localLimitation: localLimitation)
        if !issues.isEmpty {
            session = Session(app: app, element: field.element, fingerprint: fp, value: value)
            entries = remap(issues.filter { !dismissed.contains($0) }, in: value, element: field.element)
            selectedID = nil
        }
        assistantState.phase = .complete
        renderOverlay()
        onLocalFeedback?(entries.count)
        var providerLimitation: String?
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
            maximumIssues: remainingLLMCapacity, dialect: dialect
        )
        let llmCooldownElapsed = lastCallTime.map {
            Date().timeIntervalSince($0) >= EngineConfig.automaticLLMCooldown
        } ?? true
        if wantsLLM, !providerInputWithinLimit {
            providerLimitation = "providerInputTooLong"
            if issues.isEmpty { reason = "providerInputTooLong"; return false }
        } else if wantsLLM, llmCooldownElapsed {
            assistantState.phase = .checkingAI
            renderOverlay()
            await Task.pause(.seconds(max(settings.passiveDelay, 1.2) - 0.45))
            guard !Task.isCancelled, checkGeneration == runGeneration, isCurrent(), currentConfiguration() == configuration,
                  TextSelectionService.exactTextMatches(analysisDependencies.value(field.element), value) else {
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
                providerLimitation = "automaticDailyLimit"
                reservation = nil
                if issues.isEmpty { reason = "automaticDailyLimit"; return false }
            case .unavailable:
                providerLimitation = "usageReservationUnavailable"
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
                        provider: provider, model: model, apiKey: apiKey, timeout: timeout, dialect: dialect
                    )
                    if llm.usage == nil || llm.failureOutcome != nil {
                        providerLimitation = llm.failureOutcome ?? "providerFailed"
                    }
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
                } else {
                    providerLimitation = "usageReservationUnavailable"
                    if issues.isEmpty { reason = "usageReservationUnavailable"; return false }
                }
            }
        } else if providerModeEnabled, !providerVerified, issues.isEmpty {
            reason = "providerNotVerified"; return false
        } else if wantsLLM, !llmCooldownElapsed, issues.isEmpty {
            reason = "rateLimited"; return false
        }

        guard checkGeneration == runGeneration, isCurrent(), currentConfiguration() == configuration,
              let nowValue = analysisDependencies.value(field.element), TextSelectionService.exactTextMatches(nowValue, value) else {
            reason = "staleDiscarded"; return false
        }

        issues = IssueDetector.nonOverlappingIssues(issues, limit: max(1, issues.count))
        analysis = AnalysisSnapshot(element: field.element, value: value, issues: issues,
                                    configuration: configuration, localLimitation: localLimitation,
                                    providerLimitation: providerLimitation)

        let visible = issues.filter { !dismissed.contains($0) }
        let mapped = remap(visible, in: value, element: field.element)
        session = Session(app: app, element: field.element, fingerprint: fp, value: value)
        assistantState.phase = visible.isEmpty || !mapped.isEmpty ? .complete : .unavailable("cannotLocateRanges")
        assistantState.limitation = providerLimitation
        guard !mapped.isEmpty else {
            entries = []
            renderOverlay()
            reason = visible.isEmpty ? "noIssues" : "cannotLocateRanges"
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
        selectedID = id
        diag(["inlineCardShown": "true"])
        renderOverlay()
    }

    private func closeCard() {
        selectedID = nil
        renderOverlay()
    }

    private func next() {
        guard let id = selectedID, let i = entries.firstIndex(where: { $0.issue.id == id }), !entries.isEmpty else { return }
        selectedID = entries[(i + 1) % entries.count].issue.id
        renderOverlay()
    }

    func dismissIssue(_ id: UUID) {
        guard let s = session, let i = entries.firstIndex(where: { $0.issue.id == id }) else { return }
        dismissed.dismiss(entries[i].issue)
        entries = remap((analysis?.issues ?? entries.map(\.issue)).filter { !dismissed.contains($0) },
                        in: s.value, element: s.element)
        selectedID = entries.isEmpty ? nil : entries[min(i, entries.count - 1)].issue.id
        assistantState.phase = .complete
        renderOverlay()
    }

    func learnWord(_ id: UUID) {
        guard let s = session, let issue = entries.first(where: { $0.issue.id == id })?.issue,
              issue.type == .spelling else { return }
        switch userContent.upsert(DictionaryTerm(term: issue.original)) {
        case .inserted, .updated, .rejectedDuplicate:
            let visible = (analysis?.issues ?? entries.map(\.issue)).filter {
                $0.original.caseInsensitiveCompare(issue.original) != .orderedSame
            }
            analysis = AnalysisSnapshot(element: s.element, value: s.value, issues: visible,
                                        configuration: currentConfiguration(), localLimitation: analysis?.localLimitation,
                                        providerLimitation: analysis?.providerLimitation)
            entries = remap(visible.filter { !dismissed.contains($0) }, in: s.value, element: s.element)
            selectedID = nil
            assistantState.phase = .complete
            renderOverlay()
        default:
            statusHUD.showWarning("That word couldn’t be saved. Check your dictionary in Settings.")
        }
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
              TextSelectionService.exactTextMatches(nowValue, s.value),
              let expected = InlineIssueMapping.expectedValue(afterApplying: chosen, to: nowValue) else {
            diag(["inlineApplyResult": "stale"])
            hideUI()
            statusHUD.show(.warning, "Your text changed. Bean kept your newer writing.")
            return
        }

        let selection = AccessibilityService.selectedRange(of: s.element)
        let replacementStartedAt = Date()
        let result = await replacementService.replaceRange(
            app: app, element: s.element, valueBefore: nowValue, range: entry.issue.range,
            replacement: chosen.suggestion, selectionToRestore: selection
        )
        recordAcceptance(result, inputLength: chosen.original.utf16.count, issueCount: 1, startedAt: replacementStartedAt)
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
        guard let updatedValue = AccessibilityService.value(of: s.element), TextSelectionService.exactTextMatches(updatedValue, expected) else {
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
                                    configuration: currentConfiguration(), localLimitation: analysis?.localLimitation,
                                    providerLimitation: analysis?.providerLimitation)
        dismissed.update(to: updatedValue)
        session = Session(app: app, element: s.element, fingerprint: newFp, value: updatedValue)
        entries = remap(remaining.filter { !dismissed.contains($0) }, in: updatedValue, element: s.element)
        let dropped = beforeCount - entries.count
        diag(["inlineApplyResult": "replacedConfirmed", "lineBreakPreserved": "true",
              "inlineRemainingIssues": String(entries.count), "inlineRemapDroppedCount": String(dropped)])

        let undo: (() -> Void)? = undoStore.isAvailable
            ? { [weak self] in self?.undoLastCorrection() } : nil
        statusHUD.showConfirmedSuccess("Suggestion applied", sourceAnchorRect: TextRangeLocator.fieldRect(for: s.element),
                                       onUndo: undo)
        selectedID = entries.first?.issue.id // Continue only an explicitly opened review.
        assistantState.phase = .complete
        renderOverlay()
    }

    // MARK: - Rendering / remap

    private func renderOverlay() {
        assistantState.issueCount = entries.count
        assistantState.aiAvailable = settings.hasAPIKey
        assistantState.safeFixCount = session.flatMap { s in
            let safe = safeIssues(in: s.value)
            return !safe.isEmpty && analysisDependencies.canEditRanges(s.element) ? safe.count : 0
        } ?? 0
        assistantState.scope = session.flatMap { analysisDependencies.selectedRange($0.element) }
            .map { $0.length > 0 ? "selected text" : "draft" } ?? "draft"
        assistantState.canPauseApp = session?.app?.bundleIdentifier != nil
        assistantState.canChooseParagraph = runParagraphAction != nil && (session.map {
            guard let caret = analysisDependencies.selectedRange($0.element),
                  analysisDependencies.canEditRanges($0.element) else { return false }
            return NativeActionScope.paragraphRange(in: $0.value, caret: caret) != nil
        } ?? false)
        assistantState.canUndo = session.map { undoStore.isAvailable(for: $0.element, value: $0.value, app: $0.app) } ?? false
        analysisDependencies.presentState?(assistantState)
        let sourceAnchor = session.flatMap { analysisDependencies.anchor($0.element) }
        if analysisDependencies.present == nil || analysisDependencies.presentPlacement != nil {
            if let session { refreshPlacementGeometry(for: session, sourceAnchor: sourceAnchor) }
            else { renderedPlacementGeometry = nil }
            analysisDependencies.presentPlacement?(renderedPlacementGeometry)
        }
        renderedSourceAnchor = sourceAnchor
        if let present = analysisDependencies.present {
            present(entries)
            return
        }
        let position: (index: Int, total: Int)? = selectedID.flatMap { id in
            entries.firstIndex(where: { $0.issue.id == id }).map { ($0, entries.count) }
        }
        overlay.showExplanation = settings.inlineShowExplanation
        overlay.assistantState = assistantState
        overlay.showsAssistantControl = settings.bubbleEnabled || (!entries.isEmpty && entries.allSatisfy { $0.rect == nil })
        overlay.render(entries: entries, selectedID: selectedID, position: position, sourceAnchor: sourceAnchor,
                       placementGeometry: renderedPlacementGeometry)
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

    private func performWritingAction(_ action: WritingAction, currentParagraph: Bool = false) {
        guard let captured = session, let app = captured.app, !app.isTerminated else { return }
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
            if currentParagraph, let runParagraphAction = self.runParagraphAction { runParagraphAction(action) }
            else { self.runAction(action) }
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
                           issueLimit: settings.inlineMaxIssues, dialect: settings.writingDialect)
    }

    private var automaticProviderIsPaused: Bool {
        settings.passivePausedUntil.map { $0 > Date() } ?? false
    }

    private func safeIssues(in value: String) -> [TextIssue] {
        guard let analysis, TextSelectionService.exactTextMatches(analysis.value, value),
              analysis.configuration == currentConfiguration() else { return [] }
        return Array(analysis.issues.filter {
            $0.source == .local && $0.confidence >= 0.95 && !dismissed.contains($0)
                && TextBoundarySafety.isSingleLine($0.original)
                && TextBoundarySafety.preservesLineBreakStructure(from: $0.original, to: $0.suggestion)
                && InlineIssueMapping.resolvedRange(for: $0, in: value) == $0.range
        }.prefix(NativeEditPlan.maximumEdits))
    }

    private func pauseCurrentApp() {
        guard let bundle = session?.app?.bundleIdentifier else { return }
        settings.pauseAssistance(in: bundle)
        hideUI()
    }

    private func fixAll() {
        guard !isApplying, let captured = session, let app = captured.app, !app.isTerminated else { return }
        let issues = safeIssues(in: captured.value)
        let edits = issues.map { NativeTextEdit(range: $0.range, original: $0.original, replacement: $0.suggestion) }
        guard !edits.isEmpty, NativeEditPlan.validated(original: captured.value, edits: edits) != nil else { return }
        isApplying = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isApplying = false }
            if #available(macOS 14.0, *) { app.activate() } else { app.activate(options: []) }
            await Task.pause(Timing.afterActivate)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  let field = AccessibilityService.focusedField(in: app),
                  AccessibilityService.isSameElement(field.element, captured.element),
                  TextSelectionService.exactTextMatches(field.value, captured.value) else {
                self.hideUI()
                self.statusHUD.showWarning("Your text changed. Bean kept your newer writing.")
                return
            }
            let replacementStartedAt = Date()
            let result = await self.replacementService.replaceEdits(app: app, element: captured.element,
                valueBefore: captured.value, edits: edits, selectionToRestore: AccessibilityService.selectedRange(of: captured.element))
            self.recordAcceptance(result, inputLength: captured.value.utf16.count, issueCount: edits.count, startedAt: replacementStartedAt)
            if result == .replacedConfirmed {
                self.analysis = nil
                self.hideUI()
                if let updated = AccessibilityService.focusedField(in: app) { self.prepare(field: updated, app: app) }
                self.statusHUD.showConfirmedSuccess("\(edits.count) obvious issues fixed", sourceAnchorRect: self.analysisDependencies.anchor(captured.element),
                    onUndo: self.undoStore.isAvailable ? { [weak self] in self?.undoLastCorrection() } : nil)
            } else {
                self.hideUI()
                self.statusHUD.showWarning("Bean couldn’t finish every correction. Review your field before trying again.")
            }
        }
    }

    private func recordAcceptance(_ result: TextSelectionService.ReplacementResult, inputLength: Int,
                                  issueCount: Int, startedAt: Date) {
        let outcome: String
        switch result {
        case .replacedConfirmed: outcome = "replacedConfirmed"
        case .replacementSentUnconfirmed: outcome = "replacementSentUnconfirmed"
        case .noChangesNeeded: outcome = "noChangesNeeded"
        default: outcome = "failed"
        }
        AssistanceMetrics.shared.record(kind: .nativeAcceptance, inputLength: inputLength, issueCount: issueCount,
            elapsedMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000), outcome: outcome)
    }

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
