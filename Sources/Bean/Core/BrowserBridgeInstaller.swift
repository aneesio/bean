import AppKit
import Darwin
import Foundation
import Security

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
    /// Browsers whose profile metadata points at Bean's exact bundled
    /// extension. This is presentation metadata only; native-host trust still
    /// comes from the installer’s path-bound validation and manifest policy.
    let detectedExtensionBrowserNames: [String]
    let browserNames: [String]
    let configuredBrowserNames: [String]
    let detail: String
}

/// Result of removing only Bean's Mac-side native-messaging connection. Browser
/// profiles, extension files, browsing data, and the extension's own local
/// settings are never targets of this operation.
struct BrowserBridgeRemovalResult: Equatable {
    let removedBrowserNames: [String]
    let failedBrowserNames: [String]
    let manualApprovalCleared: Bool

    var succeeded: Bool {
        failedBrowserNames.isEmpty && manualApprovalCleared
    }
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
            return "No signed Chrome, Brave, or Edge profile was found. Open the browser once, then try again."
        case .writeFailed(let browser):
            return "Bean could not install the connection for \(browser). Check folder permissions and try again."
        }
    }
}

enum NativeHostLaunchDecision: Equatable {
    case gui
    case nativeHost
    case reject
}

struct NativeHostBrowserIdentity: Hashable {
    let signingIdentifier: String
    let teamIdentifier: String
}

struct NativeHostBrowserProcessEvidence: Equatable {
    let identity: NativeHostBrowserIdentity
    let dynamicCodeIsValid: Bool
    let appleAnchoredRequirementIsValid: Bool
}

/// A native-messaging origin argument is forgeable by any local process. Bean
/// additionally requires the responsible parent to be dynamically valid code
/// that satisfies an Apple-anchored requirement for the exact browser signing
/// identifier and vendor Team ID we explicitly support. Signing-information
/// metadata is descriptive only; matching strings do not establish trust.
enum NativeHostBrowserAuthenticationPolicy {
    static let allowedIdentities: Set<NativeHostBrowserIdentity> = [
        // Google Chrome (browser process and the two helper identities that can
        // own browser services across Chromium releases).
        NativeHostBrowserIdentity(signingIdentifier: "com.google.Chrome", teamIdentifier: "EQHXZ8M8AV"),
        NativeHostBrowserIdentity(signingIdentifier: "com.google.Chrome.helper", teamIdentifier: "EQHXZ8M8AV"),
        NativeHostBrowserIdentity(signingIdentifier: "com.google.Chrome.helper.renderer", teamIdentifier: "EQHXZ8M8AV"),
        // Brave.
        NativeHostBrowserIdentity(signingIdentifier: "com.brave.Browser", teamIdentifier: "KL8N8XSYF4"),
        NativeHostBrowserIdentity(signingIdentifier: "com.brave.Browser.helper", teamIdentifier: "KL8N8XSYF4"),
        NativeHostBrowserIdentity(signingIdentifier: "com.brave.Browser.helper.renderer", teamIdentifier: "KL8N8XSYF4"),
        // Microsoft Edge.
        NativeHostBrowserIdentity(signingIdentifier: "com.microsoft.edgemac", teamIdentifier: "UBF8T346G9"),
        NativeHostBrowserIdentity(signingIdentifier: "com.microsoft.edgemac.helper", teamIdentifier: "UBF8T346G9"),
        NativeHostBrowserIdentity(signingIdentifier: "com.microsoft.edgemac.helper.renderer", teamIdentifier: "UBF8T346G9"),
        // Only Google-signed Chromium is strongly attributable. Generic,
        // locally/ad-hoc-signed Chromium has no stable vendor identity and is
        // deliberately rejected instead of weakening this boundary.
        NativeHostBrowserIdentity(signingIdentifier: "org.chromium.Chromium", teamIdentifier: "EQHXZ8M8AV"),
        NativeHostBrowserIdentity(signingIdentifier: "org.chromium.Chromium.helper", teamIdentifier: "EQHXZ8M8AV"),
        NativeHostBrowserIdentity(signingIdentifier: "org.chromium.Chromium.helper.renderer", teamIdentifier: "EQHXZ8M8AV")
    ]

