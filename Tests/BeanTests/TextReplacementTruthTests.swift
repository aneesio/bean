import AppKit
import XCTest
@testable import Bean

final class TextReplacementTruthTests: XCTestCase {
    func testCapturedNativeTargetNeedsContinuityUnlessElectronRecopyWillProveIt() {
        XCTAssertEqual(
            TextSelectionService.selectionFocusContinuityFailure(
                capturedTargetExists: true,
                currentTargetExists: false,
                targetsMatch: false
            ),
            .copiedToClipboardFallback
        )
        XCTAssertEqual(
            TextSelectionService.selectionFocusContinuityFailure(
                capturedTargetExists: true,
                currentTargetExists: true,
                targetsMatch: false
            ),
            .copiedToClipboardFallback
        )
        XCTAssertNil(
            TextSelectionService.selectionFocusContinuityFailure(
                capturedTargetExists: false,
                currentTargetExists: false,
                targetsMatch: false
            ),
            "AX-free paste is allowed only when capture itself had no AX target"
        )
        XCTAssertNil(
            TextSelectionService.selectionFocusContinuityFailure(
                capturedTargetExists: false,
                currentTargetExists: true,
                targetsMatch: false
            ),
            "A later AX surface must not reclassify an AX-free capture as native"
        )
        XCTAssertNil(
            TextSelectionService.selectionFocusContinuityFailure(
                capturedTargetExists: true,
                currentTargetExists: false,
                targetsMatch: false,
                allowsMissingCurrentTargetForExactElectronRecopy: true
            ),
            "A transiently missing Electron target may proceed only to exact live Cmd+C revalidation"
        )
    }

    func testNativeSelectionRejectsChangedContentsOrMovedSelection() {
        let original = "Please fix this sentence."
        let range = (original as NSString).range(of: "fix")
        XCTAssertEqual(
            TextSelectionService.nativeSelectionContinuityFailure(
                valueBefore: original,
                valueNow: "Please fix this newer sentence.",
                selectedRangeBefore: range,
                selectedRangeNow: range,
                selectedText: "fix"
            ),
            .staleCopiedToClipboard
        )
        XCTAssertEqual(
            TextSelectionService.nativeSelectionContinuityFailure(
                valueBefore: original,
                valueNow: original,
                selectedRangeBefore: range,
                selectedRangeNow: NSRange(location: range.location + 1, length: range.length),
                selectedText: "fix"
            ),
            .staleCopiedToClipboard
        )
    }

    func testNativeSelectionRequiresSameValidNonEmptyRange() {
        let original = "Please fix this sentence."
        let range = (original as NSString).range(of: "fix")
        XCTAssertNil(
            TextSelectionService.nativeSelectionContinuityFailure(
                valueBefore: original,
                valueNow: original,
                selectedRangeBefore: range,
                selectedRangeNow: range,
                selectedText: "fix"
            )
        )
        XCTAssertEqual(
            TextSelectionService.nativeSelectionContinuityFailure(
                valueBefore: original,
                valueNow: original,
                selectedRangeBefore: nil,
                selectedRangeNow: nil,
                selectedText: "fix"
            ),
            .copiedToClipboardFallback,
            "A native selection without a captured AX range must fail closed"
        )
        XCTAssertEqual(
            TextSelectionService.nativeSelectionContinuityFailure(
                valueBefore: original,
                valueNow: original,
                selectedRangeBefore: NSRange(location: range.location, length: 0),
                selectedRangeNow: NSRange(location: range.location, length: 0),
                selectedText: "fix"
            ),
            .copiedToClipboardFallback,
            "A collapsed caret must never qualify as the captured selection"
        )
        XCTAssertEqual(
            TextSelectionService.nativeSelectionContinuityFailure(
                valueBefore: original,
                valueNow: original,
                selectedRangeBefore: range,
                selectedRangeNow: nil,
                selectedText: "fix"
            ),
            .copiedToClipboardFallback,
            "A native selection that becomes unreadable must fail closed"
        )
    }

