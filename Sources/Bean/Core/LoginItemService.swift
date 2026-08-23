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

    /// Removes both an enabled registration and one still awaiting approval.
    /// Full Reset uses this stricter form so a pending login item cannot survive
    /// merely because `isEnabled` is false until the user approves it.
    static func resetRegistration() throws {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled, .requiresApproval:
            try service.unregister()
        case .notRegistered, .notFound:
            return
        @unknown default:
            throw NSError(
                domain: "com.bean.app.login-item",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Bean couldn't verify its launch-at-login registration."]
            )
        }

        if service.status == .enabled || service.status == .requiresApproval {
            throw NSError(
                domain: "com.bean.app.login-item",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Bean is still listed as a login item. Remove it in System Settings → General → Login Items, then retry."]
            )
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
