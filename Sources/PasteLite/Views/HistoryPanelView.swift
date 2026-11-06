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
    @FocusState private var searchFocused: Bool
    @State private var scrollProxy: ScrollViewProxy?
    private var filteredItems: [ClipboardItem] { appState.filteredItems(in: historyStore.items) }
    private var selectedItem: ClipboardItem? { appState.selectedItem(in: filteredItems) }

    var body: some View {
        VStack(spacing: 0) {
            header
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
                               onCopy: onCopy, onPin: onPin, onCopyText: onCopyText)
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
        .onAppear { normalize(); searchFocused = true }
        .onChange(of: historyStore.items) { _ in
            // Data changed but search/filter stayed the same — keep the current selection.
            normalize()
            if let proxy = scrollProxy, let id = selectedItem?.id {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .onChange(of: appState.searchText) { _ in
            // Search criteria changed — reset to first match.
            appState.normalizeSelection(in: filteredItems, resetIndex: true)
            if let proxy = scrollProxy, let id = selectedItem?.id {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .onChange(of: appState.selectedFilter) { _ in
            // Filter changed — reset to first match.
            appState.normalizeSelection(in: filteredItems, resetIndex: true)
            if let proxy = scrollProxy, let id = selectedItem?.id {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .onChange(of: appState.presentationVersion) { _ in searchFocused = true; normalize() }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $appState.searchText)
                    .textFieldStyle(.plain).font(PL.Font.search).focused($searchFocused)
                    .accessibilityLabel("Search clipboard history")
                if !appState.searchText.isEmpty {
                    Button { appState.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search")
                }
                Text("\(filteredItems.count) items").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).frame(height: 52)
            HStack(spacing: 4) {
                ForEach(HistoryFilter.allCases) { filter in
                    let count = historyStore.items.filter { filter.matches($0) }.count
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
                    Text(historyStore.items.isEmpty ? "Your clipboard, remembered" : "No matching items").font(PL.Font.titleLarge)
                    Text(historyStore.items.isEmpty ? "Copy something to get started. It will appear here automatically." : "Try another search or show all your clipboard history.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if !historyStore.items.isEmpty {
                        Button("Show All Items") { appState.searchText = ""; appState.selectedFilter = .all }
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
                                        if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
                                        Text(title)
                                    }.font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 5)
                                }
                                HistoryRowView(item: item, isSelected: selectedItem?.id == item.id,
                                               historyStore: historyStore, accent: preferences.accent,
                                               shortcut: index < 9 ? index + 1 : nil,
                                               query: appState.searchText)
                                    .id(item.id).contentShape(Rectangle())
                                    .onTapGesture(count: 2) { appState.selectedItemID = item.id; onPaste(item) }
                                    .onTapGesture { appState.selectedItemID = item.id }
                                    .contextMenu { itemActions(item) }
                            }
                        }.padding(.horizontal, 8).padding(.bottom, 10)
                    }
                    .onAppear {
                        self.scrollProxy = proxy
                        scroll(proxy)
                    }
                    .onChange(of: appState.keyboardSelectionVersion) { _ in scroll(proxy) }
                    .onChange(of: appState.searchText) { _ in scroll(proxy) }
                    .onChange(of: appState.selectedFilter) { _ in scroll(proxy) }
                    .onChange(of: appState.presentationVersion) { _ in scroll(proxy) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if historyStore.deletedItem != nil {
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
                Text("Clipboard History").font(.system(size: 12)).foregroundStyle(.secondary)
                KeyCap(hotkeySettings.activeShortcut?.displayTitle ?? "No shortcut")
            }
            Spacer(minLength: 0)
            if preferences.showPreview {
                Button { if let item = selectedItem { onCopy(item) } } label: {
                    HStack(spacing: 5) { Text("Copy"); KeyCap("⌘ C") }
                }.buttonStyle(.plain).disabled(selectedItem == nil || appState.isPerformingClipboardAction)
            }
            Button { if let item = selectedItem { onPaste(item) } } label: {
                HStack(spacing: 6) { Text(primaryTitle); Text("↩") }
                    .font(.system(size: 12.5, weight: .medium)).foregroundColor(preferences.accent.foregroundColor)
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background(preferences.accent.color, in: RoundedRectangle(cornerRadius: 8))
                    .opacity(selectedItem == nil || appState.isPerformingClipboardAction ? 0.45 : 1)
            }
            .buttonStyle(.plain).disabled(selectedItem == nil || appState.isPerformingClipboardAction)
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
                    Button("Clear History…", action: onClear).foregroundColor(.red).disabled(historyStore.items.allSatisfy(\.isPinned))
                }.buttonStyle(.borderless).padding(12).frame(width: 240).accentColor(preferences.accent.color)
            }
        }
        .font(.system(size: 12)).padding(.horizontal, 14).frame(height: 50)
        .background(Color.primary.opacity(0.025))
    }

    @ViewBuilder private func itemActions(_ item: ClipboardItem) -> some View {
        Button("Copy to Clipboard    ⌘C") { appState.actionsPresented = false; onCopy(item) }
        Button("\(primaryTitle)    ↩") { appState.actionsPresented = false; onPaste(item) }
        Button(item.isPinned ? "Unpin Item    ⇧⌘P" : "Pin Item    ⇧⌘P") { appState.actionsPresented = false; onPin(item) }
        if item.kind == .link, let url = URL(string: item.previewText), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            Button("Open Link") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("Delete Item    ⌘⌫", role: .destructive) { appState.actionsPresented = false; onRemove(item) }
    }
    private var primaryTitle: String {
        if preferences.selectionAction == .copy || !AccessibilityService.isTrusted() { return "Copy to Clipboard" }
        if preferences.plainText { return "Paste as Plain Text" }
        return appState.pasteTargetName.map { "Paste to \($0)" } ?? "Paste"
    }
    private func normalize() { appState.normalizeSelection(in: filteredItems) }
    private func scroll(_ proxy: ScrollViewProxy) { if let id = selectedItem?.id { proxy.scrollTo(id, anchor: .center) } }
    private func banner(_ message: String, symbol: String, color: Color) -> some View {
        Label(message, systemImage: symbol).font(.system(size: 11)).foregroundColor(color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6)
    }
    private func sectionTitle(at index: Int) -> String? {
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
