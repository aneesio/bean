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
            $0.bundleIdentifier == bundleID && $0.processIdentifier != current.processIdentifier
        }

        guard let existing = duplicates.first else { return false }

        Log.event("single-instance: another Bean is already running; activating it and quitting")
        if #available(macOS 14.0, *) {
            existing.activate()
        } else {
            existing.activate(options: [.activateAllWindows])
        }
        return true
    }
}
