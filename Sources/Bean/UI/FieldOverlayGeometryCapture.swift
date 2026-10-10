import Foundation

/// The traversal is shared by the AX adapter and owned fixtures. Readers expose
/// only identity, role and geometry; the scanner never asks for writing/labels.
enum FieldOverlayGeometryCapture {
    struct NodeGeometry {
        let role: String
        let rect: CGRect?
    }

    enum FailureReason: String {
        case fieldBoundsUnavailable, fieldOutsideViewport, windowUnavailable, windowBoundsUnavailable
        case nodeUnavailable, nodeLimit, deadline, unlocatedControl, unresolvedContainer
        case sourcePathUnverified, ancestorDepthLimit, fieldChanged, windowChanged
    }
    struct Diagnostics {
        let failureReason: FailureReason?
        let nodeCount: Int
        let ancestorCount: Int
        let excludedBranchCount: Int
        let elapsedMilliseconds: Int
    }

    static func capture<Node>(element: Node,
                              window: (Node) -> Node?,
                              geometry: (Node) -> NodeGeometry?,
                              parent: (Node) -> Node?,
                              children: (Node, Int) -> [Node]?,
                              isSame: (Node, Node) -> Bool,
                              now: () -> TimeInterval,
                              deadline: TimeInterval,
                              protectedRects: [CGRect] = [],
                              protectedGeometry: ((Node) -> [CGRect])? = nil,
                              onDiagnostics: ((Diagnostics) -> Void)? = nil) -> FieldOverlayGeometry? {
        let started = now()
        let controls: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXSwitch",
            "AXLink", "AXMenuItem", "AXPopUpButton", "AXComboBox", "AXImage", "AXScrollBar",
            "AXIncrementor", "AXProgressIndicator", "AXTextField", "AXTextArea"]
        let neutralContainers: Set<String> = ["AXGroup", "AXScrollArea", "AXLayoutArea"]
        var remaining = 32
        var visited: [(Node, NodeGeometry)] = []
        var exclusions: [CGRect] = []
        var failure: FailureReason?
        var ancestorCount = 0
        var excludedBranches = 0
        defer {
            onDiagnostics?(.init(failureReason: failure, nodeCount: 32 - remaining,
                ancestorCount: ancestorCount, excludedBranchCount: excludedBranches,
                elapsedMilliseconds: Int(max(0, now() - started) * 1000)))
        }
        func inTime() -> Bool {
            guard now() < deadline else { failure = .deadline; return false }
            return true
        }
        func bounds(_ snapshot: NodeGeometry) -> CGRect? {
            snapshot.rect.flatMap { OverlayGeometry.isFiniteRect($0) ? $0 : nil }
        }
        func read(_ node: Node, required: Bool = true) -> NodeGeometry? {
            if let existing = visited.first(where: { isSame($0.0, node) }) { return existing.1 }
            guard inTime() else { return nil }
            guard remaining > 0 else { if required { failure = .nodeLimit }; return nil }
            remaining -= 1
            guard let snapshot = geometry(node), !snapshot.role.isEmpty else {
                if required, inTime() { failure = .nodeUnavailable }; return nil
            }
            guard inTime() else { return nil }
            visited.append((node, snapshot))
            return snapshot
        }
        guard let field = read(element), let rawFieldRect = bounds(field) else {
            if failure == nil { failure = .fieldBoundsUnavailable }; return nil
        }
        var fieldRect = rawFieldRect
        guard let sourceWindow = window(element), inTime() else {
            if failure == nil { failure = .windowUnavailable }; return nil
        }
        guard let windowGeometry = read(sourceWindow), windowGeometry.role == "AXWindow",
              let windowRect = bounds(windowGeometry), windowRect.intersects(fieldRect) else {
            if failure == nil { failure = .windowBoundsUnavailable }; return nil
        }
        exclusions = protectedRects.filter { OverlayGeometry.isFiniteRect($0) && $0.intersects(fieldRect) }
        // kAXWindow binds the exact editor to its window. We no longer require
        // a complete path through every ancestor and unrelated window subtree
        // merely to draw an 8-point dot inside this already-known editor.
        // Reserve time for final source continuity reads. Optional local scans
        // contribute known obstacles; unavailable unrelated geometry cannot
        // invalidate all in-field candidates.
        func canInspectLocal() -> Bool { remaining > 2 && now() < deadline - 0.015 }
        var viewport: (Node, CGRect)?
        var inspected: [Node] = []
        func inspectLocal(_ node: Node, depth: Int) {
            guard canInspectLocal(), !isSame(node, element),
                  !inspected.contains(where: { isSame($0, node) }) else { return }
            inspected.append(node)
            guard let snapshot = read(node, required: false) else { return }
            let rect = bounds(snapshot)
            // Static text belongs to the editable content. The presentation
            // layer protects glyph/caret geometry separately; a multiline AX
            // text bounding box is not a control-shaped obstacle.
            if snapshot.role == "AXStaticText" { return }
            if ["AXTextField", "AXTextArea", "AXComboBox"].contains(snapshot.role), rect == fieldRect { return }
            if controls.contains(snapshot.role) {
                if let rect, rect.intersects(fieldRect), !exclusions.contains(rect) {
                    exclusions.append(rect); excludedBranches += 1
                }
                return
            }
            guard depth < 2, canInspectLocal() else { return }
            if let descendants = children(node, min(16, remaining - 2)) {
                for child in descendants { inspectLocal(child, depth: depth + 1) }
            } else if let rect, rect.intersects(fieldRect), !neutralContainers.contains(snapshot.role),
                      rect.width < fieldRect.width || rect.height < fieldRect.height {
                // An opaque, bounded leaf local to the editor is an obstacle.
                // Layout wrappers and missing bounds require candidate-local
                // verification, not a whole-window disappearance.
                if !exclusions.contains(rect) { exclusions.append(rect); excludedBranches += 1 }
            }
        }
        if canInspectLocal(), let localChildren = children(element, min(16, remaining - 2)) {
            for child in localChildren { inspectLocal(child, depth: 0) }
        }
        if canInspectLocal(), let enclosing = parent(element), !isSame(enclosing, sourceWindow),
           !isSame(enclosing, element), let enclosingGeometry = read(enclosing, required: false),
           neutralContainers.contains(enclosingGeometry.role) {
            ancestorCount = 1
            // A positively bounded scroll area is the visible editor viewport.
            // Ordinary layout-group frames are not a clipping contract.
            if enclosingGeometry.role == "AXScrollArea", let visibleEditor = bounds(enclosingGeometry) {
                let clipped = fieldRect.intersection(visibleEditor)
                guard OverlayGeometry.isFiniteRect(clipped) else { failure = .fieldOutsideViewport; return nil }
                fieldRect = clipped; viewport = (enclosing, visibleEditor)
            }
            if canInspectLocal(), let neighbors = children(enclosing, min(16, remaining - 2)),
               neighbors.contains(where: { isSame($0, element) }) {
                for neighbor in neighbors where !isSame(neighbor, element) { inspectLocal(neighbor, depth: 0) }
            }
        }
        if canInspectLocal(), let protectedGeometry {
            for rect in protectedGeometry(element) where OverlayGeometry.isFiniteRect(rect) && rect.intersects(fieldRect) {
                if !exclusions.contains(rect) { exclusions.append(rect) }
            }
        }
        guard inTime() else { return nil }
        let finalField = geometry(element)
        guard inTime() else { return nil }
        guard let finalField, bounds(finalField) == rawFieldRect, finalField.role == field.role else {
            failure = .fieldChanged; return nil
        }
        let finalWindow = window(element)
        guard inTime() else { return nil }
        guard let finalWindow, isSame(finalWindow, sourceWindow) else {
            failure = .windowChanged; return nil
        }
        let finalWindowGeometry = geometry(sourceWindow)
        guard inTime() else { return nil }
        guard let finalWindowGeometry, bounds(finalWindowGeometry) == windowRect,
              finalWindowGeometry.role == windowGeometry.role else {
            failure = .windowChanged; return nil
        }
        if let viewport {
            let finalViewport = geometry(viewport.0)
            guard inTime() else { return nil }
            guard let finalViewport, finalViewport.role == "AXScrollArea", bounds(finalViewport) == viewport.1 else {
                failure = .fieldChanged; return nil
            }
        }
        return FieldOverlayGeometry(fieldRect: fieldRect, windowRect: windowRect, exclusionRects: exclusions)
    }

    enum TargetHitTest: Equatable { case field, blocked, unavailable }

    /// Probe only this candidate, through the source application's hit API.
    /// Unknown/coarse APIs remain distinguishable from a positively located
    /// control. No window tree or text/label reads are needed for this proof.
    static func targetHitTest<Node>(frame: CGRect, source: Node, sourceWindow: Node?,
                                    hit: (CGPoint) -> Node?, role: (Node) -> String?,
                                    parent: (Node) -> Node?, isSame: (Node, Node) -> Bool,
                                    belongsToSourceApplication: (Node) -> Bool?,
                                    now: () -> TimeInterval, deadline: TimeInterval) -> TargetHitTest {
        guard OverlayGeometry.isFiniteRect(frame) else { return .unavailable }
        func inTime() -> Bool { now() < deadline }
        func belongsToField(_ node: Node) -> Bool? {
            if isSame(node, source) { return true }
            var branch = node
            var visited = [node]
            for _ in 0..<4 {
                guard inTime(), let enclosing = parent(branch), inTime() else { return nil }
                if isSame(enclosing, source) { return true }
                if let sourceWindow, isSame(enclosing, sourceWindow) { return false }
                if visited.contains(where: { isSame($0, enclosing) }) { return nil }
                visited.append(enclosing); branch = enclosing
            }
            return nil
        }
        let inset = min(1, min(frame.width, frame.height) / 4)
        let points = [CGPoint(x: frame.midX, y: frame.midY),
            CGPoint(x: frame.minX + inset, y: frame.minY + inset),
            CGPoint(x: frame.maxX - inset, y: frame.minY + inset),
            CGPoint(x: frame.minX + inset, y: frame.maxY - inset),
            CGPoint(x: frame.maxX - inset, y: frame.maxY - inset)]
        let controlRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXSwitch",
            "AXLink", "AXMenuItem", "AXPopUpButton", "AXTabGroup", "AXScrollBar", "AXIncrementor"]
        var unavailable = false
        for point in points {
            guard inTime(), let target = hit(point), inTime() else { return .unavailable }
            if isSame(target, source) { continue }
            let applicationOwnership = belongsToSourceApplication(target)
            guard inTime() else { return .unavailable }
            if applicationOwnership == false { return .blocked }
            guard inTime(), let targetRole = role(target), inTime() else { return .unavailable }
            if controlRoles.contains(targetRole) { return .blocked }
            if ["AXTextField", "AXTextArea", "AXComboBox", "AXStaticText"].contains(targetRole) {
                let ownership = belongsToField(target)
                guard inTime() else { return .unavailable }
                if ownership == true { continue }
                if ownership == false, targetRole != "AXStaticText" { return .blocked }
            }
            unavailable = true
        }
        return unavailable ? .unavailable : .field
    }

}
