import AppKit
import SwiftUI

struct WritingWorkspaceView: View {
    @ObservedObject var model: WritingWorkspaceModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var userContent: UserContentStore
    let usageLedger: UsageLedgerStore
    let onSettings: (SettingsView.Category) -> Void
    let onOpen: () -> Void
    let onSave: () -> Void

    @State private var tab = ReviewTab.suggestions
    @State private var focusRequest: WritingTextEditor.FocusRequest?
    @State private var showsSampleConfirmation = false
    @State private var showsNewConfirmation = false
    @State private var providerTask: Task<Void, Never>?

    private enum ReviewTab: String, CaseIterable {
        case suggestions = "Suggestions"
        case rewrite = "Rewrite"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                draft
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                reviewPanel
                    .frame(width: 330)
            }
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 600)
        .background(BeanDesign.warmBackground)
        .tint(BeanDesign.accent)
        .onReceive(userContent.$dictionary) { _ in model.checkLocally() }
        .alert("Replace this draft with the example?", isPresented: $showsSampleConfirmation) {
            Button("Use Example") { loadSample() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save your current draft first if you want to keep it.")
        }
        .alert("Start a new draft?", isPresented: $showsNewConfirmation) {
            Button("New Draft") { model.load("", name: "Untitled draft", saved: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current draft has unsaved changes. Save it first if you want to keep them.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            BeanMark(size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bean Writer").font(.system(size: 16, weight: .semibold))
                Text("A little help. A clearer message.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: newDraft) { Label("New", systemImage: "square.and.pencil") }
                .keyboardShortcut("n", modifiers: .command)
            Button(action: onOpen) { Label("Open", systemImage: "folder") }
                .keyboardShortcut("o", modifiers: .command)
            Button(action: onSave) { Label("Save", systemImage: "square.and.arrow.down") }
                .keyboardShortcut("s", modifiers: .command)
            Button { onSettings(.general) } label: { Image(systemName: "gearshape") }
                .help("Settings")
                .accessibilityLabel("Open Settings")
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var draft: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(model.documentName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if model.isDirty {
                    Text("Unsaved").font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    ClipboardService.writeString(model.text)
                    model.showNotice("Draft copied.")
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .disabled(model.text.isEmpty)
                Button("Undo Suggestion") { model.undoSuggestion() }
                    .buttonStyle(.borderless)
                    .disabled(!model.canUndoSuggestion)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            Divider()
            ZStack(alignment: .topLeading) {
                WritingTextEditor(
                    text: model.text,
                    issues: model.issues,
                    selectedIssueID: model.selectedIssueID,
                    focusRequest: focusRequest,
                    onEdit: { model.edit($0) },
                    onSelectIssue: { model.selectedIssueID = $0; tab = .suggestions }
                )
                .id(model.documentID)
                if model.text.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Make room for your next idea.")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.secondary)
                            .allowsHitTesting(false)
                        Text("Write or paste a draft. Suggestions appear as you type.")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .allowsHitTesting(false)
                        Button("Try an example") { loadSample() }
                            .buttonStyle(.bordered)
                    }
                    .padding(36)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var reviewPanel: some View {
        VStack(spacing: 0) {
            Picker("Writing tools", selection: $tab) {
                ForEach(ReviewTab.allCases, id: \.self) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let notice = model.notice {
                        Text(notice)
                            .font(.system(size: 12))
                            .foregroundColor(BeanDesign.secondaryText)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(BeanDesign.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Status: \(notice)")
                    }
                    if tab == .suggestions { suggestions } else { rewrites }
                }
                .padding(16)
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.issues.isEmpty ? "Writing review" : "\(model.issues.count) suggestion\(model.issues.count == 1 ? "" : "s")")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                if model.hasAIReview {
                    Image(systemName: "sparkles").foregroundColor(BeanDesign.accent).help("Includes your AI review")
                }
            }
            Text(model.hasAIReview ? "Local + AI suggestions. You decide what fits." : "Spelling and spacing checked on your Mac.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            if model.issues.isEmpty {
                VStack(alignment: .center, spacing: 10) {
                    Image(systemName: model.text.isEmpty ? "text.cursor" : "checkmark.circle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(model.text.isEmpty ? BeanDesign.accent : BeanDesign.success)
                    Text(model.text.isEmpty ? "Start with your words"
                         : !model.localCheckingAvailable ? "Live checking paused"
                         : model.hasAIReview ? "Review complete" : "No local issues found")
                        .font(.system(size: 14, weight: .medium))
                    Text(model.text.isEmpty
                         ? "Your suggestions will appear here. Click an underline to review it."
                         : !model.localCheckingAvailable
                            ? "This draft is over the live checking limit. Open a smaller section to review it."
                         : model.hasAIReview
                            ? "No further suggestions found in this review. Read through your draft before sharing."
                            : "Local checks cover common typos and spacing. Use AI Review for deeper grammar feedback.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ForEach(model.issues) { issue in suggestionCard(issue) }
            }
            Divider()
            aiReviewButton
            if model.hasDismissedSuggestions {
                Button("Restore dismissed suggestions") { model.restoreDismissed() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            if !model.text.isEmpty {
                Button("Try an example") { showsSampleConfirmation = true }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
    }

    private func suggestionCard(_ issue: TextIssue) -> some View {
        let selected = model.selectedIssueID == issue.id
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                model.selectedIssueID = issue.id
                focusRequest = .init(range: issue.range)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(issue.type == .clarity ? BeanDesign.info : BeanDesign.danger).frame(width: 6, height: 6)
                        Text(issue.type.rawValue.capitalized).font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Text(issue.source == .llm ? "AI" : "On-device").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(display(issue.original)).strikethrough().foregroundColor(BeanDesign.danger)
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundColor(.secondary)
                        Text(display(issue.suggestion)).foregroundColor(BeanDesign.success)
                    }
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if selected {
                Text(issue.explanation ?? "A suggested improvement to your writing.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                HStack {
                    Button("Accept") { model.accept(issue) }
                        .buttonStyle(.borderedProminent)
                    Button("Dismiss") { model.dismiss(issue) }
                        .buttonStyle(.borderless)
                    Spacer()
                    if issue.type == .spelling {
                        Button { addToDictionary(issue) } label: { Image(systemName: "book.closed") }
                            .buttonStyle(.borderless)
                            .help("Add “\(issue.original)” to your dictionary")
                            .accessibilityLabel("Add \(issue.original) to dictionary")
                    }
                }
                .controlSize(.regular)
            }
        }
        .padding(14)
        .background(BeanDesign.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? BeanDesign.accent : BeanDesign.subtleBorder, lineWidth: selected ? 1.5 : 0.5))
    }

    @ViewBuilder
    private var aiReviewButton: some View {
        if model.isChecking {
            HStack {
                ProgressView().controlSize(.small)
                Text("Reviewing your draft…").font(.system(size: 12))
                Spacer()
                Button("Cancel") {
                    providerTask?.cancel()
                    model.cancelReview()
                }
            }
        } else if settings.hasAPIKey {
            Button { reviewWithAI() } label: {
                Label("Review with AI", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("Sends this draft to your AI provider when you click. Provider charges may apply.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        } else {
            Button { onSettings(.provider) } label: {
                Label("Connect AI for deeper feedback", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            Text("Optional. Local suggestions are free and work without an API key.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private var rewrites: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keep your voice.").font(.system(size: 20, weight: .semibold))
            Text("Choose a direction, then review the result before using it.")
                .font(.system(size: 12)).foregroundColor(.secondary)
            if let preview = model.preview {
                rewritePreview(preview)
            } else {
                ForEach([WritingAction.makeClearer, .makeConcise, .makeProfessional, .makeCasual]) { action in
                    Button {
                        if settings.hasAPIKey { rewrite(action) } else { onSettings(.provider) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: action.symbolName).font(.system(size: 17)).foregroundColor(BeanDesign.accent).frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(action.displayName).font(.system(size: 13, weight: .semibold))
                                Text(action.shortDescription).font(.system(size: 11)).foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        .padding(14)
                        .background(BeanDesign.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isChecking || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if model.isChecking { aiReviewButton }
                else {
                    Text(settings.hasAPIKey
                         ? "Uses your AI provider. Your draft stays unchanged until you apply a result."
                         : "Connect an optional AI provider in Settings to use rewrites.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        }
    }

    private func rewritePreview(_ preview: WritingWorkspaceModel.RewritePreview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(preview.action.displayName, systemImage: "sparkles").font(.system(size: 13, weight: .semibold))
            if let warning = preview.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundColor(BeanDesign.warning)
            }
            Text("Suggested version").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            Text(preview.text)
                .font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14).background(BeanDesign.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if !model.canApplyPreview {
                Text("Your draft changed. Generate a new version to apply a rewrite.")
                    .font(.system(size: 12)).foregroundColor(BeanDesign.warning)
            }
            HStack {
                Button("Apply to Draft") { model.applyPreview() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canApplyPreview)
                Button("Copy") {
                    ClipboardService.writeString(preview.text)
                    model.showNotice("Rewrite copied.")
                }
                .buttonStyle(.bordered)
            }
            DisclosureGroup("Compare original") {
                Text(preview.request.text).font(.system(size: 13)).foregroundColor(.secondary).textSelection(.enabled).padding(.top, 8)
            }
            Button("Back to rewrite options") { model.discardPreview() }.buttonStyle(.link)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Label(model.localCheckingAvailable ? "Local checking is on" : "Local checking paused · draft too long", systemImage: "lock.shield")
                .foregroundColor(model.localCheckingAvailable ? BeanDesign.success : BeanDesign.warning)
            Spacer()
            Text("\(model.wordCount) words")
            Text("\(model.text.count) characters")
            if !model.readingTime.isEmpty { Text(model.readingTime) }
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private func display(_ value: String) -> String {
        if value.isEmpty { return "Remove" }
        if value.allSatisfy(\.isWhitespace) { return value.count == 1 ? "1 space" : "\(value.count) spaces" }
        return value
    }

    private func newDraft() {
        if model.isDirty { showsNewConfirmation = true }
        else { model.load("", name: "Untitled draft", saved: true) }
    }

    private func loadSample() {
        model.load(WritingWorkspaceModel.sample, name: "Example draft", saved: false)
        tab = .suggestions
    }

    private func addToDictionary(_ issue: TextIssue) {
        switch userContent.upsert(DictionaryTerm(term: issue.original)) {
        case .inserted, .updated, .rejectedDuplicate:
            model.checkLocally()
        default:
            model.showNotice("That word couldn't be saved. Check your dictionary in Settings.")
        }
    }

    private func reviewWithAI() {
        guard let request = model.beginReview() else { return }
        let provider = settings.provider
        let providerModel = settings.model
        let key = settings.apiKey
        let timeout = settings.timeoutSeconds
        let dictionary = userContent.dictionary
        providerTask = Task {
            var detector = IssueDetector()
            detector.maxIssues = 12
            let result = await detector.llmIssues(in: request.text, context: nil, dictionary: dictionary,
                                                  provider: provider, model: providerModel, apiKey: key, timeout: timeout)
            if let usage = result.usage { usageLedger.record(usage, source: .manual, provider: provider.rawValue, model: providerModel) }
            model.completeReview(request, issues: result.issues, failure: result.failureOutcome)
        }
    }

    private func rewrite(_ action: WritingAction) {
        guard let request = model.beginReview() else { return }
        let provider = settings.provider
        let providerModel = settings.model
        let key = settings.apiKey
        let timeout = settings.timeoutSeconds
        let personalization = userContent.personalization(action: action, context: nil, explicitProfile: nil, sourceText: request.text)
        providerTask = Task {
            do {
                let result = try await WritingTransformService().transform(text: request.text, action: action, context: nil,
                    userContextLines: personalization.userContextLines, provider: provider, model: providerModel, apiKey: key, timeout: timeout)
                usageLedger.record(result.usage, source: .manual, provider: provider.rawValue, model: providerModel)
                model.completeRewrite(request, action: action, output: result.text)
            } catch {
                model.failReview(request, message: "The rewrite couldn't finish. Check your connection and AI settings, then try again.")
            }
        }
    }
}
