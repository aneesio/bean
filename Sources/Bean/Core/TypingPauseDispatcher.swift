import AppKit

// The SINGLE owner of the global key/mouse/focus monitors for Passive
// Suggestions, Inline Highlights, and the Bean Bubble. There are no other
// global monitors anywhere in the app.
//
// Typing pause routes to ONE of: Inline → (fallback) Passive → Passive → nothing.
// The Bean Bubble is the LOWEST-priority helper: it's considered on
// focus/selection and after a typing pause, but only when no richer Bean UI is
// active.
//
// Priority: Inline > Passive > Action/Preview (busy) > Bubble > nothing.
@MainActor
final class TypingPauseDispatcher {
    private let settings: AppSettings
    private let passive: PassiveSuggestionService
    private let inline: InlineHighlightService
    private let bubble: BeanBubbleService
    private let coordinatorIsBusy: () -> Bool

    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var pendingDispatch: DispatchWorkItem?
    private var pendingBubble: DispatchWorkItem?
    private var bubblePresentationRevision = 0
    private var permissionRetry: DispatchWorkItem?
    private var targetValidationTimer: Timer?
    private var generation = 0
    private var fieldActivity = TypingPauseActivityTracker()
    private var lastObservedElement: AXUIElement?
    private var fieldIdentity = 0
    private let browserOwnership = BrowserFieldOwnershipStore()
    private var browserOwnershipWasActive = false
    private var browserOwnershipTarget: AXUIElement?
    private var browserOwnershipTargetIsWebContent = false
    private var browserOwnershipTargetCheckedAt = Date.distantPast
    private var nextBrowserOwnershipCleanup = Date.distantPast
    private var pendingFeedback: (generation: Int, startedAt: Date, inputLength: Int)?

    init(settings: AppSettings, passive: PassiveSuggestionService, inline: InlineHighlightService,
         bubble: BeanBubbleService, coordinatorIsBusy: @escaping () -> Bool) {
        self.settings = settings
        self.passive = passive
        self.inline = inline
        self.bubble = bubble
        self.coordinatorIsBusy = coordinatorIsBusy
        inline.onLocalFeedback = { [weak self] count in self?.recordLocalFeedback(issueCount: count) }
        inline.onWillPresentUI = { [weak self] in self?.revokeFallbackBubble() }
        passive.onWillPresentUI = { [weak self] in self?.revokeFallbackBubble() }
    }

    private var wantsMonitor: Bool {
        settings.passiveActive || settings.inlineHighlightsEnabled || settings.bubbleEnabled
    }

