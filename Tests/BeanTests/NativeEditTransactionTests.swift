import AppKit
import XCTest
@testable import Bean

@MainActor
final class NativeEditTransactionTests: XCTestCase {
    private final class Model {
        var text = "teh first and teh second"
        var selection = NSRange(location: 4, length: 0)
        var destinationValid = true
        var rangesAreWritable = true
        var sentRanges: [NSRange] = []
        var sentText: [String] = []
        var afterEdit: (() -> Void)?
        var verificationResult: TextSelectionService.ReplacementResult = .replacedConfirmed

        var effects: NativeEditTransaction.Effects {
            .init(destinationIsValid: { self.destinationValid }, readValue: { self.text },
                selectedRange: { self.selection },
                setSelectedRange: { range in
                    guard self.rangesAreWritable else { return false }
                    self.selection = range; return true
                },
                sendEdit: { replacement in
                    self.sentRanges.append(self.selection); self.sentText.append(replacement)
                    self.text = (self.text as NSString).replacingCharacters(in: self.selection, with: replacement)
                    self.selection = NSRange(location: self.selection.location + (replacement as NSString).length, length: 0)
                    self.afterEdit?()
                },
                verify: { _, expected in
                    self.verificationResult == .replacedConfirmed && self.text.utf16.elementsEqual(expected.utf16)
                        ? .replacedConfirmed : .replacementSentUnconfirmed
                })
        }
    }

    func testBatchUsesOriginalOffsetsBackwardsAndConfirmsWholeResult() async throws {
        let model = Model()
        let plan = try XCTUnwrap(NativeEditPlan.proofread(original: model.text, corrected: "the first and the second"))
        let result = await NativeEditTransaction.run(plan: plan, capturedSelection: model.selection, effects: model.effects)
        XCTAssertEqual(result.result, .replacedConfirmed)
        XCTAssertEqual(result.confirmedValue, plan.replacement)
        XCTAssertEqual(model.sentRanges, plan.edits.reversed().map(\.range))
        XCTAssertTrue(model.sentRanges.allSatisfy { $0.length == 2 }, "No full-field paste is allowed")
    }

    func testFocusRaceAfterFirstEditStopsBeforeChangingNextSpan() async throws {
        let model = Model()
        model.afterEdit = { model.destinationValid = false }
        let plan = try XCTUnwrap(NativeEditPlan.proofread(original: model.text, corrected: "the first and the second"))
        let result = await NativeEditTransaction.run(plan: plan, capturedSelection: model.selection, effects: model.effects)
        XCTAssertEqual(model.sentRanges.count, 1)
        XCTAssertEqual(result.confirmedEdits.count, 1)
        XCTAssertEqual(result.confirmedValue, "teh first and the second")
        if case .failed = result.result {} else { XCTFail("An interrupted batch must not claim completion") }
        let partial = try XCTUnwrap(NativeEditPlan.validated(original: plan.original, edits: result.confirmedEdits))
        XCTAssertEqual(partial.replacement, result.confirmedValue)
    }

    func testUserCaretMovementBetweenSpansIsNeverOverwritten() async throws {
        let model = Model()
        model.afterEdit = { model.selection = NSRange(location: 0, length: 0) }
        let plan = try XCTUnwrap(NativeEditPlan.proofread(original: model.text, corrected: "the first and the second"))
        let result = await NativeEditTransaction.run(plan: plan, capturedSelection: model.selection, effects: model.effects)
        XCTAssertEqual(model.sentRanges.count, 1)
        XCTAssertEqual(model.selection, NSRange(location: 0, length: 0))
        XCTAssertNotEqual(result.result, .replacedConfirmed)
    }

    func testChangedCapturedCaretOrCanonicalSourcePreventsAnyEdit() async throws {
        let model = Model()
        let plan = try XCTUnwrap(NativeEditPlan.proofread(original: model.text, corrected: "the first and the second"))
        let result = await NativeEditTransaction.run(plan: plan, capturedSelection: NSRange(location: 0, length: 0), effects: model.effects)
        XCTAssertFalse(result.editWasSent)
        XCTAssertTrue(model.sentRanges.isEmpty)
        model.text = "cafe\u{301} teh"
        let canonical = try XCTUnwrap(NativeEditPlan.proofread(original: "café teh", corrected: "café the"))
        let changed = await NativeEditTransaction.run(plan: canonical, capturedSelection: nil, effects: model.effects)
        XCTAssertFalse(changed.editWasSent)
    }

    func testFailedRangeSetterAndUncertainPasteNeverBroadenOrRetry() async throws {
        let model = Model()
        let plan = try XCTUnwrap(NativeEditPlan.proofread(original: model.text, corrected: "the first and the second"))
        model.rangesAreWritable = false
        let unsupported = await NativeEditTransaction.run(plan: plan, capturedSelection: nil, effects: model.effects)
        XCTAssertFalse(unsupported.editWasSent)
        model.rangesAreWritable = true
        model.verificationResult = .replacementSentUnconfirmed
        let uncertain = await NativeEditTransaction.run(plan: plan, capturedSelection: nil, effects: model.effects)
        XCTAssertEqual(uncertain.result, .replacementSentUnconfirmed)
        XCTAssertEqual(model.sentRanges.count, 1)
        XCTAssertTrue(uncertain.confirmedEdits.isEmpty)
    }

    private final class RichTextView: NSTextView {
        let ownUndoManager = UndoManager()
        override var undoManager: UndoManager? { ownUndoManager }
    }