    static func appleAnchoredRequirementSource(
        for identity: NativeHostBrowserIdentity
    ) -> String? {
        // Only compile requirements for identities in Bean's fixed allowlist.
        // The strict literal alphabet prevents requirement-language injection
        // even if this helper is later called with process-provided metadata.
        guard allowedIdentities.contains(identity),
              let signingIdentifier = requirementStringLiteral(identity.signingIdentifier),
              let teamIdentifier = requirementStringLiteral(identity.teamIdentifier) else {
            return nil
        }
        return "anchor apple generic"
            + " and identifier \(signingIdentifier)"
            + " and certificate leaf[subject.OU] = \(teamIdentifier)"
    }

    static func permits(_ evidence: NativeHostBrowserProcessEvidence?) -> Bool {
        guard let evidence,
              evidence.dynamicCodeIsValid,
              evidence.appleAnchoredRequirementIsValid else { return false }
        return allowedIdentities.contains(evidence.identity)
    }

    private static func requirementStringLiteral(_ value: String) -> String? {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45, 46, 48...57, 65...90, 95, 97...122:
                      return true // -, ., 0-9, A-Z, _, a-z
                  default:
                      return false
                  }
              }) else { return nil }
        return "\"\(value)\""
    }
}

enum NativeHostBrowserProcessInspector {
    /// Resolves the live process through Security.framework, validates its
    /// dynamic code object, and evaluates an Apple-anchored requirement against
    /// that same live guest before returning signed identity metadata.
    static func evidence(for processIdentifier: pid_t) -> NativeHostBrowserProcessEvidence? {
        guard processIdentifier > 1 else { return nil }
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: processIdentifier)
        ] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
              let guest else { return nil }

        let dynamicValidity = SecCodeCheckValidity(
            guest,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        ) == errSecSuccess
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var rawInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        ) == errSecSuccess,
              let information = rawInformation as? [String: Any],
              let signingIdentifier = information[kSecCodeInfoIdentifier as String] as? String,
              let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String,
              !signingIdentifier.isEmpty,
              !teamIdentifier.isEmpty else { return nil }
        let identity = NativeHostBrowserIdentity(
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier
        )
        let anchoredRequirementValidity = appleAnchoredRequirementIsValid(
            for: guest,
            identity: identity
        )
        return NativeHostBrowserProcessEvidence(
            identity: identity,
            dynamicCodeIsValid: dynamicValidity,
            appleAnchoredRequirementIsValid: anchoredRequirementValidity
        )
    }

    private static func appleAnchoredRequirementIsValid(
        for guest: SecCode,
        identity: NativeHostBrowserIdentity
    ) -> Bool {
        guard let source = NativeHostBrowserAuthenticationPolicy
            .appleAnchoredRequirementSource(for: identity) else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            source as CFString,
            SecCSFlags(rawValue: 0),
            &requirement
        ) == errSecSuccess,
              let requirement else { return false }

        // SecCodeCheckValidity evaluates the requirement against this live
        // guest. `anchor apple generic` in the compiled requirement establishes
        // the Apple trust chain; strict validation rejects structural weakness.
        return SecCodeCheckValidity(
            guest,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            requirement
        ) == errSecSuccess
    }
}

/// Routes the process before any native-messaging bytes are read. Chromium's
/// manifest allowlist remains the first boundary, but Bean revalidates the
/// caller too so an authorization left in an older on-disk manifest cannot
/// silently survive an app update.
enum NativeHostLaunchPolicy {
    private static let originPrefix = "chrome-extension://"

    static func extensionID(from origin: String) -> String? {
        guard origin.hasPrefix(originPrefix), origin.hasSuffix("/") else { return nil }
        let id = String(origin.dropFirst(originPrefix.count).dropLast())
        guard !id.contains("/"), BrowserBridgeInstaller.isValidExtensionID(id) else { return nil }
        return id
    }

    static func decision(arguments: [String],
                         isAuthorized: (String) -> Bool,
                         isBrowserAuthenticated: () -> Bool) -> NativeHostLaunchDecision {
        let originLikeArguments = arguments.filter {
            $0.lowercased().hasPrefix("chrome-extension:")
        }
        let nativeModeRequested = arguments.contains("--native-messaging-host")
            || !originLikeArguments.isEmpty
        guard nativeModeRequested else { return .gui }
        guard originLikeArguments.count == 1,
              let id = extensionID(from: originLikeArguments[0]),
              isAuthorized(id),
              isBrowserAuthenticated() else { return .reject }
        return .nativeHost
    }
}