    private var isInteractingWithBean: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            && (inline.ownsUIInteraction || bubble.ownsUIInteraction)
    }

    func refresh() {
        if wantsMonitor && PermissionService.isAccessibilityGranted { start() } else { stop() }
        // Mouse monitor: needed for the bubble (focus/selection) and to dismiss
        // inline highlights when the user clicks elsewhere in the field.
        if settings.bubbleEnabled || settings.inlineHighlightsEnabled { installMouseMonitor() } else { removeMouseMonitor() }
        settings.monitorActive = (keyMonitor != nil || targetValidationTimer != nil)
        if wantsMonitor, keyMonitor == nil { schedulePermissionRetry() }
        else { permissionRetry?.cancel(); permissionRetry = nil }
        if settings.isAssistancePaused(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) { hideAll() }
    }

    private func start() {
        guard PermissionService.isAccessibilityGranted else { return }
        if keyMonitor == nil {
            let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                Task { @MainActor in self?.handleTyping(event) }
            }
            keyMonitor = monitor
            if monitor != nil { Log.event("dispatcher: monitoring started") }
        }
        if workspaceObserver == nil {
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.handleAppSwitch() } }
        }
        if targetValidationTimer == nil {
            let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollFocusedField() }
            }
            timer.tolerance = 0.08
            RunLoop.main.add(timer, forMode: .common)
            targetValidationTimer = timer
        }
    }

    private func installMouseMonitor() {
        guard mouseMonitor == nil, PermissionService.isAccessibilityGranted else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            Task { @MainActor in self?.handleClick() }
        }
    }
    private func removeMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
    }

    private func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        removeMouseMonitor()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver); self.workspaceObserver = nil }
        pendingDispatch?.cancel(); pendingDispatch = nil
        cancelPendingBubble()
        permissionRetry?.cancel(); permissionRetry = nil
        targetValidationTimer?.invalidate(); targetValidationTimer = nil
        fieldActivity.reset()
        lastObservedElement = nil
        browserOwnershipWasActive = false
        browserOwnershipTarget = nil
        generation += 1
        ElectronTextFocusEvidence.clear()
        hideAll()
        Log.event("dispatcher: monitoring stopped")
    }

    /// Accessibility can briefly report false after an ad-hoc development build
    /// is replaced at the same path. Retry quietly so granting/re-granting the
    /// permission does not require another app restart or settings toggle.
    private func schedulePermissionRetry() {
        guard permissionRetry == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.permissionRetry = nil
            guard self.wantsMonitor, self.keyMonitor == nil else { return }
            self.refresh()
        }
        permissionRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func hideAll(keepAssistant: Bool = false) {
        passive.hideUI()
        if keepAssistant { inline.typingBegan() } else { inline.hideUI() }
        bubble.hide()
    }

    // MARK: - Events

    private func handleTyping(_ event: NSEvent) {
        // Our Copy/Paste/Delete transport is part of the current operation.
        // It must not dismiss its review or start another typing-pause check.
        guard !ClipboardService.isBeanSyntheticKeyboardEvent(event) else { return }
        // Close expanded review and stale underlines, retain the quiet field
        // control, and re-arm checking after committed text changes.
        let app = NSWorkspace.shared.frontmostApplication
        guard !settings.isAssistancePaused(for: app?.bundleIdentifier) else { hideAll(); return }
        ElectronTextFocusEvidence.recordKey(event, app: app)
        hideAll(keepAssistant: settings.inlineHighlightsEnabled && !browserExtensionOwnsField(app: app))
        generation += 1
        let gen = generation
        scheduleCheck(generation: gen)
    }

    private func handleClick() {
        // A click elsewhere dismisses current Bean UI, then (after a delay) may
        // show the bubble for the newly focused field/selection.
        let app = NSWorkspace.shared.frontmostApplication
        guard !settings.isAssistancePaused(for: app?.bundleIdentifier) else { hideAll(); return }
        let field = AccessibilityService.focusedField()
        ElectronTextFocusEvidence.recordClick(
            app: NSWorkspace.shared.frontmostApplication,
            point: NSEvent.mouseLocation,
            focusedElementIsKnownNonText: field.map { !$0.isSemanticTextSurface } ?? false
        )
        passive.hideUI()
        bubble.hide()
        generation += 1
        if settings.inlineHighlightsEnabled, !browserExtensionOwnsField(app: app, field: field), let field {
            inline.prepare(field: field, app: app)
        } else { inline.hideUI() }
        pendingDispatch?.cancel()
        // Repositioning the caret must not permanently remove the existing
        // local suggestions. A delayed check reuses the exact cached snapshot.
        if settings.inlineHighlightsEnabled {
            let gen = generation
            scheduleCheck(generation: gen)
        }
        scheduleBubble(generation)
    }

    private func handleAppSwitch() {
        if inline.isApplyingCorrection || isInteractingWithBean { return }
        ElectronTextFocusEvidence.clear()
        hideAll()
        generation += 1
        fieldActivity.reset()
        lastObservedElement = nil
        pendingDispatch?.cancel()
        scheduleCheck(generation: generation)
        if settings.bubbleEnabled { scheduleBubble(generation) }
    }

    private func scheduleCheck(generation gen: Int) {
        pendingDispatch?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.dispatch(generation: gen) }
        }
        pendingDispatch = work
        let delay = settings.inlineHighlightsEnabled ? 0.45 : max(settings.passiveDelay, 0.25)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func pollFocusedField() {
        guard wantsMonitor else { return }
        guard PermissionService.isAccessibilityGranted else { refresh(); return }
        if Date() >= nextBrowserOwnershipCleanup {
            nextBrowserOwnershipCleanup = Date().addingTimeInterval(30)
            let ownership = browserOwnership
            Task.detached { ownership.removeExpiredLeases() }
        }
        // Range selection and source reactivation are transient parts of an
        // accepted correction. Poll after completion rather than hiding its UI
        // midway through a verified write. Real key events still invalidate it.
        guard !inline.isApplyingCorrection, !isInteractingWithBean else { return }
        let app = NSWorkspace.shared.frontmostApplication
        if settings.isAssistancePaused(for: app?.bundleIdentifier) {
            if settings.lastSupportReason != "appPaused" {
                generation += 1
                pendingDispatch?.cancel()
                cancelPendingBubble()
                pendingFeedback = nil
                fieldActivity.reset()
                lastObservedElement = nil
                hideAll()
                setStatus("paused", "appPaused")
            }
            return
        }
        let field = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? nil : AccessibilityService.focusedField()
        let snapshot: TypingPauseActivityTracker.Snapshot?
        if let app, let field {
            if lastObservedElement.map({ !AccessibilityService.isSameElement($0, field.element) }) ?? true {
                fieldIdentity += 1
            }
            lastObservedElement = field.element
            snapshot = .init(processIdentifier: app.processIdentifier,
                             fieldIdentity: fieldIdentity,
                             value: field.value,
                             acceptsTextInput: field.acceptsTextInput)
        } else {
            lastObservedElement = nil
            snapshot = nil
        }
        let change = fieldActivity.observe(snapshot)
        let extensionOwnsField = browserExtensionOwnsField(app: app, field: field)
        let ownershipChanged = extensionOwnsField != browserOwnershipWasActive
        browserOwnershipWasActive = extensionOwnsField
        if extensionOwnsField {
            if ownershipChanged || change != .unchanged {
                generation += 1
                pendingDispatch?.cancel()
                cancelPendingBubble()
            }
            if ownershipChanged || change != .unchanged || inline.isShowingUI
                || passive.isShowingUI || bubble.isShowing {
                hideAll()
                setStatus("browserExtension", "activeBrowserFieldOwned")
            }
            return
        }
        // A confirmed Accept has already updated the inline session and moved
        // its next card. Acknowledge that exact verified edit without hiding
        // the remaining suggestions and making them blink on the next poll.
        let confirmedInlineEdit = change == .textChanged && field.map {
            inline.matchesCurrentSession(app: app, field: $0)
        } == true
        if (change != .unchanged || ownershipChanged), !confirmedInlineEdit {
            passive.hideUI()
            bubble.hide()
            generation += 1
            pendingDispatch?.cancel()
            if snapshot != nil {
                pendingFeedback = (generation, Date(), field?.value?.count ?? 0)
                if settings.inlineHighlightsEnabled, let field { inline.prepare(field: field, app: app) }
                else { inline.hideUI() }
                scheduleCheck(generation: generation)
                if settings.bubbleEnabled { scheduleBubble(generation) }
            } else { inline.hideUI(); pendingFeedback = nil }
        }
        inline.refreshVisibleTarget()
        passive.refreshVisibleTarget()
        if inline.ownsFocusedFieldSession || inline.isShowingUI || passive.isShowingUI { bubble.hide() }
        else { bubble.refreshVisibleTarget() }
    }

    private func browserExtensionOwnsField(app: NSRunningApplication?,
                                          field: AccessibilityService.FocusedField? = nil) -> Bool {
        guard let identity = BrowserFieldOwnershipIdentity.current(for: app),
              browserOwnership.ownsField(for: identity),
              let field = field ?? AccessibilityService.focusedField(),
              field.acceptsTextInput, !field.isSecure else { return false }
        if browserOwnershipTarget.map({ AccessibilityService.isSameElement($0, field.element) }) != true
            || (!browserOwnershipTargetIsWebContent && Date().timeIntervalSince(browserOwnershipTargetCheckedAt) > 1) {
            browserOwnershipTarget = field.element
            browserOwnershipTargetIsWebContent = AccessibilityService.isBrowserWebContentField(field)
            browserOwnershipTargetCheckedAt = Date()
        }
        return browserOwnershipTargetIsWebContent
    }

    private func scheduleBubble(_ gen: Int) {
        cancelPendingBubble()
        let revision = bubblePresentationRevision
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.considerBubble(generation: gen, scheduledRevision: revision) }
        }
        pendingBubble = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.bubbleDelay, execute: work)
    }

    private func cancelPendingBubble() {
        bubblePresentationRevision += 1
        pendingBubble?.cancel()
        pendingBubble = nil
    }

    /// Runs synchronously before inline/passive presentation, so there is no
    /// frame where both it and the fallback launcher own the focused field.
    /// The revision also invalidates work already queued as a MainActor Task.
    private func revokeFallbackBubble() {
        cancelPendingBubble()
        bubble.hide()
    }

    private func considerBubble(generation gen: Int, scheduledRevision: Int? = nil) {
        guard scheduledRevision == nil || scheduledRevision == bubblePresentationRevision else { return }
        guard gen == generation, settings.bubbleEnabled, !coordinatorIsBusy() else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        // Bubble is lowest priority: yield to passive/inline if they're showing.
        guard !passive.isShowingUI, !inline.isShowingUI, !inline.ownsFocusedFieldSession else {
            revokeFallbackBubble()
            return
        }
        let app = NSWorkspace.shared.frontmostApplication
        guard !settings.isAssistancePaused(for: app?.bundleIdentifier) else { return }
        if browserExtensionOwnsField(app: app) { bubble.hide(); return }
        bubble.evaluate()
    }

    // MARK: - Typing-pause routing (passive / inline)

    private func dispatch(generation gen: Int) async {
        guard gen == generation else { return }
        if coordinatorIsBusy() { scheduleCheck(generation: gen); return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        guard settings.passiveActive || settings.inlineHighlightsEnabled else {
            considerBubble(generation: gen)
            return
        }
        guard PermissionService.isAccessibilityGranted else { return }
        let app = NSWorkspace.shared.frontmostApplication
        guard !settings.isAssistancePaused(for: app?.bundleIdentifier) else { hideAll(); return }
        guard let field = AccessibilityService.focusedField() else {
            finishPause("skipped", "noField", generation: gen, richerUIShown: false)
            return
        }

        if browserExtensionOwnsField(app: app, field: field) {
            hideAll()
            setStatus("browserExtension", "activeBrowserFieldOwned")
            return
        }
        let context = SourceAppContext.current(app: app, field: field, mode: .focusedFieldFullText)
        let isCurrent: () -> Bool = { [weak self] in self?.generation == gen }
        var reason = ""

        if settings.inlineHighlightsEnabled {
            switch inline.support(for: field) {
            case .supported:
                let shown = await inline.run(field: field, app: app, context: context, isCurrent: isCurrent, reason: &reason)
                finishPause(shown ? "inline" : "skipped", shown ? "inlineHandled" : reason,
                            generation: gen, richerUIShown: shown)
                return
            case .degradedUsePopover(let r), .unsupported(let r):
                inline.showUnavailable(field: field, app: app, reason: r)
                if settings.inlineFallbackPassive {
                    let shown = await passive.run(field: field, app: app, context: context,
                                                  isCurrent: isCurrent, forced: true, reason: &reason)
                    finishPause(shown ? "passive" : "skipped",
                                shown ? "inlineUnsupportedFallbackPassive" : reason,
                                generation: gen, richerUIShown: shown)
                } else {
                    finishPause("skipped", "inlineUnsupportedNoFallback(\(r))",
                                generation: gen, richerUIShown: false)
                }
                return
            }
        }

        if settings.passiveActive {
            let shown = await passive.run(field: field, app: app, context: context,
                                          isCurrent: isCurrent, forced: false, reason: &reason)
            finishPause(shown ? "passive" : "skipped", shown ? "passiveHandled" : reason,
                        generation: gen, richerUIShown: shown)
        }
    }

    private func finishPause(_ handler: String, _ reason: String, generation gen: Int,
                             richerUIShown: Bool) {
        guard gen == generation else { return }
        setStatus(handler, reason)
        if richerUIShown || inline.ownsFocusedFieldSession || inline.isShowingUI || passive.isShowingUI {
            revokeFallbackBubble()
        } else { considerBubble(generation: gen) }
    }

    private func setStatus(_ handler: String, _ reason: String) {
        settings.lastPauseHandler = handler
        settings.lastSupportReason = reason
        if settings.diagnosticsEnabled {
            Log.diag(["dispatcher": "pause", "handler": handler, "reason": reason])
        }
    }

    private func recordLocalFeedback(issueCount: Int) {
        guard let feedback = pendingFeedback, feedback.generation == generation else { return }
        pendingFeedback = nil
        AssistanceMetrics.shared.record(kind: .typingPauseToFeedback, inputLength: feedback.inputLength,
            issueCount: issueCount, elapsedMilliseconds: Int(Date().timeIntervalSince(feedback.startedAt) * 1_000),
            outcome: issueCount == 0 ? "noIssues" : "shown")
    }
}
