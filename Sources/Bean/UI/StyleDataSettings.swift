import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum StyleDimension: String, CaseIterable {
    case formality = "Formality"
    case warmth = "Warmth"
    case conciseness = "Conciseness"
    case directness = "Directness"
}

/// Pure presentation rules keep every 1–5 control understandable without
/// requiring the user to infer what a number means. The preview is illustrative
/// prose, generated locally and updated immediately; it never calls a provider.
enum StyleProfileUIModel {
    static func qualitativeLabel(for dimension: StyleDimension, value: Int) -> String {
        let index = min(max(value, 1), 5) - 1
        let labels: [String]
        switch dimension {
        case .formality:
            labels = ["Very casual", "Casual", "Balanced", "Formal", "Very formal"]
        case .warmth:
            labels = ["Reserved", "Matter-of-fact", "Balanced", "Warm", "Very warm"]
        case .conciseness:
            labels = ["Detailed", "Explanatory", "Balanced", "Concise", "Very concise"]
        case .directness:
            labels = ["Gentle", "Diplomatic", "Balanced", "Direct", "Very direct"]
        }
        return labels[index]
    }

    static func summary(for profile: StyleProfile) -> String {
        [
            qualitativeLabel(for: .formality, value: profile.formality),
            qualitativeLabel(for: .warmth, value: profile.warmth),
            qualitativeLabel(for: .conciseness, value: profile.conciseness),
            qualitativeLabel(for: .directness, value: profile.directness)
        ].joined(separator: " · ")
    }

    static func previewText(for profile: StyleProfile) -> String {
        let opening: String
        switch profile.warmth {
        case ...1: opening = "Update:"
        case 2: opening = "A quick update:"
        case 3: opening = "Thanks for the update."
        case 4: opening = "Thanks for the thoughtful update."
        default: opening = "Thanks so much for the thoughtful update."
        }

        let review: String
        switch profile.formality {
        case ...1: review = "I’ll take a look"
        case 2: review = "I’ll review it"
        case 3: review = "I’ll review the details"
        case 4: review = "I will review the details"
        default: review = "I will carefully review the details"
        }

        let nextStep: String
        switch profile.directness {
        case ...1: nextStep = "and share a few thoughts when I can."
        case 2: nextStep = "and suggest a few possible next steps."
        case 3: nextStep = "and share the next steps tomorrow."
        case 4: nextStep = "and send my recommendation tomorrow."
        default: nextStep = "and send my recommendation by 3 PM tomorrow."
        }

        let detail: String
        switch profile.conciseness {
        case ...1:
            detail = " I’ll include the reasoning, alternatives, and any trade-offs to consider."
        case 2:
            detail = " I’ll include the main reasoning and trade-offs."
        case 3:
            detail = " I’ll include the key trade-offs."
        case 4:
            detail = ""
        default:
            let compactNextStep: String
            switch profile.directness {
            case ...1: compactNextStep = "and follow up soon."
            case 2: compactNextStep = "and suggest a next step."
            case 3: compactNextStep = "and reply tomorrow."
            case 4: compactNextStep = "and recommend a next step tomorrow."
            default: compactNextStep = "and recommend a next step by 3 PM."
            }
            return "\(opening) \(review) \(compactNextStep)"
        }
        return "\(opening) \(review) \(nextStep)\(detail)"
    }
}

struct PersonalizationSheetMetrics: Equatable {
    let minWidth: CGFloat
    let idealWidth: CGFloat
    let maxWidth: CGFloat
    let minHeight: CGFloat
    let idealHeight: CGFloat
    let maxHeight: CGFloat
}

enum PersonalizationSheetLayout {
    static let profile = PersonalizationSheetMetrics(
        minWidth: 430, idealWidth: 500, maxWidth: 620,
        minHeight: 460, idealHeight: 650, maxHeight: 760
    )
    static let writingContext = PersonalizationSheetMetrics(
        minWidth: 400, idealWidth: 460, maxWidth: 620,
        minHeight: 340, idealHeight: 460, maxHeight: 650
    )
    static let dictionaryTerm = PersonalizationSheetMetrics(
        minWidth: 380, idealWidth: 440, maxWidth: 580,
        minHeight: 280, idealHeight: 340, maxHeight: 500
    )
    static let dictionaryImport = PersonalizationSheetMetrics(
        minWidth: 420, idealWidth: 500, maxWidth: 640,
        minHeight: 340, idealHeight: 440, maxHeight: 620
    )
    static let preferencesImport = PersonalizationSheetMetrics(
        minWidth: 440, idealWidth: 520, maxWidth: 680,
        minHeight: 340, idealHeight: 430, maxHeight: 600
    )

    static let all: [PersonalizationSheetMetrics] = [
        profile, writingContext, dictionaryTerm, dictionaryImport, preferencesImport
    ]
}

struct PersonalizationActionFeedback: Equatable {
    let message: String
    let isError: Bool

    var accessibilityLabel: String {
        "\(isError ? "Error" : "Success"): \(message)"
    }
}

enum PersonalizationActionUIModel {
    static func persistenceFailure(fallback: String, storeError: String?) -> String {
        let detail = storeError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return detail.isEmpty ? fallback : detail
    }
}

private struct PersonalizationActionFeedbackView: View {
    let feedback: PersonalizationActionFeedback

