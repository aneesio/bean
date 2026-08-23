import AppKit
import SwiftUI

// Presents the floating action menu and the rewrite preview window. Kept
// separate from WindowPresenter (settings/about/onboarding) so each stays small.
//
// The action menu is shown AFTER text acquisition, so taking key focus is safe —
// the replacement pipeline re-activates the original app before pasting.
@MainActor
final class ActionMenuController: NSObject, NSWindowDelegate {

    private var menuPanel: NSPanel?
    private var menuResolved = false
    private var menuOnCancel: (() -> Void)?

    private var previewWindow: NSWindow?
    private weak var previewModel: PreviewModel?
    private var previewResolved = false
    private var previewOnClose: (() -> Void)?

    private var noticeWindow: NSWindow?
    private var noticeResolved = false
    private var noticeOnClose: (() -> Void)?
    private var preferredScreen: NSScreen?

    // MARK: - Action menu

    func presentMenu(appName: String?,
                     captureLabel: String,
                     sourceAnchorRect: CGRect?,
                     aiAvailable: Bool,
                     onSelect: @escaping (WritingAction) -> Void,
                     onSetUpAI: @escaping () -> Void,
                     onCancel: @escaping () -> Void) {
        dismissMenu()
        preferredScreen = screenForInteraction(sourceAnchorRect: sourceAnchorRect)
        menuResolved = false
        menuOnCancel = onCancel

        let view = ActionMenuView(
            appName: appName,
            captureLabel: captureLabel,
            aiAvailable: aiAvailable,
            onSelect: { [weak self] action in
                self?.menuResolved = true
                self?.dismissMenu()
                onSelect(action)
            },
            onSetUpAI: { [weak self] in
                self?.menuResolved = true
                self?.dismissMenu()
                onSetUpAI()
            },
            onCancel: { [weak self] in
                self?.menuResolved = true
                self?.dismissMenu()
                onCancel()
            }
        )

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.contentMinSize = NSSize(width: 380, height: 360)
        panel.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .none : .utilityWindow
        panel.contentViewController = NSHostingController(rootView: view)
        panel.delegate = self
        DockPresence.prepare(panel, kind: "action-menu")
        panel.setContentSize(sizeFittingCurrentScreen(
            desired: NSSize(width: 440, height: 410), minimum: panel.contentMinSize))
        positionTopCenter(panel)

        menuPanel = panel
        DockPresence.present(panel)
    }

    func dismissMenu() {
        menuPanel?.delegate = nil
        menuPanel?.close()
        menuPanel = nil
        preferredScreen = nil
        DockPresence.refreshAfterWindowChange()
    }

    // MARK: - Preview

    func presentPreview(_ model: PreviewModel) {
        dismissPreview()
        preferredScreen = screenForInteraction(sourceAnchorRect: model.sourceAnchorRect)
        previewResolved = false
        previewModel = model
        // Closing the window (red button) behaves like Cancel.
        previewOnClose = model.onCancel

        let window = NSWindow(contentViewController: NSHostingController(rootView: RewritePreviewView(model: model)))
        window.title = "Bean — Preview"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentMinSize = NSSize(width: 520, height: 400)
        window.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .none : .documentWindow
        window.delegate = self
        DockPresence.prepare(window, kind: "preview")
        window.setContentSize(sizeFittingCurrentScreen(
            desired: NSSize(width: model.originalText == nil ? 620 : 760, height: 540),
            minimum: window.contentMinSize))
        positionCentered(window)
        previewWindow = window
        DockPresence.present(window)
    }

    /// Called by the coordinator when a preview button (Replace/Copy/Cancel)
    /// resolves the preview. Marks it resolved so the close handler doesn't also
    /// fire a (second) cancel.
    func dismissPreview() {
        previewResolved = true
        previewWindow?.delegate = nil
        previewWindow?.close()
        previewWindow = nil
        previewModel = nil
        previewOnClose = nil
        preferredScreen = nil
        DockPresence.refreshAfterWindowChange()
    }

    // MARK: - Persistent action notice

