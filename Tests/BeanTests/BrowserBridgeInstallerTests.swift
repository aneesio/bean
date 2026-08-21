import XCTest
@testable import Bean

final class BrowserBridgeInstallerTests: XCTestCase {
    private let extensionID = "abcdefghijklmnopabcdefghijklmnop"

    func testDiscoversBeanExtensionAndInstallsExactManifest() throws {
        let fixture = try makeFixture(includeBeanExtension: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let before = fixture.installer.inspect()
        XCTAssertEqual(before.state, .readyToInstall)
        XCTAssertEqual(before.extensionIDs, [extensionID])

        let after = try fixture.installer.install()
        XCTAssertEqual(after.state, .installed)
        XCTAssertEqual(after.configuredBrowserNames, ["Test Browser"])

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
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(fixture.installer.inspect().state, .extensionNotFound)
        XCTAssertThrowsError(try fixture.installer.install()) { error in
            XCTAssertEqual(error as? BrowserBridgeInstallerError, .extensionNotFound)
        }
    }

    func testManualIDFallbackIsValidated() throws {
        let fixture = try makeFixture(includeBeanExtension: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try fixture.installer.install(manualExtensionID: "bad")) { error in
            XCTAssertEqual(error as? BrowserBridgeInstallerError, .invalidExtensionID)
        }
        XCTAssertEqual(try fixture.installer.install(manualExtensionID: extensionID).state, .installed)
    }

    private func makeFixture(includeBeanExtension: Bool) throws -> (
        root: URL, browserRoot: URL, executable: URL, installer: BrowserBridgeInstaller
    ) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("BeanBridgeTests-\(UUID().uuidString)")
        let browserRoot = root.appendingPathComponent("Browser")
        let profile = browserRoot.appendingPathComponent("Default")
        let extensionRoot = root.appendingPathComponent("LoadedExtension")
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        try fm.createDirectory(at: extensionRoot, withIntermediateDirectories: true)

        let extensionManifest: [String: Any] = [
            "name": includeBeanExtension ? "Bean — Inline Proofreading" : "Unrelated helper",
            "permissions": ["nativeMessaging"]
        ]
        try JSONSerialization.data(withJSONObject: extensionManifest).write(
            to: extensionRoot.appendingPathComponent("manifest.json"), options: .atomic
        )
        let preferences: [String: Any] = [
            "extensions": ["settings": [extensionID: ["path": extensionRoot.path]]]
        ]
        try JSONSerialization.data(withJSONObject: preferences).write(
            to: profile.appendingPathComponent("Secure Preferences"), options: .atomic
        )

        let executable = root.appendingPathComponent("Bean")
        try Data("fixture".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let installer = BrowserBridgeInstaller(
            homeDirectory: root,
            executableURL: executable,
            browsers: [BrowserBridgeBrowser(name: "Test Browser", supportPath: "Browser")]
        )
        return (root, browserRoot, executable, installer)
    }
}
