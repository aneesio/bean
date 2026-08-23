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

    private var highlightPanels: [UUID: OverlayPanel] = [:]
    private var cardPanel: OverlayPanel?
    private var renderedEntries: [Entry] = []
    private var renderedSelectedID: UUID?
    private var hoverSampleTimer: Timer?
    private var hoverCandidateID: UUID?
    private var hoverCandidateSince: Date?
    private var cardIsInteractive = false
    private var cardFocusSession: OverlaySourceFocusSession?

    private let hoverDelay: TimeInterval = 0.2
    private let hoverSampleInterval: TimeInterval = 0.1

    var isShowing: Bool { !highlightPanels.isEmpty }

    // MARK: - Render

    func render(entries: [Entry], selectedID: UUID?, position: (index: Int, total: Int)?) {
        guard !entries.isEmpty else { hide(); return }
        renderedEntries = entries
        renderedSelectedID = selectedID
        startHoverSamplingIfNeeded()

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
        stopHoverSampling()
        renderedEntries = []
        renderedSelectedID = nil
        for panel in highlightPanels.values { panel.orderOut(nil) }
        highlightPanels.removeAll()
        hideCard()
    }

    // MARK: - Highlight panels

    /// Only a narrow strip around the underline is interactive. Covering the
    /// full glyph rect would prevent ordinary caret placement and selection in
    /// the source field.
    private func highlightFrame(_ rect: CGRect) -> NSRect {
        OverlayGeometry.highlightInteractionFrame(for: rect)
    }

    private func makeHighlightPanel(for id: UUID, frame: NSRect) -> OverlayPanel {
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
        view.onClick = { [weak self] in self?.activateIssue(id, intent: .explicit) }
        panel.contentView = view
        panel.orderFrontRegardless()
        return panel
    }

    /// Samples global mouse location instead of placing a large transparent
    /// window over editable text. The >=28pt hover target is therefore forgiving
    /// while every ordinary source-field click still reaches the source app.
    private func startHoverSamplingIfNeeded() {
        guard hoverSampleTimer == nil else { return }
        let timer = Timer(timeInterval: hoverSampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleHover(at: NSEvent.mouseLocation, now: Date()) }
        }
        timer.tolerance = hoverSampleInterval / 3
        RunLoop.main.add(timer, forMode: .common)
        hoverSampleTimer = timer
    }

    private func stopHoverSampling() {
        hoverSampleTimer?.invalidate()
        hoverSampleTimer = nil
        hoverCandidateID = nil
        hoverCandidateSince = nil
    }

    private func sampleHover(at point: CGPoint, now: Date) {
        // A deliberately opened card owns keyboard/VoiceOver interaction until
        // it is dismissed; passing over another underline must not replace it.
        guard !cardIsInteractive else {
            hoverCandidateID = nil
            hoverCandidateSince = nil
            return
        }
        let candidate = renderedEntries
            .filter { OverlayGeometry.highlightHoverFrame(for: $0.rect).contains(point) }
            .min { lhs, rhs in
                squaredDistance(point, lhs.rect.center) < squaredDistance(point, rhs.rect.center)
            }

        guard let id = candidate?.issue.id else {
            hoverCandidateID = nil
            hoverCandidateSince = nil
            return
        }
        if hoverCandidateID != id {
            hoverCandidateID = id
            hoverCandidateSince = now
            return
        }
        guard renderedSelectedID != id,
              let since = hoverCandidateSince,
              now.timeIntervalSince(since) >= hoverDelay else { return }
        activateIssue(id, intent: .passiveHover)
    }

    private func activateIssue(_ id: UUID, intent: OverlayActivationIntent) {
        if intent.allowsKeyboardInteraction, !cardIsInteractive {
            cardFocusSession = OverlaySourceFocusSession.capture()
            cardIsInteractive = true
        }
        onActivateIssue?(id)
        if cardIsInteractive, let cardPanel {
            makeInteractive(cardPanel)
        }
    }

    // MARK: - Correction card

    private func showCard(for entry: Entry, position: (index: Int, total: Int)?) {
        let total = position?.total ?? 1
        let model = CardModel(
            issue: entry.issue,
            positionText: position.map { "\($0.index + 1) of \($0.total)" },
            showNext: total > 1,
            showExplanation: showExplanation,
            onApply: { [weak self] in self?.applyFromCard(entry.issue.id) },
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
            panel.onExplicitInteraction = { [weak self] in self?.promoteCardFromExplicitInteraction() }
            panel.contentViewController = host
            cardPanel = panel
        }
        cardPanel?.allowsKeyInteraction = cardIsInteractive
        cardPanel?.setContentSize(host.view.fittingSize)
        anchorCard(cardPanel!, to: entry.rect)
        if cardIsInteractive {
            makeInteractive(cardPanel!, firstResponder: host.view)
        } else {
            cardPanel?.orderFrontRegardless()
        }
    }

    private func hideCard() {
        let shouldRefreshDock = cardPanel?.allowsKeyInteraction == true
        cardPanel?.orderOut(nil)
        cardPanel = nil
        cardIsInteractive = false
        let focusSession = cardFocusSession
        cardFocusSession = nil
        focusSession?.restoreIfAppropriate()
        if shouldRefreshDock { DockPresence.refreshAfterWindowChange() }
    }

    private func applyFromCard(_ id: UUID) {
        // Inline apply validates that the original AX field is focused. Restore
        // it now and again on the next run loop before entering that safety
        // check. Application activation is asynchronous, while the second AX
        // focus write makes the focused-element guard deterministic.
        let focusSession = cardFocusSession
        cardPanel?.resignKey()
        focusSession?.restoreIfAppropriate()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            focusSession?.restoreIfAppropriate()
            self.onApply?(id)
            if self.cardIsInteractive, let cardPanel = self.cardPanel, !cardPanel.isKeyWindow {
                self.makeInteractive(cardPanel, firstResponder: cardPanel.contentViewController?.view)
            }
        }
    }

    private func promoteCardFromExplicitInteraction() {
        guard !cardIsInteractive, let cardPanel else { return }
        cardFocusSession = OverlaySourceFocusSession.capture()
        cardIsInteractive = true
        makeInteractive(cardPanel, firstResponder: cardPanel.contentViewController?.view)
    }

    private func makeInteractive(_ panel: OverlayPanel, firstResponder: NSView? = nil) {
        panel.allowsKeyInteraction = true
        panel.becomesKeyOnlyIfNeeded = false
        DockPresence.prepareExplicitOverlay(panel, kind: "inline-correction-card")
        if let firstResponder { panel.initialFirstResponder = firstResponder }
        panel.makeKeyAndOrderFront(nil)
        if let firstResponder { panel.makeFirstResponder(firstResponder) }
    }

    /// Anchor the card above the issue (preferred), or below if there's no room.
    private func anchorCard(_ panel: NSPanel, to rect: CGRect) {
        let screens = OverlayScreenArea.current
        guard let screen = OverlayGeometry.screen(containing: rect, from: screens) else { return }
        panel.setFrameOrigin(OverlayGeometry.cardOrigin(
            anchoredTo: rect,
            panelSize: panel.frame.size,
            in: screen.visibleFrame
        ))
    }

    private func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}

