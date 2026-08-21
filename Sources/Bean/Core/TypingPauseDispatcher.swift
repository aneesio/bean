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
    private var permissionRetry: DispatchWorkItem?
    private var generation = 0

    init(settings: AppSettings, passive: PassiveSuggestionService, inline: InlineHighlightService,
         bubble: BeanBubbleService, coordinatorIsBusy: @escaping () -> Bool) {
        self.settings = settings
        self.passive = passive
        self.inline = inline
        self.bubble = bubble
        self.coordinatorIsBusy = coordinatorIsBusy
    }

    private var wantsMonitor: Bool {
        settings.passiveActive || settings.inlineHighlightsEnabled || settings.bubbleEnabled
    }

    func refresh() {
        if wantsMonitor { start() } else { stop() }
        // Mouse monitor: needed for the bubble (focus/selection) and to dismiss
        // inline highlights when the user clicks elsewhere in the field.
        if settings.bubbleEnabled || settings.inlineHighlightsEnabled { installMouseMonitor() } else { removeMouseMonitor() }
        settings.monitorActive = (keyMonitor != nil)
        if wantsMonitor, keyMonitor == nil { schedulePermissionRetry() }
        else { permissionRetry?.cancel(); permissionRetry = nil }
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
        pendingBubble?.cancel(); pendingBubble = nil
        permissionRetry?.cancel(); permissionRetry = nil
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

    private func hideAll() {
        passive.hideUI()
        inline.hideUI()
        bubble.hide()
    }

    // MARK: - Events

    private func handleTyping(_ event: NSEvent) {
        // Typing hides everything (including the bubble) and re-arms the
        // typing-pause router.
        ElectronTextFocusEvidence.recordKey(event, app: NSWorkspace.shared.frontmostApplication)
        hideAll()
        generation += 1
        let gen = generation
        pendingDispatch?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in await self?.dispatch(generation: gen) } }
        pendingDispatch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.passiveDelay, execute: work)
    }

    private func handleClick() {
        // A click elsewhere dismisses current Bean UI, then (after a delay) may
        // show the bubble for the newly focused field/selection.
        let field = AccessibilityService.focusedField()
        ElectronTextFocusEvidence.recordClick(
            app: NSWorkspace.shared.frontmostApplication,
            point: NSEvent.mouseLocation,
            focusedElementIsKnownNonText: field.map { !$0.isSemanticTextSurface } ?? false
        )
        hideAll()
        generation += 1
        scheduleBubble(generation)
    }

    private func handleAppSwitch() {
        ElectronTextFocusEvidence.clear()
        hideAll()
        generation += 1
        if settings.bubbleEnabled { scheduleBubble(generation) }
    }

    private func scheduleBubble(_ gen: Int) {
        pendingBubble?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.considerBubble(generation: gen) } }
        pendingBubble = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.bubbleDelay, execute: work)
    }

    private func considerBubble(generation gen: Int) {
        guard gen == generation, settings.bubbleEnabled, !coordinatorIsBusy() else { return }
        // Bubble is lowest priority: yield to passive/inline if they're showing.
        guard !passive.isShowingUI, !inline.isShowingUI else { return }
        let app = NSWorkspace.shared.frontmostApplication
        bubble.evaluate(fallbackOrigin: ElectronTextFocusEvidence.validAnchor(for: app))
    }

    // MARK: - Typing-pause routing (passive / inline)

    private func dispatch(generation gen: Int) async {
        guard gen == generation, !coordinatorIsBusy() else { return }
        guard settings.passiveActive || settings.inlineHighlightsEnabled else {
            considerBubble(generation: gen)
            return
        }
        guard PermissionService.isAccessibilityGranted else { return }
        guard let field = AccessibilityService.focusedField() else {
            finishPause("skipped", "noField", generation: gen, richerUIShown: false)
            return
        }

        let app = NSWorkspace.shared.frontmostApplication
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
        setStatus(handler, reason)
        if !richerUIShown { considerBubble(generation: gen) }
    }

    private func setStatus(_ handler: String, _ reason: String) {
        settings.lastPauseHandler = handler
        settings.lastSupportReason = reason
        if settings.diagnosticsEnabled {
            Log.diag(["dispatcher": "pause", "handler": handler, "reason": reason])
        }
    }
}