    var body: some View {
        Label(
            feedback.message,
            systemImage: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        )
        .font(.caption)
        .foregroundColor(feedback.isError ? .red : .secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(feedback.accessibilityLabel)
    }
}

private extension View {
    func personalizationSheetFrame(_ metrics: PersonalizationSheetMetrics) -> some View {
        frame(
            minWidth: metrics.minWidth,
            idealWidth: metrics.idealWidth,
            maxWidth: metrics.maxWidth,
            minHeight: metrics.minHeight,
            idealHeight: metrics.idealHeight,
            maxHeight: metrics.maxHeight
        )
    }
}

@MainActor
private func announcePersonalizationResult(_ feedback: PersonalizationActionFeedback) {
    NSAccessibility.post(
        element: NSApplication.shared,
        notification: .announcementRequested,
        userInfo: [
            .announcement: feedback.accessibilityLabel,
            .priority: NSNumber(
                value: (feedback.isError
                    ? NSAccessibilityPriorityLevel.high
                    : NSAccessibilityPriorityLevel.medium).rawValue
            )
        ]
    )
}

struct PersonalizationPersistenceStatus: View {
    @ObservedObject var store: UserContentStore

    var body: some View {
        if let persistenceError = store.persistenceError {
            Label(persistenceError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Storage error: \(persistenceError)")
        }
    }
}

// MARK: - Style Profiles

struct StyleProfilesSection: View {
    @ObservedObject var store: UserContentStore
    @State private var editing: StyleProfile?
    @State private var pendingDelete: StyleProfile?
    @State private var confirmBuiltInReset = false
    @State private var actionFeedback: PersonalizationActionFeedback?

