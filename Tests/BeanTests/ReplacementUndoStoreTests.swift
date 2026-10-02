import AppKit
import XCTest
@testable import Bean

final class ReplacementUndoStoreTests: XCTestCase {
    func testConfirmedSelectedEditSupportsUndoWithoutRequiringWholeFieldWrite() {
        let original = "Please fix teh sentence."
        XCTAssertTrue(ReplacementUndoStore.canRegisterRangeUndo(
            original: original, replacement: "Please fix the sentence.",
            range: (original as NSString).range(of: "teh"),
            originalRangeText: "teh", replacementRangeText: "the"
        ))
    }

    func testUnexpectedFieldChangeCannotBecomeAnUndoRecord() {
        let original = "Please fix teh sentence."
        XCTAssertFalse(ReplacementUndoStore.canRegisterRangeUndo(
            original: original, replacement: "Please fix the newer sentence.",
            range: (original as NSString).range(of: "teh"),
            originalRangeText: "teh", replacementRangeText: "the"
        ))
    }

    func testRepeatedTextMustUseTheCapturedOccurrenceForUndo() {
        let original = "teh first and teh second"
        XCTAssertFalse(ReplacementUndoStore.canRegisterRangeUndo(
            original: original, replacement: "teh first and the second",
            range: NSRange(location: 0, length: 3),
            originalRangeText: "teh", replacementRangeText: "the"
        ), "A correction at the second occurrence cannot prove a first-occurrence undo")
        XCTAssertTrue(ReplacementUndoStore.canRegisterRangeUndo(
            original: original, replacement: "teh first and the second",
            range: NSRange(location: 14, length: 3),
            originalRangeText: "teh", replacementRangeText: "the"
        ))
    }

    func testCanonicalEquivalentFieldChangeCannotBeUndoneFromOldUTF16Offsets() {
        XCTAssertFalse(ReplacementUndoStore.currentValueMatches(
            "the cafe\u{301}", expectedReplacement: "the café"
        ))
        XCTAssertTrue(ReplacementUndoStore.currentValueMatches(
            "the café", expectedReplacement: "the café"
        ))
        XCTAssertFalse(ReplacementUndoStore.canRegisterRangeUndo(
            original: "teh café", replacement: "the cafe\u{301}",
            range: NSRange(location: 0, length: 3),
            originalRangeText: "teh", replacementRangeText: "the"
        ), "Unrelated normalization is not the exact predicted range edit")
    }

    @MainActor
    func testConfirmedEditWithoutAnExactUndoRangeRetiresThePreviousRecord() async {
        let store = ReplacementUndoStore()
        store.registerConfirmedWholeField(
            app: .current,
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
            original: "An earlier teh edit", replacement: "An earlier the edit"
        )
        XCTAssertTrue(store.isAvailable)
        // An opaque selected-span edit must not fall back to replacing all
        // rich text, or leave the previous unrelated operation on Undo.
        store.discard()
        XCTAssertFalse(store.isAvailable)
        let result = await store.undo()
        XCTAssertEqual(result, .failed(reason: "There is no recent verified Bean change to undo."))
    }
}
