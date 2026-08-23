import Foundation
import XCTest
@testable import Bean

final class PersonalizationUIModelTests: XCTestCase {
    func testEveryStyleScaleHasPlainLanguageLabelsForOneThroughFive() {
        XCTAssertEqual(labels(for: .formality), [
            "Very casual", "Casual", "Balanced", "Formal", "Very formal"
        ])
        XCTAssertEqual(labels(for: .warmth), [
            "Reserved", "Matter-of-fact", "Balanced", "Warm", "Very warm"
        ])
        XCTAssertEqual(labels(for: .conciseness), [
            "Detailed", "Explanatory", "Balanced", "Concise", "Very concise"
        ])
        XCTAssertEqual(labels(for: .directness), [
            "Gentle", "Diplomatic", "Balanced", "Direct", "Very direct"
        ])
    }

    func testStyleLabelsClampUnexpectedPersistedValues() {
        XCTAssertEqual(
            StyleProfileUIModel.qualitativeLabel(for: .formality, value: -10),
            "Very casual"
        )
        XCTAssertEqual(
            StyleProfileUIModel.qualitativeLabel(for: .formality, value: 99),
            "Very formal"
        )
    }

    func testLivePreviewRespondsToEveryStyleDimension() {
        let balanced = StyleProfile(name: "Balanced")
        let baseline = StyleProfileUIModel.previewText(for: balanced)

        var formal = balanced
        formal.formality = 5
        XCTAssertNotEqual(StyleProfileUIModel.previewText(for: formal), baseline)

        var warm = balanced
        warm.warmth = 5
        XCTAssertNotEqual(StyleProfileUIModel.previewText(for: warm), baseline)

        var concise = balanced
        concise.conciseness = 5
        XCTAssertNotEqual(StyleProfileUIModel.previewText(for: concise), baseline)

        var direct = balanced
        direct.directness = 5
        XCTAssertNotEqual(StyleProfileUIModel.previewText(for: direct), baseline)
    }

    func testStyleSummaryNamesAllFourCurrentQualities() {
        let profile = StyleProfile(
            name: "Custom",
            formality: 1,
            warmth: 2,
            conciseness: 4,
            directness: 5
        )

        XCTAssertEqual(
            StyleProfileUIModel.summary(for: profile),
            "Very casual · Matter-of-fact · Concise · Very direct"
        )
    }

    func testPreferencesImportSummaryUsesReadableCounts() {
        let preview = PreferencesImportPreview(
            profileCount: 1,
            writingContextCount: 2,
            dictionaryCount: 3,
            appRuleCount: 1,
            repairedProfileReferenceCount: 0,
            skippedDictionaryDuplicateCount: 0,
            generalDefaultName: "Default"
        )

        XCTAssertEqual(
            PreferencesImportUIModel.summary(for: preview),
            "1 style · 2 Writing Context items · 3 dictionary terms · 1 app default"
        )
        XCTAssertTrue(PreferencesImportUIModel.notices(for: preview).isEmpty)
    }

    func testPreferencesImportNoticesDiscloseEveryRepair() {
        let preview = PreferencesImportPreview(
            profileCount: 5,
            writingContextCount: 1,
            dictionaryCount: 8,
            appRuleCount: 4,
            repairedProfileReferenceCount: 1,
            skippedDictionaryDuplicateCount: 2,
            generalDefaultName: "Professional"
        )

        XCTAssertEqual(PreferencesImportUIModel.notices(for: preview), [
            "Bean will repair 1 outdated or missing profile reference.",
            "Bean will skip 2 duplicate dictionary terms."
        ])
    }

    func testPreferencesImportFailureCopyNeverOverstatesRollback() {
        XCTAssertEqual(
            PreferencesImportUIModel.failureMessage(for: UserContentStoreError.unableToSave),
            "Bean couldn't save the imported preferences. Your existing preferences are unchanged."
        )

        let rollbackFailure = PreferencesImportUIModel.failureMessage(
            for: UserContentStoreError.unableToRollbackImport
        )
        XCTAssertTrue(rollbackFailure.contains("restore the safety backup"))
        XCTAssertFalse(rollbackFailure.localizedCaseInsensitiveContains("unchanged"))

        XCTAssertEqual(
            PreferencesImportUIModel.failureMessage(for: UserContentStoreError.unreadableBackup),
            "Bean couldn't read this backup file. Your current preferences are unchanged."
        )
    }

