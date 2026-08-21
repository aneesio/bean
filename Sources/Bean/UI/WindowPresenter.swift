import AppKit
import SwiftUI

// Owns Bean's auxiliary windows (Settings, About, Onboarding) and the logic for
// showing onboarding on first run. Keeping window lifecycle here keeps
// MenuBarController focused on the menu and AppDelegate focused on wiring.
@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
    private let settings: AppSettings
    private let userContent: UserContentStore
    private let history: OperationHistoryStore
    private let setupStatus: SetupStatusStore
    private let onCheckPermissions: () -> Void
    private let onApplyShortcut: (ShortcutSlot, GlobalShortcut) -> String?

    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    init(
        settings: AppSettings,
        userContent: UserContentStore,
        history: OperationHistoryStore,
        setupStatus: SetupStatusStore,
        onCheckPermissions: @escaping () -> Void,
        onApplyShortcut: @escaping (ShortcutSlot, GlobalShortcut) -> String?
    ) {
        self.settings = settings
        self.userContent = userContent
        self.history = history
        self.setupStatus = setupStatus
        self.onCheckPermissions = onCheckPermissions
        self.onApplyShortcut = onApplyShortcut
        super.init()
    }

    // MARK: - First run

    func showOnboardingIfNeeded() {
        guard !settings.onboardingComplete else { return }
        showOnboarding()
    }

    func showOnboarding() {
        if let onboardingWindow {
            present(onboardingWindow)
            return
        }
        let root = OnboardingView(settings: settings, history: history, setupStatus: setupStatus) { [weak self] in
            self?.finishOnboarding()
        }
        let window = makeWindow(title: "Welcome to Bean", root: root, resizable: false)
        window.delegate = self
        onboardingWindow = window
        present(window)
    }

    private func finishOnboarding() {
        settings.onboardingComplete = true
        onboardingWindow?.close()
    }

    // MARK: - Settings

    func showSettings() {
        if let settingsWindow {
            present(settingsWindow)
            return
        }
        let actions = SettingsActions(
            checkPermissions: { [weak self] in self?.onCheckPermissions() },
            resetOnboarding: { [weak self] in self?.resetOnboarding() },
            openReadme: { Self.openBundledDoc("README") },
            openTesting: { Self.openBundledDoc("TESTING") },
            applyShortcut: { [weak self] slot, shortcut in
                self?.onApplyShortcut(slot, shortcut) ?? "Bean isn't ready to set a shortcut yet."
            }
        )
        let root = SettingsView(
            settings: settings,
            store: userContent,
            history: history,
            setupStatus: setupStatus,
            actions: actions
        )
        let window = makeWindow(title: "Bean Settings", root: root, resizable: true)
        settingsWindow = window
        present(window)
    }

    private func resetOnboarding() {
        settings.onboardingComplete = false
        showOnboarding()
    }

    // MARK: - About

    func showAbout() {
        if let aboutWindow {
            present(aboutWindow)
            return
        }
        let window = makeWindow(title: "About Bean", root: AboutView(), resizable: false)
        aboutWindow = window
        present(window)
    }

    // MARK: - Window helpers

    private func makeWindow<Root: View>(title: String, root: Root, resizable: Bool) -> NSWindow {
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        window.styleMask = style
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        // Bring the (accessory) app forward so the window takes focus.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens a doc shipped in the app bundle's Resources (e.g. README.md). Falls
    /// back silently if not present (e.g. when running `swift run`).
    private static func openBundledDoc(_ name: String) {
        if let url = Bundle.main.url(forResource: name, withExtension: "md") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Closing the onboarding window (even via the red button) counts as
        // "seen", so it doesn't reappear on every launch. Settings still shows
        // setup warnings if anything is incomplete.
        if let window = notification.object as? NSWindow, window == onboardingWindow {
            settings.onboardingComplete = true
            onboardingWindow = nil
        }
    }
}
