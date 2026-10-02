import AppKit
import SwiftUI

/// Native text editing keeps standard selection, clipboard, keyboard undo and
/// accessibility behavior while Bean draws reviewable ranges in the document.
struct WritingTextEditor: NSViewRepresentable {
    struct FocusRequest: Equatable {
        let id = UUID()
        let range: NSRange
    }

    let text: String
    let issues: [TextIssue]
    let selectedIssueID: UUID?
    let focusRequest: FocusRequest?
    let onEdit: (String) -> Void
    let onSelectIssue: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let editor = ReviewTextView()
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.font = .systemFont(ofSize: 17)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.insertionPointColor = .textColor
        editor.textContainerInset = NSSize(width: 32, height: 28)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Writing draft")
        editor.setAccessibilityHelp("Write or paste your draft. Click an underlined word to review its suggestion.")
        editor.string = text
        editor.onClickIssue = { [weak coordinator = context.coordinator] id in
            coordinator?.parent.onSelectIssue(id)
        }
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? ReviewTextView,
              let storage = editor.textStorage else { return }
        context.coordinator.parent = self
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        if editor.string != text {
            let selection = editor.selectedRange()
            // insertText registers programmatic accepts/rewrites with native
            // undo, just as typing does. A draft opened from disk is handled by
            // the model, while Undo Suggestion also remains explicitly available.
            let before = editor.string
            let edit = WritingEditorChange.between(before, and: text)
            editor.breakUndoCoalescing()
            editor.insertText(edit.replacement, replacementRange: edit.range)
            editor.breakUndoCoalescing()
            let restoredSelection = InlineIssueMapping.selectionAfterReplacing(
                edit.range, replacementLength: (edit.replacement as NSString).length,
                selection: selection, originalLength: (before as NSString).length
            ) ?? NSRange(location: min(selection.location, storage.length), length: 0)
            editor.setSelectedRange(restoredSelection)
        }
        let entire = NSRange(location: 0, length: storage.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        storage.beginEditing()
        storage.setAttributes([
            .font: NSFont.systemFont(ofSize: 17),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph
        ], range: entire)
        editor.reviewIssues = issues
        for issue in issues where WritingWorkspaceModel.matches(issue, in: editor.string) {
            let color = issue.type == .clarity ? NSColor.systemBlue : NSColor.systemRed
            storage.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: color,
                .toolTip: issue.explanation ?? "Review this suggestion"
            ], range: issue.range)
            if issue.id == selectedIssueID {
                storage.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.08), range: issue.range)
            }
        }
        storage.endEditing()
        editor.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 17),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph
        ]
        if let focusRequest, context.coordinator.lastFocusID != focusRequest.id {
            context.coordinator.lastFocusID = focusRequest.id
            let range = focusRequest.range
            if range.location <= storage.length, range.length <= storage.length - range.location {
                editor.setSelectedRange(range)
                editor.scrollRangeToVisible(range)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WritingTextEditor
        var isUpdating = false
        var lastFocusID: UUID?

        init(parent: WritingTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let editor = notification.object as? NSTextView else { return }
            parent.onEdit(editor.string)
        }
    }
}

/// The smallest edit on Character boundaries avoids replacing the complete
/// document for each accepted typo, preserves the caret, and makes native
/// keyboard undo an individual correction rather than a lost draft.
struct WritingEditorChange: Equatable {
    let range: NSRange
    let replacement: String

    static func between(_ old: String, and new: String) -> WritingEditorChange {
        let before = Array(old)
        let after = Array(new)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        let leading = String(before.prefix(prefix))
        let removed = String(before[prefix..<(before.count - suffix)])
        return WritingEditorChange(
            range: NSRange(location: (leading as NSString).length, length: (removed as NSString).length),
            replacement: String(after[prefix..<(after.count - suffix)])
        )
    }
}

private final class ReviewTextView: NSTextView {
    var reviewIssues: [TextIssue] = []
    var onClickIssue: ((UUID) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let selection = selectedRange()
        if let issue = reviewIssues.first(where: {
            NSLocationInRange(selection.location, $0.range)
        }) {
            onClickIssue?(issue.id)
        }
    }
}
