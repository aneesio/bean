import AppKit
import XCTest
@testable import Bean

/// Exercises the production capture/probe logic with owned geometry. No AX
/// queries are made against another process by these fixtures.
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
                         clock: @escaping () -> TimeInterval = { 0 },
                         protectedRects: [CGRect] = []) -> FieldOverlayGeometry? {
        FieldOverlayGeometryCapture.capture(element: field, window: { _ in window },
            geometry: read ?? { $0.readable ? .init(role: $0.role, rect: $0.hasBounds ? $0.rect : nil) : nil },
            parent: { $0.parent }, children: { node, limit in node.childrenReadable && node.children.count <= limit ? node.children : nil },
            isSame: { $0 === $1 }, now: clock, deadline: 0.030, protectedRects: protectedRects)
    }

    func testEditorWithDeepUnrelatedWindowTreeCapturesWithoutWalkingAllAncestors() throws {
        let window = Node("AXWindow", windowRect)
        var container = window
        for _ in 0..<20 { let group = Node("AXGroup", .zero); group.hasBounds = false; container.add(group); container = group }
        let field = Node("AXTextArea", fieldRect); container.add(field)
        let unrelated = Node("AXUnknown", .zero); unrelated.readable = false; window.add(unrelated)
        for _ in 0..<100 { window.add(Node("AXButton", CGRect(x: 700, y: 600, width: 28, height: 28))) }
        var reads: [Node] = []
        let result = try XCTUnwrap(capture(field, window: window, read: { node in
            reads.append(node)
            return node.readable ? .init(role: node.role, rect: node.hasBounds ? node.rect : nil) : nil
        }))
        XCTAssertEqual(result.fieldRect, fieldRect)
        XCTAssertEqual(result.windowRect, windowRect)
        XCTAssertLessThanOrEqual(reads.count, 5)
        XCTAssertFalse(reads.contains(where: { $0 === unrelated }))
        XCTAssertTrue(fieldRect.contains(CGRect(origin: try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry: result,
            panelSize: CGSize(width: 28, height: 28), in: windowRect)), size: CGSize(width: 28, height: 28))))
    }

    func testZeroUnsupportedOrOpaqueParentNeverRequiresCompleteWindowPath() throws {
        for role in ["AXGroup", "AXUnknown", "AXButton"] {
            let window = Node("AXWindow", windowRect), wrapper = Node(role, .zero), field = Node("AXTextArea", fieldRect)
            wrapper.hasBounds = false; wrapper.childrenReadable = false
            window.add(wrapper); wrapper.add(field)
            let result = try XCTUnwrap(capture(field, window: window), role)
            XCTAssertEqual(result.fieldRect, fieldRect)
            XCTAssertEqual(result.windowRect, windowRect)
        }
    }

    func testImmediateScrollViewportClipsLongDocumentWithoutUsingGroupBoundsAsClipping() throws {
        for role in ["AXScrollArea", "AXGroup"] {
            let window = Node("AXWindow", windowRect)
            let viewportRect = CGRect(x: 100, y: 100, width: 400, height: 200)
            let viewport = Node(role, viewportRect)
            let documentRect = CGRect(x: 100, y: -500, width: 400, height: 1000)
            let field = Node("AXTextArea", documentRect)
            window.add(viewport); viewport.add(field)
            let result = try XCTUnwrap(capture(field, window: window))
            XCTAssertEqual(result.fieldRect, role == "AXScrollArea" ? viewportRect : documentRect)
            let frame = CGRect(origin: try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry: result,
                panelSize: CGSize(width: 28, height: 28), in: windowRect)), size: CGSize(width: 28, height: 28))
            if role == "AXScrollArea" { XCTAssertTrue(viewportRect.contains(frame)) }
        }
    }

    func testPositiveViewportMustRemainStableDuringCapture() {
        let window = Node("AXWindow", windowRect), viewport = Node("AXScrollArea", fieldRect)
        let field = Node("AXTextArea", CGRect(x: 100, y: -500, width: 400, height: 1000))
        window.add(viewport); viewport.add(field)
        var reads = 0
        XCTAssertNil(capture(field, window: window, read: { node in
            var rect = node.rect
            if node === viewport { reads += 1; if reads == 2 { rect.size.height -= 10 } }
            return .init(role: node.role, rect: rect)
        }))
        viewport.rect = CGRect(x: 700, y: 100, width: 100, height: 200)
        XCTAssertNil(capture(field, window: window), "A positively disjoint viewport is not a visible source editor")
    }

    func testKnownEditorChildAndImmediateLocalControlsAvoidInsideTopCorner() throws {
        let window = Node("AXWindow", windowRect), wrapper = Node("AXGroup", fieldRect), field = Node("AXTextArea", fieldRect)
        let localButton = Node("AXButton", CGRect(x: fieldRect.maxX - 34, y: fieldRect.maxY - 34, width: 30, height: 30))
        let childButton = Node("AXPopUpButton", CGRect(x: fieldRect.minX + 2, y: fieldRect.maxY - 30, width: 24, height: 24))
        window.add(wrapper); wrapper.add(field); wrapper.add(localButton); field.add(childButton)
        let result = try XCTUnwrap(capture(field, window: window))
        XCTAssertTrue(result.exclusionRects.contains(localButton.rect))
        XCTAssertTrue(result.exclusionRects.contains(childButton.rect))
        let target = CGRect(origin: try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry: result,
            panelSize: CGSize(width: 28, height: 28), in: windowRect)), size: CGSize(width: 28, height: 28))
        XCTAssertTrue(fieldRect.contains(target))
        XCTAssertFalse(localButton.rect.insetBy(dx: -2, dy: -2).intersects(target))
        XCTAssertFalse(childButton.rect.insetBy(dx: -2, dy: -2).intersects(target))
    }

    func testLocalOpaqueGeometryDoesNotSuppressEveryEditorCandidate() throws {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", fieldRect)
        window.add(field)
        let opaque = Node("AXGroup", .zero); opaque.childrenReadable = false; opaque.hasBounds = false; field.add(opaque)
        let unknownLeaf = Node("AXButton", .zero); unknownLeaf.hasBounds = false; field.add(unknownLeaf)
        XCTAssertNotNil(capture(field, window: window), "Unavailable local capability is handled by candidate-local hit probes, not a whole-editor failure")
        field.childrenReadable = false
        XCTAssertNotNil(capture(field, window: window), "Ordinary AX text fields need not expose children")
    }

    func testKnownCaretAndGlyphProtectionsRemainExactToThisEditor() throws {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", fieldRect); window.add(field)
        let caret = CGRect(x: 490, y: 274, width: 1, height: 20)
        let glyph = CGRect(x: 440, y: 274, width: 49, height: 20)
        let unrelated = CGRect(x: 800, y: 700, width: 20, height: 20)
        let result = try XCTUnwrap(capture(field, window: window, protectedRects: [caret, glyph, unrelated, .zero]))
        XCTAssertEqual(result.exclusionRects, [caret, glyph])
        let target = CGRect(origin: try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry: result,
            panelSize: CGSize(width: 28, height: 28), in: windowRect)), size: CGSize(width: 28, height: 28))
        XCTAssertFalse(caret.insetBy(dx: -2, dy: -2).intersects(target))
        XCTAssertFalse(glyph.insetBy(dx: -2, dy: -2).intersects(target))
    }

    func testLargeLocalSubtreeStopsAtOptionalBudgetWithoutFailingExactSource() throws {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", fieldRect); window.add(field)
        for _ in 0..<100 { field.add(Node("AXStaticText", fieldRect)) }
        var childrenReads = 0
        let result = FieldOverlayGeometryCapture.capture(element: field, window: { _ in window },
            geometry: { .init(role: $0.role, rect: $0.rect) }, parent: { $0.parent },
            children: { node, limit in childrenReads += 1; return node.children.count <= limit ? node.children : nil },
            isSame: { $0 === $1 }, now: { 0 }, deadline: 0.030)
        XCTAssertNotNil(result)
        XCTAssertEqual(childrenReads, 1)
    }

    func testFieldAndWindowStillRequirePositiveFiniteExactBounds() {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", fieldRect); window.add(field)
        field.hasBounds = false; XCTAssertNil(capture(field, window: window))
        field.hasBounds = true; window.hasBounds = false; XCTAssertNil(capture(field, window: window))
        window.hasBounds = true; field.rect = .zero; XCTAssertNil(capture(field, window: window))
        field.rect = fieldRect; window.rect = CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 800)
        XCTAssertNil(capture(field, window: window))
        window.rect = CGRect(x: 800, y: 700, width: 100, height: 100)
        XCTAssertNil(capture(field, window: window), "The source must intersect its exact window")
    }

    func testCaptureDiagnosticsRemainContentFree() {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", .zero); window.add(field)
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

    func testExactSourceReadTimeoutAndSourceMutationStillFailClosed() {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", fieldRect); window.add(field)
        var elapsed = 0.0
        XCTAssertNil(capture(field, window: window, read: { node in
            elapsed += 0.020; return .init(role: node.role, rect: node.rect)
        }, clock: { elapsed }))
        for changed in [window, field] {
            var reads = 0
            XCTAssertNil(capture(field, window: window, read: { node in
                var rect = node.rect
                if node === changed { reads += 1; if reads == 2 { rect.origin.x += 1 } }
                return .init(role: node.role, rect: rect)
            }))
        }
        let other = Node("AXWindow", windowRect)
        var references = 0
        XCTAssertNil(FieldOverlayGeometryCapture.capture(element: field,
            window: { _ in references += 1; return references == 1 ? window : other },
            geometry: { .init(role: $0.role, rect: $0.rect) }, parent: { $0.parent },
            children: { node, limit in node.children.count <= limit ? node.children : nil },
            isSame: { $0 === $1 }, now: { 0 }, deadline: 0.030))
    }

    func testFinalContinuityReadTimeoutReportsDeadlineRatherThanSourceMutation() {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", fieldRect); window.add(field)
        for phase in ["fieldGeometry", "windowReference", "windowGeometry"] {
            var elapsed = 0.0, fieldReads = 0, windowReads = 0, referenceReads = 0
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
            }, parent: { $0.parent }, children: { node, _ in node.children }, isSame: { $0 === $1 },
                now: { elapsed }, deadline: 0.030, onDiagnostics: { report = $0 }))
            XCTAssertEqual(report?.failureReason, .deadline, phase)
        }
    }

    func testPointProbesCheckCompleteTargetIncludingTransparentCorners() {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", fieldRect), button = Node("AXButton", .zero)
        window.add(field); window.add(button)
        let frame = CGRect(x: 468, y: 268, width: 28, height: 28)
        var points: [CGPoint] = []
        let result = FieldOverlayGeometryCapture.targetHitTest(frame: frame, source: field, sourceWindow: window,
            hit: { point in points.append(point); return point.x < frame.midX && point.y < frame.midY ? button : field },
            role: { $0.role }, parent: { $0.parent }, isSame: { $0 === $1 }, belongsToSourceApplication: { _ in true },
            now: { 0 }, deadline: 0.010)
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.first, CGPoint(x: frame.midX, y: frame.midY))
        XCTAssertTrue(points.allSatisfy { frame.contains($0) })
    }

    func testPointProbesAcceptExactFieldAndOwnedTextDescendants() {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", fieldRect), text = Node("AXStaticText", fieldRect)
        let group = Node("AXGroup", fieldRect); window.add(field); field.add(group); group.add(text)
        for target in [field, text] {
            var probes = 0
            let result = FieldOverlayGeometryCapture.targetHitTest(frame: CGRect(x: 468, y: 268, width: 28, height: 28),
                source: field, sourceWindow: window, hit: { _ in probes += 1; return target }, role: { $0.role },
                parent: { $0.parent }, isSame: { $0 === $1 }, belongsToSourceApplication: { _ in true }, now: { 0 }, deadline: 0.010)
            XCTAssertEqual(result, .field)
            XCTAssertEqual(probes, 5)
        }
    }

    func testUnknownHitCapabilitiesAndCoarseElectronNodesRemainUnavailableRatherThanBlocked() {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", fieldRect)
        let coarse = Node("AXWebArea", windowRect), unresolvedText = Node("AXTextArea", fieldRect)
        for target in [nil, coarse, unresolvedText] {
            let result = FieldOverlayGeometryCapture.targetHitTest(frame: CGRect(x: 468, y: 268, width: 28, height: 28),
                source: field, sourceWindow: window, hit: { _ in target }, role: { $0.role }, parent: { $0.parent },
                isSame: { $0 === $1 }, belongsToSourceApplication: { _ in true }, now: { 0 }, deadline: 0.010)
            XCTAssertEqual(result, .unavailable)
        }
    }

    func testSeparateEditorAndForeignApplicationHitsArePositiveObstructions() {
        let window = Node("AXWindow", windowRect), field = Node("AXTextArea", fieldRect), separate = Node("AXTextField", fieldRect)
        window.add(field); window.add(separate)
        for foreign in [false, true] {
            let result = FieldOverlayGeometryCapture.targetHitTest(frame: CGRect(x: 468, y: 268, width: 28, height: 28),
                source: field, sourceWindow: window, hit: { _ in separate }, role: { $0.role }, parent: { $0.parent },
                isSame: { $0 === $1 }, belongsToSourceApplication: { _ in !foreign }, now: { 0 }, deadline: 0.010)
            XCTAssertEqual(result, .blocked)
        }
    }

    func testPointProbeDeadlineCannotBecomeAFalseControlObstruction() {
        let field = Node("AXTextArea", fieldRect), control = Node("AXButton", .zero)
        var elapsed = 0.0, probes = 0
        let result = FieldOverlayGeometryCapture.targetHitTest(frame: CGRect(x: 468, y: 268, width: 28, height: 28),
            source: field, sourceWindow: nil, hit: { _ in probes += 1; elapsed = 0.010; return control }, role: { $0.role },
            parent: { $0.parent }, isSame: { $0 === $1 }, belongsToSourceApplication: { _ in true }, now: { elapsed }, deadline: 0.010)
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(probes, 1)
    }

    func testOwnershipProbeCannotReportForeignControlAfterItsDeadline() {
        let field = Node("AXTextArea", fieldRect), control = Node("AXButton", .zero)
        var elapsed = 0.0
        let result = FieldOverlayGeometryCapture.targetHitTest(frame: CGRect(x: 468, y: 268, width: 28, height: 28),
            source: field, sourceWindow: nil, hit: { _ in control }, role: { $0.role }, parent: { $0.parent },
            isSame: { $0 === $1 }, belongsToSourceApplication: { _ in elapsed = 0.010; return false },
            now: { elapsed }, deadline: 0.010)
        XCTAssertEqual(result, .unavailable)
    }

    func testOwnedNestedAppKitComposerUsesRealEditorAndInsideControlGeometry() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: windowRect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: windowRect); root.setAccessibilityRole(.group); window.contentView = root
        var container = root
        for _ in 0..<12 { let group = NSView(frame: windowRect); group.setAccessibilityRole(.group); container.addSubview(group); container = group }
        let editor = NSTextView(frame: fieldRect); editor.string = "Owned synthetic draft."; editor.setAccessibilityRole(.textArea)
        let send = NSButton(frame: CGRect(x: 468, y: 268, width: 28, height: 28)); send.title = "Send"; send.setAccessibilityRole(.button)
        container.addSubview(editor); container.addSubview(send)
        let result = try XCTUnwrap(FieldOverlayGeometryCapture.capture(element: editor as NSObject,
            window: { ($0 as? NSView)?.window }, geometry: { node in
                if let window = node as? NSWindow { return .init(role: "AXWindow", rect: window.frame) }
                guard let view = node as? NSView, let owner = view.window, let role = view.accessibilityRole() else { return nil }
                return .init(role: role.rawValue, rect: owner.convertToScreen(view.convert(view.bounds, to: nil)))
            }, parent: { ($0 as? NSView)?.superview }, children: { node, limit -> [NSObject]? in
                let nodes: [NSObject] = (node as? NSView)?.subviews ?? []
                return nodes.count <= limit ? nodes : nil
            }, isSame: { $0 === $1 }, now: { 0 }, deadline: 0.030))
        let actualSend = window.convertToScreen(send.convert(send.bounds, to: nil))
        XCTAssertTrue(result.exclusionRects.contains(actualSend))
        let frame = CGRect(origin: try XCTUnwrap(OverlayGeometry.issueTrayOrigin(geometry: result,
            panelSize: CGSize(width: 28, height: 28), in: window.frame)), size: CGSize(width: 28, height: 28))
        XCTAssertTrue(result.fieldRect.contains(frame))
        XCTAssertFalse(actualSend.insetBy(dx: -2, dy: -2).intersects(frame))
    }
}