    func testLimitedAXElectronSelectionUsesExactClipboardRevalidation() {
        let range = NSRange(location: 4, length: 3)
        XCTAssertEqual(
            TextSelectionService.selectionValidationStrategy(
                capturedTargetExists: true,
                isElectronSource: false,
                nativeReconstructionAvailable: true,
                selectedRangeBefore: range,
                selectedRangeNow: range
            ),
            .nativeRange
        )
        XCTAssertEqual(
            TextSelectionService.selectionValidationStrategy(
                capturedTargetExists: true,
                isElectronSource: true,
                nativeReconstructionAvailable: false,
                selectedRangeBefore: nil,
                selectedRangeNow: nil
            ),
            .clipboardExact,
            "A limited-AX Slack selection must be retryable through an exact live recopy"
        )
        XCTAssertEqual(
            TextSelectionService.selectionValidationStrategy(
                capturedTargetExists: false,
                isElectronSource: true,
                nativeReconstructionAvailable: false,
                selectedRangeBefore: nil,
                selectedRangeNow: nil
            ),
            .clipboardExact,
            "An AX-free Slack selection must be revalidated rather than pasted blindly"
        )
        XCTAssertEqual(
            TextSelectionService.selectionValidationStrategy(
                capturedTargetExists: true,
                isElectronSource: false,
                nativeReconstructionAvailable: false,
                selectedRangeBefore: nil,
                selectedRangeNow: nil
            ),
            .unsupported,
            "Native targets must fail closed when neither native nor Electron continuity proof is available"
        )
        XCTAssertEqual(
            TextSelectionService.selectionValidationStrategy(
                capturedTargetExists: true,
                isElectronSource: true,
                nativeReconstructionAvailable: false,
                selectedRangeBefore: range,
                selectedRangeNow: range
            ),
            .clipboardExact,
            "Electron ranges alone are insufficient when AXValue cannot reconstruct the selected edit"
        )
    }

    func testClipboardRevalidationRequiresANewExactSelectionOrDraftCopy() {
        let captured = "  Draft 👩🏽‍💻 text\n"
        XCTAssertNil(
            TextSelectionService.clipboardRevalidationFailure(
                expected: captured,
                copied: captured,
                clipboardDidChange: true
            )
        )
        XCTAssertEqual(
            TextSelectionService.clipboardRevalidationFailure(
                expected: captured,
                copied: "  Draft 👩🏽‍💻 text changed\n",
                clipboardDidChange: true
            ),
            .clipboardPreservedRecoveryRequired,
            "New typing, a moved selection, or a concurrent Copy must prevent the paste without overwriting the clipboard"
        )
        XCTAssertEqual(
            TextSelectionService.clipboardRevalidationFailure(
                expected: captured,
                copied: captured,
                clipboardDidChange: false
            ),
            .clipboardPreservedRecoveryRequired,
            "An unchanged pasteboard cannot prove that Cmd+C reached the live field"
        )
        XCTAssertEqual(
            TextSelectionService.clipboardRevalidationFailure(
                expected: captured,
                copied: nil,
                clipboardDidChange: true
            ),
            .clipboardPreservedRecoveryRequired
        )
    }

    func testNativeWholeFieldRejectsStaleAndUnverifiableValues() {
        XCTAssertEqual(
            TextSelectionService.targetContinuityFailure(
                valueWasReadable: true,
                valueBefore: "Original draft",
                valueNow: "User kept typing"
            ),
            .staleCopiedToClipboard
        )
        XCTAssertEqual(
            TextSelectionService.targetContinuityFailure(
                valueWasReadable: true,
                valueBefore: "Original draft",
                valueNow: nil
            ),
            .copiedToClipboardFallback
        )
    }

    func testVerifiedPasteFailureNeverClaimsSuccess() {
        XCTAssertEqual(
            TextSelectionService.verificationResult(
                after: "The unchanged source text",
                valueBefore: "The unchanged source text",
                expectedAfter: "The corrected text"
            ),
            .copiedToClipboardFallback
        )
        XCTAssertEqual(
            TextSelectionService.verificationResult(
                after: nil,
                valueBefore: "The unchanged source text",
                expectedAfter: "The corrected text"
            ),
            .replacementSentUnconfirmed
        )
        XCTAssertEqual(
            TextSelectionService.verificationResult(
                after: "A different, unexpected value",
                valueBefore: "The unchanged source text",
                expectedAfter: "The corrected text"
            ),
            .replacementSentUnconfirmed
        )
    }

