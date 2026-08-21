import AppKit

// Wires together the menu bar, the two global hotkeys (quick proofread + Bean
// menu), and the coordinator. Owns the long-lived services.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let userContent = UserContentStore()
    private let operationHistory = OperationHistoryStore()
    private let usageLedger = UsageLedgerStore()
    private let setupStatus = SetupStatusStore()
    private let statusHUD = StatusHUD()
    private let replacementUndo = ReplacementUndoStore()

    private lazy var coordinator = TextActionCoordinator(
        settings: settings,
        userContent: userContent,
        history: operationHistory,
        usageLedger: usageLedger,
        undoStore: replacementUndo,
        statusHUD: statusHUD
    )

    private lazy var passiveService = PassiveSuggestionService(
        settings: settings, userContent: userContent, history: operationHistory,
        usageLedger: usageLedger, undoStore: replacementUndo, statusHUD: statusHUD
    )

    private lazy var inlineService = InlineHighlightService(
        settings: settings, userContent: userContent, history: operationHistory,
        usageLedger: usageLedger, statusHUD: statusHUD
    )

    private lazy var bubbleService = BeanBubbleService(
        settings: settings,
        statusHUD: statusHUD,
        runAction: { [weak self] action in self?.coordinator.runAction(action) },
        openFullMenu: { [weak self] in self?.coordinator.showActionMenu() }
    )

    private lazy var typingDispatcher = TypingPauseDispatcher(
        settings: settings,
        passive: passiveService,
        inline: inlineService,
        bubble: bubbleService,
        coordinatorIsBusy: { [weak self] in self?.coordinator.isBusy ?? true }
    )

    private lazy var windowPresenter = WindowPresenter(
        settings: settings,
        userContent: userContent,
        history: operationHistory,
        usageLedger: usageLedger,
        setupStatus: setupStatus,
        onCheckPermissions: { [weak self] in self?.coordinator.checkPermissions() },
        onApplyShortcut: { [weak self] slot, shortcut in self?.applyShortcut(slot, shortcut) }
    )

    private lazy var menuBarController = MenuBarController(
        onProofreadNow: { [weak self] in self?.coordinator.fixSelectedText() },
        onOpenBeanMenu: { [weak self] in self?.coordinator.showActionMenu() },
        onUndoLastChange: { [weak self] in self?.coordinator.undoLastChange() },
        onCheckCurrentField: { [weak self] in self?.checkCurrentField() },
        onCheckPermissions: { [weak self] in self?.coordinator.checkPermissions() },
        onShowSettings: { [weak self] in self?.windowPresenter.showSettings() },
        onShowAbout: { [weak self] in self?.windowPresenter.showAbout() }
    )

    private let hotkeyService = HotkeyService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard: bring an existing Bean to the front and quit
        // this duplicate so two copies never both register the global shortcuts.
        if SingleInstanceGuard.anotherInstanceIsRunning() {
            NSApp.terminate(nil)
            return
        }

        menuBarController.install(proofreadShortcut: settings.shortcut, beanMenuShortcut: settings.beanMenuShortcut)
        windowPresenter.showOnboardingIfNeeded()

        registerHotkeys()

        // One shared typing-pause monitor drives both Passive Suggestions and
        // Inline Highlights, with inline taking priority and passive as fallback.
        settings.onPassiveChanged = { [weak self] in self?.typingDispatcher.refresh() }
        settings.onInlineChanged = { [weak self] in self?.typingDispatcher.refresh() }
        settings.onBubbleChanged = { [weak self] in self?.typingDispatcher.refresh() }
        typingDispatcher.refresh()
    }

    private func checkCurrentField() {
        let report = setupStatus.inspectCurrentField(settings: settings)
        operationHistory.record(OperationRecord(
            source: .setup,
            appName: report.appName,
            appBundleIdentifier: report.bundleIdentifier,
            appCategory: report.appCategory,
            action: "fieldCheck",
            inputMode: "metadataOnly",
            inputLength: 0,
            safetyResult: "notRun",
            outcome: report.focusedFieldReplacement.level.rawValue,
            usageEstimated: false
        ))
        let style: StatusHUD.Style = report.focusedFieldReplacement.level == .unsupported ? .warning : .success
        statusHUD.show(style, report.headline)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyService.stop()
    }

    // MARK: - Shortcut wiring

    private func registerHotkeys() {
        register(settings.shortcut, slot: .quickProofread, fallback: .default)
        register(settings.beanMenuShortcut, slot: .beanMenu, fallback: .beanMenuDefault)
    }

    private func register(_ shortcut: GlobalShortcut, slot: ShortcutSlot, fallback: GlobalShortcut) {
        let handler = self.handler(for: slot)
        do {
            try hotkeyService.set(shortcut, id: slot.hotkeyID, handler: handler)
        } catch {
            guard shortcut != fallback else { return }
            try? hotkeyService.set(fallback, id: slot.hotkeyID, handler: handler)
            store(fallback, slot: slot)
            menuBarController.updateShortcuts(proofread: settings.shortcut, beanMenu: settings.beanMenuShortcut)
        }
    }

    private func handler(for slot: ShortcutSlot) -> () -> Void {
        switch slot {
        case .quickProofread: return { [weak self] in self?.coordinator.fixSelectedText() }
        case .beanMenu: return { [weak self] in self?.coordinator.showActionMenu() }
        }
    }

    private func store(_ shortcut: GlobalShortcut, slot: ShortcutSlot) {
        switch slot {
        case .quickProofread: settings.shortcut = shortcut
        case .beanMenu: settings.beanMenuShortcut = shortcut
        }
    }

    /// Validates and applies a new shortcut for `slot`. Returns an error message
    /// to show in Settings, or nil on success. On failure the previous shortcut
    /// keeps working (HotkeyService re-registers it).
    private func applyShortcut(_ slot: ShortcutSlot, _ shortcut: GlobalShortcut) -> String? {
        if let reason = shortcut.validationError { return reason }

        // Avoid the two Bean shortcuts colliding.
        let other = slot == .quickProofread ? settings.beanMenuShortcut : settings.shortcut
        if shortcut == other {
            return "That shortcut is already used by Bean."
        }

        do {
            try hotkeyService.set(shortcut, id: slot.hotkeyID, handler: handler(for: slot))
            store(shortcut, slot: slot)
            menuBarController.updateShortcuts(proofread: settings.shortcut, beanMenu: settings.beanMenuShortcut)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// Identifies which Bean shortcut a Settings recorder targets.
enum ShortcutSlot {
    case quickProofread
    case beanMenu

    var hotkeyID: UInt32 {
        switch self {
        case .quickProofread: return HotkeyService.quickProofreadID
        case .beanMenu: return HotkeyService.beanMenuID
        }
    }
}
