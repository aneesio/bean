import AppKit
import XCTest
@testable import Bean

final class NativeEditingPathTests: XCTestCase {
    func testCollapsedCaretDoesNotCopyAnEditorsImplicitWholeLine() {
        XCTAssertFalse(TextSelectionService.shouldAttemptSelectionCopy(
            capturedRange: NSRange(location: 12, length: 0),
            hasEditableTextTarget: true, hasTypingEvidence: true
        ))
        XCTAssertFalse(TextSelectionService.shouldAttemptSelectionCopy(
            capturedRange: NSRange(location: NSNotFound, length: 4),
            hasEditableTextTarget: true, hasTypingEvidence: false
        ))
    }

    func testUnknownSelectionCanBeCopiedOnlyFromAnEditableDestination() {
        XCTAssertTrue(TextSelectionService.shouldAttemptSelectionCopy(
            capturedRange: nil, hasEditableTextTarget: true, hasTypingEvidence: false
        ))
        XCTAssertTrue(TextSelectionService.shouldAttemptSelectionCopy(
            capturedRange: nil, hasEditableTextTarget: false, hasTypingEvidence: true
        ))
        XCTAssertFalse(TextSelectionService.shouldAttemptSelectionCopy(
            capturedRange: nil, hasEditableTextTarget: false, hasTypingEvidence: false
        ))
        XCTAssertFalse(TextSelectionService.shouldAttemptSelectionCopy(
            capturedRange: NSRange(location: 0, length: 20),
            hasEditableTextTarget: false, hasTypingEvidence: false
        ))
    }

    func testDirectAXSelectionUsesExactUTF16WithoutSplittingEmoji() {
        let text = "👩🏽‍💻 fix teh word"
        let range = (text as NSString).range(of: "teh")
        XCTAssertEqual(TextSelectionService.selectedText(value: text, range: range), "teh")
        XCTAssertNil(TextSelectionService.selectedText(value: text, range: NSRange(location: 1, length: 1)))
        XCTAssertNil(TextSelectionService.selectedText(value: text, range: NSRange(location: 0, length: 0)))
        XCTAssertNil(TextSelectionService.selectedText(value: text, range: NSRange(location: NSNotFound, length: 1)))
        XCTAssertNil(TextSelectionService.selectedText(value: text, range: NSRange(location: 300, length: 1)))
    }

    func testRangeReconstructionRejectsSurrogateAndGraphemeFragments() {
        for (text, range, fragment) in [
            ("😀 word", NSRange(location: 0, length: 1), "\u{FFFD}"),
            ("cafe\u{301}", NSRange(location: 3, length: 1), "e"),
            ("👩🏽‍💻 word", NSRange(location: 0, length: 2), "👩")
        ] {
            XCTAssertNil(TextSelectionService.expectedValueAfterSelectionReplacement(
                valueBefore: text, selectedRange: range,
                selectedText: fragment, corrected: "replacement"
            ))
        }
        XCTAssertEqual(TextSelectionService.expectedValueAfterSelectionReplacement(
            valueBefore: "😀 teh", selectedRange: NSRange(location: 3, length: 3),
            selectedText: "teh", corrected: "the"
        ), "😀 the")
    }

    func testIndividualRichDocumentCorrectionCannotRewriteUnrelatedSignature() {
        XCTAssertFalse(TextSelectionService.canUseWholeFieldRangeFallback(role: "AXWebArea"))
        XCTAssertTrue(TextSelectionService.canUseWholeFieldRangeFallback(role: "AXTextArea"))
        XCTAssertTrue(TextSelectionService.canUseWholeFieldRangeFallback(role: "AXTextField"))
    }

    func testKnownNativeOrBrowserTargetCanRevalidateLimitedAXSelectionExactly() {
        XCTAssertEqual(TextSelectionService.selectionValidationStrategy(
            capturedTargetExists: true, isElectronSource: false,
            nativeReconstructionAvailable: false, selectedRangeBefore: nil,
            selectedRangeNow: nil, allowsExactClipboardFallback: true
        ), .clipboardExact)
        XCTAssertEqual(TextSelectionService.selectionValidationStrategy(
            capturedTargetExists: true, isElectronSource: false,
            nativeReconstructionAvailable: false, selectedRangeBefore: nil,
            selectedRangeNow: nil, allowsExactClipboardFallback: false
        ), .unsupported)
    }

    @MainActor
    func testDelayedEditorModelUpdateCanStillConfirmTheFirstPaste() async {
        var values: [String?] = ["teh draft", "teh draft", "the draft"]
        var waits = 0
        let result = await TextSelectionService.verifyReplacement(
            valueBefore: "teh draft", expectedAfter: "the draft",
            readValue: { values.removeFirst() }, wait: { _ in waits += 1 }
        )
        XCTAssertEqual(result, .replacedConfirmed)
        XCTAssertEqual(waits, 3)
        XCTAssertTrue(values.isEmpty)
    }