    func testVerifiedPasteConfirmsOnlyTheExpectedNativeResult() {
        XCTAssertEqual(
            TextSelectionService.verificationResult(
                after: "Before The corrected text After",
                valueBefore: "Before old text After",
                expectedAfter: "Before The corrected text After"
            ),
            .replacedConfirmed
        )
        XCTAssertEqual(
            TextSelectionService.verificationResult(
                after: "  The corrected text\n",
                valueBefore: "The old text",
                expectedAfter: "  The corrected text\n"
            ),
            .replacedConfirmed
        )
        XCTAssertEqual(
            TextSelectionService.verificationResult(
                after: "Prefix The corrected text Suffix",
                valueBefore: "The old text",
                expectedAfter: "The corrected text"
            ),
            .replacementSentUnconfirmed,
            "Whole-field verification must require an exact untrimmed match"
        )
        XCTAssertEqual(
            TextSelectionService.verificationResult(
                after: "The corrected text",
                valueBefore: "The old text\n",
                expectedAfter: "The corrected text\n"
            ),
            .replacementSentUnconfirmed,
            "A dropped trailing newline must never be hidden by trimming"
        )
        XCTAssertEqual(
            TextSelectionService.verificationResult(
                after: "The corrected text still surrounds old text",
                valueBefore: "The corrected text still surrounds old text",
                expectedAfter: "The corrected text still surrounds The corrected text"
            ),
            .copiedToClipboardFallback,
            "A correction already present elsewhere must not create a false selected-text confirmation"
        )
    }

    func testSelectedTextExpectedValueUsesUTF16RangeAndExactContext() {
        let before = "Start 👩🏽‍💻 teh end"
        let selected = "👩🏽‍💻 teh"
        let range = (before as NSString).range(of: selected)
        XCTAssertGreaterThan(range.length, selected.count)

        let expected = TextSelectionService.expectedValueAfterSelectionReplacement(
            valueBefore: before,
            selectedRange: range,
            selectedText: selected,
            corrected: "the code"
        )
        XCTAssertEqual(expected, "Start the code end")
        XCTAssertEqual(
            TextSelectionService.verificationResult(
                after: expected,
                valueBefore: before,
                expectedAfter: expected
            ),
            .replacedConfirmed
        )
        XCTAssertNil(
            TextSelectionService.expectedValueAfterSelectionReplacement(
                valueBefore: before,
                selectedRange: NSRange(location: range.location, length: 1),
                selectedText: selected,
                corrected: "the code"
            ),
            "A range that splits an emoji's UTF-16 representation must be rejected"
        )
    }

    @MainActor
    func testOrdinaryReplacementRestoresTheFullPriorClipboard() {
        for result in [
            TextSelectionService.ReplacementResult.replacedConfirmed,
            .replacementSentUnconfirmed
        ] {
            let stringType = NSPasteboard.PasteboardType.string.rawValue
            let privateType = "com.bean.tests.clipboard-marker"
            let privateData = Data([0x01, 0x02, 0x03, 0x04])
            let saved: ClipboardService.Snapshot = [[
                stringType: Data("User clipboard".utf8),
                privateType: privateData
            ]]
            var current: ClipboardService.Snapshot = [[
                stringType: Data("Bean temporary correction".utf8)
            ]]

            TextSelectionService.applyClipboardCompletion(
                TextSelectionService.clipboardCompletion(for: result),
                saved: saved,
                restoreClipboard: { current = $0 }
            )

            XCTAssertEqual(current, saved)
            XCTAssertEqual(current.first?[privateType], privateData)
        }
    }

    @MainActor
    func testDelayedRestoreNeverOverwritesANewerUserCopy() {
        let stringType = NSPasteboard.PasteboardType.string.rawValue
        let saved: ClipboardService.Snapshot = [[
            stringType: Data("Original clipboard".utf8)
        ]]
        let newerUserCopy: ClipboardService.Snapshot = [[
            stringType: Data("User copied this while Bean was pasting".utf8)
        ]]
        var current = newerUserCopy

        XCTAssertFalse(TextSelectionService.clipboardIsStillOwned(
            beanOwnedChangeCount: 41,
            currentChangeCount: 42
        ))
        TextSelectionService.applyClipboardCompletion(
            .restoreOriginal,
            saved: saved,
            clipboardStillOwned: false,
            restoreClipboard: { current = $0 }
        )

        XCTAssertEqual(current, newerUserCopy)
    }

