import AppKit
import SwiftUI
import XCTest
@testable import Bean

/// Renders only repository views with synthetic state. No application focus,
/// AX inspection, global input or external windows are used.
@MainActor
final class NativeAssistantViewTests: XCTestCase {
    func testProductionPanelsAndBadgesFitAndExportReviewableSyntheticSnapshots() throws {
        _ = NSApplication.shared
        let cases: [(String, NativeAssistantState)] = [
            ("checking", NativeAssistantState(phase: .checkingLocal, aiAvailable: true, canChooseParagraph: true)),
            ("basic-complete", NativeAssistantState(phase: .complete, canChooseParagraph: true)),
            ("issues", NativeAssistantState(phase: .complete, issueCount: 3, aiAvailable: true,
                safeFixCount: 2, canUndo: true, canPauseApp: true, canChooseParagraph: true)),
            ("partial", NativeAssistantState(phase: .complete, canChooseParagraph: true, localLimitation: "limitReached")),
            ("unavailable", NativeAssistantState(phase: .unavailable("cannotReadText"), aiAvailable: true)),
            ("selection", NativeAssistantState(phase: .complete, issueCount: 1, scope: "selected text", aiAvailable: true))
        ]
        let output = ProcessInfo.processInfo.environment["BEAN_QA_OUTPUT_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for scheme in [ColorScheme.light, .dark] {
            for (name, state) in cases {
                let root = VStack(alignment: .leading, spacing: 18) {
                    NativeAssistantBadgeView(state: state, onOpen: {}, onKeyboardOpen: {})
                    NativeAssistantPanelView(state: state, onReview: {}, onAction: { _, _ in },
                        onFixAll: {}, onUndo: {}, onPause: {}, onClose: {})
                }
                .padding(24)
                .background(BeanDesign.cardBackground)
                .environment(\.colorScheme, scheme)
                let view = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = view
                let size = view.fittingSize
                XCTAssertGreaterThan(size.width, 320)
                XCTAssertLessThan(size.width, 430)
                XCTAssertGreaterThan(size.height, 300)
                XCTAssertLessThan(size.height, 650, "The full assistant must remain compact and fit on a laptop screen.")
                window.setContentSize(size)
                view.layoutSubtreeIfNeeded()
                if let output {
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: output.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
                }
                window.close()
            }
        }
    }

    func testNativeOverlayPanelsCannotTakeKeyboardFocusWithoutExplicitActivation() {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        for intent in [OverlayActivationIntent.passiveHover, .pointer, .explicit] {
            panel.allowsKeyInteraction = intent.allowsKeyboardInteraction
            XCTAssertEqual(panel.canBecomeKey, intent == .explicit)
            XCTAssertFalse(panel.canBecomeMain)
        }
    }

    func testActualQuietOverlayRenderingKeepsOwnedEditorFirstResponder() {
        let editorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        editorWindow.isReleasedWhenClosed = false
        let text = NSTextField(string: "Synthetic draft with teh typo.")
        editorWindow.contentView = text
        XCTAssertTrue(editorWindow.makeFirstResponder(text))
        let originalResponder = editorWindow.firstResponder
        let originalKeyWindow = NSApplication.shared.keyWindow
        let controller = HighlightOverlayController()
        defer { controller.hide(); editorWindow.close() }
        controller.assistantState = NativeAssistantState(phase: .checkingLocal)
        controller.render(entries: [], selectedID: nil, position: nil)
        XCTAssertTrue(editorWindow.firstResponder === originalResponder)
        XCTAssertTrue(NSApplication.shared.keyWindow === originalKeyWindow)
        let issue = TextIssue(range: NSRange(location: 21, length: 3), original: "teh", suggestion: "the",
            explanation: nil, type: .spelling, confidence: 1, source: .local)
        controller.assistantState = NativeAssistantState(phase: .complete, issueCount: 1)
        controller.render(entries: [.init(issue: issue, rect: nil)], selectedID: nil, position: nil)
        XCTAssertFalse(controller.ownsKeyboardInteraction)
        XCTAssertTrue(editorWindow.firstResponder === originalResponder)
        XCTAssertTrue(NSApplication.shared.keyWindow === originalKeyWindow)
    }
}
