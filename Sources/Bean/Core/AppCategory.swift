import Foundation

// Coarse app categories derived from bundle identifiers. Used for preservation
// guidance and (Phase 3) app-specific style defaults.
enum AppCategory: String, Codable, Hashable {
    case chat
    case mail
    case codeEditor
    case docs
    case unknown

    static func from(bundleIdentifier: String?) -> AppCategory {
        guard let id = bundleIdentifier else { return .unknown }
        switch id {
        case "com.tinyspeck.slackmacgap",
             "com.microsoft.teams", "com.microsoft.teams2",
             "com.apple.MobileSMS",          // Messages
             "com.hnc.Discord":
            return .chat
        case "com.apple.mail",
             "com.microsoft.Outlook",
             "com.readdle.smartemail-Mac":    // Spark
            return .mail
        case "com.microsoft.VSCode",
             "com.todesktop.230313mzl4w4u92", // Cursor
             "com.apple.dt.Xcode",
             "com.apple.Terminal",
             "com.googlecode.iterm2",
             "com.sublimetext.4",
             "com.jetbrains.intellij":
            return .codeEditor
        case "com.apple.TextEdit",
             "com.apple.Notes",
             "notion.id",
             "com.atlassian.jira",
             "com.electron.confluence":
            return .docs
        default:
            return .unknown
        }
    }

    // Web browsers — web fields live behind the DOM, so inline coverage there is
    // the browser extension's job, not native Accessibility.
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser",
        "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"
    ]
    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return browserBundleIDs.contains(bundleID)
    }

    // Electron desktop apps that a browser extension can't reach and that
    // generally don't expose reliable text bounds — a future app adapter, or
    // the Bean Bubble / Passive fallback today.
    private static let electronBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "com.microsoft.teams", "com.microsoft.teams2", "notion.id",
        "com.electron.confluence"
    ]
    static func isElectron(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return electronBundleIDs.contains(bundleID)
    }
}
