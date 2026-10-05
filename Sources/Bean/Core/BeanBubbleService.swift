import AppKit

// The Bean Bubble (Phase 6.5): a tiny, optional contextual launcher shown near a
// supported focused field/selection. It is the LOWEST-priority Bean UI — the
// shared TypingPauseDispatcher only asks it to evaluate when no richer Bean UI
// (inline, passive, action menu, preview) is active. It never reads text to
// decide visibility (Accessibility bounds/metadata only) and never logs text.
@MainActor
final class BeanBubbleService {
    private let settings: AppSettings
    private let statusHUD: StatusHUD
    private let runAction: (WritingAction) -> Void
    private let runParagraphAction: ((WritingAction) -> Void)?
    private let openFullMenu: () -> Void
    private let openAISettings: () -> Void

    private let controller = BeanBubbleController()

    // Drag offset for the bubble, kept only in memory and only for the currently
    // focused element. Switching to a different field/app resets it. Keyed by AX
    // element identity (no text, no window title) — privacy-safe.
    private var bubbleOffset: CGSize = .zero
    private var bubbleTargetSize = CGSize(width: 28, height: 28)
    private var offsetElement: AXUIElement?
    private var sourcePID: pid_t?
    private var dismissedElement: AXUIElement?

    init(settings: AppSettings, statusHUD: StatusHUD,
         runAction: @escaping (WritingAction) -> Void,
         openFullMenu: @escaping () -> Void,
         openAISettings: @escaping () -> Void,
         runParagraphAction: ((WritingAction) -> Void)? = nil) {
        self.settings = settings
        self.statusHUD = statusHUD
        self.runAction = runAction
        self.runParagraphAction = runParagraphAction
        self.openFullMenu = openFullMenu
        self.openAISettings = openAISettings
    }

    var isShowing: Bool { controller.isShowing }
    var ownsUIInteraction: Bool { controller.ownsKeyboardInteraction }

    func hide(_ reason: String? = nil) {
        // Log the decision even when the bubble never became visible. This is
        // content-free and makes unsupported Electron fields diagnosable.
        if let reason { diag(["bubbleShown": "false", "bubbleHiddenReason": reason]) }
        controller.hide()
        sourcePID = nil
    }

    func refreshVisibleTarget() {
        guard controller.isShowing else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == sourcePID else { hide("sourceChanged"); return }
        guard let offsetElement else { hide("noFieldBounds"); return }
        guard let field = AccessibilityService.focusedFieldMetadata(in: app),
              AccessibilityService.isSameElement(field.element, offsetElement),
              !field.isSecure,
              let origin = bubbleOrigin(for: field) else { hide("fieldChanged"); return }
        controller.moveBubble(to: origin, targetSize: bubbleTargetSize.width)
    }

    private func dismissForCurrentField() {
        dismissedElement = offsetElement
        hide("dismissed")
    }

    // MARK: - Evaluate (called by the dispatcher on focus/selection)