    /// Presents a key, persistent decision surface for failures and setup
    /// requirements. Notices never auto-dismiss and are intentionally separate
    /// from the non-interactive progress/success HUD.
    func presentNotice(_ notice: ActionNotice, sourceAnchorRect: CGRect? = nil) {
        dismissNotice()
        preferredScreen = screenForInteraction(sourceAnchorRect: sourceAnchorRect)
        noticeResolved = false
        noticeOnClose = notice.onDismiss

        let view = ActionNoticeView(
            notice: notice,
            onPrimary: { [weak self] in
                self?.dismissNotice()
                notice.primaryAction.handler()
            },
            onSecondary: notice.secondaryAction.map { action in
                { [weak self] in
                    self?.dismissNotice()
                    action.handler()
                }
            },
            onCancel: { [weak self] in
                self?.dismissNotice()
                notice.onDismiss()
            }
        )

        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Bean — " + notice.title
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentMinSize = NSSize(width: 400, height: 180)
        window.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .none : .documentWindow
        window.delegate = self
        DockPresence.prepare(window, kind: "action-notice")
        window.setContentSize(sizeFittingCurrentScreen(
            desired: NSSize(width: 460, height: 240), minimum: window.contentMinSize))
        positionCentered(window)
        noticeWindow = window
        DockPresence.present(window)
    }

    func dismissNotice() {
        noticeResolved = true
        noticeWindow?.delegate = nil
        noticeWindow?.close()
        noticeWindow = nil
        noticeOnClose = nil
        preferredScreen = nil
        DockPresence.refreshAfterWindowChange()
    }

    // MARK: - Helpers

    static func preferredScreenIndex(
        sourceAnchorRect: CGRect?,
        pointerLocation: CGPoint,
        screenFrames: [CGRect]
    ) -> Int? {
        let screens = screenFrames.map { OverlayScreenArea(frame: $0, visibleFrame: $0) }
        let selected = sourceAnchorRect.flatMap { OverlayGeometry.screen(containing: $0, from: screens) }
            ?? OverlayGeometry.screen(containing: pointerLocation, from: screens)
        return selected.flatMap { screens.firstIndex(of: $0) }
    }

    private func screenForInteraction(sourceAnchorRect: CGRect?) -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = Self.preferredScreenIndex(
            sourceAnchorRect: sourceAnchorRect,
            pointerLocation: NSEvent.mouseLocation,
            screenFrames: screens.map(\.frame)
        ) else { return nil }
        return screens[index]
    }

    private var interactionScreen: NSScreen? {
        if let preferredScreen { return preferredScreen }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? NSScreen.screens.first
    }

    private func sizeFittingCurrentScreen(desired: NSSize, minimum: NSSize) -> NSSize {
        guard let visible = interactionScreen?.visibleFrame else { return desired }
        let availableWidth = max(320, visible.width - 48)
        let availableHeight = max(240, visible.height - 72)
        return NSSize(
            width: min(max(desired.width, min(minimum.width, availableWidth)), availableWidth),
            height: min(max(desired.height, min(minimum.height, availableHeight)), availableHeight)
        )
    }

    private func positionTopCenter(_ window: NSWindow) {
        guard let screen = interactionScreen else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = min(max(visible.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = max(visible.minY, visible.maxY - size.height - 80)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func positionCentered(_ window: NSWindow) {
        guard let screen = interactionScreen else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = min(max(visible.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = min(max(visible.midY - size.height / 2, visible.minY), visible.maxY - size.height)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - NSWindowDelegate

    // Click-away cancels the action menu.
    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == menuPanel, !menuResolved else { return }
        menuResolved = true
        let cancel = menuOnCancel
        dismissMenu()
        cancel?()
    }

    // Closing the preview window behaves like Cancel (restores clipboard, ends
    // the session) — unless a button already resolved it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender == previewWindow else { return true }
        return previewModel?.isRunning != true
    }

    func windowWillClose(_ notification: Notification) {
        DockPresence.refreshAfterWindowChange()
        guard let window = notification.object as? NSWindow else { return }
        if window == previewWindow, !previewResolved {
            previewResolved = true
            previewWindow = nil
            previewModel = nil
            let onClose = previewOnClose
            previewOnClose = nil
            onClose?()
        } else if window == noticeWindow, !noticeResolved {
            noticeResolved = true
            noticeWindow = nil
            let onClose = noticeOnClose
            noticeOnClose = nil
            onClose?()
        }
    }
}

// Borderless/utility panels can't become key by default; this subclass opts in
// so the SwiftUI buttons and keyboard shortcuts work.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