    var body: some View {
        PersonalizationPersistenceStatus(store: store)
        ForEach(store.profiles) { profile in
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(profile.name).fontWeight(.medium)
                        if store.defaultProfileID == profile.id {
                            Text("Default").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        }
                        if profile.isBuiltIn {
                            Image(systemName: "lock.fill").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    Text(profile.detail).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Menu {
                    if profile.isBuiltIn {
                        // Built-ins are read-only — duplicate to customize.
                        Button("View") { editing = profile }
                        Button("Duplicate to Edit") { duplicate(profile) }
                        Button("Set as Default") { setDefault(profile) }
                    } else {
                        Button("Edit") { editing = profile }
                        Button("Duplicate") { duplicate(profile) }
                        Button("Set as Default") { setDefault(profile) }
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDelete = profile }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).frame(width: 40)
                    .accessibilityLabel("More options for \(profile.name)")
            }
        }
        HStack {
            Button { editing = StyleProfile(name: "") } label: {
                Label("Add Profile", systemImage: "plus")
            }
            Spacer()
            Button("Reset Built-ins…") { confirmBuiltInReset = true }
                .confirmationDialog(
                    "Restore Bean’s built-in profiles?",
                    isPresented: $confirmBuiltInReset,
                    titleVisibility: .visible
                ) {
                    Button("Restore Built-ins") { resetBuiltIns() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Custom profiles stay intact. Built-in profiles return to their original names and settings.")
                }
        }
        // `editing` may be a built-in (View) — the editor disables saving for
        // built-ins, so viewing one can't modify it.
        .sheet(item: $editing) { profile in
            ProfileEditor(
                profile: profile,
                isNew: !store.profiles.contains(where: { $0.id == profile.id }),
                onSave: { profile in
                    let wasNew = !store.profiles.contains(where: { $0.id == profile.id })
                    let succeeded = store.upsert(profile)
                    if succeeded {
                        editing = nil
                        showFeedback(
                            wasNew ? "Added “\(profile.name)”." : "Saved “\(profile.name)”.",
                            error: false
                        )
                    }
                    return succeeded
                },
                persistenceError: { store.persistenceError },
                onCancel: { editing = nil }
            )
        }
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.name)” profile?" } ?? "Delete profile?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let profile = pendingDelete {
                Button("Delete Profile", role: .destructive) {
                    let succeeded = store.deleteProfile(profile.id)
                    pendingDelete = nil
                    if succeeded {
                        showFeedback("Deleted “\(profile.name)”.", error: false)
                    } else {
                        showFeedback(
                            persistenceFailure("Bean couldn’t save this deletion. The profile was not removed."),
                            error: true
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This cannot be undone. If it is the General Default, Bean will use its Default style. App defaults using it will return to the General Default.")
        }
        Text("Built-in profiles (🔒) are read-only — duplicate one to customize it.")
            .font(.caption2).foregroundColor(.secondary)
        if let actionFeedback {
            PersonalizationActionFeedbackView(feedback: actionFeedback)
        }
    }

    private func duplicate(_ profile: StyleProfile) {
        if store.duplicate(profile.id) {
            showFeedback("Created “\(profile.name) Copy”.", error: false)
        } else {
            showFeedback(
                persistenceFailure("Bean couldn’t save a copy of this profile."),
                error: true
            )
        }
    }

    private func setDefault(_ profile: StyleProfile) {
        if store.setDefaultProfile(profile.id) {
            showFeedback("General Default is now “\(profile.name)”.", error: false)
        } else {
            showFeedback(
                persistenceFailure("Bean couldn’t save the General Default."),
                error: true
            )
        }
    }

    private func resetBuiltIns() {
        if store.resetBuiltIns() {
            showFeedback("Built-in profiles restored.", error: false)
        } else {
            showFeedback(
                persistenceFailure("Bean couldn’t save the restored built-in profiles."),
                error: true
            )
        }
    }

    private func persistenceFailure(_ fallback: String) -> String {
        PersonalizationActionUIModel.persistenceFailure(
            fallback: fallback,
            storeError: store.persistenceError
        )
    }

    private func showFeedback(_ message: String, error: Bool) {
        let feedback = PersonalizationActionFeedback(message: message, isError: error)
        actionFeedback = feedback
        announcePersonalizationResult(feedback)
    }
}

struct ProfileEditor: View {
    private enum FocusField: Hashable { case name }

    @State private var draft: StyleProfile
    @State private var bannedText: String
    @State private var examplesText: String
    @State private var validationMessage: String?
    @FocusState private var focusedField: FocusField?
    let isNew: Bool
    let onSave: (StyleProfile) -> Bool
    let persistenceError: () -> String?
    let onCancel: () -> Void

    init(
        profile: StyleProfile,
        isNew: Bool,
        onSave: @escaping (StyleProfile) -> Bool,
        persistenceError: @escaping () -> String? = { nil },
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: profile)
        _bannedText = State(initialValue: profile.bannedPhrases.joined(separator: "\n"))
        _examplesText = State(initialValue: profile.exampleSnippets.joined(separator: "\n"))
        self.isNew = isNew
        self.onSave = onSave
        self.persistenceError = persistenceError
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.isBuiltIn ? "Built-in Profile (read-only)" : (isNew ? "Add Profile" : "Edit Profile"))
                .font(.headline)
            Form {
                TextField("Name", text: $draft.name)
                    .focused($focusedField, equals: .name)
                    .accessibilityHint("A descriptive name for this writing style")
                TextField("Description", text: $draft.detail)
                scaleRow(.formality, $draft.formality)
                scaleRow(.warmth, $draft.warmth)
                scaleRow(.conciseness, $draft.conciseness)
                scaleRow(.directness, $draft.directness)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label("Live preview", systemImage: "text.quote")
                            .font(.caption).fontWeight(.semibold)
                        Spacer()
                        Text("Local example").font(.caption2).foregroundColor(.secondary)
                    }
                    Text(StyleProfileUIModel.previewText(for: draft))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(StyleProfileUIModel.summary(for: draft))
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Style preview. \(StyleProfileUIModel.previewText(for: draft))")
                VStack(alignment: .leading) {
                    Text("Preferred instructions").font(.caption)
                    TextField("e.g. Keep it warm but concise", text: $draft.preferredInstructions)
                        .accessibilityLabel("Preferred instructions")
                }
                VStack(alignment: .leading) {
                    Text("Banned phrases (one per line)").font(.caption)
                    TextEditor(text: $bannedText)
                        .frame(height: 44)
                        .border(Color.secondary.opacity(0.2))
                        .accessibilityLabel("Banned phrases, one per line")
                }
                VStack(alignment: .leading) {
                    Text("Example snippets — style references only (one per line)").font(.caption)
                    TextEditor(text: $examplesText)
                        .frame(height: 60)
                        .border(Color.secondary.opacity(0.2))
                        .accessibilityLabel("Example snippets, one per line")
                }
            }
            .formStyle(.grouped)
            .disabled(draft.isBuiltIn) // built-ins are read-only
            .frame(maxHeight: .infinity)
            if let validationMessage {
                PersonalizationActionFeedbackView(
                    feedback: PersonalizationActionFeedback(message: validationMessage, isError: true)
                )
            }
            HStack {
                Button(draft.isBuiltIn ? "Close" : "Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !draft.isBuiltIn {
                    Button("Save") {
                        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedName.isEmpty else {
                            showError("Enter a profile name.", focus: .name)
                            return
                        }
                        draft.name = trimmedName
                        draft.bannedPhrases = lines(bannedText)
                        draft.exampleSnippets = lines(examplesText)
                        guard onSave(draft) else {
                            showError(PersonalizationActionUIModel.persistenceFailure(
                                fallback: "Bean couldn’t save this profile. Your changes remain in this editor; choose Save to try again.",
                                storeError: persistenceError()
                            ))
                            return
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(18)
        .personalizationSheetFrame(PersonalizationSheetLayout.profile)
        .onAppear {
            if !draft.isBuiltIn { focusedField = .name }
        }
    }

    private func showError(_ message: String, focus: FocusField? = nil) {
        validationMessage = message
        if let focus { focusedField = focus }
        announcePersonalizationResult(
            PersonalizationActionFeedback(message: message, isError: true)
        )
    }

    private func scaleRow(_ dimension: StyleDimension, _ value: Binding<Int>) -> some View {
        let qualitativeLabel = StyleProfileUIModel.qualitativeLabel(
            for: dimension,
            value: value.wrappedValue
        )
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(dimension.rawValue).font(.caption)
                Spacer()
                Text("\(value.wrappedValue) of 5 · \(qualitativeLabel)")
                .font(.caption).fontWeight(.medium)
            }
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = Int($0.rounded()) }
            ),
                   in: 1...5, step: 1)
                .accessibilityLabel(dimension.rawValue)
                .accessibilityValue("\(value.wrappedValue) of 5, \(qualitativeLabel)")
                .accessibilityHint("Choose from 1 to 5")
        }
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - Writing Context

struct WritingContextSection: View {
    @ObservedObject var store: UserContentStore
    @State private var editing: WritingContext?
    @State private var pendingDelete: WritingContext?
    @State private var actionFeedback: PersonalizationActionFeedback?

