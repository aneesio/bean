import Foundation
import XCTest
@testable import Bean

@MainActor
final class WritingWorkspaceTests: XCTestCase {
    func testRepeatedTyposRemainReviewableOneAtATime() throws {
        let model = WritingWorkspaceModel()
        model.load("teh cat and teh dog", name: "Draft", saved: true)
        XCTAssertEqual(model.issues.filter { $0.original == "teh" }.count, 2)
        let first = try XCTUnwrap(model.issues.first { $0.original == "teh" })
        model.accept(first)
        XCTAssertEqual(model.text, "the cat and teh dog")
        XCTAssertEqual(model.issues.filter { $0.original == "teh" }.count, 1)
        model.accept(try XCTUnwrap(model.issues.first { $0.original == "teh" }))
        XCTAssertEqual(model.text, "the cat and the dog")
        model.undoSuggestion()
        XCTAssertEqual(model.text, "the cat and teh dog")
        model.undoSuggestion()
        XCTAssertEqual(model.text, "teh cat and teh dog")
    }

    func testDismissingAnOccurrenceDoesNotDismissRepeatedWordElsewhere() throws {
        let model = WritingWorkspaceModel()
        model.load("teh cat and teh dog", name: "Draft", saved: true)
        model.dismiss(try XCTUnwrap(model.issues.first { $0.original == "teh" }))
        model.checkLocally()
        XCTAssertEqual(model.issues.filter { $0.original == "teh" }.count, 1)
        model.restoreDismissed()
        XCTAssertEqual(model.issues.filter { $0.original == "teh" }.count, 2)
    }

    func testStaleSuggestionCannotOverwriteTyping() throws {
        let model = WritingWorkspaceModel()
        model.load("teh cat", name: "Draft", saved: true)
        let issue = try XCTUnwrap(model.issues.first { $0.original == "teh" })
        model.edit("a new draft")
        model.accept(issue)
        XCTAssertEqual(model.text, "a new draft")
        XCTAssertFalse(model.canUndoSuggestion)
    }

    func testDismissalFollowsItsOccurrenceWhenEarlierTextChanges() throws {
        let model = WritingWorkspaceModel()
        model.load("teh cat and teh dog", name: "Draft", saved: true)
        let last = try XCTUnwrap(model.issues.last { $0.original == "teh" })
        model.dismiss(last)
        model.edit("🙂 " + model.text)
        model.checkLocally()
        XCTAssertEqual(model.issues.filter { $0.original == "teh" }.count, 1)
        model.accept(try XCTUnwrap(model.issues.first { $0.original == "teh" }))
        XCTAssertFalse(model.issues.contains { $0.original == "teh" })
        XCTAssertEqual(model.text, "🙂 the cat and teh dog")
    }

    func testAIReviewRejectsResultAfterEditEvenWhenTextReturnsToOriginal() throws {
        let model = WritingWorkspaceModel()
        model.load("The team are ready.", name: "Draft", saved: true)
        let request = try XCTUnwrap(model.beginReview())
        model.edit("The team is ready.")
        model.edit(request.text)
        model.completeReview(request, issues: [issue(original: "are", suggestion: "is", location: 9)], failure: nil)
        XCTAssertFalse(model.hasAIReview)
        XCTAssertFalse(model.isChecking)
        XCTAssertTrue(model.notice?.contains("changed") == true)
    }

    func testCancelledResultCannotFinishANewerRequest() throws {
        let model = WritingWorkspaceModel()
        model.load("My draft", name: "Draft", saved: true)
        let oldRequest = try XCTUnwrap(model.beginReview())
        model.cancelReview()
        let newRequest = try XCTUnwrap(model.beginReview())
        model.completeReview(oldRequest, issues: [], failure: nil)
        XCTAssertTrue(model.isChecking)
        XCTAssertFalse(model.hasAIReview)
        model.completeReview(newRequest, issues: [], failure: nil)
        XCTAssertFalse(model.isChecking)
        XCTAssertTrue(model.hasAIReview)
    }

    func testAIReviewFailurePreservesLocalSuggestions() throws {
        let model = WritingWorkspaceModel()
        model.load("teh cat", name: "Draft", saved: true)
        let request = try XCTUnwrap(model.beginReview())
        model.completeReview(request, issues: [], failure: "requestTimedOut")
        XCTAssertTrue(model.issues.contains { $0.original == "teh" })
        XCTAssertFalse(model.hasAIReview)
        XCTAssertTrue(model.notice?.contains("timed out") == true)
    }

    func testAcceptShiftsRemainingAISuggestionsUsingUTF16Lengths() throws {
        let model = WritingWorkspaceModel()
        model.load("🙂 A big cat are nice.", name: "Draft", saved: true)
        let request = try XCTUnwrap(model.beginReview())
        let first = issue(original: "big", suggestion: "small", location: 5)
        let second = issue(original: "are", suggestion: "is", location: 13)
        model.completeReview(request, issues: [first, second], failure: nil)
        model.accept(try XCTUnwrap(model.issues.first { $0.source == .llm && $0.original == "big" }))
        let remaining = try XCTUnwrap(model.issues.first { $0.source == .llm && $0.original == "are" })
        XCTAssertEqual(remaining.range.location, 15)
        model.accept(remaining)
        XCTAssertEqual(model.text, "🙂 A small cat is nice.")
    }

