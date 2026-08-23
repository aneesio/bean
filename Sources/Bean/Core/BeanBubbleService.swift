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
    private let openFullMenu: () -> Void
    private let openAISettings: () -> Void

    private let controller = BeanBubbleController()

    // Drag offset for the bubble, kept only in memory and only for the currently
    // focused element. Switching to a different field/app resets it. Keyed by AX
    // element identity (no text, no window title) — privacy-safe.
    private var bubbleOffset: CGSize = .zero
    private var offsetElement: AXUIElement?

    init(settings: AppSettings, statusHUD: StatusHUD,
         runAction: @escaping (WritingAction) -> Void,
         openFullMenu: @escaping () -> Void,
         openAISettings: @escaping () -> Void) {
        self.settings = settings
        self.statusHUD = statusHUD
        self.runAction = runAction
        self.openFullMenu = openFullMenu
        self.openAISettings = openAISettings
    }

    var isShowing: Bool { controller.isShowing }

    func hide(_ reason: String? = nil) {
        // Log the decision even when the bubble never became visible. This is
        // content-free and makes unsupported Electron fields diagnosable.
        if let reason { diag(["bubbleShown": "false", "bubbleHiddenReason": reason]) }
        controller.hide()
    }

    // MARK: - Evaluate (called by the dispatcher on focus/selection)

    func evaluate(fallbackOrigin: CGPoint? = nil) {
        guard settings.bubbleEnabled else { return hide() }
        guard PermissionService.isAccessibilityGranted else { return hide("noPermission") }
        guard let field = AccessibilityService.focusedField() else {
            if let fallbackOrigin { return showSlackFallback(near: fallbackOrigin) }
            return hide("noField")
        }
        guard !field.isSecure else { return hide("secureField") }
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let origin = bubbleOrigin(for: field)
        let capabilities = FieldCapabilityPolicy.evaluate(
            bundleIdentifier: bundle,
            category: AppCategory.from(bundleIdentifier: bundle),
            traits: FieldTraits(field: field, hasBubbleBounds: origin != nil),
            preferences: settings.capabilityPreferences
        )
        guard capabilities.beanBubble.level != .unsupported else {
            if let fallbackOrigin { return showSlackFallback(near: fallbackOrigin) }
            return hide(capabilities.beanBubble.reason)
        }

        guard let origin else {
            if let fallbackOrigin { return showSlackFallback(near: fallbackOrigin) }
            return hide("noBounds")
        }

        // Reset the drag offset when focus moves to a different field/app.
        if offsetElement == nil || !AccessibilityService.isSameElement(field.element, offsetElement!) {
            if offsetElement != nil { diag(["bubbleReset": "true"]) }
            bubbleOffset = .zero
            offsetElement = field.element
        }

        controller.showBubble(
            at: origin,
            savedOffset: bubbleOffset,
            openOnHover: settings.bubbleOpenOnHover,
            onOpen: { [weak self] intent in self?.openMenu(intent: intent) },
            onDismiss: { [weak self] in self?.hide("dismissed") },
            onCommitOffset: { [weak self] off in self?.bubbleOffset = off; self?.diag(["bubbleDragged": "true"]) },
            onReset: { [weak self] in self?.bubbleOffset = .zero; self?.diag(["bubbleReset": "true"]) }
        )
        diag(["bubbleShown": "true", "app": AppCategory.from(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier).rawValue])
    }

    /// Slack desktop sometimes exposes neither a focused AX element nor editor
    /// bounds. After the dispatcher has independently observed a recent click
    /// plus printable typing in Slack, place the bubble beside that click. The
    /// evidence gate prevents this path from appearing on ordinary controls.
    private func showSlackFallback(near point: CGPoint) {
        let app = NSWorkspace.shared.frontmostApplication
        let screens = OverlayScreenArea.current
        guard app?.bundleIdentifier == "com.tinyspeck.slackmacgap",
              settings.bubbleInChat,
              let screen = OverlayGeometry.screen(containing: point, from: screens) else {
            return hide("invalidSlackFallback")
        }

        if offsetElement != nil { diag(["bubbleReset": "true"]) }
        offsetElement = nil
        bubbleOffset = .zero
        let origin = OverlayGeometry.clampedOrigin(
            CGPoint(x: point.x + 12, y: point.y + 12),
            panelSize: CGSize(
                width: OverlayGeometry.beanLauncherSize,
                height: OverlayGeometry.beanLauncherSize
            ),
            in: screen.visibleFrame,
            inset: 4
        )
        controller.showBubble(
            at: origin,
            savedOffset: .zero,
            openOnHover: settings.bubbleOpenOnHover,
            onOpen: { [weak self] intent in self?.openMenu(intent: intent) },
            onDismiss: { [weak self] in self?.hide("dismissed") },
            onCommitOffset: { [weak self] off in self?.bubbleOffset = off; self?.diag(["bubbleDragged": "true"]) },
            onReset: { [weak self] in self?.bubbleOffset = .zero; self?.diag(["bubbleReset": "true"]) }
        )
        diag(["bubbleShown": "true", "app": "chat", "anchor": "slackTypingEvidence"])
    }

    // MARK: - Mini menu

    private func openMenu(intent: OverlayActivationIntent) {
        guard let frame = controller.bubbleFrame else { return }
        controller.showMenu(
            near: CGPoint(x: frame.minX, y: frame.minY),
            intent: intent,
            aiAvailable: settings.hasAPIKey,
            onSelect: { [weak self] action in self?.choose(action) },
            onSetUpAI: { [weak self] _ in self?.showAISetup() },
            onMore: { [weak self] in self?.hide("more"); self?.openFullMenu() },
            onCancel: { [weak self] in self?.hide("cancel") }
        )
    }

    private func choose(_ action: WritingAction) {
        // Re-acquisition + validation happens inside the coordinator's pipeline.
        diag(["menuActionChosen": action.rawValue])
        hide("actionChosen")
        runAction(action)
    }

    private func showAISetup() {
        hide("aiSetup")
        openAISettings()
    }

    // MARK: - Positioning

    private func bubbleOrigin(for field: AccessibilityService.FocusedField) -> CGPoint? {
        let size = OverlayGeometry.beanLauncherSize
        let screens = OverlayScreenArea.current

        // 1. Prefer the selection's top-right, when enabled and available.
        if settings.bubbleOnSelection, let sel = TextRangeLocator.selectionRect(for: field.element),
           isValid(sel), let screen = OverlayGeometry.screen(containing: sel, from: screens) {
            return OverlayGeometry.clampedOrigin(
                CGPoint(x: sel.maxX + 6, y: sel.maxY - size),
                panelSize: CGSize(width: size, height: size),
                in: screen.visibleFrame,
                inset: 4
            )
        }
        // 2. Else the focused field's top-right inner corner.
        if settings.bubbleOnFocus, let rect = TextRangeLocator.fieldRect(for: field.element),
           isValid(rect), rect.height >= 14, rect.width >= 40,
           let screen = OverlayGeometry.screen(containing: rect, from: screens) {
            return OverlayGeometry.clampedOrigin(
                CGPoint(x: rect.maxX - size - 8, y: rect.maxY - size - 8),
                panelSize: CGSize(width: size, height: size),
                in: screen.visibleFrame,
                inset: 4
            )
        }
        return nil
    }

    private func isValid(_ rect: CGRect) -> Bool {
        guard rect.width > 1, rect.height > 1 else { return false }
        // Must intersect some screen (on-screen, not offscreen/invalid).
        return NSScreen.screens.contains { $0.frame.intersects(rect) }
    }

    private func diag(_ extra: [String: String]) {
        guard settings.diagnosticsEnabled else { return }
        var fields = ["bubble": "true"]
        fields.merge(extra) { _, new in new }
        Log.diag(fields)
    }
}