    @MainActor
    func testVerifiedPasteStopsPollingAsSoonAsEditorConfirmsIt() async {
        var reads = 0
        let result = await TextSelectionService.verifyReplacement(
            valueBefore: "teh draft", expectedAfter: "the draft",
            readValue: { reads += 1; return "the draft" }, wait: { _ in }
        )
        XCTAssertEqual(result, .replacedConfirmed)
        XCTAssertEqual(reads, 1)
    }

    @MainActor
    func testUnchangedOrUnexpectedEditorContentNeverClaimsSuccess() async {
        let unchanged = await TextSelectionService.verifyReplacement(
            valueBefore: "teh draft", expectedAfter: "the draft",
            readValue: { "teh draft" }, wait: { _ in }
        )
        XCTAssertEqual(unchanged, .copiedToClipboardFallback)
        let unexpected = await TextSelectionService.verifyReplacement(
            valueBefore: "teh draft", expectedAfter: "the draft",
            readValue: { "the draft with newer typing" }, wait: { _ in }
        )
        XCTAssertEqual(unexpected, .replacementSentUnconfirmed)
    }

    func testWhitespaceAndPunctuationDeletionRetainExactRangeProofForUndo() {
        let original = "Please  reply!"
        let spacing = (original as NSString).range(of: "  ")
        XCTAssertTrue(ReplacementUndoStore.canRegisterRangeUndo(
            original: original, replacement: "Please reply!", range: spacing,
            originalRangeText: "  ", replacementRangeText: " "
        ))
        let punctuation = (original as NSString).range(of: "!")
        XCTAssertTrue(ReplacementUndoStore.canRegisterRangeUndo(
            original: original, replacement: "Please  reply", range: punctuation,
            originalRangeText: "!", replacementRangeText: ""
        ))
    }

    func testReplacementVerificationRequiresTheExactUnicodeRepresentation() {
        let composed = "café!"
        let decomposed = "cafe\u{301}!"
        XCTAssertEqual(composed, decomposed, "Swift equality accepts canonical equivalents")
        XCTAssertEqual(TextSelectionService.verificationResult(
            after: decomposed, valueBefore: "cafe!", expectedAfter: composed
        ), .replacementSentUnconfirmed, "A different UTF-16 result cannot be confirmed")
        XCTAssertEqual(TextSelectionService.verificationResult(
            after: decomposed, valueBefore: composed, expectedAfter: decomposed
        ), .replacedConfirmed, "An exact changed representation is not the unchanged original")
        XCTAssertFalse(TextSelectionService.exactTextMatches(nil, nil),
                       "Two unreadable values do not prove an unchanged field")
    }

    func testCanonicalEquivalentNewTypingInvalidatesNativeFieldAndSelectionProof() {
        let before = "teh café"
        let now = "teh cafe\u{301}"
        XCTAssertEqual(TextSelectionService.targetContinuityFailure(
            valueWasReadable: true, valueBefore: before, valueNow: now
        ), .staleCopiedToClipboard)
        XCTAssertEqual(TextSelectionService.nativeSelectionContinuityFailure(
            valueBefore: before, valueNow: now,
            selectedRangeBefore: NSRange(location: 0, length: 3),
            selectedRangeNow: NSRange(location: 0, length: 3), selectedText: "teh"
        ), .staleCopiedToClipboard)
        XCTAssertEqual(TextSelectionService.clipboardRevalidationFailure(
            expected: before, copied: now, clipboardDidChange: true
        ), .clipboardPreservedRecoveryRequired,
                       "Copy must prove the same code units before a guarded Paste")
    }

    func testSelectedTextReconstructionRejectsReorderedCombiningCodeUnits() {
        let original = "a\u{301}\u{323}"
        let reordered = "a\u{323}\u{301}"
        XCTAssertEqual(original, reordered)
        XCTAssertEqual((original as NSString).length, (reordered as NSString).length)
        XCTAssertNil(TextSelectionService.expectedValueAfterSelectionReplacement(
            valueBefore: original, selectedRange: NSRange(location: 0, length: 3),
            selectedText: reordered, corrected: "a"
        ), "Equal length and canonical equivalence do not prove the selected UTF-16 text")
    }

    func testCaretMappingIncludesCanonicalEquivalentUTF16LengthChanges() {
        let original = "café after"
        let replacement = "cafe\u{301} after"
        let caret = (original as NSString).range(of: "after").location
        XCTAssertEqual(TextSelectionService.selectionAfterWholeFieldReplacement(
            original: original, replacement: replacement,
            selection: NSRange(location: caret, length: 0)
        ), NSRange(location: caret + 1, length: 0))
    }

