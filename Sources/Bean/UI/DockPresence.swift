import AppKit

/// Bean normally lives only in the menu bar. User-facing Bean windows opt into
/// this marker so the Dock icon appears while any of them is visible and hides
/// again after the last one closes. Passive HUDs, bubbles, and highlights do
/// not affect Dock presence; an explicitly interactive overlay opts in only
/// while its keyboard-accessible panel is open.
@MainActor
enum DockPresence {
    private static let identifierPrefix = "com.bean.user-window."
    private static var applicationMainMenu: NSMenu?
    private static var applicationServicesMenu: NSMenu?

    /// Keep the normal application menu alive while Bean moves between its
    /// menu-bar-only and regular application states. AppKit can otherwise drop
    /// or replace the menu while changing activation policy.
    static func installMainMenu(_ menu: NSMenu, servicesMenu: NSMenu) {
        applicationMainMenu = menu
        applicationServicesMenu = servicesMenu
        NSApp.mainMenu = menu
        NSApp.servicesMenu = servicesMenu
    }

    static func prepare(_ window: NSWindow, kind: String) {
        window.identifier = NSUserInterfaceItemIdentifier(identifierPrefix + kind)
    }

    /// Marks an explicitly opened transient overlay as user-facing and shows
    /// Bean in the Dock without activating the application. Its
    /// `.nonactivatingPanel` can then become key for keyboard/VoiceOver use while
    /// the source app remains frontmost; activating Bean here would also trigger
    /// the global app-switch dismissal path and immediately close the overlay.
    static func prepareExplicitOverlay(_ window: NSWindow, kind: String) {
        prepare(window, kind: kind)
        applyActivationPolicy(.regular)
    }

    static func present(_ window: NSWindow) {
        applyActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func refreshAfterWindowChange() {
        DispatchQueue.main.async {
            let hasVisibleUserWindow = NSApp.windows.contains { window in
                window.isVisible && (window.identifier?.rawValue.hasPrefix(identifierPrefix) ?? false)
            }
            applyActivationPolicy(hasVisibleUserWindow ? .regular : .accessory)
        }
    }

    private static func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
        guard policy == .regular else { return }
        if let applicationMainMenu, NSApp.mainMenu !== applicationMainMenu {
            NSApp.mainMenu = applicationMainMenu
        }
        if let applicationServicesMenu, NSApp.servicesMenu !== applicationServicesMenu {
            NSApp.servicesMenu = applicationServicesMenu
        }
    }
}
