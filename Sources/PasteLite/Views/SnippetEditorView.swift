import SwiftUI

@MainActor
struct SnippetEditorView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var store: SQLiteHistoryStore
    let initial: LibraryDraft
    @State private var error: String?
    @State private var confirmDiscard = false
    @FocusState private var nameFocused: Bool

    private var draft: LibraryDraft { appState.editorDraft ?? initial }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 18, weight: .semibold))
            TextField("Name", text: binding(\.name)).textFieldStyle(.roundedBorder)
                .focused($nameFocused).accessibilityLabel("Saved item name")
            HStack {
                Text("Group").frame(width: 60, alignment: .leading)
                Picker("Group", selection: optionalGroupBinding) {
                    Text("Ungrouped").tag(Optional<UUID>.none)
                    ForEach(store.libraryGroups) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(maxWidth: .infinity)
                if draft.isSnippet {
                    Picker("Type", selection: binding(\.kind)) {
                        Text("Text").tag(ClipboardKind.text)
                        Text("Code").tag(ClipboardKind.code)
                    }.frame(width: 130)
                }
            }
            if draft.isSnippet {
                Text("Content").font(.system(size: 12, weight: .medium))
                TextEditor(text: binding(\.body))
                    .font(.system(size: 13, design: draft.kind == .code ? .monospaced : .default))
                    .padding(5).background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    .frame(minHeight: 200, maxHeight: .infinity)
                    .accessibilityLabel("Snippet content")
                Text("Saved as plain text. The original copied content stays unchanged.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("The original text formatting, image, or file reference will be preserved.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true).accessibilityLabel("Save failed: \(error)")
            }
            HStack {
                if appState.isEditorSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { requestClose() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.return, modifiers: .command)
                    .disabled(appState.isEditorSaving || !store.isLibraryAvailable)
            }
        }
        .padding(22).frame(width: 480, height: draft.isSnippet ? 460 : 235)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled()
        .onAppear { nameFocused = true }
        .onChange(of: appState.editorCloseRequest) { _ in requestClose() }
        .onExitCommand { requestClose() }
        .alert("Save Changes?", isPresented: $confirmDiscard) {
            Button("Save") { save() }
            Button("Discard", role: .destructive) { appState.finishEditing() }
            Button("Keep Editing", role: .cancel) { appState.continueEditing() }
        } message: { Text("Your changes have not been saved.") }
    }

    private var title: String {
        if draft.editingID != nil { return draft.isSnippet ? "Edit Snippet" : "Edit Saved Item" }
        return draft.isSnippet ? "New Snippet" : "Save to Library"
    }

    private func binding<Value>(_ key: WritableKeyPath<LibraryDraft, Value>) -> Binding<Value> {
        Binding(get: { draft[keyPath: key] }, set: { value in
            guard var current = appState.editorDraft else { return }
            current[keyPath: key] = value
            appState.editorDraft = current
        })
    }

    private var optionalGroupBinding: Binding<UUID?> { binding(\.groupID) }

    private func requestClose() {
        guard !appState.isEditorSaving else { return }
        if appState.hasUnsavedEditorChanges { confirmDiscard = true }
        else { appState.finishEditing() }
    }

    private func save() {
        guard !appState.isEditorSaving else { return }
        let value = draft
        do {
            _ = try LibraryValidation.name(value.name)
            if value.isSnippet { try LibraryValidation.snippet(value.body, kind: value.kind) }
        } catch { self.error = error.localizedDescription; return }
        appState.isEditorSaving = true
        error = nil
        Task { @MainActor in
            let result = await store.saveLibrary(value)
            appState.isEditorSaving = false
            switch result.result {
            case .success:
                if let id = result.itemID, let item = store.libraryItems.first(where: { $0.id == id }) { appState.revealSaved(item) }
                appState.finishEditing()
            case let .failure(message): error = message
            }
        }
    }
}

@MainActor
struct LibraryGroupEditorView: View {
    @ObservedObject var store: SQLiteHistoryStore
    let draft: LibraryGroupDraft
    let onDismiss: () -> Void
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.group == nil ? "New Group" : "Rename Group").font(.system(size: 18, weight: .semibold))
            TextField("Group name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityLabel("Group name").onSubmit { save() }
            if let error { Text(error).font(.system(size: 12)).foregroundColor(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: onDismiss).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.return, modifiers: .command).disabled(saving)
            }
        }.padding(22).frame(width: 380).background(Color(nsColor: .windowBackgroundColor))
            .onAppear { name = draft.group?.name ?? ""; focused = true }
            .interactiveDismissDisabled()
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task { @MainActor in
            let result: HistoryStoreMutationResult
            if let group = draft.group { result = await store.renameGroup(group, name: name) }
            else { result = await store.createGroup(name).result }
            saving = false
            switch result {
            case .success: onDismiss()
            case let .failure(message): error = message
            }
        }
    }
}
