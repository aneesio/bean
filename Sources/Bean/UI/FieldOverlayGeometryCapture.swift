import Foundation

/// The traversal is shared by the AX adapter and owned fixtures. Readers expose
/// only identity, role and geometry; the scanner never asks for writing/labels.
enum FieldOverlayGeometryCapture {
    struct NodeGeometry {
        let role: String
        let rect: CGRect
    }

    static func capture<Node>(element: Node,
                              window: (Node) -> Node?,
                              geometry: (Node) -> NodeGeometry?,
                              parent: (Node) -> Node?,
                              children: (Node, Int) -> [Node]?,
                              isSame: (Node, Node) -> Bool,
                              now: () -> TimeInterval,
                              deadline: TimeInterval) -> FieldOverlayGeometry? {
        let containers: Set<String> = ["AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXWebArea", "AXWindow"]
        var remaining = 48
        var visited: [(Node, NodeGeometry)] = []
        var exclusions: [CGRect] = []
        func inTime() -> Bool { now() < deadline }
        func read(_ node: Node) -> NodeGeometry? {
            if let existing = visited.first(where: { isSame($0.0, node) }) { return existing.1 }
            guard remaining > 0, inTime() else { return nil }
            remaining -= 1
            guard let snapshot = geometry(node), OverlayGeometry.isFiniteRect(snapshot.rect), inTime() else { return nil }
            visited.append((node, snapshot))
            return snapshot
        }
        guard let field = read(element), let sourceWindow = window(element), inTime(),
              let windowGeometry = read(sourceWindow), windowGeometry.role == "AXWindow",
              windowGeometry.rect.intersects(field.rect) else { return nil }
        let neighborhood = field.rect.insetBy(dx: -36, dy: -36)
        var inspected: [Node] = []
        func inspect(_ node: Node, depth: Int) -> Bool {
            // Each branch is processed once, including shared/cyclic AX nodes.
            if inspected.contains(where: { isSame($0, node) }) { return true }
            inspected.append(node)
            guard let snapshot = read(node) else { return false }
            guard snapshot.rect.intersects(neighborhood) else { return true }
            guard containers.contains(snapshot.role), depth < 2 else {
                exclusions.append(snapshot.rect); return true
            }
            guard let descendants = children(node, min(48, remaining + 1)), inTime() else { return false }
            if descendants.isEmpty { exclusions.append(snapshot.rect); return true }
            return descendants.allSatisfy { inspect($0, depth: depth + 1) }
        }
        var branch = element
        var reachedWindow = false
        var ancestry: [Node] = [element]
        for _ in 0..<8 {
            guard inTime(), let enclosing = parent(branch),
                  !ancestry.contains(where: { isSame($0, enclosing) }),
                  let enclosingGeometry = read(enclosing), containers.contains(enclosingGeometry.role),
                  let siblings = children(enclosing, min(48, remaining + 1)), inTime(),
                  siblings.contains(where: { isSame($0, branch) }) else { return nil }
            ancestry.append(enclosing)
            for sibling in siblings where !isSame(sibling, branch) {
                guard inspect(sibling, depth: 0) else { return nil }
            }
            if isSame(enclosing, sourceWindow) { reachedWindow = true; break }
            branch = enclosing
        }
        // Do not infer safety around an unscanned toolbar/popover branch.
        guard reachedWindow, inTime(), let finalField = geometry(element),
              finalField.rect == field.rect, finalField.role == field.role,
              let finalWindow = window(element), isSame(finalWindow, sourceWindow),
              let finalWindowGeometry = geometry(sourceWindow), finalWindowGeometry.rect == windowGeometry.rect,
              finalWindowGeometry.role == windowGeometry.role,
              inTime() else { return nil }
        return FieldOverlayGeometry(fieldRect: field.rect, windowRect: windowGeometry.rect, exclusionRects: exclusions)
    }
}
