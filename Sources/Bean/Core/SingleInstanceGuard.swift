import AppKit

// Prevents two Bean instances from running at once — most importantly so two
// copies don't both register the global shortcut and fight over it.
//
// Detection is by bundle identifier via NSRunningApplication, which is reliable
// for assembled .app bundles. When running unbundled (e.g. `swift run`) there's
// no stable bundle identifier, so the guard is a no-op and both can run — that
// only happens during development.
enum SingleInstanceGuard {

    /// Returns true if another Bean instance is already running. When it is,
    /// the existing instance is brought to the front so the user sees the live
    /// copy; the caller should then terminate this (duplicate) process.
    static func anotherInstanceIsRunning() -> Bool {
        let current = NSRunningApplication.current

        // No bundle id => unbundled/dev run; don't try to guard.
        guard let bundleID = current.bundleIdentifier else { return false }

        let duplicates = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && isDuplicateGUIApplication(
                bundleIdentifier: $0.bundleIdentifier,
                processIdentifier: $0.processIdentifier,
                activationPolicy: $0.activationPolicy,
                currentBundleIdentifier: bundleID,
                currentProcessIdentifier: current.processIdentifier
            )
        }

        guard let existing = duplicates.first else { return false }

        Log.event("single-instance: another Bean is already running; reopening it and quitting")
        // Activation alone leaves an accessory app with no windows invisible.
        // An actual app reopen invokes its delegate's normal Writer/onboarding
        // behavior. Native browser hosts share this executable but cannot
        // accept application activation, so they are excluded above.
        if let bundleURL = existing.bundleURL, NSWorkspace.shared.open(bundleURL) { return true }
        if #available(macOS 14.0, *) {
            existing.activate()
        } else {
            existing.activate(options: [.activateAllWindows])
        }
        return true
    }

    static func isDuplicateGUIApplication(bundleIdentifier: String?, processIdentifier: pid_t,
                                         activationPolicy: NSApplication.ActivationPolicy,
                                         currentBundleIdentifier: String?,
                                         currentProcessIdentifier: pid_t) -> Bool {
        guard let currentBundleIdentifier, let bundleIdentifier,
              currentBundleIdentifier == bundleIdentifier,
              processIdentifier != currentProcessIdentifier else { return false }
        return activationPolicy == .regular || activationPolicy == .accessory
    }
}