    var body: some View {
        PersonalizationPersistenceStatus(store: store)
        Text("Enabled items can accompany every provider-backed rewrite through your selected AI provider. Quick Fix and local checks never send them.")
            .font(.caption).foregroundColor(.secondary)
        if store.writingContexts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("No Writing Context yet", systemImage: "doc.text")
                    .fontWeight(.medium)
                Text("Add product details, company background, or terminology. Bean treats it as reference material, never as commands.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        ForEach(store.writingContexts) { context in
            HStack {
                Toggle("Use \(context.title)", isOn: enabledBinding(context))
                    .labelsHidden()
                    .accessibilityHint("When enabled, this Writing Context can accompany every provider-backed rewrite")
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.title).fontWeight(.medium)
                    Text(context.content).font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                Spacer()
                Menu {
                    Button("Edit") { editing = context }
                    Button("Delete…", role: .destructive) { pendingDelete = context }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).frame(width: 40)
                    .accessibilityLabel("More options for \(context.title)")
            }
        }
        Button { editing = WritingContext(title: "", content: "") } label: {
            Label("Add Writing Context", systemImage: "plus")
        }
        .sheet(item: $editing) { context in
            WritingContextEditor(
                context: context,
                onSave: { context in
                    let wasNew = !store.writingContexts.contains(where: { $0.id == context.id })
                    let succeeded = store.upsert(context)
                    if succeeded {
                        editing = nil
                        showFeedback(
                            wasNew ? "Added “\(context.title)”." : "Saved “\(context.title)”.",
                            error: false
                        )
                    }
                    return succeeded
                },
                persistenceError: { store.persistenceError },
                onCancel: { editing = nil }
            )
        }
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.title)” Writing Context?" } ?? "Delete Writing Context?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let context = pendingDelete {
                Button("Delete Writing Context", role: .destructive) {
                    let succeeded = store.deleteWritingContext(context.id)
                    pendingDelete = nil
                    if succeeded {
                        showFeedback("Deleted “\(context.title)”.", error: false)
                    } else {
                        showFeedback(
                            persistenceFailure("Bean couldn’t save this deletion. The Writing Context was not removed."),
                            error: true
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This reference will no longer be available to Bean. This cannot be undone.")
        }
        if let actionFeedback {
            PersonalizationActionFeedbackView(feedback: actionFeedback)
        }
    }

    private func enabledBinding(_ context: WritingContext) -> Binding<Bool> {
        Binding(
            get: {
                store.writingContexts.first(where: { $0.id == context.id })?.isEnabledByDefault
                    ?? context.isEnabledByDefault
            },
            set: { newValue in
                var updated = context
                updated.isEnabledByDefault = newValue
                if store.upsert(updated) {
                    actionFeedback = nil
                } else {
                    showFeedback(
                        persistenceFailure("Bean couldn’t save this Writing Context setting."),
                        error: true
                    )
                }
            }
        )
    }

    private func persistenceFailure(_ fallback: String) -> String {
        PersonalizationActionUIModel.persistenceFailure(
            fallback: fallback,
            storeError: store.persistenceError
        )
    }

    private func showFeedback(_ message: String, error: Bool) {
        let feedback = PersonalizationActionFeedback(message: message, isError: error)
        actionFeedback = feedback
        announcePersonalizationResult(feedback)
    }
}

struct WritingContextEditor: View {
    private enum FocusField: Hashable { case title, content }

    @State private var draft: WritingContext
    @State private var validationMessage: String?
    @FocusState private var focusedField: FocusField?
    let onSave: (WritingContext) -> Bool
    let persistenceError: () -> String?
    let onCancel: () -> Void

    init(
        context: WritingContext,
        onSave: @escaping (WritingContext) -> Bool,
        persistenceError: @escaping () -> String? = { nil },
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: context)
        self.onSave = onSave
        self.persistenceError = persistenceError
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.title.isEmpty ? "Add Writing Context" : "Edit Writing Context")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Give Bean durable background it can use while shaping your words. Avoid secrets or temporary message details.")
                        .font(.caption).foregroundColor(.secondary)
                    TextField("Title", text: $draft.title)
                        .focused($focusedField, equals: .title)
                        .accessibilityHint("A short name for this reference")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reference text").font(.caption)
                        TextEditor(text: $draft.content)
                            .focused($focusedField, equals: .content)
                            .frame(minHeight: 120, idealHeight: 150, maxHeight: 240)
                            .border(Color.secondary.opacity(0.2))
                            .accessibilityLabel("Writing Context reference text")
                    }
                    Toggle("Include with provider-backed rewrites", isOn: $draft.isEnabledByDefault)
                        .accessibilityHint("When enabled, this Writing Context can accompany every provider-backed rewrite; you can turn it off later")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let validationMessage {
                PersonalizationActionFeedbackView(
                    feedback: PersonalizationActionFeedback(message: validationMessage, isError: true)
                )
            }
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else {
                        showError("Enter a title.", focus: .title)
                        return
                    }
                    guard !content.isEmpty else {
                        showError("Add reference text.", focus: .content)
                        return
                    }
                    draft.title = title
                    draft.content = content
                    guard onSave(draft) else {
                        showError(PersonalizationActionUIModel.persistenceFailure(
                            fallback: "Bean couldn’t save this Writing Context. Your changes remain in this editor; choose Save to try again.",
                            storeError: persistenceError()
                        ))
                        return
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(18)
        .personalizationSheetFrame(PersonalizationSheetLayout.writingContext)
        .onAppear { focusedField = .title }
    }