    func testTemporaryPasteRestoresTheLatestUserClipboardSnapshot() {
        let stringType = NSPasteboard.PasteboardType.string.rawValue
        let original: ClipboardService.Snapshot = [[
            stringType: Data("Clipboard before acquisition".utf8)
        ]]
        let newer: ClipboardService.Snapshot = [[
            stringType: Data("Clipboard copied during AI request".utf8)
        ]]

        XCTAssertEqual(
            TextSelectionService.clipboardSnapshotToRestore(
                originalSaved: original,
                currentSnapshot: newer,
                acquisitionOwnedChangeCount: 10,
                currentChangeCount: 11
            ),
            newer
        )
        XCTAssertEqual(
            TextSelectionService.clipboardSnapshotToRestore(
                originalSaved: original,
                currentSnapshot: newer,
                acquisitionOwnedChangeCount: 10,
                currentChangeCount: 10
            ),
            original
        )
    }

    func testFallbackPromotesASecondUserCopyMadeDuringActivationForRetry() {
        let stringType = NSPasteboard.PasteboardType.string.rawValue
        let clipboardA: ClipboardService.Snapshot = [[
            stringType: Data("Clipboard A before acquisition".utf8)
        ]]
        let clipboardB1: ClipboardService.Snapshot = [[
            stringType: Data("Clipboard B1 copied during AI work".utf8)
        ]]
        let clipboardB2: ClipboardService.Snapshot = [[
            stringType: Data("Clipboard B2 copied during app activation".utf8)
        ]]
        let correction: ClipboardService.Snapshot = [[
            stringType: Data("Bean fallback correction".utf8)
        ]]

        let initiallyPromoted = TextSelectionService.clipboardSnapshotToRestore(
            originalSaved: clipboardA,
            currentSnapshot: clipboardB1,
            acquisitionOwnedChangeCount: 10,
            currentChangeCount: 11
        )
        XCTAssertEqual(initiallyPromoted, clipboardB1)

        let postActivationPromoted = TextSelectionService.clipboardSnapshotToRestore(
            originalSaved: initiallyPromoted,
            currentSnapshot: clipboardB2,
            acquisitionOwnedChangeCount: 10,
            currentChangeCount: 12
        )
        XCTAssertEqual(postActivationPromoted, clipboardB2)

        let retryRestore = TextSelectionService.clipboardSnapshotToRestore(
            originalSaved: postActivationPromoted,
            currentSnapshot: correction,
            acquisitionOwnedChangeCount: 13,
            currentChangeCount: 13
        )
        XCTAssertEqual(
            retryRestore,
            clipboardB2,
            "A retry must restore the last activation-time copy, never B1 or the pre-acquisition clipboard"
        )
    }

    @MainActor
    func testLimitedAXSelectionRejectsPostCopyFocusLossBeforeClipboardWriteOrPaste() async {
        await assertGuardedPostCopyLoss(
            path: .limitedAXSelection,
            loss: .focusedTarget
        )
    }

    @MainActor
    func testFocusedCmdARejectsPostCopyAppLossBeforeClipboardWriteOrPaste() async {
        await assertGuardedPostCopyLoss(
            path: .focusedCmdA,
            loss: .sourceApp
        )
    }

    @MainActor
    func testSlackAXFreeRejectsPostCopyTypingFocusLossBeforeClipboardWriteOrPaste() async {
        await assertGuardedPostCopyLoss(
            path: .slackAXFree,
            loss: .slackTypingFocusEvidence
        )
    }

    @MainActor
    func testLimitedAXSelectionRejectsSameTargetInteractionDuringPostCopyWait() async {
        await assertGuardedPostCopyLoss(
            path: .limitedAXSelection,
            loss: .interactionRevision
        )
    }

    @MainActor
    func testFocusedCmdARejectsSameTargetInteractionDuringPostCopyWait() async {
        await assertGuardedPostCopyLoss(
            path: .focusedCmdA,
            loss: .interactionRevision
        )
    }

