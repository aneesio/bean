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

    private let controller = BeanBubbleController()

    // Drag offset for the bubble, kept only in memory and only for the currently
    // focused element. Switching to a different field/app resets it. Keyed by AX
    // element identity (no text, no window title) — privacy-safe.
    private var bubbleOffset: CGSize = .zero
    private var offsetElement: AXUIElement?

    init(settings: AppSettings, statusHUD: StatusHUD,
         runAction: @escaping (WritingAction) -> Void,
         openFullMenu: @escaping () -> Void) {
        self.settings = settings
        self.statusHUD = statusHUD
        self.runAction = runAction
        self.openFullMenu = openFullMenu
    }

    var isShowing: Bool { controller.isShowing }

    func hide(_ reason: String? = nil) {
        // Log the decision even when the bubble never became visible. This is
        // content-free and makes unsupported Electron fields diagnosable.
        if let reason { diag(["bubbleShown": "false", "bubbleHiddenReason": reason]) }
        controller.hide()
    }

    // MARK: - Evaluate (called by the dispatcher on focus/selection)

    func evaluate() {
        guard settings.bubbleEnabled else { return hide() }
        guard PermissionService.isAccessibilityGranted else { return hide("noPermission") }
        guard let field = AccessibilityService.focusedField() else { return hide("noField") }
        guard !field.isSecure else { return hide("secureField") }
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let electronTextSurface = AppCategory.isElectron(bundle) && field.isSemanticTextSurface
        guard field.acceptsTextInput || electronTextSurface else { return hide("notEditableText") }
        guard categoryAllowed(field) else { return hide("appDisabled") }

        guard let origin = bubbleOrigin(for: field) else { return hide("noBounds") }

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
            onOpen: { [weak self] in self?.openMenu() },
            onDismiss: { [weak self] in self?.hide("dismissed") },
            onCommitOffset: { [weak self] off in self?.bubbleOffset = off; self?.diag(["bubbleDragged": "true"]) },
            onReset: { [weak self] in self?.bubbleOffset = .zero; self?.diag(["bubbleReset": "true"]) }
        )
        diag(["bubbleShown": "true", "app": AppCategory.from(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier).rawValue])
    }

    // MARK: - Mini menu

    private func openMenu() {
        guard let frame = controller.bubbleFrame else { return }
        controller.showMenu(
            near: CGPoint(x: frame.minX, y: frame.minY),
            onSelect: { [weak self] action in self?.choose(action) },
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

    // MARK: - Positioning

    private func bubbleOrigin(for field: AccessibilityService.FocusedField) -> CGPoint? {
        let size: CGFloat = 24
        guard let screen = NSScreen.main else { return nil }
        let visible = screen.visibleFrame

        // 1. Prefer the selection's top-right, when enabled and available.
        if settings.bubbleOnSelection, let sel = TextRangeLocator.selectionRect(for: field.element),
           isValid(sel, on: screen) {
            return clampedOrigin(x: sel.maxX + 6, y: sel.maxY - size, size: size, in: visible)
        }
        // 2. Else the focused field's top-right inner corner.
        if settings.bubbleOnFocus, let rect = TextRangeLocator.fieldRect(for: field.element),
           isValid(rect, on: screen), rect.height >= 14, rect.width >= 40 {
            return clampedOrigin(x: rect.maxX - size - 8, y: rect.maxY - size - 8, size: size, in: visible)
        }
        return nil
    }

    private func isValid(_ rect: CGRect, on screen: NSScreen) -> Bool {
        guard rect.width > 1, rect.height > 1 else { return false }
        // Must intersect some screen (on-screen, not offscreen/invalid).
        return NSScreen.screens.contains { $0.frame.intersects(rect) }
    }

    private func clampedOrigin(x: CGFloat, y: CGFloat, size: CGFloat, in visible: CGRect) -> CGPoint {
        CGPoint(x: min(max(x, visible.minX + 4), visible.maxX - size - 4),
                y: min(max(y, visible.minY + 4), visible.maxY - size - 4))
    }

    private func categoryAllowed(_ field: AccessibilityService.FocusedField) -> Bool {
        if field.isSearchLike { return settings.bubbleInSearch }
        switch AppCategory.from(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
        case .codeEditor: return settings.bubbleInCode
        case .chat: return settings.bubbleInChat
        case .mail, .docs: return settings.bubbleInMailBrowser
        case .unknown: return settings.bubbleInMailBrowser
        }
    }

    private func diag(_ extra: [String: String]) {
        guard settings.diagnosticsEnabled else { return }
        var fields = ["bubble": "true"]
        fields.merge(extra) { _, new in new }
        Log.diag(fields)
    }
}
