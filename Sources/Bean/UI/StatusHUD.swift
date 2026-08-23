import AppKit

/// Monotonic identity for HUD presentations and dismissals. Any asynchronous
/// completion may mutate the panel only while its token is still current.
/// Keeping this state independent from AppKit makes the stale-dismissal guard
/// deterministic to test.
struct StatusHUDPresentationGeneration {
    private(set) var current: UInt = 0

    mutating func advance() -> UInt {
        current &+= 1
        return current
    }

    func isCurrent(_ candidate: UInt) -> Bool {
        candidate == current
    }
}

// Minimal, non-interactive floating status panel. Shows short messages like
// "Fixing…" or "Text fixed" near the top-center of the active screen, then
// auto-dismisses. Borderless, non-activating, and click-through so it never
// steals focus from the app the user is typing in.
@MainActor
final class StatusHUD {

    enum Style {
        case progress
        case success
        case info
        case warning
        case error

        /// SF Symbol name for a consistent, native look.
        var symbol: String {
            switch self {
            case .progress: return "hourglass"
            case .success: return "checkmark.circle.fill"
            case .info: return "arrow.right.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }

        var tint: NSColor {
            switch self {
            case .progress: return .secondaryLabelColor
            case .success: return .systemGreen
            case .info: return .systemBlue
            case .warning: return .systemOrange
            case .error: return .systemRed
            }
        }
    }

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?
    private var lastMessage: String?
    private var presentationGeneration = StatusHUDPresentationGeneration()
    private let reduceMotion: () -> Bool
    private let announcementHandler: ((String) -> Void)?

    init(
        reduceMotion: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        },
        announce: ((String) -> Void)? = nil
    ) {
        self.reduceMotion = reduceMotion
        self.announcementHandler = announce
    }

    static func sourceAwareMessage(_ message: String, sourceAppName: String?) -> String {
        guard let source = sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else { return message }
        return "\(message) — \(source)"
    }

    static func animationDuration(reduceMotion: Bool, appearing: Bool) -> TimeInterval {
        guard !reduceMotion else { return 0 }
        return appearing ? 0.16 : 0.18
    }

    /// Use for transient work-in-progress only. Failures that need a user
    /// decision belong in `ActionMenuController.presentNotice(_:)`.
    func showProgress(
        _ message: String,
        sourceAppName: String? = nil,
        sourceAnchorRect: CGRect? = nil
    ) {
        show(
            .progress,
            Self.sourceAwareMessage(message, sourceAppName: sourceAppName),
            sourceAnchorRect: sourceAnchorRect
        )
    }

    /// Use only after Bean has verified the outcome (for example, confirmed
    /// replacement, undo, or clipboard write).
    func showConfirmedSuccess(
        _ message: String,
        sourceAppName: String? = nil,
        sourceAnchorRect: CGRect? = nil
    ) {
        show(
            .success,
            Self.sourceAwareMessage(message, sourceAppName: sourceAppName),
            sourceAnchorRect: sourceAnchorRect
        )
    }

    /// Compatibility entry point. New flows should use the explicit progress
    /// and confirmed-success methods above; actionable failures use a notice.
    /// Progress messages persist until the next show; all others auto-dismiss.
    func show(_ style: Style, _ message: String, sourceAnchorRect: CGRect? = nil) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        let presentation = presentationGeneration.advance()

        let panel = panel ?? makePanel()
        self.panel = panel

        let isRepeat = (message == lastMessage) && panel.isVisible
        lastMessage = message

        configure(panel, style: style, message: message)
        position(panel, sourceAnchorRect: sourceAnchorRect)

        if !isRepeat {
            announceForAccessibility(message)
            let duration = Self.animationDuration(reduceMotion: reduceMotion(), appearing: true)
            if duration == 0 {
                panel.alphaValue = 1
                panel.orderFrontRegardless()
            } else {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = duration
                    panel.animator().alphaValue = 1
                }
            }
        } else {
            // A repeat can arrive while an older fade-out is in flight. A
            // direct assignment interrupts that stale animation as well as
            // restoring the visible state for this new generation.
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }

        // Progress messages stay up (a result message replaces them); others
        // disappear on their own.
        if style != .progress {
            let work = DispatchWorkItem { [weak self] in
                self?.dismiss(ifCurrent: presentation)
            }
            dismissWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
        }
    }

    func dismiss() {
        dismiss(ifCurrent: nil)
    }

    private func dismiss(ifCurrent expectedPresentation: UInt?) {
        if let expectedPresentation,
           !presentationGeneration.isCurrent(expectedPresentation) {
            return
        }
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        lastMessage = nil
        let dismissal = presentationGeneration.advance()
        guard let panel, panel.isVisible else { return }
        let duration = Self.animationDuration(reduceMotion: reduceMotion(), appearing: false)
        guard duration > 0 else {
            panel.alphaValue = 1
            if presentationGeneration.isCurrent(dismissal) {
                panel.orderOut(nil)
            }
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel,
                      self.presentationGeneration.isCurrent(dismissal),
                      self.panel === panel else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func announceForAccessibility(_ message: String) {
        if let announcementHandler {
            announcementHandler(message)
            return
        }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSNumber(value: NSAccessibilityPriorityLevel.medium.rawValue)
            ]
        )
    }

    // MARK: - Panel construction

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func configure(_ panel: NSPanel, style: Style, message: String) {
        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        let badge = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        badge.image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        badge.contentTintColor = style.tint
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityLabel(message)

        let stack = NSStackView(views: [badge, label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.subviews.forEach { $0.removeFromSuperview() }
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        // Size the panel to fit its content, capped to a comfortable width.
        let fitting = stack.fittingSize
        let width = min(max(fitting.width, 160), 360)
        let height = max(fitting.height, 44)
        panel.setContentSize(NSSize(width: width, height: height))
        panel.contentView = container
    }

    static func preferredScreenIndex(
        sourceAnchorRect: CGRect?,
        pointerLocation: CGPoint,
        screenFrames: [CGRect]
    ) -> Int? {
        let screens = screenFrames.map { OverlayScreenArea(frame: $0, visibleFrame: $0) }
        let selected = sourceAnchorRect.flatMap { OverlayGeometry.screen(containing: $0, from: screens) }
            ?? OverlayGeometry.screen(containing: pointerLocation, from: screens)
        return selected.flatMap { screens.firstIndex(of: $0) }
    }

    private func position(_ panel: NSPanel, sourceAnchorRect: CGRect?) {
        let screens = NSScreen.screens
        guard let index = Self.preferredScreenIndex(
            sourceAnchorRect: sourceAnchorRect,
            pointerLocation: NSEvent.mouseLocation,
            screenFrames: screens.map(\.frame)
        ) else { return }
        let screen = screens[index]
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let proposed = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 24 // just below the menu bar
        )
        panel.setFrameOrigin(OverlayGeometry.clampedOrigin(
            proposed,
            panelSize: size,
            in: visible,
            inset: 8
        ))
    }
}
