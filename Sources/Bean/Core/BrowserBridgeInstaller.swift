import AppKit
import Foundation

struct BrowserBridgeBrowser: Equatable {
    let name: String
    let supportPath: String
}

struct BrowserBridgeStatus: Equatable {
    enum State: Equatable {
        case extensionNotFound
        case readyToInstall
        case installed
        case needsRepair
        case unavailable
    }

    let state: State
    let extensionIDs: [String]
    let browserNames: [String]
    let configuredBrowserNames: [String]
    let detail: String
}

enum BrowserBridgeInstallerError: LocalizedError, Equatable {
    case invalidExtensionID
    case extensionNotFound
    case appExecutableMissing
    case noSupportedBrowser
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidExtensionID:
            return "That does not look like a Chrome extension ID. It should be 32 letters."
        case .extensionNotFound:
            return "Bean could not find the loaded extension. Load it in Chrome first, then try again."
        case .appExecutableMissing:
            return "Bean could not locate its app executable. Move Bean to Applications and reopen it."
        case .noSupportedBrowser:
            return "No Chrome, Brave, Edge, or Chromium profile was found. Open the browser once, then try again."
        case .writeFailed(let browser):
            return "Bean could not install the connection for \(browser). Check folder permissions and try again."
        }
    }
}

/// Discovers the unpacked Bean extension from Chromium's metadata and writes
/// the per-user native-messaging manifest. It reads only extension ID/path
/// metadata and the extension's own manifest — never browser history or page
/// content.
struct BrowserBridgeInstaller {
    static let hostName = "com.bean.nativehost"
    static let defaultBrowsers = [
        BrowserBridgeBrowser(name: "Chrome", supportPath: "Library/Application Support/Google/Chrome"),
        BrowserBridgeBrowser(name: "Brave", supportPath: "Library/Application Support/BraveSoftware/Brave-Browser"),
        BrowserBridgeBrowser(name: "Edge", supportPath: "Library/Application Support/Microsoft Edge"),
        BrowserBridgeBrowser(name: "Chromium", supportPath: "Library/Application Support/Chromium")
    ]

