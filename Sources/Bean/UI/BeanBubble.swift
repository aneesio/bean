import AppKit
import SwiftUI

// The tiny contextual Bean bubble and its compact mini action menu. Both live in
// NON-activating, non-key panels so they never steal typing focus from the
// user's app (target acquisition stays safe).
@MainActor
final class BeanBubbleController {
    private var bubblePanel: NSPanel?
    private var menuPanel: NSPanel?

    private let bubbleSize: CGFloat = 24

    // Drag state. The bubble can be dragged off text that it covers; the offset
    // (in AppKit screen coords, y-up) is owned by the service and reapplied to the
    // anchor each time the bubble is shown for the same field.
    private var bubbleBaseOrigin: NSPoint = .zero
    private var bubbleSavedOffset: CGSize = .zero
    private var onCommitOffset: ((CGSize) -> Void)?
    private var onResetOffset: (() -> Void)?

    var isShowing: Bool { bubblePanel != nil || menuPanel != nil }
    var isMenuOpen: Bool { menuPanel != nil }

    // MARK: - Bubble

    func showBubble(at point: CGPoint, savedOffset: CGSize, openOnHover: Bool,
                    onOpen: @escaping () -> Void, onDismiss: @escaping () -> Void,
                    onCommitOffset: @escaping (CGSize) -> Void, onReset: @escaping () -> Void) {
        hide()
        bubbleBaseOrigin = NSPoint(x: point.x, y: point.y)
        bubbleSavedOffset = savedOffset
        self.onCommitOffset = onCommitOffset
        self.onResetOffset = onReset
        let view = BeanBubbleView(
            openOnHover: openOnHover, onOpen: onOpen, onDismiss: onDismiss,
            onDragChanged: { [weak self] t in self?.dragBubble(t) },
            onDragEnded: { [weak self] t, moved in self?.endDragBubble(t, moved: moved, onOpen: onOpen) }
        )
        let panel = makePanel(size: NSSize(width: bubbleSize, height: bubbleSize))
        panel.contentViewController = NSHostingController(rootView: view)
        let origin = NSPoint(x: bubbleBaseOrigin.x + savedOffset.width, y: bubbleBaseOrigin.y + savedOffset.height)
        panel.setFrameOrigin(clampedBubbleOrigin(origin))
        bubblePanel = panel
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    private func clampedBubbleOrigin(_ p: NSPoint) -> NSPoint {
        guard let screen = NSScreen.main else { return p }
        let v = screen.visibleFrame
        return NSPoint(x: min(max(p.x, v.minX + 2), v.maxX - bubbleSize - 2),
                       y: min(max(p.y, v.minY + 2), v.maxY - bubbleSize - 2))
    }

    // SwiftUI drag translation is y-DOWN; AppKit origin is y-UP → subtract height.
    private func dragBubble(_ t: CGSize) {
        guard let panel = bubblePanel else { return }
        if menuPanel != nil { hideMenu() } // never keep the menu open while dragging
        let origin = NSPoint(x: bubbleBaseOrigin.x + bubbleSavedOffset.width + t.width,
                             y: bubbleBaseOrigin.y + bubbleSavedOffset.height - t.height)
        panel.setFrameOrigin(clampedBubbleOrigin(origin))
    }

    private func endDragBubble(_ t: CGSize, moved: Bool, onOpen: @escaping () -> Void) {
        // A press that didn't move past the threshold is a click → open the menu.
        guard moved, let panel = bubblePanel else { onOpen(); return }
        let final = panel.frame.origin
        let offset = CGSize(width: final.x - bubbleBaseOrigin.x, height: final.y - bubbleBaseOrigin.y)
        bubbleSavedOffset = offset
        onCommitOffset?(offset)
    }

    func resetBubblePosition() {
        bubbleSavedOffset = .zero
        if let panel = bubblePanel { panel.setFrameOrigin(clampedBubbleOrigin(bubbleBaseOrigin)) }
        onResetOffset?()
    }

    var bubbleFrame: CGRect? { bubblePanel?.frame }

    // MARK: - Mini menu

    func showMenu(near point: CGPoint, onSelect: @escaping (WritingAction) -> Void,
                  onMore: @escaping () -> Void, onCancel: @escaping () -> Void) {
        menuPanel?.orderOut(nil)
        let view = MiniActionMenuView(onSelect: onSelect, onMore: onMore, onCancel: onCancel)
        let panel = makePanel(size: NSSize(width: 200, height: 240))
        panel.contentViewController = NSHostingController(rootView: view)
        panel.setContentSize(panel.contentViewController!.view.fittingSize)
        positionMenu(panel, near: point)
        menuPanel = panel
        panel.orderFrontRegardless()
    }

    func hideMenu() {
        menuPanel?.orderOut(nil)
        menuPanel = nil
    }

    func hide() {
        bubblePanel?.orderOut(nil); bubblePanel = nil
        menuPanel?.orderOut(nil); menuPanel = nil
    }

    // MARK: - Panels

    private func makePanel(size: NSSize) -> NSPanel {
        let panel = NonKeyBubblePanel(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func positionMenu(_ panel: NSPanel, near point: CGPoint) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        // Below-left of the bubble by default; clamp on-screen.
        var x = point.x
        var y = point.y - size.height - 4
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        if y < visible.minY + 8 { y = point.y + 28 } // flip above if no room below
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private final class NonKeyBubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Bubble view

struct BeanBubbleView: View {
    let openOnHover: Bool
    let onOpen: () -> Void
    let onDismiss: () -> Void
    var onDragChanged: (CGSize) -> Void = { _ in }
    var onDragEnded: (CGSize, Bool) -> Void = { _, _ in }
    @State private var hovering = false
    @State private var dragging = false

    // Past this many points a press is a drag, not a click.
    private let dragThreshold: CGFloat = 4

    var body: some View {
        BeanMark(size: 24)
            .opacity(hovering ? 1.0 : 0.82)
            .scaleEffect(dragging ? 1.12 : (hovering ? 1.06 : 1.0))
            .shadow(color: .black.opacity(0.22), radius: (hovering || dragging) ? 4 : 2, y: 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.10), value: dragging)
            .contentShape(Rectangle())
            .help("Click Bean to choose an action — drag it if it covers your text")
            .onHover { h in
                hovering = h
                if h && openOnHover && !dragging { onOpen() }
            }
            // minimumDistance 0 so a plain click also routes here: zero movement →
            // treated as a click (open menu); movement past threshold → drag.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if hypot(v.translation.width, v.translation.height) > dragThreshold {
                            dragging = true
                            onDragChanged(v.translation)
                        }
                    }
                    .onEnded { v in
                        let moved = hypot(v.translation.width, v.translation.height) > dragThreshold
                        onDragEnded(v.translation, moved)
                        dragging = false
                    }
            )
    }
}

