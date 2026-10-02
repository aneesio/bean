import AppKit
import ApplicationServices
import XCTest
@testable import Bean

@MainActor
final class InlineHighlightServiceTests: XCTestCase {
    func testFirstFocusedDraftRunsLocalDetectionAndPresentsActualIssues() async throws {
        let fixture = try Fixture(text: "Please fix teh  sentence.")
        defer { fixture.close() }
        var reason = ""

        let shown = await fixture.run(reason: &reason)

        XCTAssertTrue(shown)
        XCTAssertEqual(reason, "shown")
        XCTAssertEqual(fixture.editor.checkedTexts, [fixture.editor.value])
        let presented = try XCTUnwrap(fixture.editor.presentations.last)
        XCTAssertEqual(Set(presented.map(\.original)), ["teh", "  "])
        for issue in presented {
            XCTAssertEqual((fixture.editor.value as NSString).substring(with: issue.range), issue.original)
        }
    }

    func testChangedTextIsCheckedAndUnchangedSnapshotReusesItsIssueIdentity() async throws {
        let fixture = try Fixture(text: "Fix teh word.")
        defer { fixture.close() }
        var reason = ""
        _ = await fixture.run(reason: &reason)
        let firstIDs = try XCTUnwrap(fixture.editor.presentations.last).map(\.id)

        await assertRun(fixture, shows: true, reason: &reason)
        XCTAssertEqual(fixture.editor.checkedTexts, ["Fix teh word."])
        XCTAssertEqual(fixture.editor.presentations.last?.map(\.id), firstIDs,
                       "A cache hit must restore existing issues without invoking the detector again.")

        fixture.editor.value = "👩🏽‍💻 Please recieve teh draft."
        await assertRun(fixture, shows: true, reason: &reason)
        XCTAssertEqual(fixture.editor.checkedTexts, ["Fix teh word.", fixture.editor.value])
        let revised = try XCTUnwrap(fixture.editor.presentations.last)
        XCTAssertEqual(Set(revised.map(\.original)), ["recieve", "teh"])
        XCTAssertTrue(Set(revised.map(\.id)).isDisjoint(with: firstIDs))
        for issue in revised {
            XCTAssertEqual((fixture.editor.value as NSString).substring(with: issue.range), issue.original)
        }

        let revisedIDs = revised.map(\.id)
        await assertRun(fixture, shows: true, reason: &reason)
        XCTAssertEqual(fixture.editor.checkedTexts.count, 2)
        XCTAssertEqual(fixture.editor.presentations.last?.map(\.id), revisedIDs)
    }

    func testCleanDraftCachesCompletedCheckAndChangedTextStillGetsChecked() async throws {
        let fixture = try Fixture(text: "The sentence is correct.")
        defer { fixture.close() }
        var reason = ""

        await assertRun(fixture, shows: false, reason: &reason)
        XCTAssertEqual(reason, "noIssues")
        XCTAssertEqual(fixture.editor.checkedTexts, [fixture.editor.value])
        XCTAssertTrue(fixture.editor.presentations.isEmpty)
        await assertRun(fixture, shows: false, reason: &reason)
        XCTAssertEqual(reason, "noIssues")
        XCTAssertEqual(fixture.editor.checkedTexts.count, 1)

        fixture.editor.value = "The sentence has teh typo."
        await assertRun(fixture, shows: true, reason: &reason)
        XCTAssertEqual(fixture.editor.checkedTexts.count, 2)
        XCTAssertEqual(fixture.editor.presentations.last?.map(\.original), ["teh"])
    }

    func testCacheHitDoesNotPresentWhenDispatchIsNoLongerCurrent() async throws {
        let fixture = try Fixture(text: "Fix teh word.")
        defer { fixture.close() }
        var reason = ""
        _ = await fixture.run(reason: &reason)
        let presentationCount = fixture.editor.presentations.count

        let shown = await fixture.run(isCurrent: { false }, reason: &reason)

        XCTAssertFalse(shown)
        XCTAssertEqual(reason, "staleDiscarded")
        XCTAssertEqual(fixture.editor.presentations.count, presentationCount)
        XCTAssertEqual(fixture.editor.checkedTexts.count, 1)
    }

