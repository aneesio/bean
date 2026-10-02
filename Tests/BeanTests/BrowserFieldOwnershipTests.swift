import Foundation
import XCTest
@testable import Bean

final class BrowserFieldOwnershipTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let browser = BrowserFieldOwnershipIdentity(
        processIdentifier: 42, bundleIdentifier: "com.google.Chrome", processStartedAtMicroseconds: 100
    )

    func testFreshLeaseYieldsOnlyForTheExactBrowserProcess() throws {
        try withStore { store, _ in
            XCTAssertTrue(store.record(request("field-a"), for: browser, at: now))
            XCTAssertTrue(store.ownsField(for: browser, at: now.addingTimeInterval(4.9)))
            XCTAssertFalse(store.ownsField(for: browser, at: now.addingTimeInterval(5)))
            for other in [
                BrowserFieldOwnershipIdentity(processIdentifier: 43, bundleIdentifier: browser.bundleIdentifier,
                                              processStartedAtMicroseconds: browser.processStartedAtMicroseconds),
                BrowserFieldOwnershipIdentity(processIdentifier: browser.processIdentifier, bundleIdentifier: "com.brave.Browser",
                                              processStartedAtMicroseconds: browser.processStartedAtMicroseconds),
                BrowserFieldOwnershipIdentity(processIdentifier: browser.processIdentifier, bundleIdentifier: browser.bundleIdentifier,
                                              processStartedAtMicroseconds: 101)
            ] {
                XCTAssertFalse(store.ownsField(for: other, at: now))
            }
        }
    }

    func testBlurReleaseRestoresNativeCoverageAndOlderHeartbeatCannotReviveIt() throws {
        try withStore { store, _ in
            XCTAssertTrue(store.record(request("field-a"), for: browser, at: now))
            XCTAssertTrue(store.record(request("field-a", active: false, offset: 20), for: browser, at: now))
            XCTAssertFalse(store.ownsField(for: browser, at: now))
            XCTAssertFalse(store.record(request("field-a", offset: 10), for: browser, at: now))
            XCTAssertFalse(store.ownsField(for: browser, at: now))
        }
    }

    func testLateReleaseFromPreviousFieldCannotEraseCurrentField() throws {
        try withStore { store, _ in
            XCTAssertTrue(store.record(request("field-a"), for: browser, at: now))
            XCTAssertTrue(store.record(request("field-b", offset: 20), for: browser, at: now))
            XCTAssertFalse(store.record(request("field-a", active: false, offset: 30), for: browser, at: now))
            XCTAssertTrue(store.ownsField(for: browser, at: now))
            XCTAssertFalse(store.record(request("field-a", offset: 10), for: browser, at: now))
            XCTAssertTrue(store.ownsField(for: browser, at: now))
            XCTAssertTrue(store.record(request("field-b", active: false, offset: 40), for: browser, at: now))
            XCTAssertFalse(store.ownsField(for: browser, at: now))
        }
    }

    func testMissingHostDisabledExtensionAndExpiredLeaseAlwaysRestoreNativeCoverage() throws {
        try withStore { store, _ in
            XCTAssertFalse(store.ownsField(for: browser, at: now))
            XCTAssertTrue(store.record(request("field-a"), for: browser, at: now))
            XCTAssertFalse(store.ownsField(for: browser, at: now.addingTimeInterval(10)))
        }
    }

    func testMalformedTokensAndTimestampsCannotSuppressNativeCoverage() throws {
        try withStore { store, _ in
            let invalid = [
                request(""), request(String(repeating: "a", count: 129)), request("../field"),
                request("private text"), request("非"),
                request("field-a", offset: -5_001), request("field-a", offset: 1_001),
                BrowserFieldOwnershipRequest(fieldToken: "field-a", active: true, observedAtMilliseconds: .infinity),
                BrowserFieldOwnershipRequest(fieldToken: "field-a", active: true, observedAtMilliseconds: .nan)
            ]
            for value in invalid { XCTAssertFalse(store.record(value, for: browser, at: now)) }
            XCTAssertFalse(store.ownsField(for: browser, at: now))
        }
    }

    func testCorruptLongLivedLeaseFailsOpenToNativeCoverage() throws {
        try withStore { store, directory in
            XCTAssertTrue(store.record(request("field-a"), for: browser, at: now))
            let corrupt = BrowserFieldOwnershipLease(
                identity: browser, fieldToken: "field-a", active: true,
                observedAtMilliseconds: now.timeIntervalSince1970 * 1_000,
                expiresAt: now.addingTimeInterval(1_000)
            )
            try ExactFileSystem.writeAtomically(JSONEncoder().encode(corrupt),
                                                to: directory.appendingPathComponent("ownership-42.json"))
            XCTAssertFalse(store.ownsField(for: browser, at: now))
            try ExactFileSystem.writeAtomically(Data("broken".utf8),
                                                to: directory.appendingPathComponent("ownership-42.json"))
            XCTAssertFalse(store.ownsField(for: browser, at: now))
        }
    }

    func testRenewalUsesObservationDeadlineAndPrunesExpiredBrowserFiles() throws {
        try withStore { store, directory in
            XCTAssertTrue(store.record(request("field-a", offset: -4_000), for: browser, at: now))
            XCTAssertFalse(store.ownsField(for: browser, at: now.addingTimeInterval(1)))
            let second = BrowserFieldOwnershipIdentity(
                processIdentifier: 43, bundleIdentifier: "com.brave.Browser", processStartedAtMicroseconds: 200
            )
            XCTAssertTrue(store.record(request("field-b", offset: 2_000), for: second, at: now.addingTimeInterval(2)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ownership-42.json").path))
            XCTAssertTrue(store.ownsField(for: second, at: now.addingTimeInterval(2)))
        }
    }

    func testLeaseFilesContainOnlyContentFreeOwnershipAndArePrivate() throws {
        try withStore { store, directory in
            XCTAssertTrue(store.record(request("field-a"), for: browser, at: now))
            let data = try ExactFileSystem.readRegularFile(at: directory.appendingPathComponent("ownership-42.json"))
            XCTAssertEqual(data.permissions, 0o600)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data.data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["identity", "fieldToken", "active", "observedAtMilliseconds", "expiresAt"])
            let identity = try XCTUnwrap(object["identity"] as? [String: Any])
            XCTAssertEqual(Set(identity.keys), ["processIdentifier", "bundleIdentifier", "processStartedAtMicroseconds"])
        }
    }

    func testExpiredLeaseIsRemovedEvenWhenTheExtensionStopsSendingMessages() throws {
        try withStore { store, directory in
            XCTAssertTrue(store.record(request("field-a"), for: browser, at: now))
            XCTAssertTrue(store.removeExpiredLeases(at: now.addingTimeInterval(6)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ownership-42.json").path))
            XCTAssertFalse(store.ownsField(for: browser, at: now.addingTimeInterval(6)))
        }
    }

    func testOwnershipCapabilityIsAvailableWithoutAIOrWebAIEnabled() async throws {
        let configuration = NativeHostStatusConfiguration(
            providerConfigured: false, webInlineEnabled: false, timeout: 30,
            dailyAutomaticCallLimit: 20, automaticCallsToday: 0
        )
        let response = await NativeMessagingHost.processAsync(
            Data("{\"id\":\"status\",\"type\":\"getStatus\",\"protocolVersion\":1,\"extensionVersion\":\"0.7.2\",\"minimumAppVersion\":\"1.6.0\"}".utf8),
            statusConfiguration: configuration
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(object["fieldOwnershipAvailable"] as? Bool, true)
        XCTAssertEqual(object["providerConfigured"] as? Bool, false)
        XCTAssertEqual(object["webInlineEnabled"] as? Bool, false)
    }

    func testHostRejectsMalformedOwnershipBeforeAnyBrowserOrStoreAccess() async throws {
        let response = await NativeMessagingHost.processAsync(Data(
            "{\"id\":\"ownership\",\"type\":\"fieldOwnership\",\"protocolVersion\":1,\"extensionVersion\":\"0.7.2\",\"minimumAppVersion\":\"1.6.0\",\"ownership\":{\"fieldToken\":\"../bad\",\"active\":true,\"observedAtMilliseconds\":0}}".utf8
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["errorCode"] as? String, "invalidFieldOwnership")
    }

    private func request(_ token: String, active: Bool = true, offset: Double = 0) -> BrowserFieldOwnershipRequest {
        .init(fieldToken: token, active: active, observedAtMilliseconds: now.timeIntervalSince1970 * 1_000 + offset)
    }

    private func withStore(_ body: (BrowserFieldOwnershipStore, URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("BeanOwnershipTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(BrowserFieldOwnershipStore(directoryURL: directory), directory)
    }
}
