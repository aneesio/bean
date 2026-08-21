import SwiftUI

// The floating action menu: a compact, scannable list of writing actions. Shown
// only AFTER Bean has acquired the target text, so it's safe for it to focus.
struct ActionMenuView: View {
    let appName: String?
    /// Style profiles for rewrite/reply/compose: (id, name).
    let profiles: [(id: UUID, name: String)]
    let onSelect: (WritingAction, UUID?) -> Void
    let onCancel: () -> Void

    @State var selectedProfileID: UUID?

    private var groups: [(title: String, actions: [WritingAction])] {
        ["Improve Text", "Reply", "Compose"].compactMap { title in
            let actions = WritingAction.allCases.filter { $0.category.menuGroup == title }
            return actions.isEmpty ? nil : (title, actions)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.sm) {
            HStack(spacing: BeanDesign.Spacing.sm) {
                BeanMark(size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text("What should Bean do?").font(.system(size: 14, weight: .semibold))
                    if let appName {
                        Text("for text in \(appName)").font(BeanDesign.Typography.caption()).foregroundColor(.secondary)
                    }
                }
                Spacer()
            }

            if !profiles.isEmpty {
                HStack(spacing: BeanDesign.Spacing.sm) {
                    Text("Style").font(BeanDesign.Typography.caption()).foregroundColor(.secondary)
                    Picker("Style", selection: $selectedProfileID) {
                        ForEach(profiles, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    Spacer()
                }
            }

            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: BeanDesign.Spacing.xs) {
                    ForEach(groups, id: \.title) { group in
                        Text(group.title.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.top, BeanDesign.Spacing.xs)
                            .padding(.leading, 4)
                        ForEach(group.actions) { action in
                            ActionRow(action: action) { onSelect(action, selectedProfileID) }
                        }
                    }
                }
            }
            .frame(maxHeight: 340)
        }
        .padding(BeanDesign.Spacing.md)
        .frame(width: 320)
        .tint(BeanDesign.accent)
        .onExitCommand(perform: onCancel)
    }
}

private struct ActionRow: View {
    let action: WritingAction
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: BeanDesign.Spacing.md) {
                IconBadge(symbol: action.symbolName, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.displayName).font(.system(size: 13, weight: .medium))
                    Text(action.shortDescription).font(BeanDesign.Typography.caption()).foregroundColor(.secondary)
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
        .onHover { hovering = $0 }
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

    let actionName: String
    var styleName: String?
    var usedContext: Bool = false

    var onReplace: () -> Void = {}
    var onCopy: () -> Void = {}
    var onTryAgain: () -> Void = {}
    var onCancel: () -> Void = {}

    init(actionName: String, transformedText: String, originalText: String? = nil) {
        self.actionName = actionName
        self.transformedText = transformedText
        self.originalText = originalText
    }
}

// Preview window: transformed text in an editable panel, with action-appropriate
// button priority. Reply = copy-first; rewrite/compose = replace primary.
struct RewritePreviewView: View {
    @ObservedObject var model: PreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.md) {
            HStack(spacing: BeanDesign.Spacing.sm) {
                IconBadge(symbol: "sparkles", size: 24)
                Text(model.actionName).font(BeanDesign.Typography.title())
                Spacer()
                if let styleName = model.styleName {
                    StatusPill(text: styleName, kind: .neutral, showsIcon: false)
                }
                if model.usedContext {
                    StatusPill(text: "Context", kind: .info)
                }
            }

            HStack(alignment: .top, spacing: BeanDesign.Spacing.md) {
                if let originalText = model.originalText {
                    VStack(alignment: .leading, spacing: BeanDesign.Spacing.xs) {
                        Text("BEFORE")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                        ScrollView {
                            Text(originalText)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .frame(height: 230)
                        .background(RoundedRectangle(cornerRadius: BeanDesign.Radius.sm).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: BeanDesign.Radius.sm).stroke(BeanDesign.subtleBorder))
                    }
                    .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: BeanDesign.Spacing.xs) {
                    Text("AFTER")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $model.transformedText)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(height: 230)
                            .background(RoundedRectangle(cornerRadius: BeanDesign.Radius.sm).fill(Color(nsColor: .textBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: BeanDesign.Radius.sm).stroke(BeanDesign.subtleBorder))
                            .disabled(model.isRunning)
                            .opacity(model.isRunning ? 0.5 : 1)
                        if model.isRunning {
                            ProgressView().controlSize(.small)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

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
                Button("Cancel", role: .cancel) { model.onCancel() }
                Spacer()
                Button("Try Again") { model.onTryAgain() }.disabled(model.isRunning)
                if model.allowsReplace {
                    Button("Copy") { model.onCopy() }.disabled(model.isRunning)
                    Button("Replace") { model.onReplace() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(model.isRunning)
                } else {
                    Button("Copy") { model.onCopy() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(model.isRunning)
                }
            }
        }
        .padding(BeanDesign.Spacing.lg)
        .frame(width: model.originalText == nil ? 480 : 720)
        .tint(BeanDesign.accent)
        .onExitCommand { model.onCancel() }
    }
}
