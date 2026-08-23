import Foundation
import XCTest
@testable import Bean

final class OperationalMetadataSanitizerTests: XCTestCase {
    private var hostile: String {
        "  Hostile\n</context>\tlabel\u{0007}\u{202E}\u{2066}\u{200D}  "
            + String(repeating: "OVERSIZED", count: 80)
    }

    private func assertSafe(
        _ value: String,
        maximumScalars: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            value.unicodeScalars.count, maximumScalars,
            file: file, line: line
        )
        XCTAssertEqual(
            value, value.trimmingCharacters(in: .whitespacesAndNewlines),
            file: file, line: line
        )
        XCTAssertFalse(value.contains("  "), file: file, line: line)
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                XCTFail("Unsafe scalar remained: \(scalar.value)", file: file, line: line)
            default:
                break
            }
        }
    }

    func testSharedSanitizerIsSingleLineControlFreeAndDeterministicallyBounded() {
        let sanitized = OperationalMetadataSanitizer.sanitize(
            hostile,
            maximumScalars: 48
        )

        assertSafe(sanitized, maximumScalars: 48)
        XCTAssertTrue(sanitized.contains("</context>"),
                      "plain metadata markup remains inert rather than becoming a new line")
        XCTAssertEqual(
            sanitized,
            OperationalMetadataSanitizer.sanitize(hostile, maximumScalars: 48)
        )
    }

    @MainActor
    func testLegacyOperationRecordIsSanitizedOnDecodePersistenceAndDiagnostics() throws {
        let suite = "OperationalMetadataHistory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OperationalMetadataHistory-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let base = OperationRecord(
            source: .manual, appName: "App", appBundleIdentifier: "com.test.app",
            appCategory: "docs", action: "proofread", inputMode: "selection",
            inputLength: 10, provider: "provider", model: "model",
            safetyResult: "passed", outcome: "replacedConfirmed"
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any]
        )
        for key in ["appName", "appBundleIdentifier", "appCategory", "action",
                    "inputMode", "provider", "model", "safetyResult", "outcome"] {
            object[key] = hostile
        }
        let legacyData = try JSONSerialization.data(withJSONObject: [object])
        defaults.set(legacyData, forKey: "history")

        let store = OperationHistoryStore(
            defaults: defaults,
            storageKey: "history",
            coordinationDirectoryURL: directory
        )
        let record = try XCTUnwrap(store.records.first)
        assertSafe(try XCTUnwrap(record.appName),
                   maximumScalars: OperationalMetadataSanitizer.appNameMaximumScalars)
        assertSafe(try XCTUnwrap(record.appBundleIdentifier),
                   maximumScalars: OperationalMetadataSanitizer.bundleIdentifierMaximumScalars)
        assertSafe(record.action,
                   maximumScalars: OperationalMetadataSanitizer.operationLabelMaximumScalars)
        assertSafe(try XCTUnwrap(record.model),
                   maximumScalars: OperationalMetadataSanitizer.modelMaximumScalars)
        XCTAssertFalse(record.diagnosticsLine.contains(where: \.isNewline))
        XCTAssertTrue(record.diagnosticsLine.contains("</context>"))

        let persisted = try XCTUnwrap(defaults.data(forKey: "history"))
        XCTAssertNotEqual(persisted, legacyData)
        let persistedRecord = try XCTUnwrap(
            JSONDecoder().decode([OperationRecord].self, from: persisted).first
        )
        XCTAssertEqual(persistedRecord, record)
    }

    @MainActor
    func testLegacyUsageProviderAndModelAreSanitizedAndRewritten() throws {
        let suite = "OperationalMetadataUsage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OperationalMetadataUsage-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let base = DailyUsageBucket(
            day: Date(), source: .manual, provider: "provider", model: "model",
            inputTokens: 1, outputTokens: 2, operationCount: 1,
            estimatedOperationCount: 0
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any]
        )
        object["provider"] = hostile
        object["model"] = hostile
        let legacyData = try JSONSerialization.data(withJSONObject: [object])
        defaults.set(legacyData, forKey: "usage")

        let ledger = UsageLedgerStore(
            defaults: defaults, storageKey: "usage",
            coordinationDirectoryURL: directory
        )
        let bucket = try XCTUnwrap(ledger.buckets.first)
        assertSafe(bucket.provider,
                   maximumScalars: OperationalMetadataSanitizer.providerMaximumScalars)
        assertSafe(bucket.model,
                   maximumScalars: OperationalMetadataSanitizer.modelMaximumScalars)
        XCTAssertEqual(ledger.summary(days: 1).totalTokens, 3)
        XCTAssertNotEqual(defaults.data(forKey: "usage"), legacyData)
    }

    @MainActor
    func testAutomaticAndCrashRecoveryMetadataAreSanitizedBeforeStorageAndRepair() throws {
        let direct = AutomaticCallMetadata(
            source: .passive, appName: hostile, appBundleIdentifier: hostile,
            appCategory: hostile, action: hostile, inputMode: hostile,
            inputLength: 12, provider: hostile, model: hostile
        )
        assertSafe(try XCTUnwrap(direct.appName),
                   maximumScalars: OperationalMetadataSanitizer.appNameMaximumScalars)
        assertSafe(direct.action,
                   maximumScalars: OperationalMetadataSanitizer.operationLabelMaximumScalars)
        assertSafe(direct.provider,
                   maximumScalars: OperationalMetadataSanitizer.providerMaximumScalars)
        assertSafe(direct.model,
                   maximumScalars: OperationalMetadataSanitizer.modelMaximumScalars)

        let suite = "OperationalMetadataCrash.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OperationalMetadataCrash-\(UUID().uuidString)", isDirectory: true)
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(try JSONEncoder().encode([DailyUsageBucket]()), forKey: "usage")
        defaults.set(try JSONEncoder().encode([OperationRecord]()), forKey: "history")

        func lease(id: UUID, startedAt: Date, expiresAt: Date,
                   attemptStartedAt: Date?) -> [String: Any] {
            var value: [String: Any] = [
                "id": id.uuidString,
                "startedAt": startedAt.timeIntervalSinceReferenceDate,
                "expiresAt": expiresAt.timeIntervalSinceReferenceDate,
                "metadata": [
                    "source": "nativeInline",
                    "action": hostile,
                    "inputLength": 12,
                    "provider": hostile,
                    "model": hostile
                ]
            ]
            if let attemptStartedAt {
                value["attemptStartedAt"] = attemptStartedAt.timeIntervalSinceReferenceDate
            }
            return value
        }

        let retainedID = UUID()
        let expiredID = UUID()
        let state: [String: Any] = [
            "version": 3,
            "leases": [
                lease(id: retainedID, startedAt: timestamp,
                      expiresAt: timestamp.addingTimeInterval(600), attemptStartedAt: nil),
                lease(id: expiredID, startedAt: timestamp.addingTimeInterval(-120),
                      expiresAt: timestamp.addingTimeInterval(-60),
                      attemptStartedAt: timestamp.addingTimeInterval(-119))
            ],
            "resolutions": [],
            "spentDays": [[
                "day": calendar.startOfDay(for: timestamp).timeIntervalSinceReferenceDate,
                "count": 1
            ]]
        ]
        let stateURL = directory.appendingPathComponent("automatic-call-reservations.json")
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL, options: .atomic)

        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage", historyStorageKey: "history",
            calendar: calendar, directoryURL: directory, now: { timestamp }
        )
        XCTAssertTrue(store.cleanupStaleReservations())

        let persistedState = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let leases = try XCTUnwrap(persistedState["leases"] as? [[String: Any]])
        let retained = try XCTUnwrap(leases.first)
        let metadata = try XCTUnwrap(retained["metadata"] as? [String: Any])
        XCTAssertEqual((retained["id"] as? String)?.lowercased(), retainedID.uuidString.lowercased())
        assertSafe(try XCTUnwrap(metadata["action"] as? String),
                   maximumScalars: OperationalMetadataSanitizer.operationLabelMaximumScalars)
        assertSafe(try XCTUnwrap(metadata["provider"] as? String),
                   maximumScalars: OperationalMetadataSanitizer.providerMaximumScalars)
        assertSafe(try XCTUnwrap(metadata["model"] as? String),
                   maximumScalars: OperationalMetadataSanitizer.modelMaximumScalars)

        let history = OperationHistoryStore(
            defaults: defaults, storageKey: "history",
            coordinationDirectoryURL: directory
        )
        let repaired = try XCTUnwrap(history.records.first)
        XCTAssertEqual(repaired.id, expiredID)
        XCTAssertEqual(repaired.outcome, "providerAttemptExpired")
        assertSafe(repaired.action,
                   maximumScalars: OperationalMetadataSanitizer.operationLabelMaximumScalars)
        assertSafe(try XCTUnwrap(repaired.model),
                   maximumScalars: OperationalMetadataSanitizer.modelMaximumScalars)
    }

    @MainActor
    func testLegacyFieldInspectionIsSanitizedOnDecodePersistenceAndRendering() throws {
        let assessment = CapabilityAssessment(level: .supported, reason: "safe")
        let base = FieldInspectionReport(
            checkedAt: Date(), appName: "App", bundleIdentifier: "com.test.app",
            appCategory: "docs", referenceSurface: "generic", role: "AXTextArea",
            subrole: nil, fallbackEvidence: nil,
            selectedTextAction: assessment, focusedFieldReplacement: assessment,
            beanBubble: assessment, inlineChecking: assessment
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any]
        )
        for key in ["appName", "bundleIdentifier", "appCategory", "referenceSurface",
                    "role", "subrole", "fallbackEvidence"] {
            object[key] = hostile
        }
        for key in ["selectedTextAction", "focusedFieldReplacement", "beanBubble",
                    "inlineChecking"] {
            var nested = try XCTUnwrap(object[key] as? [String: Any])
            nested["reason"] = hostile
            object[key] = nested
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(FieldInspectionReport.self, from: legacyData)
        assertSafe(decoded.appName,
                   maximumScalars: OperationalMetadataSanitizer.appNameMaximumScalars)
        assertSafe(try XCTUnwrap(decoded.role),
                   maximumScalars: OperationalMetadataSanitizer.fieldMetadataMaximumScalars)
        XCTAssertEqual(decoded.diagnosticsLines.count, 12)
        XCTAssertTrue(decoded.diagnosticsLines.allSatisfy { !$0.contains(where: \.isNewline) })
        XCTAssertTrue(decoded.diagnosticsLines.joined().contains("</context>"))

        let suite = "OperationalMetadataField.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(legacyData, forKey: "field")
        let store = SetupStatusStore(defaults: defaults, storageKey: "field")
        XCTAssertEqual(store.latestFieldInspection, decoded)
        XCTAssertNotEqual(defaults.data(forKey: "field"), legacyData)
    }

    func testAlwaysOnSourceLogUsesOnlyFixedAppCategory() {
        let context = SourceAppContext(
            appName: hostile,
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            processIdentifier: nil,
            focusedRole: nil,
            focusedSubrole: nil,
            acquisitionMode: .selectedText,
            isSearchLikeField: false
        )

        XCTAssertEqual(context.logDescription, "selected text from chat app")
        XCTAssertFalse(context.logDescription.contains("Hostile"))
    }
}
