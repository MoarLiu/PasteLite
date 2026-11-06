import AppKit
import SwiftUI

struct HistoryPanelView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var historyStore: SQLiteHistoryStore
    @ObservedObject var preferences = AppPreferences.shared
    @ObservedObject var hotkeySettings = HotkeySettingsStore.shared
    let onCopy: (ClipboardItem) -> Void
    let onPaste: (ClipboardItem) -> Void
    let onRemove: (ClipboardItem) -> Void
    let onClear: () -> Void
    let onDismiss: () -> Void
    var onPin: (ClipboardItem) -> Void = { _ in }
    var onUndo: () -> Void = {}
    var onCopyText: (String) -> Void = { _ in }
    var onNewSnippet: () -> Void = {}
    var onCreateSnippet: (ClipboardItem) -> Void = { _ in }
    var onEditSaved: (LibraryItem) -> Void = { _ in }
    var onDeleteGroup: (LibraryGroup) -> Void = { _ in }
    var onMoveSaved: (LibraryItem, UUID?) -> Void = { _, _ in }
    var onClearLibrary: () -> Void = {}
    var onOpenLink: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @FocusState private var searchFocused: Bool
    @State private var scrollProxy: ScrollViewProxy?
    private var filteredItems: [ClipboardItem] { appState.visibleItems }
    private var selectedItem: ClipboardItem? { appState.selectedItem(in: filteredItems) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if appState.mode == .library, let error = historyStore.libraryErrorMessage {
                banner(error, symbol: "exclamationmark.triangle", color: .orange)
                if !historyStore.isLibraryAvailable {
                    Button("Retry Storage") { Task { await historyStore.retryStorage() } }
                        .font(.system(size: 12)).padding(.bottom, 6)
                }
            }
            if let message = historyStore.captureErrorMessage ?? historyStore.errorMessage ?? historyStore.storageWarning {
                banner(message, symbol: "exclamationmark.triangle", color: .orange)
            }
            if preferences.recordingPaused {
                HStack {
                    Label("Recording paused", systemImage: "pause.circle")
                    Spacer()
                    Button("Resume") { preferences.recordingPaused = false }
                        .buttonStyle(.plain).foregroundColor(.accentColor)
                }
                .font(.system(size: 11.5)).padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
            }
            if !AccessibilityService.isTrusted(), preferences.selectionAction == .paste {
                HStack {
                    Label("Allow Accessibility to paste directly. Items can still be copied.", systemImage: "hand.raised")
                    Spacer()
                    Button("Open Settings") { AccessibilityService.openSettings() }
                }
                .font(.system(size: 11)).padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.orange.opacity(0.09))
            }
            Divider()
            HStack(spacing: 0) {
                historyList.frame(width: preferences.showPreview ? PL.Size.listColumnWidth : nil)
                if preferences.showPreview {
                    Divider()
                    DetailView(item: selectedItem, historyStore: historyStore,
                               onCopy: onCopy, onPin: onPin, onCopyText: onCopyText,
                               savedItem: selectedSavedItem, onEdit: { if let item = selectedSavedItem { onEditSaved(item) } })
                        .id(appState.presentationVersion)
                        .frame(width: 880 - PL.Size.listColumnWidth - 1)
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: preferences.showPreview ? 880 : 520, height: 560)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .ignoresSafeArea()
        .accentColor(preferences.accent.color)
        .onAppear { refreshResults(); searchFocused = true }
        .onChange(of: historyStore.snapshotRevision) { _ in refreshResults() }
        .onChange(of: appState.mode) { _ in searchFocused = true }
        .onChange(of: appState.presentationVersion) { _ in searchFocused = true; refreshResults() }
        .sheet(item: Binding(get: { appState.editorDraft }, set: { value in
            if value == nil { appState.requestEditorDismissal() }
        })) { draft in
            SnippetEditorView(appState: appState, store: historyStore, initial: draft)
        }
        .sheet(item: $appState.groupDraft) { draft in
            LibraryGroupEditorView(store: historyStore, draft: draft) { appState.groupDraft = nil }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("View", selection: $appState.mode) {
                    ForEach(PanelMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 135)
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(appState.mode == .history ? "Search history" : "Search saved items", text: $appState.searchText)
                    .textFieldStyle(.plain).font(PL.Font.search).focused($searchFocused)
                    .accessibilityLabel("Search clipboard history")
                if !appState.searchText.isEmpty {
                    Button { appState.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search")
                }
                Text("\(filteredItems.count) items").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).frame(height: 52)
            if appState.mode == .library {
                HStack(spacing: 8) {
                    Picker("Saved group", selection: $appState.selectedGroup) {
                        Text("All Saved").tag(LibraryGroupSelection.all)
                        Text("Ungrouped").tag(LibraryGroupSelection.ungrouped)
                        ForEach(historyStore.libraryGroups) { Text($0.name).tag(LibraryGroupSelection.group($0.id)) }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        Button("New Group…") { appState.groupDraft = LibraryGroupDraft(group: nil) }
                        if let group = selectedGroup {
                            Button("Rename Group…") { appState.groupDraft = LibraryGroupDraft(group: group) }
                            Button("Delete Group…", role: .destructive) { onDeleteGroup(group) }
                        }
                    } label: { Label("Groups", systemImage: "folder") }.fixedSize()
                    Button(action: onNewSnippet) { Label("New Snippet", systemImage: "plus") }
                        .disabled(!historyStore.isLibraryAvailable)
                }.font(.system(size: 12)).padding(.horizontal, 14).padding(.bottom, 8)
            }
            HStack(spacing: 4) {
                ForEach(HistoryFilter.contentFilters) { filter in
                    let count = appState.filterCounts[filter] ?? 0
                    Button { appState.selectedFilter = filter } label: {
                        HStack(spacing: 4) {
                            Text(filter.title).fontWeight(appState.selectedFilter == filter ? .medium : .regular)
                            Text("\(count)").opacity(appState.selectedFilter == filter ? 1 : 0.65)
                        }
                        .font(.system(size: 11.5)).padding(.horizontal, 9).padding(.vertical, 5)
                        .foregroundColor(appState.selectedFilter == filter ? preferences.accent.foregroundColor : .secondary)
                        .background(appState.selectedFilter == filter ? Color.accentColor : .clear, in: Capsule())
                    }.buttonStyle(.plain).accessibilityLabel("\(filter.title), \(count) items")
                }
                Spacer(minLength: 0)
                if preferences.showPreview { KeyCap("↑↓"); Text("navigate").font(.system(size: 11)).foregroundStyle(.tertiary) }
            }.padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    private var historyList: some View {
        Group {
            if historyStore.isLoading {
                ProgressView("Loading history…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: appState.searchText.isEmpty ? "tray" : "magnifyingglass").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(emptyTitle).font(PL.Font.titleLarge)
                    Text(emptyMessage)
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if appState.mode == .library, historyStore.libraryItems.isEmpty {
                        Button("New Snippet", action: onNewSnippet).disabled(!historyStore.isLibraryAvailable)
                        Button("View History") { appState.mode = .history }
                    } else if !historyStore.items.isEmpty || !historyStore.libraryItems.isEmpty {
                        Button("Show All Items") { appState.searchText = ""; appState.selectedFilter = .all }
                        if appState.mode == .library { Button("All Saved") { appState.selectedGroup = .all } }
                    }
                    if preferences.recordingPaused { Button("Resume Recording") { preferences.recordingPaused = false } }
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                if let title = sectionTitle(at: index) {
                                    HStack(spacing: 5) {
                                        if item.isPinned { Image(systemName: item.origin == .library ? "star.fill" : "pin.fill").font(.system(size: 9)) }
                                        Text(title)
                                    }.font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 5)
                                }
                                HistoryRowView(item: item, isSelected: appState.selectedItemID == item.id,
                                               historyStore: historyStore, accent: preferences.accent,
                                               shortcut: index < 9 ? index + 1 : nil,
                                               query: appState.searchText,
                                               isSaved: item.origin == .library || historyStore.savedSnapshot(for: item) != nil)
                                    .id(item.id).contentShape(Rectangle())
                                    .onTapGesture(count: 2) { guard !appState.isUpdatingResults else { return }; appState.selectedItemID = item.id; onPaste(item) }
                                    .onTapGesture { appState.selectedItemID = item.id }
                                    .contextMenu { itemActions(item) }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction { guard !appState.isUpdatingResults else { return }; appState.selectedItemID = item.id; onPaste(item) }
                            }
                        }.padding(.horizontal, 8).padding(.bottom, 10)
                    }
                    .onAppear {
                        self.scrollProxy = proxy
                        scroll(proxy)
                    }
                    .onChange(of: appState.keyboardSelectionVersion) { _ in scroll(proxy) }
                    .onChange(of: appState.visibleItems) { _ in
                        DispatchQueue.main.async { scroll(proxy) }
                    }
                    .onChange(of: appState.searchText) { _ in scroll(proxy) }
                    .onChange(of: appState.selectedFilter) { _ in scroll(proxy) }
                    .onChange(of: appState.presentationVersion) { _ in scroll(proxy) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if historyStore.hasUndoDeletion {
                Text("Item deleted").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Button("Undo ⌘Z", action: onUndo).buttonStyle(.plain).foregroundColor(.accentColor)
                if let message = appState.statusMessage {
                    Text(message).font(.system(size: 11.5)).foregroundStyle(.red).lineLimit(1).help(message)
                }
            } else if let message = appState.statusMessage {
                Text(message).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).help(message)
            } else if appState.isPerformingClipboardAction {
                ProgressView().controlSize(.small)
                Text("Preparing…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else if preferences.showPreview {
                AppIconView(size: 23)
                Text(appState.mode == .history ? "Clipboard History" : "Saved Library").font(.system(size: 12)).foregroundStyle(.secondary)
                KeyCap(hotkeySettings.activeShortcut?.displayTitle ?? "No shortcut")
            }
            Spacer(minLength: 0)
            if preferences.showPreview {
                Button { if let item = selectedItem { onCopy(item) } } label: {
                    HStack(spacing: 5) { Text("Copy"); KeyCap("⌘ C") }
                }.buttonStyle(.plain).disabled(selectedItem == nil || appState.isPerformingClipboardAction || appState.isUpdatingResults)
            }
            Button { if let item = selectedItem { onPaste(item) } } label: {
                HStack(spacing: 6) { Text(primaryTitle); Text("↩") }
                    .font(.system(size: 12.5, weight: .medium)).foregroundColor(preferences.accent.foregroundColor)
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background(preferences.accent.color, in: RoundedRectangle(cornerRadius: 8))
                    .opacity(selectedItem == nil || appState.isPerformingClipboardAction ? 0.45 : 1)
            }
            .buttonStyle(.plain).disabled(selectedItem == nil || appState.isPerformingClipboardAction || appState.isUpdatingResults)
            Divider().frame(height: 22)
            Button { appState.actionsPresented.toggle() } label: {
                HStack(spacing: 5) { Text("Actions"); KeyCap("⌘ K") }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $appState.actionsPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ACTIONS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(6)
                    if let item = selectedItem { itemActions(item) }
                    Divider()
                    if appState.mode == .history {
                        Button("Clear History…", action: onClear).foregroundColor(.red).disabled(historyStore.items.allSatisfy(\.isPinned))
                    } else {
                        Button("New Snippet…", action: onNewSnippet).disabled(!historyStore.isLibraryAvailable)
                        Button("Clear Saved Library…", action: onClearLibrary).foregroundColor(.red).disabled(historyStore.libraryItems.isEmpty && historyStore.libraryGroups.isEmpty)
                    }
                }.buttonStyle(.borderless).padding(12).frame(width: 240).accentColor(preferences.accent.color)
            }
        }
        .font(.system(size: 12)).padding(.horizontal, 14).frame(height: 50)
        .background(Color.primary.opacity(0.025))
    }

    @ViewBuilder private func itemActions(_ item: ClipboardItem) -> some View {
        Button("Copy to Clipboard    ⌘C") { appState.actionsPresented = false; onCopy(item) }
        Button("\(primaryTitle)    ↩") { appState.actionsPresented = false; onPaste(item) }
        if item.origin == .history, item.kind != .concealed {
            Button(historyStore.savedSnapshot(for: item) == nil ? "Save to Library…    ⇧⌘P" : "Remove from Saved    ⇧⌘P") { appState.actionsPresented = false; onPin(item) }
                .disabled(!historyStore.isLibraryAvailable)
        }
        if let saved = historyStore.libraryItems.first(where: { $0.id == item.id }), item.origin == .library {
            Button(saved.type == .snippet ? "Edit Snippet…    ⌘E" : "Edit Name and Group…") { appState.actionsPresented = false; onEditSaved(saved) }
            Menu("Move to Group") {
                Button("Ungrouped") { onMoveSaved(saved, nil) }
                ForEach(historyStore.libraryGroups) { group in Button(group.name) { onMoveSaved(saved, group.id) } }
            }
        }
        if [.text, .code].contains(item.kind) {
            Button(item.origin == .history ? "Save as Text Snippet…" : "Create Text Snippet…") { appState.actionsPresented = false; onCreateSnippet(item) }
        }
        if item.kind == .link, let url = URL(string: item.previewText), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            Button("Open Link") { appState.actionsPresented = false; onOpenLink(url) }
        }
        Divider()
        Button(item.origin == .history ? "Delete from History    ⌘⌫" : "Delete Saved Item    ⌘⌫", role: .destructive) { appState.actionsPresented = false; onRemove(item) }
    }
    private var primaryTitle: String {
        if preferences.selectionAction == .copy || !AccessibilityService.isTrusted() || appState.pasteTargetName == nil { return "Copy to Clipboard" }
        if preferences.plainText { return "Paste as Plain Text" }
        return appState.pasteTargetName.map { "Paste to \($0)" } ?? "Paste"
    }
    private func refreshResults() { appState.refreshResults(history: historyStore.items, library: historyStore.libraryItems, groups: historyStore.libraryGroups) }
    private var selectedSavedItem: LibraryItem? { selectedItem.flatMap { item in item.origin == .library ? historyStore.libraryItems.first(where: { $0.id == item.id }) : nil } }
    private var selectedGroup: LibraryGroup? { historyStore.libraryGroups.first { $0.id == appState.selectedGroup.groupID } }
    private var emptyTitle: String {
        if appState.isUpdatingResults { return "Searching…" }
        if appState.mode == .library, historyStore.libraryItems.isEmpty { return "Keep your favorites close" }
        return appState.mode == .history && historyStore.items.isEmpty ? "Your clipboard, remembered" : "No matching items"
    }
    private var emptyMessage: String {
        if appState.mode == .library, historyStore.libraryItems.isEmpty { return "Save copied content or create a reusable text snippet." }
        return historyStore.items.isEmpty && appState.mode == .history ? "Copy something to get started. It will appear here automatically." : "Try another search, type, or group."
    }
    private func scroll(_ proxy: ScrollViewProxy) { if let id = selectedItem?.id { proxy.scrollTo(id, anchor: .center) } }
    private func banner(_ message: String, symbol: String, color: Color) -> some View {
        Label(message, systemImage: symbol).font(.system(size: 11)).foregroundColor(color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6)
    }
    private func sectionTitle(at index: Int) -> String? {
        if appState.mode == .library { return index == 0 ? (selectedGroup?.name ?? "Saved Items") : nil }
        let item = filteredItems[index]
        func title(_ item: ClipboardItem) -> String {
            if item.isPinned { return "Pinned" }
            if Calendar.current.isDateInToday(item.copiedAt) { return "Today" }
            if Calendar.current.isDateInYesterday(item.copiedAt) { return "Yesterday" }
            return "Earlier"
        }
        let value = title(item)
        return index == 0 || title(filteredItems[index - 1]) != value ? value : nil
    }
}