    @MainActor
    func testAllGuardedPathsPasteOnlyAfterFinalPostCopyDestinationProof() async {
        let stringType = NSPasteboard.PasteboardType.string.rawValue
        let beforeSelectAll: ClipboardService.Snapshot = [[
            stringType: Data("Before Select All".utf8)
        ]]
        let duringSelectAllWait: ClipboardService.Snapshot = [[
            stringType: Data("Copy during Select All wait".utf8)
        ]]

        for path in GuardedTestPath.allCases {
            var currentClipboard = beforeSelectAll
            var changeCount = 80
            let interactionRevision: UInt64 = 11
            var events: [String] = []

            let attempt = await TextSelectionService.runGuardedClipboardPaste(
                expected: "Captured draft",
                corrected: "Corrected draft",
                selectAll: path.usesSelectAll,
                effects: TextSelectionService.GuardedClipboardPasteEffects(
                    captureDestinationRevision: {
                        events.append("capture-destination-revision")
                        return 11
                    },
                    destinationIsValid: { capturedRevision, checkPoint in
                        events.append("validate-destination-\(checkPoint)")
                        return interactionRevision == capturedRevision
                    },
                    simulateSelectAll: { events.append("select-all") },
                    pauseAfterSelectAll: {
                        events.append("select-all-settled")
                        currentClipboard = duringSelectAllWait
                        changeCount += 1
                    },
                    snapshotClipboard: {
                        events.append("snapshot")
                        return currentClipboard
                    },
                    promoteSnapshot: { _ in events.append("promote-snapshot") },
                    changeCount: { changeCount },
                    simulateCopy: {
                        events.append("copy")
                        currentClipboard = [[stringType: Data("Captured draft".utf8)]]
                        changeCount += 1
                    },
                    pauseAfterCopy: { events.append("copy-settled") },
                    readString: {
                        events.append("read-copy")
                        return "Captured draft"
                    },
                    writeCorrection: { correction in
                        events.append("write-correction")
                        currentClipboard = [[stringType: Data(correction.utf8)]]
                        changeCount += 1
                    },
                    simulatePaste: { events.append("paste") }
                )
            )

            XCTAssertNil(attempt.failure, path.label)
            XCTAssertEqual(attempt.beanClipboardChangeCount, changeCount, path.label)
            XCTAssertEqual(
                attempt.clipboardToRestore,
                path.usesSelectAll ? duringSelectAllWait : beforeSelectAll,
                path.label
            )
            let validationIndex = try? XCTUnwrap(events.lastIndex(of: "validate-destination-beforePaste"))
            let writeIndex = try? XCTUnwrap(events.firstIndex(of: "write-correction"))
            let pasteIndex = try? XCTUnwrap(events.firstIndex(of: "paste"))
            XCTAssertNotNil(validationIndex, path.label)
            XCTAssertNotNil(writeIndex, path.label)
            XCTAssertNotNil(pasteIndex, path.label)
            if let validationIndex, let writeIndex, let pasteIndex {
                XCTAssertLessThan(validationIndex, writeIndex, path.label)
                XCTAssertLessThan(writeIndex, pasteIndex, path.label)
            }
            if path.usesSelectAll {
                let settledIndex = try? XCTUnwrap(events.firstIndex(of: "select-all-settled"))
                let snapshotIndex = try? XCTUnwrap(events.firstIndex(of: "snapshot"))
                if let settledIndex, let snapshotIndex {
                    XCTAssertLessThan(settledIndex, snapshotIndex, path.label)
                }
            }
        }
    }

