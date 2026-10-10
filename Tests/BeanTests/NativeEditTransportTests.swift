import AppKit
import XCTest
@testable import Bean

/// The editor belongs to this test process. No external app, clipboard, or
/// synthetic keyboard events are used; commands enter its ordinary edit model.
@MainActor
final class NativeEditTransportTests: XCTestCase {
    func testTransportDistinguishesAdvertisedWebSettersFromNativeSetters() {
        let cases: [(String?, Bool, Bool, NativeEditTransport)] = [
            ("com.tinyspeck.slackmacgap", true, false, .keyboard),
            ("com.tinyspeck.slackmacgap", true, true, .keyboard),
            ("com.hnc.Discord", true, false, .keyboard),
            ("com.google.Chrome", true, false, .keyboard),
            ("com.apple.Safari", true, true, .keyboard),
            ("org.mozilla.firefox", true, true, .keyboard),
            ("test.unknown-web-editor", true, true, .keyboard),
            (nil, true, true, .keyboard),
            ("com.apple.TextEdit", true, false, .accessibilitySelectedText),
            ("com.apple.Notes", true, false, .accessibilitySelectedText),
            ("test.native-editor", true, false, .accessibilitySelectedText),
            (nil, true, false, .accessibilitySelectedText),
            // A read-only AXSelectedText attribute does not prohibit normal
            // commands in an independently verified editable destination.
            ("com.apple.TextEdit", false, false, .keyboard),
            ("com.tinyspeck.slackmacgap", false, false, .keyboard)
        ]
        for (bundle, settable, webContent, expected) in cases {
            XCTAssertEqual(NativeEditTransport.preferred(bundleIdentifier: bundle,
                selectedTextSettable: settable, isWebContent: webContent), expected,
                "bundle=\(bundle ?? "nil"), setter=\(settable), web=\(webContent)")
        }
    }

    func testSlackScreenshotTypoUsesOneExactDeleteDespiteAdvertisedSetter() async throws {
        let original = "looks like the text replacement is broken agamin"
        let corrected = "looks like the text replacement is broken again"
        let editor = Editor(text: NSAttributedString(string: original))
        editor.view.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
        let capturedCaret = editor.view.selectedRange()
        let plan = try XCTUnwrap(NativeEditPlan.proofread(original: original, corrected: corrected))
        let typo = (original as NSString).range(of: "agamin")
        let deletion = NativeTextEdit(range: NSRange(location: typo.location + 3, length: 1),
                                      original: "m", replacement: "")
        XCTAssertEqual(plan.edits, [deletion])

        let outcome = await NativeEditTransaction.run(plan: plan, capturedSelection: capturedCaret,
            effects: editor.effects(bundleIdentifier: "com.tinyspeck.slackmacgap",
                                    selectedTextSettable: true, isWebContent: false))

        XCTAssertEqual(outcome.result, .replacedConfirmed)
        XCTAssertEqual(editor.view.string, corrected)
        XCTAssertEqual(editor.keyboardEdits, [deletion])
        XCTAssertEqual(editor.deleteCommands, 1)
        XCTAssertEqual(editor.setterCalls, 0)
        XCTAssertEqual(outcome.confirmedEdits, [deletion])
        XCTAssertEqual(plan.selectionAfterEdits(capturedCaret),
                       NSRange(location: (corrected as NSString).length, length: 0))
        XCTAssertTrue(TextSelectionService.shouldRestoreSelectionAfterPaste(
            current: editor.view.selectedRange(),
            replacementRange: try XCTUnwrap(outcome.lastReplacementRange)))
        XCTAssertTrue(editor.view.ownUndoManager.canUndo)
        editor.view.ownUndoManager.undo()
        XCTAssertEqual(editor.view.string, original)
    }