/// Discovers the unpacked Bean extension from Chromium's metadata and writes
/// the per-user native-messaging manifest. It reads only extension ID/path
/// metadata and the extension's own manifest — never browser history or page
/// content.
struct BrowserBridgeInstaller {
    static let hostName = "com.bean.nativehost"
    static let approvedManualExtensionIDsKey = "browserBridgeApprovedManualExtensionIDs"
    /// Chromium's file can grow with the number of installed extensions, so
    /// keep automatic discovery generous while still bounding synchronous I/O
    /// and JSON parsing on Bean's UI path.
    static let maximumSecurePreferencesBytes = 32 * 1_024 * 1_024
    /// Bean's shipped extension manifest is only a few kilobytes. This allows
    /// ample future growth without accepting an unexpectedly large file.
    static let maximumExtensionManifestBytes = 256 * 1_024
    /// The generated native-host manifest contains only a path and origins.
    static let maximumNativeHostManifestBytes = 256 * 1_024
    static let defaultBrowsers = [
        BrowserBridgeBrowser(name: "Chrome", supportPath: "Library/Application Support/Google/Chrome"),
        BrowserBridgeBrowser(name: "Brave", supportPath: "Library/Application Support/BraveSoftware/Brave-Browser"),
        BrowserBridgeBrowser(name: "Edge", supportPath: "Library/Application Support/Microsoft Edge")
    ]

