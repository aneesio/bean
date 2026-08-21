import Foundation

// App identity / version info, read from the bundle's Info.plist with sensible
// fallbacks (the plist isn't present when running the raw `swift run`
// executable, only in the assembled Bean.app).
enum AppInfo {
    static let name = "Bean"
    static let tagline = "A small writing helper for your menu bar."
    static let copyright = "© 2026 Anees Afzal and Bean contributors"

    static var version: String { string("CFBundleShortVersionString") ?? "1.3.1" }
    static var build: String { string("CFBundleVersion") ?? "5" }

    /// e.g. "Version 1.3.0 (4)"
    static var versionDisplay: String { "Version \(version) (\(build))" }

    private static func string(_ key: String) -> String? {
        Bundle.main.infoDictionary?[key] as? String
    }
}
