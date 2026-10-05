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

    private var bubbleSize = OverlayGeometry.beanLauncherSize
    private var bubbleView: BeanBubbleView?

    // Legacy drag offsets remain usable only while the whole target has a
    // freshly verified inside-field destination clear of known text/controls.
    private var bubbleBaseOrigin: NSPoint = .zero
    private var bubbleSavedOffset: CGSize = .zero
    private var onCommitOffset: ((CGSize) -> Void)?
    private var onResetOffset: (() -> Void)?
    private var isSafeOrigin: ((CGPoint) -> Bool)?

    var isShowing: Bool { bubblePanel != nil || menuPanel != nil }
    var isMenuOpen: Bool { menuPanel != nil }
    var ownsKeyboardInteraction: Bool { menuPanel?.allowsKeyInteraction == true }

    // MARK: - Bubble

    func showBubble(at point: CGPoint, savedOffset: CGSize, openOnHover: Bool,
                    targetSize: CGFloat = OverlayGeometry.beanLauncherSize,
                    isSafeOrigin: @escaping (CGPoint) -> Bool,
                    onOpen: @escaping (OverlayActivationIntent) -> Void,
                    onDismiss: @escaping () -> Void,
                    onCommitOffset: @escaping (CGSize) -> Void, onReset: @escaping () -> Void) {
        hide()
        bubbleSize = targetSize
        bubbleBaseOrigin = NSPoint(x: point.x, y: point.y)
        bubbleSavedOffset = savedOffset
        self.onCommitOffset = onCommitOffset
        self.onResetOffset = onReset
        self.isSafeOrigin = isSafeOrigin
        let origin = NSPoint(x: bubbleBaseOrigin.x + savedOffset.width, y: bubbleBaseOrigin.y + savedOffset.height)
        guard isSafeOrigin(origin) else { return }
        let view = BeanBubbleView(
            openOnHover: openOnHover, onOpen: onOpen, onDismiss: onDismiss, targetSize: targetSize,
            onResetPosition: { [weak self] in self?.resetBubblePosition() },
            onDragChanged: { [weak self] t in self?.dragBubble(t) },
            onDragEnded: { [weak self] t, moved in self?.endDragBubble(t, moved: moved, onOpen: onOpen) }
        )
        bubbleView = view
        let panel = makePanel(size: NSSize(width: bubbleSize, height: bubbleSize))
        panel.contentViewController = NSHostingController(rootView: view)
        // Attaching an NSHostingController can reset a borderless panel's
        // initial frame; restore the actual validated motor target explicitly.
        panel.setContentSize(NSSize(width: bubbleSize, height: bubbleSize))
        panel.setAccessibilityTitle("Bean writing control")
        panel.setAccessibilityIdentifier("com.bean.overlay.legacy-control")
        panel.setFrameOrigin(origin)
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

    func moveBubble(to point: CGPoint, targetSize: CGFloat? = nil) {
        guard let bubblePanel else { return }
        if let targetSize, targetSize != bubbleSize, var view = bubbleView {
            bubbleSize = targetSize
            view.targetSize = targetSize
            bubbleView = view
            bubblePanel.contentViewController = NSHostingController(rootView: view)
            bubblePanel.setContentSize(NSSize(width: targetSize, height: targetSize))
        }
        bubbleBaseOrigin = point
        var origin = CGPoint(
            x: point.x + bubbleSavedOffset.width,
            y: point.y + bubbleSavedOffset.height
        )
        if isSafeOrigin?(origin) != true {
            // A saved offset never overrides a newly occupied destination.
            origin = point
            bubbleSavedOffset = .zero
            onResetOffset?()
        }
        guard isSafeOrigin?(origin) == true else { hide(); return }
        bubblePanel.setFrameOrigin(origin)
    }

    // SwiftUI drag translation is y-DOWN; AppKit origin is y-UP → subtract height.
    private func dragBubble(_ t: CGSize) {
        guard let panel = bubblePanel else { return }
        if menuPanel != nil { hideMenu() } // never keep the menu open while dragging
        let origin = NSPoint(x: bubbleBaseOrigin.x + bubbleSavedOffset.width + t.width,
                             y: bubbleBaseOrigin.y + bubbleSavedOffset.height - t.height)
        guard isSafeOrigin?(origin) == true else { hide(); return }
        panel.setFrameOrigin(origin)
    }

    private func endDragBubble(
        _ t: CGSize,
        moved: Bool,
        onOpen: @escaping (OverlayActivationIntent) -> Void
    ) {
        // A press that didn't move past the threshold is a click → open the menu.
        guard moved, let panel = bubblePanel else { onOpen(.pointer); return }
        let final = panel.frame.origin
        guard isSafeOrigin?(final) == true else { hide(); return }
        let offset = CGSize(width: final.x - bubbleBaseOrigin.x, height: final.y - bubbleBaseOrigin.y)
        bubbleSavedOffset = offset
        onCommitOffset?(offset)
    }

    func resetBubblePosition() {
        bubbleSavedOffset = .zero
        guard isSafeOrigin?(bubbleBaseOrigin) == true else { hide(); return }
        if let panel = bubblePanel { panel.setFrameOrigin(bubbleBaseOrigin) }
        onResetOffset?()
    }

    var bubbleFrame: CGRect? { bubblePanel?.frame }

    // MARK: - Mini menu

    func showMenu(near point: CGPoint, intent: OverlayActivationIntent, aiAvailable: Bool, scope: String = "draft",
                  onSelect: @escaping (WritingAction) -> Void,
                  onParagraphSelect: ((WritingAction) -> Void)? = nil,
                  onSetUpAI: @escaping (WritingAction) -> Void,
                  onMore: @escaping () -> Void, onCancel: @escaping () -> Void) {
        menuPanel?.orderOut(nil)
        if intent.allowsKeyboardInteraction, menuFocusSession == nil {
            menuFocusSession = OverlaySourceFocusSession.capture()
        }
        let allowsKeyboardInteraction = menuFocusSession != nil
        let view = MiniActionMenuView(aiAvailable: aiAvailable, scope: scope, onSelect: onSelect,
                                      onParagraphSelect: onParagraphSelect,
                                      onSetUpAI: onSetUpAI, onMore: onMore,
                                      onCancel: onCancel)
        let panel = makePanel(size: NSSize(width: 220, height: 240))
        panel.allowsKeyInteraction = allowsKeyboardInteraction
        let host = NSHostingController(rootView: view)
        panel.contentViewController = host
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
        let shouldRestoreFocus = menuPanel?.isKeyWindow == true
        menuPanel?.orderOut(nil)
        menuPanel = nil
        let focusSession = menuFocusSession
        menuFocusSession = nil
        if shouldRestoreFocus { focusSession?.restoreIfAppropriate() }
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
        bubbleView = nil
        isSafeOrigin = nil
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
    var targetSize: CGFloat = OverlayGeometry.beanLauncherSize
    var onResetPosition: () -> Void = {}
    var onDragChanged: (CGSize) -> Void = { _ in }
    var onDragEnded: (CGSize, Bool) -> Void = { _, _ in }
    @State private var dragging = false

    // Past this many points a press is a drag, not a click.
    private let dragThreshold: CGFloat = 4

    var body: some View {
        ZStack { NativeStatusDot(hasSuggestions: false) }
            .frame(
                width: targetSize,
                height: targetSize
            )
            .contentShape(Rectangle())
            .help("Bean: live checking unavailable here. Click for writing actions.")
            .onHover { h in
                if h && openOnHover && !dragging { onOpen(.passiveHover) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Bean: live checking unavailable here. Open writing actions.")
            .accessibilityHint("Shows writing actions")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpen(.explicit) }
            .contextMenu {
                Button("Reset launcher position", action: onResetPosition)
                Button("Hide launcher in this field", action: onDismiss)
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
    let aiAvailable: Bool
    var scope = "draft"
    let onSelect: (WritingAction) -> Void
    var onParagraphSelect: ((WritingAction) -> Void)? = nil
    let onSetUpAI: (WritingAction) -> Void
    let onMore: () -> Void
    let onCancel: () -> Void
    @State private var currentParagraph = false
    private var actionScope: String { scope != "selected text" && currentParagraph ? "current paragraph" : scope }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                BeanMark(size: 16)
                Text("Bean").font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(.bottom, 2)

            Text("Improve \(actionScope)").font(.system(size: 11)).foregroundColor(.secondary)
            if scope != "selected text", onParagraphSelect != nil {
                Picker("Writing scope", selection: $currentParagraph) {
                    Text("Draft").tag(false)
                    Text("Paragraph").tag(true)
                }.pickerStyle(.segmented)
            }
            ForEach([aiAvailable ? WritingAction.proofread : .localQuickCheck, .makeClearer, .makeConcise, .makeProfessional, .makeCasual]) { action in
                let requiresSetup = action.requiresAISetup(aiAvailable: aiAvailable)
                MiniRow(symbol: requiresSetup ? "lock.fill" : action.symbolName,
                        title: action.category == .proofread ? "Proofread \(actionScope)" : action.displayName,
                        detail: requiresSetup ? "Set Up AI" : nil) {
                    if requiresSetup {
                        onSetUpAI(action)
                    } else {
                        if currentParagraph, scope != "selected text", let onParagraphSelect { onParagraphSelect(action) }
                        else { onSelect(action) }
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
