import AppKit
import SwiftUI

// Inline-highlights overlay (redesigned). Each issue gets a tiny, transparent,
// non-activating panel positioned exactly over its text range that draws the
// underline and handles explicit clicks. A quiet field control opens review,
// progress details, and writing actions. Cards do not appear while typing.
// The service owns the issue list and selection; this controller renders it.
@MainActor
final class HighlightOverlayController {
    struct Entry { let issue: TextIssue; let rect: CGRect? } // nil: exact text, unavailable glyph bounds

    // Interaction callbacks (set by the service).
    var onActivateIssue: ((UUID) -> Void)?
    var onApply: ((UUID) -> Void)?
    var onApplyAlternative: ((UUID, String) -> Void)?
    var onIgnore: ((UUID) -> Void)?
    var onLearnWord: ((UUID) -> Void)?
    var onNext: (() -> Void)?
    var onCloseCard: (() -> Void)?
    var onWritingAction: ((WritingAction, Bool) -> Void)?
    var onFixAll: (() -> Void)?
    var onUndo: (() -> Void)?
    var onPauseApp: (() -> Void)?
    var onPrepareAssistant: (() -> Void)?
    var validateFieldControl: ((CGRect) -> Bool)?
    var assistantState = NativeAssistantState()
    var showsAssistantControl = true
    var showExplanation = true

    private var highlightPanels: [UUID: OverlayPanel] = [:]
    private var cardPanel: OverlayPanel?
    private var trayPanel: OverlayPanel?
    private var sourceAnchor: CGRect?
    private var placementGeometry: FieldOverlayGeometry?
    private var cardPinned = false
    private var preferTrayCardAnchor = false
    private var renderedEntries: [Entry] = []
    private var renderedSelectedID: UUID?
    private var cardIsInteractive = false
    private var cardFocusSession: OverlaySourceFocusSession?
    private var assistantOpen = false


    var isShowing: Bool { !highlightPanels.isEmpty || trayPanel != nil || cardPanel != nil }
    var ownsKeyboardInteraction: Bool { cardIsInteractive }

    // MARK: - Render

    func render(entries: [Entry], selectedID: UUID?, position: (index: Int, total: Int)?,
                sourceAnchor: CGRect? = nil, placementGeometry: FieldOverlayGeometry? = nil) {
        self.sourceAnchor = sourceAnchor
        self.placementGeometry = placementGeometry
        renderedEntries = entries
        renderedSelectedID = selectedID

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
        if showsAssistantControl { showTray() }
        else { trayPanel?.orderOut(nil); trayPanel = nil }

        // Card for the selected issue (if any).
        if let selectedID, let entry = entries.first(where: { $0.issue.id == selectedID }) {
            assistantOpen = false
            showCard(for: entry, position: position)
        } else if assistantOpen {
            showAssistantCard()
        } else {
            hideCard()
        }
    }

    func hide() {
        renderedEntries = []
        renderedSelectedID = nil
        assistantOpen = false
        for panel in highlightPanels.values { panel.orderOut(nil) }
        highlightPanels.removeAll()
        trayPanel?.orderOut(nil)
        trayPanel = nil
        sourceAnchor = nil
        placementGeometry = nil
        hideCard()
    }

    func dismissExpandedUI() {
        assistantOpen = false
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
        // Underlines are pointer shortcuts to the same suggestions available
        // through the field control. A separate blank six-pixel window per
        // issue adds no useful accessibility navigation or action.
        panel.setAccessibilityElement(false)
        panel.setAccessibilityChildren([])
        panel.setAccessibilityIdentifier("com.bean.overlay.underline.\(id.uuidString)")
        view.setAccessibilityElement(false)
        view.setAccessibilityChildren([])
        view.onClick = { [weak self] in self?.activateIssue(id, intent: .pointer) }
        panel.contentView = view
        panel.orderFrontRegardless()
        return panel
    }

    private func activateIssue(_ id: UUID, intent: OverlayActivationIntent, anchorToTray: Bool = false) {
        assistantOpen = false
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
            onLearnWord: entry.issue.type == .spelling ? { [weak self] in self?.onLearnWord?(entry.issue.id) } : nil,
            onNext: { [weak self] in self?.onNext?() },
            onClose: { [weak self] in self?.onCloseCard?() }
        )