    let homeDirectory: URL
    let executableURL: URL
    let browsers: [BrowserBridgeBrowser]
    private let fileManager: FileManager
    private let removeItem: (URL) throws -> Void
    private let trustedExtensionDirectoryURL: URL?
    private let approvalDefaults: UserDefaults
    private let parentProcessIdentifier: () -> pid_t
    private let browserProcessEvidence: (pid_t) -> NativeHostBrowserProcessEvidence?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        executableURL: URL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: "/Applications/Bean.app/Contents/MacOS/Bean"),
        browsers: [BrowserBridgeBrowser] = BrowserBridgeInstaller.defaultBrowsers,
        fileManager: FileManager = .default,
        trustedExtensionDirectoryURL: URL? = Bundle.main.resourceURL?
            .appendingPathComponent("BrowserExtension", isDirectory: true),
        approvalDefaults: UserDefaults = .standard,
        removeItem: ((URL) throws -> Void)? = nil,
        parentProcessIdentifier: @escaping () -> pid_t = { getppid() },
        browserProcessEvidence: @escaping (pid_t) -> NativeHostBrowserProcessEvidence? = {
            NativeHostBrowserProcessInspector.evidence(for: $0)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.executableURL = executableURL
        self.browsers = browsers
        self.fileManager = fileManager
        self.removeItem = removeItem ?? { try ExactFileSystem.unlinkRegularFile(at: $0) }
        self.trustedExtensionDirectoryURL = trustedExtensionDirectoryURL
        self.approvalDefaults = approvalDefaults
        self.parentProcessIdentifier = parentProcessIdentifier
        self.browserProcessEvidence = browserProcessEvidence
    }

    func inspect() -> BrowserBridgeStatus {
        let installedBrowsers = browsers.filter { browserRootIsSafe($0) }
        guard !installedBrowsers.isEmpty else {
            return BrowserBridgeStatus(
                state: .unavailable, extensionIDs: [], detectedExtensionBrowserNames: [],
                browserNames: [], configuredBrowserNames: [],
                detail: "Open signed Chrome, Brave, or Edge once, then return here."
            )
        }

        // Preserve which browser actually contains the trusted unpacked
        // extension so setup can open the matching Extensions page instead of
        // guessing from a hard-coded application order. Explicit manual IDs
        // remain authorized, but intentionally do not pretend that Bean found
        // an extension in a browser profile.
        let discoveredByBrowser = installedBrowsers.map { browser in
            (browser: browser, ids: discoverExtensionIDs(in: [browser]))
        }
        let detectedBrowserNames = discoveredByBrowser.compactMap { discovery in
            discovery.ids.isEmpty ? nil : discovery.browser.name
        }
        let discoveredIDs = discoveredByBrowser.flatMap(\.ids)
        let ids = Array(Set(discoveredIDs + approvedManualExtensionIDs())).sorted()
        guard !ids.isEmpty else {
            return BrowserBridgeStatus(
                state: .extensionNotFound, extensionIDs: [], detectedExtensionBrowserNames: [],
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
            state: state, extensionIDs: ids,
            detectedExtensionBrowserNames: detectedBrowserNames,
            browserNames: installedBrowsers.map(\.name),
            configuredBrowserNames: configured.map(\.name), detail: detail
        )
    }

    /// Runtime authorization deliberately ignores every current native-host
    /// manifest. Those files are an enforcement output, never an input to trust.
    /// This closes the upgrade window where a stale origin could otherwise keep
    /// launching a newer Bean binary before the user opened Settings to repair it.
    func isAuthorizedNativeExtensionID(_ extensionID: String) -> Bool {
        guard Self.isValidExtensionID(extensionID) else { return false }
        let installedBrowsers = browsers.filter { browserRootIsSafe($0) }
        return authorizedExtensionIDs(in: installedBrowsers).contains(extensionID)
    }

    func nativeHostLaunchDecision(arguments: [String]) -> NativeHostLaunchDecision {
        NativeHostLaunchPolicy.decision(
            arguments: arguments,
            isAuthorized: { isAuthorizedNativeExtensionID($0) },
            isBrowserAuthenticated: {
                NativeHostBrowserAuthenticationPolicy.permits(
                    browserProcessEvidence(parentProcessIdentifier())
                )
            }
        )
    }

    @discardableResult
    func install(manualExtensionID: String? = nil) throws -> BrowserBridgeStatus {
        guard executableURL.exists(using: fileManager), fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw BrowserBridgeInstallerError.appExecutableMissing
        }
        var installedBrowsers: [BrowserBridgeBrowser] = []
        for browser in browsers {
            do {
                switch try ExactFileSystem.entryKind(at: browserRoot(browser)) {
                case .missing:
                    continue
                case .directory:
                    installedBrowsers.append(browser)
                case .regularFile, .symbolicLink, .other:
                    throw BrowserBridgeInstallerError.writeFailed(browser.name)
                }
            } catch let error as BrowserBridgeInstallerError {
                throw error
            } catch {
                throw BrowserBridgeInstallerError.writeFailed(browser.name)
            }
        }
        guard !installedBrowsers.isEmpty else { throw BrowserBridgeInstallerError.noSupportedBrowser }

        // Preflight every browser before changing an approval or writing the
        // first manifest. This avoids a partial install when any parent or exact
        // target is a symlink, directory, device, or otherwise unsafe entry.
        for browser in installedBrowsers {
            do { try validateManifestLocation(for: browser, allowMissingHostsDirectory: true) }
            catch { throw BrowserBridgeInstallerError.writeFailed(browser.name) }
        }

        var ids = discoverExtensionIDs(in: installedBrowsers)
        var manualApproval: String?
        if let value = manualExtensionID?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            guard Self.isValidExtensionID(value) else { throw BrowserBridgeInstallerError.invalidExtensionID }
            manualApproval = value
            ids.append(value)
        } else {
            ids.append(contentsOf: approvedManualExtensionIDs())
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
            do {
                let directory = try prepareManifestDirectory(for: browser)
                let destination = directory.appendingPathComponent("\(Self.hostName).json")
                try ExactFileSystem.writeAtomically(data, to: destination, permissions: 0o600)
            } catch {
                throw BrowserBridgeInstallerError.writeFailed(browser.name)
            }
        }
        if let manualApproval {
            // A manually entered ID is an explicit user authorization. Replace
            // the previous manual approval only after every manifest succeeds.
            approvalDefaults.set([manualApproval], forKey: Self.approvedManualExtensionIDsKey)
            approvalDefaults.synchronize()
        }
        return inspect()
    }

    /// Removes Bean's exact native-host manifest from each configured Chromium
    /// browser and clears only the explicit manual-extension approval owned by
    /// Bean. It never removes a browser directory, profile, extension, blocked
    /// site setting, or any neighboring native-host manifest.
    func removeBeanConnectionAndApprovals() -> BrowserBridgeRemovalResult {
        var removed: [String] = []
        var failed: [String] = []

        for browser in browsers {
            let root = browserRoot(browser)
            switch (try? ExactFileSystem.entryKind(at: root)) {
            case .missing:
                continue
            case .directory:
                do { try ExactFileSystem.requireRealDirectoryChain(from: homeDirectory, through: root) }
                catch {
                    failed.append(browser.name)
                    continue
                }
            case .regularFile, .symbolicLink, .other, .none:
                failed.append(browser.name)
                continue
            }

            let hosts = manifestDirectory(for: browser)
            switch (try? ExactFileSystem.entryKind(at: hosts)) {
            case .missing:
                continue
            case .directory:
                do { try ExactFileSystem.requireRealDirectoryChain(from: homeDirectory, through: hosts) }
                catch {
                    failed.append(browser.name)
                    continue
                }
            case .regularFile, .symbolicLink, .other, .none:
                failed.append(browser.name)
                continue
            }

            let manifest = hosts.appendingPathComponent("\(Self.hostName).json")
            switch (try? ExactFileSystem.entryKind(at: manifest)) {
            case .missing:
                continue
            case .regularFile:
                break
            case .directory, .symbolicLink, .other, .none:
                failed.append(browser.name)
                continue
            }
            do {
                try removeItem(manifest)
                if try ExactFileSystem.entryKind(at: manifest) != .missing {
                    failed.append(browser.name)
                } else {
                    removed.append(browser.name)
                }
            } catch {
                failed.append(browser.name)
            }
        }

        approvalDefaults.removeObject(forKey: Self.approvedManualExtensionIDsKey)
        approvalDefaults.synchronize()
        let approvalCleared = approvalDefaults.object(
            forKey: Self.approvedManualExtensionIDsKey
        ) == nil

        return BrowserBridgeRemovalResult(
            removedBrowserNames: removed.sorted(),
            failedBrowserNames: failed.sorted(),
            manualApprovalCleared: approvalCleared
        )
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
            guard (try? ExactFileSystem.requireRealDirectoryChain(
                from: homeDirectory, through: root
            )) != nil else { continue }
            guard let profiles = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for profile in profiles {
                let name = profile.lastPathComponent
                guard name == "Default" || name.hasPrefix("Profile ") || name == "Guest Profile" else { continue }
                // Browser metadata is not a trust anchor. Refuse a profile
                // symlink (or any symlinked intermediate component) before
                // looking at the preferences entry beneath it.
                guard (try? ExactFileSystem.requireRealDirectoryChain(
                    from: root, through: profile
                )) != nil else { continue }
                let preferences = profile.appendingPathComponent("Secure Preferences")
                guard let data = Self.readBoundedRegularFile(
                    at: preferences,
                    maximumBytes: Self.maximumSecurePreferencesBytes
                ),
                      let rootObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let extensions = rootObject["extensions"] as? [String: Any],
                      let settings = extensions["settings"] as? [String: Any] else { continue }
                for (id, rawEntry) in settings where Self.isValidExtensionID(id) {
                    guard let entry = rawEntry as? [String: Any],
                          let rawPath = entry["path"] as? String,
                          extensionAtPathIsTrustedBeanBundle(rawPath, relativeTo: root) else { continue }
                    result.insert(id)
                }
            }
        }
        return result.sorted()
    }

    private func authorizedExtensionIDs(in installedBrowsers: [BrowserBridgeBrowser]) -> [String] {
        Array(Set(discoverExtensionIDs(in: installedBrowsers) + approvedManualExtensionIDs())).sorted()
    }

    private func approvedManualExtensionIDs() -> [String] {
        (approvalDefaults.stringArray(forKey: Self.approvedManualExtensionIDsKey) ?? [])
            .filter(Self.isValidExtensionID)
    }

    /// Automatic authorization is deliberately path-bound to Bean's bundled
    /// extension. An unrelated extension can copy Bean's display name and request
    /// `nativeMessaging`; neither property proves that it is the extension the user
    /// revealed from this app. Repository/developer copies still work through the
    /// explicit 32-letter-ID fallback in Settings.
    private func extensionAtPathIsTrustedBeanBundle(_ rawPath: String,
                                                     relativeTo browserRoot: URL) -> Bool {
        guard let trustedExtensionDirectoryURL else { return false }
        let expanded = NSString(string: rawPath).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : browserRoot.appendingPathComponent(expanded)
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedTrustedURL = trustedExtensionDirectoryURL.standardizedFileURL
            .resolvingSymlinksInPath()
        guard resolvedURL == resolvedTrustedURL else { return false }
        // Read from the resolved trusted bundle rather than through the
        // browser-provided spelling of its path. The descriptor refuses a
        // final symlink, hard link, directory, device, socket, or oversized
        // file and never blocks opening a FIFO.
        let manifestURL = resolvedTrustedURL.appendingPathComponent("manifest.json")
        guard let data = Self.readBoundedRegularFile(
                at: manifestURL,
                maximumBytes: Self.maximumExtensionManifestBytes
              ),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["manifest_version"] as? Int == 3,
              manifest["name"] as? String == "Bean for the Web",
              let permissions = manifest["permissions"] as? [String],
              permissions.contains("nativeMessaging") else { return false }
        return true
    }

    private func manifestIsCurrent(for browser: BrowserBridgeBrowser,
                                   expectedOrigins: Set<String>) -> Bool {
        let url = manifestDirectory(for: browser).appendingPathComponent("\(Self.hostName).json")
        guard browserRootIsSafe(browser),
              (try? ExactFileSystem.requireRealDirectoryChain(
                from: homeDirectory, through: manifestDirectory(for: browser)
              )) != nil,
              let data = Self.readBoundedRegularFile(
                at: url,
                maximumBytes: Self.maximumNativeHostManifestBytes
              ),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["name"] as? String == Self.hostName,
              manifest["type"] as? String == "stdio",
              manifest["path"] as? String == executableURL.path,
              let origins = manifest["allowed_origins"] as? [String] else { return false }
        return Set(origins) == expectedOrigins
    }

    /// A nonblocking descriptor preflight keeps hostile special files from
    /// hanging the main thread. `fstat` binds validation to the opened inode,
    /// and the byte check is repeated while reading in case a regular file grows
    /// after the initial size check.
    private static func readBoundedRegularFile(at url: URL,
                                               maximumBytes: Int) -> Data? {
        guard maximumBytes >= 0 else { return nil }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_nlink == 1,
              information.st_size >= 0,
              information.st_size <= off_t(maximumBytes) else { return nil }

        var data = Data()
        data.reserveCapacity(Int(information.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard data.count <= maximumBytes - count else { return nil }
            data.append(buffer, count: count)
        }
    }

    private func browserRoot(_ browser: BrowserBridgeBrowser) -> URL {
        homeDirectory.appendingPathComponent(browser.supportPath, isDirectory: true)
    }

    private func manifestDirectory(for browser: BrowserBridgeBrowser) -> URL {
        browserRoot(browser).appendingPathComponent("NativeMessagingHosts", isDirectory: true)
    }

    private func browserRootIsSafe(_ browser: BrowserBridgeBrowser) -> Bool {
        (try? ExactFileSystem.requireRealDirectoryChain(
            from: homeDirectory,
            through: browserRoot(browser)
        )) != nil
    }

    private func validateManifestLocation(
        for browser: BrowserBridgeBrowser,
        allowMissingHostsDirectory: Bool
    ) throws {
        let root = browserRoot(browser)
        try ExactFileSystem.requireRealDirectoryChain(from: homeDirectory, through: root)
        let hosts = manifestDirectory(for: browser)
        switch try ExactFileSystem.entryKind(at: hosts) {
        case .missing where allowMissingHostsDirectory:
            return
        case .directory:
            try ExactFileSystem.requireRealDirectoryChain(from: homeDirectory, through: hosts)
            let manifest = hosts.appendingPathComponent("\(Self.hostName).json")
            switch try ExactFileSystem.entryKind(at: manifest) {
            case .missing, .regularFile:
                return
            case .directory, .symbolicLink, .other:
                throw BrowserBridgeInstallerError.writeFailed(browser.name)
            }
        case .missing, .regularFile, .symbolicLink, .other:
            throw BrowserBridgeInstallerError.writeFailed(browser.name)
        }
    }

    private func prepareManifestDirectory(for browser: BrowserBridgeBrowser) throws -> URL {
        let directory = manifestDirectory(for: browser)
        switch try ExactFileSystem.entryKind(at: directory) {
        case .missing:
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        case .directory:
            break
        case .regularFile, .symbolicLink, .other:
            throw BrowserBridgeInstallerError.writeFailed(browser.name)
        }
        try validateManifestLocation(for: browser, allowMissingHostsDirectory: false)
        return directory
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
            message = "Mac connection installed. Reload the extension once, then check its connection status."
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
