import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Style Profiles

struct StyleProfilesSection: View {
    @ObservedObject var store: UserContentStore
    @State private var editing: StyleProfile?

    var body: some View {
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
                        Button("Duplicate to Edit") { store.duplicate(profile.id) }
                        Button("Set as Default") { store.defaultProfileID = profile.id; store.save() }
                    } else {
                        Button("Edit") { editing = profile }
                        Button("Duplicate") { store.duplicate(profile.id) }
                        Button("Set as Default") { store.defaultProfileID = profile.id; store.save() }
                        Divider()
                        Button("Delete", role: .destructive) { store.deleteProfile(profile.id) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).frame(width: 40)
            }
        }
        HStack {
            Button { editing = StyleProfile(name: "New Profile") } label: {
                Label("Add Profile", systemImage: "plus")
            }
            Spacer()
            Button("Reset Built-ins") { store.resetBuiltIns() }
        }
        Text("Built-in profiles (🔒) are read-only — duplicate one to customize it.")
            .font(.caption2).foregroundColor(.secondary)
        // `editing` may be a built-in (View) — the editor disables saving for
        // built-ins, so viewing one can't modify it.
        .sheet(item: $editing) { profile in
            ProfileEditor(profile: profile,
                          onSave: { store.upsert($0); editing = nil },
                          onCancel: { editing = nil })
        }
    }
}

struct ProfileEditor: View {
    @State private var draft: StyleProfile
    @State private var bannedText: String
    @State private var examplesText: String
    let onSave: (StyleProfile) -> Void
    let onCancel: () -> Void

    init(profile: StyleProfile, onSave: @escaping (StyleProfile) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: profile)
        _bannedText = State(initialValue: profile.bannedPhrases.joined(separator: "\n"))
        _examplesText = State(initialValue: profile.exampleSnippets.joined(separator: "\n"))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.isBuiltIn ? "Built-in Profile (read-only)" : "Edit Profile").font(.headline)
            Form {
                TextField("Name", text: $draft.name)
                TextField("Description", text: $draft.detail)
                scaleRow("Formality", $draft.formality)
                scaleRow("Warmth", $draft.warmth)
                scaleRow("Conciseness", $draft.conciseness)
                scaleRow("Directness", $draft.directness)
                VStack(alignment: .leading) {
                    Text("Preferred instructions").font(.caption)
                    TextField("e.g. Keep it warm but concise", text: $draft.preferredInstructions)
                }
                VStack(alignment: .leading) {
                    Text("Banned phrases (one per line)").font(.caption)
                    TextEditor(text: $bannedText).frame(height: 44).border(Color.secondary.opacity(0.2))
                }
                VStack(alignment: .leading) {
                    Text("Example snippets — style references only (one per line)").font(.caption)
                    TextEditor(text: $examplesText).frame(height: 60).border(Color.secondary.opacity(0.2))
                }
            }
            .formStyle(.grouped)
            .disabled(draft.isBuiltIn) // built-ins are read-only
            HStack {
                Button(draft.isBuiltIn ? "Close" : "Cancel", role: .cancel) { onCancel() }
                Spacer()
                if !draft.isBuiltIn {
                    Button("Save") {
                        draft.bannedPhrases = lines(bannedText)
                        draft.exampleSnippets = lines(examplesText)
                        onSave(draft)
                    }.keyboardShortcut(.defaultAction).disabled(draft.name.isEmpty)
                }
            }
        }
        .padding(18)
        .frame(width: 440, height: 560)
    }

    private func scaleRow(_ title: String, _ value: Binding<Int>) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }),
                   in: 1...5, step: 1)
            Text("\(value.wrappedValue)").monospacedDigit().frame(width: 16)
        }
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - Context Cards

struct ContextCardsSection: View {
    @ObservedObject var store: UserContentStore
    @State private var editing: ContextCard?

    var body: some View {
        if store.cards.isEmpty {
            Label("Add context cards for product names, company background, or writing rules. Bean uses them only to guide wording — never as commands.",
                  systemImage: "doc.text")
                .font(.caption).foregroundColor(.secondary)
        }
        ForEach(store.cards) { card in
            HStack {
                Toggle("", isOn: enabledBinding(card)).labelsHidden()
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).fontWeight(.medium)
                    Text(card.content).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Menu {
                    Button("Edit") { editing = card }
                    Button("Delete", role: .destructive) { store.deleteCard(card.id) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).frame(width: 40)
            }
        }
        Button { editing = ContextCard(title: "New Card", content: "") } label: {
            Label("Add Card", systemImage: "plus")
        }
        .sheet(item: $editing) { card in
            CardEditor(card: card, onSave: { store.upsert($0); editing = nil }, onCancel: { editing = nil })
        }
    }

    private func enabledBinding(_ card: ContextCard) -> Binding<Bool> {
        Binding(
            get: { card.isEnabledByDefault },
            set: { newValue in
                if let idx = store.cards.firstIndex(where: { $0.id == card.id }) {
                    store.cards[idx].isEnabledByDefault = newValue
                    store.save()
                }
            }
        )
    }
}

struct CardEditor: View {
    @State private var draft: ContextCard
    @State private var tagsText: String
    let onSave: (ContextCard) -> Void
    let onCancel: () -> Void