    func testCacheHitChecksLiveValueBeforeRestoringSuggestions() async throws {
        let fixture = try Fixture(text: "Fix teh word.")
        defer { fixture.close() }
        var reason = ""
        _ = await fixture.run(reason: &reason)
        let capturedField = fixture.field()
        let presentationCount = fixture.editor.presentations.count
        fixture.editor.value = "The user has already changed this draft."

        let shown = await fixture.service.run(field: capturedField, app: nil,
            context: fixture.context, isCurrent: { true }, reason: &reason)

        XCTAssertFalse(shown)
        XCTAssertEqual(reason, "staleDiscarded")
        XCTAssertEqual(fixture.editor.presentations.count, presentationCount)
        XCTAssertEqual(fixture.editor.checkedTexts.count, 1)
    }

    private func assertRun(_ fixture: Fixture, shows expected: Bool, reason: inout String,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let shown = await fixture.run(reason: &reason)
        XCTAssertEqual(shown, expected, file: file, line: line)
    }

    @MainActor
    private final class MemoryEditor {
        var value: String
        var checkedTexts: [String] = []
        var presentations: [[TextIssue]] = []

        init(text: String) { value = text }
    }

    @MainActor
    private final class Fixture {
        let suite = "InlineHighlightServiceTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InlineHighlightServiceTests-\(UUID().uuidString)")
        let defaults: UserDefaults
        let editor: MemoryEditor
        let service: InlineHighlightService
        // An opaque identity only: every OS read and presentation is injected.
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)

        init(text: String) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let editor = MemoryEditor(text: text)
            self.editor = editor
            let settings = AppSettings(defaults: defaults, readKeychain: { _ in
                XCTFail("Offline live checking must not read a provider key.")
                return nil
            })
            settings.inlineLocalOnly = true
            settings.inlineIncludeLLM = false
            let dependencies = InlineHighlightService.AnalysisDependencies(
                value: { _ in editor.value },
                rangeText: { _, range in
                    let value = editor.value as NSString
                    guard range.location >= 0, range.location <= value.length,
                          range.length >= 0, range.length <= value.length - range.location else { return nil }
                    return value.substring(with: range)
                },
                rangeRect: { _, _ in nil },
                localIssues: { text, dictionary, maximumIssues in
                    editor.checkedTexts.append(text)
                    var detector = IssueDetector()
                    detector.maxIssues = maximumIssues
                    return detector.localIssues(in: text, dictionary: dictionary, includeSpellChecker: false)
                },
                present: { editor.presentations.append($0.map(\.issue)) }
            )
            service = InlineHighlightService(
                settings: settings,
                userContent: UserContentStore(fileURL: directory.appendingPathComponent("userContent.json")),
                history: OperationHistoryStore(defaults: defaults, coordinationDirectoryURL: directory),
                usageLedger: UsageLedgerStore(defaults: defaults, coordinationDirectoryURL: directory),
                automaticCallBudget: AutomaticCallBudgetStore(defaults: defaults, directoryURL: directory),
                undoStore: ReplacementUndoStore(), statusHUD: StatusHUD(),
                runAction: { _ in XCTFail("Checking must not launch a writing action.") },
                analysisDependencies: dependencies
            )
        }

        var context: SourceAppContext {
            SourceAppContext.current(app: nil, field: field(), mode: .focusedFieldFullText)
        }

        func field() -> AccessibilityService.FocusedField {
            .init(element: element, role: "AXTextArea", subrole: nil, value: editor.value,
                  title: nil, placeholder: nil, isValueSettable: false,
                  isSelectedTextSettable: false, isEnabled: true,
                  hasEditableAncestor: false, isExplicitlyEditable: true,
                  isSelectedRangeSettable: true)
        }

        func run(isCurrent: @escaping () -> Bool = { true }, reason: inout String) async -> Bool {
            await service.run(field: field(), app: nil, context: context,
                              isCurrent: isCurrent, reason: &reason)
        }

        func close() {
            service.hideUI()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
