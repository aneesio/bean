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
    private var previewResolved = false
    private var previewOnClose: (() -> Void)?

    // MARK: - Action menu

    func presentMenu(appName: String?,
                     profiles: [(id: UUID, name: String)],
                     defaultProfileID: UUID?,
                     onSelect: @escaping (WritingAction, UUID?) -> Void,
                     onCancel: @escaping () -> Void) {
        dismissMenu()
        menuResolved = false
        menuOnCancel = onCancel

        let view = ActionMenuView(
            appName: appName,
            profiles: profiles,
            onSelect: { [weak self] action, profileID in
                self?.menuResolved = true
                self?.dismissMenu()
                onSelect(action, profileID)
            },
            onCancel: { [weak self] in
                self?.menuResolved = true
                self?.dismissMenu()
                onCancel()
            },
            selectedProfileID: defaultProfileID
        )

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.contentViewController = NSHostingController(rootView: view)
        panel.delegate = self
        panel.setContentSize(panel.contentViewController!.view.fittingSize)
        positionTopCenter(panel)

        menuPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismissMenu() {
        menuPanel?.delegate = nil
        menuPanel?.close()
        menuPanel = nil
    }

    // MARK: - Preview

    func presentPreview(_ model: PreviewModel) {
        dismissPreview()
        previewResolved = false
        // Closing the window (red button) behaves like Cancel.
        previewOnClose = model.onCancel

        let window = NSWindow(contentViewController: NSHostingController(rootView: RewritePreviewView(model: model)))
        window.title = "Bean — Preview"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        window.center()
        previewWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Called by the coordinator when a preview button (Replace/Copy/Cancel)
    /// resolves the preview. Marks it resolved so the close handler doesn't also
    /// fire a (second) cancel.
    func dismissPreview() {
        previewResolved = true
        previewWindow?.delegate = nil
        previewWindow?.close()
        previewWindow = nil
    }

    // MARK: - Helpers

    private func positionTopCenter(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - 80
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
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == previewWindow, !previewResolved else { return }
        previewResolved = true
        previewWindow = nil
        previewOnClose?()
    }
}

// Borderless/utility panels can't become key by default; this subclass opts in
// so the SwiftUI buttons and keyboard shortcuts work.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
