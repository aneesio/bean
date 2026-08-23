import AppKit
import SwiftUI

// Owns the NSStatusItem (menu bar icon) and its menu. Window presentation is
// delegated out via closures. Menu:
//   Quick Fix · AI Proofread · Open Bean Menu · Undo · Settings · Help · About · Quit
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let onQuickFix: () -> Void
    private let onAIProofread: () -> Void
    private let onOpenBeanMenu: () -> Void
    private let onUndoLastChange: () -> Void
    private let isUndoAvailable: () -> Bool
    private let onCheckCurrentField: () -> Void
    private let onCheckPermissions: () -> Void
    private let onShowSettings: () -> Void
    private let onShowAbout: () -> Void

    private var statusItem: NSStatusItem?
    private weak var undoItem: NSMenuItem?
    private var proofreadShortcut: GlobalShortcut = .default
    private var shortcutAction: PrimaryShortcutAction = .quickFix
    private var beanMenuShortcut: GlobalShortcut = .beanMenuDefault

    init(
        onQuickFix: @escaping () -> Void,
        onAIProofread: @escaping () -> Void,
        onOpenBeanMenu: @escaping () -> Void,
        onUndoLastChange: @escaping () -> Void,
        isUndoAvailable: @escaping () -> Bool,
        onCheckCurrentField: @escaping () -> Void,
        onCheckPermissions: @escaping () -> Void,
        onShowSettings: @escaping () -> Void,
        onShowAbout: @escaping () -> Void
    ) {
        self.onQuickFix = onQuickFix
        self.onAIProofread = onAIProofread
        self.onOpenBeanMenu = onOpenBeanMenu
        self.onUndoLastChange = onUndoLastChange
        self.isUndoAvailable = isUndoAvailable
        self.onCheckCurrentField = onCheckCurrentField
        self.onCheckPermissions = onCheckPermissions
        self.onShowSettings = onShowSettings
        self.onShowAbout = onShowAbout
        super.init()
    }

    func install(proofreadShortcut: GlobalShortcut, shortcutAction: PrimaryShortcutAction,
                 beanMenuShortcut: GlobalShortcut) {
        self.proofreadShortcut = proofreadShortcut
        self.shortcutAction = shortcutAction
        self.beanMenuShortcut = beanMenuShortcut
        let applicationMenu = ApplicationMainMenuBuilder.build(
            target: self,
            aboutAction: #selector(handleAbout),
            settingsAction: #selector(handleSettings),
            quitAction: #selector(handleQuit)
        )
        DockPresence.installMainMenu(applicationMenu.menu, servicesMenu: applicationMenu.servicesMenu)

        let item = NSStatusItem.makeMenuBarItem()
        if let button = item.button {
            button.image = Self.menuBarImage()
            button.toolTip = "Bean — \(shortcutAction.displayName) (\(proofreadShortcut.displayString)) · menu (\(beanMenuShortcut.displayString))"
        }
        item.menu = buildMenu()
        statusItem = item
    }

    /// The bundled monochrome bean template (tints for light/dark menu bars),
    /// falling back to an SF Symbol if the asset isn't present (e.g. `swift run`).
    private static func menuBarImage() -> NSImage {
        if let url = Bundle.main.url(forResource: "MenuBarTemplate", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        let fallback = NSImage(systemSymbolName: "text.badge.checkmark",
                               accessibilityDescription: "Bean")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        fallback.isTemplate = true
        return fallback
    }

    /// Refreshes the displayed shortcuts after the user changes them.
    func updateShortcuts(proofread: GlobalShortcut, shortcutAction: PrimaryShortcutAction? = nil,
                         beanMenu: GlobalShortcut) {
        proofreadShortcut = proofread
        if let shortcutAction { self.shortcutAction = shortcutAction }
        beanMenuShortcut = beanMenu
        statusItem?.button?.toolTip = "Bean — \(self.shortcutAction.displayName) (\(proofread.displayString)) · menu (\(beanMenu.displayString))"
        statusItem?.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        // Bean owns enablement because Undo depends on a verified in-memory
        // replacement, not merely on whether its selector has a target.
        menu.autoenablesItems = false

        // The chosen primary action owns the direct shortcut. The other action
        // remains available without a misleading second key equivalent.
        let quickFixItem: NSMenuItem
        if shortcutAction == .quickFix, let keyEquivalent = proofreadShortcut.menuKeyEquivalent {
            quickFixItem = NSMenuItem(title: "Quick Fix · Offline", action: #selector(handleQuickFix), keyEquivalent: keyEquivalent)
            quickFixItem.keyEquivalentModifierMask = proofreadShortcut.nsModifierFlags
        } else if shortcutAction == .quickFix {
            quickFixItem = NSMenuItem(title: "Quick Fix · Offline (\(proofreadShortcut.displayString))", action: #selector(handleQuickFix), keyEquivalent: "")
        } else {
            quickFixItem = NSMenuItem(title: "Quick Fix · Offline", action: #selector(handleQuickFix), keyEquivalent: "")
        }
        quickFixItem.target = self
        quickFixItem.image = Self.icon("bolt.shield")
        menu.addItem(quickFixItem)

        let aiProofreadItem: NSMenuItem
        if shortcutAction == .aiProofread, let keyEquivalent = proofreadShortcut.menuKeyEquivalent {
            aiProofreadItem = NSMenuItem(title: "AI Proofread · Uses AI",
                                         action: #selector(handleAIProofread), keyEquivalent: keyEquivalent)
            aiProofreadItem.keyEquivalentModifierMask = proofreadShortcut.nsModifierFlags
        } else if shortcutAction == .aiProofread {
            aiProofreadItem = NSMenuItem(title: "AI Proofread · Uses AI (\(proofreadShortcut.displayString))",
                                         action: #selector(handleAIProofread), keyEquivalent: "")
        } else {
            aiProofreadItem = NSMenuItem(title: "AI Proofread · Uses AI",
                                         action: #selector(handleAIProofread), keyEquivalent: "")
        }
        aiProofreadItem.target = self
        aiProofreadItem.image = Self.icon("sparkles")
        menu.addItem(aiProofreadItem)

        let beanMenuItem: NSMenuItem
        if let keyEquivalent = beanMenuShortcut.menuKeyEquivalent {
            beanMenuItem = NSMenuItem(title: "Open Bean Menu", action: #selector(handleOpenBeanMenu), keyEquivalent: keyEquivalent)
            beanMenuItem.keyEquivalentModifierMask = beanMenuShortcut.nsModifierFlags
        } else {
            beanMenuItem = NSMenuItem(title: "Open Bean Menu (\(beanMenuShortcut.displayString))", action: #selector(handleOpenBeanMenu), keyEquivalent: "")
        }
        beanMenuItem.target = self
        beanMenuItem.image = Self.icon("wand.and.stars")
        menu.addItem(beanMenuItem)

        let undoItem = NSMenuItem(title: "Undo Last Bean Change", action: #selector(handleUndoLastChange), keyEquivalent: "")
        undoItem.target = self
        undoItem.image = Self.icon("arrow.uturn.backward")
        undoItem.isEnabled = isUndoAvailable()
        self.undoItem = undoItem
        menu.addItem(undoItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(handleSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = Self.icon("gearshape")
        menu.addItem(settingsItem)

        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpItem.image = Self.icon("questionmark.circle")
        let helpMenu = NSMenu(title: "Help")
        let fieldItem = NSMenuItem(title: "Check Current Field", action: #selector(handleCheckCurrentField), keyEquivalent: "")
        fieldItem.target = self
        fieldItem.image = Self.icon("scope")
        helpMenu.addItem(fieldItem)
        let permissionsItem = NSMenuItem(title: "Check Permissions", action: #selector(handleCheckPermissions), keyEquivalent: "")
        permissionsItem.target = self
        permissionsItem.image = Self.icon("lock.shield")
        helpMenu.addItem(permissionsItem)
        helpItem.submenu = helpMenu
        menu.addItem(helpItem)

        let aboutItem = NSMenuItem(title: "About Bean", action: #selector(handleAbout), keyEquivalent: "")
        aboutItem.target = self
        aboutItem.image = Self.icon("info.circle")
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Bean", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private static func icon(_ symbol: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    // MARK: - Actions

    func menuWillOpen(_ menu: NSMenu) {
        undoItem?.isEnabled = isUndoAvailable()
    }

    @objc private func handleQuickFix() {
        onQuickFix()
    }

    @objc private func handleAIProofread() {
        onAIProofread()
    }

    @objc private func handleOpenBeanMenu() {
        onOpenBeanMenu()
    }

    @objc private func handleUndoLastChange() {
        onUndoLastChange()
    }

    @objc private func handleCheckPermissions() {
        onCheckPermissions()
    }

    @objc private func handleCheckCurrentField() {
        onCheckCurrentField()
    }

    @objc private func handleSettings() {
        onShowSettings()
    }

    @objc private func handleAbout() {
        onShowAbout()
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }
}

/// Builds the standard menus used while Bean has a Dock presence. Edit actions
/// intentionally have no explicit target, allowing AppKit to route them to the
/// active SwiftUI/AppKit text control through the responder chain.
@MainActor
enum ApplicationMainMenuBuilder {
    struct Result {
        let menu: NSMenu
        let servicesMenu: NSMenu
    }

    static func build(
        target: AnyObject,
        aboutAction: Selector,
        settingsAction: Selector,
        quitAction: Selector
    ) -> Result {
        let mainMenu = NSMenu(title: "Main Menu")

        let beanRoot = NSMenuItem(title: "Bean", action: nil, keyEquivalent: "")
        let beanMenu = NSMenu(title: "Bean")
        mainMenu.addItem(beanRoot)
        mainMenu.setSubmenu(beanMenu, for: beanRoot)

        let about = NSMenuItem(title: "About Bean", action: aboutAction, keyEquivalent: "")
        about.target = target
        beanMenu.addItem(about)
        beanMenu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: settingsAction, keyEquivalent: ",")
        settings.target = target
        beanMenu.addItem(settings)
        beanMenu.addItem(.separator())

        let servicesMenu = NSMenu(title: "Services")
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = servicesMenu
        beanMenu.addItem(services)
        beanMenu.addItem(.separator())

        beanMenu.addItem(firstResponderItem(title: "Hide Bean", action: "hide:", key: "h"))
        let hideOthers = firstResponderItem(title: "Hide Others", action: "hideOtherApplications:", key: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        beanMenu.addItem(hideOthers)
        beanMenu.addItem(firstResponderItem(title: "Show All", action: "unhideAllApplications:", key: ""))
        beanMenu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Bean", action: quitAction, keyEquivalent: "q")
        quit.target = target
        beanMenu.addItem(quit)

        let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        mainMenu.addItem(editRoot)
        mainMenu.setSubmenu(editMenu, for: editRoot)

        editMenu.addItem(firstResponderItem(title: "Undo", action: "undo:", key: "z"))
        let redo = firstResponderItem(title: "Redo", action: "redo:", key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(firstResponderItem(title: "Cut", action: "cut:", key: "x"))
        editMenu.addItem(firstResponderItem(title: "Copy", action: "copy:", key: "c"))
        editMenu.addItem(firstResponderItem(title: "Paste", action: "paste:", key: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(firstResponderItem(title: "Select All", action: "selectAll:", key: "a"))

        return Result(menu: mainMenu, servicesMenu: servicesMenu)
    }

    private static func firstResponderItem(title: String, action: String, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector((action)), keyEquivalent: key)
        item.target = nil
        return item
    }
}

private extension NSStatusItem {
    static func makeMenuBarItem() -> NSStatusItem {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }
}
