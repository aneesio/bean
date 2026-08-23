import Foundation
import XCTest

final class NativeMessagingScriptTests: XCTestCase {
    func testAdvancedInstallAndUninstallKeepExactApprovalAndManifestInSync() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeScriptTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent("Home", isDirectory: true)
        let browserRoot = home.appendingPathComponent(
            "Library/Application Support/Google/Chrome", isDirectory: true
        )
        let app = root.appendingPathComponent("Bean.app", isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/Bean")
        let fakeBin = root.appendingPathComponent("bin", isDirectory: true)
        let defaultsLog = root.appendingPathComponent("defaults.log")
        try FileManager.default.createDirectory(at: browserRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path
        )
        let fakeDefaults = fakeBin.appendingPathComponent("defaults")
        try Data("""
        #!/bin/bash
        printf '%s\\n' "$*" >> "$FAKE_DEFAULTS_LOG"
        """.utf8).write(to: fakeDefaults)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeDefaults.path
        )

        let extensionID = "abcdefghijklmnopabcdefghijklmnop"
        let environment = ProcessInfo.processInfo.environment.merging([
            "HOME": home.path,
            "PATH": "\(fakeBin.path):/usr/bin:/bin",
            "FAKE_DEFAULTS_LOG": defaultsLog.path
        ]) { _, testValue in testValue }
        let install = try run(
            repositoryRoot.appendingPathComponent("scripts/install_native_messaging_host.sh"),
            arguments: [extensionID, app.path], environment: environment
        )
        XCTAssertEqual(install.status, 0, install.output)