    @MainActor
    private func assertGuardedPostCopyLoss(
        path: GuardedTestPath,
        loss: GuardedTestLoss
    ) async {
        let stringType = NSPasteboard.PasteboardType.string.rawValue
        let beforeSelectAll: ClipboardService.Snapshot = [[
            stringType: Data("Clipboard before guarded sequence".utf8)
        ]]
        let copyDuringSelectAllWait: ClipboardService.Snapshot = [[
            stringType: Data("Copy made during Select All settle".utf8)
        ]]
        let exactDraftCopy: ClipboardService.Snapshot = [[
            stringType: Data("Captured draft".utf8)
        ]]

        var currentClipboard = beforeSelectAll
        var changeCount = 50
        var sourceAppIsFrontmost = true
        var focusedTargetMatches = true
        var slackTypingFocusEvidenceIsStable = true
        var interactionRevision: UInt64 = 7
        var promotedSnapshot: ClipboardService.Snapshot?
        var events: [String] = []
        var correctionWriteCount = 0
        var pasteCount = 0

        let attempt = await TextSelectionService.runGuardedClipboardPaste(
            expected: "Captured draft",
            corrected: "Corrected draft",
            selectAll: path.usesSelectAll,
            effects: TextSelectionService.GuardedClipboardPasteEffects(
                captureDestinationRevision: {
                    events.append("capture-destination-revision")
                    return 7
                },
                destinationIsValid: { capturedRevision, checkPoint in
                    events.append("validate-destination-\(checkPoint)")
                    guard interactionRevision == capturedRevision else { return false }
                    switch path {
                    case .limitedAXSelection, .focusedCmdA:
                        return sourceAppIsFrontmost && focusedTargetMatches
                    case .slackAXFree:
                        return sourceAppIsFrontmost && slackTypingFocusEvidenceIsStable
                    }
                },
                simulateSelectAll: {
                    events.append("select-all")
                },
                pauseAfterSelectAll: {
                    events.append("select-all-settled")
                    currentClipboard = copyDuringSelectAllWait
                    changeCount += 1
                },
                snapshotClipboard: {
                    events.append("snapshot")
                    return currentClipboard
                },
                promoteSnapshot: {
                    events.append("promote-snapshot")
                    promotedSnapshot = $0
                },
                changeCount: { changeCount },
                simulateCopy: {
                    events.append("copy")
                    currentClipboard = exactDraftCopy
                    changeCount += 1
                },
                pauseAfterCopy: {
                    events.append("copy-settled")
                    switch loss {
                    case .sourceApp:
                        sourceAppIsFrontmost = false
                    case .focusedTarget:
                        focusedTargetMatches = false
                    case .slackTypingFocusEvidence:
                        slackTypingFocusEvidenceIsStable = false
                    case .interactionRevision:
                        interactionRevision += 1
                    }
                },
                readString: {
                    events.append("read-copy")
                    return "Captured draft"
                },
                writeCorrection: { _ in
                    correctionWriteCount += 1
                    events.append("write-correction")
                },
                simulatePaste: {
                    pasteCount += 1
                    events.append("paste")
                }
            )
        )

        XCTAssertEqual(attempt.failure, .clipboardPreservedRecoveryRequired)
        XCTAssertNil(attempt.beanClipboardChangeCount)
        XCTAssertEqual(correctionWriteCount, 0, "\(path.label) must not overwrite the clipboard after destination loss")
        XCTAssertEqual(pasteCount, 0, "\(path.label) must not paste after destination loss")
        XCTAssertEqual(currentClipboard, exactDraftCopy, "\(path.label) must leave the current clipboard untouched on loss")
        XCTAssertFalse(events.contains("write-correction"))
        XCTAssertFalse(events.contains("paste"))

        let expectedRestore = path.usesSelectAll ? copyDuringSelectAllWait : beforeSelectAll
        XCTAssertEqual(attempt.clipboardToRestore, expectedRestore)
        XCTAssertEqual(promotedSnapshot, expectedRestore)
        if path.usesSelectAll {
            let settledIndex = try? XCTUnwrap(events.firstIndex(of: "select-all-settled"))
            let snapshotIndex = try? XCTUnwrap(events.firstIndex(of: "snapshot"))
            let copyIndex = try? XCTUnwrap(events.firstIndex(of: "copy"))
            XCTAssertNotNil(settledIndex)
            XCTAssertNotNil(snapshotIndex)
            XCTAssertNotNil(copyIndex)
            if let settledIndex, let snapshotIndex, let copyIndex {
                XCTAssertLessThan(settledIndex, snapshotIndex)
                XCTAssertLessThan(snapshotIndex, copyIndex)
            }
        }
        let copySettledIndex = try? XCTUnwrap(events.firstIndex(of: "copy-settled"))
        let finalValidationIndex = events.lastIndex(of: "validate-destination-beforePaste")
        XCTAssertNotNil(copySettledIndex)
        XCTAssertNotNil(finalValidationIndex)
        if let copySettledIndex, let finalValidationIndex {
            XCTAssertLessThan(copySettledIndex, finalValidationIndex)
        }
    }

    @MainActor
    func testFocusedCmdARevalidationRestoresCopyMadeDuringSelectAllWait() {
        assertSelectAllWaitCopyBecomesRestoreSnapshot(path: "focused Cmd+A")
    }

    @MainActor
    func testSlackAXFreeRevalidationRestoresCopyMadeDuringSelectAllWait() {
        assertSelectAllWaitCopyBecomesRestoreSnapshot(path: "AX-free Slack")
    }

