import SwiftUI

enum ActionMenuKeyboardNavigation {
    static func adjacentAction(
        to current: WritingAction?,
        offset: Int,
        in actions: [WritingAction]
    ) -> WritingAction? {
        guard !actions.isEmpty else { return nil }
        guard let current, let index = actions.firstIndex(of: current) else {
            return offset < 0 ? actions.last : actions.first
        }
        let next = (index + offset + actions.count) % actions.count
        return actions[next]
    }
}

// The floating action menu: a compact, scannable list of writing actions. Shown
// only AFTER Bean has acquired the target text, so it's safe for it to focus.
struct ActionMenuView: View {
    let appName: String?
    let captureLabel: String
    let aiAvailable: Bool
    let onSelect: (WritingAction) -> Void
    let onSetUpAI: () -> Void
    let onCancel: () -> Void

    @State private var showsMore = false
    @FocusState private var focusedAction: WritingAction?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visibleActions: [WritingAction] {
        showsMore ? WritingAction.moreActions : WritingAction.primaryActions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.sm) {
            HStack(spacing: BeanDesign.Spacing.sm) {
                BeanMark(size: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text("What should Bean do?").font(.system(size: 14, weight: .semibold))
                    HStack(spacing: BeanDesign.Spacing.sm) {
                        Label(appName ?? "Current app", systemImage: "app")
                        Label(captureLabel, systemImage: "text.cursor")
                    }
                    .font(BeanDesign.Typography.caption())
                    .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider().opacity(0.4)

            Text(showsMore ? "MORE WRITING TOOLS" : "WRITING TOOLS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.leading, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: BeanDesign.Spacing.xs) {
                        ForEach(visibleActions) { action in
                            ActionRow(action: action, aiAvailable: aiAvailable,
                                      focusedAction: $focusedAction,
                                      onTap: { onSelect(action) }, onSetUpAI: onSetUpAI)
                                .id(action)
                        }
                    }
                }
                .onChange(of: focusedAction) { action in
                    guard let action else { return }
                    if reduceMotion {
                        proxy.scrollTo(action, anchor: .center)
                    } else {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(action, anchor: .center)
                        }
                    }
                }
            }
            .frame(minHeight: 220, idealHeight: 280, maxHeight: .infinity)

            Divider().opacity(0.4)

