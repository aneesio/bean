import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    private var writerWindow: NSWindow?
    private var draftURL: URL?
    private lazy var writerModel = WritingWorkspaceModel(dictionary: { [weak self] in
        self?.userContent.dictionary ?? []
    })
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
        if !settings.onboardingComplete { showOnboarding() }
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
        // Continue typing in the user's app; Bean's assistance lives there.
    }

    // MARK: - Writer

    func showWriter() {
        if let writerWindow { present(writerWindow); return }
        let root = WritingWorkspaceView(
            model: writerModel,
            settings: settings,
            userContent: userContent,
            usageLedger: usageLedger,
            onSettings: { [weak self] section in self?.showSettings(section: section) },
            onOpen: { [weak self] in self?.openDraft() },
            onSave: { [weak self] in _ = self?.saveDraft() }
        )
        let window = makeWindow(title: "Bean Writer", root: root, resizable: true, identifier: "writer")
        window.contentMinSize = NSSize(width: 860, height: 600)
        window.setContentSize(NSSize(width: 1080, height: 760))
        window.setFrameAutosaveName("BeanWriterWindow")
        writerWindow = window
        present(window)
    }

    private func openDraft() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.title = "Open a writing draft"
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= WritingWorkspaceModel.maximumLocalCharacters * 4 else {
                writerModel.showNotice("This file is too large. Open a section of up to 50,000 characters.")
                return
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.count <= WritingWorkspaceModel.maximumLocalCharacters else {
                writerModel.showNotice("This file is too long. Open a section of up to 50,000 characters.")
                return
            }
            draftURL = url
            writerModel.load(text, name: url.lastPathComponent, saved: true)
        } catch {
            writerModel.showNotice("Bean couldn't open this file. Choose a UTF-8 text or Markdown file.")
        }
    }

    @discardableResult
    private func saveDraft() -> Bool {
        let panel = NSSavePanel()
        panel.title = "Save your draft"
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = writerModel.documentName == "Untitled draft" || writerModel.documentName == "Example draft"
            ? "Draft.txt" : writerModel.documentName
        if let draftURL { panel.directoryURL = draftURL.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try writerModel.text.write(to: url, atomically: true, encoding: .utf8)
            draftURL = url
            writerModel.markSaved(name: url.lastPathComponent)
            return true
        } catch {
            writerModel.showNotice("Bean couldn't save this draft. Choose a writable folder and try again.")
            return false
        }
    }

    /// Window closure keeps the current draft in memory. Leaving the process
    /// or opening another document protects unsaved work with standard choices.
    func confirmQuit() -> Bool {
        guard writerModel.isDirty else { return true }
        showWriter()
        return confirmDiscard()
    }

    private func confirmDiscard() -> Bool {
        guard writerModel.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to your draft?"
        alert.informativeText = "Your unsaved writing will be lost if you continue without saving."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveDraft()
        case .alertThirdButtonReturn: return true
        default: return false
        }
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
            },
            openWriter: { [weak self] in self?.showWriter() }
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
        window.contentMinSize = NSSize(width: 820, height: 600)
        window.setContentSize(NSSize(width: 980, height: 720))
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
