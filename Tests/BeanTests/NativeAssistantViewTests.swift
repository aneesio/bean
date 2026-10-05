import AppKit
import SwiftUI
import XCTest
@testable import Bean

/// Renders only repository views with synthetic state. No application focus,
/// external AX inspection, global input or external windows are used.
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

    func testCompactDotAndLegacyLauncherUseFixedTargetWithoutCountGrowth() async throws {
        _ = NSApplication.shared
        for count in [0, 1, 3, 99] {
            let state = NativeAssistantState(phase: .complete, issueCount: count)
            let root = NativeAssistantBadgeView(state: state, onOpen: {}, onKeyboardOpen: {})
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let view = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 28, height: 28),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = view
            XCTAssertEqual(view.fittingSize.width, 28, accuracy: 0.01)
            XCTAssertEqual(view.fittingSize.height, 28, accuracy: 0.01)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            if count > 0 {
                XCTAssertGreaterThan(center.redComponent, center.blueComponent + 0.2, "Suggestions fill the dot amber")
            } else {
                // cacheDisplay uses the current display's ColorSync profile.
                // Assert visible brown paint, rather than monitor-specific RGB.
                XCTAssertGreaterThan(center.redComponent, center.greenComponent + 0.15)
                XCTAssertGreaterThan(center.greenComponent, center.blueComponent + 0.10)
                XCTAssertLessThan(center.redComponent, 0.75,
                    "The default dot is filled brown, distinct from amber and a gray/empty ring")
            }
        }
        let legacy = NSHostingView(rootView: BeanBubbleView(openOnHover: false, onOpen: { _ in }, onDismiss: {}))
        XCTAssertEqual(legacy.fittingSize, CGSize(width: 28, height: 28))
        let dot = NSHostingView(rootView: NativeStatusDot(hasSuggestions: false))
        XCTAssertEqual(dot.fittingSize, CGSize(width: 10, height: 10))
    }

    func testUnknownAndCrowdedPlacementHideOnlyDotAndKeepUnderline() throws {
        _ = NSApplication.shared
        let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = HighlightOverlayController()
        defer { closeOwnedOverlay(controller, excluding: previousWindows) }
        let issue = TextIssue(range: NSRange(location: 0, length: 3), original: "teh", suggestion: "the",
            explanation: nil, type: .spelling, confidence: 1, source: .local)
        let entries = [HighlightOverlayController.Entry(issue: issue, rect: fixturePlacement.fieldRect.insetBy(dx: 30, dy: 20))]
        controller.render(entries: entries, selectedID: nil, position: nil)
        XCTAssertFalse(ownedPanels(excluding: previousWindows).contains { $0.accessibilityIdentifier() == "com.bean.overlay.field-control" })
        XCTAssertTrue(ownedPanels(excluding: previousWindows).contains { $0.accessibilityIdentifier().hasPrefix("com.bean.overlay.underline.") })
        controller.render(entries: entries, selectedID: nil, position: nil,
            sourceAnchor: self.fixturePlacement.fieldRect, placementGeometry: self.fixturePlacement)
        let control = try XCTUnwrap(ownedPanels(excluding: previousWindows).first { $0.accessibilityIdentifier() == "com.bean.overlay.field-control" })
        XCTAssertEqual(control.frame.size, CGSize(width: 28, height: 28))
        let crowded = FieldOverlayGeometry(fieldRect: fixturePlacement.fieldRect, windowRect: fixturePlacement.windowRect,
            exclusionRects: [fixturePlacement.validatedNeighborhood])
        controller.render(entries: entries, selectedID: nil, position: nil,
            sourceAnchor: crowded.fieldRect, placementGeometry: crowded)
        XCTAssertFalse(control.isVisible, "Moving a nearby control must remove the full pointer target")
        XCTAssertTrue(ownedPanels(excluding: previousWindows).contains { $0.isVisible && $0.accessibilityIdentifier().hasPrefix("com.bean.overlay.underline.") })
    }

    func testLegacyLauncherRefusesUnsafeSavedOffsetAndNewlyOccupiedDestination() {
        _ = NSApplication.shared
        let placement = fixturePlacement
        let visible = NSScreen.screens.first!.visibleFrame
        let origin = OverlayGeometry.issueTrayOrigin(geometry: placement,
            panelSize: CGSize(width: 28, height: 28), in: visible)!
        var occupied = false
        let controller = BeanBubbleController()
        defer { controller.hide() }
        let validate: (CGPoint) -> Bool = { point in
            !occupied && OverlayGeometry.isSafeFieldControlFrame(CGRect(origin: point, size: CGSize(width: 28, height: 28)),
                geometry: placement, in: visible)
        }
        controller.showBubble(at: origin, savedOffset: CGSize(width: 300, height: 0), openOnHover: false,
            isSafeOrigin: validate, onOpen: { _ in XCTFail("Placement must not open writing actions") },
            onDismiss: {}, onCommitOffset: { _ in }, onReset: {})
        XCTAssertFalse(controller.isShowing)
        controller.showBubble(at: origin, savedOffset: .zero, openOnHover: false,
            isSafeOrigin: validate, onOpen: { _ in XCTFail("Placement must not open writing actions") },
            onDismiss: {}, onCommitOffset: { _ in }, onReset: {})
        XCTAssertEqual(controller.bubbleFrame?.size, CGSize(width: 28, height: 28))
        occupied = true
        controller.moveBubble(to: origin)
        XCTAssertFalse(controller.isShowing, "An old position cannot survive a newly occupied target")
    }

    private var fixturePlacement: FieldOverlayGeometry {
        let visible = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return FieldOverlayGeometry(fieldRect: CGRect(x: visible.midX - 150, y: visible.midY - 50, width: 300, height: 100),
            windowRect: visible.insetBy(dx: 8, dy: 8), exclusionRects: [])
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
        controller.render(entries: [], selectedID: nil, position: nil, sourceAnchor: self.fixturePlacement.fieldRect, placementGeometry: self.fixturePlacement)
        XCTAssertTrue(editorWindow.firstResponder === originalResponder)
        XCTAssertTrue(NSApplication.shared.keyWindow === originalKeyWindow)
        let issue = TextIssue(range: NSRange(location: 21, length: 3), original: "teh", suggestion: "the",
            explanation: nil, type: .spelling, confidence: 1, source: .local)
        controller.assistantState = NativeAssistantState(phase: .complete, issueCount: 1)
        controller.render(entries: [.init(issue: issue, rect: nil)], selectedID: nil, position: nil, sourceAnchor: self.fixturePlacement.fieldRect, placementGeometry: self.fixturePlacement)
        XCTAssertFalse(controller.ownsKeyboardInteraction)
        XCTAssertTrue(editorWindow.firstResponder === originalResponder)
        XCTAssertTrue(NSApplication.shared.keyWindow === originalKeyWindow)
    }

    func testDecorativeUnderlinesDoNotAddAccessibilityWindowsAndPointerReviewStillWorks() async throws {
        _ = NSApplication.shared
        let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let originalKeyWindow = NSApp.keyWindow
        let controller = HighlightOverlayController()
        let issue = TextIssue(range: NSRange(location: 0, length: 3), original: "teh", suggestion: "the",
            explanation: "A spelling correction.", type: .spelling, confidence: 1, source: .local)
        let entries = [HighlightOverlayController.Entry(issue: issue, rect: CGRect(x: 120, y: 160, width: 30, height: 18))]
        var activatedIssue: UUID?
        controller.onActivateIssue = { id in
            activatedIssue = id
            controller.render(entries: entries, selectedID: id, position: (0, 1), sourceAnchor: self.fixturePlacement.fieldRect, placementGeometry: self.fixturePlacement)
        }
        defer { closeOwnedOverlay(controller, excluding: previousWindows) }
        controller.assistantState = NativeAssistantState(phase: .complete, issueCount: 1)
        controller.render(entries: entries, selectedID: nil, position: nil, sourceAnchor: self.fixturePlacement.fieldRect, placementGeometry: self.fixturePlacement)
        try await Task.sleep(nanoseconds: 50_000_000)

        let underline = try XCTUnwrap(ownedPanels(excluding: previousWindows).first {
            $0.accessibilityIdentifier().hasPrefix("com.bean.overlay.underline.")
        })
        let control = try XCTUnwrap(ownedPanels(excluding: previousWindows).first {
            $0.accessibilityIdentifier() == "com.bean.overlay.field-control"
        })
        XCTAssertFalse(underline.isAccessibilityElement())
        let underlineView = try XCTUnwrap(underline.contentView)
        XCTAssertFalse(underlineView.isAccessibilityElement())
        XCTAssertTrue(NSAccessibility.unignoredChildren(from: [underline]).isEmpty,
                      "Neither a decorative window nor its descendants should create a navigation stop")
        let publishedWindows = NSAccessibility.unignoredChildren(from: NSApp.accessibilityWindows() ?? [])
        XCTAssertFalse(publishedWindows.contains { ($0 as AnyObject) === underline })
        XCTAssertTrue(publishedWindows.contains { ($0 as AnyObject) === control },
                      "The meaningful field control must remain published")
        XCTAssertEqual(control.accessibilityTitle(), "Bean writing control")
        XCTAssertEqual(control.accessibilityRole(), .window)
        XCTAssertEqual(control.accessibilitySubrole(), .floatingWindow)
        XCTAssertFalse(underline.canBecomeKey)
        XCTAssertFalse(underline.ignoresMouseEvents)
        XCTAssertTrue(NSApp.keyWindow === originalKeyWindow)

        let pointer = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 5, y: 3),
            modifierFlags: [], timestamp: 0, windowNumber: underline.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        underline.contentView?.mouseDown(with: pointer)
        XCTAssertEqual(activatedIssue, issue.id, "Ignoring AX must not disable the existing pointer shortcut")
        let correction = try XCTUnwrap(ownedPanels(excluding: previousWindows).first {
            $0.accessibilityIdentifier() == "com.bean.overlay.correction"
        })
        correction.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(correction.accessibilityTitle(), "Bean writing suggestion")
        XCTAssertEqual(correction.accessibilitySubrole(), .floatingWindow)
        XCTAssertTrue(correction.isAccessibilityElement())
        XCTAssertTrue(NSAccessibility.unignoredChildren(from: correction.accessibilityChildren() ?? []).contains {
            ($0 as AnyObject) === correction.contentView
        }, "The suggestion's hosting view must remain in the actual accessibility tree")
        XCTAssertFalse(controller.ownsKeyboardInteraction)
        XCTAssertTrue(NSApp.keyWindow === originalKeyWindow)
    }

    func testPassiveUpdatesReuseBadgeHostAndAssistantKeepsAccessibleControls() async throws {
        _ = NSApplication.shared
        let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let originalKeyWindow = NSApp.keyWindow
        let controller = HighlightOverlayController()
        defer { closeOwnedOverlay(controller, excluding: previousWindows) }
        controller.assistantState = NativeAssistantState(phase: .checkingLocal)
        controller.render(entries: [], selectedID: nil, position: nil, sourceAnchor: self.fixturePlacement.fieldRect, placementGeometry: self.fixturePlacement)
        let control = try XCTUnwrap(ownedPanels(excluding: previousWindows).first {
            $0.accessibilityIdentifier() == "com.bean.overlay.field-control"
        })
        let host = try XCTUnwrap(control.contentViewController as? NSHostingController<NativeAssistantBadgeView>)
        let hostingView = host.view
        controller.assistantState = NativeAssistantState(phase: .complete, issueCount: 3)
        controller.render(entries: [], selectedID: nil, position: nil, sourceAnchor: self.fixturePlacement.fieldRect, placementGeometry: self.fixturePlacement)
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(control.contentViewController === host)
        XCTAssertTrue(control.contentView === hostingView)
        XCTAssertEqual(host.rootView.state.issueCount, 3)
        XCTAssertTrue(NSAccessibility.unignoredChildren(from: control.accessibilityChildren() ?? []).contains {
            ($0 as AnyObject) === hostingView
        }, "The retained control's AX hosting child must stay published")

        host.rootView.onOpen() // The production pointer path, without system-wide focus capture.
        let assistant = try XCTUnwrap(ownedPanels(excluding: previousWindows).first {
            $0.accessibilityIdentifier() == "com.bean.overlay.assistant"
        })
        assistant.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(assistant.accessibilityTitle(), "Bean writing assistant")
        XCTAssertEqual(assistant.accessibilitySubrole(), .floatingWindow)
        XCTAssertTrue(assistant.isAccessibilityElement())
        XCTAssertTrue(NSAccessibility.unignoredChildren(from: assistant.accessibilityChildren() ?? []).contains {
            ($0 as AnyObject) === assistant.contentView
        }, "Naming the assistant must not hide its hosting child")
        XCTAssertFalse(assistant.canBecomeKey)
        XCTAssertFalse(controller.ownsKeyboardInteraction)
        XCTAssertTrue(NSApp.keyWindow === originalKeyWindow)
    }

    func testSwiftUIAXControlLabelsWhenOwnedHostPublishesDescendants() async throws {
        _ = NSApplication.shared
        let baseline = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        baseline.isReleasedWhenClosed = false
        defer { baseline.close() }
        baseline.contentView = NSButton(title: "Synthetic AppKit button", target: nil, action: nil)
        XCTAssertTrue(accessibilityLabels(in: baseline).contains("Synthetic AppKit button"),
                      "The fixture must first prove that its real AppKit AX traversal works")
        baseline.contentView = NSHostingView(rootView: Button("Synthetic hosted button", action: {}))
        baseline.orderFrontRegardless()
        try await Task.sleep(nanoseconds: 50_000_000)
        guard accessibilityLabels(in: baseline).contains("Synthetic hosted button") else {
            throw XCTSkip("This owned unit host publishes no descendants even for a plain SwiftUI Button. Real SwiftUI controls and VoiceOver/AXPress transport require an installed app accessibility session.")
        }

        let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = HighlightOverlayController()
        defer { closeOwnedOverlay(controller, excluding: previousWindows) }
        controller.assistantState = NativeAssistantState(phase: .checkingLocal)
        controller.render(entries: [], selectedID: nil, position: nil, sourceAnchor: self.fixturePlacement.fieldRect, placementGeometry: self.fixturePlacement)
        let control = try XCTUnwrap(ownedPanels(excluding: previousWindows).first {
            $0.accessibilityIdentifier() == "com.bean.overlay.field-control"
        })
        let host = try XCTUnwrap(control.contentViewController as? NSHostingController<NativeAssistantBadgeView>)
        let issue = TextIssue(range: NSRange(location: 0, length: 3), original: "teh", suggestion: "the",
            explanation: nil, type: .spelling, confidence: 1, source: .local)
        let entries = [HighlightOverlayController.Entry(issue: issue, rect: nil)]
        controller.assistantState = NativeAssistantState(phase: .complete, issueCount: 1)
        controller.render(entries: entries, selectedID: nil, position: nil, sourceAnchor: self.fixturePlacement.fieldRect, placementGeometry: self.fixturePlacement)
        control.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(accessibilityLabels(in: control).contains {
            $0.contains("1 writing suggestion") && $0.contains("Open writing assistant")
        }, "The retained badge must expose its updated status to accessibility")

        host.rootView.onOpen()
        let assistant = try XCTUnwrap(ownedPanels(excluding: previousWindows).first {
            $0.accessibilityIdentifier() == "com.bean.overlay.assistant"
        })
        assistant.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        let assistantLabels = accessibilityLabels(in: assistant)
        XCTAssertTrue(assistantLabels.contains("Close writing assistant"))
        XCTAssertTrue(assistantLabels.contains("Proofread draft"))

        controller.render(entries: entries, selectedID: issue.id, position: (0, 1), sourceAnchor: self.fixturePlacement.fieldRect, placementGeometry: self.fixturePlacement)
        let correction = try XCTUnwrap(ownedPanels(excluding: previousWindows).first {
            $0.accessibilityIdentifier() == "com.bean.overlay.correction"
        })
        correction.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(accessibilityLabels(in: correction).contains("Accept"))
    }

    private func ownedPanels(excluding previousWindows: Set<ObjectIdentifier>) -> [OverlayPanel] {
        NSApp.windows.compactMap { window in
            guard !previousWindows.contains(ObjectIdentifier(window)) else { return nil }
            return window as? OverlayPanel
        }
    }

    private func closeOwnedOverlay(_ controller: HighlightOverlayController, excluding previousWindows: Set<ObjectIdentifier>) {
        let windows = ownedPanels(excluding: previousWindows)
        controller.onActivateIssue = nil
        controller.hide()
        for window in windows {
            window.isReleasedWhenClosed = false
            window.close()
        }
    }

    private func accessibilityLabels(in root: Any) -> [String] {
        var visited = Set<ObjectIdentifier>()
        func visit(_ element: Any) -> [String] {
            guard let accessible = element as? NSObject,
                  visited.insert(ObjectIdentifier(accessible)).inserted else { return [] }
            // SwiftUI publishes private AX nodes with the standard Objective-C
            // getters, without necessarily declaring the complete AppKit protocol.
            func value(_ getter: String) -> Any? {
                let selector = NSSelectorFromString(getter)
                guard accessible.responds(to: selector) else { return nil }
                return accessible.perform(selector)?.takeUnretainedValue()
            }
            let children = NSAccessibility.unignoredChildren(from: value("accessibilityChildren") as? [Any] ?? [])
            let own = [value("accessibilityLabel") as? String, value("accessibilityTitle") as? String].compactMap { $0 }
            return own + children.flatMap(visit)
        }
        return visit(root)
    }
}
