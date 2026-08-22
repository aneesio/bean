import AppKit
import SwiftUI

// Owns the NSStatusItem (menu bar icon) and its menu. Window presentation is
// delegated out via closures. Menu:
//   Proofread Now · Open Bean Menu · Undo · Settings · Help · About · Quit
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let onProofreadNow: () -> Void
    private let onOpenBeanMenu: () -> Void
    private let onUndoLastChange: () -> Void
    private let onCheckCurrentField: () -> Void
    private let onCheckPermissions: () -> Void
    private let onShowSettings: () -> Void
    private let onShowAbout: () -> Void

    private var statusItem: NSStatusItem?
    private var proofreadShortcut: GlobalShortcut = .default
    private var beanMenuShortcut: GlobalShortcut = .beanMenuDefault

    init(
        onProofreadNow: @escaping () -> Void,
        onOpenBeanMenu: @escaping () -> Void,
        onUndoLastChange: @escaping () -> Void,
        onCheckCurrentField: @escaping () -> Void,
        onCheckPermissions: @escaping () -> Void,
        onShowSettings: @escaping () -> Void,
        onShowAbout: @escaping () -> Void
    ) {
        self.onProofreadNow = onProofreadNow
        self.onOpenBeanMenu = onOpenBeanMenu
        self.onUndoLastChange = onUndoLastChange
        self.onCheckCurrentField = onCheckCurrentField
        self.onCheckPermissions = onCheckPermissions
        self.onShowSettings = onShowSettings
        self.onShowAbout = onShowAbout
        super.init()
    }

    func install(proofreadShortcut: GlobalShortcut, beanMenuShortcut: GlobalShortcut) {
        self.proofreadShortcut = proofreadShortcut
        self.beanMenuShortcut = beanMenuShortcut
        let item = NSStatusItem.makeMenuBarItem()
        if let button = item.button {
            button.image = Self.menuBarImage()
            button.toolTip = "Bean — proofread (\(proofreadShortcut.displayString)) · menu (\(beanMenuShortcut.displayString))"
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
    func updateShortcuts(proofread: GlobalShortcut, beanMenu: GlobalShortcut) {
        proofreadShortcut = proofread
        beanMenuShortcut = beanMenu
        statusItem?.button?.toolTip = "Bean — proofread (\(proofread.displayString)) · menu (\(beanMenu.displayString))"
        statusItem?.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        // Proofread Now — shows its shortcut. For letter/number keys we use a
        // real keyEquivalent (renders right-aligned); otherwise append to title.
        let proofreadItem: NSMenuItem
        if let keyEquivalent = proofreadShortcut.menuKeyEquivalent {
            proofreadItem = NSMenuItem(title: "AI Proofread Now", action: #selector(handleProofread), keyEquivalent: keyEquivalent)
            proofreadItem.keyEquivalentModifierMask = proofreadShortcut.nsModifierFlags
        } else {
            proofreadItem = NSMenuItem(title: "AI Proofread Now (\(proofreadShortcut.displayString))", action: #selector(handleProofread), keyEquivalent: "")
        }
        proofreadItem.target = self
        proofreadItem.image = Self.icon("checkmark.circle")
        menu.addItem(proofreadItem)

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

    @objc private func handleProofread() {
        onProofreadNow()
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

private extension NSStatusItem {
    static func makeMenuBarItem() -> NSStatusItem {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }
}