// MARK: - Mini menu view

struct MiniActionMenuView: View {
    let onSelect: (WritingAction) -> Void
    let onMore: () -> Void
    let onCancel: () -> Void

    // Highest-value subset of actions.
    private let actions: [WritingAction] = [.proofread, .makeClearer, .makeConcise, .draftReply, .composeMessage]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                BeanMark(size: 16)
                Text("Bean").font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(.bottom, 2)

            ForEach(actions) { action in
                MiniRow(symbol: action.symbolName, title: miniLabel(action)) { onSelect(action) }
            }
            Divider().opacity(0.4).padding(.vertical, 2)
            MiniRow(symbol: "ellipsis.circle", title: "More…") { onMore() }
        }
        .padding(8)
        .frame(width: 200)
        .tint(BeanDesign.accent)
        .background(
            RoundedRectangle(cornerRadius: BeanDesign.Radius.card)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        )
        .onExitCommand(perform: onCancel)
    }

    private func miniLabel(_ action: WritingAction) -> String {
        switch action {
        case .draftReply: return "Reply"
        case .composeMessage: return "Compose"
        default: return action.displayName
        }
    }
}

private struct MiniRow: View {
    let symbol: String
    let title: String
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16).foregroundColor(BeanDesign.accent)
                Text(title).font(.system(size: 13))
                Spacer()
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? BeanDesign.accent.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