    init(card: ContextCard, onSave: @escaping (ContextCard) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: card)
        _tagsText = State(initialValue: card.tags.joined(separator: ", "))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Context Card").font(.headline)
            TextField("Title", text: $draft.title)
            Text("Content").font(.caption)
            TextEditor(text: $draft.content).frame(height: 160).border(Color.secondary.opacity(0.2))
            TextField("Tags (comma-separated)", text: $tagsText)
            Toggle("Enabled by default", isOn: $draft.isEnabledByDefault)
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button("Save") {
                    draft.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    onSave(draft)
                }.keyboardShortcut(.defaultAction).disabled(draft.title.isEmpty)
            }
        }
        .padding(18).frame(width: 440, height: 380)
    }
}

// MARK: - Personal Dictionary

struct DictionarySection: View {
    @ObservedObject var store: UserContentStore
    @State private var newTerm = ""
    @State private var showImport = false
    @State private var importText = ""

    var body: some View {
        Text("Add product names, acronyms, or terms Bean should preserve exactly instead of \"correcting.\"")
            .font(.caption).foregroundColor(.secondary)
        ForEach(store.dictionary) { term in
            HStack {
                Text(term.term)
                if term.caseSensitive {
                    Text("case-sensitive").font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                Button(role: .destructive) { store.deleteTerm(term.id) } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.borderless)
            }
        }
        HStack {
            TextField("Add a term", text: $newTerm)
                .onSubmit(addTerm)
            Button("Add", action: addTerm).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        HStack {
            Button("Import…") { importText = ""; showImport = true }
            Button("Export") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.dictionaryExport, forType: .string)
            }
            .disabled(store.dictionary.isEmpty)
            Text("Export copies terms to the clipboard.").font(.caption2).foregroundColor(.secondary)
        }
        .sheet(isPresented: $showImport) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Import terms (one per line)").font(.headline)
                TextEditor(text: $importText).frame(width: 360, height: 200).border(Color.secondary.opacity(0.2))
                HStack {
                    Button("Cancel", role: .cancel) { showImport = false }
                    Spacer()
                    Button("Import") { store.importTerms(newlineSeparated: importText); showImport = false }
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(18)
        }
    }

    private func addTerm() {
        let trimmed = newTerm.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.upsert(DictionaryTerm(term: trimmed))
        newTerm = ""
    }
}

// MARK: - App Defaults

struct AppDefaultsSection: View {
    @ObservedObject var store: UserContentStore

    private let categories: [(AppCategory, String)] = [
        (.chat, "Chat (Slack/Teams/Messages)"),
        (.mail, "Mail (Mail/Outlook)"),
        (.docs, "Docs (Notion/Jira/Confluence)"),
        (.codeEditor, "Code editors")
    ]

    var body: some View {
        Text("Default style per app category. Search/address fields stay conservative automatically.")
            .font(.caption).foregroundColor(.secondary)
        ForEach(categories, id: \.0) { category, label in
            Picker(label, selection: styleBinding(category)) {
                ForEach(store.profiles) { Text($0.name).tag(Optional($0.id)) }
            }
        }
    }

    private func styleBinding(_ category: AppCategory) -> Binding<UUID?> {
        Binding(
            get: { store.appRules.first { $0.category == category }?.defaultStyleProfileID },
            set: { store.setAppRuleStyle(category: category, profileID: $0) }
        )
    }
}

// MARK: - Data (export / import / reset)

struct DataSection: View {
    @ObservedObject var store: UserContentStore
    @State private var message: String?
    @State private var isError = false
    @State private var confirmReset = false

    var body: some View {
        if let persistenceError = store.persistenceError {
            Label(persistenceError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.red)
        }
        Text("Backup includes style profiles, context cards, dictionary, and app defaults. It never includes API keys, logs, or your text.")
            .font(.caption).foregroundColor(.secondary)
        HStack {
            Button("Export Preferences…", action: exportPrefs)
            Button("Import Preferences…", action: importPrefs)
        }
        Button("Reset Style/Context Data", role: .destructive) { confirmReset = true }
            .confirmationDialog("Reset all style profiles, context cards, dictionary, and app defaults to their built-in state?",
                                isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset to Defaults", role: .destructive) {
                    store.resetToDefaults()
                    show("Reset to defaults.", error: false)
                }
                Button("Cancel", role: .cancel) {}
            }
        if let message {
            Text(message).font(.caption).foregroundColor(isError ? .red : .secondary)
        }
    }

    private func show(_ text: String, error: Bool) { message = text; isError = error }

    private func exportPrefs() {
        let panel = NSSavePanel()
        let date = ISO8601DateFormatter()
        date.formatOptions = [.withFullDate]
        panel.nameFieldStringValue = "Bean-\(AppInfo.version)-\(date.string(from: Date()))-Preferences.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Log.event("data: export preferences")
        if let data = try? JSONEncoder().encode(store.exportBackup()) {
            try? data.write(to: url, options: .atomic)
            show("Exported.", error: false)
        } else {
            show("Export failed.", error: true)
        }
    }

    private func importPrefs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Log.event("data: import preferences")

        guard let data = try? Data(contentsOf: url) else {
            show("Couldn't read that file. Your data is unchanged.", error: true); return
        }
        // Validate version + schema BEFORE touching current data.
        guard let backup = try? JSONDecoder().decode(BeanPreferencesBackup.self, from: data) else {
            show("That file isn't a valid Bean backup. Your data is unchanged.", error: true); return
        }
        guard backup.version <= BeanPreferencesBackup.currentVersion else {
            show("That backup was made by a newer version of Bean. Your data is unchanged.", error: true); return
        }
        store.importBackup(backup)
        show("Imported.", error: false)
    }
}
