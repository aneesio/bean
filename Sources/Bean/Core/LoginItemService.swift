import Foundation
import ServiceManagement

// Launch-at-login support via the modern ServiceManagement API
// (SMAppService.mainApp), available on macOS 13+. No deprecated
// SMLoginItemSetEnabled / login-item helper bundles.
//
// Limitation: SMAppService registers the *currently running* app bundle. It
// works reliably when Bean is launched from a real, signed Bean.app (ideally in
// /Applications). When running the bare `swift run` executable there is no
// bundle to register, so status reports `.notFound` and toggling will throw —
// handled gracefully by the UI.
@MainActor
enum LoginItemService {

    /// Current enabled state, best-effort.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers/unregisters Bean as a login item. Throws on failure so the UI
    /// can surface a clear message and revert the toggle.
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled { try service.register() }
        } else {
            if service.status == .enabled { try service.unregister() }
        }
    }

    /// Human-readable status for display/troubleshooting.
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "On"
        case .requiresApproval: return "Needs approval in System Settings ▸ General ▸ Login Items"
        case .notRegistered: return "Off"
        case .notFound: return "Unavailable (launch Bean from the built Bean.app)"
        @unknown default: return "Unknown"
        }
    }

    /// Whether toggling is meaningful right now (i.e. we're a real app bundle).
    static var isAvailable: Bool {
        SMAppService.mainApp.status != .notFound
    }
}
