import AppKit
import XCTest
@testable import Bean

/// Exercises the production traversal with owned/injected geometry. This does
/// not query AX in another process or certify WindowServer/third-party trees.
@MainActor
final class FieldOverlayGeometryCaptureTests: XCTestCase {
    private final class Node {
        var role: String
        var rect: CGRect
        weak var parent: Node?
        var children: [Node] = []
        var readable = true
        var hasBounds = true
        var childrenReadable = true
        init(_ role: String, _ rect: CGRect) { self.role = role; self.rect = rect }
        func add(_ node: Node) { children.append(node); node.parent = self }
    }
    private let windowRect = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let fieldRect = CGRect(x: 100, y: 100, width: 400, height: 200)

    private func capture(_ field: Node, window: Node,
                         read: ((Node) -> FieldOverlayGeometryCapture.NodeGeometry?)? = nil,
                         clock: @escaping () -> TimeInterval = { 0 }) -> FieldOverlayGeometry? {
        FieldOverlayGeometryCapture.capture(element: field, window: { _ in window },
            geometry: read ?? { $0.readable ? .init(role: $0.role, rect: $0.hasBounds ? $0.rect : nil) : nil },
            parent: { $0.parent }, children: { node, limit in node.childrenReadable && node.children.count <= limit ? node.children : nil },
            isSame: { $0 === $1 }, now: clock, deadline: 0.030)
    }