private final class OverlayPanel: NSPanel {
    var allowsKeyInteraction = false
    var onExplicitInteraction: (() -> Void)?
    override var canBecomeKey: Bool { allowsKeyInteraction }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { onExplicitInteraction?() }
        super.sendEvent(event)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

// MARK: - Highlight hit view (draws underline + hover/click)

private final class HighlightHitView: NSView {
    var onClick: (() -> Void)?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Subtle warm dashed underline near the bottom of the range.
        let color = NSColor(BeanDesign.accent).withAlphaComponent(0.85)
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.setLineDash([2.5, 2.0], count: 2, phase: 0)
        path.lineCapStyle = .round
        let y: CGFloat = 3
        path.move(to: NSPoint(x: 2, y: y))
        path.line(to: NSPoint(x: bounds.width - 2, y: y))
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
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
                Button(action: model.onClose) {
                    Image(systemName: "xmark")
                        .frame(
                            width: OverlayGeometry.minimumMotorTarget,
                            height: OverlayGeometry.minimumMotorTarget
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .font(.system(size: 11, weight: .semibold))
                .accessibilityLabel("Close suggestion")
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
                Button { model.onIgnore() } label: {
                    Text("Ignore")
                        .frame(minHeight: OverlayGeometry.minimumMotorTarget)
                        .contentShape(Rectangle())
                }
                .controlSize(.small)
                Spacer()
                if model.showNext {
                    Button { model.onNext() } label: {
                        Image(systemName: "arrow.right")
                            .frame(
                                width: OverlayGeometry.minimumMotorTarget,
                                height: OverlayGeometry.minimumMotorTarget
                            )
                            .contentShape(Rectangle())
                    }
                    .controlSize(.small)
                    .help("Next suggestion")
                    .accessibilityLabel("Next suggestion")
                }
                Button { model.onApply() } label: {
                    Text("Apply")
                        .frame(minHeight: OverlayGeometry.minimumMotorTarget)
                        .contentShape(Rectangle())
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
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