    func testPreferencesImportFileReadIsBoundedBeforePreview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BeanPreferencesImportUI-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let ordinary = directory.appendingPathComponent("ordinary.json")
        let ordinaryData = Data(#"{"version":1}"#.utf8)
        try ordinaryData.write(to: ordinary)
        XCTAssertEqual(
            try PreferencesImportUIModel.boundedBackupData(at: ordinary),
            ordinaryData
        )

        let oversized = directory.appendingPathComponent("oversized.json")
        try Data(
            repeating: 0x20,
            count: UserContentFileLimits.maximumEncodedBytes + 1
        ).write(to: oversized)
        XCTAssertThrowsError(
            try PreferencesImportUIModel.boundedBackupData(at: oversized)
        ) {
            XCTAssertEqual($0 as? UserContentStoreError, .unreadableBackup)
        }
    }

    func testPreferencesImportRejectsUntrustedEntriesBeforePreviewStage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BeanPreferencesImportBoundary-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("target.json")
        try Data(#"{"version":1}"#.utf8).write(to: target)

        let symbolicLink = directory.appendingPathComponent("symbolic-link.json")
        try FileManager.default.createSymbolicLink(
            at: symbolicLink, withDestinationURL: target
        )

        let selectedDirectory = directory.appendingPathComponent(
            "directory.json", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: selectedDirectory, withIntermediateDirectories: false
        )

        let hardLinkSource = directory.appendingPathComponent("hard-link-source.json")
        try Data(#"{"version":1}"#.utf8).write(to: hardLinkSource)
        let hardLink = directory.appendingPathComponent("hard-link.json")
        try FileManager.default.linkItem(at: hardLinkSource, to: hardLink)

        let sparseOversized = directory.appendingPathComponent("sparse-oversized.json")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: sparseOversized.path,
            contents: Data()
        ))
        let handle = try FileHandle(forWritingTo: sparseOversized)
        try handle.truncate(
            atOffset: UInt64(UserContentFileLimits.maximumEncodedBytes + 1)
        )
        try handle.close()

