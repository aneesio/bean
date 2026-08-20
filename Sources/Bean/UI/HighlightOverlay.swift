import AppKit
import SwiftUI

// Inline-highlights overlay (redesigned). Each issue gets a tiny, transparent,
// non-activating panel positioned exactly over its text range that draws the
// underline AND handles hover/click — so the highlight itself is the affordance
// (no top-right badge). A separate anchored panel shows the correction card next
// to the issue. The service owns the issue list + selection; this controller
// just renders and forwards interactions.
@MainActor
final class HighlightOverlayController {
    struct Entry { let issue: TextIssue; let rect: CGRect } // rect in Cocoa screen coords

    // Interaction callbacks (set by the service).
    var onActivateIssue: ((UUID) -> Void)?   // hover or click a highlight
    var onApply: ((UUID) -> Void)?
    var onIgnore: ((UUID) -> Void)?
    var onNext: (() -> Void)?
    var onCloseCard: (() -> Void)?
    var showExplanation = true

    private var highlightPanels: [UUID: NSPanel] = [:]
    private var cardPanel: NSPanel?
    private var cardDismissTimer: Timer?

    var isShowing: Bool { !highlightPanels.isEmpty }

    // MARK: - Render

    func render(entries: [Entry], selectedID: UUID?, position: (index: Int, total: Int)?) {
        guard !entries.isEmpty else { hide(); return }

        // Sync highlight panels with the current entries.
        let ids = Set(entries.map { $0.issue.id })
        for (id, panel) in highlightPanels where !ids.contains(id) {
            panel.orderOut(nil); highlightPanels[id] = nil
        }
        for entry in entries {
            let frame = highlightFrame(entry.rect)
            if let panel = highlightPanels[entry.issue.id] {
                panel.setFrame(frame, display: false)
            } else {
                highlightPanels[entry.issue.id] = makeHighlightPanel(for: entry.issue.id, frame: frame)
            }
        }

        // Card for the selected issue (if any).
        if let selectedID, let entry = entries.first(where: { $0.issue.id == selectedID }) {
            showCard(for: entry, position: position)
        } else {
            hideCard()
        }
    }

    func hide() {
        cardDismissTimer?.invalidate(); cardDismissTimer = nil
        for panel in highlightPanels.values { panel.orderOut(nil) }
        highlightPanels.removeAll()
        hideCard()
    }

    // MARK: - Highlight panels

    /// The panel covers the issue text plus a little vertical room for the
    /// underline and easier hovering.
    private func highlightFrame(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.minX - 2, y: rect.minY - 4, width: rect.width + 4, height: rect.height + 6)
    }

    private func makeHighlightPanel(for id: UUID, frame: NSRect) -> NSPanel {
        let panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = HighlightHitView()
        view.onHover = { [weak self] in self?.onActivateIssue?(id) }
        view.onClick = { [weak self] in self?.onActivateIssue?(id) }
        panel.contentView = view
        panel.orderFrontRegardless()
        return panel
    }

    // MARK: - Correction card

    private func showCard(for entry: Entry, position: (index: Int, total: Int)?) {
        cardDismissTimer?.invalidate(); cardDismissTimer = nil

        let total = position?.total ?? 1
        let model = CardModel(
            issue: entry.issue,
            positionText: position.map { "\($0.index + 1) of \($0.total)" },
            showNext: total > 1,
            showExplanation: showExplanation,
            onApply: { [weak self] in self?.onApply?(entry.issue.id) },
            onIgnore: { [weak self] in self?.onIgnore?(entry.issue.id) },
            onNext: { [weak self] in self?.onNext?() },
            onClose: { [weak self] in self?.onCloseCard?() }
        )

        let host = NSHostingController(rootView: CorrectionCardView(model: model))
        if let cardPanel {
            cardPanel.contentViewController = host
        } else {
            let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentViewController = host
            cardPanel = panel
        }
        cardPanel?.setContentSize(host.view.fittingSize)
        anchorCard(cardPanel!, to: entry.rect)
        cardPanel?.orderFrontRegardless()

        // Fallback auto-dismiss if the user never interacts (kept generous; the
        // dispatcher also hides on typing / click-away / Esc / app change).
        cardDismissTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.onCloseCard?() }
        }
    }

    private func hideCard() {
        cardDismissTimer?.invalidate(); cardDismissTimer = nil
        cardPanel?.orderOut(nil)
        cardPanel = nil
    }

    /// Anchor the card above the issue (preferred), or below if there's no room.
    private func anchorCard(_ panel: NSPanel, to rect: CGRect) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let gap: CGFloat = 8

        var x = rect.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)

        var y = rect.maxY + gap // above the word (Cocoa y-up)
        if y + size.height > visible.maxY - 8 {
            y = rect.minY - size.height - gap // not enough room above → below
        }
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Highlight hit view (draws underline + hover/click)