    private func showError(_ message: String, focus: FocusField? = nil) {
        validationMessage = message
        if let focus { focusedField = focus }
        announcePersonalizationResult(
            PersonalizationActionFeedback(message: message, isError: true)
        )
    }
}

// MARK: - Personal Dictionary

struct DictionarySection: View {
    @ObservedObject var store: UserContentStore
    @State private var editing: DictionaryTerm?
    @State private var pendingDelete: DictionaryTerm?
    @State private var showImport = false
    @State private var feedbackMessage: String?
    @State private var feedbackIsError = false

    var body: some View {
        PersonalizationPersistenceStatus(store: store)
        Text("Add product names, acronyms, or terms Bean should preserve exactly instead of \"correcting.\"")
            .font(.caption).foregroundColor(.secondary)
        if store.dictionary.isEmpty {
            Label("No saved terms yet", systemImage: "book.closed")
                .font(.caption).foregroundColor(.secondary)
                .accessibilityHint("Choose Add Term to create your first dictionary entry")
        }
        ForEach(store.dictionary) { term in
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(term.term).fontWeight(.medium)
                        if term.caseSensitive {
                            Text("Case-sensitive")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    if let note = term.note, !note.isEmpty {
                        Text(note).font(.caption).foregroundColor(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Menu {
                    Button("Edit") { editing = term }
                    Button("Delete…", role: .destructive) { pendingDelete = term }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).frame(width: 40)
                .accessibilityLabel("More options for \(term.term)")
            }
        }
        HStack {
            Button {
                editing = DictionaryTerm(term: "")
            } label: {
                Label("Add Term", systemImage: "plus")
            }
            .sheet(item: $editing) { term in
                DictionaryTermEditor(
                    term: term,
                    isNew: !store.dictionary.contains(where: { $0.id == term.id }),
                    onSave: { draft in
                        let result = store.upsert(draft)
                        switch result {
                        case .inserted(let saved):
                            editing = nil
                            showFeedback("Added “\(saved.term)”.", error: false)
                        case .updated(let saved):
                            editing = nil
                            showFeedback("Saved “\(saved.term)”.", error: false)
                        case .rejectedEmpty, .rejectedDuplicate, .persistenceFailed:
                            break
                        }
                        return result
                    },
                    persistenceError: { store.persistenceError },
                    onCancel: { editing = nil }
                )
            }
            Spacer()
            Button("Import…") { showImport = true }
                .sheet(isPresented: $showImport) {
                    DictionaryImportSheet(store: store) { report in
                        showImport = false
                        var parts = ["Imported \(report.addedCount) \(report.addedCount == 1 ? "term" : "terms")."]
                        if report.duplicateCount > 0 {
                            parts.append("Skipped \(report.duplicateCount) \(report.duplicateCount == 1 ? "duplicate" : "duplicates").")
                        }
                        if report.emptyLineCount > 0 {
                            parts.append("Ignored \(report.emptyLineCount) empty \(report.emptyLineCount == 1 ? "line" : "lines").")
                        }
                        showFeedback(parts.joined(separator: " "), error: false)
                    } onCancel: {
                        showImport = false
                    }
                }
            Button("Export…", action: exportDictionary)
                .disabled(store.dictionary.isEmpty)
        }
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.term)” from the dictionary?" } ?? "Delete dictionary term?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let term = pendingDelete {
                Button("Delete Term", role: .destructive) {
                    pendingDelete = nil
                    if store.deleteTerm(term.id) {
                        showFeedback("Deleted “\(term.term)”.", error: false)
                    } else {
                        showFeedback(
                            persistenceFailure("Bean couldn’t save this deletion. The term was not removed."),
                            error: true
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Bean may correct this term normally after it is removed.")
        }
        Text("Text import and export include terms only. A preferences backup also preserves notes and case settings.")
            .font(.caption2).foregroundColor(.secondary)
        if let feedbackMessage {
            PersonalizationActionFeedbackView(
                feedback: PersonalizationActionFeedback(
                    message: feedbackMessage,
                    isError: feedbackIsError
                )
            )
        }
    }

    private func showFeedback(_ text: String, error: Bool) {
        feedbackMessage = text
        feedbackIsError = error
        announcePersonalizationResult(
            PersonalizationActionFeedback(message: text, isError: error)
        )
    }

    private func persistenceFailure(_ fallback: String) -> String {
        PersonalizationActionUIModel.persistenceFailure(
            fallback: fallback,
            storeError: store.persistenceError
        )
    }

    private func exportDictionary() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Bean-Dictionary.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportDictionary(to: url)
            showFeedback(
                "Exported \(store.dictionary.count) \(store.dictionary.count == 1 ? "term" : "terms") to \(url.lastPathComponent).",
                error: false
            )
        } catch {
            showFeedback("Bean couldn’t export the dictionary. Choose another location and try again.", error: true)
        }
    }
}

struct DictionaryTermEditor: View {
    private enum FocusField: Hashable { case term, note }

    @State private var draft: DictionaryTerm
    @State private var validationMessage: String?
    @FocusState private var focusedField: FocusField?
    let isNew: Bool
    let onSave: (DictionaryTerm) -> DictionaryMutationResult
    let persistenceError: () -> String?
    let onCancel: () -> Void

    init(
        term: DictionaryTerm,
        isNew: Bool,
        onSave: @escaping (DictionaryTerm) -> DictionaryMutationResult,
        persistenceError: @escaping () -> String? = { nil },
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: term)
        self.isNew = isNew
        self.onSave = onSave
        self.persistenceError = persistenceError
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Add Dictionary Term" : "Edit Dictionary Term")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Bean preserves this term when it already appears in your writing. It will never insert the term on its own.")
                        .font(.caption).foregroundColor(.secondary)
                    TextField("Term", text: $draft.term)
                        .focused($focusedField, equals: .term)
                        .accessibilityHint("The word, name, or acronym Bean should preserve")
                    TextField("Note (optional)", text: noteBinding)
                        .focused($focusedField, equals: .note)
                        .accessibilityHint("A private reminder about this term")
                    Toggle("Case-sensitive", isOn: $draft.caseSensitive)
                        .accessibilityHint("When enabled, only this exact capitalization is protected")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let validationMessage {
                PersonalizationActionFeedbackView(
                    feedback: PersonalizationActionFeedback(message: validationMessage, isError: true)
                )
            }
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .personalizationSheetFrame(PersonalizationSheetLayout.dictionaryTerm)
        .onAppear { focusedField = .term }
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { draft.note ?? "" },
            set: { draft.note = $0 }
        )
    }

