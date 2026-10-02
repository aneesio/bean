import Foundation
import XCTest
@testable import Bean

final class NativeEditPlanTests: XCTestCase {
    func testMechanicalFixturesHaveExactForwardAndInverseTextIncludingUnicodeAndBoundaries() throws {
        let cases = [
            ("lets try", "let’s try"), ("a  b", "a b"),
            ("teh teh", "the the"), ("first second", "first, second."),
            ("👍🏽 correct ?", "👍🏽 correct?"), ("foo bar", "foo baz"),
            ("café", "cafe\u{301}"), ("e.g, wording", "e.g. wording"),
            ("\"quoted teh\"", "\"quoted the\""), ("", "Restored"), ("Deleted", "")
        ]
        for (original, corrected) in cases {
            let plan = try XCTUnwrap(NativeEditPlan.proofread(original: original, corrected: corrected), original)
            XCTAssertTrue(plan.replacement.utf16.elementsEqual(corrected.utf16), original)
            let inverse = try XCTUnwrap(NativeEditPlan.validated(original: corrected, edits: plan.inverseEdits), original)
            XCTAssertTrue(inverse.replacement.utf16.elementsEqual(original.utf16), original)
        }
    }

    func testMechanicalProofreadTargetsOnlyChangedLettersAndPunctuation() throws {
        let original = "Please fix teh spelling and recieved files"
        let corrected = "Please fix the spelling and received files."
        let plan = try XCTUnwrap(NativeEditPlan.proofread(original: original, corrected: corrected))
        XCTAssertEqual(plan.replacement, corrected)
        XCTAssertEqual(plan.edits.map(\.original), ["eh", "ie", ""])
        XCTAssertEqual(plan.edits.map(\.replacement), ["he", "ei", "."])
        XCTAssertEqual(plan.edits.last?.range, NSRange(location: (original as NSString).length, length: 0))
    }

    func testRepeatedPhraseTargetsCorrectOccurrenceWithoutSubstringGuessing() throws {
        let original = "teh first; teh second; teh third"
        let plan = try XCTUnwrap(NativeEditPlan.proofread(original: original,
                                                       corrected: "teh first; the second; teh third"))
        XCTAssertEqual(plan.edits.count, 1)
        XCTAssertEqual(plan.edits[0].range, NSRange(location: 12, length: 2))
        XCTAssertEqual(plan.replacement, "teh first; the second; teh third")
    }

    func testLineBreaksAndAttachmentMarkersRemainOutsideEditedSpans() throws {
        let original = "teh first\r\nSignature \u{fffc}\r\nrecieved later"
        let plan = try XCTUnwrap(NativeEditPlan.proofread(original: original,
            corrected: "the first\r\nSignature \u{fffc}\r\nreceived later"))
        XCTAssertEqual(plan.edits.count, 2)
        XCTAssertTrue(plan.edits.allSatisfy { !$0.original.contains("\r") && !$0.original.contains("\u{fffc}") })
        XCTAssertNil(NativeEditPlan.proofread(original: original,
            corrected: "the first\nSignature \u{fffc}\nreceived later"))
        XCTAssertNil(NativeEditPlan.proofread(original: "File \u{fffc} here", corrected: "File here"))
    }

    func testExactUTF16AndCharacterBoundariesAreRequired() throws {
        let original = "🙂 cafe\u{301} teh"
        XCTAssertNil(NativeEditPlan.validated(original: original,
            edits: [.init(range: NSRange(location: 1, length: 1), original: "", replacement: "x")]))
        let accent = (original as NSString).range(of: "e\u{301}", options: .literal)
        XCTAssertNil(NativeEditPlan.validated(original: original,
            edits: [.init(range: NSRange(location: accent.location + 1, length: 1), original: "\u{301}", replacement: "")]))
        XCTAssertNil(NativeEditPlan.validated(original: original,
            edits: [.init(range: accent, original: "é", replacement: "e")]))
        let plan = try XCTUnwrap(NativeEditPlan.proofread(original: original, corrected: "🙂 cafe\u{301} the"))
        XCTAssertTrue(plan.replacement.utf16.elementsEqual("🙂 cafe\u{301} the".utf16))
    }

    func testInversePlanRestoresInsertionDeletionAndMultipleShiftedRanges() throws {
        let original = "🙂 teh later!! recieved"
        let corrected = "🙂 the later! received."
        let plan = try XCTUnwrap(NativeEditPlan.proofread(original: original, corrected: corrected))
        let inverse = try XCTUnwrap(NativeEditPlan.validated(original: corrected, edits: plan.inverseEdits))
        XCTAssertTrue(inverse.replacement.utf16.elementsEqual(original.utf16))
        XCTAssertTrue(inverse.edits.contains { $0.range.length == 0 && !$0.replacement.isEmpty })
    }

