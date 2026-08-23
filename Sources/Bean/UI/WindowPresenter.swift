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
    private let usageLedger: UsageLedgerStore
    private let automaticCallBudget: AutomaticCallBudgetStore
    private let setupStatus: SetupStatusStore
    private let onCheckPermissions: () -> Void
    private let onApplyShortcut: (ShortcutSlot, GlobalShortcut) -> String?

    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let settingsNavigation = SettingsNavigation()

    init(
        settings: AppSettings,
        userContent: UserContentStore,
        history: OperationHistoryStore,
        usageLedger: UsageLedgerStore,
        automaticCallBudget: AutomaticCallBudgetStore,
        setupStatus: SetupStatusStore,
        onCheckPermissions: @escaping () -> Void,
        onApplyShortcut: @escaping (ShortcutSlot, GlobalShortcut) -> String?
    ) {
        self.settings = settings
        self.userContent = userContent
        self.history = history
        self.usageLedger = usageLedger
        self.automaticCallBudget = automaticCallBudget
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
        let root = OnboardingView(settings: settings, usageLedger: usageLedger) { [weak self] in
            self?.finishOnboarding()
        }
        let window = makeWindow(title: "Welcome to Bean", root: root,
                                resizable: true, identifier: "onboarding")
        // This is a content requirement: `NSWindow.minSize` includes the title
        // bar and would leave the SwiftUI root less than its advertised 620 pt
        // minimum at the smallest resize.
        window.contentMinSize = NSSize(width: 600, height: 620)
        window.setContentSize(NSSize(width: 640, height: 700))
        onboardingWindow = window
        present(window)
    }

    private func finishOnboarding() {
        settings.onboardingStepRawValue = OnboardingStep.ready.rawValue
        settings.onboardingComplete = true
        onboardingWindow?.close()
    }

    // MARK: - Settings

    func showSettings(section: SettingsView.Category? = nil) {
        if let section {
            settingsNavigation.selection = section
        }
        if let settingsWindow {
            present(settingsWindow)
            return
        }
        let actions = SettingsActions(
            checkPermissions: { [weak self] in self?.onCheckPermissions() },
            resetOnboarding: { [weak self] in self?.resetOnboarding() },
            openReadme: { Self.openBundledDoc("README") },
            openTesting: { Self.openBundledDoc("TESTING") },
            fullReset: { [settings, userContent, automaticCallBudget] in
                FullResetService.live(
                    settings: settings,
                    userContent: userContent,
                    automaticCallBudget: automaticCallBudget
                ).perform()
            },
            applyShortcut: { [weak self] slot, shortcut in
                self?.onApplyShortcut(slot, shortcut) ?? "Bean isn't ready to set a shortcut yet."
            }
        )
        let root = SettingsView(
            settings: settings,
            store: userContent,
            history: history,
            usageLedger: usageLedger,
            automaticCallBudget: automaticCallBudget,
            setupStatus: setupStatus,
            navigation: settingsNavigation,
            actions: actions
        )
        let window = makeWindow(title: "Bean Settings", root: root,
                                resizable: true, identifier: "settings")
        window.minSize = NSSize(width: 980, height: 720)
        window.setContentSize(NSSize(width: 1120, height: 800))
        window.setFrameAutosaveName("BeanSettingsWindow")
        window.center()
        settingsWindow = window
        present(window)
    }

    private func resetOnboarding() {
        settings.onboardingComplete = false
        settings.onboardingStepRawValue = OnboardingStep.welcome.rawValue
        showOnboarding()
    }

    // MARK: - About

    func showAbout() {
        if let aboutWindow {
            present(aboutWindow)
            return
        }
        let root = AboutView(onOpenUpdateCheck: { [weak self] in
            self?.showSettings(section: .general)
        })
        let window = makeWindow(title: "About Bean", root: root,
                                resizable: true, identifier: "about")
        // Match AboutView's content minimum rather than applying the same
        // numbers to the larger titled-window frame.
        window.contentMinSize = NSSize(width: 420, height: 460)
        window.setContentSize(NSSize(width: 520, height: 590))
        aboutWindow = window
        present(window)
    }

    // MARK: - Window helpers

    private func makeWindow<Root: View>(title: String, root: Root, resizable: Bool,
                                        identifier: String) -> NSWindow {
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        window.styleMask = style
        window.isReleasedWhenClosed = false
        window.delegate = self
        DockPresence.prepare(window, kind: identifier)
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        DockPresence.present(window)
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
        // Closing an unfinished setup does not silently mark it complete. Bean
        // will offer the guide again on the next launch.
        if let window = notification.object as? NSWindow, window == onboardingWindow {
            onboardingWindow = nil
        }
        DockPresence.refreshAfterWindowChange()
    }
}