    private func save() {
        switch onSave(draft) {
        case .inserted, .updated:
            break
        case .rejectedEmpty:
            showError("Enter a term.", focus: .term)
        case .rejectedDuplicate:
            showError(
                "That term conflicts with an existing entry. Differently capitalized variants can coexist only when both entries are case-sensitive.",
                focus: .term
            )
        case .persistenceFailed:
            showError(PersonalizationActionUIModel.persistenceFailure(
                fallback: "Bean couldn’t save this term. Your changes remain in this editor; choose Save to try again.",
                storeError: persistenceError()
            ))
        }
    }

    private func showError(_ message: String, focus: FocusField? = nil) {
        validationMessage = message
        if let focus { focusedField = focus }
        announcePersonalizationResult(
            PersonalizationActionFeedback(message: message, isError: true)
        )
    }
}

struct DictionaryImportSheet: View {
    private enum FocusField: Hashable { case terms }

    @ObservedObject var store: UserContentStore
    @State private var importText = ""
    @State private var preview: DictionaryImportPreview?
    @State private var importError: String?
    @FocusState private var focusedField: FocusField?
    let onImport: (DictionaryImportReport) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let preview {
                Text("Review Dictionary Import").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Nothing changes until you confirm.")
                            .font(.caption).foregroundColor(.secondary)
                        importPreview(preview)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Import Dictionary Terms").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Paste one term per line. Imported terms are case-insensitive by default; you can edit them afterward.")
                            .font(.caption).foregroundColor(.secondary)
                        TextEditor(text: $importText)
                            .focused($focusedField, equals: .terms)
                            .frame(minHeight: 160, idealHeight: 210, maxHeight: 320)
                            .border(Color.secondary.opacity(0.2))
                            .accessibilityLabel("Terms to import, one per line")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let importError {
                PersonalizationActionFeedbackView(
                    feedback: PersonalizationActionFeedback(message: importError, isError: true)
                )
            }
            Divider()
            if let preview {
                HStack {
                    Button("Back") {
                        self.preview = nil
                        importError = nil
                        DispatchQueue.main.async { focusedField = .terms }
                    }
                    Button("Cancel", role: .cancel) { onCancel() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Import \(preview.addedCount) \(preview.addedCount == 1 ? "Term" : "Terms")") {
                        performImport()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.addedCount == 0)
                }
            } else {
                HStack {
                    Button("Cancel", role: .cancel) { onCancel() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Review Import") {
                        preview = store.previewTermImport(newlineSeparated: importText)
                        importError = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(18)
        .personalizationSheetFrame(PersonalizationSheetLayout.dictionaryImport)
        .onAppear { focusedField = .terms }
    }

    private func performImport() {
        let report = store.importTerms(newlineSeparated: importText)
        guard report.persistenceSucceeded else {
            let message = PersonalizationActionUIModel.persistenceFailure(
                fallback: "Bean couldn’t save the imported terms. Nothing was imported; choose Import to try again.",
                storeError: store.persistenceError
            )
            importError = message
            announcePersonalizationResult(
                PersonalizationActionFeedback(message: message, isError: true)
            )
            return
        }
        onImport(report)
    }

    @ViewBuilder
    private func importPreview(_ preview: DictionaryImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "\(preview.addedCount) new \(preview.addedCount == 1 ? "term" : "terms")",
                systemImage: preview.addedCount > 0 ? "checkmark.circle.fill" : "minus.circle"
            )
            if !preview.acceptedTerms.isEmpty {
                Text(preview.acceptedTerms.prefix(6).map(\.term).joined(separator: ", "))
                    .font(.caption).foregroundColor(.secondary).lineLimit(3)
            }
            if !preview.duplicateTerms.isEmpty {
                Label(
                    "\(preview.duplicateTerms.count) \(preview.duplicateTerms.count == 1 ? "duplicate" : "duplicates") will be skipped",
                    systemImage: "arrow.uturn.forward.circle"
                )
                Text(preview.duplicateTerms.prefix(6).joined(separator: ", "))
                    .font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
            if preview.emptyLineCount > 0 {
                Text("\(preview.emptyLineCount) empty \(preview.emptyLineCount == 1 ? "line" : "lines") will be ignored.")
                    .font(.caption).foregroundColor(.secondary)
            }
            if preview.addedCount == 0 {
                Label("There are no new terms to import.", systemImage: "info.circle")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - App Defaults

struct AppDefaultsSection: View {
    @ObservedObject var store: UserContentStore
    @State private var actionFeedback: PersonalizationActionFeedback?

    private let categories: [(AppCategory, String)] = [
        (.chat, "Chat (Slack/Teams/Messages)"),
        (.mail, "Mail (Mail/Outlook)"),
        (.docs, "Docs (Notion/Jira/Confluence)"),
        (.codeEditor, "Code editors")
    ]

    var body: some View {
        PersonalizationPersistenceStatus(store: store)
        Text("Choose a style for each app category, or let it follow the General Default (\(generalDefaultName)). Search and address fields stay conservative automatically.")
            .font(.caption).foregroundColor(.secondary)
        ForEach(categories, id: \.0) { category, label in
            Picker(label, selection: styleBinding(category)) {
                Text("Use General Default").tag(Optional<UUID>.none)
                Divider()
                ForEach(store.profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            .accessibilityHint("Use General Default follows the profile selected as Bean’s overall default")
        }
        if let actionFeedback {
            PersonalizationActionFeedbackView(feedback: actionFeedback)
        }
    }

    private var generalDefaultName: String {
        store.profile(store.defaultProfileID)?.name ?? "Default"
    }

    private func styleBinding(_ category: AppCategory) -> Binding<UUID?> {
        Binding(
            get: { store.appRuleStyle(category: category) },
            set: { profileID in
                let categoryName = categories.first(where: { $0.0 == category })?.1 ?? category.rawValue
                let styleName = profileID.flatMap { store.profile($0)?.name } ?? "General Default"
                if store.setAppRuleStyle(category: category, profileID: profileID) {
                    showFeedback("\(categoryName) now uses \(styleName).", error: false)
                } else {
                    showFeedback(
                        PersonalizationActionUIModel.persistenceFailure(
                            fallback: "Bean couldn’t save the app default. The previous selection is still in use.",
                            storeError: store.persistenceError
                        ),
                        error: true
                    )
                }
            }
        )
    }

    private func showFeedback(_ message: String, error: Bool) {
        let feedback = PersonalizationActionFeedback(message: message, isError: error)
        actionFeedback = feedback
        announcePersonalizationResult(feedback)
    }
}

// MARK: - Data (export / import / reset)

enum PreferencesImportUIModel {
    /// Reads a user-selected backup without allowing a sparse or unexpectedly
    /// large file to be materialized on the main actor before validation. The
    /// descriptor-based helper also verifies that the selected entry remains a
    /// regular file for the duration of the bounded read.
    static func boundedBackupData(at url: URL) throws -> Data {
        do {
            return try ExactFileSystem.readRegularFile(
                at: url,
                maximumBytes: UserContentFileLimits.maximumEncodedBytes
            ).data
        } catch {
            throw UserContentStoreError.unreadableBackup
        }
    }

    /// Keeps the filesystem trust boundary ahead of JSON previewing. Invalid
    /// entries never reach the store, and the returned candidate binds the
    /// reviewed preview to the exact bounded bytes that can later be imported.
    static func prepareCandidate(
        at url: URL,
        preview: (Data) throws -> PreferencesImportPreview
    ) throws -> PreferencesImportCandidate {
        let data = try boundedBackupData(at: url)
        return PreferencesImportCandidate(
            sourceName: url.lastPathComponent,
            data: data,
            preview: try preview(data)
        )
    }

    static func summary(for preview: PreferencesImportPreview) -> String {
        [
            count(preview.profileCount, singular: "style", plural: "styles"),
            count(preview.writingContextCount, singular: "Writing Context item", plural: "Writing Context items"),
            count(preview.dictionaryCount, singular: "dictionary term", plural: "dictionary terms"),
            count(preview.appRuleCount, singular: "app default", plural: "app defaults")
        ].joined(separator: " · ")
    }

    static func notices(for preview: PreferencesImportPreview) -> [String] {
        var result: [String] = []
        if preview.repairedProfileReferenceCount > 0 {
            result.append(
                "Bean will repair \(count(preview.repairedProfileReferenceCount, singular: "outdated or missing profile reference", plural: "outdated or missing profile references"))."
            )
        }
        if preview.skippedDictionaryDuplicateCount > 0 {
            result.append(
                "Bean will skip \(count(preview.skippedDictionaryDuplicateCount, singular: "duplicate dictionary term", plural: "duplicate dictionary terms"))."
            )
        }
        return result
    }

    static func failureMessage(for error: Error) -> String {
        let message: String
        if let description = (error as? LocalizedError)?.errorDescription, !description.isEmpty {
            message = description
        } else {
            message = "Bean couldn’t read this preferences backup."
        }

        if let storeError = error as? UserContentStoreError,
           storeError == .unableToRollbackImport {
            // This exceptional path deliberately does not claim the old state
            // survived; the store's recovery instruction must stand on its own.
            return message
        }
        if message.localizedCaseInsensitiveContains("unchanged") { return message }
        return "\(message) Your current preferences are unchanged."
    }

    private static func count(_ value: Int, singular: String, plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }
}

struct PreferencesImportCandidate: Identifiable {
    let id = UUID()
    let sourceName: String
    let data: Data
    let preview: PreferencesImportPreview
}

struct DataSection: View {
    @ObservedObject var store: UserContentStore
    @State private var message: String?
    @State private var isError = false
    @State private var confirmReset = false
    @State private var pendingImport: PreferencesImportCandidate?
    @State private var safetyBackupURL: URL?

    var body: some View {
        if let persistenceError = store.persistenceError {
            Label(persistenceError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.red)
                .accessibilityLabel("Storage error: \(persistenceError)")
        }
        Text("Backups include styles, Writing Context, dictionary terms, and app defaults. They never include API keys, logs, or text you proofread or rewrite.")
            .font(.caption).foregroundColor(.secondary)
        HStack {
            Button("Export Preferences…", action: exportPrefs)
            Button("Import Preferences…", action: importPrefs)
                .sheet(item: $pendingImport) { candidate in
                    PreferencesImportConfirmation(
                        candidate: candidate,
                        onConfirm: { confirmImport(candidate) },
                        onCancel: { pendingImport = nil }
                    )
                }
        }
        Button("Reset Personalization Data…", role: .destructive) { confirmReset = true }
            .confirmationDialog("Reset styles, Writing Context, dictionary terms, and app defaults?",
                                isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset to Defaults", role: .destructive) {
                    if store.resetToDefaults() {
                        show("Personalization data was reset to Bean’s defaults.", error: false)
                    } else {
                        show(
                            PersonalizationActionUIModel.persistenceFailure(
                                fallback: "Bean couldn’t save the reset. Your personalization was not changed.",
                                storeError: store.persistenceError
                            ),
                            error: true
                        )
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Custom styles, Writing Context, and dictionary terms will be deleted. Export a backup first if you may want them later.")
            }
        if let message {
            PersonalizationActionFeedbackView(
                feedback: PersonalizationActionFeedback(message: message, isError: isError)
            )
        }
        if let safetyBackupURL {
            Button("Show Pre-import Backup in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([safetyBackupURL])
            }
            .font(.caption)
            .accessibilityHint("Shows the automatic safety copy of your previous preferences")
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        isError = error
        announcePersonalizationResult(
            PersonalizationActionFeedback(message: text, isError: error)
        )
    }

    private func exportPrefs() {
        let panel = NSSavePanel()
        let date = ISO8601DateFormatter()
        date.formatOptions = [.withFullDate]
        panel.nameFieldStringValue = "Bean-\(AppInfo.version)-\(date.string(from: Date()))-Preferences.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Log.event("data: export preferences")
        do {
            let data = try store.encodedBackup(prettyPrinted: true)
            try data.write(to: url, options: [.atomic])
            show("Exported preferences to \(url.lastPathComponent).", error: false)
        } catch {
            show("Bean couldn’t write the backup. Choose another location and try again.", error: true)
        }
    }

    private func importPrefs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Log.event("data: import preferences")

        do {
            // The store validates and normalizes the entire candidate without
            // changing current preferences. The user reviews this exact data.
            pendingImport = try PreferencesImportUIModel.prepareCandidate(at: url) { data in
                try store.previewBackupImport(data: data)
            }
        } catch {
            show(PreferencesImportUIModel.failureMessage(for: error), error: true)
        }
    }

    private func confirmImport(_ candidate: PreferencesImportCandidate) -> String? {
        do {
            // The store creates the backup and commits the import as one
            // transaction, restoring the previous state if persistence fails.
            let report = try store.importBackup(data: candidate.data)
            pendingImport = nil
            safetyBackupURL = report.safetyBackupURL
            show(
                "Imported \(candidate.sourceName). Your previous preferences were saved as \(report.safetyBackupURL.lastPathComponent).",
                error: false
            )
            return nil
        } catch {
            let failure = PreferencesImportUIModel.failureMessage(for: error)
            show(failure, error: true)
            return failure
        }
    }
}

struct PreferencesImportConfirmation: View {
    let candidate: PreferencesImportCandidate
    let onConfirm: () -> String?
    let onCancel: () -> Void
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Preferences Import").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(candidate.sourceName)
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(PreferencesImportUIModel.summary(for: candidate.preview))
                            .font(.callout).fontWeight(.medium)
                        Text("General Default: \(candidate.preview.generalDefaultName)")
                            .font(.caption).foregroundColor(.secondary)
                        ForEach(PreferencesImportUIModel.notices(for: candidate.preview), id: \.self) { notice in
                            Label(notice, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                    .accessibilityElement(children: .combine)
                    Label(
                        "Bean will automatically save your current preferences before importing.",
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption).foregroundColor(.secondary)
                    Text("Importing replaces your current personalization settings. Nothing changes until you confirm.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let importError {
                PersonalizationActionFeedbackView(
                    feedback: PersonalizationActionFeedback(message: importError, isError: true)
                )
            }
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import Preferences") { importError = onConfirm() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .personalizationSheetFrame(PersonalizationSheetLayout.preferencesImport)
    }
}