    func testRewriteRequiresReviewAndIsUndoable() throws {
        let model = WritingWorkspaceModel()
        model.load("I would like to say thanks.", name: "Draft", saved: true)
        let request = try XCTUnwrap(model.beginReview())
        model.completeRewrite(request, action: .makeConcise, output: "Thank you.")
        XCTAssertEqual(model.text, request.text)
        XCTAssertTrue(model.canApplyPreview)
        model.applyPreview()
        XCTAssertEqual(model.text, "Thank you.")
        XCTAssertNil(model.preview)
        model.undoSuggestion()
        XCTAssertEqual(model.text, request.text)
        XCTAssertFalse(model.isDirty)
    }

    func testRewriteCannotReplaceAnEditedDraft() throws {
        let model = WritingWorkspaceModel()
        model.load("Thanks for your help.", name: "Draft", saved: true)
        let request = try XCTUnwrap(model.beginReview())
        model.completeRewrite(request, action: .makeClearer, output: "Thank you for helping.")
        model.edit("Please use my newer draft.")
        XCTAssertFalse(model.canApplyPreview)
        model.applyPreview()
        XCTAssertEqual(model.text, "Please use my newer draft.")
    }

    func testHardBlockedRewriteIsNotOffered() throws {
        let model = WritingWorkspaceModel()
        model.load("Thank you for reviewing.", name: "Draft", saved: true)
        let request = try XCTUnwrap(model.beginReview())
        model.completeRewrite(request, action: .makeClearer, output: "")
        XCTAssertNil(model.preview)
        XCTAssertEqual(model.text, request.text)
        XCTAssertNotNil(model.notice)
    }

    func testUndoSuggestionDoesNotEraseTypingMadeAfterAccept() throws {
        let model = WritingWorkspaceModel()
        model.load("teh cat", name: "Draft", saved: true)
        model.accept(try XCTUnwrap(model.issues.first { $0.original == "teh" }))
        model.edit(model.text + " is asleep")
        model.undoSuggestion()
        XCTAssertEqual(model.text, "the cat is asleep")
        XCTAssertFalse(model.canUndoSuggestion)
    }

    func testSavedAndOpenedDraftsTrackDirtyState() {
        let model = WritingWorkspaceModel()
        model.load("Draft", name: "Draft.txt", saved: true)
        XCTAssertFalse(model.isDirty)
        model.edit("New draft")
        XCTAssertTrue(model.isDirty)
        model.markSaved(name: "New.txt")
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.documentName, "New.txt")
        model.edit("New draft!")
        XCTAssertTrue(model.isDirty)
        model.edit("New draft")
        XCTAssertFalse(model.isDirty)
    }

    func testEmptyAndOversizedDraftsNeverBeginProviderReview() {
        let model = WritingWorkspaceModel()
        XCTAssertNil(model.beginReview())
        model.edit("   \n")
        XCTAssertNil(model.beginReview())
        model.edit(String(repeating: "a", count: EngineConfig.maxProviderInputCharacters + 1))
        XCTAssertNil(model.beginReview())
        XCTAssertFalse(model.isChecking)
        XCTAssertNotNil(model.notice)
    }

    func testInvalidRangesNeverReachSubstringAccess() {
        let negative = issue(original: "x", suggestion: "y", location: -1)
        let overflowing = TextIssue(range: NSRange(location: Int.max - 1, length: 10), original: "x", suggestion: "y", explanation: nil, type: .spelling, confidence: 1, source: .llm)
        XCTAssertFalse(WritingWorkspaceModel.matches(negative, in: "x"))
        XCTAssertFalse(WritingWorkspaceModel.matches(overflowing, in: "x"))
    }

    func testNativeEditorChangesOnlyTheAcceptedRange() {
        let edit = WritingEditorChange.between("Hi team, I recieved it.", and: "Hi team, I received it.")
        XCTAssertEqual(("Hi team, I recieved it." as NSString).replacingCharacters(in: edit.range, with: edit.replacement), "Hi team, I received it.")
        XCTAssertLessThan(edit.range.length, 8)
        XCTAssertGreaterThan(edit.range.location, 10)
    }

    func testNativeEditBoundariesPreserveEmojiAndCombiningCharacters() {
        for (before, after) in [("🙂 teh cat", "🙂 the cat"), ("👨‍👩‍👧‍👦 café", "👨‍👩‍👧‍👦 café!"), ("a🙂z", "a😄z")] {
            let edit = WritingEditorChange.between(before, and: after)
            XCTAssertNotNil(Range(edit.range, in: before))
            XCTAssertEqual((before as NSString).replacingCharacters(in: edit.range, with: edit.replacement), after)
        }
    }

    private func issue(original: String, suggestion: String, location: Int) -> TextIssue {
        TextIssue(range: NSRange(location: location, length: (original as NSString).length), original: original, suggestion: suggestion, explanation: "Test suggestion", type: .grammar, confidence: 1, source: .llm)
    }
}