        let hosts = browserRoot.appendingPathComponent("NativeMessagingHosts")
        let manifest = hosts.appendingPathComponent("com.bean.nativehost.json")
        let neighbor = hosts.appendingPathComponent("com.other.nativehost.json")
        let profileMarker = browserRoot.appendingPathComponent("Default/keep.txt")
        let manifestJSON = try Data(contentsOf: manifest)
        let manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestJSON) as? [String: Any]
        )
        XCTAssertEqual(manifestObject["allowed_origins"] as? [String], [
            "chrome-extension://\(extensionID)/"
        ])
        XCTAssertEqual(manifestObject["path"] as? String, executable.path)
        try Data("neighbor".utf8).write(to: neighbor)
        try FileManager.default.createDirectory(
            at: profileMarker.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("profile".utf8).write(to: profileMarker)

        let uninstall = try run(
            repositoryRoot.appendingPathComponent("scripts/uninstall_native_messaging_host.sh"),
            arguments: [], environment: environment
        )
        XCTAssertEqual(uninstall.status, 0, uninstall.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbor.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileMarker.path))

        let calls = try String(contentsOf: defaultsLog, encoding: .utf8)
        XCTAssertTrue(calls.contains(
            "write com.bean.app browserBridgeApprovedManualExtensionIDs -array \(extensionID)"
        ))
        XCTAssertTrue(calls.contains(
            "delete com.bean.app browserBridgeApprovedManualExtensionIDs"
        ))
    }

    func testAdvancedInstallerJSONEscapesArbitraryAppPathAndUsesPrivateAtomicFile() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = try makeInstallFixture(appName: "Bean \"Quoted\"\nPath.app")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let extensionID = "abcdefghijklmnopabcdefghijklmnop"

        let install = try run(
            repositoryRoot.appendingPathComponent("scripts/install_native_messaging_host.sh"),
            arguments: [extensionID, fixture.app.path],
            environment: fixture.environment
        )

        XCTAssertEqual(install.status, 0, install.output)
        let hosts = fixture.browserRoot.appendingPathComponent("NativeMessagingHosts")
        let manifest = hosts.appendingPathComponent("com.bean.nativehost.json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
                as? [String: Any]
        )
        XCTAssertEqual(object["path"] as? String, fixture.executable.path)
        XCTAssertEqual(object["allowed_origins"] as? [String], [
            "chrome-extension://\(extensionID)/"
        ])
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: manifest.path)[.posixPermissions]
                as? NSNumber
        ).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: hosts.path)
                .contains { $0.hasPrefix(".com.bean.nativehost.json.") }
        )
    }

    func testAdvancedInstallerRefusesSymlinkAndDirectoryManifestTargets() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let extensionID = "abcdefghijklmnopabcdefghijklmnop"
        for targetKind in ["symlink", "directory"] {
            let fixture = try makeInstallFixture(appName: "Bean.app")
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let hosts = fixture.browserRoot.appendingPathComponent("NativeMessagingHosts")
            try FileManager.default.createDirectory(
                at: hosts, withIntermediateDirectories: false
            )
            let manifest = hosts.appendingPathComponent("com.bean.nativehost.json")
            let external = fixture.root.appendingPathComponent("external-\(targetKind)")
            let sentinel = Data("SCRIPT_\(targetKind)_SENTINEL".utf8)
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

            let install = try run(
                repositoryRoot.appendingPathComponent("scripts/install_native_messaging_host.sh"),
                arguments: [extensionID, fixture.app.path],
                environment: fixture.environment
            )

            XCTAssertNotEqual(install.status, 0)
            XCTAssertTrue(install.output.contains("unsafe existing manifest target"))
            if targetKind == "symlink" {
                XCTAssertEqual(try Data(contentsOf: external), sentinel)
                XCTAssertTrue(
                    try manifest.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
                )
            } else {
                XCTAssertEqual(
                    try Data(contentsOf: manifest.appendingPathComponent("keep.txt")),
                    sentinel
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.defaultsLog.path))
        }
    }

    func testAdvancedScriptsRefuseIntermediateAncestorSymlink() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeAncestorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent("Home", isDirectory: true)
        let applicationSupport = home.appendingPathComponent(
            "Library/Application Support", isDirectory: true
        )
        let externalGoogle = root.appendingPathComponent("ExternalGoogle", isDirectory: true)
        let browserRoot = externalGoogle.appendingPathComponent("Chrome", isDirectory: true)
        let hosts = browserRoot.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        let manifest = hosts.appendingPathComponent("com.bean.nativehost.json")
        let sentinel = root.appendingPathComponent("external-sentinel.txt")
        let app = root.appendingPathComponent("Bean.app", isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/Bean")
        let fakeBin = root.appendingPathComponent("bin", isDirectory: true)
        let defaultsLog = root.appendingPathComponent("defaults.log")

        try FileManager.default.createDirectory(
            at: applicationSupport, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path
        )
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: applicationSupport.appendingPathComponent("Google"),
            withDestinationURL: externalGoogle
        )

        let fakeDefaults = fakeBin.appendingPathComponent("defaults")
        try Data("""
        #!/bin/bash
        printf '%s\\n' "$*" >> "$FAKE_DEFAULTS_LOG"
        """.utf8).write(to: fakeDefaults)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeDefaults.path
        )
        let environment = ProcessInfo.processInfo.environment.merging([
            "HOME": home.path,
            "PATH": "\(fakeBin.path):/usr/bin:/bin",
            "FAKE_DEFAULTS_LOG": defaultsLog.path
        ]) { _, testValue in testValue }

        let extensionID = "abcdefghijklmnopabcdefghijklmnop"
        let install = try run(
            repositoryRoot.appendingPathComponent("scripts/install_native_messaging_host.sh"),
            arguments: [extensionID, app.path], environment: environment
        )
        XCTAssertNotEqual(install.status, 0)
        XCTAssertTrue(install.output.contains("unsafe browser directory chain"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultsLog.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))

        try Data("do-not-remove".utf8).write(to: manifest)
        let uninstall = try run(
            repositoryRoot.appendingPathComponent("scripts/uninstall_native_messaging_host.sh"),
            arguments: [], environment: environment
        )
        XCTAssertEqual(uninstall.status, 0, uninstall.output)
        XCTAssertTrue(uninstall.output.contains("Skipped unsafe browser directory chain"))
        XCTAssertEqual(try Data(contentsOf: manifest), Data("do-not-remove".utf8))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    private func makeInstallFixture(appName: String) throws -> (
        root: URL,
        browserRoot: URL,
        app: URL,
        executable: URL,
        defaultsLog: URL,
        environment: [String: String]
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeScriptFixture-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let browserRoot = home.appendingPathComponent(
            "Library/Application Support/Google/Chrome", isDirectory: true
        )
        let app = root.appendingPathComponent(appName, isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/Bean")
        let fakeBin = root.appendingPathComponent("bin", isDirectory: true)
        let defaultsLog = root.appendingPathComponent("defaults.log")
        try FileManager.default.createDirectory(
            at: browserRoot, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fakeBin, withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path
        )
        let fakeDefaults = fakeBin.appendingPathComponent("defaults")
        try Data("""
        #!/bin/bash
        printf '%s\\n' "$*" >> "$FAKE_DEFAULTS_LOG"
        """.utf8).write(to: fakeDefaults)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeDefaults.path
        )
        let environment = ProcessInfo.processInfo.environment.merging([
            "HOME": home.path,
            "PATH": "\(fakeBin.path):/usr/bin:/bin",
            "FAKE_DEFAULTS_LOG": defaultsLog.path
        ]) { _, testValue in testValue }
        return (root, browserRoot, app, executable, defaultsLog, environment)
    }

    private func run(
        _ script: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        return (process.terminationStatus, output)
    }
}
