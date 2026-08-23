import Darwin
import Security
import XCTest
@testable import Bean

final class BrowserBridgeInstallerTests: XCTestCase {
    private let extensionID = "abcdefghijklmnopabcdefghijklmnop"

    func testDiscoversBeanExtensionAndInstallsExactManifest() throws {
        let fixture = try makeFixture(includeBeanExtension: true)
        defer { cleanup(fixture.root, defaultsSuiteName: fixture.defaultsSuiteName) }

        let before = fixture.installer.inspect()
        XCTAssertEqual(before.state, .readyToInstall)
        XCTAssertEqual(before.extensionIDs, [extensionID])
        XCTAssertEqual(before.detectedExtensionBrowserNames, ["Test Browser"])
        XCTAssertEqual(fixture.installer.nativeHostLaunchDecision(arguments: [
            "chrome-extension://\(extensionID)/"
        ]), .nativeHost)

        let after = try fixture.installer.install()
        XCTAssertEqual(after.state, .installed)
        XCTAssertEqual(after.configuredBrowserNames, ["Test Browser"])
        XCTAssertEqual(after.detectedExtensionBrowserNames, ["Test Browser"])

        let manifestURL = fixture.browserRoot
            .appendingPathComponent("NativeMessagingHosts/com.bean.nativehost.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(manifest["path"] as? String, fixture.executable.path)
        XCTAssertEqual(manifest["allowed_origins"] as? [String], [
            "chrome-extension://\(extensionID)/"
        ])
    }

    func testDoesNotTrustAnUnrelatedNativeMessagingExtension() throws {
        let fixture = try makeFixture(includeBeanExtension: false)
        defer { cleanup(fixture.root, defaultsSuiteName: fixture.defaultsSuiteName) }

        XCTAssertEqual(fixture.installer.inspect().state, .extensionNotFound)
        XCTAssertThrowsError(try fixture.installer.install()) { error in
            XCTAssertEqual(error as? BrowserBridgeInstallerError, .extensionNotFound)
        }
    }

    func testManualIDFallbackIsValidated() throws {
        let fixture = try makeFixture(includeBeanExtension: false)
        defer { cleanup(fixture.root, defaultsSuiteName: fixture.defaultsSuiteName) }

        XCTAssertThrowsError(try fixture.installer.install(manualExtensionID: "bad")) { error in
            XCTAssertEqual(error as? BrowserBridgeInstallerError, .invalidExtensionID)
        }
        XCTAssertEqual(try fixture.installer.install(manualExtensionID: extensionID).state, .installed)
        XCTAssertEqual(fixture.installer.inspect().extensionIDs, [extensionID],
                       "an explicit manual approval survives a later status refresh")
        XCTAssertEqual(fixture.installer.nativeHostLaunchDecision(arguments: [
            "chrome-extension://\(extensionID)/"
        ]), .nativeHost)
    }

    func testExtensionsPageRoutingPrefersTheBrowserWhereBeanDetectedTheExtension() {
        let status = BrowserBridgeStatus(
            state: .needsRepair,
            extensionIDs: [extensionID],
            detectedExtensionBrowserNames: ["Brave"],
            browserNames: ["Chrome", "Brave", "Edge"],
            configuredBrowserNames: ["Chrome"],
            detail: "Repair required."
        )

        XCTAssertEqual(BrowserExtensionsPageRouting.targets(for: status), [.brave])
        XCTAssertEqual(
            BrowserExtensionsPageTarget.brave.extensionsPageURL.absoluteString,
            "brave://extensions/"
        )
    }

    func testExtensionsPageRoutingUsesConfiguredBrowserForManualApproval() {
        let status = BrowserBridgeStatus(
            state: .needsRepair,
            extensionIDs: [extensionID],
            detectedExtensionBrowserNames: [],
            browserNames: ["Chrome", "Edge"],
            configuredBrowserNames: ["Edge"],
            detail: "Repair required."
        )

        XCTAssertEqual(BrowserExtensionsPageRouting.targets(for: status), [.edge])
        XCTAssertEqual(
            BrowserExtensionsPageTarget.edge.extensionsPageURL.absoluteString,
            "edge://extensions/"
        )
    }

    func testExtensionsPageRoutingOffersEveryDetectedBrowserInsteadOfGuessing() {
        let status = BrowserBridgeStatus(
            state: .extensionNotFound,
            extensionIDs: [],
            detectedExtensionBrowserNames: [],
            browserNames: ["Chrome", "Brave", "Edge"],
            configuredBrowserNames: [],
            detail: "Choose a browser."
        )

        XCTAssertEqual(
            BrowserExtensionsPageRouting.targets(for: status),
            [.chrome, .brave, .edge]
        )
        XCTAssertEqual(
            BrowserExtensionsPageTarget.chrome.extensionsPageURL.absoluteString,
            "chrome://extensions/"
        )
    }

    func testOversizedSecurePreferencesIsSkippedAndManualFallbackStillWorks() throws {
        let fixture = try makeFixture(includeBeanExtension: true)
        defer { cleanup(fixture.root, defaultsSuiteName: fixture.defaultsSuiteName) }
        let preferences = fixture.browserRoot
            .appendingPathComponent("Default/Secure Preferences")
        try Data(
            repeating: 0x20,
            count: BrowserBridgeInstaller.maximumSecurePreferencesBytes + 1
        ).write(to: preferences)

        XCTAssertEqual(fixture.installer.inspect().state, .extensionNotFound)
        XCTAssertEqual(
            try fixture.installer.install(manualExtensionID: extensionID).state,
            .installed,
            "bounded automatic discovery must not remove the explicit manual-ID recovery path"
        )
    }

    func testSparseOversizedSecurePreferencesIsRejectedBeforeReading() throws {
        let fixture = try makeFixture(includeBeanExtension: true)
        defer { cleanup(fixture.root, defaultsSuiteName: fixture.defaultsSuiteName) }
        let preferences = fixture.browserRoot
            .appendingPathComponent("Default/Secure Preferences")
        let descriptor = preferences.path.withCString {
            Darwin.open($0, O_WRONLY | O_TRUNC | O_CLOEXEC)
        }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        XCTAssertEqual(
            ftruncate(
                descriptor,
                off_t(BrowserBridgeInstaller.maximumSecurePreferencesBytes + 1)
            ),
            0
        )
        _ = Darwin.close(descriptor)

        XCTAssertEqual(fixture.installer.inspect().state, .extensionNotFound)
    }

    func testSpecialSecurePreferencesCannotBlockDiscovery() throws {
        let fixture = try makeFixture(includeBeanExtension: true)
        defer { cleanup(fixture.root, defaultsSuiteName: fixture.defaultsSuiteName) }
        let preferences = fixture.browserRoot
            .appendingPathComponent("Default/Secure Preferences")
        try FileManager.default.removeItem(at: preferences)
        XCTAssertEqual(
            preferences.path.withCString { Darwin.mkfifo($0, mode_t(0o600)) },
            0
        )

        XCTAssertEqual(
            fixture.installer.inspect().state,
            .extensionNotFound,
            "a FIFO must be rejected without waiting for a writer"
        )
    }

    func testSymlinkedSecurePreferencesIsNeverFollowed() throws {
        let fixture = try makeFixture(includeBeanExtension: true)
        defer { cleanup(fixture.root, defaultsSuiteName: fixture.defaultsSuiteName) }
        let preferences = fixture.browserRoot
            .appendingPathComponent("Default/Secure Preferences")
        let validPreferences = try Data(contentsOf: preferences)
        let external = fixture.root.appendingPathComponent("ExternalSecurePreferences")
        try validPreferences.write(to: external)
        try FileManager.default.removeItem(at: preferences)
        try FileManager.default.createSymbolicLink(
            at: preferences, withDestinationURL: external
        )

        XCTAssertEqual(fixture.installer.inspect().state, .extensionNotFound)
        XCTAssertEqual(try Data(contentsOf: external), validPreferences)
    }

    func testSymlinkedProfileCannotEscapeValidatedBrowserRoot() throws {
        let fixture = try makeFixture(includeBeanExtension: true)
        defer { cleanup(fixture.root, defaultsSuiteName: fixture.defaultsSuiteName) }
        let profile = fixture.browserRoot.appendingPathComponent("Default", isDirectory: true)
        let validPreferences = try Data(
            contentsOf: profile.appendingPathComponent("Secure Preferences")
        )
        let externalProfile = fixture.root.appendingPathComponent(
            "ExternalProfile", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: externalProfile, withIntermediateDirectories: false
        )
        try validPreferences.write(
            to: externalProfile.appendingPathComponent("Secure Preferences")
        )
        try FileManager.default.removeItem(at: profile)
        try FileManager.default.createSymbolicLink(
            at: profile, withDestinationURL: externalProfile
        )

        XCTAssertEqual(fixture.installer.inspect().state, .extensionNotFound)
        XCTAssertEqual(
            try fixture.installer.install(manualExtensionID: extensionID).state,
            .installed
        )
    }

    func testOversizedTrustedExtensionManifestIsRejected() throws {
        let fixture = try makeFixture(includeBeanExtension: true)
        defer { cleanup(fixture.root, defaultsSuiteName: fixture.defaultsSuiteName) }
        let manifest = fixture.root.appendingPathComponent("LoadedExtension/manifest.json")
        try Data(
            repeating: 0x20,
            count: BrowserBridgeInstaller.maximumExtensionManifestBytes + 1
        ).write(to: manifest)

        XCTAssertEqual(fixture.installer.inspect().state, .extensionNotFound)
    }

    func testSymlinkedTrustedExtensionManifestIsNeverFollowed() throws {
        let fixture = try makeFixture(includeBeanExtension: true)
        defer { cleanup(fixture.root, defaultsSuiteName: fixture.defaultsSuiteName) }
        let manifest = fixture.root.appendingPathComponent("LoadedExtension/manifest.json")
        let validManifest = try Data(contentsOf: manifest)
        let external = fixture.root.appendingPathComponent("ExternalExtensionManifest.json")
        try validManifest.write(to: external)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(
            at: manifest, withDestinationURL: external
        )

        XCTAssertEqual(fixture.installer.inspect().state, .extensionNotFound)
        XCTAssertEqual(try Data(contentsOf: external), validManifest)
    }

    func testDoesNotAutoAuthorizeANameAndPermissionSpoofAtAnotherPath() throws {
        let fixture = try makeFixture(includeBeanExtension: true, loadedFromTrustedBundle: false)
        defer { cleanup(fixture.root, defaultsSuiteName: fixture.defaultsSuiteName) }

        XCTAssertEqual(fixture.installer.inspect().state, .extensionNotFound)
        XCTAssertEqual(fixture.installer.nativeHostLaunchDecision(arguments: [
            "chrome-extension://\(extensionID)/"
        ]), .reject)
        XCTAssertThrowsError(try fixture.installer.install()) { error in
            XCTAssertEqual(error as? BrowserBridgeInstallerError, .extensionNotFound)
        }
    }

    func testRepairReplacesStaleManifestOriginsInsteadOfInheritingThem() throws {
        let fixture = try makeFixture(includeBeanExtension: false)
        defer { cleanup(fixture.root, defaultsSuiteName: fixture.defaultsSuiteName) }
        let staleID = "pppppppppppppppppppppppppppppppp"
        let manifestURL = fixture.browserRoot
            .appendingPathComponent("NativeMessagingHosts/com.bean.nativehost.json")
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let staleManifest: [String: Any] = [
            "name": BrowserBridgeInstaller.hostName,
            "path": fixture.executable.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(staleID)/"]
        ]
        try JSONSerialization.data(withJSONObject: staleManifest).write(to: manifestURL, options: .atomic)

        XCTAssertEqual(fixture.installer.inspect().state, .extensionNotFound,
                       "an old native-host manifest is not an authorization source")
        XCTAssertEqual(fixture.installer.nativeHostLaunchDecision(arguments: [
            "chrome-extension://\(staleID)/"
        ]), .reject, "a stale manifest origin cannot launch the native pipe loop")
        _ = try fixture.installer.install(manualExtensionID: extensionID)
        let written = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        XCTAssertEqual(written["allowed_origins"] as? [String], [
            "chrome-extension://\(extensionID)/"
        ])
    }

    func testNativeHostLaunchPolicyRequiresOneCanonicalAuthorizedOrigin() {
        let allowed = extensionID
        let other = "pppppppppppppppppppppppppppppppp"
        let authorize: (String) -> Bool = { $0 == allowed }

        XCTAssertEqual(NativeHostLaunchPolicy.decision(
            arguments: [], isAuthorized: authorize,
            isBrowserAuthenticated: { true }
        ), .gui)
        XCTAssertEqual(NativeHostLaunchPolicy.decision(
            arguments: ["--some-normal-app-argument"], isAuthorized: authorize,
            isBrowserAuthenticated: { true }
        ), .gui)
        XCTAssertEqual(NativeHostLaunchPolicy.decision(
            arguments: ["chrome-extension://\(allowed)/"], isAuthorized: authorize,
            isBrowserAuthenticated: { true }
        ), .nativeHost)
        XCTAssertEqual(NativeHostLaunchPolicy.decision(
            arguments: ["chrome-extension://\(allowed)/"], isAuthorized: authorize,
            isBrowserAuthenticated: { false }
        ), .reject, "a forgeable origin argument cannot enter the native pipe loop")

        for arguments in [
            ["--native-messaging-host"],
            ["chrome-extension://bad/"],
            ["chrome-extension://\(other)/"],
            ["chrome-extension://\(allowed)"],
            ["chrome-extension://\(allowed)/extra"],
            ["CHROME-EXTENSION://\(allowed)/"],
            ["chrome-extension://\(allowed)/", "chrome-extension://\(allowed)/"],
            ["chrome-extension://\(allowed)/", "chrome-extension://bad/"]
        ] {
            XCTAssertEqual(NativeHostLaunchPolicy.decision(
                arguments: arguments, isAuthorized: authorize,
                isBrowserAuthenticated: { true }
            ), .reject, "Rejected native invocation: \(arguments)")
        }
    }

    func testNativeHostBrowserAuthenticationRequiresDynamicValidityAppleAnchorAndExactVendorPair() throws {
        let chromeMain = NativeHostBrowserIdentity(
            signingIdentifier: "com.google.Chrome",
            teamIdentifier: "EQHXZ8M8AV"
        )
        let chromeHelper = NativeHostBrowserIdentity(
            signingIdentifier: "com.google.Chrome.helper",
            teamIdentifier: "EQHXZ8M8AV"
        )
        let braveRenderer = NativeHostBrowserIdentity(
            signingIdentifier: "com.brave.Browser.helper.renderer",
            teamIdentifier: "KL8N8XSYF4"
        )
        let edgeMain = NativeHostBrowserIdentity(
            signingIdentifier: "com.microsoft.edgemac",
            teamIdentifier: "UBF8T346G9"
        )
        for identity in [chromeMain, chromeHelper, braveRenderer, edgeMain] {
            XCTAssertTrue(NativeHostBrowserAuthenticationPolicy.permits(
                NativeHostBrowserProcessEvidence(
                    identity: identity,
                    dynamicCodeIsValid: true,
                    appleAnchoredRequirementIsValid: true
                )
            ))
        }

        XCTAssertFalse(
            NativeHostBrowserAuthenticationPolicy.permits(
                NativeHostBrowserProcessEvidence(
                    identity: chromeMain,
                    dynamicCodeIsValid: true,
                    appleAnchoredRequirementIsValid: false
                )
            ),
            "Valid code and matching metadata cannot substitute for the Apple-anchored requirement"
        )
        XCTAssertFalse(NativeHostBrowserAuthenticationPolicy.permits(
            NativeHostBrowserProcessEvidence(
                identity: chromeMain,
                dynamicCodeIsValid: false,
                appleAnchoredRequirementIsValid: true
            )
        ))
        XCTAssertFalse(NativeHostBrowserAuthenticationPolicy.permits(
            NativeHostBrowserProcessEvidence(
                identity: NativeHostBrowserIdentity(
                    signingIdentifier: "com.google.Chrome",
                    teamIdentifier: "ATTACKER01"
                ),
                dynamicCodeIsValid: true,
                appleAnchoredRequirementIsValid: true
            )
        ))
        XCTAssertFalse(NativeHostBrowserAuthenticationPolicy.permits(
            NativeHostBrowserProcessEvidence(
                identity: NativeHostBrowserIdentity(
                    signingIdentifier: "org.chromium.Chromium",
                    teamIdentifier: ""
                ),
                dynamicCodeIsValid: true,
                appleAnchoredRequirementIsValid: true
            )
        ), "generic/ad-hoc Chromium has no stable vendor Team ID and must fail closed")
        XCTAssertFalse(NativeHostBrowserAuthenticationPolicy.permits(nil))

        let chromeRequirementSource = try XCTUnwrap(
            NativeHostBrowserAuthenticationPolicy.appleAnchoredRequirementSource(
                for: chromeMain
            )
        )
        XCTAssertEqual(
            chromeRequirementSource,
            #"anchor apple generic and identifier "com.google.Chrome" and certificate leaf[subject.OU] = "EQHXZ8M8AV""#
        )
        for identity in NativeHostBrowserAuthenticationPolicy.allowedIdentities {
            let source = try XCTUnwrap(
                NativeHostBrowserAuthenticationPolicy.appleAnchoredRequirementSource(
                    for: identity
                )
            )
            var compiledRequirement: SecRequirement?
            XCTAssertEqual(
                SecRequirementCreateWithString(
                    source as CFString,
                    SecCSFlags(rawValue: 0),
                    &compiledRequirement
                ),
                errSecSuccess,
                "Every shipped browser requirement must compile with Security.framework"
            )
            XCTAssertNotNil(compiledRequirement)
        }
        XCTAssertNil(
            NativeHostBrowserAuthenticationPolicy.appleAnchoredRequirementSource(
                for: NativeHostBrowserIdentity(
                    signingIdentifier: #"com.google.Chrome" or true"#,
                    teamIdentifier: "EQHXZ8M8AV"
                )
            ),
            "process-provided metadata must never be able to inject requirement syntax"
        )
    }

    func testFullResetRemovesOnlyBeanManifestAndManualApproval() throws {
        let fixture = try makeFixture(includeBeanExtension: false)
        defer { cleanup(fixture.root, defaultsSuiteName: fixture.defaultsSuiteName) }
        _ = try fixture.installer.install(manualExtensionID: extensionID)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: fixture.defaultsSuiteName))
        defaults.set("keep", forKey: "unrelated-browser-preference")