private final class HighlightHitView: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    private var hoverTimer: Timer?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        // Subtle warm dashed underline near the bottom of the range.
        let color = NSColor(BeanDesign.accent).withAlphaComponent(0.85)
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.setLineDash([2.5, 2.0], count: 2, phase: 0)
        path.lineCapStyle = .round
        let y: CGFloat = 4
        path.move(to: NSPoint(x: 2, y: y))
        path.line(to: NSPoint(x: bounds.width - 2, y: y))
        path.stroke()
    }

    override func mouseEntered(with event: NSEvent) {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.onHover?() }
        }
    }
    override func mouseExited(with event: NSEvent) {
        hoverTimer?.invalidate(); hoverTimer = nil
    }
    override func mouseDown(with event: NSEvent) {
        hoverTimer?.invalidate(); hoverTimer = nil
        onClick?()
    }
}

// MARK: - Correction card

@MainActor
final class CardModel: ObservableObject {
    let issue: TextIssue
    let positionText: String?
    let showNext: Bool
    let showExplanation: Bool
    let onApply: () -> Void
    let onIgnore: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    init(issue: TextIssue, positionText: String?, showNext: Bool, showExplanation: Bool,
         onApply: @escaping () -> Void, onIgnore: @escaping () -> Void,
         onNext: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.issue = issue
        self.positionText = positionText
        self.showNext = showNext
        self.showExplanation = showExplanation
        self.onApply = onApply; self.onIgnore = onIgnore; self.onNext = onNext; self.onClose = onClose
    }
}

struct CorrectionCardView: View {
    @ObservedObject var model: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.sm) {
            HStack(spacing: 6) {
                StatusPill(text: model.issue.type.rawValue.capitalized, kind: .neutral, showsIcon: false)
                if let pos = model.positionText {
                    Text(pos).font(BeanDesign.Typography.caption()).foregroundColor(.secondary)
                }
                Spacer()
                Button(action: model.onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundColor(.secondary).font(.system(size: 11, weight: .semibold))
            }
            HStack(spacing: BeanDesign.Spacing.sm) {
                Text(model.issue.original).strikethrough().foregroundColor(.secondary)
                Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary)
                Text(model.issue.suggestion).fontWeight(.semibold).foregroundColor(BeanDesign.accent)
            }
            .font(.system(size: 14))
            .fixedSize(horizontal: false, vertical: true)

            if model.showExplanation, let explanation = model.issue.explanation, !explanation.isEmpty {
                Text(explanation).font(BeanDesign.Typography.caption()).foregroundColor(.secondary)
            }

            HStack {
                Button("Ignore") { model.onIgnore() }.controlSize(.small)
                Spacer()
                if model.showNext {
                    Button { model.onNext() } label: { Image(systemName: "arrow.right") }
                        .controlSize(.small).help("Next suggestion")
                }
                Button("Apply") { model.onApply() }.controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .padding(BeanDesign.Spacing.md)
        .frame(width: 300)
        .tint(BeanDesign.accent)
        .background(RoundedRectangle(cornerRadius: BeanDesign.Radius.card).fill(.regularMaterial)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4))
        .onExitCommand { model.onClose() }
    }
}
