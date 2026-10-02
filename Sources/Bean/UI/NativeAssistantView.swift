import SwiftUI

struct NativeAssistantBadgeView: View {
    let state: NativeAssistantState
    let onOpen: () -> Void
    let onKeyboardOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 5) {
                BeanMark(size: 19)
                if !state.badgeText.isEmpty {
                    Text(state.badgeText).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                }
            }
            .padding(.horizontal, 9)
            .frame(minWidth: 38, minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .help(state.title)
        .accessibilityLabel("Bean: \(state.title). Open writing assistant.")
        .accessibilityAction { onKeyboardOpen() }
        .accessibilityAction(named: Text("Review with keyboard"), onKeyboardOpen)
    }
}

struct NativeAssistantPanelView: View {
    let state: NativeAssistantState
    let onReview: () -> Void
    let onAction: (WritingAction, Bool) -> Void
    let onFixAll: () -> Void
    let onUndo: () -> Void
    let onPause: () -> Void
    let onClose: () -> Void
    @State private var currentParagraph = false

    private var scope: String { state.canChooseParagraph && currentParagraph ? "current paragraph" : state.scope }
    private func perform(_ action: WritingAction) { onAction(action, state.canChooseParagraph && currentParagraph) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Text(state.title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 6)
                Button(action: onClose) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).accessibilityLabel("Close writing assistant")
            }
            Text(state.detail).font(.system(size: 11)).foregroundColor(BeanDesign.secondaryText).fixedSize(horizontal: false, vertical: true)
            if state.canChooseParagraph {
                Picker("Writing scope", selection: $currentParagraph) {
                    Text("Whole draft").tag(false)
                    Text("Current paragraph").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Writing scope")
                .accessibilityHint("Chooses which part of the focused editor Proofread and Rewrite change")
            }
            HStack {
                if state.issueCount > 0 { Button("Review suggestions", action: onReview) }
                Spacer(minLength: 0)
                Button("Proofread \(scope)") { perform(state.aiAvailable ? .proofread : .localQuickCheck) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            if state.safeFixCount > 0 {
                Button("Fix \(state.safeFixCount) obvious issue\(state.safeFixCount == 1 ? "" : "s")", action: onFixAll)
                    .controlSize(.small)
                    .accessibilityHint("Applies only high-confidence local corrections and verifies every edit")
            }
            Divider()
            Text("Rewrite \(scope) with AI").font(.system(size: 11, weight: .medium)).foregroundColor(BeanDesign.secondaryText)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Button("Clearer") { perform(.makeClearer) }
                    Button("Concise") { perform(.makeConcise) }
                }
                HStack {
                    Button("Professional") { perform(.makeProfessional) }
                    Button("Friendly") { perform(.makeCasual) }
                }
            }
            .controlSize(.small)
            .disabled(!state.aiAvailable)
            if !state.aiAvailable {
                Text("Connect AI in Bean Settings to rewrite.").font(.system(size: 11)).foregroundColor(BeanDesign.secondaryText)
            }
            if state.canUndo || state.canPauseApp {
                Divider()
                HStack {
                    if state.canUndo { Button("Undo Bean change", action: onUndo) }
                    Spacer(minLength: 0)
                    if state.canPauseApp { Button("Pause in this app for 1 hour", action: onPause) }
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 320)
        .tint(BeanDesign.accent)
        .background(RoundedRectangle(cornerRadius: BeanDesign.Radius.card).fill(.regularMaterial)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4))
        .onExitCommand(perform: onClose)
    }
}