    func testOwnedRichEditorPreservesUnchangedAttributesAttachmentAndNativeUndo() async throws {
        let view = RichTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        view.isRichText = true
        view.allowsUndo = true
        view.ownUndoManager.groupsByEvent = false
        let original = NSMutableAttributedString(string: "teh first\nVisit example.com\nAttachment: ")
        original.addAttribute(.font, value: NSFont.systemFont(ofSize: 15), range: NSRange(location: 0, length: original.length))
        let linkRange = (original.string as NSString).range(of: "example.com")
        original.addAttribute(.link, value: URL(string: "https://example.com")!, range: linkRange)
        original.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: linkRange)
        let attachment = NSTextAttachment()
        original.append(NSAttributedString(attachment: attachment))
        original.append(NSAttributedString(string: "\nrecieved last"))
        try XCTUnwrap(view.textStorage).setAttributedString(original)
        view.setSelectedRange(NSRange(location: 5, length: 0))
        let before = NSAttributedString(attributedString: original)
        let corrected = original.string.replacingOccurrences(of: "teh", with: "the")
            .replacingOccurrences(of: "recieved", with: "received") + "."
        let plan = try XCTUnwrap(NativeEditPlan.proofread(original: original.string, corrected: corrected))
        var sentRanges: [NSRange] = []
        let effects = NativeEditTransaction.Effects(destinationIsValid: { true }, readValue: { view.string },
            selectedRange: { view.selectedRange() }, setSelectedRange: { view.setSelectedRange($0); return true },
            sendEdit: { replacement in
                sentRanges.append(view.selectedRange())
                view.ownUndoManager.beginUndoGrouping()
                view.insertText(replacement, replacementRange: view.selectedRange())
                view.ownUndoManager.endUndoGrouping()
            },
            verify: { _, expected in view.string.utf16.elementsEqual(expected.utf16) ? .replacedConfirmed : .replacementSentUnconfirmed })
        let clock = ContinuousClock()
        let started = clock.now
        let result = await NativeEditTransaction.run(plan: plan, capturedSelection: view.selectedRange(), effects: effects)
        let elapsed = started.duration(to: clock.now).components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000
        print("NATIVE_EDITOR_MODEL_TIMING changes=\(plan.edits.count) milliseconds=\(String(format: "%.3f", milliseconds)) AX_clipboard_transport=excluded")
        XCTAssertEqual(result.result, .replacedConfirmed)
        XCTAssertEqual(view.string, corrected)
        XCTAssertEqual(sentRanges.count, 3)
        let current = try XCTUnwrap(view.textStorage)
        let currentLinkRange = (view.string as NSString).range(of: "example.com")
        XCTAssertTrue(current.attributedSubstring(from: currentLinkRange).isEqual(to: before.attributedSubstring(from: linkRange)))
        let attachmentRange = (view.string as NSString).range(of: "\u{fffc}")
        XCTAssertTrue(current.attribute(.attachment, at: attachmentRange.location, effectiveRange: nil) as? NSTextAttachment === attachment)
        XCTAssertTrue(view.ownUndoManager.canUndo, "Ordinary native edits must register native Undo")
        for _ in 0..<plan.edits.count { view.ownUndoManager.undo() }
        XCTAssertTrue(current.isEqual(to: before), "Native Undo restores the exact attributed document")
    }

    func testSpanUndoRestoresDeletedTextWithoutPastingOverAttachment() async throws {
        let model = Model()
        model.text = "teh later!\nAttachment \u{fffc}\nEnd"
        model.selection = NSRange(location: 0, length: 0)
        let plan = try XCTUnwrap(NativeEditPlan.proofread(original: model.text, corrected: "the later\nAttachment \u{fffc}\nEnd."))
        let forward = await NativeEditTransaction.run(plan: plan, capturedSelection: model.selection, effects: model.effects)
        XCTAssertEqual(forward.result, .replacedConfirmed)
        let inverse = try XCTUnwrap(NativeEditPlan.validated(original: plan.replacement, edits: plan.inverseEdits))
        model.sentRanges = []
        let undo = await NativeEditTransaction.run(plan: inverse, capturedSelection: model.selection, effects: model.effects)
        XCTAssertEqual(undo.result, .replacedConfirmed)
        XCTAssertEqual(model.text, plan.original)
        XCTAssertTrue(model.sentRanges.contains { $0.length == 0 }, "Deleted text returns at an exact insertion caret")
        XCTAssertFalse(model.sentRanges.contains { $0.length == (plan.replacement as NSString).length })
    }

    func testUndoCanInsertIntoPreciselyVerifiedEmptyFieldThenClearIt() async throws {
        let model = Model()
        model.text = ""; model.selection = NSRange(location: 0, length: 0)
        let plan = try XCTUnwrap(NativeEditPlan.proofread(original: "", corrected: "Restored text"))
        let insertion = await NativeEditTransaction.run(plan: plan, capturedSelection: model.selection, effects: model.effects)
        XCTAssertEqual(insertion.result, .replacedConfirmed)
        XCTAssertEqual(model.sentRanges, [NSRange(location: 0, length: 0)])
        let inverse = try XCTUnwrap(NativeEditPlan.validated(original: plan.replacement, edits: plan.inverseEdits))
        let deletion = await NativeEditTransaction.run(plan: inverse, capturedSelection: model.selection, effects: model.effects)
        XCTAssertEqual(deletion.result, .replacedConfirmed)
        XCTAssertEqual(model.text, "")
    }
}