    func testWholeFieldProofreadPreservesCaretOutsideChangedText() {
        let original = "👩🏽‍💻 Please fix teh draft today."
        let replacement = "👩🏽‍💻 Please fix the draft today."
        let beforeIssue = (original as NSString).range(of: "Please").location
        XCTAssertEqual(TextSelectionService.selectionAfterWholeFieldReplacement(
            original: original, replacement: replacement,
            selection: NSRange(location: beforeIssue, length: 0)
        ), NSRange(location: beforeIssue, length: 0))

        let originalLonger = "Please fix teh draft today."
        let replacementLonger = "Please fix the new draft today."
        let caret = (originalLonger as NSString).range(of: "today").location
        XCTAssertEqual(TextSelectionService.selectionAfterWholeFieldReplacement(
            original: originalLonger, replacement: replacementLonger,
            selection: NSRange(location: caret, length: 0)
        ), NSRange(location: caret + 4, length: 0))
        XCTAssertNil(TextSelectionService.selectionAfterWholeFieldReplacement(
            original: original, replacement: replacement,
            selection: NSRange(location: 300, length: 0)
        ))
    }

    func testCaretRestorationDoesNotUndoNewUserNavigationAfterPaste() {
        let inserted = NSRange(location: 11, length: 3)
        XCTAssertTrue(TextSelectionService.shouldRestoreSelectionAfterPaste(
            current: NSRange(location: 14, length: 0), replacementRange: inserted
        ))
        XCTAssertTrue(TextSelectionService.shouldRestoreSelectionAfterPaste(
            current: inserted, replacementRange: inserted
        ))
        XCTAssertFalse(TextSelectionService.shouldRestoreSelectionAfterPaste(
            current: NSRange(location: 13, length: 0), replacementRange: inserted
        ))
        XCTAssertFalse(TextSelectionService.shouldRestoreSelectionAfterPaste(
            current: nil, replacementRange: inserted
        ))
    }

    func testMarkerOnlySelectionRequiresAnExactReadableFieldSnapshot() {
        let field = "👩🏽‍💻 Please fix teh draft and teh signature.\n"
        XCTAssertEqual(TextSelectionService.markerOnlySelectedText(valueBefore: field, selectedText: "teh"), "teh")
        XCTAssertEqual(TextSelectionService.markerOnlySelectedText(valueBefore: field, selectedText: "👩🏽‍💻 Please"), "👩🏽‍💻 Please")
        XCTAssertNil(TextSelectionService.markerOnlySelectedText(valueBefore: nil, selectedText: "teh"))
        XCTAssertNil(TextSelectionService.markerOnlySelectedText(valueBefore: field, selectedText: "other text"))
        XCTAssertNil(TextSelectionService.markerOnlySelectedText(valueBefore: field, selectedText: ""))
        XCTAssertNil(TextSelectionService.markerOnlySelectedText(valueBefore: field, selectedText: " \n"))
        XCTAssertNil(TextSelectionService.markerOnlySelectedText(valueBefore: field, selectedText: "👩"),
                     "A selected string inside a joined emoji is not a complete source range")
        XCTAssertNil(TextSelectionService.markerOnlySelectedText(valueBefore: "cafe\u{301}", selectedText: "café"),
                     "Canonical equivalence is not an exact UTF-16 selection")
    }

    func testMarkerIdentityRejectsMovingToAnotherIdenticalSelectedWord() {
        let field = "teh draft and teh signature"
        XCTAssertNil(TextSelectionService.selectedTextSnapshotContinuityFailure(
            valueBefore: field, valueNow: field, selectedTextBefore: "teh", selectedTextNow: "teh",
            selectionIdentityMatches: true
        ))
        XCTAssertEqual(TextSelectionService.selectedTextSnapshotContinuityFailure(
            valueBefore: field, valueNow: field, selectedTextBefore: "teh", selectedTextNow: "teh",
            selectionIdentityMatches: false
        ), .staleCopiedToClipboard)
    }