        for invalidURL in [symbolicLink, selectedDirectory, hardLink, sparseOversized] {
            var previewCalls = 0
            XCTAssertThrowsError(
                try PreferencesImportUIModel.prepareCandidate(at: invalidURL) { _ in
                    previewCalls += 1
                    return PreferencesImportPreview(
                        profileCount: 0,
                        writingContextCount: 0,
                        dictionaryCount: 0,
                        appRuleCount: 0,
                        repairedProfileReferenceCount: 0,
                        skippedDictionaryDuplicateCount: 0,
                        generalDefaultName: "Default"
                    )
                },
                "Expected \(invalidURL.lastPathComponent) to be rejected"
            ) {
                XCTAssertEqual($0 as? UserContentStoreError, .unreadableBackup)
            }
            XCTAssertEqual(
                previewCalls, 0,
                "An untrusted entry must be rejected before preview or mutation work"
            )
        }
    }

    func testPersonalizationFeedbackHasExplicitVoiceOverMeaning() {
        XCTAssertEqual(
            PersonalizationActionFeedback(
                message: "Built-in profiles restored.",
                isError: false
            ).accessibilityLabel,
            "Success: Built-in profiles restored."
        )
        XCTAssertEqual(
            PersonalizationActionFeedback(
                message: "The previous selection is still in use.",
                isError: true
            ).accessibilityLabel,
            "Error: The previous selection is still in use."
        )
    }

    func testPersistenceFailureUsesConcreteStoreDetailAndSafeFallback() {
        XCTAssertEqual(
            PersonalizationActionUIModel.persistenceFailure(
                fallback: "Fallback",
                storeError: "  Disk is read-only.  "
            ),
            "Disk is read-only."
        )
        XCTAssertEqual(
            PersonalizationActionUIModel.persistenceFailure(
                fallback: "Nothing changed.",
                storeError: "  \n  "
            ),
            "Nothing changed."
        )
    }

    func testEveryPersonalizationSheetHasFlexibleOrderedDimensions() {
        XCTAssertEqual(PersonalizationSheetLayout.all.count, 5)
        for metrics in PersonalizationSheetLayout.all {
            XCTAssertGreaterThan(metrics.minWidth, 0)
            XCTAssertLessThanOrEqual(metrics.minWidth, metrics.idealWidth)
            XCTAssertLessThanOrEqual(metrics.idealWidth, metrics.maxWidth)
            XCTAssertGreaterThan(metrics.minHeight, 0)
            XCTAssertLessThanOrEqual(metrics.minHeight, metrics.idealHeight)
            XCTAssertLessThanOrEqual(metrics.idealHeight, metrics.maxHeight)
        }
    }

    func testPersonalizationSurfaceKeepsSafetyAndProductLanguageWired() throws {
        let source = try String(contentsOf: styleDataSettingsURL, encoding: .utf8)

        XCTAssertTrue(source.contains("struct WritingContextSection"))
        XCTAssertFalse(source.contains("ContextCardsSection"))
        XCTAssertFalse(source.contains("store.cards"))
        XCTAssertFalse(source.contains("deleteCard"))
        XCTAssertFalse(source.contains("Tags (comma-separated)"))
        XCTAssertTrue(source.contains("Use General Default"))
        XCTAssertTrue(source.contains("setDefaultProfile(profile.id)"))
        XCTAssertFalse(source.contains("store.defaultProfileID = profile.id"))
        XCTAssertTrue(source.contains("Reset Built-ins…"))
        XCTAssertTrue(source.contains("Delete Profile"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "PersonalizationPersistenceStatus(store: store)").count - 1,
            4
        )
        XCTAssertTrue(source.contains("Note (optional)"))
        XCTAssertTrue(source.contains("Case-sensitive"))
        XCTAssertTrue(source.contains("Review Dictionary Import"))
        XCTAssertTrue(source.contains("report.persistenceSucceeded"))
        XCTAssertTrue(source.contains("Review Preferences Import"))
        XCTAssertTrue(source.contains("previewBackupImport(data:"))
        XCTAssertTrue(source.contains("store.importBackup(data:"))
        XCTAssertTrue(source.contains("try data.write(to:"))
        XCTAssertFalse(source.contains("try? data.write(to:"))
    }

    func testPersonalizationMutationsAndSheetsKeepFailureUXWired() throws {
        let source = try String(contentsOf: styleDataSettingsURL, encoding: .utf8)

        XCTAssertFalse(source.contains("_ = store."),
                       "Transactional results must never be explicitly discarded")
        XCTAssertTrue(source.contains("let succeeded = store.deleteProfile"))
        XCTAssertTrue(source.contains("let succeeded = store.deleteWritingContext"))
        XCTAssertTrue(source.contains("if store.setAppRuleStyle"))
        XCTAssertTrue(source.contains("guard report.persistenceSucceeded else"))
        XCTAssertTrue(source.contains("Your changes remain in this editor"))
        XCTAssertFalse(source.contains("Review the storage warning"))
        XCTAssertTrue(source.contains(".announcementRequested"))

        XCTAssertEqual(
            source.components(separatedBy: ".keyboardShortcut(.cancelAction)").count - 1,
            6
        )
        XCTAssertEqual(
            source.components(separatedBy: ".personalizationSheetFrame(").count - 1,
            5,
            "Every personalization sheet must stay adaptive"
        )
        XCTAssertFalse(source.contains(".frame(width: 500, height: 700)"))
        XCTAssertTrue(source.contains("A descriptive name for this writing style"))
        XCTAssertFalse(source.contains("A unique name for this writing style"))
    }

    private func labels(for dimension: StyleDimension) -> [String] {
        (1...5).map { StyleProfileUIModel.qualitativeLabel(for: dimension, value: $0) }
    }

    private var styleDataSettingsURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Bean/UI/StyleDataSettings.swift")
    }
}
