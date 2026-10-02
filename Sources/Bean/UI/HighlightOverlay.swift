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
    struct Entry { let issue: TextIssue; let rect: CGRect? } // nil: exact text, unavailable glyph bounds

    // Interaction callbacks (set by the service).
    var onActivateIssue: ((UUID) -> Void)?   // hover or click a highlight
    var onApply: ((UUID) -> Void)?
    var onApplyAlternative: ((UUID, String) -> Void)?
    var onIgnore: ((UUID) -> Void)?
    var onNext: (() -> Void)?
    var onCloseCard: (() -> Void)?
    var onWritingAction: (() -> Void)?
    var writingActionLabel = "Quick Fix"
    var showExplanation = true

    private var highlightPanels: [UUID: OverlayPanel] = [:]
    private var cardPanel: OverlayPanel?
    private var trayPanel: OverlayPanel?
    private var sourceAnchor: CGRect?
    private var cardPinned = false
    private var preferTrayCardAnchor = false
    private var renderedEntries: [Entry] = []
    private var renderedSelectedID: UUID?
    private var hoverSampleTimer: Timer?
    private var hoverCandidateID: UUID?
    private var hoverCandidateSince: Date?
    private var cardIsInteractive = false
    private var cardFocusSession: OverlaySourceFocusSession?
    private var lastHoverWithinCard: Date?

    private let hoverDelay: TimeInterval = 0.2
    private let hoverSampleInterval: TimeInterval = 0.1

    var isShowing: Bool { !highlightPanels.isEmpty || trayPanel != nil || cardPanel != nil }
    var ownsKeyboardInteraction: Bool { cardIsInteractive }

    // MARK: - Render

    func render(entries: [Entry], selectedID: UUID?, position: (index: Int, total: Int)?,
                sourceAnchor: CGRect? = nil) {
        guard !entries.isEmpty else { hide(); return }
        self.sourceAnchor = sourceAnchor
        renderedEntries = entries
        renderedSelectedID = selectedID
        startHoverSamplingIfNeeded()

        // Sync highlight panels with the current entries.
        let ids = Set(entries.filter { $0.rect != nil }.map { $0.issue.id })
        for (id, panel) in highlightPanels where !ids.contains(id) {
            panel.orderOut(nil); highlightPanels[id] = nil
        }
        for entry in entries {
            guard let rect = entry.rect else { continue }
            let frame = highlightFrame(rect)
            if let panel = highlightPanels[entry.issue.id] {
                panel.setFrame(frame, display: false)
            } else {
                highlightPanels[entry.issue.id] = makeHighlightPanel(for: entry.issue.id, frame: frame)
            }
        }
        showTray(issueCount: entries.count)

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
        trayPanel?.orderOut(nil)
        trayPanel = nil
        sourceAnchor = nil
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
        view.onClick = { [weak self] in self?.activateIssue(id, intent: .pointer) }
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
        guard !cardIsInteractive, !cardPinned else {
            hoverCandidateID = nil
            hoverCandidateSince = nil
            return
        }
        if let cardPanel, cardPanel.frame.insetBy(dx: -10, dy: -10).contains(point) {
            lastHoverWithinCard = now
            return
        }
        let candidate = renderedEntries
            .filter { $0.rect.map { OverlayGeometry.highlightHoverFrame(for: $0).contains(point) } ?? false }
            .min { lhs, rhs in
                squaredDistance(point, lhs.rect!.center) < squaredDistance(point, rhs.rect!.center)
            }

        guard let id = candidate?.issue.id else {
            hoverCandidateID = nil
            hoverCandidateSince = nil
            // Allow a short bridge from the underline to its card. A passive
            // card then closes as the pointer leaves the writing interaction.
            if renderedSelectedID != nil,
               now.timeIntervalSince(lastHoverWithinCard ?? now) > 0.6 {
                onCloseCard?()
            }
            return
        }
        lastHoverWithinCard = now
        if hoverCandidateID != id {
            hoverCandidateID = id
            hoverCandidateSince = now
            lastHoverWithinCard = now
            return
        }
        guard renderedSelectedID != id,
              let since = hoverCandidateSince,
              now.timeIntervalSince(since) >= hoverDelay else { return }
        activateIssue(id, intent: .passiveHover)
    }

    private func activateIssue(_ id: UUID, intent: OverlayActivationIntent, anchorToTray: Bool = false) {
        lastHoverWithinCard = Date()
        preferTrayCardAnchor = anchorToTray
        if intent != .passiveHover { cardPinned = true }
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
            onApplyAlternative: { [weak self] choice in self?.applyFromCard(entry.issue.id, choice: choice) },
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
            // Accept/Dismiss are direct pointer actions. Making this panel key
            // would move focus away from the field and race the live dispatcher.
            panel.onExplicitInteraction = { [weak self] in self?.cardPinned = true }
            panel.contentViewController = host
            cardPanel = panel
        }
        cardPanel?.allowsKeyInteraction = cardIsInteractive
        cardPanel?.setContentSize(host.view.fittingSize)
        let anchor = preferTrayCardAnchor ? trayPanel?.frame : entry.rect
        if let anchor = anchor ?? trayPanel?.frame ?? sourceAnchor {
            anchorCard(cardPanel!, to: anchor)
        }
        if cardIsInteractive {
            makeInteractive(cardPanel!, firstResponder: host.view)
        } else {
            cardPanel?.orderFrontRegardless()
        }
    }

    private func hideCard() {
        let shouldRefreshDock = cardPanel?.allowsKeyInteraction == true
        let shouldRestoreFocus = cardPanel?.isKeyWindow == true
        cardPanel?.orderOut(nil)
        cardPanel = nil
        cardIsInteractive = false
        cardPinned = false
        preferTrayCardAnchor = false
        lastHoverWithinCard = nil
        let focusSession = cardFocusSession
        cardFocusSession = nil
        if shouldRestoreFocus { focusSession?.restoreIfAppropriate() }
        if shouldRefreshDock { DockPresence.refreshAfterWindowChange() }
    }

    private func applyFromCard(_ id: UUID, choice: String? = nil) {
        // Inline apply validates that the original AX field is focused. Restore
        // it now and again on the next run loop before entering that safety
        // check. Application activation is asynchronous, while the second AX
        // focus write makes the focused-element guard deterministic.
        let focusSession = cardFocusSession
        cardFocusSession = nil
        cardIsInteractive = false
        cardPanel?.allowsKeyInteraction = false
        cardPanel?.resignKey()
        focusSession?.restoreIfAppropriate()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            focusSession?.restoreIfAppropriate()
            if let choice { self.onApplyAlternative?(id, choice) }
            else { self.onApply?(id) }
        }
        DockPresence.refreshAfterWindowChange()
    }

    private func promoteCardFromExplicitInteraction() {
        guard !cardIsInteractive, let cardPanel else { return }
        cardFocusSession = OverlaySourceFocusSession.capture()
        cardIsInteractive = true
        makeInteractive(cardPanel, firstResponder: cardPanel.contentViewController?.view)
    }

    private func showTray(issueCount: Int) {
        let host = NSHostingController(rootView: LiveIssueTrayView(count: issueCount, actionLabel: writingActionLabel,
                                                                  onAction: { [weak self] in self?.onWritingAction?() }, onOpen: { [weak self] in
            guard let self, let id = self.renderedSelectedID ?? self.renderedEntries.first?.issue.id else { return }
            self.activateIssue(id, intent: .pointer, anchorToTray: true)
        }, onKeyboardOpen: { [weak self] in
            guard let self, let id = self.renderedSelectedID ?? self.renderedEntries.first?.issue.id else { return }
            self.activateIssue(id, intent: .explicit, anchorToTray: true)
        }))
        let panel: OverlayPanel
        if let existing = trayPanel { panel = existing }
        else {
            panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 36),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.isFloatingPanel = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            trayPanel = panel
        }
        panel.contentViewController = host
        panel.setContentSize(host.view.fittingSize)
        let screens = OverlayScreenArea.current
        let screen = sourceAnchor.flatMap { OverlayGeometry.screen(containing: $0, from: screens) }
            ?? OverlayGeometry.screen(containing: NSEvent.mouseLocation, from: screens)
        if let screen {
            panel.setFrameOrigin(OverlayGeometry.issueTrayOrigin(anchoredTo: sourceAnchor,
                                                                 panelSize: panel.frame.size,
                                                                 in: screen.visibleFrame))
        }
        panel.orderFrontRegardless()
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
        let color = NSColor(BeanDesign.danger).withAlphaComponent(0.95)
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2
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
    let onApplyAlternative: (String) -> Void
    let onIgnore: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    init(issue: TextIssue, positionText: String?, showNext: Bool, showExplanation: Bool,
         onApply: @escaping () -> Void, onApplyAlternative: @escaping (String) -> Void,
         onIgnore: @escaping () -> Void,
         onNext: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.issue = issue
        self.positionText = positionText
        self.showNext = showNext
        self.showExplanation = showExplanation
        self.onApplyAlternative = onApplyAlternative
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
                Text(InlineSuggestionDisplay.text(model.issue.original)).strikethrough().foregroundColor(.secondary)
                Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary)
                Text(InlineSuggestionDisplay.text(model.issue.suggestion)).fontWeight(.semibold).foregroundColor(BeanDesign.accent)
            }
            .font(.system(size: 14))
            .fixedSize(horizontal: false, vertical: true)

            if model.showExplanation, let explanation = model.issue.explanation, !explanation.isEmpty {
                Text(explanation).font(BeanDesign.Typography.caption()).foregroundColor(.secondary)
            }

            if !model.issue.alternatives.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Other spellings").font(BeanDesign.Typography.caption()).foregroundColor(.secondary)
                    ForEach(Array(model.issue.alternatives.prefix(3)), id: \.self) { choice in
                        Button { model.onApplyAlternative(choice) } label: {
                            Text(choice).frame(minHeight: OverlayGeometry.minimumMotorTarget)
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Replace with \(choice)")
                    }
                }
            }

            HStack {
                Button { model.onIgnore() } label: {
                    Text("Dismiss")
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
                    Text("Accept")
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

private struct LiveIssueTrayView: View {
    let count: Int
    let actionLabel: String
    let onAction: () -> Void
    let onOpen: () -> Void
    let onKeyboardOpen: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    BeanMark(size: 18)
                    Text("\(count) suggestion\(count == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .help("Review suggestions for this field")
            .accessibilityLabel("\(count) writing suggestion\(count == 1 ? "" : "s"). Review suggestions.")
            .accessibilityAction(named: Text("Review with keyboard"), onKeyboardOpen)
            Divider().frame(height: 18)
            Button(actionLabel, action: onAction)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .help("\(actionLabel) in this field")
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
    }
}

enum InlineSuggestionDisplay {
    static func text(_ value: String) -> String {
        if value.isEmpty { return "Remove" }
        if value.allSatisfy({ $0 == " " }) { return value.count == 1 ? "1 space" : "\(value.count) spaces" }
        if value.first?.isWhitespace == true || value.last?.isWhitespace == true {
            return value.replacingOccurrences(of: " ", with: "␣")
        }
        return value
    }
}