            Button {
                showsMore.toggle()
            } label: {
                Label(showsMore ? "Back to main tools" : "More…",
                      systemImage: showsMore ? "chevron.left" : "ellipsis.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("m", modifiers: [.command])
            .padding(.vertical, BeanDesign.Spacing.xs)
            .accessibilityHint(showsMore
                               ? "Shows Bean's five main writing tools"
                               : "Shows additional writing tools")
        }
        .padding(BeanDesign.Spacing.md)
        .frame(minWidth: 380, idealWidth: 440, maxWidth: .infinity,
               minHeight: 360, idealHeight: 410, maxHeight: .infinity)
        .tint(BeanDesign.accent)
        .onExitCommand(perform: onCancel)
        .onAppear { focusedAction = visibleActions.first }
        .onChange(of: showsMore) { _ in focusedAction = visibleActions.first }
        .onMoveCommand { direction in
            switch direction {
            case .down:
                focusedAction = ActionMenuKeyboardNavigation.adjacentAction(
                    to: focusedAction, offset: 1, in: visibleActions)
            case .up:
                focusedAction = ActionMenuKeyboardNavigation.adjacentAction(
                    to: focusedAction, offset: -1, in: visibleActions)
            default:
                break
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ActionRow: View {
    let action: WritingAction
    let aiAvailable: Bool
    let focusedAction: FocusState<WritingAction?>.Binding
    let onTap: () -> Void
    let onSetUpAI: () -> Void
    @State private var hovering = false

    private var requiresSetup: Bool {
        action.requiresAISetup(aiAvailable: aiAvailable)
    }

    var body: some View {
        Button(action: requiresSetup ? onSetUpAI : onTap) {
            HStack(spacing: BeanDesign.Spacing.md) {
                IconBadge(symbol: requiresSetup ? "lock.fill" : action.symbolName, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: BeanDesign.Spacing.xs) {
                        Text(action.displayName).font(.system(size: 13, weight: .medium))
                        StatusPill(
                            text: requiresSetup ? "Set Up AI" : (action.usesProvider ? "AI" : "Offline"),
                            kind: requiresSetup ? .neutral : (action.usesProvider ? .experimental : .neutral),
                            showsIcon: false
                        )
                    }
                    Text(requiresSetup ? "Connect an AI provider to use this tool" : action.shortDescription)
                        .font(BeanDesign.Typography.caption()).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? BeanDesign.accent.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused(focusedAction, equals: action)
        .onHover { hovering = $0 }
        .accessibilityLabel(requiresSetup
                            ? "\(action.displayName), requires AI setup"
                            : action.displayName)
        .accessibilityHint(requiresSetup
                           ? "Opens AI setup"
                           : action.shortDescription)
    }
}

// MARK: - Preview model

@MainActor
final class PreviewModel: ObservableObject {
    @Published var transformedText: String
    @Published var isRunning: Bool = false
    @Published var errorMessage: String?
    @Published var reviewWarning: String?
    @Published var originalText: String?
    @Published var allowsReplace: Bool = true
    @Published var helperText: String = "Review before replacing your text."
    /// Content regeneration is an additional provider call. Replacement
    /// recovery changes this to "Retry Replacement" because it must not imply
    /// that Bean will spend tokens or generate different wording.
    @Published var retryButtonTitle: String = "Generate Again · uses AI"
    /// Unconfirmed replacement is not safely repeatable because the source may
    /// already contain the new text. That recovery state hides retry and offers
    /// only explicit copy/cancel choices.
    @Published var showsRetryButton: Bool = true
    /// Makes provider-backed output explicit at the point of approval.
    @Published var showsAIIndicator: Bool = true

    let actionName: String
    let sourceAppName: String?
    let captureLabel: String?
    let sourceAnchorRect: CGRect?
    var styleName: String?
    var usedContext: Bool = false

    var sourceSummary: String? {
        let source = sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = captureLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (scope?.isEmpty == false ? scope : nil, source?.isEmpty == false ? source : nil) {
        case let (scope?, source?): return "\(scope) in \(source)"
        case let (scope?, nil): return scope
        case let (nil, source?): return "Text in \(source)"
        case (nil, nil): return nil
        }
    }

    var onReplace: () -> Void = {}
    var onCopy: () -> Void = {}
    var onTryAgain: () -> Void = {}
    var onCancel: () -> Void = {}

    /// Builds an action callback that can use the current preview model without
    /// making the model retain itself through one of its stored handlers.
    func weakHandler(_ action: @escaping (PreviewModel) -> Void) -> () -> Void {
        { [weak self] in
            guard let self else { return }
            action(self)
        }
    }

    /// Replacement/retry mutates another app asynchronously. Do not let a
    /// Cancel action dismiss the recovery state while that operation can still
    /// reach its final paste checkpoint.
    func cancelIfIdle() {
        guard !isRunning else { return }
        onCancel()
    }

    init(actionName: String, transformedText: String, originalText: String? = nil,
         sourceAppName: String? = nil, captureLabel: String? = nil,
         sourceAnchorRect: CGRect? = nil) {
        self.actionName = actionName
        self.transformedText = transformedText
        self.originalText = originalText
        self.sourceAppName = sourceAppName
        self.captureLabel = captureLabel
        self.sourceAnchorRect = sourceAnchorRect
        if actionName == "Replacement Recovery" {
            self.retryButtonTitle = "Retry Replacement"
        }
    }
}

// Preview window: transformed text in an editable panel, with action-appropriate
// button priority. Reply = copy-first; rewrite/compose = replace primary.
struct RewritePreviewView: View {
    @ObservedObject var model: PreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.md) {
            HStack(alignment: .top, spacing: BeanDesign.Spacing.sm) {
                IconBadge(symbol: model.actionName == "Replacement Recovery"
                          ? "exclamationmark.arrow.triangle.2.circlepath" : "sparkles", size: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.actionName).font(BeanDesign.Typography.title())
                    if let source = model.sourceSummary {
                        Label(source, systemImage: "scope")
                            .font(BeanDesign.Typography.caption())
                            .foregroundColor(.secondary)
                            .accessibilityLabel("Source: \(source)")
                    }
                }
                Spacer()
                HStack(spacing: BeanDesign.Spacing.xs) {
                    if let styleName = model.styleName {
                        StatusPill(text: styleName, kind: .neutral, showsIcon: false)
                    }
                    if model.usedContext {
                        StatusPill(text: "Context", kind: .info)
                    }
                    if model.showsAIIndicator {
                        StatusPill(text: "AI", kind: .experimental, showsIcon: false)
                    }
                }
            }

            comparison
                .frame(minHeight: 250, maxHeight: .infinity)

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(BeanDesign.Typography.caption()).foregroundColor(BeanDesign.danger)
            } else if let warning = model.reviewWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(BeanDesign.Typography.caption()).foregroundColor(.orange)
            } else {
                Text(model.helperText)
                    .font(BeanDesign.Typography.caption()).foregroundColor(.secondary)
            }

            HStack {
                Button("Cancel", role: .cancel) { model.cancelIfIdle() }
                    .disabled(model.isRunning)
                Spacer()
                if model.showsRetryButton {
                    Button(model.retryButtonTitle) { model.onTryAgain() }
                        .keyboardShortcut("r", modifiers: [.command])
                        .disabled(model.isRunning)
                }
                if model.allowsReplace {
                    Button("Copy Result") { model.onCopy() }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                        .disabled(model.isRunning)
                    Button("Replace") { model.onReplace() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(model.isRunning)
                } else {
                    Button("Copy Result") { model.onCopy() }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(model.isRunning)
                }
            }
        }
        .padding(BeanDesign.Spacing.lg)
        .frame(minWidth: 520, idealWidth: model.originalText == nil ? 600 : 760,
               maxWidth: .infinity, minHeight: 400, idealHeight: 540,
               maxHeight: .infinity)
        .tint(BeanDesign.accent)
        .onExitCommand { model.cancelIfIdle() }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var comparison: some View {
        if let originalText = model.originalText {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: BeanDesign.Spacing.md) {
                    originalPane(originalText)
                    resultPane
                }
                .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: BeanDesign.Spacing.md) {
                    originalPane(originalText)
                    resultPane
                }
            }
        } else {
            resultPane
        }
    }

