import Foundation

/// The traversal is shared by the AX adapter and owned fixtures. Readers expose
/// only identity, role and geometry; the scanner never asks for writing/labels.
enum FieldOverlayGeometryCapture {
    struct NodeGeometry {
        let role: String
        let rect: CGRect?
    }

    enum FailureReason: String {
        case fieldBoundsUnavailable, windowUnavailable, windowBoundsUnavailable
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
                              onDiagnostics: ((Diagnostics) -> Void)? = nil) -> FieldOverlayGeometry? {
        let started = now()
        let containers: Set<String> = ["AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXWebArea", "AXWindow"]
        let leaves: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXSwitch",
            "AXLink", "AXMenuItem", "AXPopUpButton", "AXTextField", "AXTextArea", "AXComboBox",
            "AXStaticText", "AXImage", "AXScrollBar", "AXIncrementor", "AXProgressIndicator"]
        var remaining = 48
        var visited: [(Node, NodeGeometry)] = []
        var exclusions: [CGRect] = []
        var failure: FailureReason?
        var ancestorCount = 0
        var excludedBranches = 0
        defer {
            onDiagnostics?(.init(failureReason: failure, nodeCount: 48 - remaining,
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
        func read(_ node: Node) -> NodeGeometry? {
            if let existing = visited.first(where: { isSame($0.0, node) }) { return existing.1 }
            guard inTime() else { return nil }
            guard remaining > 0 else { failure = .nodeLimit; return nil }
            remaining -= 1
            guard let snapshot = geometry(node), !snapshot.role.isEmpty else {
                if inTime() { failure = .nodeUnavailable }; return nil
            }
            guard inTime() else { return nil }
            visited.append((node, snapshot))
            return snapshot
        }
        guard let field = read(element), let fieldRect = bounds(field) else {
            if failure == nil { failure = .fieldBoundsUnavailable }; return nil
        }
        guard let sourceWindow = window(element), inTime() else {
            if failure == nil { failure = .windowUnavailable }; return nil
        }
        guard let windowGeometry = read(sourceWindow), windowGeometry.role == "AXWindow",
              let windowRect = bounds(windowGeometry), windowRect.intersects(fieldRect) else {
            if failure == nil { failure = .windowBoundsUnavailable }; return nil
        }
        let neighborhood = fieldRect.insetBy(dx: -36, dy: -36)
        var inspected: [Node] = []
        func inspect(_ node: Node, depth: Int) -> Bool {
            if inspected.contains(where: { isSame($0, node) }) { return true }
            inspected.append(node)
            guard let snapshot = read(node) else { return false }
            let rect = bounds(snapshot)
            if leaves.contains(snapshot.role) {
                guard let rect else { failure = .unlocatedControl; return false }
                if rect.intersects(neighborhood) { exclusions.append(rect); excludedBranches += 1 }
                return true
            }
            // AXFrame is not a clipping contract. A container's descendants
            // can escape its rectangle, even when that frame is far away.
            // Resolve them completely within the budget or omit the control.
            let descendants = children(node, min(48, remaining + 1))
            guard inTime() else { return false }
            guard let descendants else { failure = .unresolvedContainer; return false }
            if descendants.isEmpty {
                guard let rect else { failure = .unlocatedControl; return false }
                if rect.intersects(neighborhood) { exclusions.append(rect); excludedBranches += 1 }
                return true
            }
            guard depth < 2 else { failure = .unresolvedContainer; return false }
            return descendants.allSatisfy { inspect($0, depth: depth + 1) }
        }
        var branch = element
        var reachedWindow = false
        var ancestry: [Node] = [element]
        for _ in 0..<8 {
            guard inTime() else { return nil }
            guard let enclosing = parent(branch),
                  !ancestry.contains(where: { isSame($0, enclosing) }),
                  let enclosingGeometry = read(enclosing), containers.contains(enclosingGeometry.role),
                  let siblings = children(enclosing, min(48, remaining + 1)),
                  siblings.contains(where: { isSame($0, branch) }) else {
                if failure == nil { failure = .sourcePathUnverified }; return nil
            }
            guard inTime() else { return nil }
            ancestorCount += 1
            ancestry.append(enclosing)
            for sibling in siblings where !isSame(sibling, branch) {
                guard inspect(sibling, depth: 0) else { return nil }
            }
            if isSame(enclosing, sourceWindow) { reachedWindow = true; break }
            branch = enclosing
        }
        guard reachedWindow else { failure = .ancestorDepthLimit; return nil }
        guard inTime() else { return nil }
        let finalField = geometry(element)
        guard inTime() else { return nil }
        guard let finalField, bounds(finalField) == fieldRect, finalField.role == field.role else {
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
        return FieldOverlayGeometry(fieldRect: fieldRect, windowRect: windowRect, exclusionRects: exclusions)
    }
}