    func testSlackKeyboardEditsPreserveRichSurroundingsForReplacementDeletionAndInsertion() async throws {
        let source = NSMutableAttributedString(string: "👩🏽‍💻 teh draft agamin\nVisit example.test\nAttachment: ")
        source.addAttribute(.font, value: NSFont.systemFont(ofSize: 15),
                            range: NSRange(location: 0, length: source.length))
        let bold = (source.string as NSString).range(of: "draft")
        source.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 15), range: bold)
        let link = (source.string as NSString).range(of: "example.test")
        source.addAttribute(.link, value: URL(string: "https://example.test")!, range: link)
        let attachment = NSTextAttachment()
        source.append(NSAttributedString(attachment: attachment))
        source.append(NSAttributedString(string: "\nReady"))
        let before = NSAttributedString(attributedString: source)
        let editor = Editor(text: before)
        let capturedCaret = NSRange(location: link.location, length: 0)
        editor.view.setSelectedRange(capturedCaret)
        let corrected = source.string.replacingOccurrences(of: "teh", with: "the")
            .replacingOccurrences(of: "agamin", with: "again") + "."
        let plan = try XCTUnwrap(NativeEditPlan.proofread(original: source.string, corrected: corrected))
        XCTAssertEqual(plan.edits.map(\.original), ["eh", "m", ""])
        XCTAssertEqual(plan.edits.map(\.replacement), ["he", "", "."])

        let outcome = await NativeEditTransaction.run(plan: plan, capturedSelection: capturedCaret,
            effects: editor.effects(bundleIdentifier: "com.tinyspeck.slackmacgap",
                                    selectedTextSettable: true, isWebContent: true))

        XCTAssertEqual(outcome.result, .replacedConfirmed)
        XCTAssertEqual(editor.view.string, corrected)
        XCTAssertEqual(editor.keyboardEdits, Array(plan.edits.reversed()))
        XCTAssertEqual(editor.deleteCommands, 1)
        XCTAssertEqual(editor.setterCalls, 0)
        let storage = try XCTUnwrap(editor.view.textStorage)
        let currentBold = (corrected as NSString).range(of: "draft")
        let currentLink = (corrected as NSString).range(of: "example.test")
        XCTAssertTrue(storage.attributedSubstring(from: currentBold).isEqual(to: before.attributedSubstring(from: bold)))
        XCTAssertTrue(storage.attributedSubstring(from: currentLink).isEqual(to: before.attributedSubstring(from: link)))
        let attachmentRange = (corrected as NSString).range(of: "\u{fffc}")
        XCTAssertTrue(storage.attribute(.attachment, at: attachmentRange.location, effectiveRange: nil)
                      as? NSTextAttachment === attachment)
        XCTAssertEqual(plan.selectionAfterEdits(capturedCaret),
                       NSRange(location: currentLink.location, length: 0))
        XCTAssertTrue(editor.view.ownUndoManager.canUndo)
        for _ in plan.edits { editor.view.ownUndoManager.undo() }
        XCTAssertTrue(storage.isEqual(to: before), "Native Undo restores the exact attributed draft")
    }

    func testNativeTextViewStillUsesItsSupportedSelectedTextSetter() async throws {
        let editor = Editor(text: NSAttributedString(string: "teh draft"))
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        let plan = try XCTUnwrap(NativeEditPlan.proofread(original: editor.view.string, corrected: "the draft"))
        let outcome = await NativeEditTransaction.run(plan: plan, capturedSelection: editor.view.selectedRange(),
            effects: editor.effects(bundleIdentifier: "com.apple.TextEdit",
                                    selectedTextSettable: true, isWebContent: false,
                                    permitNativeSetter: true))
        XCTAssertEqual(outcome.result, .replacedConfirmed)
        XCTAssertEqual(editor.view.string, "the draft")
        XCTAssertTrue(editor.keyboardEdits.isEmpty)
        XCTAssertEqual(editor.setterCalls, 1)
    }

    private final class RichTextView: NSTextView {
        let ownUndoManager = UndoManager()
        override var undoManager: UndoManager? { ownUndoManager }
    }

    @MainActor
    private final class Editor {
        let view = RichTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        var keyboardEdits: [NativeTextEdit] = []
        var deleteCommands = 0
        var setterCalls = 0

        init(text: NSAttributedString) {
            view.isRichText = true
            view.allowsUndo = true
            view.ownUndoManager.groupsByEvent = false
            view.textStorage?.setAttributedString(text)
        }

        func effects(bundleIdentifier: String, selectedTextSettable: Bool, isWebContent: Bool,
                     permitNativeSetter: Bool = false) -> NativeEditTransaction.Effects {
            let transport = NativeEditTransport.preferred(bundleIdentifier: bundleIdentifier,
                selectedTextSettable: selectedTextSettable, isWebContent: isWebContent)
            let setter: ((String) -> Bool)? = transport == .accessibilitySelectedText ? { replacement in
                self.setterCalls += 1
                guard permitNativeSetter else {
                    XCTFail("A web editor's advertised setter must never be attempted")
                    return false
                }
                self.view.ownUndoManager.beginUndoGrouping()
                self.view.setAccessibilitySelectedText(replacement)
                self.view.ownUndoManager.endUndoGrouping()
                return true
            } : nil
            return .init(destinationIsValid: { true }, readValue: { self.view.string },
                selectedRange: { self.view.selectedRange() },
                setSelectedRange: { self.view.setSelectedRange($0); return true },
                sendEdit: { replacement in
                    XCTAssertFalse(permitNativeSetter, "Supported native setters keep their direct transport")
                    let range = self.view.selectedRange()
                    self.keyboardEdits.append(.init(range: range,
                        original: (self.view.string as NSString).substring(with: range), replacement: replacement))
                    self.view.ownUndoManager.beginUndoGrouping()
                    if replacement.isEmpty {
                        self.deleteCommands += 1
                        self.view.deleteBackward(nil)
                    } else {
                        self.view.insertText(replacement, replacementRange: range)
                    }
                    self.view.ownUndoManager.endUndoGrouping()
                },
                verify: { _, expected in
                    self.view.string.utf16.elementsEqual(expected.utf16) ? .replacedConfirmed : .replacementSentUnconfirmed
                },
                readSelectedText: { (self.view.string as NSString).substring(with: self.view.selectedRange()) },
                replaceSelectedText: setter)
        }
    }
}