    private func originalPane(_ originalText: String) -> some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.xs) {
            Label("ORIGINAL", systemImage: "doc.text")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            ScrollView {
                Text(originalText)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .accessibilityLabel("Original text")
                    .accessibilityValue(originalText)
            }
            .frame(minHeight: 130, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: BeanDesign.Radius.sm)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: BeanDesign.Radius.sm)
                .stroke(BeanDesign.subtleBorder, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultPane: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.xs) {
            Label("BEAN'S RESULT · EDITABLE", systemImage: "pencil.line")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(BeanDesign.accent)
            ZStack(alignment: .center) {
                TextEditor(text: $model.transformedText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 130, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: BeanDesign.Radius.sm)
                        .fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: BeanDesign.Radius.sm)
                        .stroke(BeanDesign.accent.opacity(0.72), lineWidth: 1.5))
                    .disabled(model.isRunning)
                    .opacity(model.isRunning ? 0.5 : 1)
                    .accessibilityLabel("Bean result, editable")
                    .accessibilityHint("Review or edit this text before copying or replacing")
                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Bean is generating another result")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Persistent action notice

/// A failure or setup message that needs a decision from the user. Unlike the
/// status HUD, notices stay visible until the user chooses an action or closes
/// the window. Keep source text and model output out of these values.
struct ActionNotice {
    enum DismissalPolicy: Equatable {
        /// The notice remains until the user presses a button, Escape, or the
        /// standard close control. It is never driven by a timer.
        case explicitUserAction
    }

    enum Kind {
        case info
        case warning
        case danger

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .info: return BeanDesign.info
            case .warning: return BeanDesign.warning
            case .danger: return BeanDesign.danger
            }
        }
    }

    struct Action {
        let title: String
        let handler: () -> Void

        init(_ title: String, handler: @escaping () -> Void) {
            self.title = title
            self.handler = handler
        }
    }

    let title: String
    let message: String
    let kind: Kind
    let primaryAction: Action
    let secondaryAction: Action?
    let onDismiss: () -> Void
    let dismissalPolicy: DismissalPolicy = .explicitUserAction

    init(title: String,
         message: String,
         kind: Kind,
         primaryAction: Action,
         secondaryAction: Action? = nil,
         onDismiss: @escaping () -> Void = {}) {
        self.title = title
        self.message = message
        self.kind = kind
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.onDismiss = onDismiss
    }
}

struct ActionNoticeView: View {
    let notice: ActionNotice
    let onPrimary: () -> Void
    let onSecondary: (() -> Void)?
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.lg) {
            HStack(alignment: .top, spacing: BeanDesign.Spacing.md) {
                IconBadge(symbol: notice.kind.symbol, tint: notice.kind.color, size: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BeanDesign.Spacing.xs) {
                    Text(notice.title)
                        .font(BeanDesign.Typography.title())
                    ScrollView {
                        Text(notice.message)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 44, idealHeight: 72, maxHeight: 180)
                    .accessibilityLabel(notice.message)
                }
            }

            HStack {
                Button("Not Now", role: .cancel, action: onCancel)
                Spacer()
                if let onSecondary, let action = notice.secondaryAction {
                    Button(action.title, action: onSecondary)
                }
                Button(notice.primaryAction.title, action: onPrimary)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Completes this Bean notice")
            }
        }
        .padding(BeanDesign.Spacing.lg)
        .frame(minWidth: 400, idealWidth: 460, maxWidth: .infinity,
               minHeight: 180, idealHeight: 240, maxHeight: .infinity)
        .tint(BeanDesign.accent)
        .onExitCommand(perform: onCancel)
        .accessibilityElement(children: .contain)
    }
}