    func testMarkerSelectionRejectsNewTypingChangedTextAndUnreadableDrafts() {
        XCTAssertEqual(TextSelectionService.selectedTextSnapshotContinuityFailure(
            valueBefore: "Please fix teh draft", valueNow: "Please fix teh newer draft",
            selectedTextBefore: "teh", selectedTextNow: "teh", selectionIdentityMatches: true
        ), .staleCopiedToClipboard)
        XCTAssertEqual(TextSelectionService.selectedTextSnapshotContinuityFailure(
            valueBefore: "Please fix teh draft", valueNow: "Please fix teh draft",
            selectedTextBefore: "teh", selectedTextNow: "draft", selectionIdentityMatches: true
        ), .staleCopiedToClipboard)
        XCTAssertEqual(TextSelectionService.selectedTextSnapshotContinuityFailure(
            valueBefore: "Please fix teh draft", valueNow: nil,
            selectedTextBefore: "teh", selectedTextNow: "teh", selectionIdentityMatches: true
        ), .copiedToClipboardFallback)
        XCTAssertEqual(TextSelectionService.selectedTextSnapshotContinuityFailure(
            valueBefore: "Please fix teh draft", valueNow: "Please fix teh draft",
            selectedTextBefore: "teh", selectedTextNow: nil, selectionIdentityMatches: true
        ), .copiedToClipboardFallback)
        XCTAssertEqual(TextSelectionService.selectedTextSnapshotContinuityFailure(
            valueBefore: "cafe\u{301} teh", valueNow: "café teh",
            selectedTextBefore: "teh", selectedTextNow: "teh", selectionIdentityMatches: true
        ), .staleCopiedToClipboard)
    }

    func testOpaqueSelectionVerificationPreservesExactLayoutAndUTF16Text() {
        XCTAssertEqual(TextSelectionService.expectedValueAfterUniqueSelectedTextReplacement(
            valueBefore: " \n👩🏽‍💻 Please fix teh draft.\n", selectedText: "teh", corrected: "the"
        ), " \n👩🏽‍💻 Please fix the draft.\n")
        XCTAssertEqual(TextSelectionService.expectedValueAfterUniqueSelectedTextReplacement(
            valueBefore: "Delete ! here", selectedText: "!", corrected: ""
        ), "Delete  here")
        XCTAssertNil(TextSelectionService.expectedValueAfterUniqueSelectedTextReplacement(
            valueBefore: "👩🏽‍💻 draft", selectedText: "👩", corrected: "person"
        ))
    }

    func testOpaqueSelectionVerificationNeverChoosesARepeatedOrOverlappingMatch() {
        XCTAssertNil(TextSelectionService.expectedValueAfterUniqueSelectedTextReplacement(
            valueBefore: "teh draft and teh signature", selectedText: "teh", corrected: "the"
        ))
        XCTAssertNil(TextSelectionService.expectedValueAfterUniqueSelectedTextReplacement(
            valueBefore: "aaa", selectedText: "aa", corrected: "b"
        ))
        XCTAssertNil(TextSelectionService.expectedValueAfterUniqueSelectedTextReplacement(
            valueBefore: "Draft", selectedText: "", corrected: "replacement"
        ))
        XCTAssertNil(TextSelectionService.expectedValueAfterUniqueSelectedTextReplacement(
            valueBefore: "Draft", selectedText: "missing", corrected: "replacement"
        ))
    }

    @MainActor
    func testMarkerSelectionMovementAfterCopyStopsBeforeCorrectionWriteOrPaste() async {
        var selectionIdentityMatches = true
        var copiedText = "User clipboard"
        var changeCount = 10
        var wroteCorrection = false
        var pasted = false
        let field = "teh draft and teh signature"
        let saved: ClipboardService.Snapshot = [[NSPasteboard.PasteboardType.string.rawValue: Data(copiedText.utf8)]]
        let attempt = await TextSelectionService.runGuardedClipboardPaste(
            expected: "teh", corrected: "the", selectAll: false,
            effects: TextSelectionService.GuardedClipboardPasteEffects(
                captureDestinationRevision: { 1 },
                destinationIsValid: { _, _ in
                    TextSelectionService.selectedTextSnapshotContinuityFailure(
                        valueBefore: field, valueNow: field,
                        selectedTextBefore: "teh", selectedTextNow: "teh",
                        selectionIdentityMatches: selectionIdentityMatches
                    ) == nil
                },
                simulateSelectAll: { XCTFail("A selected marker must not select the whole composer") },
                pauseAfterSelectAll: {}, snapshotClipboard: { saved }, promoteSnapshot: { _ in },
                changeCount: { changeCount },
                simulateCopy: { copiedText = "teh"; changeCount += 1 },
                pauseAfterCopy: { selectionIdentityMatches = false },
                readString: { copiedText },
                writeCorrection: { _ in wroteCorrection = true },
                simulatePaste: { pasted = true }
            )
        )
        XCTAssertEqual(attempt.failure, .clipboardPreservedRecoveryRequired)
        XCTAssertFalse(wroteCorrection)
        XCTAssertFalse(pasted)
        XCTAssertEqual(copiedText, "teh")
    }
}