    func evaluate() {
        guard settings.bubbleEnabled else { return hide() }
        guard !settings.isAssistancePaused(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else { return hide("appPaused") }
        guard PermissionService.isAccessibilityGranted else { return hide("noPermission") }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let field = AccessibilityService.focusedFieldMetadata(in: app) else { return hide("noFieldBounds") }
        guard !field.isSecure else { return hide("secureField") }
        if let dismissedElement {
            if AccessibilityService.isSameElement(dismissedElement, field.element) { return hide("dismissedField") }
            self.dismissedElement = nil
        }
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let origin = bubbleOrigin(for: field)
        let capabilities = FieldCapabilityPolicy.evaluate(
            bundleIdentifier: bundle,
            category: AppCategory.from(bundleIdentifier: bundle),
            traits: FieldTraits(field: field, hasBubbleBounds: origin != nil),
            preferences: settings.capabilityPreferences
        )
        guard capabilities.beanBubble.level != .unsupported else {
            return hide(capabilities.beanBubble.reason)
        }

        guard let origin else {
            return hide("noBounds")
        }

        // Reset the drag offset when focus moves to a different field/app.
        if offsetElement == nil || !AccessibilityService.isSameElement(field.element, offsetElement!) {
            if offsetElement != nil { diag(["bubbleReset": "true"]) }
            bubbleOffset = .zero
            offsetElement = field.element
        }

        sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let savedOrigin = CGPoint(x: origin.x + bubbleOffset.width, y: origin.y + bubbleOffset.height)
        if !isSafeBubbleOrigin(savedOrigin) { bubbleOffset = .zero }
        controller.showBubble(
            at: origin,
            savedOffset: bubbleOffset,
            openOnHover: settings.bubbleOpenOnHover, targetSize: bubbleTargetSize.width,
            isSafeOrigin: { [weak self] point in self?.isSafeBubbleOrigin(point) == true },
            onOpen: { [weak self] intent in self?.openMenu(intent: intent) },
            onDismiss: { [weak self] in self?.dismissForCurrentField() },
            onCommitOffset: { [weak self] off in self?.bubbleOffset = off; self?.diag(["bubbleDragged": "true"]) },
            onReset: { [weak self] in self?.bubbleOffset = .zero; self?.diag(["bubbleReset": "true"]) }
        )
        diag(["bubbleShown": controller.isShowing ? "true" : "false", "app": AppCategory.from(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier).rawValue])
    }

    // MARK: - Mini menu

    private func openMenu(intent: OverlayActivationIntent) {
        guard let frame = controller.bubbleFrame else { return }
        guard isSafeBubbleOrigin(frame.origin) else { hide("unsafePlacement"); return }
        controller.showMenu(
            near: CGPoint(x: frame.minX, y: frame.minY),
            intent: intent,
            aiAvailable: settings.hasAPIKey,
            scope: offsetElement.flatMap { AccessibilityService.selectedRange(of: $0) }
                .map { $0.length > 0 ? "selected text" : "draft" } ?? "draft",
            onSelect: { [weak self] action in self?.choose(action) },
            onParagraphSelect: runParagraphAction == nil ? nil : { [weak self] action in self?.choose(action, currentParagraph: true) },
            onSetUpAI: { [weak self] _ in self?.showAISetup() },
            onMore: { [weak self] in
                self?.performInSourceApp(afterHiding: "more") { [weak self] in self?.openFullMenu() }
            },
            onCancel: { [weak self] in self?.hide("cancel") }
        )
    }

    private func choose(_ action: WritingAction, currentParagraph: Bool = false) {
        // Re-acquisition + validation happens inside the coordinator's pipeline.
        diag(["menuActionChosen": action.rawValue])
        performInSourceApp(afterHiding: "actionChosen") { [weak self] in
            if currentParagraph, let paragraph = self?.runParagraphAction { paragraph(action) }
            else { self?.runAction(action) }
        }
    }

    private func showAISetup() {
        hide("aiSetup")
        openAISettings()
    }

    private func performInSourceApp(afterHiding reason: String, action: @escaping () -> Void) {
        guard let sourcePID, let app = NSRunningApplication(processIdentifier: sourcePID), !app.isTerminated else {
            hide(reason)
            return
        }
        let element = offsetElement
        hide(reason)
        Task { [weak self] in
            guard let self else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != sourcePID {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
                    self.statusHUD.show(.warning, "Return to your writing app, then choose Bean again.")
                    return
                }
                if #available(macOS 14.0, *) { app.activate() }
                else { app.activate(options: []) }
                await Task.pause(Timing.afterActivate)
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else {
                self.statusHUD.show(.warning, "Return to your writing app, then choose Bean again.")
                return
            }
            if let element {
                guard let field = AccessibilityService.focusedFieldMetadata(in: app),
                      AccessibilityService.isSameElement(field.element, element) else {
                    self.statusHUD.show(.warning, "Return to the original field, then choose Bean again.")
                    return
                }
            }
            action()
        }
    }

    // MARK: - Positioning

    private func bubbleOrigin(for field: AccessibilityService.FocusedField) -> CGPoint? {
        guard settings.bubbleOnFocus || (settings.bubbleOnSelection && (AccessibilityService.selectedRange(of: field.element)?.length ?? 0) > 0),
              let geometry = AccessibilityService.fieldOverlayGeometry(for: field.element),
              let size = OverlayGeometry.fieldControlSize(for: geometry.fieldRect),
              let screen = OverlayGeometry.screen(containing: geometry.fieldRect, from: OverlayScreenArea.current) else { return nil }
        bubbleTargetSize = size
        var checked: [CGRect] = []
        for frame in OverlayGeometry.issueTrayCandidateFrames(geometry: geometry, panelSize: size, in: screen.visibleFrame) {
            if checked.contains(where: { abs($0.minX - frame.minX) < size.width && abs($0.minY - frame.minY) < size.height }) { continue }
            checked.append(frame)
            if AccessibilityService.fieldOverlayTargetHitTest(frame, for: field.element) != .blocked { return frame.origin }
            if checked.count == 3 { break }
        }
        return nil
    }

    /// Called on every legacy drag move/commit, not just at initial display.
    /// No persistent offset can carry the transparent target onto text/Send.
    private func isSafeBubbleOrigin(_ point: CGPoint) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier == sourcePID,
              let element = offsetElement,
              let field = AccessibilityService.focusedFieldMetadata(in: app),
              !field.isSecure, AccessibilityService.isSameElement(field.element, element),
              let geometry = AccessibilityService.fieldOverlayGeometry(for: element),
              let screen = OverlayGeometry.screen(containing: geometry.fieldRect, from: OverlayScreenArea.current) else { return false }
        return OverlayGeometry.isSafeFieldControlFrame(
            CGRect(origin: point, size: bubbleTargetSize),
            geometry: geometry, in: screen.visibleFrame)
            && AccessibilityService.fieldOverlayTargetHitTest(CGRect(origin: point, size: bubbleTargetSize), for: element) != .blocked
    }

    private func diag(_ extra: [String: String]) {
        guard settings.diagnosticsEnabled else { return }
        var fields = ["bubble": "true"]
        fields.merge(extra) { _, new in new }
        Log.diag(fields)
    }
}