    @MainActor
    private func assertSelectAllWaitCopyBecomesRestoreSnapshot(path: String) {
        let stringType = NSPasteboard.PasteboardType.string.rawValue
        let beforeSelectAllWait: ClipboardService.Snapshot = [[
            stringType: Data("Clipboard before Select All".utf8)
        ]]
        let copyDuringSelectAllWait: ClipboardService.Snapshot = [[
            stringType: Data("User copy during Select All settle delay".utf8)
        ]]
        let beanCorrection: ClipboardService.Snapshot = [[
            stringType: Data("Bean temporary correction".utf8)
        ]]

        let postWaitRestoreSnapshot = TextSelectionService.clipboardSnapshotToRestore(
            originalSaved: beforeSelectAllWait,
            currentSnapshot: copyDuringSelectAllWait,
            acquisitionOwnedChangeCount: 30,
            currentChangeCount: 31
        )
        XCTAssertEqual(
            postWaitRestoreSnapshot,
            copyDuringSelectAllWait,
            "\(path) must promote the clipboard after the Select-All wait and before Cmd+C"
        )

        var current = beanCorrection
        TextSelectionService.applyClipboardCompletion(
            .restoreOriginal,
            saved: postWaitRestoreSnapshot,
            clipboardStillOwned: true,
            restoreClipboard: { current = $0 }
        )
        XCTAssertEqual(
            current,
            copyDuringSelectAllWait,
            "\(path) successful paste must restore the copy made during the Select-All wait"
        )
    }

    @MainActor
    func testCancelAfterEveryRecopyFailureLeavesConcurrentClipboardUntouched() {
        let stringType = NSPasteboard.PasteboardType.string.rawValue
        let concurrentUserCopy: ClipboardService.Snapshot = [[
            stringType: Data("User copy during guarded Cmd+C wait".utf8)
        ]]
        let olderSaved: ClipboardService.Snapshot = [[
            stringType: Data("Clipboard before guarded Cmd+C".utf8)
        ]]

        for path in ["selection", "focused Cmd+A field", "AX-free Slack field"] {
            var current = concurrentUserCopy
            let result = TextSelectionService.clipboardRevalidationFailure(
                expected: "Captured text",
                copied: "Concurrent clipboard text",
                clipboardDidChange: true
            )
            XCTAssertEqual(result, .clipboardPreservedRecoveryRequired)
            XCTAssertEqual(
                TextSelectionService.clipboardCompletion(
                    for: .clipboardPreservedRecoveryRequired
                ),
                .noAction
            )
            XCTAssertFalse(
                TextSelectionService.restoreClipboardIfOwned(
                    olderSaved,
                    beanOwnedChangeCount: nil,
                    currentChangeCount: { 21 },
                    restoreClipboard: { current = $0 }
                )
            )
            XCTAssertEqual(current, concurrentUserCopy, "\(path) Cancel must preserve the concurrent copy")
        }
    }

    @MainActor
    func testExplicitFallbackAccuratelyLeavesTheCorrectionOnClipboard() {
        for result in [
            TextSelectionService.ReplacementResult.copiedToClipboardFallback,
            .staleCopiedToClipboard
        ] {
            let stringType = NSPasteboard.PasteboardType.string.rawValue
            let saved: ClipboardService.Snapshot = [[
                stringType: Data("User clipboard".utf8)
            ]]
            var current: ClipboardService.Snapshot = [[
                stringType: Data("The safe correction".utf8)
            ]]
            var restoreCount = 0

            TextSelectionService.applyClipboardCompletion(
                TextSelectionService.clipboardCompletion(for: result),
                saved: saved,
                clipboardStillOwned: true,
                restoreClipboard: {
                    restoreCount += 1
                    current = $0
                }
            )

            XCTAssertEqual(
                current.first?[stringType],
                Data("The safe correction".utf8)
            )
            XCTAssertEqual(restoreCount, 0)
            XCTAssertEqual(
                TextSelectionService.clipboardCompletion(for: result),
                .keepCorrection
            )
            XCTAssertEqual(
                TextSelectionService.replacementResultAfterClipboardCompletion(
                    result,
                    clipboardStillOwned: true
                ),
                result
            )
        }
    }

