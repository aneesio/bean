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
    private let settings: AppSettings
    private let userContent: UserContentStore
    private let history: OperationHistoryStore
    private let usageLedger: UsageLedgerStore
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
         statusHUD: StatusHUD) {
        self.settings = settings
        self.userContent = userContent
        self.history = history
        self.usageLedger = usageLedger
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
        guard PermissionService.isAccessibilityGranted else {
            return .unsupported(reason: InlineCoverageReason.noAccessibilityPermission)
        }
        if field.isSecure { return .unsupported(reason: InlineCoverageReason.secureField) }
        if field.isSearchLike { return .unsupported(reason: InlineCoverageReason.searchFieldDisabled) }

        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if AppCategory.from(bundleIdentifier: bundle) == .codeEditor {
            return .unsupported(reason: InlineCoverageReason.codeEditorDisabled)
        }
        // Web fields → browser extension; Electron → future app adapter. Native
        // AX inline isn't the right tool for either, so degrade to fallback.
        if AppCategory.isBrowser(bundle) {
            return .degraded(mode: .browserExtension, reason: InlineCoverageReason.webEditorRequiresExtension)
        }
        if AppCategory.isElectron(bundle) {
            return .degraded(mode: .appAdapter, reason: InlineCoverageReason.electronEditorRequiresAdapter)
        }

        guard field.acceptsTextInput, let value = field.value, !value.isEmpty else {
            return .unsupported(reason: InlineCoverageReason.richTextUnsupported)
        }
        guard value.count <= 1500 else { return .unsupported(reason: "textTooLong") }

        if TextRangeLocator.boundsAreReliable(for: field.element, valueLength: value.count) {
            return .supported(mode: .nativeAccessibility, confidence: 0.9)
        }
        return .degraded(mode: .passiveFallback, reason: InlineCoverageReason.nativeRangeBoundsMissing)
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
        let wantsLLM = issues.count < settings.inlineMaxIssues
            && !settings.inlineLocalOnly && settings.inlineIncludeLLM && !settings.apiKey.isEmpty
        let llmCooldownElapsed = lastCallTime.map {
            Date().timeIntervalSince($0) >= EngineConfig.automaticLLMCooldown
        } ?? true
        let automaticAllowed = usageLedger.allowsAutomaticCall(
            dailyLimit: settings.dailyAutomaticCallLimit)
        if wantsLLM, !automaticAllowed, issues.isEmpty {
            reason = "automaticDailyLimit"; return false
        } else if wantsLLM, !automaticAllowed {
            // Keep free local findings, but do not make a provider request.
        } else if wantsLLM, llmCooldownElapsed {
            lastCallTime = Date()
            let llm = await detector.llmIssues(in: value, context: context, dictionary: userContent.dictionary,
                                               provider: settings.provider, model: settings.model,
                                               apiKey: settings.apiKey, timeout: settings.timeoutSeconds)
            llmCount = llm.issues.count
            issues += llm.issues
            if let usage = llm.usage {
                usageLedger.record(usage, source: .nativeInline,
                                   provider: settings.provider.rawValue, model: settings.model)
                history.record(OperationRecord(
                    source: .nativeInline,
                    appName: context.appName,
                    appBundleIdentifier: context.bundleIdentifier,
                    appCategory: AppCategory.from(bundleIdentifier: context.bundleIdentifier).rawValue,
                    action: "detectIssues",
                    inputMode: context.acquisitionMode.rawLabel,
                    inputLength: value.count,
                    outputLength: llm.issues.reduce(0) { $0 + $1.suggestion.count },
                    provider: settings.provider.rawValue,
                    model: settings.model,
                    safetyResult: "structuredIssueMapping",
                    outcome: llm.issues.isEmpty ? "noIssues" : "issuesShown",
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens,
                    usageEstimated: usage.isEstimated
                ))
            }
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
            // LINE-BREAK SAFETY: never map (and thus never apply) an issue whose
            // original spans a paragraph/line break. Replacing such a range could
            // drop the newline or merge the next paragraph. The range we apply is
            // exactly issue.original, so refusing multi-line originals here makes
            // single Apply provably boundary-preserving.
            if issue.original.contains("\n") || issue.original.contains("\r") { lineBreakRefused += 1; continue }
            guard occurrences(of: issue.original, in: ns) == 1 else { continue }
            let range = ns.range(of: issue.original)
            guard range.location != NSNotFound else { continue }
            guard AccessibilityService.string(in: element, range: range) == issue.original else { continue }
            // Defense in depth: the live range text must also be break-free.
            let live = AccessibilityService.string(in: element, range: range) ?? ""
            if live.contains("\n") || live.contains("\r") { lineBreakRefused += 1; continue }
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
