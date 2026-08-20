import AppKit

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

    /// Shows `message`. Progress messages persist until the next show; all
    /// others auto-dismiss. Repeated identical messages just refresh the timer
    /// (no flicker / spam).
    func show(_ style: Style, _ message: String) {
        dismissWorkItem?.cancel()

        let panel = panel ?? makePanel()
        self.panel = panel

        let isRepeat = (message == lastMessage) && panel.isVisible
        lastMessage = message

        configure(panel, style: style, message: message)
        position(panel)

        if !isRepeat {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }

        // Progress messages stay up (a result message replaces them); others
        // disappear on their own.
        if style != .progress {
            let work = DispatchWorkItem { [weak self] in self?.dismiss() }
            dismissWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
        }
    }

    func dismiss() {
        lastMessage = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
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

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - 24 // just below the menu bar
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