    @MainActor
    func testFallbackNeverOverwritesConcurrentUserCopyAndReportsPreviewOnlyRecovery() {
        let stringType = NSPasteboard.PasteboardType.string.rawValue
        let saved: ClipboardService.Snapshot = [[
            stringType: Data("Clipboard before Bean".utf8)
        ]]
        let newerUserCopy: ClipboardService.Snapshot = [[
            stringType: Data("User copied this during Bean's paste".utf8)
        ]]

        for result in [
            TextSelectionService.ReplacementResult.copiedToClipboardFallback,
            .staleCopiedToClipboard
        ] {
            var current = newerUserCopy
            var restoreCount = 0
            TextSelectionService.applyClipboardCompletion(
                TextSelectionService.clipboardCompletion(for: result),
                saved: saved,
                clipboardStillOwned: false,
                restoreClipboard: {
                    restoreCount += 1
                    current = $0
                }
            )

            XCTAssertEqual(current, newerUserCopy)
            XCTAssertEqual(restoreCount, 0)
            XCTAssertEqual(
                TextSelectionService.replacementResultAfterClipboardCompletion(
                    result,
                    clipboardStillOwned: false
                ),
                .clipboardPreservedRecoveryRequired
            )
        }
    }

    func testPassiveUnconfirmedReplacementRemainsPersistentlyRecoverable() {
        let unconfirmed = PassiveSuggestionService.replacementRecoveryPolicy(
            for: .replacementSentUnconfirmed
        )
        XCTAssertTrue(unconfirmed.isPersistent)
        XCTAssertFalse(unconfirmed.correctionIsOnClipboard)
        XCTAssertFalse(unconfirmed.allowsRetry)

        let copiedFallback = PassiveSuggestionService.replacementRecoveryPolicy(
            for: .copiedToClipboardFallback
        )
        XCTAssertTrue(copiedFallback.isPersistent)
        XCTAssertTrue(copiedFallback.correctionIsOnClipboard)
        XCTAssertTrue(copiedFallback.allowsRetry)

        let concurrentCopyFallback = PassiveSuggestionService.replacementRecoveryPolicy(
            for: .clipboardPreservedRecoveryRequired
        )
        XCTAssertTrue(concurrentCopyFallback.isPersistent)
        XCTAssertFalse(concurrentCopyFallback.correctionIsOnClipboard)
        XCTAssertTrue(concurrentCopyFallback.allowsRetry)
        XCTAssertEqual(
            TextSelectionService.clipboardCompletion(
                for: .clipboardPreservedRecoveryRequired
            ),
            .noAction
        )
    }

    func testPassiveApplyRequiresTheExactReactivatedTargetAndValue() {
        XCTAssertNil(
            PassiveSuggestionService.passiveTargetContinuityFailure(
                currentTargetExists: true,
                targetsMatch: true,
                valueBefore: "  Exact draft\n",
                valueNow: "  Exact draft\n"
            )
        )
        XCTAssertEqual(
            PassiveSuggestionService.passiveTargetContinuityFailure(
                currentTargetExists: false,
                targetsMatch: false,
                valueBefore: "Exact draft",
                valueNow: "Exact draft"
            ),
            .staleCopiedToClipboard
        )
        XCTAssertEqual(
            PassiveSuggestionService.passiveTargetContinuityFailure(
                currentTargetExists: true,
                targetsMatch: false,
                valueBefore: "Exact draft",
                valueNow: "Exact draft"
            ),
            .staleCopiedToClipboard
        )
        XCTAssertEqual(
            PassiveSuggestionService.passiveTargetContinuityFailure(
                currentTargetExists: true,
                targetsMatch: true,
                valueBefore: "Exact draft",
                valueNow: "Exact draft "
            ),
            .staleCopiedToClipboard,
            "Passive apply must compare exact text, not a fingerprint or trimmed value"
        )
    }

}

private enum GuardedTestPath: CaseIterable {
    case limitedAXSelection
    case focusedCmdA
    case slackAXFree

    var usesSelectAll: Bool {
        switch self {
        case .limitedAXSelection: false
        case .focusedCmdA, .slackAXFree: true
        }
    }

    var label: String {
        switch self {
        case .limitedAXSelection: "limited-AX selection"
        case .focusedCmdA: "focused Cmd+A field"
        case .slackAXFree: "AX-free Slack field"
        }
    }
}

private enum GuardedTestLoss {
    case sourceApp
    case focusedTarget
    case slackTypingFocusEvidence
    case interactionRevision
}