        let hosts = fixture.browserRoot.appendingPathComponent("NativeMessagingHosts")
        let beanManifest = hosts.appendingPathComponent("com.bean.nativehost.json")
        let unrelatedManifest = hosts.appendingPathComponent("com.other.nativehost.json")
        let profileMarker = fixture.browserRoot.appendingPathComponent("Default/keep-me.txt")
        try Data("unrelated".utf8).write(to: unrelatedManifest)
        try Data("profile data".utf8).write(to: profileMarker)

        let result = fixture.installer.removeBeanConnectionAndApprovals()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.removedBrowserNames, ["Test Browser"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: beanManifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedManifest.path),
                      "full reset must not touch another native host")
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileMarker.path),
                      "full reset must not touch browser profiles or extension data")
        XCTAssertEqual(defaults.string(forKey: "unrelated-browser-preference"), "keep",
                       "bridge cleanup must clear only Bean's manual-approval key")
        XCTAssertEqual(fixture.installer.inspect().state, .extensionNotFound)
        XCTAssertEqual(fixture.installer.nativeHostLaunchDecision(arguments: [
            "chrome-extension://\(extensionID)/"
        ]), .reject, "manual native-host authorization must be cleared")
    }

    func testFullResetReportsEachBrowserManifestRemovalFailure() throws {
        let fixture = try makeFixture(
            includeBeanExtension: false,
            removeItem: { url in
                if url.path.contains("NativeMessagingHosts") {
                    throw NSError(domain: "test", code: 1)
                }
                try FileManager.default.removeItem(at: url)
            }
        )
        defer { cleanup(fixture.root, defaultsSuiteName: fixture.defaultsSuiteName) }
        let hosts = fixture.browserRoot.appendingPathComponent("NativeMessagingHosts")
        try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
        let beanManifest = hosts.appendingPathComponent("com.bean.nativehost.json")
        try Data("{}".utf8).write(to: beanManifest)

        let result = fixture.installer.removeBeanConnectionAndApprovals()

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failedBrowserNames, ["Test Browser"])
        XCTAssertTrue(result.manualApprovalCleared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: beanManifest.path))
    }

    func testFullResetNeverTraversesSymlinkedNativeHostDirectory() throws {
        let fixture = try makeFixture(includeBeanExtension: false)
        defer { cleanup(fixture.root, defaultsSuiteName: fixture.defaultsSuiteName) }
        let externalHosts = fixture.root.appendingPathComponent("ExternalNativeHosts")
        try FileManager.default.createDirectory(at: externalHosts, withIntermediateDirectories: true)
        let externalTarget = externalHosts.appendingPathComponent("com.bean.nativehost.json")
        try Data("external file with generated name".utf8).write(to: externalTarget)
        let redirectedHosts = fixture.browserRoot.appendingPathComponent("NativeMessagingHosts")
        try FileManager.default.createSymbolicLink(
            at: redirectedHosts, withDestinationURL: externalHosts
        )

        let result = fixture.installer.removeBeanConnectionAndApprovals()

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failedBrowserNames, ["Test Browser"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalTarget.path),
                      "reset must not traverse a host-directory symlink")
        XCTAssertEqual(try Data(contentsOf: externalTarget),
                       Data("external file with generated name".utf8))
    }

    func testInstallRefusesSymlinkedNativeHostDirectoryWithoutTouchingExternalManifest() throws {
        let fixture = try makeFixture(includeBeanExtension: false)
        defer { cleanup(fixture.root, defaultsSuiteName: fixture.defaultsSuiteName) }
        let externalHosts = fixture.root.appendingPathComponent("ExternalInstallHosts")
        try FileManager.default.createDirectory(at: externalHosts, withIntermediateDirectories: true)
        let externalManifest = externalHosts.appendingPathComponent("com.bean.nativehost.json")
        let sentinel = Data("EXTERNAL_MANIFEST_SENTINEL".utf8)
        try sentinel.write(to: externalManifest)
        let hosts = fixture.browserRoot.appendingPathComponent("NativeMessagingHosts")
        try FileManager.default.createSymbolicLink(at: hosts, withDestinationURL: externalHosts)

        XCTAssertThrowsError(try fixture.installer.install(manualExtensionID: extensionID)) {
            XCTAssertEqual(
                $0 as? BrowserBridgeInstallerError,
                .writeFailed("Test Browser")
            )
        }
        XCTAssertEqual(try Data(contentsOf: externalManifest), sentinel)
        XCTAssertTrue(try hosts.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    func testInstallRefusesSymlinkOrDirectoryAtExactManifestTarget() throws {
        for targetKind in ["symlink", "directory"] {
            let fixture = try makeFixture(includeBeanExtension: false)
            defer { cleanup(fixture.root, defaultsSuiteName: fixture.defaultsSuiteName) }
            let hosts = fixture.browserRoot.appendingPathComponent("NativeMessagingHosts")
            try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
            let manifest = hosts.appendingPathComponent("com.bean.nativehost.json")
            let external = fixture.root.appendingPathComponent("external-\(targetKind)")
            let sentinel = Data("EXTERNAL_\(targetKind)_SENTINEL".utf8)
            if targetKind == "symlink" {
                try sentinel.write(to: external)
                try FileManager.default.createSymbolicLink(
                    at: manifest, withDestinationURL: external
                )
            } else {
                try FileManager.default.createDirectory(
                    at: manifest, withIntermediateDirectories: false
                )
                try sentinel.write(to: manifest.appendingPathComponent("keep.txt"))
            }

            XCTAssertThrowsError(try fixture.installer.install(manualExtensionID: extensionID)) {
                XCTAssertEqual(
                    $0 as? BrowserBridgeInstallerError,
                    .writeFailed("Test Browser")
                )
            }
            if targetKind == "symlink" {
                XCTAssertEqual(try Data(contentsOf: external), sentinel)
                XCTAssertTrue(try manifest.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
            } else {
                XCTAssertEqual(
                    try Data(contentsOf: manifest.appendingPathComponent("keep.txt")),
                    sentinel
                )
            }
        }
    }

    func testRemovalRefusesSymlinkOrDirectoryAtExactManifestTarget() throws {
        for targetKind in ["symlink", "directory"] {
            let fixture = try makeFixture(includeBeanExtension: false)
            defer { cleanup(fixture.root, defaultsSuiteName: fixture.defaultsSuiteName) }
            let hosts = fixture.browserRoot.appendingPathComponent("NativeMessagingHosts")
            try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
            let manifest = hosts.appendingPathComponent("com.bean.nativehost.json")
            let external = fixture.root.appendingPathComponent("remove-external-\(targetKind)")
            let sentinel = Data("REMOVE_\(targetKind)_SENTINEL".utf8)
            if targetKind == "symlink" {
                try sentinel.write(to: external)
                try FileManager.default.createSymbolicLink(
                    at: manifest, withDestinationURL: external
                )
            } else {
                try FileManager.default.createDirectory(
                    at: manifest, withIntermediateDirectories: false
                )
                try sentinel.write(to: manifest.appendingPathComponent("keep.txt"))
            }

            let result = fixture.installer.removeBeanConnectionAndApprovals()

            XCTAssertEqual(result.failedBrowserNames, ["Test Browser"])
            XCTAssertTrue(result.removedBrowserNames.isEmpty)
            if targetKind == "symlink" {
                XCTAssertEqual(try Data(contentsOf: external), sentinel)
                XCTAssertTrue(try manifest.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
            } else {
                XCTAssertEqual(
                    try Data(contentsOf: manifest.appendingPathComponent("keep.txt")),
                    sentinel
                )
            }
        }
    }

    private func makeFixture(includeBeanExtension: Bool,
                             loadedFromTrustedBundle: Bool = true,
                             removeItem: ((URL) throws -> Void)? = nil) throws -> (
        root: URL, browserRoot: URL, executable: URL,
        defaultsSuiteName: String, installer: BrowserBridgeInstaller
    ) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("BeanBridgeTests-\(UUID().uuidString)")
        let browserRoot = root.appendingPathComponent("Browser")
        let profile = browserRoot.appendingPathComponent("Default")
        let extensionRoot = root.appendingPathComponent("LoadedExtension")
        let trustedExtensionRoot = loadedFromTrustedBundle
            ? extensionRoot : root.appendingPathComponent("BundledBrowserExtension")
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        try fm.createDirectory(at: extensionRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: trustedExtensionRoot, withIntermediateDirectories: true)

        let extensionManifest: [String: Any] = [
            "manifest_version": 3,
            "name": includeBeanExtension ? "Bean for the Web" : "Unrelated helper",
            "permissions": ["nativeMessaging"]
        ]
        try JSONSerialization.data(withJSONObject: extensionManifest).write(
            to: extensionRoot.appendingPathComponent("manifest.json"), options: .atomic
        )
        if trustedExtensionRoot != extensionRoot {
            let trustedManifest: [String: Any] = [
                "manifest_version": 3,
                "name": "Bean for the Web",
                "permissions": ["nativeMessaging"]
            ]
            try JSONSerialization.data(withJSONObject: trustedManifest).write(
                to: trustedExtensionRoot.appendingPathComponent("manifest.json"), options: .atomic
            )
        }
        let preferences: [String: Any] = [
            "extensions": ["settings": [extensionID: ["path": extensionRoot.path]]]
        ]
        try JSONSerialization.data(withJSONObject: preferences).write(
            to: profile.appendingPathComponent("Secure Preferences"), options: .atomic
        )

        let executable = root.appendingPathComponent("Bean")
        try Data("fixture".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let defaultsSuiteName = "BeanBridgeTests-\(UUID().uuidString)"
        let approvalDefaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        approvalDefaults.removePersistentDomain(forName: defaultsSuiteName)
        let installer = BrowserBridgeInstaller(
            homeDirectory: root,
            executableURL: executable,
            browsers: [BrowserBridgeBrowser(name: "Test Browser", supportPath: "Browser")],
            trustedExtensionDirectoryURL: trustedExtensionRoot,
            approvalDefaults: approvalDefaults,
            removeItem: removeItem,
            parentProcessIdentifier: { 42 },
            browserProcessEvidence: { _ in
                NativeHostBrowserProcessEvidence(
                    identity: NativeHostBrowserIdentity(
                        signingIdentifier: "com.google.Chrome",
                        teamIdentifier: "EQHXZ8M8AV"
                    ),
                    dynamicCodeIsValid: true,
                    appleAnchoredRequirementIsValid: true
                )
            }
        )
        return (root, browserRoot, executable, defaultsSuiteName, installer)
    }

    private func cleanup(_ root: URL, defaultsSuiteName: String) {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(
            forName: defaultsSuiteName
        )
    }
}
