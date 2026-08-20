import AppKit
import SwiftUI

// The small, non-intrusive "Bean found a suggestion" popover shown after a
// typing pause. It must NEVER take key focus (the user is still typing in their
// app), so it lives in a non-activating, non-key panel near the menu bar.
@MainActor
final class SuggestionPopoverController {
    private var panel: NSPanel?
    private var dismissTimer: Timer?

    /// Shows the popover. `showApply` is false when Settings requires a preview
    /// before applying.
    func present(previewText: String,
                 showApply: Bool,
                 onApply: @escaping () -> Void,
                 onPreview: @escaping () -> Void,
                 onIgnore: @escaping () -> Void,
                 onCopy: @escaping () -> Void) {
        dismiss()

        let view = SuggestionPopoverView(
            previewText: previewText,
            showApply: showApply,
            onApply: { [weak self] in self?.dismiss(); onApply() },
            onPreview: { [weak self] in self?.dismiss(); onPreview() },
            onIgnore: { [weak self] in self?.dismiss(); onIgnore() },
            onCopy: { [weak self] in self?.dismiss(); onCopy() }
        )

        let panel = NonKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: view)
        panel.setContentSize(panel.contentViewController!.view.fittingSize)
        positionTopRight(panel)

        self.panel = panel
        panel.orderFrontRegardless() // does NOT take key focus

        // Auto-dismiss after 15s if untouched.
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    var isShowing: Bool { panel != nil }

    private func positionTopRight(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = visible.maxX - size.width - 16
        let y = visible.maxY - size.height - 12
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct SuggestionPopoverView: View {
    let previewText: String
    let showApply: Bool
    let onApply: () -> Void
    let onPreview: () -> Void
    let onIgnore: () -> Void
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.md) {
            HStack(spacing: BeanDesign.Spacing.sm) {
                BeanMark(size: 20)
                Text("Bean found a suggestion").font(.system(size: 13, weight: .semibold))
            }
            Text(previewText)
                .font(BeanDesign.Typography.body())
                .lineLimit(4)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(BeanDesign.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: BeanDesign.Radius.sm).fill(BeanDesign.warmBackground))

            HStack {
                Button("Ignore") { onIgnore() }.controlSize(.small)
                Spacer()
                Button("Copy") { onCopy() }.controlSize(.small)
                Button("Preview") { onPreview() }.controlSize(.small)
                if showApply {
                    Button("Apply") { onApply() }.controlSize(.small).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(BeanDesign.Spacing.md)
        .frame(width: 320)
        .tint(BeanDesign.accent)
        .background(
            RoundedRectangle(cornerRadius: BeanDesign.Radius.card)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        )
    }
}
