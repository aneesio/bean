import Foundation

/// One guarded session, with no retry of a delivered edit. The editor receives
/// ordinary Paste/Delete commands on exact spans, retaining its own rich model
/// and native Undo. A source app may keep each span as a separate Undo step.
@MainActor
enum NativeEditTransaction {
    struct Effects {
        let destinationIsValid: () -> Bool
        let readValue: () -> String?
        let selectedRange: () -> NSRange?
        let setSelectedRange: (NSRange) -> Bool
        let sendEdit: (String) -> Void
        let verify: (_ before: String, _ expected: String) async -> TextSelectionService.ReplacementResult
        let readSelectedText: (() -> String?)?
        let replaceSelectedText: ((String) -> Bool)?
        let settleSelection: (() async -> Void)?

        init(destinationIsValid: @escaping () -> Bool, readValue: @escaping () -> String?,
             selectedRange: @escaping () -> NSRange?, setSelectedRange: @escaping (NSRange) -> Bool,
             sendEdit: @escaping (String) -> Void,
             verify: @escaping (String, String) async -> TextSelectionService.ReplacementResult,
             readSelectedText: (() -> String?)? = nil,
             replaceSelectedText: ((String) -> Bool)? = nil,
             settleSelection: (() async -> Void)? = nil) {
            self.destinationIsValid = destinationIsValid; self.readValue = readValue
            self.selectedRange = selectedRange; self.setSelectedRange = setSelectedRange
            self.sendEdit = sendEdit; self.verify = verify
            self.readSelectedText = readSelectedText; self.replaceSelectedText = replaceSelectedText
            self.settleSelection = settleSelection
        }
    }

    struct Outcome {
        let result: TextSelectionService.ReplacementResult
        /// Original-snapshot coordinates, only for edits verified individually.
        let confirmedEdits: [NativeTextEdit]
        let confirmedValue: String
        let lastReplacementRange: NSRange?
        let lastRequestedRange: NSRange?
        let editWasSent: Bool
    }

    static func run(plan: NativeEditPlan, capturedSelection: NSRange?, effects: Effects) async -> Outcome {
        var value = plan.original
        var confirmed: [NativeTextEdit] = []
        var lastReplacementRange: NSRange?
        var lastRequestedRange: NSRange?
        var sent = false
        func outcome(_ result: TextSelectionService.ReplacementResult) -> Outcome {
            Outcome(result: result, confirmedEdits: confirmed, confirmedValue: value,
                    lastReplacementRange: lastReplacementRange, lastRequestedRange: lastRequestedRange, editWasSent: sent)
        }
        guard !plan.edits.isEmpty else { return outcome(.noChangesNeeded) }
        guard effects.destinationIsValid(), exact(effects.readValue(), value),
              capturedSelection == nil || effects.selectedRange() == capturedSelection else {
            return outcome(.failed(reason: "The field or selection changed. Bean left the current text intact."))
        }
        for edit in plan.edits.reversed() {
            guard effects.destinationIsValid(), exact(effects.readValue(), value),
                  lastReplacementRange == nil || TextSelectionService.shouldRestoreSelectionAfterPaste(
                    current: effects.selectedRange(), replacementRange: lastReplacementRange!
                  ) else {
                return outcome(.failed(reason: confirmed.isEmpty
                    ? "The field changed. Bean left the current text intact."
                    : "Bean stopped after applying \(confirmed.count) changes because the editor changed."))
            }
            lastRequestedRange = edit.range
            guard let single = NativeEditPlan.validated(original: value, edits: [edit]),
                  effects.setSelectedRange(edit.range) else {
                return outcome(.failed(reason: confirmed.isEmpty
                    ? "This editor cannot safely target the correction. Select the text and try again."
                    : "Bean stopped after applying \(confirmed.count) changes because the next span could not be verified."))
            }
            // Selection changes can commit an editor's pending autocorrection.
            // Let its selection settle, then require both range and actual
            // selected text; an immediate cached range alone is insufficient.
            if let settle = effects.settleSelection { await settle() }
            guard effects.destinationIsValid(), exact(effects.readValue(), value),
                  effects.selectedRange() == edit.range,
                  effects.readSelectedText.map({ exact($0(), edit.original) }) ?? true else {
                return outcome(.failed(reason: confirmed.isEmpty
                    ? "The field or selection changed. Bean left the current text intact."
                    : "Bean stopped after applying \(confirmed.count) changes because the editor changed."))
            }
            // Prefer a supported synchronous selected-text edit. Never queue
            // Paste as a retry after a setter that might already have edited.
            if let replace = effects.replaceSelectedText {
                // A false AX result may mean timeout after delivery. Invocation
                // is an attempt; only exact readback decides confirmation.
                _ = replace(edit.replacement)
            } else {
                effects.sendEdit(edit.replacement)
            }
            sent = true
            let result = await effects.verify(value, single.replacement)
            guard result == .replacedConfirmed else {
                return outcome(.replacementSentUnconfirmed)
            }
            value = single.replacement
            confirmed.append(edit)
            lastReplacementRange = NSRange(location: edit.range.location,
                                            length: (edit.replacement as NSString).length)
        }
        guard exact(value, plan.replacement), exact(effects.readValue(), plan.replacement) else {
            return outcome(.replacementSentUnconfirmed)
        }
        return outcome(.replacedConfirmed)
    }

    private static func exact(_ left: String?, _ right: String) -> Bool {
        left.map { $0.utf16.elementsEqual(right.utf16) } == true
    }
}
