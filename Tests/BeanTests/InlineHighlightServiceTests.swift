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
        XCTAssertTrue(fixture.editor.presentations.allSatisfy(\.isEmpty))
        XCTAssertEqual(fixture.service.assistantState.phase, .complete)
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

    func testQuietControlCommunicatesTypingAndCheckingWithoutOpeningCorrectionCard() async throws {
        let fixture = try Fixture(text: "Fix teh word.")
        defer { fixture.close() }
        fixture.service.prepare(field: fixture.field(), app: nil)
        XCTAssertEqual(fixture.service.assistantState.phase, .waiting)
        XCTAssertNil(fixture.service.selectedIssueID)
        var reason = ""
        _ = await fixture.run(reason: &reason)
        XCTAssertTrue(fixture.editor.states.contains { $0.phase == .checkingLocal })
        XCTAssertEqual(fixture.service.assistantState.phase, .complete)
        XCTAssertEqual(fixture.service.assistantState.issueCount, 1)
        XCTAssertNil(fixture.service.selectedIssueID, "Missing glyph bounds must not open a card automatically.")
        fixture.service.typingBegan()
        XCTAssertEqual(fixture.service.assistantState.phase, .waiting)
        XCTAssertEqual(fixture.service.assistantState.issueCount, 0)
        XCTAssertNil(fixture.service.selectedIssueID)
    }

    func testPreparedTextCannotBeAcknowledgedAsAnAlreadyAnalyzedEdit() async throws {
        let fixture = try Fixture(text: "Fix teh word.")
        defer { fixture.close() }
        fixture.service.prepare(field: fixture.field(), app: nil)
        XCTAssertFalse(fixture.service.matchesCurrentSession(app: nil, field: fixture.field()))
        var reason = ""
        _ = await fixture.run(reason: &reason)
        XCTAssertTrue(fixture.service.matchesCurrentSession(app: nil, field: fixture.field()))
        fixture.editor.value = "Fix the word."
        fixture.service.prepare(field: fixture.field(), app: nil)
        XCTAssertFalse(fixture.service.matchesCurrentSession(app: nil, field: fixture.field()),
                       "Fix All prepares new text; the dispatcher must schedule its fresh check.")
        _ = await fixture.run(reason: &reason)
        XCTAssertTrue(fixture.service.matchesCurrentSession(app: nil, field: fixture.field()))
        XCTAssertEqual(fixture.editor.checkedTexts.count, 2)
    }

    func testCanonicalUnicodeChangeIsANewRevisionAndRetainsDismissedOccurrence() async throws {
        let fixture = try Fixture(text: "Café teh word.")
        defer { fixture.close() }
        var reason = ""
        _ = await fixture.run(reason: &reason)
        let first = try XCTUnwrap(fixture.editor.presentations.last?.first)
        fixture.service.dismissIssue(first.id)
        fixture.editor.value = "Cafe\u{301} teh word."
        _ = await fixture.run(reason: &reason)
        XCTAssertEqual(fixture.editor.checkedTexts.count, 2)
        XCTAssertEqual(fixture.service.assistantState.issueCount, 0)
    }

    func testIncompleteLocalCoverageStaysTruthfulOnCacheHits() async throws {
        for coverage in [IssueDetector.LocalCoverage.limitReached, .unavailable, .invalidResponse] {
            let fixture = try Fixture(text: "The sentence is correct.")
            defer { fixture.close() }
            fixture.editor.localCoverage = coverage
            var reason = ""
            _ = await fixture.run(reason: &reason)
            XCTAssertEqual(fixture.service.assistantState.localLimitation, coverage.rawValue)
            XCTAssertEqual(fixture.service.assistantState.title, "No suggestions in checked text")
            _ = await fixture.run(reason: &reason)
            XCTAssertEqual(fixture.editor.checkedTexts.count, 1)
            XCTAssertEqual(fixture.service.assistantState.localLimitation, coverage.rawValue)
        }
    }

    func testDismissalSurvivesUnrelatedTypingAndDoesNotHideAnotherOccurrence() async throws {
        let fixture = try Fixture(text: "Fix teh and teh words.")
        defer { fixture.close() }
        var reason = ""
        _ = await fixture.run(reason: &reason)
        let first = try XCTUnwrap(fixture.editor.presentations.last?.first)
        fixture.service.dismissIssue(first.id)
        XCTAssertEqual(fixture.service.assistantState.issueCount, 1)
        fixture.editor.value = "👩🏽‍💻 Fix teh and teh words. Thanks."
        _ = await fixture.run(reason: &reason)
        let remaining = try XCTUnwrap(fixture.editor.presentations.last)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.range.location,
                       (fixture.editor.value as NSString).range(of: "teh", options: .backwards).location)
        fixture.editor.value = fixture.editor.value.replacingOccurrences(of: "Fix teh", with: "Fix tehh")
        _ = await fixture.run(reason: &reason)
        XCTAssertEqual(fixture.editor.presentations.last?.filter { $0.original == "teh" }.count, 1)
    }

    func testLearningSpellingPersistsDictionaryAndRemovesMatchingOccurrences() async throws {
        let fixture = try Fixture(text: "We use teh and teh labels.")
        defer { fixture.close() }
        var reason = ""
        _ = await fixture.run(reason: &reason)
        let first = try XCTUnwrap(fixture.editor.presentations.last?.first)
        fixture.service.learnWord(first.id)
        XCTAssertEqual(fixture.service.assistantState.issueCount, 0)
        XCTAssertEqual(fixture.service.assistantState.phase, .complete)
        XCTAssertEqual(fixture.content.dictionary.map(\.term), ["teh"])
        let reopened = UserContentStore(fileURL: fixture.directory.appendingPathComponent("userContent.json"))
        XCTAssertEqual(reopened.dictionary.map(\.term), ["teh"])
        fixture.editor.value += " We also use teh later."
        await assertRun(fixture, shows: false, reason: &reason)
        XCTAssertEqual(reason, "noIssues")
    }

    func testFixAllRequiresCurrentHighConfidenceLocalIssuesAndWritableNumericRange() async throws {
        let fixture = try Fixture(text: "Fix teh  sentence.")
        defer { fixture.close() }
        var reason = ""
        _ = await fixture.run(reason: &reason)
        XCTAssertEqual(fixture.service.assistantState.safeFixCount, 2)
        fixture.editor.canEditRanges = false
        _ = await fixture.run(reason: &reason)
        XCTAssertEqual(fixture.service.assistantState.safeFixCount, 0)
        fixture.editor.canEditRanges = true
        fixture.editor.value += " New text."
        fixture.service.prepare(field: fixture.field(), app: nil)
        XCTAssertEqual(fixture.service.assistantState.safeFixCount, 0,
                       "A prepared revision cannot offer edits from the previous analysis.")
    }

    func testUnreadableAndOversizedFieldsReportUnavailableRatherThanClean() async throws {
        let fixture = try Fixture(text: "")
        defer { fixture.close() }
        var reason = ""
        let unreadable = AccessibilityService.FocusedField(element: fixture.element, role: "AXTextArea", subrole: nil,
            value: nil, title: nil, placeholder: nil, isValueSettable: false, isSelectedTextSettable: false,
            isEnabled: true, hasEditableAncestor: false, isExplicitlyEditable: true, isSelectedRangeSettable: true)
        let shown = await fixture.service.run(field: unreadable, app: nil, context: fixture.context,
                                             isCurrent: { true }, reason: &reason)
        XCTAssertFalse(shown)
        XCTAssertEqual(fixture.service.assistantState.phase, .unavailable("cannotReadText"))
        fixture.editor.value = String(repeating: "a", count: 50_001)
        await assertRun(fixture, shows: false, reason: &reason)
        XCTAssertEqual(fixture.service.assistantState.phase, .unavailable("textTooLong"))
        XCTAssertTrue(fixture.editor.checkedTexts.isEmpty)
    }

    func testPausedAppDoesNotCheckOrPublishAFalseCleanResult() async throws {
        let fixture = try Fixture(text: "Fix teh word.")
        defer { fixture.close() }
        fixture.settings.pauseAssistance(in: "com.bean.synthetic-editor")
        var context = fixture.context
        context.bundleIdentifier = "com.bean.synthetic-editor"
        var reason = ""
        let shown = await fixture.service.run(field: fixture.field(), app: nil, context: context,
                                             isCurrent: { true }, reason: &reason)
        XCTAssertFalse(shown)
        XCTAssertEqual(reason, "appPaused")
        XCTAssertTrue(fixture.editor.checkedTexts.isEmpty)
        XCTAssertTrue(fixture.editor.states.isEmpty)
    }

    func testParagraphChoiceRequiresProvenCollapsedWritableCaret() async throws {
        let fixture = try Fixture(text: "First paragraph.\nFix teh word.", hasParagraphAction: true)
        defer { fixture.close() }
        var reason = ""
        _ = await fixture.run(reason: &reason)
        XCTAssertFalse(fixture.service.assistantState.canChooseParagraph,
                       "Text-marker-only editors cannot prove a numeric paragraph destination.")
        fixture.editor.selectedRange = NSRange(location: 20, length: 0)
        _ = await fixture.run(reason: &reason)
        XCTAssertTrue(fixture.service.assistantState.canChooseParagraph)
        fixture.editor.selectedRange = NSRange(location: 20, length: 3)
        _ = await fixture.run(reason: &reason)
        XCTAssertFalse(fixture.service.assistantState.canChooseParagraph)
        fixture.editor.selectedRange = NSRange(location: 20, length: 0)
        fixture.editor.canEditRanges = false
        _ = await fixture.run(reason: &reason)
        XCTAssertFalse(fixture.service.assistantState.canChooseParagraph)
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
        var states: [NativeAssistantState] = []
        var canEditRanges = true
        var selectedRange: NSRange?
        var localCoverage: IssueDetector.LocalCoverage = .complete

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
        let settings: AppSettings
        let content: UserContentStore
        // An opaque identity only: every OS read and presentation is injected.
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)

        init(text: String, hasParagraphAction: Bool = false) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let editor = MemoryEditor(text: text)
            self.editor = editor
            let settings = AppSettings(defaults: defaults, readKeychain: { _ in
                XCTFail("Offline live checking must not read a provider key.")
                return nil
            })
            self.settings = settings
            let content = UserContentStore(fileURL: directory.appendingPathComponent("userContent.json"))
            self.content = content
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
                localAnalysis: { text, dictionary, maximumIssues, dialect in
                    editor.checkedTexts.append(text)
                    var detector = IssueDetector()
                    detector.maxIssues = maximumIssues
                    let result = detector.localAnalysis(in: text, dictionary: dictionary, includeSpellChecker: false, dialect: dialect)
                    return IssueDetector.LocalAnalysis(issues: result.issues,
                        spellingCoverage: editor.localCoverage, grammarCoverage: editor.localCoverage)
                },
                present: { editor.presentations.append($0.map(\.issue)) },
                selectedRange: { _ in editor.selectedRange }, anchor: { _ in nil },
                presentState: { editor.states.append($0) }, canEditRanges: { _ in editor.canEditRanges }
            )
            service = InlineHighlightService(
                settings: settings,
                userContent: content,
                history: OperationHistoryStore(defaults: defaults, coordinationDirectoryURL: directory),
                usageLedger: UsageLedgerStore(defaults: defaults, coordinationDirectoryURL: directory),
                automaticCallBudget: AutomaticCallBudgetStore(defaults: defaults, directoryURL: directory),
                undoStore: ReplacementUndoStore(), statusHUD: StatusHUD(),
                runAction: { _ in XCTFail("Checking must not launch a writing action.") },
                runParagraphAction: hasParagraphAction ? { _ in XCTFail("Checking must not launch a paragraph action.") } : nil,
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
