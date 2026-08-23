import XCTest
@testable import Bean

@MainActor
final class DiagnosticsPrivacyTests: XCTestCase {
    func testSummaryUsesCurrentNamesAndNeverEmitsPersonalizationOrFullPaths() throws {
        let suite = "DiagnosticsPrivacyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        let contentURL = directory.appendingPathComponent("userContent.json")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let settings = AppSettings(defaults: defaults)
        settings.model = "PRIVATE CUSTOM MODEL LABEL"
        settings.inlineHighlightsEnabled = true
        settings.inlineLocalOnly = false
        settings.inlineIncludeLLM = true
        settings.lastPauseHandler = "inline\nFORGED-HANDLER\u{202E}" + String(repeating: "H", count: 200)
        settings.lastSupportReason = "reason\tFORGED-REASON\u{2066}" + String(repeating: "R", count: 200)
        let store = UserContentStore(fileURL: contentURL)
        let privateProfile = StyleProfile(
            name: "PRIVATE STYLE NAME",
            detail: "PRIVATE STYLE DETAIL",
            preferredInstructions: "PRIVATE STYLE INSTRUCTIONS"
        )
        XCTAssertTrue(store.upsert(privateProfile))
        XCTAssertTrue(store.setDefaultProfile(privateProfile.id))
        XCTAssertTrue(store.upsert(WritingContext(
            title: "PRIVATE CONTEXT TITLE",
            content: "PRIVATE CONTEXT BODY",
            isEnabledByDefault: true
        )))
        XCTAssertTrue(store.upsert(DictionaryTerm(term: "PRIVATE-DICTIONARY-TERM")).succeeded)

        let history = OperationHistoryStore(
            defaults: defaults, storageKey: "history",
            coordinationDirectoryURL: directory
        )
        let usage = UsageLedgerStore(
            defaults: defaults, storageKey: "usage",
            coordinationDirectoryURL: directory
        )
        let setup = SetupStatusStore(defaults: defaults, storageKey: "field")
        let summary = Diagnostics(
            settings: settings, store: store, history: history,
            usageLedger: usage, setupStatus: setup
        ).summaryText

        for privateValue in [
            "PRIVATE STYLE NAME", "PRIVATE STYLE DETAIL", "PRIVATE STYLE INSTRUCTIONS",
            "PRIVATE CONTEXT TITLE", "PRIVATE CONTEXT BODY", "PRIVATE-DICTIONARY-TERM",
            "PRIVATE CUSTOM MODEL LABEL", directory.path
        ] {
            XCTAssertFalse(summary.contains(privateValue), privateValue)
        }
        XCTAssertTrue(summary.contains("activeStyle: custom"))
        XCTAssertTrue(summary.contains("model: custom"))
        XCTAssertTrue(summary.contains("writingContextItems: 1 (enabled: 1)"))
        XCTAssertTrue(summary.contains("liveSuggestionsEnabled: yes"))
        XCTAssertTrue(summary.contains("deeperAISuggestionsEnabled: yes"))
        XCTAssertFalse(summary.contains("appPath:"))
        XCTAssertFalse(summary.contains("nativeHostBinary:"))
        XCTAssertFalse(summary.contains("contextCards:"))
        XCTAssertFalse(summary.contains("passiveEnabled:"))
        XCTAssertFalse(summary.contains("passiveDelay:"))
        XCTAssertFalse(summary.components(separatedBy: "\n").contains("FORGED-HANDLER"))
        XCTAssertFalse(summary.components(separatedBy: "\n").contains("FORGED-REASON"))
        let handlerLine = try XCTUnwrap(
            summary.components(separatedBy: "\n").first { $0.hasPrefix("lastPauseHandler: ") }
        )
        let reasonLine = try XCTUnwrap(
            summary.components(separatedBy: "\n").first { $0.hasPrefix("lastReasonCode: ") }
        )
        XCTAssertLessThanOrEqual(
            handlerLine.dropFirst("lastPauseHandler: ".count).unicodeScalars.count,
            OperationalMetadataSanitizer.operationLabelMaximumScalars
        )
        XCTAssertLessThanOrEqual(
            reasonLine.dropFirst("lastReasonCode: ".count).unicodeScalars.count,
            OperationalMetadataSanitizer.operationLabelMaximumScalars
        )
        XCTAssertFalse(handlerLine.unicodeScalars.contains { $0.properties.generalCategory == .format })
        XCTAssertFalse(reasonLine.unicodeScalars.contains { $0.properties.generalCategory == .format })
    }
}