    func testNestedEditorFindsNearbySendWithoutReadingWriting() throws {
        let window = Node("AXWindow", windowRect)
        var container = window
        for _ in 0..<6 { let group = Node("AXGroup", windowRect); container.add(group); container = group }
        let field = Node("AXTextArea", fieldRect)
        container.add(field)
        let send = Node("AXButton", CGRect(x: 504, y: 100, width: 28, height: 28))
        container.add(send)
        let result = try XCTUnwrap(capture(field, window: window))
        XCTAssertEqual(result.fieldRect, fieldRect)
        XCTAssertEqual(result.exclusionRects, [send.rect])
        let origin = try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry: result, panelSize: CGSize(width: 28, height: 28), in: windowRect))
        XCTAssertFalse(send.rect.intersects(CGRect(origin: origin, size: CGSize(width: 28, height: 28))))
    }

    func testZeroOrUnsupportedNeutralAncestorBoundsUseExactCompleteChildPath() throws {
        for unsupported in [true, false] {
            let window = Node("AXWindow", windowRect)
            let wrapper = Node("AXGroup", unsupported ? windowRect : .zero)
            wrapper.hasBounds = !unsupported
            let field = Node("AXTextArea", fieldRect)
            let send = Node("AXButton", CGRect(x: 504, y: 100, width: 28, height: 28))
            window.add(wrapper); wrapper.add(field); wrapper.add(send)
            let result = try XCTUnwrap(capture(field, window: window))
            XCTAssertEqual(result.fieldRect, fieldRect)
            XCTAssertEqual(result.windowRect, windowRect)
            XCTAssertEqual(result.exclusionRects, [send.rect])
            wrapper.childrenReadable = false
            XCTAssertNil(capture(field, window: window), "Missing bounds never excuse an incomplete source path")
        }
    }

    func testBoundlessNeutralSiblingUsesBoundedDescendantsAndUnlocatedLeafHides() throws {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", fieldRect)
        let wrapper = Node("AXGroup", .zero), nested = Node("AXGroup", .zero)
        let button = Node("AXButton", CGRect(x: 504, y: 100, width: 28, height: 28))
        window.add(field); window.add(wrapper); wrapper.add(nested); nested.add(button)
        XCTAssertEqual(try XCTUnwrap(capture(field, window: window)).exclusionRects, [button.rect])
        button.hasBounds = false
        XCTAssertNil(capture(field, window: window), "An unlocated interactive leaf remains unsafe")
        button.hasBounds = true
        nested.childrenReadable = false
        XCTAssertNil(capture(field, window: window), "A boundless branch must prove every descendant")
    }

    func testKnownContainerFrameCannotCertifyUnavailableDescendantsAreClipped() {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", fieldRect)
        let branch = Node("AXGroup", CGRect(x: 0, y: 0, width: 20, height: 20))
        // The child escapes its small parent onto the dot's otherwise-safe edge.
        let escaped = Node("AXButton", CGRect(x: 504, y: 100, width: 28, height: 28))
        branch.add(escaped); branch.childrenReadable = false
        window.add(field); window.add(branch)
        XCTAssertNil(capture(field, window: window), "A frame is not a descendant clipping proof")
    }

    func testEscapedChildOutsideFarNeutralWrapperFrameStillBlocksDot() throws {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", fieldRect)
        let wrapper = Node("AXGroup", CGRect(x: 0, y: 0, width: 20, height: 20))
        let escaped = Node("AXButton", CGRect(x: 504, y: 100, width: 28, height: 28))
        window.add(field); window.add(wrapper); wrapper.add(escaped)
        let result = try XCTUnwrap(capture(field, window: window))
        XCTAssertEqual(result.exclusionRects, [escaped.rect])
        let origin = try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry: result,
            panelSize: CGSize(width: 28, height: 28), in: windowRect))
        XCTAssertFalse(escaped.rect.intersects(CGRect(origin: origin, size: CGSize(width: 28, height: 28))))
    }

    func testUnknownRoleNeedsSuccessfulEmptyChildrenProofBeforeUsingItsRectangle() throws {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", fieldRect)
        let unknown = Node("AXUnknown", CGRect(x: 504, y: 100, width: 28, height: 28))
        window.add(field); window.add(unknown)
        XCTAssertEqual(try XCTUnwrap(capture(field, window: window)).exclusionRects, [unknown.rect])
        unknown.childrenReadable = false
        XCTAssertNil(capture(field, window: window))
    }

    func testFieldAndWindowStillRequirePositiveFiniteExactBounds() {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", fieldRect)
        window.add(field)
        field.hasBounds = false
        XCTAssertNil(capture(field, window: window))
        field.hasBounds = true; window.hasBounds = false
        XCTAssertNil(capture(field, window: window))
        window.hasBounds = true; field.rect = .zero
        XCTAssertNil(capture(field, window: window))
        field.rect = fieldRect; window.rect = CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 800)
        XCTAssertNil(capture(field, window: window))
    }

    func testCaptureDiagnosticsContainOnlyClassificationsAndBoundedCounts() {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", .zero)
        window.add(field)
        var report: FieldOverlayGeometryCapture.Diagnostics?
        XCTAssertNil(FieldOverlayGeometryCapture.capture(element: field, window: { _ in window },
            geometry: { .init(role: $0.role, rect: $0.rect) }, parent: { $0.parent },
            children: { node, _ in node.children }, isSame: { $0 === $1 }, now: { 0 }, deadline: 0.030,
            onDiagnostics: { report = $0 }))
        XCTAssertEqual(report?.failureReason, .fieldBoundsUnavailable)
        XCTAssertEqual(report?.nodeCount, 1)
        XCTAssertEqual(report?.ancestorCount, 0)
        XCTAssertEqual(report?.elapsedMilliseconds, 0)
    }

    func testOpaqueOrInteractiveSourceAncestorCannotCertifyNeutralSpace() {
        for role in ["AXButton", "AXUnknown", "AXTabGroup"] {
            let window = Node("AXWindow", windowRect)
            let opaque = Node(role, windowRect)
            let field = Node("AXTextArea", fieldRect)
            window.add(opaque); opaque.add(field)
            XCTAssertNil(capture(field, window: window), role)
        }
    }

    func testUnknownNearbyLeafIsExcludedAndUnreadableBranchHides() throws {
        let window = Node("AXWindow", windowRect)
        let field = Node("AXTextArea", fieldRect)
        let unknown = Node("AXUnknown", CGRect(x: 504, y: 100, width: 28, height: 28))
        window.add(field); window.add(unknown)
        XCTAssertEqual(try XCTUnwrap(capture(field, window: window)).exclusionRects, [unknown.rect])
        unknown.readable = false
        XCTAssertNil(capture(field, window: window))
    }

    func testUnresolvedDeepSiblingHidesRatherThanAssumingDescendantClipping() {
        let window = Node("AXWindow", windowRect)
        let field = Node("AXTextArea", fieldRect)
        window.add(field)
        let rect = CGRect(x: 500, y: 100, width: 34, height: 200)
        let a = Node("AXGroup", rect), b = Node("AXGroup", rect), c = Node("AXGroup", rect)
        window.add(a); a.add(b); b.add(c)
        c.add(Node("AXButton", rect))
        XCTAssertNil(capture(field, window: window), "A deep container frame does not prove its children stay inside it")
    }

    func testTraversalDepthNodeAndTimeLimitsFailClosed() {
        let window = Node("AXWindow", windowRect)
        var branch = window
        for _ in 0..<8 { let next = Node("AXGroup", windowRect); branch.add(next); branch = next }
        let deepField = Node("AXTextArea", fieldRect); branch.add(deepField)
        XCTAssertNil(capture(deepField, window: window))
        let crowded = Node("AXWindow", windowRect), field = Node("AXTextArea", fieldRect)
        crowded.add(field)
        for _ in 0..<48 { crowded.add(Node("AXButton", CGRect(x: 504, y: 100, width: 28, height: 28))) }
        XCTAssertNil(capture(field, window: crowded))
        let slow = Node("AXWindow", windowRect), slowField = Node("AXTextArea", fieldRect)
        slow.add(slowField)
        var elapsed = 0.0
        XCTAssertNil(capture(slowField, window: slow, read: {
            elapsed += 0.020
            return .init(role: $0.role, rect: $0.rect)
        }, clock: { elapsed }))
    }

    func testWindowAndFieldChangesDuringCaptureFailClosed() {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", fieldRect)
        window.add(field)
        for changed in [window, field] {
            var reads = 0
            XCTAssertNil(capture(field, window: window, read: { node in
                var rect = node.rect
                if node === changed { reads += 1; if reads == 2 { rect.origin.x += 1 } }
                return .init(role: node.role, rect: rect)
            }))
        }
        let other = Node("AXWindow", windowRect)
        var windowReads = 0
        XCTAssertNil(FieldOverlayGeometryCapture.capture(element: field,
            window: { _ in windowReads += 1; return windowReads == 1 ? window : other },
            geometry: { .init(role: $0.role, rect: $0.rect) }, parent: { $0.parent },
            children: { $0.children.count <= $1 ? $0.children : nil }, isSame: { $0 === $1 }, now: { 0 }, deadline: 0.030))
    }

    func testFinalContinuityReadTimeoutReportsDeadlineInsteadOfSourceMutation() {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", fieldRect)
        window.add(field)
        for phase in ["fieldGeometry", "windowReference", "windowGeometry"] {
            var elapsed = 0.0
            var fieldReads = 0, windowReads = 0, referenceReads = 0
            var report: FieldOverlayGeometryCapture.Diagnostics?
            XCTAssertNil(FieldOverlayGeometryCapture.capture(element: field, window: { _ in
                referenceReads += 1
                if phase == "windowReference", referenceReads == 2 { elapsed = 0.030; return nil }
                return window
            }, geometry: { node in
                if node === field {
                    fieldReads += 1
                    if phase == "fieldGeometry", fieldReads == 2 { elapsed = 0.030; return nil }
                } else if node === window {
                    windowReads += 1
                    if phase == "windowGeometry", windowReads == 2 { elapsed = 0.030; return nil }
                }
                return .init(role: node.role, rect: node.rect)
            }, parent: { $0.parent }, children: { node, _ in node.children },
                isSame: { $0 === $1 }, now: { elapsed }, deadline: 0.030, onDiagnostics: { report = $0 }))
            XCTAssertEqual(report?.failureReason, .deadline, phase)
            XCTAssertEqual(report?.elapsedMilliseconds, 30, phase)
        }
    }

    func testOwnedNestedAppKitComposerUsesRealViewGeometryAndButtonObstacle() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: windowRect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: windowRect)
        root.setAccessibilityRole(.group)
        window.contentView = root
        var container = root
        for _ in 0..<5 {
            let group = NSView(frame: windowRect); group.setAccessibilityRole(.group)
            container.addSubview(group); container = group
        }
        let editor = NSTextView(frame: fieldRect)
        editor.string = "Owned synthetic draft."
        editor.setAccessibilityRole(.textArea)
        let send = NSButton(frame: CGRect(x: 504, y: 100, width: 28, height: 28))
        send.title = "Send"; send.setAccessibilityRole(.button)
        container.addSubview(editor); container.addSubview(send)
        let result = try XCTUnwrap(FieldOverlayGeometryCapture.capture(element: editor as NSObject,
            window: { ($0 as? NSView)?.window }, geometry: { node in
                if let window = node as? NSWindow { return .init(role: "AXWindow", rect: window.frame) }
                guard let view = node as? NSView, let owner = view.window,
                      let role = view.accessibilityRole() else { return nil }
                return .init(role: role.rawValue, rect: owner.convertToScreen(view.convert(view.bounds, to: nil)))
            }, parent: { node -> NSObject? in
                guard let view = node as? NSView else { return nil }
                if view === root { return window }
                return view.superview
            }, children: { node, limit -> [NSObject]? in
                let result: [NSObject] = node is NSWindow ? [root] : (node as? NSView)?.subviews ?? []
                return result.count <= limit ? result : nil
            }, isSame: { $0 === $1 }, now: { 0 }, deadline: 0.030))
        let actualSend = window.convertToScreen(send.convert(send.bounds, to: nil))
        XCTAssertTrue(result.exclusionRects.contains(actualSend))
        let origin = try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry: result, panelSize: CGSize(width: 28, height: 28), in: window.frame))
        XCTAssertFalse(actualSend.intersects(CGRect(origin: origin, size: CGSize(width: 28, height: 28))))
    }
}
