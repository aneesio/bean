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
    private static let maximumInlineCharacters = 1_500

    private let settings: AppSettings
    private let userContent: UserContentStore
    private let history: OperationHistoryStore
    private let usageLedger: UsageLedgerStore
    private let automaticCallBudget: AutomaticCallBudgetStore
    private let statusHUD: StatusHUD

    private let detector = IssueDetector()
    private let overlay = HighlightOverlayController()

    private var lastFingerprint: Int?
    private var lastCallTime: Date?
    private var ignored = Set<String>()

    private struct Session {
        let app: NSRunningApplication?
        let element: AXUIElement
        var fingerprint: Int
    }
    private var session: Session?
    private var entries: [HighlightOverlayController.Entry] = []
    private var selectedID: UUID?

    init(settings: AppSettings, userContent: UserContentStore,
         history: OperationHistoryStore, usageLedger: UsageLedgerStore,
         automaticCallBudget: AutomaticCallBudgetStore,
         statusHUD: StatusHUD) {
        self.settings = settings
        self.userContent = userContent
        self.history = history
        self.usageLedger = usageLedger
        self.automaticCallBudget = automaticCallBudget
        self.statusHUD = statusHUD
        overlay.onActivateIssue = { [weak self] id in self?.activate(id) }
        overlay.onApply = { [weak self] id in self?.apply(id) }
        overlay.onIgnore = { [weak self] id in self?.ignore(id) }
        overlay.onNext = { [weak self] in self?.next() }
        overlay.onCloseCard = { [weak self] in self?.closeCard() }
    }

    func hideUI() { overlay.hide(); entries = []; selectedID = nil }
    var isShowingUI: Bool { overlay.isShowing }

    /// The technically-honest coverage classification for a field — drives both
    /// runtime routing and the user-facing "why" (native vs web vs fallback).
    func coverage(for field: AccessibilityService.FocusedField) -> InlineSupportResult {
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let boundsReliable = field.value.map {
            !$0.isEmpty && $0.count <= Self.maximumInlineCharacters
                && TextRangeLocator.boundsAreReliable(for: field.element, valueLength: $0.count)
        }
        let capabilities = FieldCapabilityPolicy.evaluate(
            bundleIdentifier: bundle,
            category: AppCategory.from(bundleIdentifier: bundle),
            traits: FieldTraits(field: field, nativeRangeBoundsReliable: boundsReliable),
            preferences: settings.capabilityPreferences
        )
        let assessment = capabilities.inlineChecking
        if field.value?.count ?? 0 > Self.maximumInlineCharacters {
            return .unsupported(reason: "textTooLong")
        }
        switch assessment.level {
        case .supported:
            return .supported(mode: .nativeAccessibility, confidence: 0.9)
        case .unsupported:
            return .unsupported(reason: assessment.reason)
        case .degraded:
            if AppCategory.isBrowser(bundle) {
                return .degraded(mode: .browserExtension, reason: assessment.reason)
            }
            if AppCategory.isElectron(bundle) {
                return .degraded(mode: .appAdapter, reason: assessment.reason)
            }
            return .degraded(mode: .passiveFallback, reason: assessment.reason)
        }
    }

    func support(for field: AccessibilityService.FocusedField) -> FieldSupport {
        switch coverage(for: field) {
        case .supported(.nativeAccessibility, _):
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
        guard let value = field.value, !value.isEmpty else { reason = "cannotReadText"; return false }
        let fp = fingerprint(value)
        if fp == lastFingerprint { reason = "unchanged"; return false }

        var issues = detector.localIssues(in: value, dictionary: userContent.dictionary)
        var llmCount = 0
        let remainingLLMCapacity = IssueDetector.remainingProviderIssueCapacity(
            totalLimit: settings.inlineMaxIssues, localIssueCount: issues.count
        )
        let provider = settings.provider
        let model = settings.model
        let providerModeEnabled = remainingLLMCapacity > 0
            && !settings.inlineLocalOnly && settings.inlineIncludeLLM
        // Legacy preferences or a just-changed provider/key can leave the old
        // automatic toggle on briefly. Never read Keychain, reserve budget, or
        // send field text unless this exact captured pair is still verified.
        let providerVerified = settings.isProviderConnectionVerified(
            provider: provider, model: model
        )
        let wantsLLM = providerModeEnabled && providerVerified && !settings.apiKey.isEmpty
        let providerInputWithinLimit = EngineConfig.providerInputIsWithinLimit(
            value,
            maximumCharacters: Self.maximumInlineCharacters
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
                            safetyResult: "structuredIssueMapping",
                            outcome: llm.issues.isEmpty ? "noIssues" : "issuesShown"
                        )
                    } else {
                        _ = reservation.fail(outcome: llm.failureOutcome ?? "providerFailed")
                    }
                    usageLedger.refresh()
                    history.refresh()
                    if llm.usage == nil, issues.isEmpty {
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

        guard isCurrent(), let nowValue = AccessibilityService.value(of: field.element), fingerprint(nowValue) == fp else {
            reason = "staleDiscarded"; return false
        }

        issues = issues.filter { !ignored.contains(ignoreKey(fp, $0)) }
        issues = Array(issues.prefix(settings.inlineMaxIssues))

        let mapped = remap(issues, in: value, element: field.element)
        guard !mapped.isEmpty else { reason = "cannotLocateRanges"; return false }

        lastFingerprint = fp
        session = Session(app: app, element: field.element, fingerprint: fp)
        entries = mapped
        selectedID = nil // highlights first; hover/click reveals a card
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

    private func ignore(_ id: UUID) {
        if let entry = entries.first(where: { $0.issue.id == id }), let s = session {
            ignored.insert(ignoreKey(s.fingerprint, entry.issue))
        }
        guard let i = entries.firstIndex(where: { $0.issue.id == id }) else { return }
        entries.remove(at: i)
        if entries.isEmpty { hideUI(); statusHUD.show(.info, "No more suggestions"); return }
        selectedID = entries[min(i, entries.count - 1)].issue.id // show next
        renderOverlay()
    }

    private func apply(_ id: UUID) {
        guard let s = session, let app = s.app, !app.isTerminated,
              let entry = entries.first(where: { $0.issue.id == id }) else {
            hideUI(); statusHUD.show(.warning, "Text changed. Run Bean again."); return
        }
        // Stale guard: same field, unchanged text, original still present.
        guard let current = AccessibilityService.focusedElement(),
              AccessibilityService.isSameElement(current, s.element),
              let nowValue = AccessibilityService.value(of: s.element),
              fingerprint(nowValue) == s.fingerprint,
              AccessibilityService.string(in: s.element, range: entry.issue.range) == entry.issue.original else {
            diag(["inlineApplyResult": "stale"])
            hideUI()
            statusHUD.show(.warning, "Text changed. Run Bean again.")
            return
        }

        if #available(macOS 14.0, *) { app.activate() } else { app.activate(options: []) }
        guard AccessibilityService.replaceRange(entry.issue.range, with: entry.issue.suggestion, in: s.element) else {
            diag(["inlineApplyResult": "fallbackCopy"])
            ClipboardService.writeString(entry.issue.suggestion)
            statusHUD.show(.warning, "Couldn't apply inline. Suggestion copied to clipboard.")
            return
        }

        // Apply succeeded → remap the remaining issues against the new text.
        let remaining = entries.filter { $0.issue.id != id }.map { $0.issue }
        let beforeCount = remaining.count
        guard let updatedValue = AccessibilityService.value(of: s.element) else {
            hideUI(); statusHUD.show(.success, "Fixed"); return
        }
        let newFp = fingerprint(updatedValue)
        session?.fingerprint = newFp
        lastFingerprint = newFp
        entries = remap(remaining, in: updatedValue, element: s.element)
        let dropped = beforeCount - entries.count
        diag(["inlineApplyResult": "replacedConfirmed", "lineBreakPreserved": "true",
              "inlineRemainingIssues": String(entries.count), "inlineRemapDroppedCount": String(dropped)])

        if entries.isEmpty {
            hideUI()
            statusHUD.show(.success, "All suggestions applied")
        } else {
            selectedID = entries.first?.issue.id // continue with the next issue
            statusHUD.show(.success, "Fixed")
            renderOverlay()
        }
    }

    // MARK: - Rendering / remap

    private func renderOverlay() {
        let position: (index: Int, total: Int)? = selectedID.flatMap { id in
            entries.firstIndex(where: { $0.issue.id == id }).map { ($0, entries.count) }
        }
        overlay.showExplanation = settings.inlineShowExplanation
        overlay.render(entries: entries, selectedID: selectedID, position: position)
    }

    /// Maps each issue's original substring to a unique current range + screen
    /// rect. Drops issues whose original is missing or ambiguous (the safe
    /// strategy after an edit shifts offsets).
    private func remap(_ issues: [TextIssue], in value: String, element: AXUIElement) -> [HighlightOverlayController.Entry] {
        let ns = value as NSString
        var result: [HighlightOverlayController.Entry] = []
        var lineBreakRefused = 0
        for issue in issues {
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
            guard occurrences(of: issue.original, in: ns) == 1 else { continue }
            let range = ns.range(of: issue.original)
            guard range.location != NSNotFound else { continue }
            guard AccessibilityService.string(in: element, range: range) == issue.original else { continue }
            // Defense in depth: the live range text must also be break-free.
            let live = AccessibilityService.string(in: element, range: range) ?? ""
            if !TextBoundarySafety.isSingleLine(live) { lineBreakRefused += 1; continue }
            guard let rect = TextRangeLocator.screenRects(for: range, in: element).first else { continue }
            var updated = issue
            updated.range = range
            result.append(HighlightOverlayController.Entry(issue: updated, rect: rect))
        }
        if lineBreakRefused > 0 { diag(["lineBreakRiskRefused": String(lineBreakRefused)]) }
        return result.sorted { $0.issue.range.location < $1.issue.range.location }
    }

    private func occurrences(of sub: String, in ns: NSString) -> Int {
        guard !sub.isEmpty else { return 0 }
        var count = 0, start = 0
        while start < ns.length {
            let r = ns.range(of: sub, options: [], range: NSRange(location: start, length: ns.length - start))
            if r.location == NSNotFound { break }
            count += 1
            start = r.location + max(r.length, 1)
        }
        return count
    }

    // MARK: - Helpers

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