    func testAdjacentDeletedSpansShareOneExactUndoInsertionCaret() throws {
        let plan = try XCTUnwrap(NativeEditPlan.validated(original: "a!b",
            edits: [.init(range: NSRange(location: 0, length: 1), original: "a", replacement: ""),
                    .init(range: NSRange(location: 1, length: 1), original: "!", replacement: "")]))
        XCTAssertEqual(plan.replacement, "b")
        XCTAssertEqual(plan.inverseEdits, [.init(range: NSRange(location: 0, length: 0), original: "", replacement: "a!")])
        XCTAssertEqual(NativeEditPlan.validated(original: plan.replacement, edits: plan.inverseEdits)?.replacement, "a!b")
        let adjacent = try XCTUnwrap(NativeEditPlan.validated(original: "ab",
            edits: [.init(range: NSRange(location: 0, length: 1), original: "a", replacement: ""),
                    .init(range: NSRange(location: 1, length: 1), original: "b", replacement: "B")]))
        XCTAssertEqual(NativeEditPlan.validated(original: adjacent.replacement, edits: adjacent.inverseEdits)?.replacement, "ab")
    }

    func testInvalidOverlappingAndUnboundedPlansAreRejected() {
        XCTAssertNil(NativeEditPlan.validated(original: "teh",
            edits: [.init(range: NSRange(location: 0, length: 2), original: "te", replacement: "x"),
                    .init(range: NSRange(location: 1, length: 2), original: "eh", replacement: "y")]))
        XCTAssertNil(NativeEditPlan.validated(original: "teh",
            edits: [.init(range: NSRange(location: Int.max, length: Int.max), original: "x", replacement: "y")]))
        XCTAssertNil(NativeEditPlan.validated(original: "teh",
            edits: [.init(range: NSRange(location: 0, length: 3), original: "teh", replacement: "teh")]))
        let a = (0..<1_100).map { "before\($0)" }.joined(separator: " ")
        let b = (0..<1_100).map { "after\($0)" }.joined(separator: " ")
        XCTAssertNil(NativeEditPlan.proofread(original: a, corrected: b), "Complex rewrites must not become a broad paste")
    }

    func testCaretMappingKeepsUnselectedPositionAndTracksBoundaryPunctuation() throws {
        let original = "teh first and recieved last"
        let plan = try XCTUnwrap(NativeEditPlan.proofread(original: original, corrected: "the first and received last."))
        XCTAssertEqual(plan.selectionAfterEdits(NSRange(location: 4, length: 0)), NSRange(location: 4, length: 0))
        XCTAssertEqual(plan.selectionAfterEdits(NSRange(location: (original as NSString).length, length: 0)),
                       NSRange(location: (plan.replacement as NSString).length, length: 0))
    }

    func testParagraphScopeUsesNumericCaretAndPreservesCRLFSeparators() throws {
        let text = "🙂 First\r\nSecond cafe\u{301}\r\nThird"
        let expected = (text as NSString).range(of: "Second cafe\u{301}", options: .literal)
        XCTAssertEqual(NativeActionScope.paragraphRange(in: text,
            caret: NSRange(location: expected.location + 3, length: 0)), expected)
        XCTAssertEqual(NativeActionScope.paragraphRange(in: text,
            caret: NSRange(location: NSMaxRange(expected), length: 0)), expected)
        XCTAssertNil(NativeActionScope.paragraphRange(in: text, caret: NSRange(location: 1, length: 0)))
        XCTAssertNil(NativeActionScope.paragraphRange(in: text, caret: NSRange(location: expected.location, length: 3)))
        XCTAssertNil(NativeActionScope.paragraphRange(in: "First\n\nThird", caret: NSRange(location: 6, length: 0)))
    }

    func testParagraphBoundaryEditsNeverTouchOtherParagraphs() throws {
        let original = "Untouched\nSecond teh\nSignature \u{fffc}"
        let range = try XCTUnwrap(NativeActionScope.paragraphRange(in: original, caret: NSRange(location: 19, length: 0)))
        let local = try XCTUnwrap(NativeEditPlan.proofread(original: (original as NSString).substring(with: range),
                                                        corrected: "Second the."))
        let edits = local.edits.map { NativeTextEdit(range: NSRange(location: range.location + $0.range.location,
                                                                   length: $0.range.length),
                                                     original: $0.original, replacement: $0.replacement) }
        let full = try XCTUnwrap(NativeEditPlan.validated(original: original, edits: edits))
        XCTAssertEqual(full.replacement, "Untouched\nSecond the.\nSignature \u{fffc}")
    }
}