        let host: NSHostingController<CorrectionCardView>
        if let existing = cardPanel?.contentViewController as? NSHostingController<CorrectionCardView> {
            existing.rootView = CorrectionCardView(model: model)
            host = existing
        } else { host = NSHostingController(rootView: CorrectionCardView(model: model)) }
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
        cardPanel?.describeAccessibility(title: "Bean writing suggestion", identifier: "com.bean.overlay.correction")
        cardPanel?.allowsKeyInteraction = cardIsInteractive
        cardPanel?.setContentSize(host.view.fittingSize)
        let anchor = preferTrayCardAnchor ? trayPanel?.frame : entry.rect
        if let anchor = anchor ?? trayPanel?.frame ?? sourceAnchor {
            anchorCard(cardPanel!, to: anchor)
        }
        if cardIsInteractive, cardPanel?.isKeyWindow != true {
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

    private func showTray() {
        guard let geometry = placementGeometry,
              let size = OverlayGeometry.fieldControlSize(for: geometry.fieldRect),
              let screen = OverlayGeometry.screen(containing: geometry.fieldRect, from: OverlayScreenArea.current),
              let frame = availableControlFrame(geometry: geometry, size: size, visibleFrame: screen.visibleFrame) else {
            trayPanel?.orderOut(nil); trayPanel = nil
            return
        }
        let view = NativeAssistantBadgeView(state: assistantState,
            onOpen: { [weak self] in self?.openAssistant(intent: .pointer) },
            onKeyboardOpen: { [weak self] in self?.openAssistant(intent: .explicit) }, targetSize: size.width)
        let host: NSHostingController<NativeAssistantBadgeView>
        if let existing = trayPanel?.contentViewController as? NSHostingController<NativeAssistantBadgeView> {
            existing.rootView = view
            host = existing
        } else { host = NSHostingController(rootView: view) }
        let panel: OverlayPanel
        if let existing = trayPanel { panel = existing }
        else {
            panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.isFloatingPanel = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            trayPanel = panel
        }
        panel.describeAccessibility(title: "Bean writing control", identifier: "com.bean.overlay.field-control")
        if panel.contentViewController !== host { panel.contentViewController = host }
        panel.setContentSize(size)
        panel.setFrameOrigin(frame.origin)
        panel.orderFrontRegardless()
    }

    private func availableControlFrame(geometry: FieldOverlayGeometry, size: CGSize, visibleFrame: CGRect) -> CGRect? {
        let candidates = OverlayGeometry.issueTrayCandidateFrames(geometry: geometry, panelSize: size, in: visibleFrame)
        guard let validateFieldControl else { return candidates.first }
        // Keep AX work bounded and try distinct destinations, rather than
        // spending every probe on subpixel variants of one blocked corner.
        var checked: [CGRect] = []
        for frame in candidates {
            if checked.contains(where: { abs($0.minX - frame.minX) < size.width && abs($0.minY - frame.minY) < size.height }) { continue }
            checked.append(frame)
            if validateFieldControl(frame) { return frame }
            if checked.count == 3 { break }
        }
        return nil
    }

    private func openAssistant(intent: OverlayActivationIntent) {
        let activatedFrame = trayPanel?.frame
        onPrepareAssistant?()
        // A moving caret/control may invalidate the formerly drawn corner.
        // The click cannot authorize a new assistant at that stale location.
        guard let activatedFrame, trayPanel?.frame == activatedFrame,
              validateFieldControl?(activatedFrame) != false else { return }
        assistantOpen = true
        if intent.allowsKeyboardInteraction, !cardIsInteractive {
            cardFocusSession = OverlaySourceFocusSession.capture()
            cardIsInteractive = true
        }
        showAssistantCard()
    }

    private func showAssistantCard() {
        let view = NativeAssistantPanelView(state: assistantState,
            onReview: { [weak self] in
                guard let self, let id = self.renderedEntries.first?.issue.id else { return }
                self.activateIssue(id, intent: self.cardIsInteractive ? .explicit : .pointer, anchorToTray: true)
            }, onAction: { [weak self] action, paragraph in
                self?.finishAssistantInteraction { self?.onWritingAction?(action, paragraph) }
            }, onFixAll: { [weak self] in self?.finishAssistantInteraction { self?.onFixAll?() } },
            onUndo: { [weak self] in self?.finishAssistantInteraction { self?.onUndo?() } },
            onPause: { [weak self] in self?.finishAssistantInteraction { self?.onPauseApp?() } },
            onClose: { [weak self] in self?.assistantOpen = false; self?.hideCard() })
        // Keep SwiftUI identity and the user's selected scope/focused control
        // when a background check updates the status of an open assistant.
        let host: NSHostingController<NativeAssistantPanelView>
        if let existing = cardPanel?.contentViewController as? NSHostingController<NativeAssistantPanelView> {
            existing.rootView = view
            host = existing
        } else { host = NSHostingController(rootView: view) }
        if let cardPanel { cardPanel.contentViewController = host }
        else {
            let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 230),
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
        cardPanel?.describeAccessibility(title: "Bean writing assistant", identifier: "com.bean.overlay.assistant")
        cardPanel?.allowsKeyInteraction = cardIsInteractive
        cardPanel?.setContentSize(host.view.fittingSize)
        if let anchor = trayPanel?.frame ?? sourceAnchor { anchorCard(cardPanel!, to: anchor) }
        if cardIsInteractive, cardPanel?.isKeyWindow != true { makeInteractive(cardPanel!, firstResponder: host.view) }
        else { cardPanel?.orderFrontRegardless() }
    }

    private func finishAssistantInteraction(_ action: @escaping @MainActor () -> Void) {
        assistantOpen = false
        hideCard()
        Task { @MainActor in action() }
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

final class OverlayPanel: NSPanel {
    var allowsKeyInteraction = false
    var onExplicitInteraction: (() -> Void)?
    override var canBecomeKey: Bool { allowsKeyInteraction }
    override var canBecomeMain: Bool { false }

    fileprivate func describeAccessibility(title: String, identifier: String) {
        self.title = title
        setAccessibilityTitle(title)
        setAccessibilityIdentifier(identifier)
        setAccessibilityElement(true)
        setAccessibilityRole(.window)
        setAccessibilitySubrole(.floatingWindow)
    }

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
    let onLearnWord: (() -> Void)?
    let onNext: () -> Void
    let onClose: () -> Void

    init(issue: TextIssue, positionText: String?, showNext: Bool, showExplanation: Bool,
         onApply: @escaping () -> Void, onApplyAlternative: @escaping (String) -> Void,
         onIgnore: @escaping () -> Void, onLearnWord: (() -> Void)? = nil,
         onNext: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.issue = issue
        self.positionText = positionText
        self.showNext = showNext
        self.showExplanation = showExplanation
        self.onApplyAlternative = onApplyAlternative
        self.onLearnWord = onLearnWord
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

            if let onLearnWord = model.onLearnWord {
                Button("Add to Dictionary", action: onLearnWord)
                    .controlSize(.small)
                    .frame(minHeight: OverlayGeometry.minimumMotorTarget)
                    .accessibilityLabel("Add \(model.issue.original) to Bean dictionary")
                    .accessibilityHint("Keeps this spelling in future local checks")
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
