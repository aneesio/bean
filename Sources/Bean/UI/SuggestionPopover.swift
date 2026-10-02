import AppKit
import SwiftUI

// The small, non-intrusive "Bean found a suggestion" popover shown after a
// typing pause. It must NEVER take key focus (the user is still typing in their
// app). Deliberate interaction enables keyboard navigation without activating
// Bean, and the card stays beside the writing that produced it.
@MainActor
final class SuggestionPopoverController {
    private var panel: NonKeyPanel?
    private var focusSession: OverlaySourceFocusSession?

    /// Shows the popover. `showApply` is false when Settings requires a preview
    /// before applying.
    func present(previewText: String,
                 showApply: Bool,
                 sourceAnchor: CGRect? = nil,
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
        position(panel, sourceAnchor: sourceAnchor)

        self.panel = panel
        panel.orderFrontRegardless() // does NOT take key focus
    }

    func dismiss() {
        let wasKey = panel?.isKeyWindow == true
        let wasInteractive = panel?.allowsKeyInteraction == true
        panel?.orderOut(nil)
        panel = nil
        if wasKey { focusSession?.restoreIfAppropriate() }
        focusSession = nil
        if wasInteractive { DockPresence.refreshAfterWindowChange() }
    }

    var isShowing: Bool { panel != nil }

    func reposition(sourceAnchor: CGRect?) {
        guard let panel else { return }
        position(panel, sourceAnchor: sourceAnchor)
    }

    private func position(_ window: NSWindow, sourceAnchor: CGRect?) {
        let screens = OverlayScreenArea.current
        let sourceRect: CGRect? = sourceAnchor ?? AccessibilityService.focusedField().flatMap { field in
            TextRangeLocator.selectionRect(for: field.element)
                ?? TextRangeLocator.caretRect(for: field.element)
                ?? TextRangeLocator.fieldRect(for: field.element)
        }
        let screen = sourceRect.flatMap { OverlayGeometry.screen(containing: $0, from: screens) }
            ?? OverlayGeometry.screen(containing: NSEvent.mouseLocation, from: screens)
        guard let screen else { return }
        if let sourceRect {
            window.setFrameOrigin(OverlayGeometry.cardOrigin(
                anchoredTo: sourceRect, panelSize: window.frame.size, in: screen.visibleFrame
            ))
            return
        }
        window.setFrameOrigin(OverlayGeometry.topRightOrigin(
            panelSize: window.frame.size,
            in: screen.visibleFrame
        ))
    }
}

private final class NonKeyPanel: NSPanel {
    var allowsKeyInteraction = false
    var onExplicitInteraction: (() -> Void)?
    override var canBecomeKey: Bool { allowsKeyInteraction }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { onExplicitInteraction?() }
        super.sendEvent(event)
    }
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
                Text("Writing suggestion").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onIgnore) {
                    Image(systemName: "xmark")
                        .frame(width: OverlayGeometry.minimumMotorTarget, height: OverlayGeometry.minimumMotorTarget)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .accessibilityLabel("Dismiss suggestion")
            }
            Text("Suggested version")
                .font(BeanDesign.Typography.caption()).foregroundColor(.secondary)
            Text(previewText)
                .font(BeanDesign.Typography.body())
                .lineLimit(4)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(BeanDesign.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: BeanDesign.Radius.sm).fill(BeanDesign.warmBackground))

            HStack {
                Button("Dismiss") { onIgnore() }.controlSize(.small)
                Spacer()
                Button("Copy") { onCopy() }.controlSize(.small)
                if !showApply { Button("Review") { onPreview() }.controlSize(.small) }
                if showApply {
                    Button("Accept") { onApply() }.controlSize(.small).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(BeanDesign.Spacing.md)
        .frame(width: 320)
        .tint(BeanDesign.accent)
        .onExitCommand(perform: onIgnore)
        .background(
            RoundedRectangle(cornerRadius: BeanDesign.Radius.card)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        )
    }
}