    let homeDirectory: URL
    let executableURL: URL
    let browsers: [BrowserBridgeBrowser]
    private let fileManager: FileManager

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        executableURL: URL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: "/Applications/Bean.app/Contents/MacOS/Bean"),
        browsers: [BrowserBridgeBrowser] = BrowserBridgeInstaller.defaultBrowsers,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.executableURL = executableURL
        self.browsers = browsers
        self.fileManager = fileManager
    }

    func inspect() -> BrowserBridgeStatus {
        let installedBrowsers = browsers.filter { browserRoot($0).exists(using: fileManager) }
        guard !installedBrowsers.isEmpty else {
            return BrowserBridgeStatus(
                state: .unavailable, extensionIDs: [], browserNames: [], configuredBrowserNames: [],
                detail: "Open Chrome, Brave, Edge, or Chromium once, then return here."
            )
        }

        let ids = discoverExtensionIDs(in: installedBrowsers)
        guard !ids.isEmpty else {
            return BrowserBridgeStatus(
                state: .extensionNotFound, extensionIDs: [],
                browserNames: installedBrowsers.map(\.name), configuredBrowserNames: [],
                detail: "Load the Bean extension first, then return here to connect it."
            )
        }

        let expectedOrigins = Set(ids.map { "chrome-extension://\($0)/" })
        let configured = installedBrowsers.filter {
            manifestIsCurrent(for: $0, expectedOrigins: expectedOrigins)
        }
        let state: BrowserBridgeStatus.State
        let detail: String
        if configured.count == installedBrowsers.count {
            state = .installed
            detail = "Ready in \(configured.map(\.name).joined(separator: ", "))."
        } else if configured.isEmpty {
            state = .readyToInstall
            detail = "Extension found. Bean can install the browser connection now."
        } else {
            state = .needsRepair
            detail = "The connection is missing or outdated in one or more browsers."
        }
        return BrowserBridgeStatus(
            state: state, extensionIDs: ids, browserNames: installedBrowsers.map(\.name),
            configuredBrowserNames: configured.map(\.name), detail: detail
        )
    }

    @discardableResult
    func install(manualExtensionID: String? = nil) throws -> BrowserBridgeStatus {
        guard executableURL.exists(using: fileManager), fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw BrowserBridgeInstallerError.appExecutableMissing
        }
        let installedBrowsers = browsers.filter { browserRoot($0).exists(using: fileManager) }
        guard !installedBrowsers.isEmpty else { throw BrowserBridgeInstallerError.noSupportedBrowser }

        var ids = discoverExtensionIDs(in: installedBrowsers)
        if let value = manualExtensionID?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            guard Self.isValidExtensionID(value) else { throw BrowserBridgeInstallerError.invalidExtensionID }
            ids.append(value)
        }
        ids = Array(Set(ids)).sorted()
        guard !ids.isEmpty else { throw BrowserBridgeInstallerError.extensionNotFound }

        let manifest: [String: Any] = [
            "name": Self.hostName,
            "description": "Bean native messaging host (browser extension ↔ Bean Mac app).",
            "path": executableURL.path,
            "type": "stdio",
            "allowed_origins": ids.map { "chrome-extension://\($0)/" }
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])

        for browser in installedBrowsers {
            let directory = manifestDirectory(for: browser)
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent("\(Self.hostName).json")
                try data.write(to: destination, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            } catch {
                throw BrowserBridgeInstallerError.writeFailed(browser.name)
            }
        }
        return inspect()
    }

    static func isValidExtensionID(_ value: String) -> Bool {
        value.count == 32 && value.unicodeScalars.allSatisfy {
            $0.value >= 97 && $0.value <= 112
        }
    }

    private func discoverExtensionIDs(in installedBrowsers: [BrowserBridgeBrowser]) -> [String] {
        var result = Set<String>()
        for browser in installedBrowsers {
            let root = browserRoot(browser)
            result.formUnion(extensionIDsFromCurrentManifest(for: browser))
            guard let profiles = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for profile in profiles {
                let name = profile.lastPathComponent
                guard name == "Default" || name.hasPrefix("Profile ") || name == "Guest Profile" else { continue }
                let preferences = profile.appendingPathComponent("Secure Preferences")
                guard let data = try? Data(contentsOf: preferences),
                      let rootObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let extensions = rootObject["extensions"] as? [String: Any],
                      let settings = extensions["settings"] as? [String: Any] else { continue }
                for (id, rawEntry) in settings where Self.isValidExtensionID(id) {
                    guard let entry = rawEntry as? [String: Any],
                          let rawPath = entry["path"] as? String,
                          extensionAtPathIsBean(rawPath, relativeTo: root) else { continue }
                    result.insert(id)
                }
            }
        }
        return result.sorted()
    }

    private func extensionIDsFromCurrentManifest(for browser: BrowserBridgeBrowser) -> Set<String> {
        let url = manifestDirectory(for: browser).appendingPathComponent("\(Self.hostName).json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["name"] as? String == Self.hostName,
              manifest["type"] as? String == "stdio",
              manifest["path"] as? String == executableURL.path,
              let origins = manifest["allowed_origins"] as? [String] else { return [] }
        return Set(origins.compactMap { origin in
            let prefix = "chrome-extension://"
            guard origin.hasPrefix(prefix), origin.hasSuffix("/") else { return nil }
            let id = String(origin.dropFirst(prefix.count).dropLast())
            return Self.isValidExtensionID(id) ? id : nil
        })
    }

    private func extensionAtPathIsBean(_ rawPath: String, relativeTo browserRoot: URL) -> Bool {
        let expanded = NSString(string: rawPath).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : browserRoot.appendingPathComponent(expanded)
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = manifest["name"] as? String,
              name.localizedCaseInsensitiveContains("Bean"),
              let permissions = manifest["permissions"] as? [String],
              permissions.contains("nativeMessaging") else { return false }
        return true
    }

    private func manifestIsCurrent(for browser: BrowserBridgeBrowser,
                                   expectedOrigins: Set<String>) -> Bool {
        let url = manifestDirectory(for: browser).appendingPathComponent("\(Self.hostName).json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["name"] as? String == Self.hostName,
              manifest["type"] as? String == "stdio",
              manifest["path"] as? String == executableURL.path,
              let origins = manifest["allowed_origins"] as? [String] else { return false }
        return Set(origins) == expectedOrigins
    }

    private func browserRoot(_ browser: BrowserBridgeBrowser) -> URL {
        homeDirectory.appendingPathComponent(browser.supportPath, isDirectory: true)
    }

    private func manifestDirectory(for browser: BrowserBridgeBrowser) -> URL {
        browserRoot(browser).appendingPathComponent("NativeMessagingHosts", isDirectory: true)
    }
}

@MainActor
final class BrowserBridgeManager: ObservableObject {
    @Published private(set) var status: BrowserBridgeStatus
    @Published private(set) var message: String?
    @Published private(set) var isWorking = false

    private let installer: BrowserBridgeInstaller

    init(installer: BrowserBridgeInstaller = BrowserBridgeInstaller()) {
        self.installer = installer
        self.status = installer.inspect()
    }

    func refresh() {
        status = installer.inspect()
        message = nil
    }

    func installOrRepair(manualExtensionID: String? = nil) {
        isWorking = true
        defer { isWorking = false }
        do {
            status = try installer.install(manualExtensionID: manualExtensionID)
            message = "Browser connected. Reload the extension once to start using Bean."
        } catch {
            status = installer.inspect()
            message = error.localizedDescription
        }
    }
}

private extension URL {
    func exists(using fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: path)
    }
}
