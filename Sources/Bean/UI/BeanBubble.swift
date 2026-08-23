import AppKit
import SwiftUI

// The contextual Bean bubble stays passive while typing. Its menu only becomes
// key when the user deliberately clicks/presses the launcher; hover-opened UI
// remains nonactivating so target acquisition stays safe.
@MainActor
final class BeanBubbleController {
    private var bubblePanel: NonKeyBubblePanel?
    private var menuPanel: NonKeyBubblePanel?
    private var menuFocusSession: OverlaySourceFocusSession?

    private let bubbleSize = OverlayGeometry.beanLauncherSize

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
                    onOpen: @escaping (OverlayActivationIntent) -> Void,
                    onDismiss: @escaping () -> Void,
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
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
    }

    private func clampedBubbleOrigin(_ p: NSPoint) -> NSPoint {
        let screens = OverlayScreenArea.current
        let center = CGPoint(x: p.x + bubbleSize / 2, y: p.y + bubbleSize / 2)
        guard let screen = OverlayGeometry.screen(containing: center, from: screens) else { return p }
        return OverlayGeometry.clampedOrigin(
            p,
            panelSize: CGSize(width: bubbleSize, height: bubbleSize),
            in: screen.visibleFrame,
            inset: 2
        )
    }

    // SwiftUI drag translation is y-DOWN; AppKit origin is y-UP → subtract height.
    private func dragBubble(_ t: CGSize) {
        guard let panel = bubblePanel else { return }
        if menuPanel != nil { hideMenu() } // never keep the menu open while dragging
        let origin = NSPoint(x: bubbleBaseOrigin.x + bubbleSavedOffset.width + t.width,
                             y: bubbleBaseOrigin.y + bubbleSavedOffset.height - t.height)
        panel.setFrameOrigin(clampedBubbleOrigin(origin))
    }

    private func endDragBubble(
        _ t: CGSize,
        moved: Bool,
        onOpen: @escaping (OverlayActivationIntent) -> Void
    ) {
        // A press that didn't move past the threshold is a click → open the menu.
        guard moved, let panel = bubblePanel else { onOpen(.explicit); return }
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

    func showMenu(near point: CGPoint, intent: OverlayActivationIntent, aiAvailable: Bool,
                  onSelect: @escaping (WritingAction) -> Void,
                  onSetUpAI: @escaping (WritingAction) -> Void,
                  onMore: @escaping () -> Void, onCancel: @escaping () -> Void) {
        menuPanel?.orderOut(nil)
        if intent.allowsKeyboardInteraction, menuFocusSession == nil {
            menuFocusSession = OverlaySourceFocusSession.capture()
        }
        let allowsKeyboardInteraction = menuFocusSession != nil
        let view = MiniActionMenuView(aiAvailable: aiAvailable, onSelect: onSelect,
                                      onSetUpAI: onSetUpAI, onMore: onMore,
                                      onCancel: onCancel)
        let panel = makePanel(size: NSSize(width: 220, height: 240))
        panel.allowsKeyInteraction = allowsKeyboardInteraction
        let host = NSHostingController(rootView: view)
        panel.contentViewController = host
        panel.onExplicitInteraction = { [weak self, weak panel] in
            guard let panel else { return }
            self?.promoteMenuForExplicitInteraction(panel)
        }
        panel.setContentSize(host.view.fittingSize)
        positionMenu(panel, near: point)
        menuPanel = panel
        if allowsKeyboardInteraction {
            promoteMenuForExplicitInteraction(panel)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hideMenu() {
        let shouldRefreshDock = menuPanel?.allowsKeyInteraction == true
        menuPanel?.orderOut(nil)
        menuPanel = nil
        let focusSession = menuFocusSession
        menuFocusSession = nil
        focusSession?.restoreIfAppropriate()
        if shouldRefreshDock { DockPresence.refreshAfterWindowChange() }
    }

    private func promoteMenuForExplicitInteraction(_ panel: NonKeyBubblePanel) {
        guard menuPanel === panel else { return }
        if menuFocusSession == nil {
            menuFocusSession = OverlaySourceFocusSession.capture()
        }
        panel.allowsKeyInteraction = true
        panel.becomesKeyOnlyIfNeeded = false
        DockPresence.prepareExplicitOverlay(panel, kind: "bean-menu")
        if let contentView = panel.contentViewController?.view {
            panel.initialFirstResponder = contentView
        }
        panel.makeKeyAndOrderFront(nil)
        if let contentView = panel.contentViewController?.view {
            panel.makeFirstResponder(contentView)
        }
    }

    func hide() {
        bubblePanel?.orderOut(nil); bubblePanel = nil
        hideMenu()
    }

    // MARK: - Panels

    private func makePanel(size: NSSize) -> NonKeyBubblePanel {
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
        let screens = OverlayScreenArea.current
        guard let screen = OverlayGeometry.screen(containing: point, from: screens) else { return }
        panel.setFrameOrigin(OverlayGeometry.menuOrigin(
            below: point,
            panelSize: panel.frame.size,
            in: screen.visibleFrame,
            accessoryHeight: bubbleSize
        ))
    }
}

private final class NonKeyBubblePanel: NSPanel {
    var allowsKeyInteraction = false
    var onExplicitInteraction: (() -> Void)?
    override var canBecomeKey: Bool { allowsKeyInteraction }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { onExplicitInteraction?() }
        super.sendEvent(event)
    }
}

// MARK: - Bubble view

struct BeanBubbleView: View {
    let openOnHover: Bool
    let onOpen: (OverlayActivationIntent) -> Void
    let onDismiss: () -> Void
    var onDragChanged: (CGSize) -> Void = { _ in }
    var onDragEnded: (CGSize, Bool) -> Void = { _, _ in }
    @State private var hovering = false
    @State private var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Past this many points a press is a drag, not a click.
    private let dragThreshold: CGFloat = 4

    var body: some View {
        BeanMark(size: OverlayGeometry.beanLauncherSize)
            .frame(
                width: OverlayGeometry.beanLauncherSize,
                height: OverlayGeometry.beanLauncherSize
            )
            .opacity(hovering ? 1.0 : 0.82)
            .scaleEffect(dragging ? 1.12 : (hovering ? 1.06 : 1.0))
            .shadow(color: .black.opacity(0.22), radius: (hovering || dragging) ? 4 : 2, y: 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: dragging)
            .contentShape(Rectangle())
            .help("Click Bean to choose an action — drag it if it covers your text")
            .onHover { h in
                hovering = h
                if h && openOnHover && !dragging { onOpen(.passiveHover) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Open Bean")
            .accessibilityHint("Shows writing actions")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpen(.explicit) }
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
    let aiAvailable: Bool
    let onSelect: (WritingAction) -> Void
    let onSetUpAI: (WritingAction) -> Void
    let onMore: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                BeanMark(size: 16)
                Text("Bean").font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(.bottom, 2)

            ForEach(WritingAction.primaryActions) { action in
                let requiresSetup = action.requiresAISetup(aiAvailable: aiAvailable)
                MiniRow(symbol: requiresSetup ? "lock.fill" : action.symbolName,
                        title: action.displayName,
                        detail: requiresSetup ? "Set Up AI" : nil) {
                    if requiresSetup {
                        onSetUpAI(action)
                    } else {
                        onSelect(action)
                    }
                }
            }
            Divider().opacity(0.4).padding(.vertical, 2)
            MiniRow(symbol: "ellipsis.circle", title: "More…", detail: nil) { onMore() }
        }
        .padding(8)
        .frame(width: 220)
        .tint(BeanDesign.accent)
        .background(
            RoundedRectangle(cornerRadius: BeanDesign.Radius.card)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        )
        .onExitCommand(perform: onCancel)
    }
}

private struct MiniRow: View {
    let symbol: String
    let title: String
    let detail: String?
    let onTap: () -> Void
    @State private var hovering = false

    private var accessibilityTitle: String {
        detail.map { "\(title), \($0)" } ?? title
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16).foregroundColor(BeanDesign.accent)
                Text(title).font(.system(size: 13))
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .frame(minHeight: OverlayGeometry.minimumMotorTarget)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? BeanDesign.accent.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint(detail == "Set Up AI" ? "Opens AI setup" : "Runs \(title)")
    }
}
